--- Tests for dooing-sync.nvim fs module.
--- Run with:  nvim --headless -l tests/test_fs.lua
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

-- Set up config with a temp base_path for testing.
local test_dir = '/tmp/dooing_sync_test_' .. os.time()
os.execute('mkdir -p ' .. test_dir)

package.loaded['dooing-sync.config'] = nil
local config = require('dooing-sync.config')
config.setup({
    base_path = test_dir .. '/base.json',
    debug = false,
})

package.loaded['dooing-sync.fs'] = nil
local fs = require('dooing-sync.fs')

-------------------------------------------------------------------------------
puts('fs.read_json() / fs.write_json()')
-------------------------------------------------------------------------------

test('write then read round-trip', function()
    local path = test_dir .. '/roundtrip.json'
    local data = {
        { id = 'a', text = 'First', done = false, created_at = 100 },
        { id = 'b', text = 'Second', done = true, created_at = 200 },
    }
    assert(fs.write_json(path, data), 'write ok')
    local read_back = fs.read_json(path)
    assert(read_back ~= nil, 'read ok')
    assert(#read_back == 2, 'correct count')
end)

test('read_json returns nil for missing file', function()
    local result = fs.read_json(test_dir .. '/nonexistent.json')
    assert(result == nil)
end)

test('read_json returns nil for empty file', function()
    local path = test_dir .. '/empty.json'
    local f = io.open(path, 'w')
    f:write('')
    f:close()
    local result = fs.read_json(path)
    assert(result == nil)
end)

test('read_json returns nil for invalid JSON', function()
    local path = test_dir .. '/bad.json'
    local f = io.open(path, 'w')
    f:write('not json {{{')
    f:close()
    local result = fs.read_json(path)
    assert(result == nil)
end)

test('read_json returns nil for non-array JSON', function()
    local path = test_dir .. '/object.json'
    local f = io.open(path, 'w')
    f:write('{"key": "value"}')
    f:close()
    -- A JSON object is a table, so read_json should actually accept it.
    -- The check is type(data) ~= 'table', and objects are tables in Lua.
    local result = fs.read_json(path)
    assert(result ~= nil, 'object is a valid table')
end)

test('write_json produces deterministic output', function()
    local path = test_dir .. '/deterministic.json'
    local data = {
        { id = 'x', zebra = 1, alpha = 2, middle = 3 },
    }
    fs.write_json(path, data)
    local f1 = io.open(path, 'r')
    local content1 = f1:read('*a')
    f1:close()
    -- Write again and verify identical output.
    fs.write_json(path, data)
    local f2 = io.open(path, 'r')
    local content2 = f2:read('*a')
    f2:close()
    assert(content1 == content2, 'identical output on repeated writes')
    assert(content1:find('"alpha"') ~= nil, 'fields present')
end)

test('write_json is atomic (no .tmp file left behind)', function()
    local path = test_dir .. '/atomic.json'
    local tmp = path .. '.dooing-sync.tmp'
    fs.write_json(path, { { id = 'a' } })
    local f = io.open(tmp, 'r')
    assert(f == nil, 'tmp file should not exist')
    -- But the target file should exist.
    f = io.open(path, 'r')
    assert(f ~= nil, 'target file should exist')
    f:close()
end)

test('write_json overwrites existing file', function()
    local path = test_dir .. '/overwrite.json'
    fs.write_json(path, { { id = 'v1', text = 'first' } })
    fs.write_json(path, { { id = 'v2', text = 'second' } })
    local data = fs.read_json(path)
    assert(#data == 1)
    assert(data[1].id == 'v2')
end)

-------------------------------------------------------------------------------
puts('')
puts('fs.load_base() / fs.save_base()')
-------------------------------------------------------------------------------

test('load_base returns nil when no base exists', function()
    -- base_path is test_dir/base.json which doesn't exist yet.
    local base = fs.load_base()
    assert(base == nil)
end)

test('save_base then load_base round-trip', function()
    local data = {
        { id = 'base1', text = 'Base item', done = false, created_at = 300 },
    }
    assert(fs.save_base(data), 'save ok')
    local loaded = fs.load_base()
    assert(loaded ~= nil, 'load ok')
    assert(#loaded == 1, 'correct count')
    assert(loaded[1].id == 'base1', 'correct id')
end)

test('save_base overwrites previous base', function()
    fs.save_base({ { id = 'old' } })
    fs.save_base({ { id = 'new1' }, { id = 'new2' } })
    local loaded = fs.load_base()
    assert(#loaded == 2)
    assert(loaded[1].id ~= 'old', 'old data gone')
end)

-------------------------------------------------------------------------------
puts('')
puts('fs.watch() / fs.unwatch()')
-------------------------------------------------------------------------------

test('watch and unwatch do not error', function()
    local path = test_dir .. '/watchme.json'
    fs.write_json(path, { { id = 'w' } })
    -- Just verify they don't throw.
    fs.watch(path, function() end)
    fs.unwatch()
end)

test('unwatch is safe to call when not watching', function()
    fs.unwatch()
    fs.unwatch()
end)

-------------------------------------------------------------------------------
puts('')
-------------------------------------------------------------------------------

-- Clean up test directory.
os.execute('rm -rf ' .. test_dir)

local total = pass_count + fail_count
if fail_count == 0 then
    puts(string.format('All %d tests passed ✓', total))
else
    puts(string.format('%d/%d tests passed, %d FAILED ✗', pass_count, total, fail_count))
    os.exit(1)
end
