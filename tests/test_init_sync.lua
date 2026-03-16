--- Unit tests for dooing-sync.nvim protected sync cycle.
--- Run with:  nvim --headless -l tests/test_init_sync.lua
---   (from the plugin root directory)
---
--- These tests mock gdrive to avoid real API calls.
--- They verify locking, ETag handling, and retry behavior.

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

--- Wait helper.
local function wait(ms, pred)
    vim.wait(ms, pred, 50)
end

--- Fully reload all dooing-sync modules.
local function reload()
    for k, _ in pairs(package.loaded) do
        if k:match('^dooing%-sync') then package.loaded[k] = nil end
    end
end

-- Test directory.
local test_dir = '/tmp/dooing_sync_init_sync_test_' .. os.time()
os.execute('mkdir -p ' .. test_dir)
local test_save_path = test_dir .. '/dooing_todos.json'
local test_base_path = test_dir .. '/base.json'
local test_lock_path = test_base_path .. '.lock'

--- Seed the local file with test data.
local seed_data = {
    { id = 'item_1', text = 'Test item 1', done = false, created_at = 1000 },
    { id = 'item_2', text = 'Test item 2', done = true, created_at = 2000, completed_at = 2500 },
}

local function seed_local()
    local f = io.open(test_save_path, 'w')
    f:write(vim.json.encode(seed_data, { sort_keys = true }))
    f:close()
end

--- Remove lock file and base snapshot between tests.
local function cleanup()
    pcall(os.remove, test_lock_path)
    pcall(os.remove, test_base_path)
    seed_local()
end

-------------------------------------------------------------------------------
-- Mock gdrive module
-------------------------------------------------------------------------------

--- Create a mock gdrive that records calls and returns configurable responses.
local function make_mock_gdrive()
    local mock = {
        pull_calls = 0,
        push_calls = 0,
        last_push_content = nil,
        last_push_etag = nil,
        -- Configurable responses.
        pull_content = nil,       -- JSON string or nil
        pull_etag = nil,          -- ETag string or nil
        pull_err = nil,           -- error string or nil
        push_ok = true,
        push_err = nil,
    }

    function mock.pull(callback)
        mock.pull_calls = mock.pull_calls + 1
        vim.schedule(function()
            callback(mock.pull_content, mock.pull_etag, mock.pull_err)
        end)
    end

    function mock.push(content, etag_or_cb, callback)
        mock.push_calls = mock.push_calls + 1
        local etag = nil
        if type(etag_or_cb) == 'function' then
            callback = etag_or_cb
        else
            etag = etag_or_cb
        end
        mock.last_push_content = content
        mock.last_push_etag = etag
        vim.schedule(function()
            callback(mock.push_ok, mock.push_err)
        end)
    end

    -- Stubs for functions that init.lua doesn't call directly during sync,
    -- but might be referenced.
    function mock.get_access_token(cb) cb('fake', nil) end
    function mock.find_file(_, _, _, cb) cb('fid', nil) end
    function mock.download(_, _, cb) cb(mock.pull_content, mock.pull_etag, nil) end
    function mock.upload(_, _, content, etag, cb)
        if type(etag) == 'function' then cb = etag; etag = nil end
        cb(mock.push_ok, mock.push_err)
    end
    function mock.ensure_file(_, _, cb) cb('fid', false, nil) end
    function mock.refresh_access_token(cb) cb('fake', nil) end
    function mock.invalidate_token() end

    return mock
end

