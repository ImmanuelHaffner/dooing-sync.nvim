# Concurrency Protection: Local Locking + ETag-Based Conditional Push

This document describes the design and implementation plan for protecting dooing-sync
against race conditions when multiple Neovim sessions run on the same machine **and**
when multiple machines sync to the same Google Drive file.

---

## Table of Contents

- [Problem Statement](#problem-statement)
- [Threat Model](#threat-model)
- [Solution Overview](#solution-overview)
- [Part 1: Local File Locking](#part-1-local-file-locking)
- [Part 2: ETag-Based Conditional Push](#part-2-etag-based-conditional-push)
- [Part 3: Eliminating the Blind Push](#part-3-eliminating-the-blind-push)
- [Integration: The Protected Sync Cycle](#integration-the-protected-sync-cycle)
- [Edge Cases and Failure Modes](#edge-cases-and-failure-modes)
- [Configuration Changes](#configuration-changes)
- [Testing Plan](#testing-plan)
- [Implementation Order](#implementation-order)
- [File-by-File Change Summary](#file-by-file-change-summary)

---

## Problem Statement

The current implementation has no concurrency protection. Two Neovim sessions on the
same machine — or two machines syncing to the same Google Drive file — can corrupt data
through several race conditions:

| # | Race | Consequence |
|---|------|-------------|
| R1 | Two sessions read/write `base_path` concurrently | Stale base → incorrect merge → data loss |
| R2 | Two sessions write `save_path` concurrently | Last writer clobbers the other's merged result |
| R3 | Two sessions (or machines) push to Drive concurrently | Last push wins, silently dropping the other's changes |
| R4 | `push_local` is a blind push (no merge) | Pushes potentially stale local data, overwriting remote |
| R5 | Session reads `save_path` while another renames a `.tmp` into it | Stale read leads to stale merge (mitigated by atomic rename, but read-then-act is still racy) |

---

## Threat Model

### In scope

1. **Multiple Neovim sessions on the same machine** — e.g. multiple terminal tabs, tmux
   panes, or GUI instances, all using dooing-sync with the same `save_path` and `base_path`.
2. **Multiple machines syncing to the same Google Drive file** — the primary use case of
   this plugin.
3. **Neovim crashes** — a session may die while holding a lock or mid-sync.

### Out of scope

- Malicious actors manipulating lockfiles or Drive content.
- External programs modifying `save_path` outside of dooing/dooing-sync.
- NFS or network filesystem semantics for local files (we assume a local POSIX filesystem).

---

## Solution Overview

Two complementary mechanisms, each covering a different domain:

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Same Machine                                 │
│                                                                     │
│   Session A ──┐                                                     │
│               ├── Local Lockfile ── serializes access to ──┐        │
│   Session B ──┘   (fs.lua)         save_path & base_path   │        │
│                                                             │        │
│                                                             ▼        │
│                                                     ┌─────────────┐ │
│                                                     │ Google Drive│ │
│                                                     │   (remote)  │ │
│                                                     └──────┬──────┘ │
│                                                            │        │
│   Machine X ──┐                                            │        │
│               ├── ETag Conditional Push ── prevents ───────┘        │
│   Machine Y ──┘   (gdrive.lua)             lost updates            │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

- **Local lockfile** prevents R1, R2, R5 by serializing the entire sync cycle across
  sessions on one machine.
- **ETag conditional push** prevents R3 by making the Drive API reject a push when
  the remote has changed since we last read it.
- **Eliminating `push_local`** in favor of a full sync cycle prevents R4.

---

## Part 1: Local File Locking

### Mechanism

A **lockfile** at `<base_path>.lock` (e.g. `~/.local/share/nvim/dooing_sync_base.json.lock`)
guards the critical section. The lockfile contains the PID of the owning process for
stale-lock detection.

### API (new functions in `fs.lua`)

```lua
--- Acquire the sync lock. Blocks (with polling) until acquired or timeout.
---
--- Uses O_CREAT|O_EXCL via vim.uv.fs_open() for atomic creation.
--- Writes the current PID into the lockfile for stale-lock detection.
---
--- @param timeout_ms integer  Maximum time to wait (default: 10000).
--- @return boolean acquired   True if the lock was acquired.
function M.lock(timeout_ms)

--- Release the sync lock.
---
--- Verifies we own the lock (PID matches) before removing.
--- Safe to call even if we don't hold the lock.
---
--- @return boolean released  True if the lock was released.
function M.unlock()
```

### Lock File Path

Derived from `base_path`:

```lua
local lock_path = config.options.base_path .. '.lock'
```

This ensures the lock and the base snapshot are co-located on the same filesystem,
which is required for `os.rename` atomicity and `O_EXCL` semantics.

### Acquisition Algorithm

```
function lock(timeout_ms):
    deadline ← now + timeout_ms
    lock_path ← base_path .. ".lock"

    while now < deadline:
        fd ← uv.fs_open(lock_path, O_WRONLY | O_CREAT | O_EXCL, 0644)

        if fd ≠ nil:
            // Successfully created lockfile — we own it.
            uv.fs_write(fd, tostring(getpid()))
            uv.fs_close(fd)
            return true

        // Lockfile exists. Check if the owner is still alive.
        owner_pid ← read_pid_from(lock_path)
        if owner_pid and not process_alive(owner_pid):
            // Stale lock from a crashed session. Remove and retry.
            log("Removing stale lock from PID " .. owner_pid)
            uv.fs_unlink(lock_path)
            continue   // Retry immediately (don't sleep)

        // Lock is held by a live process. Wait and retry.
        sleep(100ms)

    // Timed out.
    log("Failed to acquire sync lock after " .. timeout_ms .. "ms", WARN)
    return false
```

### Process Liveness Check

```lua
--- Check if a process is alive.
--- @param pid integer
--- @return boolean
local function process_alive(pid)
    -- vim.uv.kill(pid, 0) sends signal 0 (no-op) to check existence.
    -- Returns 0 on success (process exists), non-zero on failure.
    local ok, err = pcall(vim.uv.kill, pid, 0)
    return ok and (err == nil or err == 0)
end
```

**Note**: `vim.uv.kill(pid, 0)` with signal 0 is a POSIX standard way to test process
existence without actually sending a signal. It returns success if the process exists
and we have permission to signal it.

### Release Algorithm

```
function unlock():
    lock_path ← base_path .. ".lock"

    // Read the PID from the lockfile to verify ownership.
    owner_pid ← read_pid_from(lock_path)
    my_pid ← getpid()

    if owner_pid ≠ my_pid:
        log("Lock not owned by us (owner: " .. owner_pid .. ", us: " .. my_pid .. ")", WARN)
        return false

    uv.fs_unlink(lock_path)
    return true
```

### Reentrancy

The lock is **not reentrant**. A single session must not call `lock()` while already
holding the lock. This is enforced by a module-local boolean:

```lua
local lock_held = false

function M.lock(timeout_ms)
    if lock_held then
        config.log('BUG: lock() called while already holding lock', vim.log.levels.ERROR)
        return true  -- Treat as success to avoid deadlock.
    end
    -- ... acquire ...
    lock_held = true
    return true
end

function M.unlock()
    if not lock_held then return false end
    -- ... release ...
    lock_held = false
    return true
end
```

### Lock Timeout

Default: **10 seconds**. This is generous enough to cover:
- A full sync cycle with a slow network (~30s curl timeout won't happen under lock;
  see integration section for how we handle this).
- Multiple sessions waiting in sequence.

If the timeout is reached, the sync is **skipped** (not retried). The next trigger
(periodic pull, file watcher, manual command) will try again.

---

## Part 2: ETag-Based Conditional Push

### Background: Google Drive ETags

Every file on Google Drive has an **ETag** — an opaque string that changes whenever the
file's content or metadata is modified. The Drive API supports conditional requests:

- **`If-Match: <etag>`** on a `PATCH` request: the update succeeds only if the file's
  current ETag matches. If someone else modified the file since we read it, the API
  returns **HTTP 412 Precondition Failed**.

This is **optimistic concurrency control**: we don't lock the remote file; instead, we
detect conflicts at push time and retry.

### API Changes in `gdrive.lua`

#### `download` — capture ETag

The current `download` function only returns the file content. We need it to also
return the ETag from the response headers.

```lua
--- Download a file's content from Google Drive.
--- @param token string     Access token.
--- @param file_id string   Drive file ID.
--- @param callback fun(content: string|nil, etag: string|nil, err: string|nil)
function M.download(token, file_id, callback)
```

**Implementation**: Add `-D -` (dump headers to stdout) or `-i` (include headers) to
the curl command, then parse the `ETag:` header from the response.

Preferred approach — use `-D <tmpfile>` to separate headers from body:

```
curl -s -D /tmp/dooing_sync_headers.tmp \
     -H "Authorization: Bearer <token>" \
     "https://www.googleapis.com/drive/v3/files/<id>?alt=media&fields=*"
```

Then parse the header file for:
```
ETag: "<value>"
```

**Alternative**: Use a metadata request to get the ETag separately, but this doubles
the API calls. The `-D` approach is more efficient.

**Note on header file**: We use a temporary file for headers rather than `-i` (include
headers in body) because the body is JSON and we want to parse it without header
stripping. The temp file path should be deterministic and per-process:

```lua
local header_path = os.tmpname()  -- or vim.fn.tempname()
```

#### `upload` — send `If-Match`

```lua
--- Update an existing file's content on Google Drive.
--- @param token string          Access token.
--- @param file_id string        Drive file ID.
--- @param content string        New file content (JSON string).
--- @param etag string|nil       ETag from the last download. If provided, the upload
---                               is conditional (fails with 412 if remote changed).
--- @param callback fun(ok: boolean, err: string|nil)
function M.upload(token, file_id, content, etag, callback)
```

When `etag` is non-nil, add the header:

```
curl -X PATCH \
     -H "Authorization: Bearer <token>" \
     -H "Content-Type: application/json" \
     -H "If-Match: <etag>" \
     --data-raw '<content>' \
     "https://www.googleapis.com/upload/drive/v3/files/<id>?uploadType=media"
```

#### `upload` — detect HTTP 412

The `parse_response` helper must distinguish 412 from other errors. The Google Drive API
returns a JSON error body on 412:

```json
{
  "error": {
    "code": 412,
    "message": "Precondition Failed",
    "errors": [{ "reason": "conditionNotMet" }]
  }
}
```

We surface this as a **distinct error string** so the caller can detect it:

```lua
if data.error and data.error.code == 412 then
    return nil, 'etag_mismatch'
end
```

#### `push` — plumb ETag through

The high-level `push` function must accept and forward the ETag:

```lua
--- Upload content to the dooing file on Google Drive.
--- @param content string        JSON string to upload.
--- @param etag string|nil       ETag for conditional push.
--- @param callback fun(ok: boolean, err: string|nil)
function M.push(content, etag, callback)
```

#### `pull` — return ETag

The high-level `pull` function must return the ETag alongside content:

```lua
--- Download the dooing file from Google Drive.
--- @param callback fun(content: string|nil, etag: string|nil, err: string|nil)
function M.pull(callback)
```

### ETag Lifecycle

```
pull()
  → download(token, file_id)
  → callback(content, etag, nil)
       ↓
    etag is passed into sync cycle
       ↓
push(merged_json, etag)
  → upload(token, file_id, merged_json, etag)
  → success: done
  → 412:    retry sync from pull (with fresh etag)
```

---

## Part 3: Eliminating the Blind Push

### Problem

The current `push_local` function reads `save_path` and pushes directly to Drive with
no merge. This is race R4:

```lua
-- Current code (init.lua):
local function push_local(on_done)
    local local_data = fs.read_json(save_path)
    local content = vim.json.encode(local_data, { sort_keys = true })
    gdrive.push(content, function(ok, err) ... end)  -- no merge, no ETag
end
```

If two sessions push near-simultaneously, the second push silently overwrites the first.

### Solution

**Replace `push_local` with `M.sync()`**. Every push goes through the full three-way
merge cycle with ETag protection. This ensures:

1. We merge against the latest remote before pushing.
2. The ETag prevents clobbering a concurrent push from another machine.
3. The local lock prevents clobbering from another local session.

The file watcher callback becomes:

```lua
local function on_file_changed()
    if writing_local then return end
    if not config.options.sync.push_on_save then return end
    config.log('Detected dooing save, syncing...', vim.log.levels.DEBUG)
    M.sync()  -- Full sync instead of blind push.
end
```

Similarly, the `VimLeavePre` handler calls `M.sync()` instead of `push_local()`.

### Performance Consideration

A full sync is more expensive than a blind push (one extra download). This is acceptable
because:

- Syncs are infrequent (only on save, every 5 min, and on exit).
- The download is small (a JSON file of typically <100KB).
- Correctness is more important than saving one HTTP round-trip.

---

## Integration: The Protected Sync Cycle

### Full Sync Flow (with locking + ETag)

```
M.sync()
│
├── 1. Acquire local lock
│       fs.lock(10000)
│       └── Failed? → log warning, abort sync, return
│
├── 2. Read local state (under lock)
│       base_data  ← fs.load_base()
│       local_data ← fs.read_json(save_path)
│
├── 3. Pull remote (network I/O, still under lock)
│       remote_content, etag ← gdrive.pull()
│       └── Failed? → release lock, return
│
├── 4. Three-way merge
│       merged, report ← merge.merge(base_data, local_data, remote_data)
│
├── 5. Write local results (under lock)
│       ├── fs.write_json(save_path, merged)   -- if changed
│       ├── fs.save_base(merged)
│       └── reload_dooing()                    -- refresh in-memory state
│
├── 6. Push to Drive with ETag (network I/O, still under lock)
│       gdrive.push(merged_json, etag)
│       ├── Success → done
│       └── 412 Precondition Failed → release lock, retry (step 1)
│
├── 7. Release local lock
│       fs.unlock()
│
└── Done
```

### Why hold the lock during network I/O?

Releasing the lock between local reads and writes would allow another session to
interleave, causing a stale merge. The lock must cover the entire read-merge-write-push
sequence.

**Concern**: A slow network request (up to 30s) blocks other sessions.
**Mitigation**:
- The curl timeout is 30s (configured in `gdrive.lua`). In practice, Drive API
  responses take <2s.
- Other sessions wait at `fs.lock()` with a 10s timeout. If the timeout is reached,
  they skip this sync cycle and try again on the next trigger.
- The lock is always released in a `finally`-equivalent pattern (see below).

### Guaranteed Lock Release

Use a helper to ensure the lock is released even on error:

```lua
--- Execute a function while holding the sync lock.
--- The lock is always released when the function returns or errors.
--- @param timeout_ms integer
--- @param fn fun(): any
--- @return boolean acquired  Whether the lock was acquired.
--- @return any ...            Return values from fn.
local function with_lock(timeout_ms, fn)
    if not fs.lock(timeout_ms) then
        return false
    end
    local ok, result = pcall(fn)
    fs.unlock()
    if not ok then
        error(result)  -- Re-raise after unlocking.
    end
    return true, result
end
```

**Note on async**: The current sync flow uses callbacks (async via `vim.system`).
The lock must be held across the entire callback chain. This means:
- `lock()` is called at the start of `M.sync()`
- `unlock()` is called in the **final callback** (after push completes or fails)
- Every error path must also call `unlock()`

This is the trickiest part of the implementation. Every early-return and error branch
in the async chain must release the lock. A disciplined approach:

```lua
function M.sync(opts)
    if not fs.lock(10000) then
        config.log('Could not acquire sync lock, skipping', vim.log.levels.WARN)
        if opts.on_done then opts.on_done() end
        return
    end

    -- All paths below MUST call fs.unlock() before returning.
    local function finish()
        fs.unlock()
        if opts.on_done then opts.on_done() end
    end

    -- ... async chain, every error branch calls finish() ...
end
```

### ETag Retry Loop

On HTTP 412, the entire sync cycle is retried with fresh data:

```
MAX_RETRIES = 2  -- avoid infinite loops

function sync(opts, retry_count):
    retry_count = retry_count or 0

    lock()
    ... merge ...
    push(merged, etag, function(ok, err)
        unlock()

        if err == 'etag_mismatch' and retry_count < MAX_RETRIES:
            log("Remote changed during sync, retrying...")
            sync(opts, retry_count + 1)   -- recursive retry
            return

        if err:
            log("Push failed: " .. err)

        finish()
    end)
```

The lock is **released before retry** so other local sessions get a chance to run.
The retry acquires the lock anew.

---

## Edge Cases and Failure Modes

### Neovim crash while holding lock

**Scenario**: Session crashes between `lock()` and `unlock()`.
**Detection**: The lockfile contains the PID. On next `lock()` attempt, any session
checks if the owner PID is alive. Dead PID → stale lock → remove and acquire.
**Data integrity**: The base snapshot is in one of two states:
- Old (pre-merge): safe, next sync will re-merge.
- New (post-merge): safe, already written atomically.

### Lock file on a different filesystem

If `base_path` is on a different filesystem from `/tmp`, `O_EXCL` still works (it's a
local filesystem operation, not dependent on the temp directory).

### Very slow network

If a sync takes >10s (the lock timeout for other sessions), waiting sessions will
skip their sync. This is acceptable — the next periodic pull or manual `:DooingSync`
will succeed.

### ETag unavailable

If Drive stops returning ETags (API change, proxy stripping headers), the `etag`
parameter will be `nil`. In this case, `upload` falls back to an unconditional push
(current behavior). We log a warning:

```lua
if not etag then
    config.log('No ETag available, push is unconditional (risk of lost updates)', vim.log.levels.WARN)
end
```

### Concurrent file creation on Drive

Two sessions may both find no remote file and try to create one simultaneously. The
current `ensure_file` handles this: both create, one wins, the other will find the
existing file on next sync. The duplicate file is harmless (searched by name, first
match wins).

To be safer, we could add an `If-None-Match: *` header to the create request, but
this is a low-probability edge case and not worth the complexity in the initial
implementation.

### Lock cleanup on normal exit

The `VimLeavePre` handler does a final sync (which acquires/releases the lock). If
the sync completes, the lock is released. If it times out, the lock may remain — but
the PID-based stale detection handles this on the next startup.

---

## Configuration Changes

### New option: `lock_timeout_ms`

```lua
M.defaults = {
    -- ... existing options ...

    --- Maximum time (ms) to wait for the sync lock.
    --- Set to 0 to disable locking (not recommended with multiple sessions).
    lock_timeout_ms = 10000,

    --- Maximum number of retries on ETag mismatch (HTTP 412).
    max_retries = 2,
}
```

### No change to `base_path`

The lockfile path is derived from `base_path` (appending `.lock`). No new config
option needed.

---

## Testing Plan

### Unit Tests: `fs.lua` locking

| # | Test | Description |
|---|------|-------------|
| L1 | Lock acquire/release | `lock()` creates lockfile, `unlock()` removes it |
| L2 | Lock contention | Two calls to `lock()` in sequence; second blocks until first unlocks |
| L3 | Stale lock detection | Create lockfile with dead PID, verify `lock()` removes it and acquires |
| L4 | Lock timeout | Hold lock indefinitely, verify second `lock()` returns false after timeout |
| L5 | Lock ownership | Verify `unlock()` refuses to release if PID doesn't match |
| L6 | Reentrancy guard | Calling `lock()` while holding logs error, returns true |
| L7 | Lock + write_json | Verify `write_json` works correctly while lock is held |

### Unit Tests: `gdrive.lua` ETag handling

| # | Test | Description |
|---|------|-------------|
| E1 | Download returns ETag | Mock curl response with `ETag` header, verify it's parsed |
| E2 | Upload sends If-Match | Verify curl command includes `-H "If-Match: <etag>"` when etag is provided |
| E3 | Upload without ETag | Verify curl command omits `If-Match` when etag is nil |
| E4 | 412 detection | Mock a 412 response, verify error string is `'etag_mismatch'` |
| E5 | ETag passthrough in pull/push | Verify high-level `pull`/`push` propagate ETag correctly |

### Integration Tests: `init.lua` sync cycle

| # | Test | Description |
|---|------|-------------|
| S1 | Sync acquires and releases lock | Verify lockfile exists during sync, gone after |
| S2 | Sync retries on 412 | Mock a 412 on first push, verify retry succeeds |
| S3 | Sync gives up after max retries | Mock perpetual 412, verify it stops after `max_retries` |
| S4 | Concurrent sync is serialized | Start two syncs, verify they don't interleave (check log order) |
| S5 | File watcher triggers full sync | Verify `on_file_changed` calls `M.sync()` not `push_local` |
| S6 | VimLeavePre calls sync | Verify exit handler calls `M.sync()` |

### Manual Tests

| # | Test | Description |
|---|------|-------------|
| M1 | Two Neovim sessions | Open two nvim instances, add todos in both, verify no data loss |
| M2 | Kill during sync | `kill -9` a session mid-sync, verify the other session recovers |
| M3 | Two machines | Sync from two machines, verify three-way merge works end-to-end |
| M4 | Slow network simulation | Use `tc` or a proxy to add 5s latency, verify lock timeout behavior |

---

## Implementation Order

### Step 1: `fs.lua` — Add locking primitives

- Add `process_alive()` helper
- Add `M.lock(timeout_ms)` with `O_CREAT|O_EXCL`, PID writing, stale detection
- Add `M.unlock()` with PID ownership verification
- Add module-local `lock_held` reentrancy guard
- Add tests L1–L7

### Step 2: `gdrive.lua` — ETag support

- Modify `download()` to use `-D <tmpfile>` and parse ETag header
- Modify `upload()` to accept `etag` param, add `If-Match` header
- Modify `parse_response()` to detect HTTP 412 → return `'etag_mismatch'`
- Modify `push()` and `pull()` signatures to plumb ETag through
- Add tests E1–E5

### Step 3: `init.lua` — Protected sync cycle

- Remove `push_local()` function entirely
- Modify `M.sync()`:
  - Acquire lock at start
  - Release lock on every exit path (success, error, timeout)
  - Pass ETag from `pull` to `push`
  - Add retry loop on `'etag_mismatch'` (max `config.options.max_retries`)
- Modify `on_file_changed()` to call `M.sync()` instead of `push_local()`
- Modify `VimLeavePre` handler to call `M.sync()` instead of `push_local()`
- Add `retry_count` parameter to `M.sync()` (internal, not exposed in public API)
- Add tests S1–S6

### Step 4: `config.lua` — New options

- Add `lock_timeout_ms` (default: 10000)
- Add `max_retries` (default: 2)

### Step 5: Documentation

- Update `ARCHITECTURE.md` with concurrency section
- Update `README.md` with notes on multi-session safety
- Update inline docstrings in all modified functions

---

## File-by-File Change Summary

### `lua/dooing-sync/config.lua`

```
+ defaults.lock_timeout_ms = 10000
+ defaults.max_retries = 2
```

### `lua/dooing-sync/fs.lua`

```
+ local lock_held = false
+ local lock_path  (derived from config)
+ local function process_alive(pid)
+ function M.lock(timeout_ms)
+ function M.unlock()
  (all new code, no changes to existing functions)
```

### `lua/dooing-sync/gdrive.lua`

```
~ function M.download(token, file_id, callback)
    - Add -D <tmpfile> to curl command
    - Parse ETag from header file
    - Change callback signature: callback(content, etag, err)

~ function M.upload(token, file_id, content, etag, callback)
    - Add etag parameter
    - Add -H "If-Match: <etag>" when etag is non-nil

~ local function parse_response(stdout, stderr, code)
    - Detect error.code == 412 → return nil, 'etag_mismatch'

~ function M.pull(callback)
    - Propagate etag from download to callback
    - New signature: callback(content, etag, err)

~ function M.push(content, etag, callback)
    - Add etag parameter, forward to upload
```

### `lua/dooing-sync/init.lua`

```
- Remove local function push_local(on_done)

~ function M.sync(opts)
    - Add opts.retry_count (internal)
    - Acquire lock at start
    - Release lock on every exit path
    - Capture etag from pull
    - Pass etag to push
    - Retry on 'etag_mismatch' up to max_retries

~ local function on_file_changed()
    - Call M.sync() instead of push_local()

~ VimLeavePre autocmd
    - Call M.sync() instead of push_local()
```

### Test files

```
~ tests/test_fs.lua       + L1–L7 (lock tests)
~ tests/test_gdrive.lua   + E1–E5 (ETag tests)
~ tests/test_init.lua     + S1–S6 (protected sync tests)
```
