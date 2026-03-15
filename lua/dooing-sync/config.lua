--- dooing-sync.nvim configuration module.
--- Declares defaults and merges with user options.
local M = {}

M.defaults = {
    --- Path to dooing's JSON file. If nil, auto-detected from dooing's config.
    save_path = nil,

    --- Where to store the base snapshot (last synced version).
    base_path = vim.fn.stdpath('data') .. '/dooing_sync_base.json',

    --- Google Drive file name (used to find/create the file in Drive).
    gdrive_filename = 'dooing_todos.json',

    --- Google Drive folder ID to store the file in (nil = root).
    gdrive_folder_id = nil,

    --- Environment variable names for OAuth credentials.
    env = {
        client_id     = 'DOOING_GDRIVE_CLIENT_ID',
        client_secret = 'DOOING_GDRIVE_CLIENT_SECRET',
        refresh_token = 'DOOING_GDRIVE_REFRESH_TOKEN',
    },

    --- Sync behavior.
    sync = {
        --- Pull from Google Drive on setup (before dooing loads).
        pull_on_start = true,
        --- Push to Google Drive after every dooing save.
        push_on_save = true,
        --- Periodic pull interval in seconds (0 = disabled).
        pull_interval = 300,
    },

    --- Conflict resolution for true field-level conflicts.
    --- Options: 'prompt', 'local', 'remote', 'recent'
    conflict_strategy = 'recent',

    --- Enable debug logging.
    debug = false,
}

M.options = {}

--- Resolve the dooing save_path, trying multiple sources.
--- @return string
function M.resolve_save_path()
    -- 1. Explicit user config
    if M.options.save_path then
        return vim.fn.expand(M.options.save_path)
    end
    -- 2. Read from dooing's config if loaded
    local has_dooing_config, dooing_config = pcall(require, 'dooing.config')
    if has_dooing_config and dooing_config.options and dooing_config.options.save_path then
        return vim.fn.expand(dooing_config.options.save_path)
    end
    -- 3. Default fallback
    return vim.fn.stdpath('data') .. '/dooing_todos.json'
end

--- Check whether all required OAuth credentials are present.
--- @return boolean ok
--- @return string|nil missing  Name of the first missing env var, if any.
function M.has_credentials()
    for key, var_name in pairs(M.options.env) do
        if not vim.env[var_name] or vim.env[var_name] == '' then
            return false, var_name
        end
    end
    return true, nil
end

--- Log a message at the appropriate level.
--- @param msg string
--- @param level integer  vim.log.levels.*
function M.log(msg, level)
    level = level or vim.log.levels.INFO
    if level == vim.log.levels.DEBUG and not M.options.debug then
        return
    end
    vim.notify('[dooing-sync] ' .. msg, level)
end

--- Merge user options with defaults.
--- @param opts table|nil
function M.setup(opts)
    M.options = vim.tbl_deep_extend('force', M.defaults, opts or {})
end

return M
