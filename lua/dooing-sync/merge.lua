--- dooing-sync.nvim three-way merge engine.
--- Pure functions, no I/O, no side effects.
local M = {}

local config = require('dooing-sync.config')

--- All known per-item fields (excluding `id`, which is the merge key).
local FIELDS = {
    'text', 'done', 'in_progress', 'category', 'created_at',
    'completed_at', 'priorities', 'estimated_hours', 'notes',
    'parent_id', 'depth', 'due_at',
}

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

--- Deep-compare two values (handles nil, primitives, and tables).
--- @param a any
--- @param b any
--- @return boolean
local function equal(a, b)
    if a == nil and b == nil then return true end
    if a == nil or b == nil then return false end
    if type(a) ~= type(b) then return false end
    if type(a) ~= 'table' then return a == b end
    return vim.deep_equal(a, b)
end

--- Serialize a todo item deterministically for whole-item comparison.
--- @param item table|nil
--- @return string|nil
local function serialize(item)
    if item == nil then return nil end
    return vim.json.encode(item, { sort_keys = true })
end

--- Build an id-keyed map from a list of todos.
--- @param todos table|nil  Array of todo items.
--- @return table<string, table>  Map from id → todo item.
local function id_map(todos)
    local map = {}
    if not todos then return map end
    for _, item in ipairs(todos) do
        if item.id then
            map[item.id] = item
        end
    end
    return map
end

--- Collect the union of keys from up to three maps.
--- @return table<string, boolean>
local function union_keys(...)
    local keys = {}
    for _, map in ipairs({...}) do
        for k, _ in pairs(map) do
            keys[k] = true
        end
    end
    return keys
end

-------------------------------------------------------------------------------
-- Field-level merge
-------------------------------------------------------------------------------

--- Resolve a single field conflict where base, local, and remote all differ.
--- @param field string         Field name (for logging).
--- @param base_val any
--- @param local_val any
--- @param remote_val any
--- @param local_item table     Full local item (for heuristics).
--- @param remote_item table    Full remote item (for heuristics).
--- @return any resolved_value
--- @return boolean was_conflict  True if this was a true conflict.
local function resolve_field_conflict(field, base_val, local_val, remote_val, local_item, remote_item)
    local strategy = config.options.conflict_strategy

    if strategy == 'local' then
        return local_val, true
    elseif strategy == 'remote' then
        return remote_val, true
    elseif strategy == 'recent' then
        -- Prefer the item that was modified more recently.
        -- Use completed_at (if available), then created_at as a tiebreaker.
        local local_time = local_item.completed_at or local_item.created_at or 0
        local remote_time = remote_item.completed_at or remote_item.created_at or 0
        if remote_time > local_time then
            return remote_val, true
        else
            return local_val, true
        end
    else
        -- 'prompt' or unknown: default to local (prompt handled at a higher level).
        return local_val, true
    end
end

--- Merge a single todo item field-by-field.
--- @param base_item table   Item from the base snapshot.
--- @param local_item table  Item from local save_path.
--- @param remote_item table Item from Google Drive.
--- @return table merged_item
--- @return integer conflicts  Number of true field-level conflicts.
local function merge_item(base_item, local_item, remote_item)
    local merged = { id = local_item.id }
    local conflicts = 0

    for _, field in ipairs(FIELDS) do
        local base_val   = base_item[field]
        local local_val  = local_item[field]
        local remote_val = remote_item[field]

        if equal(local_val, base_val) then
            -- Local unchanged → take remote.
            merged[field] = remote_val
        elseif equal(remote_val, base_val) then
            -- Remote unchanged → take local.
            merged[field] = local_val
        elseif equal(local_val, remote_val) then
            -- Both changed the same way → take either.
            merged[field] = local_val
        else
            -- True conflict: both changed differently.
            local resolved, was_conflict = resolve_field_conflict(
                field, base_val, local_val, remote_val, local_item, remote_item
            )
            merged[field] = resolved
            if was_conflict then
                conflicts = conflicts + 1
                config.log(
                    string.format('Conflict on field "%s" of todo "%s" (id: %s)',
                        field, (local_item.text or ''):sub(1, 40), local_item.id),
                    vim.log.levels.DEBUG
                )
            end
        end
    end

    -- Preserve any extra fields we don't know about (forward compatibility).
    -- This ensures we don't silently drop fields added by future dooing versions.
    local known = { id = true }
    for _, f in ipairs(FIELDS) do known[f] = true end

    for key, val in pairs(local_item) do
        if not known[key] and merged[key] == nil then
            merged[key] = val
        end
    end
    for key, val in pairs(remote_item) do
        if not known[key] and merged[key] == nil then
            merged[key] = val
        end
    end

    return merged, conflicts
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------

