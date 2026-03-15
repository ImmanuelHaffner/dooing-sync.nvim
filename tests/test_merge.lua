--- Tests for dooing-sync.nvim merge engine.
--- Run with:  nvim --headless -l tests/test_merge.lua
---   (from the plugin root directory)

-- Add plugin to Lua path.
vim.opt.rtp:prepend('.')

local config = require('dooing-sync.config')
config.setup({ debug = false })

local merge = require('dooing-sync.merge')

local pass_count = 0
local fail_count = 0

--- Print to stdout, flushed (for nvim -l).
--- @param s string
local function puts(s)
    io.stdout:write(s .. '\n')
    io.stdout:flush()
end

--- Simple test runner.
--- @param name string
--- @param fn function
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        pass_count = pass_count + 1
        puts('  ✓ ' .. name)
    else
        fail_count = fail_count + 1
        puts('  ✗ ' .. name)
        puts('    ' .. tostring(err))
    end
end

-------------------------------------------------------------------------------
puts('merge.merge()')
-------------------------------------------------------------------------------

test('added locally → kept', function()
    local merged, report = merge.merge({}, {
        { id = 'a', text = 'New local', done = false, created_at = 100 },
    }, {})
    assert(#merged == 1)
    assert(merged[1].id == 'a')
    assert(report.added_local == 1)
    assert(report.added_remote == 0)
end)

test('added remotely → kept', function()
    local merged, report = merge.merge({}, {}, {
        { id = 'b', text = 'New remote', done = false, created_at = 200 },
    })
    assert(#merged == 1)
    assert(merged[1].id == 'b')
    assert(report.added_remote == 1)
end)

test('added on both sides → both kept', function()
    local merged, report = merge.merge({}, {
        { id = 'a', text = 'Local', done = false, created_at = 100 },
    }, {
        { id = 'b', text = 'Remote', done = false, created_at = 200 },
    })
    assert(#merged == 2)
    assert(report.added_local == 1)
    assert(report.added_remote == 1)
end)

test('deleted locally → deleted', function()
    local base = {
        { id = 'x', text = 'Gone', done = false, created_at = 100 },
    }
    local merged, report = merge.merge(base, {}, {
        { id = 'x', text = 'Gone', done = false, created_at = 100 },
    })
    assert(#merged == 0)
    assert(report.deleted == 1)
end)

test('deleted remotely → deleted', function()
    local base = {
        { id = 'x', text = 'Gone', done = false, created_at = 100 },
    }
    local merged, report = merge.merge(base, {
        { id = 'x', text = 'Gone', done = false, created_at = 100 },
    }, {})
    assert(#merged == 0)
    assert(report.deleted == 1)
end)

test('deleted on both sides → deleted', function()
    local base = {
        { id = 'x', text = 'Gone', done = false, created_at = 100 },
    }
    local merged, report = merge.merge(base, {}, {})
    assert(#merged == 0)
    assert(report.deleted == 1)
end)

test('remote-only modification → take remote', function()
    local base = {
        { id = 'x', text = 'Original', done = false, created_at = 100 },
    }
    local merged, report = merge.merge(base, {
        { id = 'x', text = 'Original', done = false, created_at = 100 },
    }, {
        { id = 'x', text = 'Changed', done = false, created_at = 100 },
    })
    assert(merged[1].text == 'Changed')
    assert(report.modified == 1)
end)

test('local-only modification → take local', function()
    local base = {
        { id = 'x', text = 'Original', done = false, created_at = 100 },
    }
    local merged, report = merge.merge(base, {
        { id = 'x', text = 'Changed', done = false, created_at = 100 },
    }, {
        { id = 'x', text = 'Original', done = false, created_at = 100 },
    })
    assert(merged[1].text == 'Changed')
    assert(report.modified == 1)
end)

test('both modified identically → keep as-is', function()
    local base = {
        { id = 'x', text = 'Original', done = false, created_at = 100 },
    }
    local merged, report = merge.merge(base, {
        { id = 'x', text = 'Same edit', done = false, created_at = 100 },
    }, {
        { id = 'x', text = 'Same edit', done = false, created_at = 100 },
    })
    assert(merged[1].text == 'Same edit')
    assert(report.modified == 1)
    assert(report.conflicts == 0)
end)

test('field-level merge: different fields changed → both applied', function()
    local base = {
        { id = 'x', text = 'Original', done = false, notes = '', created_at = 100 },
    }
    local merged, report = merge.merge(base, {
        { id = 'x', text = 'Edited locally', done = false, notes = '', created_at = 100 },
    }, {
        { id = 'x', text = 'Original', done = true, completed_at = 999, notes = '', created_at = 100 },
    })
    assert(merged[1].text == 'Edited locally', 'text from local')
    assert(merged[1].done == true, 'done from remote')
    assert(merged[1].completed_at == 999, 'completed_at from remote')
    assert(report.conflicts == 0, 'no true conflicts')
end)

test('field-level conflict: same field changed differently → recent wins', function()
    config.setup({ conflict_strategy = 'recent', debug = false })
    local base = {
        { id = 'x', text = 'Original', done = false, created_at = 100 },
    }
    local merged, report = merge.merge(base, {
        { id = 'x', text = 'Local edit', done = false, created_at = 100 },
    }, {
        { id = 'x', text = 'Remote edit', done = false, created_at = 200 },
    })
    assert(merged[1].text == 'Remote edit', 'remote has higher created_at')
    assert(report.conflicts == 1)
end)

test('field-level conflict: strategy=local → local wins', function()
    config.setup({ conflict_strategy = 'local', debug = false })
    local base = {
        { id = 'x', text = 'Original', done = false, created_at = 100 },
    }
    local merged, report = merge.merge(base, {
        { id = 'x', text = 'Local edit', done = false, created_at = 100 },
    }, {
        { id = 'x', text = 'Remote edit', done = false, created_at = 200 },
    })
    assert(merged[1].text == 'Local edit')
    assert(report.conflicts == 1)
    config.setup({ conflict_strategy = 'recent', debug = false })
end)

test('field-level conflict: strategy=remote → remote wins', function()
    config.setup({ conflict_strategy = 'remote', debug = false })
    local base = {
        { id = 'x', text = 'Original', done = false, created_at = 100 },
    }
    local merged, report = merge.merge(base, {
        { id = 'x', text = 'Local edit', done = false, created_at = 100 },
    }, {
        { id = 'x', text = 'Remote edit', done = false, created_at = 100 },
    })
    assert(merged[1].text == 'Remote edit')
    assert(report.conflicts == 1)
    config.setup({ conflict_strategy = 'recent', debug = false })
end)

test('first sync (no base): union with dedup', function()
    local merged, report = merge.merge(nil, {
        { id = 'shared', text = 'Same', done = false, created_at = 100 },
        { id = 'only_local', text = 'Local', done = false, created_at = 101 },
    }, {
        { id = 'shared', text = 'Same', done = false, created_at = 100 },
        { id = 'only_remote', text = 'Remote', done = false, created_at = 102 },
    })
    assert(#merged == 3, 'expected 3, got ' .. #merged)
end)

test('noop: all identical → is_noop=true', function()
    local item = { id = 'x', text = 'Same', done = false, created_at = 100 }
    local merged, report = merge.merge({ item }, { item }, { item })
    assert(report.is_noop == true)
    assert(report.unchanged == 1)
end)

test('not noop: remote added item', function()
    local item = { id = 'x', text = 'Same', done = false, created_at = 100 }
    local merged, report = merge.merge({ item }, { item }, {
        item,
        { id = 'y', text = 'New', done = false, created_at = 200 },
    })
    assert(report.is_noop == false)
    assert(#merged == 2)
end)

test('unknown fields are preserved (forward compatibility)', function()
    local base = {
        { id = 'x', text = 'Hello', done = false, created_at = 100, future_field = 'base' },
    }
    local merged, _ = merge.merge(base, {
        { id = 'x', text = 'Hello', done = false, created_at = 100, future_field = 'base' },
    }, {
        { id = 'x', text = 'Hello', done = true, completed_at = 500, created_at = 100,
          future_field = 'base', another_new = 42 },
    })
    assert(merged[1].future_field == 'base', 'future_field preserved')
    assert(merged[1].another_new == 42, 'another_new from remote')
end)

test('multiple items: mixed operations', function()
    local base = {
        { id = 'keep',     text = 'Unchanged',   done = false, created_at = 100 },
        { id = 'del_loc',  text = 'Del locally',  done = false, created_at = 101 },
        { id = 'del_rem',  text = 'Del remotely', done = false, created_at = 102 },
        { id = 'mod_rem',  text = 'Will change',  done = false, created_at = 103 },
    }
    local local_ = {
        { id = 'keep',     text = 'Unchanged',   done = false, created_at = 100 },
        -- del_loc removed
        { id = 'del_rem',  text = 'Del remotely', done = false, created_at = 102 },
        { id = 'mod_rem',  text = 'Will change',  done = false, created_at = 103 },
        { id = 'add_loc',  text = 'Added locally', done = false, created_at = 200 },
    }
    local remote = {
        { id = 'keep',     text = 'Unchanged',   done = false, created_at = 100 },
        { id = 'del_loc',  text = 'Del locally',  done = false, created_at = 101 },
        -- del_rem removed
        { id = 'mod_rem',  text = 'Changed remotely', done = false, created_at = 103 },
        { id = 'add_rem',  text = 'Added remotely', done = false, created_at = 201 },
    }
    local merged, report = merge.merge(base, local_, remote)
    -- Expected: keep, mod_rem (changed), add_loc, add_rem = 4 items
    assert(#merged == 4, 'expected 4, got ' .. #merged)
    assert(report.deleted == 2)
    assert(report.added_local == 1)
    assert(report.added_remote == 1)
    assert(report.modified == 1)
    assert(report.unchanged == 1)

    local by_id = {}
    for _, item in ipairs(merged) do by_id[item.id] = item end
    assert(by_id['keep'] ~= nil, 'keep present')
    assert(by_id['mod_rem'].text == 'Changed remotely', 'mod_rem updated')
    assert(by_id['add_loc'] ~= nil, 'add_loc present')
    assert(by_id['add_rem'] ~= nil, 'add_rem present')
    assert(by_id['del_loc'] == nil, 'del_loc gone')
    assert(by_id['del_rem'] == nil, 'del_rem gone')
end)

-------------------------------------------------------------------------------
puts('\nvim.NIL / serialization determinism')
-------------------------------------------------------------------------------

test('vim.NIL fields treated as absent (noop)', function()
    local base = {
        { id = 'x', text = 'test', done = false, created_at = 100, notes = vim.NIL },
    }
    local local_ = {
        { id = 'x', text = 'test', done = false, created_at = 100 },
    }
    local remote = {
        { id = 'x', text = 'test', done = false, created_at = 100, notes = vim.NIL },
    }
    local merged, report = merge.merge(base, local_, remote)
    assert(report.is_noop == true, 'expected noop')
    assert(report.unchanged == 1, 'expected unchanged=1, got ' .. report.unchanged)
    assert(report.modified == 0, 'expected modified=0, got ' .. report.modified)
end)

test('multiple vim.NIL fields across all versions = noop', function()
    local base = {
        { id = 'x', text = 'test', done = false, created_at = 100,
          notes = vim.NIL, category = vim.NIL },
    }
    local local_ = {
        { id = 'x', text = 'test', done = false, created_at = 100 },
    }
    local remote = {
        { id = 'x', text = 'test', done = false, created_at = 100,
          category = vim.NIL },
    }
    local merged, report = merge.merge(base, local_, remote)
    assert(report.is_noop == true, 'expected noop')
    assert(report.unchanged == 1)
end)

test('stable_encode produces deterministic output regardless of table creation order', function()
    local t1 = { id = 'x', text = 'hello', done = false, created_at = 100 }
    local t2 = { created_at = 100, done = false, id = 'x', text = 'hello' }
    assert(merge.stable_encode(t1) == merge.stable_encode(t2),
        'same data in different insertion order must serialize identically')
end)

test('stable_encode strips vim.NIL from output', function()
    local t1 = { id = 'x', text = 'hello', notes = vim.NIL }
    local t2 = { id = 'x', text = 'hello' }
    assert(merge.stable_encode(t1) == merge.stable_encode(t2),
        'vim.NIL field must not appear in serialized output')
end)

test('stable_encode handles nested tables and arrays', function()
    local t = { id = 'x', priorities = { 1, 2, 3 }, meta = { a = 'b', c = 'd' } }
    local encoded = merge.stable_encode(t)
    -- Should be deterministic on repeated calls.
    assert(encoded == merge.stable_encode(t), 'repeated calls must be identical')
    -- Nested object keys should be sorted.
    assert(encoded:find('"a":"b"'), 'nested object keys should be sorted')
end)

-------------------------------------------------------------------------------
puts('')
-------------------------------------------------------------------------------

local total = pass_count + fail_count
if fail_count == 0 then
    puts(string.format('All %d tests passed ✓', total))
else
    puts(string.format('%d/%d tests passed, %d FAILED ✗', pass_count, total, fail_count))
    os.exit(1)
end
