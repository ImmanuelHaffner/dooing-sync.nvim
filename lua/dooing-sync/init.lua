--- dooing-sync.nvim — Google Drive sync for dooing.
--- Entry point: setup(), public API, autocmds, user commands.
local M = {}

local config = require('dooing-sync.config')
local fs     = require('dooing-sync.fs')
local gdrive = require('dooing-sync.gdrive')
local merge  = require('dooing-sync.merge')

--- State
local save_path = nil           -- Resolved path to dooing's JSON file.
local sync_enabled = false      -- Whether sync is active (credentials present, setup succeeded).
local writing_local = false     -- Guard: true while we are writing to save_path (suppress watcher).
local sync_in_progress = false  -- Guard: true while a sync cycle is running (prevents reentrant syncs).
local pull_timer = nil          -- Periodic pull timer handle.
local last_sync_time = nil      -- Timestamp of last successful sync.
local last_report = nil         -- Last merge report.

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
        config.log('Sync: no changes', vim.log.levels.INFO, { routine = true })
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

--- Perform a full sync cycle: lock → pull → merge → write → push → unlock.
---
--- The entire cycle is protected by a local file lock (serializes access across
--- sessions on the same machine) and ETag-based conditional push (prevents lost
--- updates across machines).
---
--- @param opts { blocking: boolean, on_done: fun()|nil, _retry_count: integer|nil }|nil
function M.sync(opts)
    opts = opts or {}
    local retry_count = opts._retry_count or 0

    if not sync_enabled then
        config.log('Sync disabled (no credentials)', vim.log.levels.DEBUG)
        if opts.on_done then opts.on_done() end
        return
    end

    -- Prevent reentrant syncs (e.g. file watcher firing during an ongoing sync).
    if sync_in_progress then
        config.log('Sync already in progress, skipping', vim.log.levels.DEBUG)
        if opts.on_done then opts.on_done() end
        return
    end

    --- The core sync body, called once the lock is acquired.
    --- sync_in_progress is already true at this point (set eagerly above).
    local function do_sync()
        --- Release lock, clear in-progress flag, and call on_done.
        --- Every exit path from this point MUST call finish().
        local function finish()
            sync_in_progress = false
            fs.unlock()
            if opts.on_done then opts.on_done() end
        end

        -- Guard: teardown() may have run while we waited for the async lock.
        if not sync_enabled or not save_path then
            finish()
            return
        end

        config.log('Starting sync'
            .. (retry_count > 0 and (' (retry ' .. retry_count .. ')') or '')
            .. '...', vim.log.levels.DEBUG)

        -- Read local state under lock (before network I/O).
        local base_data  = fs.load_base()
        local local_data = fs.read_json(save_path) or {}

        gdrive.pull(function(remote_content, etag, pull_err)
        if pull_err then
            config.log('Pull failed: ' .. pull_err, vim.log.levels.WARN)
            finish()
            return
        end

        local remote_data = remote_content and vim.json.decode(remote_content) or nil

        if not remote_data then
            -- No remote file yet. Push local as-is (no ETag needed).
            config.log('No remote file, pushing local data...', vim.log.levels.DEBUG)
            local content = vim.json.encode(local_data)
            gdrive.push(content, function(ok, push_err)
                if ok then
                    fs.save_base(local_data)
                    last_sync_time = os.time()
                    config.log('Initial push complete', vim.log.levels.INFO, { routine = true })
                else
                    config.log('Initial push failed: ' .. (push_err or '?'), vim.log.levels.WARN)
                end
                finish()
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


        -- Push to Drive if merged differs from remote (conditional on ETag).
        -- Use the merge module's deterministic serializer so key ordering
        -- and vim.NIL differences don't cause false positives.
        local merged_json = vim.json.encode(merged)
        local merged_stable = merge.stable_encode(merged)
        local remote_stable = merge.stable_encode(remote_data)
        if merged_stable ~= remote_stable then
            gdrive.push(merged_json, etag, function(ok, push_err)
                if ok then
                    -- Push succeeded: state is consistent, update base snapshot.
                    fs.save_base(merged)
                    last_sync_time = os.time()
                    config.log('Push complete', vim.log.levels.DEBUG)
                    finish()
                elseif push_err == 'etag_mismatch'
                    and retry_count < config.options.max_retries then
                    -- Remote changed since we pulled. Retry with fresh data.
                    config.log(
                        'Remote changed during sync (ETag mismatch), retrying...',
                        vim.log.levels.INFO)
                    -- Release lock before retry so other sessions get a chance.
                    sync_in_progress = false
                    fs.unlock()
                    M.sync({
                        blocking = opts.blocking,
                        on_done = opts.on_done,
                        _retry_count = retry_count + 1,
                    })
                else
                    if push_err == 'etag_mismatch' then
                        config.log('ETag mismatch after '
                            .. config.options.max_retries
                            .. ' retries, giving up', vim.log.levels.WARN)
                    else
                        config.log('Push failed: '
                            .. (push_err or '?'), vim.log.levels.WARN)
                    end
                    finish()
                end
            end)
        else
            -- Remote already up-to-date: no push needed, save base.
            fs.save_base(merged)
            last_sync_time = os.time()
            config.log('Remote already up-to-date, skipping push', vim.log.levels.DEBUG)
            finish()
        end
        end)
    end

    -- Mark in-progress eagerly so a second M.sync() call before the async lock
    -- callback fires is correctly rejected by the guard at the top.
    sync_in_progress = true

    -- Acquire local lock (serializes with other Neovim sessions on this machine).
    if opts.blocking then
        -- Blocking lock — used by VimLeavePre where we must finish before exit.
        if not fs.lock() then
            sync_in_progress = false
            config.log('Could not acquire sync lock, skipping', vim.log.levels.WARN)
            if opts.on_done then opts.on_done() end
            return
        end
        do_sync()
    else
        -- Async lock — never blocks the main thread.
        fs.lock_async(nil, function(acquired)
            if not acquired then
                sync_in_progress = false
                config.log('Could not acquire sync lock, skipping', vim.log.levels.WARN)
                if opts.on_done then opts.on_done() end
                return
            end
            do_sync()
        end)
    end
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

    config.log('Detected dooing save, syncing...', vim.log.levels.DEBUG)
    M.sync()
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

--- Check whether a UI is attached.
--- @return boolean
local function has_ui()
    return #vim.api.nvim_list_uis() > 0
end

--- Start the sync engine: initial sync, file watcher, periodic timer.
--- Called when a UI attaches (UIEnter) or immediately if UI is already present.
local function start_sync_engine()
    if not sync_enabled then return end

    -- Initial async sync (non-blocking: dooing keeps local data, refreshes on completion).
    if config.options.sync.sync_on_open then
        config.log('Starting background sync...', vim.log.levels.DEBUG)
        M.sync()
    end

    -- Start file watcher.
    if config.options.sync.push_on_save then
        fs.watch(save_path, on_file_changed)
    end

    -- Start periodic pull timer.
    start_pull_timer()

    config.log('Ready', vim.log.levels.DEBUG)
end

local function register_autocmds()
    augroup = vim.api.nvim_create_augroup('dooing_sync', { clear = true })

    -- Final sync on exit (short blocking wait to flush pending changes).
    if config.options.sync.sync_on_close then
        vim.api.nvim_create_autocmd('VimLeavePre', {
            group = augroup,
            callback = function()
                if not sync_enabled or not has_ui() then return end
                config.log('Final sync before exit...', vim.log.levels.DEBUG)
                local done = false
                M.sync({ blocking = true, on_done = function() done = true end })
                local timeout = config.options.sync.sync_on_close_timeout_ms or 3000
                vim.wait(timeout, function() return done end, 50)
            end,
        })
    end

    -- Defer sync engine start until a UI attaches (skips headless mode).
    if not has_ui() then
        vim.api.nvim_create_autocmd('UIEnter', {
            group = augroup,
            once = true,
            callback = function()
                config.log('UI attached, starting sync engine', vim.log.levels.DEBUG)
                start_sync_engine()
            end,
        })
    end
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
--- Can be called before or after dooing.setup() — order no longer matters because
--- the initial sync is async and dooing is reloaded when the sync completes.
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

    -- Register commands and autocmds (including UIEnter if no UI yet).
    register_commands()
    register_autocmds()

    -- If a UI is already attached (normal startup), start immediately.
    -- Otherwise UIEnter autocmd (registered above) will start the engine.
    if has_ui() then
        start_sync_engine()
    end
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
    sync_in_progress = false
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