--- Merge report.
--- @class dooing_sync.MergeReport
--- @field added_local integer   Items added from local.
--- @field added_remote integer  Items added from remote.
--- @field deleted integer       Items deleted.
--- @field modified integer      Items merged (changed on one or both sides).
--- @field conflicts integer     True field-level conflicts encountered.
--- @field unchanged integer     Items identical across all versions.
--- @field is_noop boolean       True if merged result equals local (no changes needed).

--- Three-way merge of dooing todo lists.
---
--- @param base table|nil   Parsed base snapshot (nil on first sync).
--- @param local_ table     Parsed local save_path.
--- @param remote table     Parsed remote (Google Drive).
--- @return table merged    Merged array of todos.
--- @return dooing_sync.MergeReport report
function M.merge(base, local_, remote)
    local base_map   = id_map(base)
    local local_map  = id_map(local_)
    local remote_map = id_map(remote)
    local all_ids    = union_keys(base_map, local_map, remote_map)

    local merged = {}
    local report = {
        added_local  = 0,
        added_remote = 0,
        deleted      = 0,
        modified     = 0,
        conflicts    = 0,
        unchanged    = 0,
        is_noop      = false,
    }

    for id, _ in pairs(all_ids) do
        local base_item   = base_map[id]
        local local_item  = local_map[id]
        local remote_item = remote_map[id]

        local base_json   = serialize(base_item)
        local local_json  = serialize(local_item)
        local remote_json = serialize(remote_item)

        if not base_item then
            -- Not in base: added on one or both sides.
            if local_item and not remote_item then
                table.insert(merged, local_item)
                report.added_local = report.added_local + 1
            elseif remote_item and not local_item then
                table.insert(merged, remote_item)
                report.added_remote = report.added_remote + 1
            else
                -- Added on both sides (same id): keep local version.
                table.insert(merged, local_item)
                report.added_local = report.added_local + 1
            end
        elseif not local_item and not remote_item then
            -- Deleted on both sides.
            report.deleted = report.deleted + 1
        elseif not local_item then
            -- Deleted locally, exists in remote.
            report.deleted = report.deleted + 1
        elseif not remote_item then
            -- Deleted remotely, exists in local.
            report.deleted = report.deleted + 1
        else
            -- Exists in all three: check for modifications.
            if local_json == remote_json then
                -- Both sides identical → keep as-is.
                table.insert(merged, local_item)
                if local_json == base_json then
                    report.unchanged = report.unchanged + 1
                else
                    report.modified = report.modified + 1
                end
            elseif local_json == base_json then
                -- Only remote changed.
                table.insert(merged, remote_item)
                report.modified = report.modified + 1
            elseif remote_json == base_json then
                -- Only local changed.
                table.insert(merged, local_item)
                report.modified = report.modified + 1
            else
                -- Both changed differently → field-level merge.
                local merged_item, conflicts = merge_item(base_item, local_item, remote_item)
                table.insert(merged, merged_item)
                report.modified = report.modified + 1
                report.conflicts = report.conflicts + conflicts
            end
        end
    end

    -- Check if the merge is a no-op (merged == local).
    -- Compare by serializing both; ordering doesn't matter because dooing sorts on load,
    -- so we compare id-keyed maps.
    local merged_map = id_map(merged)
    report.is_noop = true
    if #merged ~= #local_ then
        report.is_noop = false
    else
        for id, m_item in pairs(merged_map) do
            if serialize(m_item) ~= serialize(local_map[id]) then
                report.is_noop = false
                break
            end
        end
        -- Also check if local has items not in merged.
        if report.is_noop then
            for id, _ in pairs(local_map) do
                if not merged_map[id] then
                    report.is_noop = false
                    break
                end
            end
        end
    end

    return merged, report
end

return M
