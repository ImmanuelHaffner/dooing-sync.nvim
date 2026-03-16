--- dooing-sync.nvim filesystem module.
--- Base snapshot management, JSON I/O, and file watching.
local M = {}

local config = require('dooing-sync.config')

-- Active file watcher handle and debounce timer.
local fs_event = nil
local debounce_timer = nil
local DEBOUNCE_MS = 500

-------------------------------------------------------------------------------
-- JSON I/O
-------------------------------------------------------------------------------

--- Read and parse a JSON file.
--- @param path string
--- @return table|nil  Parsed array of todos, or nil on error/missing file.
function M.read_json(path)
    local file = io.open(path, 'r')
    if not file then
        return nil
    end
    local content = file:read('*a')
    file:close()
    if not content or content == '' then
        return nil
    end
    local ok, data = pcall(vim.json.decode, content)
    if not ok then
        config.log('Failed to parse JSON from ' .. path, vim.log.levels.ERROR)
        return nil
    end
    if type(data) ~= 'table' then
        config.log('JSON root is not an array in ' .. path, vim.log.levels.ERROR)
        return nil
    end
    return data
end

--- Serialize and write JSON to a file atomically.
--- Writes to a temporary file first, then renames to avoid partial reads.
--- @param path string
--- @param data table
--- @return boolean ok
function M.write_json(path, data)
    local json_str = vim.json.encode(data)
    local tmp_path = path .. '.dooing-sync.tmp'
    local file = io.open(tmp_path, 'w')
    if not file then
        config.log('Failed to open for writing: ' .. tmp_path, vim.log.levels.ERROR)
        return false
    end
    file:write(json_str)
    file:close()
    local ok, err = os.rename(tmp_path, path)
    if not ok then
        config.log('Failed to rename tmp file: ' .. tostring(err), vim.log.levels.ERROR)
        os.remove(tmp_path)
        return false
    end
    return true
end

-------------------------------------------------------------------------------
-- Base Snapshot
-------------------------------------------------------------------------------

--- Load the base snapshot (last successfully synced version).
--- @return table|nil  Parsed todos array, or nil if no base exists.
function M.load_base()
    return M.read_json(config.options.base_path)
end

--- Save a new base snapshot.
--- @param data table
--- @return boolean
function M.save_base(data)
    return M.write_json(config.options.base_path, data)
end

-------------------------------------------------------------------------------
-- File Locking
-------------------------------------------------------------------------------

local lock_held = false

--- Derive the lock file path from the configured base_path.
--- @return string
local function lock_path()
    return config.options.base_path .. '.lock'
end

--- Check if a process is alive by sending signal 0.
--- @param pid integer
--- @return boolean
local function process_alive(pid)
    if not pid or pid <= 0 then return false end
    -- signal 0 is a no-op that checks process existence.
    -- Returns: 0 on success, or nil + err_msg + err_name on failure.
    local ok, ret, _, err_name = pcall(vim.uv.kill, pid, 0)
    if not ok then return false end       -- pcall itself failed
    if ret == 0 then return true end      -- success: process exists
    -- ESRCH = no such process. EPERM = exists but no permission (e.g. PID 1).
    return err_name ~= 'ESRCH'
end

--- Read the PID stored in a lockfile.
--- @param path string
--- @return integer|nil
local function read_pid(path)
    local fd = vim.uv.fs_open(path, 'r', 420) -- 0644
    if not fd then return nil end
    local data = vim.uv.fs_read(fd, 64, 0)
    vim.uv.fs_close(fd)
    if not data then return nil end
    return tonumber(data:match('%d+'))
end

