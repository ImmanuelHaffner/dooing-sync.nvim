# dooing-sync.nvim Concurrency Work

## Status
- Created `CONCURRENCY.md` — comprehensive implementation plan for local locking + ETag-based conditional push.
- **Part 1 DONE**: Local file locking in `fs.lua` + config options + 18 tests in `test_fs_lock.lua`.
- **Part 2 DONE**: ETag support in `gdrive.lua` + 16 tests in `test_gdrive_etag.lua`. All 78 tests pass.
  - `download()` captures ETag via `-D <tmpfile>`, callback is now `(content, etag, err)`
  - `upload()` accepts optional etag, sends `If-Match` header
  - `parse_response()` detects HTTP 412 → `'etag_mismatch'`
  - `pull()` propagates etag: callback is `(content, etag, err)`
  - `push()` accepts optional etag, forwards to upload
  - Backward compat: old `push(content, callback)` / `upload(..., callback)` still work
  - Also fixed a bug in `download()` error handling (dead code for API error detection)
- **Part 3 DONE**: Protected sync cycle in `init.lua` + 9 tests in `test_init_sync.lua`. All 87 tests pass.
  - Removed `push_local()` — all pushes go through full sync cycle
  - `M.sync()` wraps in lock/unlock with `finish()` helper for every exit path
  - `sync_in_progress` guard prevents reentrant syncs from file watcher
  - ETag from `pull` forwarded to `push` with `If-Match` header
  - Retry on `etag_mismatch` up to `max_retries`, releasing lock between retries
  - `fs.save_base()` moved to AFTER successful push (correctness fix)
  - VimLeavePre and on_file_changed both use `M.sync()` now
  - test_init.lua updated for new pull callback signature
- **Docs DONE**: ARCHITECTURE.md and README.md updated with concurrency section.
- All implementation complete. 87 unit tests pass, integration tests (test_gdrive.lua, test_init.lua) require credentials.
- **Async lock fix**: `fs.lock()` was blocking the main thread (busy-wait with `vim.wait`), causing startup hang via `sync_on_open`.
  - Added `fs.lock_async(timeout_ms, callback)` using `vim.uv.new_timer()` for non-blocking polling.
  - `M.sync()` now uses `lock_async` by default; `opts.blocking = true` uses the old synchronous `lock()` (for VimLeavePre only).
  - `sync_in_progress` is set eagerly before `lock_async` to prevent reentrant syncs.
  - 7 new tests (A1–A7) in `test_fs_lock.lua`, S4 test updated for async timing. All 99 unit tests pass.
  - ARCHITECTURE.md and README.md updated: startup sync documented as non-blocking, VimLeavePre as only blocking path.

## Integration test sandboxing (DONE)
- Both `test_gdrive.lua` and `test_init.lua` now use `gdrive_filename = 'dooing_todos_TEST.json'`
- Added `M.delete_file()` to `gdrive.lua` for cleanup
- Added `reset_cached_file_id()` and `get_cached_file_id()` to `gdrive._testing`
- Tests clean up the TEST file from Drive after running
- `test_init.lua`: fires `UIEnter` autocmd manually in headless mode to start sync engine
- `do_sync()` has a guard for teardown-during-async-lock (nil save_path check)
- File watcher test in `test_init.lua` is timing-sensitive (flaky) due to macOS FSEvents + atomic write interaction — pre-existing issue

## ETag → Version migration (DONE)
- Google Drive v3 `alt=media` endpoint does NOT return ETag headers
- Google Drive v3 upload endpoint IGNORES `If-Match` headers (no 412 support)
- Replaced ETag-based approach with **version-based** optimistic concurrency:
  - `download()`: fetches content + version in parallel (two API calls)
  - `upload()`: pre-flight version check before uploading, returns `version_mismatch` on conflict
  - `pull()`/`push()`: pass `version` (string) instead of `etag`
- `parse_etag_from_headers()` removed, replaced with `fetch_version()`
- All tests updated: `etag` → `version`, `etag_mismatch` → `version_mismatch`
- 97 unit tests + 5 integration tests pass

## Key Decisions
- Local lockfile (O_CREAT|O_EXCL + PID-based stale detection) for same-machine serialization
- ETag conditional push (If-Match header) for cross-machine safety on Google Drive
- Eliminate `push_local` — replace with full `M.sync()` everywhere
- Lock covers the entire sync cycle including network I/O
- Retry on HTTP 412 up to max_retries (default 2)

## Implementation Order
1. `fs.lua` — lock/unlock primitives
2. `gdrive.lua` — ETag capture on download, If-Match on upload, 412 detection
3. `init.lua` — protected sync cycle, remove push_local
4. `config.lua` — new options (lock_timeout_ms, max_retries)
5. Documentation updates
