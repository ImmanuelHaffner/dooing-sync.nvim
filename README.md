# dooing-sync.nvim

Google Drive sync for [dooing](https://github.com/atiladefreitas/dooing) — synchronize your todo list across machines.

## Features

- **Automatic sync** — pulls on startup, pushes on every save, periodic background pulls
- **Three-way merge** — concurrent edits on different machines are merged intelligently at the field level
- **No format changes** — works with dooing's native JSON format, fully forward-compatible with upstream updates
- **Offline-safe** — if the network is unavailable, dooing works normally; sync resumes when connectivity returns
- **Minimal dependencies** — only requires `curl` (universally available) and a Google Cloud project with Drive API enabled
- **Multi-session safe** — file locking + ETag-based conditional push prevents data loss across concurrent Neovim sessions and machines
- **Graceful degradation** — missing credentials simply disable sync; dooing continues to work as usual

## Requirements

- **Neovim** ≥ 0.11
- **dooing** ≥ 2.0
- **curl** (available on virtually all systems)
- A Google Cloud project with the Drive API enabled (free, one-time setup)

## Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

Add `dooing-sync.nvim` as a dependency of dooing. The order matters — dooing-sync must
set up **before** dooing so the initial sync runs first.

```lua
{
    'atiladefreitas/dooing',
    dependencies = {
        'ImmanuelHaffner/dooing-sync.nvim',
    },
    config = function()
        -- Sync setup FIRST: pulls from Google Drive, merges, writes to save_path.
        require('dooing-sync').setup({
            gdrive_folder_id = 'YOUR_FOLDER_ID',  -- optional: store in a specific Drive folder
        })

        -- Dooing setup SECOND: loads the now-current JSON.
        require('dooing').setup({
            -- your dooing options
        })
    end,
}
```

For local development, use a `dir` dependency:

```lua
dependencies = {
    { dir = '~/.local/share/nvim/lazy/dooing-sync.nvim' },
},
```

## Google Drive Setup (One-Time)

### 1. Create a Google Cloud Project

1. Go to [console.cloud.google.com](https://console.cloud.google.com/)
2. Create a new project (e.g. `dooing-sync`)
3. Enable the **Google Drive API** (APIs & Services → Library → search "Drive API" → Enable)

### 2. Configure OAuth Consent Screen

1. Go to **Google Auth platform → Branding**
2. Click **Get Started**, fill in app name (`dooing-sync`) and email
3. Set audience to **External**
4. Add your Google account as a **Test user** under **Google Auth platform → Audience**

### 3. Add the Drive File Scope

1. Go to **Google Auth platform → Data Access**
2. Click **Add or Remove Scopes**
3. Add `https://www.googleapis.com/auth/drive.file`
4. This scope only allows access to files the app creates — your other Drive files remain invisible

### 4. Create OAuth Credentials

1. Go to **Google Auth platform → Clients**
2. Click **Create Client** → **Desktop app** → name it `dooing-sync-neovim`
3. Copy the **Client ID** and **Client Secret**

### 5. Obtain a Refresh Token

Open this URL in your browser (replace `YOUR_CLIENT_ID`):

```
https://accounts.google.com/o/oauth2/v2/auth?client_id=YOUR_CLIENT_ID&redirect_uri=http://localhost:8085&response_type=code&scope=https://www.googleapis.com/auth/drive.file&access_type=offline&prompt=consent
```

After granting consent, the browser redirects to `http://localhost:8085/?code=XXXX`.
Copy the `code` parameter from the URL bar, then exchange it:

```bash
curl -s -X POST https://oauth2.googleapis.com/token \
  -d "code=PASTE_CODE_HERE" \
  -d "client_id=YOUR_CLIENT_ID" \
  -d "client_secret=YOUR_CLIENT_SECRET" \
  -d "redirect_uri=http://localhost:8085" \
  -d "grant_type=authorization_code" | python3 -m json.tool
```

Copy the `refresh_token` from the JSON response.

### 6. Store Credentials

Add these to your shell environment (e.g. `~/.secrets.zshenv`, `~/.bashrc`, etc.):

```bash
export DOOING_GDRIVE_CLIENT_ID="xxxx.apps.googleusercontent.com"
export DOOING_GDRIVE_CLIENT_SECRET="GOCSPX-xxxx"
export DOOING_GDRIVE_REFRESH_TOKEN="1//xxxx"
```

Restart your shell or source the file.

## Configuration

All options with their defaults:

```lua
require('dooing-sync').setup({
    -- Path to dooing's JSON file. Auto-detected from dooing's config if nil.
    save_path = nil,

    -- Where to store the base snapshot (last synced version).
    base_path = vim.fn.stdpath('data') .. '/dooing_sync_base.json',

    -- Google Drive file name.
    gdrive_filename = 'dooing_todos.json',

    -- Google Drive folder ID (nil = Drive root).
    -- Get this from the folder URL: https://drive.google.com/drive/folders/<ID>
    gdrive_folder_id = nil,

    -- Environment variable names for OAuth credentials.
    env = {
        client_id     = 'DOOING_GDRIVE_CLIENT_ID',
        client_secret = 'DOOING_GDRIVE_CLIENT_SECRET',
        refresh_token = 'DOOING_GDRIVE_REFRESH_TOKEN',
    },

    -- Sync behavior.
    sync = {
        pull_on_start = true,   -- pull from Drive on setup
        push_on_save  = true,   -- push after every dooing save
        pull_interval = 300,    -- periodic pull in seconds (0 = disabled)
    },

    -- Conflict resolution for true field-level conflicts.
    -- 'recent': prefer the item with the more recent timestamp
    -- 'local':  always prefer local version
    -- 'remote': always prefer remote version
    conflict_strategy = 'recent',

    -- Notification verbosity.
    -- 'all':     show every sync message (default)
    -- 'changes': only notify when data actually changed (or on warnings/errors)
    -- 'errors':  only show warnings and errors
    -- 'none':    suppress all notifications
    notify = 'all',

    -- Concurrency protection.
    lock_timeout_ms = 10000,  -- max time to wait for sync lock (0 = disable locking)
    max_retries = 2,          -- retry count on ETag mismatch (HTTP 412)

    -- Enable debug logging.
    debug = false,
})
```

## Commands

| Command | Description |
|---------|-------------|
| `:DooingSync` | Manual sync: pull → merge → push |
| `:DooingSyncStatus` | Show sync status, last sync time, and merge report |

## API

```lua
local dooing_sync = require('dooing-sync')

-- Get sync status (for statusline integration, etc.)
local status = dooing_sync.status()
-- status.enabled    (boolean)
-- status.last_sync  (integer timestamp or nil)
-- status.last_report (table with merge statistics)

-- Trigger a manual sync
dooing_sync.sync()

-- Teardown (stop watcher, timers, remove commands)
dooing_sync.teardown()
```

## Multi-Session Safety

dooing-sync is safe to use with multiple Neovim instances on the same machine and across
multiple machines:

- **Same machine**: A lockfile serializes sync cycles across sessions. If one session is
  syncing, others wait (up to `lock_timeout_ms`) or skip. Stale locks from crashed
  sessions are automatically detected and removed.
- **Multiple machines**: ETag-based conditional push prevents lost updates. If another
  machine pushed since we last pulled, the push fails and the sync retries with fresh data.
- **Every push is a full sync**: There are no blind pushes. Every write to Google Drive
  goes through the three-way merge, ensuring remote changes are never silently overwritten.

## How It Works

dooing stores todos in a JSON file. dooing-sync synchronizes this file with Google Drive
using a three-way merge:

1. **Base snapshot** — the last successfully synced version (stored locally)
2. **Local** — the current file on disk
3. **Remote** — the file on Google Drive

Each todo has a unique `id` field, used as the merge key. Changes are detected and merged
at the individual field level, so editing the text of a todo on one machine while marking
it done on another produces the correct result.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the full technical design.

## FAQ

### What happens if I lose network connectivity?

Dooing works normally with its local file. Sync operations silently skip. Next time you
have connectivity, `:DooingSync` or the next automatic sync will reconcile changes.

### What Google Drive permissions does this need?

Only `drive.file` — the most restrictive Drive scope. The plugin can **only** access files
it created. It cannot see, list, or modify any other files on your Drive.

### Does this modify dooing's data format?

No. The plugin reads and writes dooing's native JSON format without any modifications.
Unknown fields from future dooing versions are preserved through merges.

### What if the same todo is edited on two machines?

Fields are merged individually. If different fields were changed (e.g. text on one machine,
done status on another), both changes are kept. If the same field was changed to different
values, the `conflict_strategy` setting determines the winner (default: most recent).

### Can I run multiple Neovim sessions on the same machine?

Yes. A lockfile serializes sync operations so sessions don't corrupt each other's data.
If a session crashes mid-sync, the stale lock is automatically detected and cleaned up by
the next session.

## Running Tests

```bash
cd ~/.local/share/nvim/lazy/dooing-sync.nvim

# Unit tests (no network required)
nvim --headless -l tests/test_config.lua
nvim --headless -l tests/test_fs.lua
nvim --headless -l tests/test_fs_lock.lua
nvim --headless -l tests/test_merge.lua
nvim --headless -l tests/test_gdrive_etag.lua
nvim --headless -l tests/test_init_sync.lua

# Integration tests (requires OAuth credentials in environment)
nvim --headless -l tests/test_gdrive.lua
nvim --headless -l tests/test_init.lua

# Run all
for f in tests/test_*.lua; do nvim --headless -l "$f"; done
```

## License

MIT
