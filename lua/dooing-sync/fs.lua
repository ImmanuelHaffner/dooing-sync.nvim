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
    local json_str = vim.json.encode(data, { sort_keys = true })
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
