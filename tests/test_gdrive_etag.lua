--- Unit tests for dooing-sync.nvim gdrive version-based concurrency.
--- Run with:  nvim --headless -l tests/test_gdrive_etag.lua
---   (from the plugin root directory)
---
--- These tests do NOT hit the real Google Drive API.
--- They test version checking, command construction, and error detection via mocking.

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

-------------------------------------------------------------------------------
puts('parse_response() — error detection')
-------------------------------------------------------------------------------

test('V1a: 412 error code returns etag_mismatch', function()
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

test('V1b: 403 error code returns API error', function()
    local body = vim.json.encode({
        error = {
            code = 403,
            message = 'Forbidden',
        }
    })
    local data, err = parse_response(body, '', 0)
    assert(data == nil, 'data should be nil')
    assert(err:find('Forbidden'), 'err should contain Forbidden')
end)

test('V1c: 200 response with valid data returns data', function()
    local body = vim.json.encode({ id = 'abc', name = 'test.json' })
    local data, err = parse_response(body, '', 0)
    assert(err == nil, 'err should be nil')
    assert(data ~= nil, 'data should not be nil')
    assert(data.id == 'abc')
end)

test('V1d: curl failure returns error', function()
    local data, err = parse_response('', 'connection refused', 7)
    assert(data == nil)
    assert(err:find('curl failed'), 'err should mention curl: ' .. tostring(err))
end)

-------------------------------------------------------------------------------
puts('')
puts('upload() — version-based conditional upload')
-------------------------------------------------------------------------------

-- Mock infrastructure for vim.system.
local system_calls = {}
local original_system = vim.system

--- Mock vim.system to record calls and return predefined responses.
--- @param responses table Array of {stdout, code} tables, consumed in order.
local function mock_system(responses)
    local call_idx = 0
    system_calls = {}
    vim.system = function(cmd, opts, callback)
        call_idx = call_idx + 1
        table.insert(system_calls, cmd)
        local resp = responses[call_idx] or responses[#responses]
        vim.schedule(function()
            callback({
                stdout = resp.stdout or '',
                stderr = resp.stderr or '',
                code = resp.code or 0,
            })
        end)
    end
end

local function restore_system()
    vim.system = original_system
    system_calls = {}
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

test('V2a: upload with version does pre-flight check and uploads on match', function()
    mock_system({
        -- 1st call: fetch_version returns matching version
        { stdout = vim.json.encode({ version = '42' }) },
        -- 2nd call: actual upload succeeds
        { stdout = vim.json.encode({ id = 'f1', modifiedTime = '2026-01-01T00:00:00Z' }) },
    })

    local done = false
    gdrive.upload('fake_token', 'f1', '{"data":true}', '42', function(ok, err)
        done = true
        assert(ok == true, 'upload should succeed')
        assert(err == nil)
    end)
    vim.wait(2000, function() return done end, 50)
    assert(done, 'timed out')
    assert(#system_calls == 2, 'expected 2 calls (version check + upload), got: ' .. #system_calls)
    restore_system()
end)

test('V2b: upload with version aborts on mismatch', function()
    mock_system({
        -- fetch_version returns a different version
        { stdout = vim.json.encode({ version = '99' }) },
    })

    local done = false
    local result_err
    gdrive.upload('fake_token', 'f1', '{"data":true}', '42', function(ok, err)
        done = true
        result_err = err
        assert(ok == false, 'upload should fail')
    end)
    vim.wait(2000, function() return done end, 50)
    assert(done, 'timed out')
    assert(result_err == 'version_mismatch', 'expected version_mismatch, got: ' .. tostring(result_err))
    assert(#system_calls == 1, 'should only have version check call, got: ' .. #system_calls)
    restore_system()
end)

test('V2c: upload without version skips pre-flight check', function()
    mock_system({
        -- Only call: the upload itself
        { stdout = vim.json.encode({ id = 'f1', modifiedTime = '2026-01-01T00:00:00Z' }) },
    })

    local done = false
    gdrive.upload('fake_token', 'f1', '{"data":true}', nil, function(ok, err)
        done = true
        assert(ok == true)
    end)
    vim.wait(2000, function() return done end, 50)
    assert(done, 'timed out')
    assert(#system_calls == 1, 'expected 1 call (upload only), got: ' .. #system_calls)

    -- No If-Match header should be present
    local headers = all_flag_values(system_calls[1], '-H')
    for _, h in ipairs(headers) do
        assert(not h:find('If%-Match'), 'If-Match should not be present: ' .. h)
    end
    restore_system()
end)

test('V2d: upload backward compat — callback as 4th arg', function()
    mock_system({
        { stdout = vim.json.encode({ id = 'f1', modifiedTime = '2026-01-01T00:00:00Z' }) },
    })

    local done = false
    -- Old signature: upload(token, file_id, content, callback)
    gdrive.upload('fake_token', 'f1', '{"data":true}', function(ok, err)
        done = true
        assert(ok == true)
    end)
    vim.wait(2000, function() return done end, 50)
    assert(done, 'timed out')
    assert(#system_calls == 1, 'should be 1 call (no version check)')
    restore_system()
end)

-------------------------------------------------------------------------------
puts('')
puts('download() — version fetch in parallel')
-------------------------------------------------------------------------------

test('V3a: download returns content and version', function()
    local todo_json = vim.json.encode({ { id = 'x', text = 'test' } })
    mock_system({
        -- 1st call: content download
        { stdout = todo_json },
        -- 2nd call: fetch_version
        { stdout = vim.json.encode({ version = '55' }) },
    })

    local done = false
    local result_content, result_version, result_err
    gdrive.download('fake_token', 'f1', function(content, ver, err)
        result_content, result_version, result_err = content, ver, err
        done = true
    end)
    vim.wait(2000, function() return done end, 50)
    assert(done, 'timed out')
    assert(result_err == nil, 'err should be nil: ' .. tostring(result_err))
    assert(result_content == todo_json, 'content mismatch')
    assert(result_version == '55', 'version should be "55", got: ' .. tostring(result_version))
    assert(#system_calls == 2, 'expected 2 parallel calls')
    restore_system()
end)

test('V3b: download succeeds even if version fetch fails', function()
    local todo_json = vim.json.encode({ { id = 'y', text = 'test2' } })
    mock_system({
        -- 1st call: content download succeeds
        { stdout = todo_json },
        -- 2nd call: fetch_version fails
        { stdout = '', code = 7 },
    })

    local done = false
    local result_content, result_version, result_err
    gdrive.download('fake_token', 'f1', function(content, ver, err)
        result_content, result_version, result_err = content, ver, err
        done = true
    end)
    vim.wait(2000, function() return done end, 50)
    assert(done, 'timed out')
    assert(result_err == nil, 'download should succeed despite version failure')
    assert(result_content == todo_json)
    assert(result_version == nil, 'version should be nil on fetch failure')
    restore_system()
end)

test('V3c: download fails if content request fails', function()
    mock_system({
        -- 1st call: content download fails
        { stdout = '', code = 7 },
        -- 2nd call: version fetch succeeds
        { stdout = vim.json.encode({ version = '55' }) },
    })

    local done = false
    local result_err
    gdrive.download('fake_token', 'f1', function(content, ver, err)
        result_err = err
        done = true
    end)
    vim.wait(2000, function() return done end, 50)
    assert(done, 'timed out')
    assert(result_err ~= nil, 'should have error')
    assert(result_err:find('curl failed'), 'err: ' .. tostring(result_err))
    restore_system()
end)

-------------------------------------------------------------------------------
puts('')
puts('push() — version passthrough')
-------------------------------------------------------------------------------

test('V4a: push without version — backward compat', function()
    mock_system({
        -- upload (no version check)
        { stdout = vim.json.encode({ id = 'f1', modifiedTime = '2026-01-01T00:00:00Z' }) },
    })

    local orig_get_token = gdrive.get_access_token
    gdrive.get_access_token = function(cb) cb('fake_token', nil) end
    local orig_ensure = gdrive.ensure_file
    gdrive.ensure_file = function(_, _, cb) cb('f1', false, nil) end

    local done = false
    -- Old signature: push(content, callback)
    gdrive.push('{"test":1}', function(ok, err)
        done = true
        assert(ok == true, 'push should succeed: ' .. tostring(err))
    end)
    vim.wait(2000, function() return done end, 50)
    assert(done, 'timed out')
    assert(#system_calls == 1, 'should be 1 call (upload only)')

    gdrive.get_access_token = orig_get_token
    gdrive.ensure_file = orig_ensure
    restore_system()
end)

test('V4b: push with version forwards to upload', function()
    mock_system({
        -- 1st: version check (match)
        { stdout = vim.json.encode({ version = '100' }) },
        -- 2nd: upload
        { stdout = vim.json.encode({ id = 'f1', modifiedTime = '2026-01-01T00:00:00Z' }) },
    })

    local orig_get_token = gdrive.get_access_token
    gdrive.get_access_token = function(cb) cb('fake_token', nil) end
    local orig_ensure = gdrive.ensure_file
    gdrive.ensure_file = function(_, _, cb) cb('f1', false, nil) end

    local done = false
    gdrive.push('{"test":1}', '100', function(ok, err)
        done = true
        assert(ok == true, 'push should succeed: ' .. tostring(err))
    end)
    vim.wait(2000, function() return done end, 50)
    assert(done, 'timed out')
    assert(#system_calls == 2, 'expected 2 calls (version check + upload)')

    gdrive.get_access_token = orig_get_token
    gdrive.ensure_file = orig_ensure
    restore_system()
end)

test('V4c: push with version returns version_mismatch on conflict', function()
    mock_system({
        -- version check returns different version
        { stdout = vim.json.encode({ version = '200' }) },
    })

    local orig_get_token = gdrive.get_access_token
    gdrive.get_access_token = function(cb) cb('fake_token', nil) end
    local orig_ensure = gdrive.ensure_file
    gdrive.ensure_file = function(_, _, cb) cb('f1', false, nil) end

    local done = false
    local result_err
    gdrive.push('{"test":1}', '100', function(ok, err)
        done = true
        result_err = err
        assert(ok == false, 'push should fail')
    end)
    vim.wait(2000, function() return done end, 50)
    assert(done, 'timed out')
    assert(result_err == 'version_mismatch', 'expected version_mismatch, got: ' .. tostring(result_err))

    gdrive.get_access_token = orig_get_token
    gdrive.ensure_file = orig_ensure
    restore_system()
end)

-------------------------------------------------------------------------------
puts('')
-------------------------------------------------------------------------------

local total = pass_count + fail_count
if fail_count == 0 then
    puts(string.format('All %d tests passed ✓', total))
else
    puts(string.format('%d/%d tests passed, %d FAILED ✗', pass_count, total, fail_count))
    os.exit(1)
end
