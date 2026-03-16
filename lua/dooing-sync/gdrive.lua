--- dooing-sync.nvim Google Drive API module.
--- Handles OAuth token refresh, file search, download, upload, and creation.
--- All operations are async via vim.system() + curl.
local M = {}

local config = require('dooing-sync.config')

--- Cached access token and expiry.
local access_token = nil
local token_expires_at = 0

-------------------------------------------------------------------------------
-- Internal helpers
-------------------------------------------------------------------------------

--- Build a curl command table with common options.
--- @param args table  Additional curl arguments.
--- @return table
local function curl_cmd(args)
    local cmd = { 'curl', '-s', '--connect-timeout', '10', '--max-time', '30' }
    for _, arg in ipairs(args) do
        table.insert(cmd, arg)
    end
    return cmd
end

--- Parse a JSON response body, handling errors.
--- @param stdout string
--- @param stderr string
--- @param code integer
--- @return table|nil data
--- @return string|nil err
local function parse_response(stdout, stderr, code)
    if code ~= 0 then
        return nil, 'curl failed (exit ' .. code .. '): ' .. (stderr or '')
    end
    if not stdout or stdout == '' then
        return nil, 'empty response'
    end
    local ok, data = pcall(vim.json.decode, stdout)
    if not ok then
        return nil, 'invalid JSON response: ' .. stdout:sub(1, 200)
    end
    if data.error then
        -- Distinguish 412 Precondition Failed (ETag mismatch) from other errors.
        if data.error.code == 412 then
            return nil, 'etag_mismatch'
        end
        local msg = data.error.message or data.error_description or vim.inspect(data.error)
        return nil, 'API error: ' .. msg
    end
    return data, nil
end

--- Fetch the current version of a file from Google Drive metadata.
--- The version is a monotonically increasing string used for optimistic concurrency.
--- @param token string     Access token.
--- @param file_id string   Drive file ID.
--- @param callback fun(version: string|nil, err: string|nil)
local function fetch_version(token, file_id, callback)
    local cmd = curl_cmd({
        '-H', 'Authorization: Bearer ' .. token,
        'https://www.googleapis.com/drive/v3/files/' .. file_id .. '?fields=version',
    })

    vim.system(cmd, { text = true }, function(result)
        vim.schedule(function()
            local data, err = parse_response(result.stdout, result.stderr, result.code)
            if err then
                callback(nil, err)
                return
            end
            callback(data.version, nil)
        end)
    end)
end

-------------------------------------------------------------------------------
-- Token management
-------------------------------------------------------------------------------

--- Refresh the OAuth access token using the stored refresh token.
--- @param callback fun(token: string|nil, err: string|nil)
function M.refresh_access_token(callback)
    local client_id     = vim.env[config.options.env.client_id]
    local client_secret = vim.env[config.options.env.client_secret]
    local refresh_token = vim.env[config.options.env.refresh_token]

    if not client_id or not client_secret or not refresh_token then
        callback(nil, 'missing OAuth credentials in environment')
        return
    end

    local cmd = curl_cmd({
        '-X', 'POST', 'https://oauth2.googleapis.com/token',
        '-d', 'client_id=' .. client_id,
        '-d', 'client_secret=' .. client_secret,
        '-d', 'refresh_token=' .. refresh_token,
        '-d', 'grant_type=refresh_token',
    })

    vim.system(cmd, { text = true }, function(result)
        vim.schedule(function()
            local data, err = parse_response(result.stdout, result.stderr, result.code)
            if err then
                config.log('Token refresh failed: ' .. err, vim.log.levels.ERROR)
                callback(nil, err)
                return
            end
            access_token = data.access_token
            token_expires_at = os.time() + (data.expires_in or 3600) - 60  -- 60s safety margin
            config.log('Access token refreshed, expires in ' .. (data.expires_in or '?') .. 's', vim.log.levels.DEBUG)
            callback(access_token, nil)
        end)
    end)
end