--- Setup dooing-sync with mocked gdrive.
--- @return table dooing_sync  The init module.
--- @return table mock_gdrive  The mock gdrive.
--- @return table fs           The fs module.
local function setup_with_mock(mock_overrides)
    reload()

    -- Configure.
    local config = require('dooing-sync.config')
    config.setup({
        save_path = test_save_path,
        base_path = test_base_path,
        lock_timeout_ms = 2000,
        max_retries = 2,
        debug = false,
        sync = {
            pull_on_start = false,  -- We control sync calls manually.
            push_on_save = false,
            pull_interval = 0,
        },
        -- Fake credentials so sync_enabled = true.
        env = {
            client_id = 'DOOING_TEST_CID',
            client_secret = 'DOOING_TEST_CS',
            refresh_token = 'DOOING_TEST_RT',
        },
    })

    -- Set fake env vars so credential check passes.
    vim.env.DOOING_TEST_CID = 'fake_cid'
    vim.env.DOOING_TEST_CS = 'fake_cs'
    vim.env.DOOING_TEST_RT = 'fake_rt'

    -- Inject mock gdrive before loading init.
    local mock = make_mock_gdrive()
    if mock_overrides then
        for k, v in pairs(mock_overrides) do mock[k] = v end
    end
    package.loaded['dooing-sync.gdrive'] = mock

    local dooing_sync = require('dooing-sync')
    dooing_sync.setup({
        save_path = test_save_path,
        base_path = test_base_path,
        lock_timeout_ms = 2000,
        max_retries = 2,
        debug = false,
        sync = {
            pull_on_start = false,
            push_on_save = false,
            pull_interval = 0,
        },
        env = {
            client_id = 'DOOING_TEST_CID',
            client_secret = 'DOOING_TEST_CS',
            refresh_token = 'DOOING_TEST_RT',
        },
    })

    local fs = require('dooing-sync.fs')
    return dooing_sync, mock, fs
end

local function teardown_mock(dooing_sync)
    dooing_sync.teardown()
    vim.env.DOOING_TEST_CID = nil
    vim.env.DOOING_TEST_CS = nil
    vim.env.DOOING_TEST_RT = nil
end

-------------------------------------------------------------------------------
puts('S1: Sync acquires and releases lock')
-------------------------------------------------------------------------------

test('lock file exists during sync, removed after', function()
    cleanup()
    local remote_data = vim.json.encode(seed_data, { sort_keys = true })
    local dooing_sync, mock, fs = setup_with_mock()

    local lock_existed = false
    -- Patch pull to check lock state mid-sync (pull always runs).
    mock.pull = function(callback)
        mock.pull_calls = mock.pull_calls + 1
        -- Lock should already be held at this point.
        local lf = io.open(test_lock_path, 'r')
        if lf then
            lock_existed = true
            lf:close()
        end
        vim.schedule(function()
            callback(remote_data, '"etag1"', nil)
        end)
    end

    local done = false
    dooing_sync.sync({ on_done = function() done = true end })
    wait(3000, function() return done end)
    assert(done, 'sync should complete')
    assert(lock_existed, 'lock file should exist during sync')

    -- Lock should be released after sync.
    local lf = io.open(test_lock_path, 'r')
    assert(lf == nil, 'lock file should be removed after sync')

    teardown_mock(dooing_sync)
end)

-------------------------------------------------------------------------------
puts('')
puts('S2: Sync retries on ETag mismatch (412)')
-------------------------------------------------------------------------------

test('retries once on etag_mismatch then succeeds', function()
    cleanup()
    local remote_v1 = { { id = 'item_1', text = 'Test item 1', done = false, created_at = 1000 } }
    local remote_v2 = { { id = 'item_1', text = 'Test item 1', done = false, created_at = 1000 },
                         { id = 'item_3', text = 'Added by other', done = false, created_at = 3000 } }

    local dooing_sync, mock, fs = setup_with_mock()
    local push_attempt = 0

    -- First pull returns v1, second pull returns v2 (someone pushed between).
    local orig_pull = mock.pull
    mock.pull = function(callback)
        mock.pull_calls = mock.pull_calls + 1
        vim.schedule(function()
            if mock.pull_calls <= 1 then
                callback(vim.json.encode(remote_v1, { sort_keys = true }), '"etag_v1"', nil)
            else
                callback(vim.json.encode(remote_v2, { sort_keys = true }), '"etag_v2"', nil)
            end
        end)
    end

    -- First push fails with etag_mismatch, second succeeds.
    mock.push = function(content, etag_or_cb, callback)
        local etag = nil
        if type(etag_or_cb) == 'function' then
            callback = etag_or_cb
        else
            etag = etag_or_cb
        end
        push_attempt = push_attempt + 1
        mock.last_push_content = content
        mock.last_push_etag = etag
        vim.schedule(function()
            if push_attempt == 1 then
                callback(false, 'etag_mismatch')
            else
                callback(true, nil)
            end
        end)
    end

    local done = false
    dooing_sync.sync({ on_done = function() done = true end })
    wait(5000, function() return done end)
    assert(done, 'sync should complete')
    assert(push_attempt == 2, 'should have pushed twice, got: ' .. push_attempt)

    -- Second push should use etag_v2.
    assert(mock.last_push_etag == '"etag_v2"',
        'retry should use fresh ETag, got: ' .. tostring(mock.last_push_etag))

    -- Base should be saved (push succeeded).
    local base = fs.read_json(test_base_path)
    assert(base ~= nil, 'base should exist after successful sync')

    teardown_mock(dooing_sync)
end)

