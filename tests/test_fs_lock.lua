--- Tests for dooing-sync.nvim fs locking primitives.
--- Run with:  nvim --headless -l tests/test_fs_lock.lua
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
local test_dir = '/tmp/dooing_sync_lock_test_' .. os.time()
os.execute('mkdir -p ' .. test_dir)

package.loaded['dooing-sync.config'] = nil
local config = require('dooing-sync.config')
config.setup({
    base_path = test_dir .. '/base.json',
    lock_timeout_ms = 2000,
    debug = false,
})

package.loaded['dooing-sync.fs'] = nil
local fs = require('dooing-sync.fs')

--- Helper: clean up lockfile and reset state between tests.
local function reset()
    pcall(function() os.remove(test_dir .. '/base.json.lock') end)
    fs._testing.reset_lock_state()
end

-------------------------------------------------------------------------------
puts('process_alive()')
-------------------------------------------------------------------------------

test('process_alive returns true for our own PID', function()
    local my_pid = vim.uv.os_getpid()
    assert(fs._testing.process_alive(my_pid) == true, 'own PID should be alive')
end)

test('process_alive returns false for a dead PID', function()
    -- PID 99999999 is almost certainly not running.
    assert(fs._testing.process_alive(99999999) == false, 'dead PID should not be alive')
end)

test('process_alive returns false for nil', function()
    assert(fs._testing.process_alive(nil) == false)
end)

test('process_alive returns false for 0', function()
    assert(fs._testing.process_alive(0) == false)
end)

test('process_alive returns false for negative PID', function()
    assert(fs._testing.process_alive(-1) == false)
end)

-------------------------------------------------------------------------------
puts('')
puts('read_pid()')
-------------------------------------------------------------------------------

test('read_pid reads PID from file', function()
    local path = test_dir .. '/pid_test.lock'
    local f = io.open(path, 'w')
    f:write('12345')
    f:close()
    assert(fs._testing.read_pid(path) == 12345, 'should read PID')
    os.remove(path)
end)

test('read_pid returns nil for missing file', function()
    assert(fs._testing.read_pid(test_dir .. '/no_such.lock') == nil)
end)

test('read_pid returns nil for file with non-numeric content', function()
    local path = test_dir .. '/bad_pid.lock'
    local f = io.open(path, 'w')
    f:write('not-a-pid')
    f:close()
    assert(fs._testing.read_pid(path) == nil, 'non-numeric should be nil')
    os.remove(path)
end)

-------------------------------------------------------------------------------
puts('')
puts('lock() / unlock()')
-------------------------------------------------------------------------------

test('L1: lock and unlock round-trip', function()
    reset()
    assert(fs.lock(2000) == true, 'should acquire lock')
    assert(fs._testing.is_lock_held() == true, 'lock_held should be true')
    -- Lockfile should exist.
    local f = io.open(fs._testing.lock_path(), 'r')
    assert(f ~= nil, 'lockfile should exist')
    f:close()
    -- Unlock.
    assert(fs.unlock() == true, 'should release lock')
    assert(fs._testing.is_lock_held() == false, 'lock_held should be false')
    -- Lockfile should be gone.
    f = io.open(fs._testing.lock_path(), 'r')
    assert(f == nil, 'lockfile should be removed')
end)

test('L2: lock writes our PID', function()
    reset()
    fs.lock(2000)
    local pid = fs._testing.read_pid(fs._testing.lock_path())
    assert(pid == vim.uv.os_getpid(), 'lockfile should contain our PID')
    fs.unlock()
end)

test('L3: stale lock from dead PID is removed and acquired', function()
    reset()
    -- Create a lockfile with a dead PID.
    local lpath = fs._testing.lock_path()
    local f = io.open(lpath, 'w')
    f:write('99999999') -- almost certainly dead
    f:close()
    -- Should succeed by detecting stale lock.
    assert(fs.lock(2000) == true, 'should acquire after removing stale lock')
    local pid = fs._testing.read_pid(lpath)
    assert(pid == vim.uv.os_getpid(), 'should now contain our PID')
    fs.unlock()
end)

test('L4: lock times out when held by a live process', function()
    reset()
    -- Create a lockfile with our own PID but pretend we don't hold it
    -- by using a different live PID (PID 1 = launchd/init, always alive).
    local lpath = fs._testing.lock_path()
    local f = io.open(lpath, 'w')
    f:write('1') -- PID 1 is always alive
    f:close()
    -- Try to acquire with a short timeout.
    local start = vim.uv.hrtime()
    local acquired = fs.lock(300) -- 300ms timeout
    local elapsed_ms = (vim.uv.hrtime() - start) / 1e6
    assert(acquired == false, 'should fail to acquire')
    assert(elapsed_ms >= 250, 'should have waited near the timeout')
    -- Clean up.
    os.remove(lpath)
end)

test('L5: unlock verifies PID ownership', function()
    reset()
    -- Create a lockfile owned by a different PID.
    local lpath = fs._testing.lock_path()
    local f = io.open(lpath, 'w')
    f:write('1') -- PID 1
    f:close()
    -- Pretend we think we hold the lock.
    fs._testing.reset_lock_state()
    -- We need lock_held = true for unlock to proceed past the guard.
    -- Manually set it via acquiring a lock with timeout 0 (disabled locking).
    local saved_timeout = config.options.lock_timeout_ms
    config.options.lock_timeout_ms = 0
    fs.lock()
    config.options.lock_timeout_ms = saved_timeout
    -- Now try to unlock — should fail because PID doesn't match.
    local released = fs.unlock()
    assert(released == false, 'should refuse to release lock we do not own')
    -- Lockfile should still exist.
    f = io.open(lpath, 'r')
    assert(f ~= nil, 'lockfile should still exist')
    f:close()
    -- Clean up.
    os.remove(lpath)
end)

test('L6: reentrancy guard returns true without deadlocking', function()
    reset()
    assert(fs.lock(2000) == true, 'first lock should succeed')
    -- Second lock while held should return true (reentrancy guard).
    assert(fs.lock(2000) == true, 'reentrant lock should return true')
    -- Should still be able to unlock.
    assert(fs.unlock() == true, 'unlock should succeed')
end)

test('L7: lock + write_json works correctly under lock', function()
    reset()
    assert(fs.lock(2000) == true)
    local path = test_dir .. '/locked_write.json'
    local data = { { id = 'locked', text = 'Written under lock' } }
    assert(fs.write_json(path, data) == true, 'write should succeed under lock')
    local read_back = fs.read_json(path)
    assert(read_back ~= nil, 'read should succeed under lock')
    assert(read_back[1].id == 'locked')
    fs.unlock()
end)

test('unlock returns false when not held', function()
    reset()
    assert(fs.unlock() == false, 'unlock without lock should return false')
end)

test('lock with timeout_ms=0 disables locking', function()
    reset()
    assert(fs.lock(0) == true, 'should succeed immediately')
    assert(fs._testing.is_lock_held() == true)
    -- No lockfile should be created.
    local f = io.open(fs._testing.lock_path(), 'r')
    assert(f == nil, 'no lockfile when locking disabled')
    fs.unlock()
end)

test('lock reacquires own lockfile (leftover from same PID)', function()
    reset()
    -- Simulate a leftover lockfile from the same PID (e.g. crash without unlock).
    local lpath = fs._testing.lock_path()
    local f = io.open(lpath, 'w')
    f:write(tostring(vim.uv.os_getpid()))
    f:close()
    -- Should succeed because the PID matches ours.
    assert(fs.lock(2000) == true, 'should reacquire own lock')
    fs.unlock()
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
