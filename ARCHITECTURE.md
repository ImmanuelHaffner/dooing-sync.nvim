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
- [Concurrency Protection](#concurrency-protection)
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
│  Neovim   │                       │ Google OAuth │
│  (curl)   │                       │    Server    │
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

## Concurrency Protection

dooing-sync is safe to use with **multiple Neovim sessions on the same machine** and
**multiple machines syncing to the same Google Drive file**.

### Threat Model

| # | Race | Without protection |
|---|------|--------------------|
| R1 | Two sessions read/write `base_path` concurrently | Stale base → incorrect merge → data loss |
| R2 | Two sessions write `save_path` concurrently | Last writer clobbers the other's merge |
| R3 | Two sessions (or machines) push to Drive concurrently | Last push wins, silently dropping changes |
| R4 | Session reads `save_path` while another writes | Stale read → stale merge |

### Two-Layer Protection

```
┌──────────────────────────────────────────────────────────────────┐
│                        Same Machine                              │
│                                                                  │
│   Session A ──┐                                                  │
│               ├── Local Lockfile ── serializes access to ──┐     │
│   Session B ──┘   (fs.lua)         save_path & base_path   │     │
│                                                            │     │
│                                                            ▼     │
│                                                     ┌──────────┐ │
│   Machine X ──┐                                     │  Google  │ │
│               ├── ETag Conditional Push ───────────►│  Drive   │ │
│   Machine Y ──┘   (gdrive.lua)                      └──────────┘ │
│                    prevents lost updates                         │
└──────────────────────────────────────────────────────────────────┘
```

#### Layer 1: Local File Locking

A lockfile at `<base_path>.lock` serializes the entire sync cycle across Neovim sessions
on the same machine. The lock covers all local reads, the merge, local writes, and the
push to Drive.

- **Mechanism**: `O_CREAT|O_EXCL` via `vim.uv.fs_open()` for atomic creation.
- **Content**: The PID of the owning process.
- **Stale detection**: On lock failure, the lockfile's PID is read and checked with
  `kill(pid, 0)`. If the process is dead, the lock is removed and reacquired.
- **Timeout**: Configurable via `lock_timeout_ms` (default: 10s). On timeout, the sync
  is skipped — the next trigger will retry.
- **Reentrancy guard**: A module-local `sync_in_progress` flag in `init.lua` prevents
  reentrant sync attempts (e.g. file watcher firing during an ongoing sync).

#### Layer 2: ETag-Based Conditional Push

Google Drive assigns an **ETag** to every file version. dooing-sync captures the ETag
on download and sends it back as an `If-Match` header on upload.

- **Download**: `curl -D <tmpfile>` captures response headers; the `ETag` header is parsed.
- **Upload**: When an ETag is available, `curl -H "If-Match: <etag>"` makes the push
  conditional. If another machine pushed since our download, Drive returns **HTTP 412
  Precondition Failed**.
- **Retry**: On 412, the entire sync cycle is retried (release lock → re-pull → re-merge
  → re-push with fresh ETag). Retries are capped at `max_retries` (default: 2).
- **Graceful fallback**: If the ETag is unavailable (e.g. header stripped by proxy), the
  push is unconditional (equivalent to pre-concurrency behavior).

### Base Snapshot Integrity

The base snapshot is only updated **after a successful push** (or when no push is needed
because merged == remote). This ensures that a failed push leaves the base in its previous
state, so the next sync re-merges correctly without data loss.

### No Blind Pushes

There is no "push-only" code path. Every push goes through the full three-way merge cycle
(`pull → merge → push`), ensuring we never overwrite remote changes.

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
 │  ├─ 1. Acquire local lock
 │  │
 │  ├─ 2. Load base snapshot + local file (under lock)
 │  │
 │  ├─ 3. Pull remote (with ETag capture)
 │  │     ├─ Find file on Drive (by name + folder)
 │  │     └─ Download content + ETag
 │  │        └─ Not found? → push local as-is, save base, unlock, done
 │  │
 │  ├─ 4. Three-way merge(base, local, remote)
 │  │     └─ See "Three-Way Merge Algorithm" below
 │  │
 │  ├─ 5. Write merged → save_path (if changed)
 │  │     └─ Set write guard (suppress file watcher)
 │  │
 │  ├─ 6. Push merged → Drive (conditional: If-Match ETag)
 │  │     ├─ Success → save base snapshot, unlock, done
 │  │     ├─ 412 Mismatch → unlock, retry from step 1 (max 2 retries)
 │  │     └─ Other error → unlock, done (retry on next trigger)
 │  │
 │  └─ 7. Release local lock
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

Triggered by the file watcher when dooing writes to `save_path`. Uses the full sync
cycle (not a blind push) to prevent lost updates.

```
 dooing saves file
 │
 ▼
 fs_event fires
 │
 ├─ Debounce (500ms)
 │
 ├─ Write guard active? → Yes → skip (this was our own write)
 │
 ├─ Sync already in progress? → Yes → skip
 │
 └─ Full sync cycle (same as startup sync: lock → pull → merge → push → unlock)
```

### Periodic Pull Flow

Triggered by a repeating timer (default: every 5 minutes). Uses the same full sync cycle.

```
 Timer fires
 │
 ├─ Sync already in progress? → Yes → skip
 │
 └─ Full sync cycle (lock → pull → merge → push → unlock)
```

### VimLeavePre Flow

Ensures data is synced before Neovim exits. Uses a blocking full sync cycle.

```
 VimLeavePre
 │
 └─ Full sync cycle (blocking, up to 15s timeout)
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
| Concurrent pushes from two machines | ETag mismatch → automatic retry with fresh data (up to `max_retries`) |
| Lock timeout (another local session syncing) | Sync skipped; next trigger retries |
| Neovim crash while holding lock | Stale lock detected by PID check on next sync, automatically removed |

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
├── test_config.lua       13 unit tests   Config merging, credential validation, path resolution
├── test_fs.lua           13 unit tests   JSON I/O, atomic writes, base snapshots, file watcher
├── test_fs_lock.lua      18 unit tests   File locking, PID detection, stale lock cleanup
├── test_merge.lua        18 unit tests   All merge cases, field-level merge, conflict strategies
├── test_gdrive_etag.lua  16 unit tests   ETag parsing, If-Match headers, 412 detection
├── test_init_sync.lua     9 unit tests   Protected sync cycle, retry, lock lifecycle (mocked gdrive)
├── test_gdrive.lua        5 integration  Token refresh, push/pull round-trip (requires credentials)
└── test_init.lua         10 integration  Full lifecycle: setup, sync, push-on-save, teardown
                          ──────────────
                          102 total
```

### Running Tests

```bash
# Unit tests (offline, fast)
nvim --headless -l tests/test_config.lua
nvim --headless -l tests/test_fs.lua
nvim --headless -l tests/test_fs_lock.lua
nvim --headless -l tests/test_merge.lua
nvim --headless -l tests/test_gdrive_etag.lua
nvim --headless -l tests/test_init_sync.lua

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