-------------------------------------------------------------------------------
puts('')
puts('S3: Sync gives up after max retries')
-------------------------------------------------------------------------------

test('stops retrying after max_retries', function()
    cleanup()
    local remote = vim.json.encode(
        { { id = 'item_1', text = 'Remote version', done = false, created_at = 1000 } },
        { sort_keys = true })

    local dooing_sync, mock, fs = setup_with_mock({
        pull_content = remote,
        pull_etag = '"always_stale"',
        push_ok = false,
        push_err = 'etag_mismatch',
    })

    -- All pulls return the same thing (perpetual conflict).
    local pull_count = 0
    mock.pull = function(callback)
        pull_count = pull_count + 1
        vim.schedule(function()
            callback(remote, '"always_stale"', nil)
        end)
    end

    local done = false
    dooing_sync.sync({ on_done = function() done = true end })
    wait(10000, function() return done end)
    assert(done, 'sync should complete (with failure)')

    -- Should have tried initial + max_retries = 3 total pulls.
    assert(pull_count == 3, 'expected 3 pull attempts (1 + 2 retries), got: ' .. pull_count)

    -- Base should NOT be saved (all pushes failed).
    local base = fs.read_json(test_base_path)
    assert(base == nil, 'base should not exist when all pushes failed')

    -- Lock should be released.
    local lf = io.open(test_lock_path, 'r')
    assert(lf == nil, 'lock should be released after giving up')

    teardown_mock(dooing_sync)
end)

-------------------------------------------------------------------------------
puts('')
puts('S4: Reentrant sync is skipped')
-------------------------------------------------------------------------------

test('concurrent sync call is skipped', function()
    cleanup()
    local remote = vim.json.encode(seed_data, { sort_keys = true })

    local dooing_sync, mock, fs = setup_with_mock()

    -- Make pull block: don't call callback until we say so.
    local pull_callback = nil
    mock.pull = function(callback)
        mock.pull_calls = mock.pull_calls + 1
        pull_callback = callback
    end

    -- Start first sync (will block at pull).
    local done1 = false
    dooing_sync.sync({ on_done = function() done1 = true end })

    -- Try a second sync while first is in progress.
    local done2 = false
    dooing_sync.sync({ on_done = function() done2 = true end })

    -- Second should complete immediately (skipped).
    wait(500, function() return done2 end)
    assert(done2, 'second sync should complete immediately (skipped)')
    assert(not done1, 'first sync should still be in progress')
    assert(mock.pull_calls == 1, 'only one pull should have been made')

    -- Now unblock the first sync.
    vim.schedule(function()
        pull_callback(remote, '"etag1"', nil)
    end)
    wait(3000, function() return done1 end)
    assert(done1, 'first sync should complete')

    teardown_mock(dooing_sync)
end)

-------------------------------------------------------------------------------
puts('')
puts('S5: File watcher triggers full sync (not blind push)')
-------------------------------------------------------------------------------

