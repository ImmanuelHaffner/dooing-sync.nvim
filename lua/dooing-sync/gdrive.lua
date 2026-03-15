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
        local msg = data.error.message or data.error_description or vim.inspect(data.error)
        return nil, 'API error: ' .. msg
    end
    return data, nil
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
--- @param token string     Access token.
--- @param file_id string   Drive file ID.
--- @param callback fun(content: string|nil, err: string|nil)
function M.download(token, file_id, callback)
    local cmd = curl_cmd({
        '-H', 'Authorization: Bearer ' .. token,
        'https://www.googleapis.com/drive/v3/files/' .. file_id .. '?alt=media',
    })

    vim.system(cmd, { text = true }, function(result)
        vim.schedule(function()
            if result.code ~= 0 then
                callback(nil, 'curl failed (exit ' .. result.code .. ')')
                return
            end
            if not result.stdout or result.stdout == '' then
                callback(nil, 'empty response')
                return
            end
            -- Verify it's valid JSON before returning.
            local ok, _ = pcall(vim.json.decode, result.stdout)
            if not ok then
                -- Could be an error response.
                local edata, _ = pcall(vim.json.decode, result.stdout)
                if type(edata) == 'table' and edata.error then
                    callback(nil, 'API error: ' .. (edata.error.message or 'unknown'))
                else
                    callback(nil, 'downloaded content is not valid JSON')
                end
                return
            end
            config.log('Downloaded ' .. #result.stdout .. ' bytes', vim.log.levels.DEBUG)
            callback(result.stdout, nil)
        end)
    end)
end

--- Update an existing file's content on Google Drive.
--- @param token string     Access token.
--- @param file_id string   Drive file ID.
--- @param content string   New file content (JSON string).
--- @param callback fun(ok: boolean, err: string|nil)
function M.upload(token, file_id, content, callback)
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
--- @param callback fun(content: string|nil, err: string|nil)
function M.pull(callback)
    M.get_access_token(function(token, err)
        if err then callback(nil, err); return end

        local filename = config.options.gdrive_filename
        local folder_id = config.options.gdrive_folder_id

        M.find_file(token, filename, folder_id, function(file_id, find_err)
            if find_err then callback(nil, find_err); return end
            if not file_id then
                -- File doesn't exist on Drive yet; not an error.
                config.log('No remote file found, will create on first push', vim.log.levels.DEBUG)
                callback(nil, nil)
                return
            end
            cached_file_id = file_id
            M.download(token, file_id, callback)
        end)
    end)
end

--- Upload content to the dooing file on Google Drive.
--- Creates the file if it doesn't exist.
--- @param content string  JSON string to upload.
--- @param callback fun(ok: boolean, err: string|nil)
function M.push(content, callback)
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
            M.upload(token, file_id, content, callback)
        end)
    end)
end

return M
