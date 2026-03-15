--- dooing-sync.nvim — Google Drive sync for dooing.
--- Entry point: setup(), public API, autocmds, user commands.
local M = {}

local config = require('dooing-sync.config')
local fs     = require('dooing-sync.fs')
local gdrive = require('dooing-sync.gdrive')
local merge  = require('dooing-sync.merge')

--- State
local save_path = nil       -- Resolved path to dooing's JSON file.
local sync_enabled = false  -- Whether sync is active (credentials present, setup succeeded).
local writing_local = false -- Guard: true while we are writing to save_path (suppress watcher).
local pull_timer = nil      -- Periodic pull timer handle.
local last_sync_time = nil  -- Timestamp of last successful sync.
local last_report = nil     -- Last merge report.

-------------------------------------------------------------------------------
-- Internal helpers
-------------------------------------------------------------------------------

--- Log a merge report summary.
--- @param report dooing_sync.MergeReport
local function log_report(report)
    local parts = {}
    if report.added_local > 0  then table.insert(parts, '+' .. report.added_local .. ' local') end
    if report.added_remote > 0 then table.insert(parts, '+' .. report.added_remote .. ' remote') end
    if report.deleted > 0      then table.insert(parts, '-' .. report.deleted .. ' deleted') end
    if report.modified > 0     then table.insert(parts, '~' .. report.modified .. ' modified') end
    if report.conflicts > 0    then table.insert(parts, '!' .. report.conflicts .. ' conflicts') end

    if #parts == 0 then
        config.log('Sync: no changes', vim.log.levels.DEBUG)
    else
        config.log('Sync: ' .. table.concat(parts, ', '), vim.log.levels.INFO)
    end
end

--- Reload dooing's in-memory state from disk, if dooing is loaded.
local function reload_dooing()
    local has_state, state = pcall(require, 'dooing.state')
    if has_state and state.load_todos then
        state.load_todos()
        config.log('Reloaded dooing state from disk', vim.log.levels.DEBUG)
    end
end

-------------------------------------------------------------------------------
-- Sync operations
-------------------------------------------------------------------------------

--- Perform a full sync cycle: pull → merge → write → push.
--- @param opts { blocking: boolean, on_done: fun()|nil }|nil
function M.sync(opts)
    opts = opts or {}
    if not sync_enabled then
        config.log('Sync disabled (no credentials)', vim.log.levels.DEBUG)
        if opts.on_done then opts.on_done() end
        return
    end

    config.log('Starting sync...', vim.log.levels.DEBUG)

    gdrive.pull(function(remote_content, pull_err)
        if pull_err then
            config.log('Pull failed: ' .. pull_err, vim.log.levels.WARN)
            if opts.on_done then opts.on_done() end
            return
        end

        -- Parse all three versions.
        local base_data   = fs.load_base()
        local local_data  = fs.read_json(save_path) or {}
        local remote_data = remote_content and vim.json.decode(remote_content) or nil

        if not remote_data then
            -- No remote file yet. Push local as-is.
            config.log('No remote file, pushing local data...', vim.log.levels.DEBUG)
            local content = vim.json.encode(local_data, { sort_keys = true })
            gdrive.push(content, function(ok, push_err)
                if ok then
                    fs.save_base(local_data)
                    last_sync_time = os.time()
                    config.log('Initial push complete', vim.log.levels.INFO)
                else
                    config.log('Initial push failed: ' .. (push_err or '?'), vim.log.levels.WARN)
                end
                if opts.on_done then opts.on_done() end
            end)
            return
        end

        -- Three-way merge.
        local merged, report = merge.merge(base_data, local_data, remote_data)
        last_report = report
        log_report(report)

        -- Write merged result locally if it differs from current local.
        if not report.is_noop then
            writing_local = true
            fs.write_json(save_path, merged)
            -- Schedule clearing the guard after the watcher debounce window.
            vim.defer_fn(function() writing_local = false end, 700)
            reload_dooing()
        end

        -- Always update the base snapshot.
        fs.save_base(merged)

        -- Push to Drive if merged differs from remote.
        local merged_json = vim.json.encode(merged, { sort_keys = true })
        if merged_json ~= remote_content then
            gdrive.push(merged_json, function(ok, push_err)
                if ok then
                    last_sync_time = os.time()
                    config.log('Push complete', vim.log.levels.DEBUG)
                else
                    config.log('Push failed: ' .. (push_err or '?'), vim.log.levels.WARN)
                end
                if opts.on_done then opts.on_done() end
            end)
        else
            last_sync_time = os.time()
            config.log('Remote already up-to-date, skipping push', vim.log.levels.DEBUG)
            if opts.on_done then opts.on_done() end
        end
    end)
end

--- Push the current local file to Drive (no merge, used after local saves).
--- @param on_done fun()|nil
local function push_local(on_done)
    if not sync_enabled then
        if on_done then on_done() end
        return
    end

    local local_data = fs.read_json(save_path)
    if not local_data then
        config.log('Cannot push: failed to read local file', vim.log.levels.WARN)
        if on_done then on_done() end
        return
    end

    local content = vim.json.encode(local_data, { sort_keys = true })

    gdrive.push(content, function(ok, err)
        if ok then
            fs.save_base(local_data)
            last_sync_time = os.time()
            config.log('Pushed local changes', vim.log.levels.DEBUG)
        else
            config.log('Push failed: ' .. (err or '?'), vim.log.levels.WARN)
        end
        if on_done then on_done() end
    end)
