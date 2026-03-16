--- Integration tests for dooing-sync.nvim init module (full sync lifecycle).
--- Run with:  nvim --headless -l tests/test_init.lua
---   (from the plugin root directory)
---
--- REQUIRES: valid OAuth credentials in environment.
--- Skipped if credentials are not available.

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

--- Fully reload all dooing-sync modules.
local function reload()
    for k, _ in pairs(package.loaded) do
        if k:match('^dooing%-sync') then package.loaded[k] = nil end
    end
end

--- Wait helper.
local function wait(ms, pred)
    vim.wait(ms, pred, 50)
end

-------------------------------------------------------------------------------
-- Credential check
-------------------------------------------------------------------------------

reload()
local cfg = require('dooing-sync.config')
cfg.setup({})
local has_creds, missing = cfg.has_credentials()

if not has_creds then
    puts('init integration tests')
    puts('')
    skip('all tests', 'missing env var: ' .. (missing or '?'))
    puts('')
    puts(string.format('0 passed, 0 failed, %d skipped', skip_count))
    os.exit(0)
end

-------------------------------------------------------------------------------
-- Setup with a temporary save_path and a dedicated test filename on Drive
-- so we never touch the user's real data.
-------------------------------------------------------------------------------

local TEST_FILENAME = 'dooing_todos_TEST.json'

local test_dir = '/tmp/dooing_sync_init_test_' .. os.time()
os.execute('mkdir -p ' .. test_dir)
local test_save_path = test_dir .. '/dooing_todos.json'
local test_base_path = test_dir .. '/base.json'

-- Seed with some test data.
local seed_data = {
    { id = 'init_test_1', text = 'Init test item 1', done = false, created_at = os.time() - 100 },
    { id = 'init_test_2', text = 'Init test item 2', done = true, created_at = os.time() - 50,
      completed_at = os.time() - 10 },
}
local f = io.open(test_save_path, 'w')
f:write(vim.json.encode(seed_data, { sort_keys = true }))
f:close()

-------------------------------------------------------------------------------
puts('init.setup()')
-------------------------------------------------------------------------------

test('setup completes without error', function()
    reload()
    local dooing_sync = require('dooing-sync')
    dooing_sync.setup({
        save_path = test_save_path,
        base_path = test_base_path,
        gdrive_filename = TEST_FILENAME,
        debug = false,
        sync = {
            sync_on_open = true,
            push_on_save = true,
            sync_on_close = false,
            pull_interval = 0,
        },
    })
    local status = dooing_sync.status()
    assert(status.enabled == true, 'sync should be enabled')

    -- In headless mode (no UI), start_sync_engine is deferred to UIEnter.
    -- Fire the autocmd manually to start the sync engine (watcher, timer, initial sync).
    vim.api.nvim_exec_autocmds('UIEnter', { group = 'dooing_sync' })

    -- Wait for the async sync to complete.
    wait(15000, function()
        return require('dooing-sync').status().last_sync ~= nil
    end)
end)

test('initial sync sets last_sync time', function()
    local status = require('dooing-sync').status()
    assert(status.last_sync ~= nil, 'last_sync should be set after async sync')
    assert(os.time() - status.last_sync < 30, 'sync should be recent')
end)

