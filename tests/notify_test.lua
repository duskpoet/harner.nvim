local t = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/helper.lua")
local check = t.check
vim.o.columns = 160; vim.o.lines = 50
-- Offline test of term.lua's notifications: the escape per terminal, the
-- focus gate, events and their filter, tmux passthrough, silence while a
-- status backend is active. `term.send` is replaced, nothing reaches a tty.
local ENV = {
  "TERM_PROGRAM", "KITTY_WINDOW_ID", "GHOSTTY_RESOURCES_DIR", "WEZTERM_PANE", "ITERM_SESSION_ID",
  "LC_TERMINAL", "TMUX", "AGTERM_ENABLED", "AGTERM_SESSION_ID", "AGTERM_SOCKET", "AGTERM_PANE", "AGTERM_PANE_ID",
}
local function env(vars)
  for _, k in ipairs(ENV) do vim.env[k] = nil end
  vim.env.TERM = "dumb"
  for k, v in pairs(vars or {}) do vim.env[k] = v end
end
env()

require("harner").setup({ auto = { enabled = false } })
local cfg = require("harner").config.terminal
local term = require("harner.term")
local real_send = term.send
local out = {}
term.send = function(data) table.insert(out, data) end
local function settle()
  vim.wait(100, function() return false end, 10)
end
---Everything sent by `fn` and the tick after it.
local function sent(fn)
  out = {}
  fn()
  settle()
  return table.concat(out)
end
local function done() term.finished(false, false) end
local function blur() vim.api.nvim_exec_autocmds("FocusLost", {}) end
local function focus() vim.api.nvim_exec_autocmds("FocusGained", {}) end

local ESC = "\027"
local ST = ESC .. "\\"
local title = "harner · " .. vim.fn.fnamemodify(vim.fn.getcwd(), ":t")

-- 1. opt-in, and the focus gate
check(cfg.notify.enabled == false and cfg.notify.when == "unfocused" and cfg.notify.protocol == "auto", "notify defaults")
blur()
check(sent(done) == "", "off by default")
cfg.notify.enabled = true
focus()
check(sent(done) == "", "nothing while the terminal is focused")
blur()
check(sent(done) == "\007", "unknown terminal, unfocused: a bell")
focus()
check(sent(done) == "", "quiet again after FocusGained")
cfg.notify.when = "always"
check(sent(done) == "\007", "when = always ignores focus")
cfg.notify.when = "unfocused"
blur()

-- 2. the escape per terminal
env({ KITTY_WINDOW_ID = "1", TERM = "xterm-kitty" })
check(sent(done) == ESC .. "]99;i=harner:d=0;" .. title .. ST .. ESC .. "]99;i=harner:p=body;finished" .. ST, "kitty: OSC 99 title + body")
env({ TERM_PROGRAM = "ghostty", TERM = "xterm-ghostty" })
check(sent(done) == ESC .. "]9;" .. title .. ": finished" .. ST, "ghostty: OSC 9")
env({ GHOSTTY_RESOURCES_DIR = "/x", KITTY_WINDOW_ID = "1" })
check(sent(done):find("]9;", 1, true) ~= nil, "ghostty wins over a stray KITTY_WINDOW_ID")
env({ TERM_PROGRAM = "WezTerm" })
check(sent(done):find("]9;", 1, true) ~= nil, "WezTerm: OSC 9")
env({ LC_TERMINAL = "iTerm2", TERM = "xterm-256color" })
check(sent(done):find("]9;", 1, true) ~= nil, "iTerm2 over ssh (LC_TERMINAL): OSC 9")
env({ TERM = "xterm-kitty" })
check(sent(done):find("]9;", 1, true) ~= nil, "TERM alone only selects OSC 9")
env({ TERM = "foot-extra" })
check(sent(done) == ESC .. "]777;notify;" .. title .. ";finished" .. ST, "foot: OSC 777")
env({ TERM_PROGRAM = "agterm", TERM = "xterm-kitty" })
check(sent(done):find("]9;", 1, true) ~= nil, "agterm without its control variables: OSC 9")

-- 3. a forced protocol, and an unknown one
env()
cfg.notify.protocol = "osc777"
check(sent(done):find("]777;notify;", 1, true) ~= nil, "protocol forced")
cfg.notify.protocol = "nope"
check(sent(done) == "", "unknown protocol sends nothing")
cfg.notify.protocol = "auto"

-- 4. tmux passthrough (not for the bell)
env({ TMUX = "/tmp/tmux-1/default,1,0" })
check(sent(done) == "\007", "bell goes through tmux as it is")
env({ TMUX = "/tmp/tmux-1/default,1,0", TERM_PROGRAM = "ghostty" })
check(sent(done) == ESC .. "Ptmux;" .. ESC .. ESC .. "]9;" .. title .. ": finished" .. ESC .. ESC .. "\\" .. ST, "wrapped for tmux with doubled escapes")

-- 5. which events
env({ TERM_PROGRAM = "ghostty" })
check(sent(function() term.finished(false, true) end):find(": run failed", 1, true) ~= nil, "failed run")
check(sent(function() term.finished(true, false) end) == "", "a cancel is not announced")
check(sent(function() done(); term.started() end) == "", "a queued message starting in the same tick: nothing yet")
cfg.notify.events = { "blocked" }
check(sent(done) == "", "event not listed")
cfg.notify.events = { "blocked", "done", "error" }
cfg.notify.enabled = false
check(sent(done) == "", "enabled = false")
cfg.notify.enabled = true

-- 6. a confirm waiting: announced once
local confirm = require("harner.confirm")
local answer
confirm.ask = function(_, cb)
  answer = cb
  return function(choice) cb(choice) end
end
local tools = require("harner.tools")
local got = sent(function()
  local res = tools.call("ask_user", { question = "Which?", choices = { "a", "b" } })
  check(type(res) == "table" and res.pending ~= nil, "ask_user is pending")
end)
check(got == ESC .. "]9;" .. title .. ": waiting for your answer" .. ST, "blocked announced")
check(sent(function() term.update() end) == "", "still blocked: not announced again")
check(sent(function() answer("item", 1) end) == "", "answering announces nothing")
focus()
got = sent(function() tools.call("ask_user", { question = "Again?", choices = { "a", "b" } }) end)
check(got == "", "a confirm while focused is not announced")
answer("item", 1)
settle()
blur()

-- 7. a status backend shows the state already: auto stays silent
env({ AGTERM_ENABLED = "1", AGTERM_SESSION_ID = "SID-1" })
cfg.backend, cfg.agtermctl = "auto", vim.fn.exepath("true")
term.reset()
blur()
check(next(term.env()) ~= nil, "agterm backend detected")
check(sent(done) == "", "auto: no escape next to the agterm backend")
cfg.notify.protocol = "osc9"
check(sent(done):find("]9;", 1, true) ~= nil, "a forced protocol still notifies")
cfg.notify.protocol = "auto"
cfg.backend = false
term.reset()

-- 8. the real sender: no terminal attached (headless), so nothing and no error
check(pcall(real_send, "\007"), "send without a tty is a no-op")

t.finish()
