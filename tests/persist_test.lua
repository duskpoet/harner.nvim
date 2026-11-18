-- Saved chats: written per cwd, restored through the picker, capped, and not
-- offered twice. Offline: no claude is started.
local t = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/helper.lua")
local check = t.check

local chat = require("harner.chat")
local store = require("harner.store")
local cwd = vim.fn.getcwd()

check(#store.list() == 0, "nothing saved at first")

-- a chat that has not run yet is not saved
local c1 = chat.ensure()
chat.save(c1)
check(#store.list() == 0, "a chat that never ran is not saved")

-- one whose run failed without a result left no session to resume
c1.started, c1.cwd, c1.title = true, cwd, "first question"
chat.save(c1)
check(#store.list() == 0, "a chat without a result is not saved")

-- after a run with a result it is, with its transcript
c1.resumable = true
vim.api.nvim_buf_set_lines(c1.buf, 0, -1, false, { "## You", "", "first question", "", "## Claude", "", "answer" })
chat.save(c1)
local saved = store.list()
check(#saved == 1 and saved[1].session_id == c1.session_id, "saved after a run")
check(saved[1].lines[7] == "answer", "transcript saved")
check(#store.list(cwd .. "/elsewhere") == 0, "other projects do not see it")

-- saving it again unchanged keeps its timestamp (restored chats only looked at)
local before = store.list()[1].updated
vim.uv.sleep(1100)
chat.save(c1)
check(store.list()[1].updated == before, "unchanged chat keeps its timestamp")
vim.api.nvim_buf_set_lines(c1.buf, -1, -1, false, { "draft" })
chat.save(c1)
check(store.list()[1].updated > before and store.list()[1].lines[8] == "draft", "a changed chat is updated")
vim.api.nvim_buf_set_lines(c1.buf, 7, 8, false, {})
chat.save(c1)
check(#store.list() == 1, "still one entry")

-- a run in flight is skipped
c1.run = {}
vim.api.nvim_buf_set_lines(c1.buf, 0, -1, false, { "partial" })
chat.save(c1)
check(store.list()[1].lines[1] == "## You", "mid-run transcript not saved")
c1.run = nil

-- the file is private
local mode = vim.uv.fs_stat(store.path()).mode % 512
check(mode == 384, "chats file is 0600 (got " .. string.format("%o", mode) .. ")")

-- "restart": no chats in memory; the saved one is offered and restored
vim.api.nvim_buf_set_lines(c1.buf, 0, -1, false, saved[1].lines)
chat.chats, chat.current = {}, nil
local offered
vim.ui.select = function(items, opts, cb)
	offered = { items = items, label = opts.format_item(items[1]) }
	cb(items[1])
end
chat.pick()
check(offered and #offered.items == 1, "saved chat offered after restart")
check(offered.label:find("^saved ") and offered.label:find("first question"), "saved label: " .. tostring(offered.label))
local restored = chat.chats[chat.current]
check(restored and restored.session_id == c1.session_id, "restored with the same session id")
check(restored.started == true, "restored chat resumes (started)")
local lines = vim.api.nvim_buf_get_lines(restored.buf, 0, -1, false)
check(lines[3] == "first question" and lines[7] == "answer", "transcript restored")

-- an open chat is not offered again
offered = nil
chat.pick()
check(offered and #offered.items == 1 and offered.items[1].id == restored.id, "open chat listed once, no saved copy")

-- cap per project, newest kept
require("harner").config.persist.max = 3
for i = 1, 5 do
	store.save(cwd, { session_id = "s" .. i, title = "t" .. i, lines = { "x" } })
end
check(#store.list() == 3, "capped at max (got " .. #store.list() .. ")")

-- disabled: nothing is read or written
require("harner").config.persist.enabled = false
store.save(cwd, { session_id = "off", lines = { "x" } })
check(#store.list() == 0, "disabled: list is empty")
require("harner").config.persist.enabled = true
check(
	#vim.tbl_filter(function(e)
		return e.session_id == "off"
	end, store.list()) == 0,
	"disabled: nothing written"
)

-- a damaged file is ignored, not an error
local f = io.open(store.path(), "w")
f:write("{not json")
f:close()
check(#store.list() == 0, "damaged file reads as empty")
store.save(cwd, { session_id = "again", lines = { "x" } })
check(#store.list() == 1, "save recovers from a damaged file")

t.finish()