--- Get a valid access token, refreshing if necessary.
--- @param callback fun(token: string|nil, err: string|nil)
function M.get_access_token(callback)
    if access_token and os.time() < token_expires_at then
        callback(access_token, nil)
        return
    end
    M.refresh_access_token(callback)
end

--- Clear the cached access token (e.g. after a 401).
function M.invalidate_token()
    access_token = nil
    token_expires_at = 0
end

-------------------------------------------------------------------------------
-- File operations
-------------------------------------------------------------------------------

--- Search Google Drive for a file by name.
--- @param token string        Access token.
--- @param filename string     File name to search for.
--- @param folder_id string|nil  Parent folder ID (nil = search everywhere).
--- @param callback fun(file_id: string|nil, err: string|nil)
function M.find_file(token, filename, folder_id, callback)
    local q = "name='" .. filename .. "' and trashed=false"
    if folder_id then
        q = q .. " and '" .. folder_id .. "' in parents"
    end

    local cmd = curl_cmd({
        '-H', 'Authorization: Bearer ' .. token,
        'https://www.googleapis.com/drive/v3/files?q=' .. vim.uri_encode(q)
            .. '&fields=files(id,name,modifiedTime)&spaces=drive',
    })

    vim.system(cmd, { text = true }, function(result)
        vim.schedule(function()
            local data, err = parse_response(result.stdout, result.stderr, result.code)
            if err then
                callback(nil, err)
                return
            end
            if data.files and #data.files > 0 then
                local file = data.files[1]
                config.log('Found file: ' .. file.name .. ' (id: ' .. file.id .. ')', vim.log.levels.DEBUG)
                callback(file.id, nil)
            else
                config.log('File not found: ' .. filename, vim.log.levels.DEBUG)
                callback(nil, nil)  -- Not an error, just doesn't exist yet.
            end
        end)
    end)
end