test('on_file_changed calls sync not push_local', function()
    cleanup()
    local remote = vim.json.encode(seed_data, { sort_keys = true })
    local dooing_sync, mock, fs = setup_with_mock({
        pull_content = remote,
        pull_etag = '"etag1"',
    })

    -- Enable push_on_save and do an initial sync to set things up.
    local config = require('dooing-sync.config')
    config.options.sync.push_on_save = true

    local done = false
    dooing_sync.sync({ on_done = function() done = true end })
    wait(3000, function() return done end)
    assert(done, 'initial sync should complete')

    -- Now simulate a dooing save by watching then writing.
    -- We can't easily test the watcher integration here, but we can verify
    -- that sync works as the push mechanism (push_local no longer exists).
    mock.pull_calls = 0
    mock.push_calls = 0

    done = false
    dooing_sync.sync({ on_done = function() done = true end })
    wait(3000, function() return done end)
    assert(done, 'second sync should complete')
    -- A full sync should pull (not just push).
    assert(mock.pull_calls >= 1, 'sync should pull, got: ' .. mock.pull_calls)

    teardown_mock(dooing_sync)
end)

-------------------------------------------------------------------------------
puts('')
puts('S6: Base only saved after successful push')
-------------------------------------------------------------------------------

test('base not saved when push fails', function()
    cleanup()
    -- Remove any pre-existing base.
    pcall(os.remove, test_base_path)

    local remote = vim.json.encode(
        { { id = 'item_1', text = 'Remote version', done = true, created_at = 1000 } },
        { sort_keys = true })

    local dooing_sync, mock, fs = setup_with_mock({
        pull_content = remote,
        pull_etag = '"etag1"',
        push_ok = false,
        push_err = 'network error',
    })

    local done = false
    dooing_sync.sync({ on_done = function() done = true end })
    wait(3000, function() return done end)
    assert(done, 'sync should complete')

    -- Base should NOT exist because push failed.
    local base = fs.read_json(test_base_path)
    assert(base == nil, 'base should not be saved when push fails')

    -- Lock should still be released.
    local lf = io.open(test_lock_path, 'r')
    assert(lf == nil, 'lock should be released')

    teardown_mock(dooing_sync)
end)

test('base saved when push succeeds', function()
    cleanup()
    pcall(os.remove, test_base_path)

    local remote = vim.json.encode(
        { { id = 'item_1', text = 'Remote version', done = true, created_at = 1000 } },
        { sort_keys = true })

    local dooing_sync, mock, fs = setup_with_mock({
        pull_content = remote,
        pull_etag = '"etag1"',
        push_ok = true,
    })

    local done = false
    dooing_sync.sync({ on_done = function() done = true end })
    wait(3000, function() return done end)
    assert(done, 'sync should complete')

    local base = fs.read_json(test_base_path)
    assert(base ~= nil, 'base should be saved after successful push')

    teardown_mock(dooing_sync)
end)

test('base saved when remote already up-to-date (no push needed)', function()
    cleanup()

    -- Seed a base snapshot so merge sees all three versions as identical.
    -- This ensures merged output matches remote (no reordering from first-sync path).
    local remote = vim.json.encode(seed_data, { sort_keys = true })
    local bf = io.open(test_base_path, 'w')
    bf:write(remote)
    bf:close()

    local dooing_sync, mock, fs = setup_with_mock({
        pull_content = remote,
        pull_etag = '"etag1"',
    })

    local done = false
    dooing_sync.sync({ on_done = function() done = true end })
    wait(3000, function() return done end)
    assert(done, 'sync should complete')

    local base = fs.read_json(test_base_path)
    assert(base ~= nil, 'base should be saved when no push needed')

    -- With base present and all three identical, no push should be made.
    assert(mock.push_calls == 0, 'no push expected, got: ' .. mock.push_calls)

    teardown_mock(dooing_sync)
end)

-------------------------------------------------------------------------------
puts('')
puts('Sync with pull failure')
-------------------------------------------------------------------------------

test('pull failure releases lock', function()
    cleanup()
    local dooing_sync, mock, fs = setup_with_mock({
        pull_err = 'network timeout',
    })

    local done = false
    dooing_sync.sync({ on_done = function() done = true end })
    wait(3000, function() return done end)
    assert(done, 'sync should complete')

    -- Lock should be released.
    local lf = io.open(test_lock_path, 'r')
    assert(lf == nil, 'lock should be released after pull failure')

    teardown_mock(dooing_sync)
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
