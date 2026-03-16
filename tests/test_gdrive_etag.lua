--- Unit tests for dooing-sync.nvim gdrive ETag support.
--- Run with:  nvim --headless -l tests/test_gdrive_etag.lua
---   (from the plugin root directory)
---
--- These tests do NOT hit the real Google Drive API.
--- They test parsing, command construction, and 412 detection via mocking.

vim.opt.rtp:prepend('.')

local pass_count = 0
local fail_count = 0

local function puts(s)
    io.stdout:write(s .. '\n')
    io.stdout:flush()
end

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        pass_count = pass_count + 1
        puts('  ✓ ' .. name)
    else
        fail_count = fail_count + 1
        puts('  ✗ ' .. name)
        puts('    ' .. tostring(err))
    end
end

-- Set up config.
package.loaded['dooing-sync.config'] = nil
local config = require('dooing-sync.config')
config.setup({ debug = false })

package.loaded['dooing-sync.gdrive'] = nil
local gdrive = require('dooing-sync.gdrive')

local parse_response = gdrive._testing.parse_response
local parse_etag_from_headers = gdrive._testing.parse_etag_from_headers

local test_dir = '/tmp/dooing_sync_etag_test_' .. os.time()
os.execute('mkdir -p ' .. test_dir)

-------------------------------------------------------------------------------
puts('parse_response() — 412 detection')
-------------------------------------------------------------------------------

test('E4a: 412 error code returns etag_mismatch', function()
    local body = vim.json.encode({
        error = {
            code = 412,
            message = 'Precondition Failed',
            errors = { { reason = 'conditionNotMet' } },
        }
    })
    local data, err = parse_response(body, '', 0)
    assert(data == nil, 'data should be nil')
    assert(err == 'etag_mismatch', 'err should be etag_mismatch, got: ' .. tostring(err))
end)

test('E4b: 403 error code returns API error (not etag_mismatch)', function()
    local body = vim.json.encode({
        error = {
            code = 403,
            message = 'Forbidden',
        }
    })
    local data, err = parse_response(body, '', 0)
    assert(data == nil, 'data should be nil')
    assert(err ~= 'etag_mismatch', 'err should not be etag_mismatch')
    assert(err:find('Forbidden'), 'err should contain Forbidden')
end)

test('E4c: 200 response with valid data returns data', function()
    local body = vim.json.encode({ id = 'abc', name = 'test.json' })
    local data, err = parse_response(body, '', 0)
    assert(err == nil, 'err should be nil')
    assert(data ~= nil, 'data should not be nil')
    assert(data.id == 'abc')
end)

test('E4d: curl failure returns error', function()
    local data, err = parse_response('', 'connection refused', 7)
    assert(data == nil)
    assert(err:find('curl failed'), 'err should mention curl: ' .. tostring(err))
end)

-------------------------------------------------------------------------------
puts('')
puts('parse_etag_from_headers()')
-------------------------------------------------------------------------------

test('E1a: parses quoted ETag from headers', function()
    local path = test_dir .. '/headers1.txt'
    local f = io.open(path, 'w')
    f:write('HTTP/2 200\r\n')
    f:write('content-type: application/json\r\n')
    f:write('etag: "MTczOTYxODY0MDAwMA"\r\n')
    f:write('cache-control: no-cache\r\n')
    f:write('\r\n')
    f:close()
    local etag = parse_etag_from_headers(path)
    assert(etag == '"MTczOTYxODY0MDAwMA"', 'expected quoted ETag, got: ' .. tostring(etag))
    -- File should be cleaned up.
    local check = io.open(path, 'r')
    assert(check == nil, 'header file should be removed')
end)

test('E1b: parses ETag with mixed case header name', function()
    local path = test_dir .. '/headers2.txt'
    local f = io.open(path, 'w')
    f:write('HTTP/1.1 200 OK\r\n')
    f:write('ETag: "abc123"\r\n')
    f:write('\r\n')
    f:close()
    local etag = parse_etag_from_headers(path)
    assert(etag == '"abc123"', 'expected "abc123", got: ' .. tostring(etag))
end)

test('E1c: returns nil when no ETag header present', function()
    local path = test_dir .. '/headers3.txt'
    local f = io.open(path, 'w')
    f:write('HTTP/2 200\r\n')
    f:write('content-type: application/json\r\n')
    f:write('\r\n')
    f:close()
    local etag = parse_etag_from_headers(path)
    assert(etag == nil, 'expected nil, got: ' .. tostring(etag))
end)

test('E1d: returns nil for missing file', function()
    local etag = parse_etag_from_headers(test_dir .. '/no_such_file.txt')
    assert(etag == nil)
end)

