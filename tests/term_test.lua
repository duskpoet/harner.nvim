local t = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/helper.lua")
local check = t.check
vim.o.columns = 160; vim.o.lines = 50
-- Offline test of term.lua against a fake `agtermctl` that logs its arguments
-- and fake `claude` scripts: no backend outside agterm, status over a run,
-- confirm -> blocked, cancel -> idle, the hook takeover in the runner's env,
-- and the synchronous reset on exit.
local tmp = vim.fn.tempname() .. "-term"
vim.fn.mkdir(tmp, "p")
local log = tmp .. "/ctl.log"
local ctl = tmp .. "/agtermctl"
vim.fn.writefile({ "#!/bin/sh", 'printf "%s\\n" "$*" >> ' .. log }, ctl)
vim.fn.setfperm(ctl, "rwxr-xr-x")

local result = vim.json.encode({ type = "result", subtype = "success", is_error = false, duration_api_ms = 1, total_cost_usd = 0.01, result = "ok" })
local function script(name, lines)
  local path = tmp .. "/" .. name
  vim.fn.writefile(vim.list_extend({ "#!/bin/sh", "cat >/dev/null" }, lines), path)
  vim.fn.setfperm(path, "rwxr-xr-x")
  return path
end
local quick = script("claude-quick", {
  'printf "%s" "[$AGTERM_SESSION_ID]" > ' .. tmp .. "/env",
  "sleep 0.3",
  "echo '" .. result .. "'",
})
-- exec: a cancel must kill the sleep itself, an orphan would hold the stdout pipe open
local slow = script("claude-slow", { "exec sleep 30" })

local function calls()
  return vim.fn.filereadable(log) == 1 and vim.fn.readfile(log) or {}
end
local function seen(text)
  for i, line in ipairs(calls()) do
    if line:find(text, 1, true) then return i end
  end
end
local function wait_for(text)
  return vim.wait(3000, function() return seen(text) ~= nil end, 20)
end
local function settle()
  vim.wait(200, function() return false end, 20)
end

for _, k in ipairs({ "AGTERM_ENABLED", "AGTERM_SESSION_ID", "AGTERM_SOCKET", "AGTERM_PANE", "AGTERM_PANE_ID" }) do
  vim.env[k] = nil
end
require("harner").setup({ claude_cmd = quick, terminal = { backend = "auto", agtermctl = ctl }, auto = { enabled = false } })
local term = require("harner.term")
local chat = require("harner.chat")

