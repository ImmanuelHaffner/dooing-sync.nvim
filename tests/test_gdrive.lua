--- Integration tests for dooing-sync.nvim Google Drive module.
--- Run with:  nvim --headless -l tests/test_gdrive.lua
---   (from the plugin root directory)
---
--- REQUIRES: valid OAuth credentials in environment.
--- These tests hit the real Google Drive API — they are skipped
--- if credentials are not available.

vim.opt.rtp:prepend('.')

local pass_count = 0
local fail_count = 0
local skip_count = 0

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

local function skip(name, reason)
    skip_count = skip_count + 1
    puts('  ⊘ ' .. name .. ' (skipped: ' .. reason .. ')')
end

--- Wait for an async operation to complete.
--- @param timeout_ms integer
--- @param predicate fun(): boolean
local function wait(timeout_ms, predicate)
    vim.wait(timeout_ms, predicate, 100)
end

-------------------------------------------------------------------------------
-- Setup
-------------------------------------------------------------------------------

package.loaded['dooing-sync.config'] = nil
package.loaded['dooing-sync.gdrive'] = nil

local config = require('dooing-sync.config')
-- Use a dedicated test filename so we never touch the user's real data.
local TEST_FILENAME = 'dooing_todos_TEST.json'
config.setup({ debug = false, gdrive_filename = TEST_FILENAME })

local has_creds, missing = config.has_credentials()
if not has_creds then
    puts('gdrive integration tests')
    puts('')
    skip('all tests', 'missing env var: ' .. (missing or '?'))
    puts('')
    puts(string.format('0 passed, 0 failed, %d skipped', skip_count))
    os.exit(0)
end

local gdrive = require('dooing-sync.gdrive')
-- Ensure we start with a clean cached file ID.
gdrive._testing.reset_cached_file_id()

--- Helper: delete the test file from Drive (best-effort cleanup).
local function cleanup_test_file()
    local file_id = gdrive._testing.get_cached_file_id()
    if not file_id then return end
    local done = false
    gdrive.get_access_token(function(token, err)
        if err or not token then done = true; return end
        gdrive.delete_file(token, file_id, function()
            gdrive._testing.reset_cached_file_id()
            done = true
        end)
    end)
    wait(10000, function() return done end)
end

-------------------------------------------------------------------------------
puts('gdrive token management')
-------------------------------------------------------------------------------

test('refresh_access_token obtains a valid token', function()
    local token, err
    local done = false
    gdrive.refresh_access_token(function(t, e)
        token, err = t, e
        done = true
    end)
    wait(10000, function() return done end)
    assert(done, 'timed out')
    assert(err == nil, 'error: ' .. tostring(err))
    assert(token ~= nil, 'token is nil')
    assert(#token > 20, 'token too short')
end)

test('get_access_token returns cached token on second call', function()
    local t1, t2
    local done = false

    gdrive.get_access_token(function(t, _)
        t1 = t
        gdrive.get_access_token(function(t, _)
            t2 = t
            done = true
        end)
    end)
    wait(10000, function() return done end)
    assert(t1 == t2, 'tokens should be identical (cached)')
end)

test('invalidate_token forces a refresh', function()
    local t1, t2
    local done = false

    gdrive.get_access_token(function(t, _)
        t1 = t
        gdrive.invalidate_token()
        gdrive.get_access_token(function(t, _)
            t2 = t
            done = true
        end)
    end)
    wait(15000, function() return done end)
    -- New token may or may not be different (Google sometimes returns same token),
    -- but the call should succeed.
    assert(t1 ~= nil, 'first token nil')
    assert(t2 ~= nil, 'second token nil')
end)

-------------------------------------------------------------------------------
puts('')
puts('gdrive file operations')
-------------------------------------------------------------------------------

test('pull returns content or nil (no error)', function()
    local content, version, err
    local done = false
    gdrive.pull(function(c, ver, e)
        content, version, err = c, ver, e
        done = true
    end)
    wait(15000, function() return done end)
    assert(done, 'timed out')
    assert(err == nil, 'error: ' .. tostring(err))
    -- content may be nil (no file) or a JSON string.
    if content then
        local ok, _ = pcall(vim.json.decode, content)
        assert(ok, 'content should be valid JSON')
        -- Version should be present for an existing file.
        assert(version ~= nil, 'version should be non-nil when content exists')
        assert(tonumber(version) > 0, 'version should be a positive number: ' .. tostring(version))
    end
end)

test('push then pull round-trip', function()
    local test_data = {
        { id = 'gdrive_test_' .. os.time(), text = 'Integration test item',
          done = false, created_at = os.time() },
    }
    local push_content = vim.json.encode(test_data, { sort_keys = true })

    -- Push.
    local push_ok, push_err
    local done = false
    gdrive.push(push_content, function(ok, err)
        push_ok, push_err = ok, err
        done = true
    end)
    wait(15000, function() return done end)
    assert(push_ok, 'push failed: ' .. tostring(push_err))

    -- Pull back.
    local pull_content, pull_version, pull_err
    done = false
    gdrive.pull(function(c, ver, e)
        pull_content, pull_version, pull_err = c, ver, e
        done = true
    end)
    wait(15000, function() return done end)
    assert(pull_err == nil, 'pull error: ' .. tostring(pull_err))
    assert(pull_content ~= nil, 'pull returned nil')

    local pulled = vim.json.decode(pull_content)
    assert(#pulled >= 1, 'expected at least 1 item')
    assert(pulled[1].text == 'Integration test item', 'content mismatch')
    assert(pull_version ~= nil, 'pull should return version')
end)

-------------------------------------------------------------------------------
puts('')
puts('cleanup')
-------------------------------------------------------------------------------

-- Delete the test file from Drive so we don't leave garbage behind.
cleanup_test_file()
puts('  ✓ test file cleaned up from Drive')

-------------------------------------------------------------------------------
puts('')
-------------------------------------------------------------------------------

local total = pass_count + fail_count
if fail_count == 0 then
    puts(string.format('All %d tests passed ✓ (%d skipped)', total, skip_count))
else
    puts(string.format('%d/%d tests passed, %d FAILED ✗ (%d skipped)',
        pass_count, total, fail_count, skip_count))
    os.exit(1)
end