--- Acquire the sync lock. Blocks (with polling) until acquired or timeout.
---
--- Uses O_CREAT|O_EXCL via vim.uv.fs_open() for atomic creation.
--- Writes the current PID into the lockfile for stale-lock detection.
---
--- @param timeout_ms integer|nil  Maximum time to wait (default from config).
--- @return boolean acquired
function M.lock(timeout_ms)
    if lock_held then
        config.log('BUG: lock() called while already holding lock', vim.log.levels.ERROR)
        return true -- Avoid deadlock.
    end

    timeout_ms = timeout_ms or config.options.lock_timeout_ms
    if timeout_ms <= 0 then
        -- Locking disabled.
        lock_held = true
        return true
    end

    local lpath = lock_path()
    local my_pid = vim.uv.os_getpid()
    local deadline = vim.uv.hrtime() + timeout_ms * 1e6

    while vim.uv.hrtime() < deadline do
        local fd, _, err_name = vim.uv.fs_open(lpath, 'wx', 420) -- O_WRONLY|O_CREAT|O_EXCL, 0644

        if fd then
            vim.uv.fs_write(fd, tostring(my_pid))
            vim.uv.fs_close(fd)
            lock_held = true
            config.log('Lock acquired (PID ' .. my_pid .. ')', vim.log.levels.DEBUG)
            return true
        end

        -- Lockfile exists. Check if the owner is still alive.
        local owner_pid = read_pid(lpath)
        if owner_pid and owner_pid == my_pid then
            -- We already own it (e.g. leftover from a previous crash in the same PID).
            lock_held = true
            config.log('Reacquired own lock (PID ' .. my_pid .. ')', vim.log.levels.DEBUG)
            return true
        elseif owner_pid and not process_alive(owner_pid) then
            config.log('Removing stale lock from PID ' .. owner_pid, vim.log.levels.WARN)
            vim.uv.fs_unlink(lpath)
            -- Retry immediately without sleeping.
        else
            -- Lock held by a live process. Wait and retry.
            vim.wait(100, function() return false end)
        end
    end

    config.log('Failed to acquire sync lock after ' .. timeout_ms .. 'ms', vim.log.levels.WARN)
    return false
end

--- Release the sync lock.
---
--- Verifies ownership (PID matches) before removing the lockfile.
---
--- @return boolean released
function M.unlock()
    if not lock_held then
        return false
    end

    local lpath = lock_path()
    local my_pid = vim.uv.os_getpid()
    local owner_pid = read_pid(lpath)

    if owner_pid and owner_pid ~= my_pid then
        config.log(
            'Lock not owned by us (owner: ' .. owner_pid .. ', us: ' .. my_pid .. ')',
            vim.log.levels.WARN
        )
        lock_held = false
        return false
    end

    vim.uv.fs_unlink(lpath)
    lock_held = false
    config.log('Lock released (PID ' .. my_pid .. ')', vim.log.levels.DEBUG)
    return true
end

--- Expose internals for testing.
--- @private
M._testing = {
    process_alive = process_alive,
    read_pid = read_pid,
    lock_path = lock_path,
    --- Reset the lock_held state (for tests only).
    reset_lock_state = function() lock_held = false end,
    --- Get the lock_held state (for tests only).
    is_lock_held = function() return lock_held end,
}

-------------------------------------------------------------------------------
-- File Watching
-------------------------------------------------------------------------------

--- Start watching a file for changes.
--- The callback is debounced so rapid successive writes only trigger once.
--- @param path string       File path to watch.
--- @param callback function Called (with no args) when the file changes.
function M.watch(path, callback)
    M.unwatch()

    fs_event = vim.uv.new_fs_event()
    if not fs_event then
        config.log('Failed to create fs_event watcher', vim.log.levels.WARN)
        return
    end

    fs_event:start(path, {}, function(err, _, _)
        if err then
            config.log('fs_event error: ' .. tostring(err), vim.log.levels.WARN)
            return
        end
        -- Debounce: reset timer on each event.
        if debounce_timer then
            debounce_timer:stop()
        end
        debounce_timer = vim.uv.new_timer()
        debounce_timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(function()
            debounce_timer:stop()
            debounce_timer:close()
            debounce_timer = nil
            callback()
        end))
    end)

    config.log('Watching ' .. path, vim.log.levels.DEBUG)
end

--- Stop the active file watcher, if any.
function M.unwatch()
    if debounce_timer then
        debounce_timer:stop()
        debounce_timer:close()
        debounce_timer = nil
    end
    if fs_event then
        fs_event:stop()
        fs_event:close()
        fs_event = nil
    end
end

return M