end

-------------------------------------------------------------------------------
-- File watcher callback
-------------------------------------------------------------------------------

--- Called when the dooing save_path file changes on disk.
local function on_file_changed()
    if writing_local then
        config.log('Ignoring file change (our own write)', vim.log.levels.DEBUG)
        return
    end

    if not config.options.sync.push_on_save then
        return
    end

    config.log('Detected dooing save, pushing...', vim.log.levels.DEBUG)
    push_local()
end

-------------------------------------------------------------------------------
-- Periodic pull
-------------------------------------------------------------------------------

--- Start the periodic pull timer.
local function start_pull_timer()
    local interval = config.options.sync.pull_interval
    if not interval or interval <= 0 then return end

    if pull_timer then
        pull_timer:stop()
        pull_timer:close()
    end

    pull_timer = vim.uv.new_timer()
    pull_timer:start(interval * 1000, interval * 1000, vim.schedule_wrap(function()
        config.log('Periodic pull...', vim.log.levels.DEBUG)
        M.sync()
    end))

    config.log('Periodic pull every ' .. interval .. 's', vim.log.levels.DEBUG)
end

--- Stop the periodic pull timer.
local function stop_pull_timer()
    if pull_timer then
        pull_timer:stop()
        pull_timer:close()
        pull_timer = nil
    end
end

-------------------------------------------------------------------------------
-- Autocmds
-------------------------------------------------------------------------------

local augroup = nil

local function register_autocmds()
    augroup = vim.api.nvim_create_augroup('dooing_sync', { clear = true })

    -- Final push on exit (synchronous to ensure it completes).
    vim.api.nvim_create_autocmd('VimLeavePre', {
        group = augroup,
        callback = function()
            if not sync_enabled then return end
            config.log('Final push before exit...', vim.log.levels.DEBUG)
            local done = false
            push_local(function() done = true end)
            vim.wait(10000, function() return done end, 50)
        end,
    })
end

-------------------------------------------------------------------------------
-- User commands
-------------------------------------------------------------------------------

local function register_commands()
    vim.api.nvim_create_user_command('DooingSync', function()
        config.log('Manual sync triggered', vim.log.levels.INFO)
        M.sync()
    end, { desc = 'dooing-sync: Pull from Google Drive, merge, and push' })

    vim.api.nvim_create_user_command('DooingSyncStatus', function()
        local lines = { 'dooing-sync status:' }
        table.insert(lines, '  Sync enabled: ' .. tostring(sync_enabled))
        table.insert(lines, '  Save path:    ' .. (save_path or 'nil'))
        table.insert(lines, '  Base path:    ' .. config.options.base_path)
        if last_sync_time then
            local ago = os.time() - last_sync_time
            table.insert(lines, '  Last sync:    ' .. ago .. 's ago (' .. os.date('%H:%M:%S', last_sync_time) .. ')')
        else
            table.insert(lines, '  Last sync:    never')
        end
        if last_report then
            table.insert(lines, string.format('  Last report:  +%d local, +%d remote, -%d del, ~%d mod, !%d conflicts',
                last_report.added_local, last_report.added_remote,
                last_report.deleted, last_report.modified, last_report.conflicts))
        end
        vim.notify(table.concat(lines, '\n'), vim.log.levels.INFO)
    end, { desc = 'dooing-sync: Show sync status' })
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------

--- Setup dooing-sync.
--- Call this BEFORE require'dooing'.setup() so the initial sync runs first.
--- @param opts table|nil  User configuration (see config.lua for defaults).
function M.setup(opts)
    config.setup(opts)

    -- Resolve save_path.
    save_path = config.resolve_save_path()
    config.log('Save path: ' .. save_path, vim.log.levels.DEBUG)

    -- Check credentials.
    local has_creds, missing = config.has_credentials()
    if not has_creds then
        config.log('Sync disabled: missing env var ' .. (missing or '?')
            .. '. Dooing will work normally without sync.', vim.log.levels.INFO)
        sync_enabled = false
        register_commands()
        return
    end

    sync_enabled = true

    -- Register commands and autocmds.
    register_commands()
    register_autocmds()

    -- Initial sync (blocking, so dooing loads the merged file).
    if config.options.sync.pull_on_start then
        local done = false
        M.sync({ blocking = true, on_done = function() done = true end })
        vim.wait(15000, function() return done end, 50)
        if not done then
            config.log('Initial sync timed out, continuing with local data', vim.log.levels.WARN)
        end
    end

    -- Start file watcher.
    if config.options.sync.push_on_save then
        fs.watch(save_path, on_file_changed)
    end

    -- Start periodic pull timer.
    start_pull_timer()

    config.log('Ready', vim.log.levels.DEBUG)
end

--- Teardown (for testing or plugin unload).
function M.teardown()
    fs.unwatch()
    stop_pull_timer()
    if augroup then
        vim.api.nvim_del_augroup_by_id(augroup)
        augroup = nil
    end
    pcall(vim.api.nvim_del_user_command, 'DooingSync')
    pcall(vim.api.nvim_del_user_command, 'DooingSyncStatus')
    sync_enabled = false
    last_sync_time = nil
    last_report = nil
    save_path = nil
end

--- Get sync status (for statusline integration, etc.).
--- @return { enabled: boolean, last_sync: integer|nil, last_report: dooing_sync.MergeReport|nil }
function M.status()
    return {
        enabled = sync_enabled,
        last_sync = last_sync_time,
        last_report = last_report,
    }
end

return M
