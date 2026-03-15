# dooing-sync.nvim — Implementation Plan

## Overview

A Neovim plugin that synchronizes [dooing](https://github.com/atiladefreitas/dooing) todo
lists across machines via Google Drive. Uses a three-way, field-level merge engine to handle
concurrent edits gracefully. Designed as a companion plugin to dooing, with no modifications
to dooing's data format.

---

## 1. Architecture

```
┌────────────────────────────────────────────────────────────┐
│                        Neovim                              │
│                                                            │
│  ┌──────────────┐    ┌──────────────┐   ┌──────────────┐  │
│  │  dooing.nvim  │◄───│ dooing-sync  │───►│ Google Drive │  │
│  │  (upstream)   │    │   .nvim      │   │   REST API   │  │
│  └──────┬───────┘    └──────┬───────┘   └──────────────┘  │
│         │                   │                              │
│         ▼                   ▼                              │
│   save_path JSON      base snapshot                        │
│   (dooing's file)     (last synced)                        │
└────────────────────────────────────────────────────────────┘
```

### Plugin loads as a dependency of dooing

In the user's lazy.nvim spec, `dooing-sync.nvim` is listed as a dependency of dooing.
This ensures dooing-sync loads **before** dooing. The user calls
`require'dooing-sync'.setup{}` before `require'dooing'.setup{}`.

---

## 2. File Layout

```
dooing-sync.nvim/
├── lua/
│   └── dooing-sync/
│       ├── init.lua       # setup(), public API, autocmds
│       ├── config.lua     # defaults + user config merge
│       ├── gdrive.lua     # Google Drive API: auth, upload, download
│       ├── merge.lua      # Three-way field-level merge engine
│       └── fs.lua         # Base snapshot management, file watching
├── doc/
│   └── dooing-sync.txt    # Vimdoc help file
├── PLAN.md                # This file
├── README.md              # User-facing documentation
└── LICENSE
```

---

## 3. Module Specifications

### 3.1 `config.lua`

**Purpose**: Declare defaults, merge with user options.

```lua
M.defaults = {
    -- How to locate dooing's JSON file. If nil, reads from
    -- require'dooing.config'.options.save_path after dooing is set up.
    -- Set explicitly if dooing-sync.setup() runs before dooing.setup().
    save_path = nil,

    -- Where to store the base snapshot (last synced version).
    base_path = vim.fn.stdpath('data') .. '/dooing_sync_base.json',

    -- Google Drive file name (used to find/create the file in Drive).
    gdrive_filename = 'dooing_todos.json',

    -- Google Drive folder ID to store the file in (nil = root).
    gdrive_folder_id = nil,

    -- Environment variable names for credentials (stored in ~/.secrets.zshenv).
    env = {
        client_id     = 'DOOING_GDRIVE_CLIENT_ID',
        client_secret = 'DOOING_GDRIVE_CLIENT_SECRET',
        refresh_token = 'DOOING_GDRIVE_REFRESH_TOKEN',
    },

    -- Sync behavior.
    sync = {
        -- Pull from Google Drive on setup (before dooing loads).
        pull_on_start = true,
        -- Push to Google Drive after every dooing save.
        push_on_save = true,
        -- Periodic pull interval in seconds (0 = disabled).
        -- Useful for long-running sessions to catch remote changes.
        pull_interval = 300,  -- 5 minutes
    },

    -- Conflict resolution strategy for true field-level conflicts.
    -- Options: 'prompt', 'local', 'remote', 'recent'
    conflict_strategy = 'recent',

    -- Enable debug logging via vim.notify at DEBUG level.
    debug = false,
}
```

### 3.2 `gdrive.lua`

**Purpose**: All Google Drive HTTP interactions via `vim.system()` + `curl`.

**Functions**:

| Function | Description |
|----------|-------------|
| `M.refresh_access_token(callback)` | Uses refresh token to obtain a short-lived access token. Caches in memory with expiry tracking. Calls `callback(access_token, err)`. |
| `M.find_file(access_token, filename, folder_id, callback)` | Searches Drive for a file by name (and optional parent folder). Returns file ID or nil. |
| `M.download(access_token, file_id, callback)` | Downloads file content as string. Calls `callback(content, err)`. |
| `M.upload(access_token, file_id, content, callback)` | Updates existing file content. Calls `callback(ok, err)`. |
| `M.create(access_token, filename, folder_id, content, callback)` | Creates a new file in Drive. Calls `callback(file_id, err)`. |
| `M.upload_or_create(access_token, content, callback)` | High-level: finds file, uploads if exists, creates if not. |

**Implementation notes**:
- All functions are **async** using `vim.system()` with callbacks.
- Access token cached in module-local variable with `expires_at` timestamp.
- `refresh_access_token` is called automatically if token is expired/missing.
- Credentials read from `vim.env[config.env.client_id]` etc.
- On missing credentials, `setup()` logs a warning and disables sync silently.

**Google Drive API endpoints used**:
```
POST   https://oauth2.googleapis.com/token          # refresh token → access token
GET    https://www.googleapis.com/drive/v3/files     # search by name
GET    https://www.googleapis.com/drive/v3/files/{id}?alt=media  # download
PATCH  https://www.googleapis.com/upload/drive/v3/files/{id}     # update
POST   https://www.googleapis.com/upload/drive/v3/files          # create
```

**Error handling**:
- Network errors (curl exit ≠ 0): log warning, continue offline.
- 401 Unauthorized: attempt one token refresh, retry, then give up.
- 404 Not Found on download: treat as empty remote (first sync from this machine).
- 429 Rate Limit: log warning, retry after delay (exponential backoff, max 3 retries).

### 3.3 `merge.lua`

**Purpose**: Pure-function three-way merge. No I/O, no side effects.

**Primary function**:
```lua
--- Three-way merge of dooing todo lists.
--- @param base table|nil  Parsed JSON array from base snapshot (nil on first sync)
--- @param local_ table    Parsed JSON array from local save_path
--- @param remote table    Parsed JSON array from remote (Google Drive)
--- @return table merged   Merged array of todos
--- @return table report   { added = n, deleted = n, modified = n, conflicts = n }
function M.merge(base, local_, remote)
```

**Algorithm**:

```
1. Build ID-keyed maps:  base_map, local_map, remote_map
2. Collect all_ids = union of keys from all three maps
3. For each id in all_ids:

   base_item   = base_map[id]    -- may be nil
   local_item  = local_map[id]   -- may be nil
   remote_item = remote_map[id]  -- may be nil

   -- Serialize for comparison (vim.json.encode with sort_keys)
   base_json   = serialize(base_item)
   local_json  = serialize(local_item)
   remote_json = serialize(remote_item)

   CASE: base=nil, local=item, remote=nil  → KEEP local  (added locally)
   CASE: base=nil, local=nil, remote=item  → KEEP remote (added remotely)
   CASE: base=nil, local=item, remote=item → KEEP either (added both; dedup)
   CASE: base=item, local=nil, remote=nil  → DELETE       (deleted both)
   CASE: base=item, local=nil, remote=item → DELETE       (deleted locally)
   CASE: base=item, local=item, remote=nil → DELETE       (deleted remotely)
   CASE: base=item, local=item, remote=item:
       if local_json == remote_json         → KEEP either (same state)
       if local_json == base_json           → KEEP remote (remote changed)
       if remote_json == base_json          → KEEP local  (local changed)
       else                                 → FIELD-LEVEL MERGE (both changed)

4. Return merged list (ordering doesn't matter; dooing sorts on load)
```

**Field-level merge** (when both local and remote changed the same item):

```
FIELDS = { 'text', 'done', 'in_progress', 'category', 'created_at',
           'completed_at', 'priorities', 'estimated_hours', 'notes',
           'parent_id', 'depth', 'due_at' }

For each field in FIELDS:
    base_val   = base_item[field]
    local_val  = local_item[field]
    remote_val = remote_item[field]

    if equal(local_val, base_val)    → use remote_val
    if equal(remote_val, base_val)   → use local_val
    if equal(local_val, remote_val)  → use local_val
    else → TRUE CONFLICT, resolve per conflict_strategy:
        'recent'  → compare created_at/completed_at heuristics
        'local'   → always prefer local
        'remote'  → always prefer remote
        'prompt'  → vim.ui.select() (only viable for few conflicts)
```

**Field comparison**:
- Primitives: `==`
- Tables (e.g. `priorities`): `vim.deep_equal()`
- nil handling: `nil == nil` is true; `nil ~= value` is a change

**Edge case: `id` field itself**:
- `id` is the merge key and is immutable — never merge the id field.

**Edge case: first sync (no base)**:
- If `base` is nil, treat it as an empty list.
- All local items are "added locally", all remote items are "added remotely".
- Items with the same `id` in both: keep either (they're the same item from a
  previous un-tracked sync).

### 3.4 `fs.lua`

**Purpose**: Manage the base snapshot and watch for file changes.

**Functions**:

| Function | Description |
|----------|-------------|
| `M.read_json(path)` | Read and parse JSON file. Returns `table` or `nil`. |
| `M.write_json(path, data)` | Serialize and write JSON atomically (write to `.tmp`, rename). |
| `M.save_base(data)` | Write merged result as the new base snapshot. |
| `M.load_base()` | Load base snapshot (returns nil if doesn't exist — first sync). |
| `M.watch(path, callback)` | Start `vim.uv.new_fs_event()` watcher on path. Debounce 500ms. Calls `callback()` on change. |
| `M.unwatch()` | Stop the file watcher. |

**Debouncing**: dooing may write the file multiple times in quick succession
(e.g. `save_todos()` called from `sort_todos` then `migrate_todos`). The watcher
debounces with a 500ms timer so we only trigger one push per "batch" of writes.

**Atomic writes**: Write to `path .. '.tmp'`, then `vim.uv.fs_rename()`. Prevents
reading a half-written file if dooing and sync race.

### 3.5 `init.lua`

**Purpose**: Public API, lifecycle orchestration, autocmds.

**`M.setup(opts)`**:
```
1. Merge opts with defaults  →  config
2. Validate credentials exist in vim.env; if missing, warn and disable sync
3. Determine save_path:
   a. From config.save_path if set
   b. From require'dooing.config'.options.save_path (if dooing already loaded)
   c. Fall back to vim.fn.stdpath('data') .. '/dooing_todos.json'
4. Perform initial sync (async):
   a. refresh access token
   b. download remote
   c. read local save_path
   d. read base snapshot
   e. merge(base, local, remote)
   f. write merged → save_path
   g. write merged → base snapshot
   h. upload merged → Google Drive (only if merged ≠ remote, to avoid unnecessary writes)
5. Start file watcher on save_path
6. Register autocmds:
   - VimLeavePre: final push (synchronous, to ensure it completes)
   - Optionally: timer for periodic pull (pull_interval)
7. Register user commands:
   - :DooingSync       — manual pull + merge + push
   - :DooingSyncStatus — show last sync time, conflict count, online/offline
```

**Push flow** (triggered by file watcher):
```
1. Read new local save_path content
2. Upload to Google Drive (async)
3. Update base snapshot to match local
   (No merge needed: we ARE the latest writer; remote will be overwritten)
```

**Periodic pull flow** (triggered by timer):
```
1. Download remote
2. Read current local
3. Read base
4. If remote == base → no remote changes, skip
5. If remote ≠ base → merge, write local, write base, upload merged
6. If dooing window is open, trigger a refresh:
   require'dooing.state'.load_todos()
   -- and re-render if UI is visible
```

---

## 4. Google Drive OAuth Setup (One-Time Per User)

Users must create a Google Cloud project with the Drive API enabled. This is a
one-time setup documented in the README.

### Steps:
1. Go to https://console.cloud.google.com/
2. Create a new project (e.g. "dooing-sync")
3. Enable the **Google Drive API**
4. Create OAuth 2.0 credentials (Desktop application type)
5. Note the `client_id` and `client_secret`
6. Obtain a refresh token by running the provided helper script (see below)
7. Store all three values in `~/.secrets.zshenv`:
   ```bash
   export DOOING_GDRIVE_CLIENT_ID="xxxx.apps.googleusercontent.com"
   export DOOING_GDRIVE_CLIENT_SECRET="GOCSPX-xxxx"
   export DOOING_GDRIVE_REFRESH_TOKEN="1//xxxx"
   ```

### Helper: Token Acquisition Script

We provide a small shell script `scripts/gdrive-auth.sh` that:
1. Opens the browser for OAuth consent
2. Starts a temporary local HTTP server to receive the authorization code
3. Exchanges the code for a refresh token
4. Prints the export lines to paste into `~/.secrets.zshenv`

This only needs to run once per machine (refresh tokens are long-lived).

```
dooing-sync.nvim/
├── scripts/
│   └── gdrive-auth.sh     # One-time OAuth helper
```

---

## 5. Error Handling & Offline Mode

| Scenario | Behavior |
|----------|----------|
| No credentials in env | `setup()` logs info message, sync disabled, dooing works normally |
| Network unreachable | Push/pull silently skipped, local dooing works normally |
| Google API error (5xx) | Retry up to 3 times with exponential backoff, then skip |
| Token expired | Auto-refresh via refresh_token; if refresh fails, log warning |
| Corrupt remote JSON | Log error, skip merge, keep local as-is |
| Corrupt base snapshot | Treat as first sync (base = nil); full merge |
| Corrupt local JSON | Let dooing handle it (not our responsibility) |
| Race condition (two machines push simultaneously) | Last push wins on Drive; next pull on the other machine will merge |
| `save_path` doesn't exist yet | Create empty file; on first sync, pull remote → becomes local |

**Principle**: Never break dooing's normal operation. If sync fails for any
reason, dooing continues to work with its local file. Sync issues are logged
but never throw errors.

---

## 6. User-Facing Configuration Example

```lua
-- lua/plugins/dooing.lua
return {
    {
        'atiladefreitas/dooing',
        version = '^2',
        dependencies = {
            'folke/which-key.nvim',
            'immanuel-haffner/dooing-sync.nvim',  -- or wherever hosted
        },
        config = function()
            require'dooing-sync'.setup{
                sync = {
                    pull_on_start = true,
                    push_on_save = true,
                    pull_interval = 300,
                },
            }
            require'dooing'.setup{
                keymaps = {
                    toggle_window = false,
                    toggle_priority = 'x',
                },
                window = { position = 'bottom-right' },
            }
        end,
    }
}
```

---

## 7. Implementation Order

### Phase 1: Foundation
1. **`config.lua`** — Defaults, option merging
2. **`fs.lua`** — JSON read/write, base snapshot management
3. **`merge.lua`** — Three-way merge engine (pure functions, testable in isolation)

### Phase 2: Google Drive
4. **`gdrive.lua`** — Token refresh, find, download, upload, create
5. **`scripts/gdrive-auth.sh`** — One-time OAuth helper script

### Phase 3: Integration
6. **`init.lua`** — setup(), sync lifecycle, autocmds, commands
7. Wire up file watcher (push-on-save)
8. Wire up periodic pull timer

### Phase 4: Polish
9.  **`doc/dooing-sync.txt`** — Vimdoc help
10. **`README.md`** — User documentation with OAuth setup guide
11. Error handling hardening, edge case testing
12. Decide on GitHub repo location, LICENSE

---

## 8. Testing Strategy

- **`merge.lua`**: Unit tests with hand-crafted base/local/remote tables.
  Cover all 7 cases from the merge algorithm, plus field-level conflicts.
  Can be run with `nvim -l` or a test framework like `plenary.busted`.
- **`gdrive.lua`**: Manual testing with real Google Drive API.
  Mock tests possible by stubbing `vim.system()`.
- **Integration**: Manual testing across two machines (or two Neovim instances
  with different save_paths simulating two machines).

---

## 9. Open Questions

- [ ] Should we support syncing per-project dooing files too, or only the global one?
      (Start with global only; per-project can be added later.)
- [ ] Should the periodic pull also trigger a dooing UI refresh?
      (Yes, if the dooing window is currently open.)
- [ ] Should we provide a Telescope picker for conflict resolution?
      (Nice-to-have; not in Phase 1.)