test('E1e: parses unquoted ETag as fallback', function()
    local path = test_dir .. '/headers4.txt'
    local f = io.open(path, 'w')
    f:write('HTTP/2 200\r\n')
    f:write('etag: W/abc123\r\n')
    f:write('\r\n')
    f:close()
    local etag = parse_etag_from_headers(path)
    assert(etag == 'W/abc123', 'expected W/abc123, got: ' .. tostring(etag))
end)

-------------------------------------------------------------------------------
puts('')
puts('upload() — If-Match header construction')
-------------------------------------------------------------------------------

-- We mock vim.system to capture the curl command without making real HTTP calls.
local captured_cmd = nil
local original_system = vim.system

local function mock_system(response_body, response_code)
    response_code = response_code or 0
    vim.system = function(cmd, opts, callback)
        captured_cmd = cmd
        -- Simulate async callback via schedule.
        vim.schedule(function()
            callback({
                stdout = response_body,
                stderr = '',
                code = response_code,
            })
        end)
    end
end

local function restore_system()
    vim.system = original_system
    captured_cmd = nil
end

--- Check if a table (array) contains a value.
local function contains(tbl, val)
    for _, v in ipairs(tbl) do
        if v == val then return true end
    end
    return false
end

--- Find the value after a given flag in a command array.
local function flag_value(cmd, flag)
    for i, v in ipairs(cmd) do
        if v == flag and cmd[i + 1] then
            return cmd[i + 1]
        end
    end
    return nil
end

--- Find ALL values for a repeated flag (e.g. multiple -H).
local function all_flag_values(cmd, flag)
    local values = {}
    for i, v in ipairs(cmd) do
        if v == flag and cmd[i + 1] then
            table.insert(values, cmd[i + 1])
        end
    end
    return values
end

test('E2: upload with ETag sends If-Match header', function()
    local ok_response = vim.json.encode({ id = 'file123', modifiedTime = '2026-01-01T00:00:00Z' })
    mock_system(ok_response)

    local done = false
    gdrive.upload('fake_token', 'file123', '{"data":true}', '"etag_value"', function(ok, err)
        done = true
        assert(ok == true, 'upload should succeed')
        assert(err == nil)
    end)
    vim.wait(2000, function() return done end, 50)
    assert(done, 'timed out')

    -- Verify the curl command contains the If-Match header.
    assert(captured_cmd ~= nil, 'command should have been captured')
    local headers = all_flag_values(captured_cmd, '-H')
    local found_if_match = false
    for _, h in ipairs(headers) do
        if h == 'If-Match: "etag_value"' then
            found_if_match = true
            break
        end
    end
    assert(found_if_match, 'If-Match header not found in: ' .. vim.inspect(headers))
    restore_system()
end)

test('E3: upload without ETag omits If-Match header', function()
    local ok_response = vim.json.encode({ id = 'file123', modifiedTime = '2026-01-01T00:00:00Z' })
    mock_system(ok_response)

    local done = false
    gdrive.upload('fake_token', 'file123', '{"data":true}', nil, function(ok, err)
        done = true
        assert(ok == true)
    end)
    vim.wait(2000, function() return done end, 50)
    assert(done, 'timed out')

    local headers = all_flag_values(captured_cmd, '-H')
    for _, h in ipairs(headers) do
        assert(not h:find('If%-Match'), 'If-Match should not be present: ' .. h)
    end
    restore_system()
end)

test('E2b: upload backward compat — callback as 4th arg', function()
    local ok_response = vim.json.encode({ id = 'file123', modifiedTime = '2026-01-01T00:00:00Z' })
    mock_system(ok_response)

    local done = false
    -- Old signature: upload(token, file_id, content, callback)
    gdrive.upload('fake_token', 'file123', '{"data":true}', function(ok, err)
        done = true
        assert(ok == true)
    end)
    vim.wait(2000, function() return done end, 50)
    assert(done, 'timed out')

    -- Should not have If-Match.
    local headers = all_flag_values(captured_cmd, '-H')
    for _, h in ipairs(headers) do
        assert(not h:find('If%-Match'), 'If-Match should not be present with old signature')
    end
    restore_system()
end)

test('E4e: upload returns etag_mismatch on 412 response', function()
    local body_412 = vim.json.encode({
        error = {
            code = 412,
            message = 'Precondition Failed',
            errors = { { reason = 'conditionNotMet' } },
        }
    })
    mock_system(body_412)

    local done = false
    local result_err = nil
    gdrive.upload('fake_token', 'file123', '{"data":true}', '"old_etag"', function(ok, err)
        done = true
        assert(ok == false, 'upload should fail on 412')
        result_err = err
    end)
    vim.wait(2000, function() return done end, 50)
    assert(done, 'timed out')
    assert(result_err == 'etag_mismatch', 'expected etag_mismatch, got: ' .. tostring(result_err))
    restore_system()
end)

