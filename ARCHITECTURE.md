# Architecture

This document describes the internal design of dooing-sync.nvim — how it synchronizes
dooing todo lists across machines via Google Drive.

## Table of Contents

- [System Overview](#system-overview)
- [Module Map](#module-map)
- [Data Model](#data-model)
- [Google Drive API Usage](#google-drive-api-usage)
- [Synchronization Flow](#synchronization-flow)
- [Three-Way Merge Algorithm](#three-way-merge-algorithm)
- [File Watching & Push-on-Save](#file-watching--push-on-save)
- [Token Management](#token-management)
- [Error Handling & Offline Mode](#error-handling--offline-mode)
- [Testing Strategy](#testing-strategy)

---

## System Overview

```
┌──────────────────────────────────────────────────────────────────┐
│                           Neovim                                 │
│                                                                  │
│  ┌──────────────┐           ┌──────────────────┐                 │
│  │ dooing.nvim  │  setup()  │ dooing-sync.nvim │                 │
│  │ (upstream)   │◄──────────│                  │                 │
│  └──────┬───────┘           │ ┌──────────────┐ │                 │
│         │ reads/writes      │ │  merge.lua   │ │                 │
│         ▼                   │ │  (3-way)     │ │                 │
│   ┌──────────┐              │ └──────────────┘ │                 │
│   │save_path │◄─────────────│                  │  curl + async   │
│   │  .json   │ write merged │ ┌──────────────┐ │───────────┐     │
│   └──────────┘              │ │  gdrive.lua  │ │           │     │
│                             │ │  (REST API)  │ │           │     │
│   ┌──────────┐              │ └──────────────┘ │           │     │
│   │  base    │◄─────────────│                  │           │     │
│   │ snapshot │ save base    │ ┌──────────────┐ │           │     │
│   └──────────┘              │ │   fs.lua     │ │           ▼     │
│                             │ │  (watcher)   │ │    ┌──────────┐ │
│                             │ └──────────────┘ │    │  Google  │ │
│                             └──────────────────┘    │  Drive   │ │
│                                                     │  v3 API  │ │
│                                                     └──────────┘ │
└──────────────────────────────────────────────────────────────────┘
```

---

## Module Map

```
lua/dooing-sync/
├── init.lua       Entry point. setup(), sync lifecycle, autocmds, user commands.
├── config.lua     Default options, credential validation, logging.
├── gdrive.lua     Google Drive REST API: OAuth tokens, find, download, upload, create.
├── merge.lua      Three-way field-level merge engine. Pure functions, no I/O.
└── fs.lua         JSON file I/O, base snapshot management, file watcher (libuv).
```

### Dependency Graph

```
init.lua
├── config.lua
├── fs.lua ──── config.lua
├── gdrive.lua ── config.lua
└── merge.lua ── config.lua
```

All modules depend on `config.lua` for options and logging. No circular dependencies.

---

## Data Model

### Dooing Todo Item

Each todo is a JSON object with these fields:

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | **Unique identifier** (format: `<unix_timestamp>_<random>`). Used as the merge key. |
| `text` | string | Todo text, may contain `#tags`. |
| `done` | boolean | Completion status. |
| `in_progress` | boolean | In-progress status. |
| `category` | string | Extracted from first `#tag` in text. |
| `created_at` | integer | Unix timestamp of creation. |
| `completed_at` | integer? | Unix timestamp of completion. |
| `priorities` | string[]? | Array of priority names (e.g. `["important", "urgent"]`). |
| `estimated_hours` | number? | Estimated completion time in hours. |
| `notes` | string | Freeform notes text. |
| `parent_id` | string? | ID of parent todo (for nested tasks). |
| `depth` | integer | Nesting depth (0 = top level). |
| `due_at` | integer? | Unix timestamp of due date. |

### Storage Files

| File | Location | Purpose |
|------|----------|---------|
| **save_path** | `vim.fn.stdpath('data') .. '/dooing_todos.json'` | Dooing's live data file. |
| **base snapshot** | `vim.fn.stdpath('data') .. '/dooing_sync_base.json'` | Last successfully synced version. Used as the common ancestor in three-way merge. |
| **remote** | Google Drive (`dooing_todos.json`) | The shared copy. |

---

## Google Drive API Usage

### OAuth 2.0 Flow

dooing-sync uses the **OAuth 2.0 refresh token grant** for authentication. The user
performs a one-time browser-based authorization to obtain a long-lived refresh token.

```
┌───────────┐                       ┌──────────────┐
│  Neovim   │                       │ Google OAuth  │
│  (curl)   │                       │    Server     │
└─────┬─────┘                       └──────┬───────┘
      │                                    │
      │  POST /token                       │
      │  grant_type=refresh_token          │
      │  refresh_token=xxx                 │
      │  client_id=xxx                     │
      │  client_secret=xxx                 │
      │───────────────────────────────────►│
      │                                    │
      │  { access_token, expires_in }      │
      │◄───────────────────────────────────│
      │                                    │
      │  (cached in memory for ~1hr)       │
      │                                    │
```

### Scope

The plugin uses `drive.file` — the most restrictive Google Drive scope:

> Allows access only to files created or opened by the app. Does not allow access
> to any other files on the user's Drive.

### API Endpoints

| Method | Endpoint | Purpose |
|--------|----------|---------|
| `POST` | `https://oauth2.googleapis.com/token` | Exchange refresh token for access token |
| `GET` | `https://www.googleapis.com/drive/v3/files?q=...` | Search for file by name (and optional parent folder) |
| `GET` | `https://www.googleapis.com/drive/v3/files/{id}?alt=media` | Download file content |
| `PATCH` | `https://www.googleapis.com/upload/drive/v3/files/{id}?uploadType=media` | Update existing file content |
| `POST` | `https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart` | Create new file with metadata + content |

### File Identity

The plugin finds its file on Drive by searching for the configured `gdrive_filename`
(default: `dooing_todos.json`) within the configured `gdrive_folder_id`. The Drive
file ID is cached in memory after the first lookup to avoid repeated searches.

---

## Synchronization Flow

### Startup Sync (Blocking)

This runs during `dooing-sync.setup()`, **before** `dooing.setup()`, so dooing loads
the already-merged data.

```
 dooing-sync.setup()
 │
 ├─ Validate credentials
 │  └─ Missing? → disable sync, return
 │
 ├─ Resolve save_path
 │
 ├─ INITIAL SYNC (blocking via vim.wait)
 │  │
 │  ├─ 1. Refresh access token
 │  │
 │  ├─ 2. Pull remote
 │  │     ├─ Find file on Drive (by name + folder)
 │  │     └─ Download content
 │  │        └─ Not found? → push local as-is, done
 │  │
 │  ├─ 3. Load local (save_path)
 │  │
 │  ├─ 4. Load base snapshot
 │  │
 │  ├─ 5. Three-way merge(base, local, remote)
 │  │     └─ See "Three-Way Merge Algorithm" below
 │  │
 │  ├─ 6. Write merged → save_path (if changed)
 │  │     └─ Set write guard (suppress file watcher)
 │  │
 │  ├─ 7. Write merged → base snapshot
 │  │
 │  └─ 8. Push merged → Drive (async, only if merged ≠ remote)
 │
 ├─ Start file watcher on save_path
 │
 ├─ Start periodic pull timer
 │
 ├─ Register VimLeavePre autocmd
 │
 └─ Register :DooingSync, :DooingSyncStatus commands
      │
      ▼
 dooing.setup()  ← loads the merged file
```

### Push-on-Save Flow

Triggered by the file watcher when dooing writes to `save_path`.

```
 dooing saves file
 │
 ▼
 fs_event fires
 │
 ├─ Debounce (500ms)
 │
 ├─ Write guard active?
 │  └─ Yes → skip (this was our own write)
 │
 ├─ Read new local content
 │
 ├─ Upload to Google Drive (async)
 │
 └─ Update base snapshot
```

### Periodic Pull Flow

Triggered by a repeating timer (default: every 5 minutes).

```
 Timer fires
 │
 ├─ Pull remote from Drive
 │
 ├─ Compare remote with base snapshot
 │  └─ Identical? → skip (no remote changes)
 │
 ├─ Three-way merge(base, local, remote)
 │
 ├─ Write merged → save_path (if changed)
 │  └─ Reload dooing's in-memory state
 │
 ├─ Write merged → base snapshot
 │
 └─ Push merged → Drive (if merged ≠ remote)
```

### VimLeavePre Flow

Ensures data is pushed before Neovim exits.

```
 VimLeavePre
 │
 ├─ Read local save_path
 ├─ Upload to Drive (async, but vim.wait blocks up to 10s)
 └─ Update base snapshot
```

---

## Three-Way Merge Algorithm

### Overview

The merge operates on **three versions** of the todo list:

- **Base** — the last successfully synced state (common ancestor)
- **Local** — the current file on this machine
- **Remote** — the file from Google Drive (another machine's changes)

Each todo item has a unique `id` field, used as the merge key.

### Item-Level Classification

For each `id` present in any of the three versions:

```
┌────────┬─────────┬─────────┬──────────────────────────────────┐
│  Base  │  Local  │ Remote  │  Action                          │
├────────┼─────────┼─────────┼──────────────────────────────────┤
│   —    │    ✓    │    —    │  Added locally → KEEP            │
│   —    │    —    │    ✓    │  Added remotely → KEEP           │
│   —    │    ✓    │    ✓    │  Added both → KEEP (dedup by id) │
│   ✓    │    —    │    —    │  Deleted both → DELETE           │
│   ✓    │    —    │    ✓    │  Deleted locally → DELETE        │
│   ✓    │    ✓    │    —    │  Deleted remotely → DELETE       │
│   ✓    │    ✓    │    ✓    │  See "Modification Detection"    │
└────────┴─────────┴─────────┴──────────────────────────────────┘
```

### Modification Detection

When an item exists in all three versions, compare serialized JSON (with sorted keys):

```
local_json  == remote_json  →  Both same (take either)
local_json  == base_json    →  Only remote changed  → take REMOTE
remote_json == base_json    →  Only local changed   → take LOCAL
all three differ            →  FIELD-LEVEL MERGE
```

### Field-Level Merge

When both local and remote changed the same item differently, merge individual fields:

```
For each field in { text, done, in_progress, category, created_at,
                    completed_at, priorities, estimated_hours, notes,
                    parent_id, depth, due_at }:

    local_val  == base_val    →  Use remote_val  (remote changed it)
    remote_val == base_val    →  Use local_val   (local changed it)
    local_val  == remote_val  →  Use either      (same change)
    all three differ          →  TRUE CONFLICT   → resolve per strategy
```

### Conflict Resolution Strategies

| Strategy | Behavior |
|----------|----------|
| `recent` (default) | Prefer the item with the higher `completed_at` or `created_at` timestamp |
| `local` | Always prefer the local version |
| `remote` | Always prefer the remote version |

### Forward Compatibility

Unknown fields (added by future dooing versions) are preserved through merges.
The merge engine copies any unrecognized keys from both local and remote items
to the merged result.

### Array Ordering

The merged result is an unordered list of items. Dooing re-sorts todos by
priority, due date, and creation time on every load, so output order is irrelevant.

### First Sync (No Base)

When no base snapshot exists (first sync from a machine), base is treated as empty:

- All local items are classified as "added locally"
- All remote items are classified as "added remotely"
- Items with the same `id` in both are deduplicated

---

## File Watching & Push-on-Save

### Mechanism

Uses libuv's `fs_event` via `vim.uv.new_fs_event()` to watch dooing's `save_path`.

### Debouncing

Dooing may write multiple times in quick succession (e.g. sort + save). The watcher
debounces with a **500ms timer** — only the last event in a burst triggers a push.

```
Event 1  ──►  start 500ms timer
Event 2  ──►  reset timer
Event 3  ──►  reset timer
              ... 500ms pass ...
         ──►  trigger push callback
```

### Write Guard

When dooing-sync itself writes to `save_path` (after a merge), a `writing_local` flag
is set to suppress the file watcher from triggering an unnecessary push. The flag is
cleared after 700ms (beyond the debounce window).

### Atomic Writes

`fs.write_json()` writes to a `.tmp` file first, then renames atomically via
`os.rename()`. This prevents reading a half-written file if dooing and sync race.

---

## Token Management

### Caching

The access token is cached in a module-local variable with an `expires_at` timestamp.
A 60-second safety margin is applied to avoid using an expired token.

```lua
token_expires_at = os.time() + expires_in - 60
```

### Auto-Refresh

`get_access_token()` checks the cache first. If expired or missing, it automatically
calls `refresh_access_token()`.

### Invalidation

`invalidate_token()` clears the cache, forcing a refresh on the next request. This
is useful after receiving a 401 Unauthorized response.

### Credential Storage

Credentials are read from environment variables (not files), making them compatible
with any secret management approach:

| Variable | Content |
|----------|---------|
| `DOOING_GDRIVE_CLIENT_ID` | OAuth 2.0 Client ID |
| `DOOING_GDRIVE_CLIENT_SECRET` | OAuth 2.0 Client Secret |
| `DOOING_GDRIVE_REFRESH_TOKEN` | Long-lived refresh token |

---

## Error Handling & Offline Mode

### Design Principle

> Never break dooing's normal operation. Sync failures are logged but never
> throw errors or block the editor.

### Error Matrix

| Scenario | Behavior |
|----------|----------|
| No credentials in environment | Sync disabled silently, dooing works normally |
| Network unreachable | Push/pull skipped, logged as warning |
| Google API 5xx | Logged as warning, operation skipped |
| Token expired | Auto-refresh; if refresh fails, logged as error |
| Corrupt remote JSON | Logged as error, merge skipped, local preserved |
| Corrupt base snapshot | Treated as first sync (base = nil) |
| Initial sync timeout | Logged as warning, dooing loads local data |
| Concurrent pushes from two machines | Last push wins; next pull on other machine reconciles via merge |

### Logging Levels

| Level | When |
|-------|------|
| `DEBUG` | Token refreshes, file operations, sync steps (only with `debug = true`) |
| `INFO` | Sync results, initial push, credential warnings |
| `WARN` | Network failures, timeouts, push failures |
| `ERROR` | Corrupt data, parse failures |

---

## Testing Strategy

### Test Suite Structure

```
tests/
├── test_config.lua   13 unit tests      Config merging, credential validation, path resolution
├── test_fs.lua       13 unit tests      JSON I/O, atomic writes, base snapshots, file watcher
├── test_merge.lua    18 unit tests      All merge cases, field-level merge, conflict strategies
├── test_gdrive.lua    5 integration     Token refresh, push/pull round-trip (requires credentials)
└── test_init.lua     10 integration     Full lifecycle: setup, sync, push-on-save, teardown
                      ──────────────
                      59 total
```

### Running Tests

```bash
# Unit tests (offline, fast)
nvim --headless -l tests/test_config.lua
nvim --headless -l tests/test_fs.lua
nvim --headless -l tests/test_merge.lua

# Integration tests (requires network + OAuth credentials)
nvim --headless -l tests/test_gdrive.lua
nvim --headless -l tests/test_init.lua
```

### Integration Test Isolation

- Integration tests use a temporary `save_path` and `base_path` in `/tmp/`
- They clean up after themselves
- `test_gdrive.lua` gracefully skips if credentials are missing
- `test_init.lua` uses `teardown()` to clean up state between tests

### Test Runner

Tests use a minimal custom runner (no external dependencies):
- `test(name, fn)` — wraps `pcall`, prints `✓`/`✗` with error details
- `skip(name, reason)` — prints `⊘` for skipped tests
- Non-zero exit code on any failure
