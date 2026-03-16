--- Tests for dooing-sync.nvim config module.
--- Run with:  nvim --headless -l tests/test_config.lua
---   (from the plugin root directory)

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

--- Reset module state between tests.
local function reload_config(opts)
    package.loaded['dooing-sync.config'] = nil
    local config = require('dooing-sync.config')
    config.setup(opts)
    return config
end

-------------------------------------------------------------------------------
puts('config.setup()')
-------------------------------------------------------------------------------

test('defaults are set when no opts given', function()
    local config = reload_config()
    assert(config.options.base_path ~= nil, 'base_path set')
    assert(config.options.gdrive_filename == 'dooing_todos.json', 'gdrive_filename default')
    assert(config.options.sync.sync_on_open == true, 'sync_on_open default')
    assert(config.options.sync.push_on_save == true, 'push_on_save default')
    assert(config.options.sync.sync_on_close == true, 'sync_on_close default')
    assert(config.options.sync.pull_interval == 300, 'pull_interval default')
    assert(config.options.conflict_strategy == 'recent', 'conflict_strategy default')
    assert(config.options.debug == false, 'debug default')
end)

test('user opts override defaults', function()
    local config = reload_config({
        debug = true,
        conflict_strategy = 'local',
        sync = { pull_interval = 60 },
    })
    assert(config.options.debug == true, 'debug overridden')
    assert(config.options.conflict_strategy == 'local', 'conflict_strategy overridden')
    assert(config.options.sync.pull_interval == 60, 'pull_interval overridden')
    -- Non-overridden nested values preserved by vim.tbl_deep_extend.
    assert(config.options.sync.sync_on_open == true, 'sync_on_open still default')
    assert(config.options.sync.push_on_save == true, 'push_on_save still default')
end)

test('save_path default is nil', function()
    local config = reload_config()
    assert(config.options.save_path == nil, 'save_path nil by default')
end)

test('save_path can be set explicitly', function()
    local config = reload_config({ save_path = '/tmp/my_todos.json' })
    assert(config.options.save_path == '/tmp/my_todos.json')
end)

test('env defaults are set', function()
    local config = reload_config()
    assert(config.options.env.client_id == 'DOOING_GDRIVE_CLIENT_ID')
    assert(config.options.env.client_secret == 'DOOING_GDRIVE_CLIENT_SECRET')
    assert(config.options.env.refresh_token == 'DOOING_GDRIVE_REFRESH_TOKEN')
end)

-------------------------------------------------------------------------------
puts('')
puts('config.resolve_save_path()')
-------------------------------------------------------------------------------

test('returns explicit save_path when set', function()
    local config = reload_config({ save_path = '/tmp/explicit.json' })
    assert(config.resolve_save_path() == '/tmp/explicit.json')
end)

test('expands ~ in explicit save_path', function()
    local config = reload_config({ save_path = '~/todos.json' })
    local resolved = config.resolve_save_path()
    assert(not resolved:match('^~'), 'tilde expanded: ' .. resolved)
    assert(resolved:match('todos%.json$'), 'filename preserved: ' .. resolved)
end)

test('falls back to stdpath when no explicit path and dooing not loaded', function()
    -- Ensure dooing.config is NOT loadable for this test.
    local saved = package.loaded['dooing.config']
    package.loaded['dooing.config'] = nil
    -- Temporarily break require for dooing.config.
    package.preload['dooing.config'] = function() error('not available') end

    local config = reload_config()
    local resolved = config.resolve_save_path()
    assert(resolved:match('dooing_todos%.json$'), 'fallback path: ' .. resolved)

    package.preload['dooing.config'] = nil
    package.loaded['dooing.config'] = saved
end)

-------------------------------------------------------------------------------
puts('')
puts('config.has_credentials()')
-------------------------------------------------------------------------------

test('returns false when env vars are missing', function()
    local config = reload_config({
        env = {
            client_id     = 'DOOING_TEST_MISSING_1_' .. os.time(),
            client_secret = 'DOOING_TEST_MISSING_2_' .. os.time(),
            refresh_token = 'DOOING_TEST_MISSING_3_' .. os.time(),
        },
    })
    local ok, missing = config.has_credentials()
    assert(ok == false, 'should be false')
    assert(missing ~= nil, 'should report missing var')
end)

test('returns true when all env vars are set', function()
    local ts = tostring(os.time())
    local vars = {
        client_id     = 'DOOING_TEST_CID_' .. ts,
        client_secret = 'DOOING_TEST_SEC_' .. ts,
        refresh_token = 'DOOING_TEST_REF_' .. ts,
    }
    -- Set temporary env vars.
    vim.env[vars.client_id]     = 'test_value'
    vim.env[vars.client_secret] = 'test_value'
    vim.env[vars.refresh_token] = 'test_value'

    local config = reload_config({ env = vars })
    local ok, missing = config.has_credentials()
    assert(ok == true, 'should be true')
    assert(missing == nil, 'no missing var')

    -- Clean up.
    vim.env[vars.client_id]     = nil
    vim.env[vars.client_secret] = nil
    vim.env[vars.refresh_token] = nil
end)

test('returns false when env var is empty string', function()
    local var = 'DOOING_TEST_EMPTY_' .. os.time()
    vim.env[var] = ''
    local config = reload_config({
        env = { client_id = var, client_secret = var, refresh_token = var },
    })
    local ok, _ = config.has_credentials()
    assert(ok == false, 'empty string is not valid')
    vim.env[var] = nil
end)

-------------------------------------------------------------------------------
puts('')
puts('config.log()')
-------------------------------------------------------------------------------

test('debug messages suppressed when debug=false', function()
    local config = reload_config({ debug = false })
    -- This should not error or produce output; just a smoke test.
    config.log('test debug message', vim.log.levels.DEBUG)
end)

test('info messages always go through', function()
    local config = reload_config({ debug = false })
    -- Smoke test — would call vim.notify internally.
    config.log('test info message', vim.log.levels.INFO)
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