-------------------------------------------------------------------------------
puts('')
puts('push() — ETag passthrough')
-------------------------------------------------------------------------------

test('E5a: push backward compat — callback as 2nd arg', function()
    -- Mock ensure_file to return a cached file ID immediately.
    local ok_response = vim.json.encode({ id = 'file123', modifiedTime = '2026-01-01T00:00:00Z' })
    mock_system(ok_response)

    -- Pre-set a cached token to skip token refresh.
    gdrive._testing._set_test_token = nil  -- we can't easily set internal state
    -- Instead, mock get_access_token.
    local orig_get_token = gdrive.get_access_token
    gdrive.get_access_token = function(cb) cb('fake_token', nil) end

    local orig_ensure = gdrive.ensure_file
    gdrive.ensure_file = function(token, content, cb) cb('file123', false, nil) end

    local done = false
    -- Old signature: push(content, callback)
    gdrive.push('{"test":1}', function(ok, err)
        done = true
        assert(ok == true, 'push should succeed: ' .. tostring(err))
    end)
    vim.wait(2000, function() return done end, 50)
    assert(done, 'timed out')

    -- No If-Match expected.
    local headers = all_flag_values(captured_cmd, '-H')
    for _, h in ipairs(headers) do
        assert(not h:find('If%-Match'), 'If-Match should not be present')
    end

    gdrive.get_access_token = orig_get_token
    gdrive.ensure_file = orig_ensure
    restore_system()
end)

test('E5b: push with ETag forwards to upload', function()
    local ok_response = vim.json.encode({ id = 'file123', modifiedTime = '2026-01-01T00:00:00Z' })
    mock_system(ok_response)

    local orig_get_token = gdrive.get_access_token
    gdrive.get_access_token = function(cb) cb('fake_token', nil) end

    local orig_ensure = gdrive.ensure_file
    gdrive.ensure_file = function(token, content, cb) cb('file123', false, nil) end

    local done = false
    gdrive.push('{"test":1}', '"my_etag_value"', function(ok, err)
        done = true
        assert(ok == true, 'push should succeed: ' .. tostring(err))
    end)
    vim.wait(2000, function() return done end, 50)
    assert(done, 'timed out')

    -- If-Match should be present.
    local headers = all_flag_values(captured_cmd, '-H')
    local found = false
    for _, h in ipairs(headers) do
        if h == 'If-Match: "my_etag_value"' then found = true end
    end
    assert(found, 'If-Match header should be present: ' .. vim.inspect(headers))

    gdrive.get_access_token = orig_get_token
    gdrive.ensure_file = orig_ensure
    restore_system()
end)

-------------------------------------------------------------------------------
puts('')
puts('download() — ETag capture')
-------------------------------------------------------------------------------

test('E1f: download passes ETag from headers to callback', function()
    -- We need to mock vim.system AND create a header file that download expects.
    -- download() creates a temp file path via vim.fn.tempname(), then passes it
    -- to curl as -D <path>. Our mock won't actually run curl, so we need to
    -- pre-create the header file at the path download will use.

    -- Intercept vim.fn.tempname to return a known path.
    local header_path = test_dir .. '/download_headers.txt'
    local orig_tempname = vim.fn.tempname
    vim.fn.tempname = function() return header_path end

    -- Pre-create the header file (simulating curl -D output).
    local hf = io.open(header_path, 'w')
    hf:write('HTTP/2 200\r\n')
    hf:write('content-type: application/json\r\n')
    hf:write('etag: "download_etag_123"\r\n')
    hf:write('\r\n')
    hf:close()

    local todo_json = vim.json.encode({ { id = 'x', text = 'test' } })
    mock_system(todo_json)

    local done = false
    local result_content, result_etag, result_err
    gdrive.download('fake_token', 'file123', function(content, etag, err)
        result_content, result_etag, result_err = content, etag, err
        done = true
    end)
    vim.wait(2000, function() return done end, 50)
    assert(done, 'timed out')

    assert(result_err == nil, 'err should be nil: ' .. tostring(result_err))
    assert(result_content == todo_json, 'content mismatch')
    assert(result_etag == '"download_etag_123"', 'etag mismatch: ' .. tostring(result_etag))

    -- Verify -D flag was in the curl command.
    assert(contains(captured_cmd, '-D'), 'curl command should contain -D flag')

    vim.fn.tempname = orig_tempname
    restore_system()
end)

-------------------------------------------------------------------------------
puts('')
-------------------------------------------------------------------------------

-- Clean up.
os.execute('rm -rf ' .. test_dir)

local total = pass_count + fail_count
if fail_count == 0 then
    puts(string.format('All %d tests passed ✓', total))
else
    puts(string.format('%d/%d tests passed, %d FAILED ✗', pass_count, total, fail_count))
    os.exit(1)
end