test('base snapshot created after initial sync', function()
    local fs = require('dooing-sync.fs')
    local base = fs.read_json(test_base_path)
    assert(base ~= nil, 'base should exist')
    assert(#base >= 2, 'base should have our seed items')
end)

-------------------------------------------------------------------------------
puts('')
puts('push-on-save via file watcher')
-------------------------------------------------------------------------------

test('file write triggers push to Drive', function()
    -- Ensure at least 1 second has elapsed since last sync so os.time() advances.
    local prev_sync = require('dooing-sync').status().last_sync or 0
    wait(1500, function() return os.time() > prev_sync end)

    -- Modify the local file (simulate dooing saving).
    local new_data = {
        { id = 'init_test_1', text = 'Init test item 1', done = false, created_at = os.time() - 100 },
        { id = 'init_test_2', text = 'Init test item 2', done = true, created_at = os.time() - 50,
          completed_at = os.time() - 10 },
        { id = 'init_test_3', text = 'Newly added item', done = false, created_at = os.time() },
    }
    local file = io.open(test_save_path, 'w')
    file:write(vim.json.encode(new_data, { sort_keys = true }))
    file:close()

    -- Wait for debounce (500ms) + async lock + network push.
    wait(15000, function()
        local s = require('dooing-sync').status()
        return s.last_sync and s.last_sync > prev_sync
    end)

    local status = require('dooing-sync').status()
    assert(status.last_sync and status.last_sync > prev_sync, 'sync time should have advanced')

    -- Verify remote has the new item.
    local pull_done = false
    local remote_items
    require('dooing-sync.gdrive').pull(function(content, _etag, err)
        if content then
            remote_items = vim.json.decode(content)
        end
        pull_done = true
    end)
    wait(10000, function() return pull_done end)
    assert(remote_items ~= nil, 'should pull remote')

    local found = false
    for _, item in ipairs(remote_items) do
        if item.id == 'init_test_3' then found = true end
    end
    assert(found, 'new item should be on remote')
end)

-------------------------------------------------------------------------------
puts('')
puts('manual sync command')
-------------------------------------------------------------------------------

test(':DooingSync runs without error', function()
    vim.cmd('DooingSync')
    wait(10000, function()
        local s = require('dooing-sync').status()
        return s.last_report and s.last_report.is_noop == true
    end)
    local s = require('dooing-sync').status()
    assert(s.last_report ~= nil, 'report should exist')
end)

test(':DooingSyncStatus runs without error', function()
    -- Just verify it doesn't throw.
    vim.cmd('DooingSyncStatus')
end)

-------------------------------------------------------------------------------
puts('')
puts('status API')
-------------------------------------------------------------------------------

test('status() returns expected fields', function()
    local status = require('dooing-sync').status()
    assert(type(status.enabled) == 'boolean')
    assert(type(status.last_sync) == 'number')
    assert(type(status.last_report) == 'table')
end)

-------------------------------------------------------------------------------
puts('')
puts('teardown')
-------------------------------------------------------------------------------

test('teardown cleans up', function()
    require('dooing-sync').teardown()
    local status = require('dooing-sync').status()
    assert(status.enabled == false)
    assert(status.last_sync == nil)
end)

test('commands removed after teardown', function()
    local ok1 = pcall(vim.cmd, 'DooingSync')
    local ok2 = pcall(vim.cmd, 'DooingSyncStatus')
    assert(not ok1, 'DooingSync should not exist')
    assert(not ok2, 'DooingSyncStatus should not exist')
end)

-------------------------------------------------------------------------------
puts('')
puts('setup without credentials')
-------------------------------------------------------------------------------

test('setup with missing credentials disables sync gracefully', function()
    reload()
    local dooing_sync = require('dooing-sync')
    dooing_sync.setup({
        save_path = test_save_path,
        base_path = test_base_path,
        env = {
            client_id = 'NONEXISTENT_VAR_1',
            client_secret = 'NONEXISTENT_VAR_2',
            refresh_token = 'NONEXISTENT_VAR_3',
        },
    })
    local status = dooing_sync.status()
    assert(status.enabled == false, 'sync should be disabled')
    dooing_sync.teardown()
end)

-------------------------------------------------------------------------------
puts('')
-------------------------------------------------------------------------------

-- Clean up test file from Drive (best-effort).
-- Reuse the already-loaded gdrive module to avoid stale module side-effects.
local function cleanup_test_file()
    local gdrive = require('dooing-sync.gdrive')
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
cleanup_test_file()
puts('  ✓ test file cleaned up from Drive')

-- Clean up test directory.
os.execute('rm -rf ' .. test_dir)

local total = pass_count + fail_count
if fail_count == 0 then
    puts(string.format('All %d tests passed ✓ (%d skipped)', total, skip_count))
else
    puts(string.format('%d/%d tests passed, %d FAILED ✗ (%d skipped)',
        pass_count, total, fail_count, skip_count))
    os.exit(1)
end