-- 1. not inside agterm: no backend, nothing called, env untouched
term.started()
term.finished()
settle()
check(#calls() == 0, "no backend outside agterm")
check(next(term.env()) == nil, "no env override outside agterm")

-- 2. backend = false wins over the environment
vim.env.AGTERM_ENABLED = "1"
vim.env.AGTERM_SESSION_ID = "SID-1"
vim.env.AGTERM_SOCKET = tmp .. "/sock"
vim.env.AGTERM_PANE = "left"
vim.env.AGTERM_PANE_ID = "PANE-1"
require("harner").config.terminal.backend = false
term.reset()
term.finished()
settle()
check(#calls() == 0 and next(term.env()) == nil, "backend = false does nothing")
require("harner").config.terminal.backend = "auto"
term.reset()

-- 3. a run: active, then completed; info line set and cleared; hooks silenced
chat.open()
local c = chat.chats[chat.current]
local buf = c.buf
local function send(text, b)
  b = b or chat.show(c, false) and c.buf -- a hidden chat's buffer may have been rebuilt
  local n = vim.api.nvim_buf_line_count(b)
  vim.api.nvim_buf_set_lines(b, n - 1, n, false, { text })
  check(chat.send(b), "send accepted: " .. text)
end
send("hello")
check(wait_for("session status active --blink --target SID-1 --socket " .. tmp .. "/sock --pane left --pane-id PANE-1"), "active sent with target, socket and pane")
check(wait_for("session info harner #1 thinking… --hide-after 45 --target SID-1"), "info line names the chat state")
check(vim.wait(5000, function() return c.run == nil end, 20), "run finished")
check(wait_for("session status completed --auto-reset"), "completed sent after the run")
check(wait_for("session info --clear"), "info line cleared after the run")
check(seen("session status active") < seen("session status completed"), "active before completed")
check(vim.fn.readfile(tmp .. "/env")[1] == "[]", "claude runs with an empty AGTERM_SESSION_ID")
check(vim.env.AGTERM_SESSION_ID == "SID-1", "nvim's own environment untouched")

-- 4. a second completion is reported again (the terminal reset the first on visit)
vim.fn.delete(log)
send("again")
check(vim.wait(5000, function() return c.run == nil end, 20), "second run finished")
check(wait_for("session status completed"), "completed sent again")

-- 4b. a failed run (error result) gets its own glyph
vim.fn.delete(log)
local failing = script("claude-failing", {
  "echo '" .. vim.json.encode({ type = "result", subtype = "error", is_error = true, duration_api_ms = 1, result = "boom" }) .. "'",
})
require("harner").config.claude_cmd = failing
send("fail")
check(vim.wait(5000, function() return c.run == nil end, 20), "failing run finished")
check(wait_for("session status completed --auto-reset --shape triangle"), "failed run marked with a triangle")
require("harner").config.claude_cmd = quick
vim.fn.delete(log)
send("recover")
check(vim.wait(5000, function() return c.run == nil end, 20), "next run finished")
check(wait_for("session status completed --auto-reset --target"), "a later success is a plain completed")

-- 5. a confirm waiting: blocked, back to the previous state when answered
vim.fn.delete(log)
local confirm = require("harner.confirm")
local answer
confirm.ask = function(_, cb)
  answer = cb
  return function(choice) cb(choice) end
end
local tools = require("harner.tools")
local res = tools.call("ask_user", { question = "Which?", choices = { "a", "b" } })
check(type(res) == "table" and res.pending ~= nil, "ask_user is pending")
check(wait_for("session status blocked --blink"), "blocked while a confirm waits")
check(wait_for("session info harner: waiting for you"), "info says waiting")
answer("item", 1)
check(wait_for("session status completed"), "status restored after the answer")

-- 6. cancel: idle, not completed
vim.fn.delete(log)
require("harner").config.claude_cmd = slow
send("long")
check(wait_for("session status active"), "active for the long run")
chat.cancel(buf)
check(vim.wait(5000, function() return c.run == nil end, 20), "cancelled run ended")
check(wait_for("session status idle"), "idle after cancel")
settle()
check(not seen("session status completed"), "cancel is not reported as completed")

-- 7. two chats overlap: one finishing does not end "active"; its "completed"
-- shows once the other is gone, even though that one was cancelled
vim.fn.delete(log)
send("first of two")
chat.new()
local c2 = chat.chats[chat.current]
check(c2.id ~= c.id, "second chat created")
require("harner").config.claude_cmd = quick
send("second of two", c2.buf)
check(wait_for("session info harner: 2 chats running"), "info counts the running chats")
check(vim.wait(5000, function() return c2.run == nil end, 20), "second chat finished")
check(wait_for("session info harner #1"), "info back to the chat still running")
settle()
check(not seen("session status completed") and not seen("session status idle"), "still active while the first chat runs")
chat.show(c, false)
chat.cancel(c.buf)
check(vim.wait(5000, function() return c.run == nil end, 20), "first chat cancelled")
check(wait_for("session status completed"), "the finished chat's completed shows after the other ends")
require("harner").config.claude_cmd = slow

-- 8. leaving nvim mid-run resets synchronously
vim.fn.delete(log)
send("leaving")
check(wait_for("session status active"), "active again")
settle() -- the info line may be unchanged since the last run and not re-sent
term.leave()
check(seen("session status idle") ~= nil and seen("session info --clear") ~= nil, "leave resets status and info at once")
chat.cancel(c.buf)
vim.wait(5000, function() return c.run == nil end, 20)

vim.fn.delete(tmp, "rf")
t.finish()