--- Download a file's content from Google Drive.
--- Fetches content and file version in parallel. The version string is used
--- for optimistic concurrency on subsequent uploads.
--- @param token string     Access token.
--- @param file_id string   Drive file ID.
--- @param callback fun(content: string|nil, version: string|nil, err: string|nil)
function M.download(token, file_id, callback)
    local content_cmd = curl_cmd({
        '-H', 'Authorization: Bearer ' .. token,
        'https://www.googleapis.com/drive/v3/files/' .. file_id .. '?alt=media',
    })

    -- Fire content download and version fetch in parallel.
    local content_result, version_str, version_err
    local pending = 2

    local function try_finish()
        pending = pending - 1
        if pending > 0 then return end

        -- Both requests done — process results.
        vim.schedule(function()
            if not content_result then
                callback(nil, nil, 'content request missing')
                return
            end
            if content_result.code ~= 0 then
                callback(nil, nil, 'curl failed (exit ' .. content_result.code .. ')')
                return
            end
            if not content_result.stdout or content_result.stdout == '' then
                callback(nil, nil, 'empty response')
                return
            end
            -- Verify it's valid JSON and not an API error response.
            local decode_ok, decoded = pcall(vim.json.decode, content_result.stdout)
            if not decode_ok then
                callback(nil, nil, 'downloaded content is not valid JSON')
                return
            end
            if type(decoded) == 'table' and decoded.error then
                local msg = decoded.error.message or vim.inspect(decoded.error)
                callback(nil, nil, 'API error: ' .. msg)
                return
            end
            if version_err then
                config.log('Version fetch failed: ' .. version_err .. ' (continuing without version)', vim.log.levels.WARN)
            end
            config.log('Downloaded ' .. #content_result.stdout .. ' bytes (version: ' .. (version_str or 'nil') .. ')', vim.log.levels.DEBUG)
            callback(content_result.stdout, version_str, nil)
        end)
    end

    vim.system(content_cmd, { text = true }, function(result)
        content_result = result
        try_finish()
    end)

    fetch_version(token, file_id, function(ver, err)
        version_str = ver
        version_err = err
        try_finish()
    end)
end

--- Update an existing file's content on Google Drive.
--- Supports conditional upload via version check (optimistic concurrency).
--- If an expected_version is provided, the current version is fetched first;
--- if it doesn't match, the upload is aborted with a 'version_mismatch' error.
--- @param token string              Access token.
--- @param file_id string            Drive file ID.
--- @param content string            New file content (JSON string).
--- @param version_or_cb string|function|nil  Expected version for conditional upload, or callback (backward compat).
--- @param callback fun(ok: boolean, err: string|nil)|nil
function M.upload(token, file_id, content, version_or_cb, callback)
    -- Backward compatible: upload(token, file_id, content, callback) still works.
    local expected_version = nil
    if type(version_or_cb) == 'function' then
        callback = version_or_cb
    else
        expected_version = version_or_cb
    end

    local function do_upload()
        local cmd = curl_cmd({
            '-X', 'PATCH',
            '-H', 'Authorization: Bearer ' .. token,
            '-H', 'Content-Type: application/json',
            '--data-raw', content,
            'https://www.googleapis.com/upload/drive/v3/files/' .. file_id
                .. '?uploadType=media&fields=id,modifiedTime',
        })

        vim.system(cmd, { text = true }, function(result)
            vim.schedule(function()
                local data, err = parse_response(result.stdout, result.stderr, result.code)
                if err then
                    callback(false, err)
                    return
                end
                config.log('Uploaded to file ' .. (data.id or file_id), vim.log.levels.DEBUG)
                callback(true, nil)
            end)
        end)
    end

    if expected_version then
        -- Pre-flight check: verify the remote version hasn't changed.
        fetch_version(token, file_id, function(current_version, ver_err)
            if ver_err then
                callback(false, 'version check failed: ' .. ver_err)
                return
            end
            if current_version ~= expected_version then
                config.log('Version mismatch: expected ' .. expected_version
                    .. ', got ' .. (current_version or 'nil'), vim.log.levels.DEBUG)
                callback(false, 'version_mismatch')
                return
            end
            do_upload()
        end)
    else
        do_upload()
    end
end

--- Create a new file on Google Drive.
--- @param token string          Access token.
--- @param filename string       File name.
--- @param folder_id string|nil  Parent folder ID (nil = root).
--- @param content string        File content (JSON string).
--- @param callback fun(file_id: string|nil, err: string|nil)
function M.create(token, filename, folder_id, content, callback)
    -- Use multipart upload to set metadata + content in one request.
    local metadata = { name = filename, mimeType = 'application/json' }
    if folder_id then
        metadata.parents = { folder_id }
    end
    local metadata_json = vim.json.encode(metadata)

    local boundary = 'dooing_sync_boundary_' .. os.time()
    local body = '--' .. boundary .. '\r\n'
        .. 'Content-Type: application/json; charset=UTF-8\r\n\r\n'
        .. metadata_json .. '\r\n'
        .. '--' .. boundary .. '\r\n'
        .. 'Content-Type: application/json\r\n\r\n'
        .. content .. '\r\n'
        .. '--' .. boundary .. '--'

    local cmd = curl_cmd({
        '-X', 'POST',
        '-H', 'Authorization: Bearer ' .. token,
        '-H', 'Content-Type: multipart/related; boundary=' .. boundary,
        '--data-raw', body,
        'https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id,name,modifiedTime',
    })

    vim.system(cmd, { text = true }, function(result)
        vim.schedule(function()
            local data, err = parse_response(result.stdout, result.stderr, result.code)
            if err then
                callback(nil, err)
                return
            end
            config.log('Created file: ' .. (data.name or filename) .. ' (id: ' .. (data.id or '?') .. ')', vim.log.levels.DEBUG)
            callback(data.id, nil)
        end)
    end)
end

-------------------------------------------------------------------------------
-- High-level operations
-------------------------------------------------------------------------------

--- Cached file ID to avoid repeated searches.
local cached_file_id = nil

--- Find the dooing file on Drive, creating it if it doesn't exist.
--- Caches the file ID for subsequent calls.
--- @param token string
--- @param content_for_create string  Content to use if creating a new file.
--- @param callback fun(file_id: string|nil, created: boolean, err: string|nil)
function M.ensure_file(token, content_for_create, callback)
    if cached_file_id then
        callback(cached_file_id, false, nil)
        return
    end

    local filename = config.options.gdrive_filename
    local folder_id = config.options.gdrive_folder_id

    M.find_file(token, filename, folder_id, function(file_id, err)
        if err then
            callback(nil, false, err)
            return
        end
        if file_id then
            cached_file_id = file_id
            callback(file_id, false, nil)
        else
            -- File doesn't exist yet; create it.
            M.create(token, filename, folder_id, content_for_create, function(new_id, create_err)
                if create_err then
                    callback(nil, false, create_err)
                    return
                end
                cached_file_id = new_id
                callback(new_id, true, nil)
            end)
        end
    end)
end

--- Download the dooing file from Google Drive.
--- Handles token acquisition, file lookup, and download in one call.
--- @param callback fun(content: string|nil, version: string|nil, err: string|nil)
function M.pull(callback)
    M.get_access_token(function(token, err)
        if err then callback(nil, nil, err); return end

        local filename = config.options.gdrive_filename
        local folder_id = config.options.gdrive_folder_id

        M.find_file(token, filename, folder_id, function(file_id, find_err)
            if find_err then callback(nil, nil, find_err); return end
            if not file_id then
                -- File doesn't exist on Drive yet; not an error.
                config.log('No remote file found, will create on first push', vim.log.levels.DEBUG)
                callback(nil, nil, nil)
                return
            end
            cached_file_id = file_id
            M.download(token, file_id, callback)
        end)
    end)
end

--- Upload content to the dooing file on Google Drive.
--- Creates the file if it doesn't exist.
--- Supports conditional upload via version check to prevent lost updates.
--- @param content string                      JSON string to upload.
--- @param version_or_cb string|function|nil   Expected version for conditional upload, or callback (backward compat).
--- @param callback fun(ok: boolean, err: string|nil)|nil
function M.push(content, version_or_cb, callback)
    -- Backward compatible: push(content, callback) still works.
    local expected_version = nil
    if type(version_or_cb) == 'function' then
        callback = version_or_cb
    else
        expected_version = version_or_cb
    end

    if expected_version then
        config.log('Pushing with expected version: ' .. expected_version, vim.log.levels.DEBUG)
    end

    M.get_access_token(function(token, err)
        if err then callback(false, err); return end

        M.ensure_file(token, content, function(file_id, created, ensure_err)
            if ensure_err then callback(false, ensure_err); return end
            if created then
                -- File was just created with our content; no need to upload again.
                config.log('Created new remote file', vim.log.levels.INFO)
                callback(true, nil)
                return
            end
            M.upload(token, file_id, content, expected_version, callback)
        end)
    end)
end

--- Delete a file from Google Drive (permanently).
--- @param token string     Access token.
--- @param file_id string   Drive file ID.
--- @param callback fun(ok: boolean, err: string|nil)
function M.delete_file(token, file_id, callback)
    local cmd = curl_cmd({
        '-X', 'DELETE',
        '-H', 'Authorization: Bearer ' .. token,
        'https://www.googleapis.com/drive/v3/files/' .. file_id,
    })

    vim.system(cmd, { text = true }, function(result)
        vim.schedule(function()
            if result.code ~= 0 then
                callback(false, 'curl failed (exit ' .. result.code .. ')')
                return
            end
            -- Successful DELETE returns 204 No Content (empty body).
            if result.stdout and result.stdout ~= '' then
                local _, err = parse_response(result.stdout, result.stderr, result.code)
                if err then
                    callback(false, err)
                    return
                end
            end
            config.log('Deleted file ' .. file_id, vim.log.levels.DEBUG)
            callback(true, nil)
        end)
    end)
end

--- Expose internals for testing.
--- @private
M._testing = {
    parse_response = parse_response,
    fetch_version = fetch_version,
    curl_cmd = curl_cmd,
    --- Reset cached file ID (for tests that switch filenames).
    reset_cached_file_id = function() cached_file_id = nil end,
    --- Get cached file ID (for test cleanup).
    get_cached_file_id = function() return cached_file_id end,
}

return M
