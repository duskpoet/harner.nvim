local t = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/helper.lua")
local check = t.check
vim.o.columns = 160; vim.o.lines = 50
-- Offline test of the show_page tool: kinds by extension, the agterm overlay
-- command against a fake `agtermctl`, the fallbacks without it (system viewer
-- through a stubbed `vim.ui.open`, text in the editor), refusals.
local tmp = vim.uv.fs_realpath(vim.fn.fnamemodify(vim.fn.tempname(), ":h")) .. "/harner-page-" .. vim.fn.getpid()
vim.fn.mkdir(tmp, "p")
local log = tmp .. "/ctl.log"
local ctl = tmp .. "/agtermctl"
vim.fn.writefile({ "#!/bin/sh", 'printf "%s\\n" "$*" >> ' .. log }, ctl)
vim.fn.setfperm(ctl, "rwxr-xr-x")
local failing = tmp .. "/agtermctl-failing"
vim.fn.writefile({ "#!/bin/sh", "echo 'no such session' >&2", "exit 1" }, failing)
vim.fn.setfperm(failing, "rwxr-xr-x")

local function file(name, lines)
  vim.fn.writefile(lines, tmp .. "/" .. name)
  return tmp .. "/" .. name
end
local md = file("notes.md", { "# Notes" })
local html = file("page.HTML", { "<h1>hi</h1>" })
local png = file("pic.png", { "not really a picture" })
local lua = file("code.lua", { "local a = 1", "local b = 2", "return a + b" })
local cmd = file("run.command", { "#!/bin/sh", "touch " .. tmp .. "/ran" })
local bin = tmp .. "/blob.dat"
do
  local f = assert(io.open(bin, "wb"))
  f:write("abc\0def")
  f:close()
end

for _, k in ipairs({ "AGTERM_ENABLED", "AGTERM_SESSION_ID", "AGTERM_SOCKET", "AGTERM_PANE", "AGTERM_PANE_ID" }) do
  vim.env[k] = nil
end
require("harner").setup({ terminal = { backend = "auto", agtermctl = ctl }, auto = { enabled = false } })
local cfg = require("harner").config
local term = require("harner.term")
local tools = require("harner.tools")

local opened = {}
local open_err
local open_exit ---@type table|nil result of an opener that exits right away
vim.ui.open = function(what)
  table.insert(opened, what)
  if open_err then return nil, open_err end
  if not open_exit then return {}, nil end
  local r = open_exit
  return { is_closing = function() return true end, wait = function() return r end }, nil
end

---Call show_page and wait for its result.
---@return string text, boolean is_error
local function show(args)
  local res = tools.call("show_page", args)
  if res.pending then
    local id = res.pending
    res = nil
    vim.wait(3000, function()
      local r = tools.poll(id)
      if type(r) == "table" then res = r end
      return res ~= nil
    end, 20)
  end
  if not res then return "no result", true end
  return res.content[1].text, res.isError == true
end
local function last_call()
  local lines = vim.fn.filereadable(log) == 1 and vim.fn.readfile(log) or {}
  return lines[#lines] or ""
end

local names = vim.tbl_map(function(x) return x.name end, tools.list())
check(vim.tbl_contains(names, "show_page"), "show_page is listed")

-- 1. no terminal overlay: the system viewer for pages, the editor for text
local text, err = show({ path = md })
check(not err and text:find("with the system viewer", 1, true) and opened[#opened] == md, "markdown goes to vim.ui.open: " .. text)
-- a URL reaches the user's browser (their logins) only after a confirm
local asked, answer = {}, "no"
require("harner.confirm").ask = function(opts, cb)
  table.insert(asked, opts)
  local pick = answer
  vim.schedule(function() cb(pick) end)
  return function(choice) cb(choice) end
end
local n = #opened
text, err = show({ url = "https://example.com/a?b=1" })
check(err and text:find("declined", 1, true) and #opened == n, "a declined URL is not opened: " .. text)
check(#asked == 1 and asked[1].body[1] == "https://example.com/a?b=1", "the confirm shows the URL")
answer = "yes"
text, err = show({ url = "https://example.com/a?b=1" })
check(not err and text:find("with the system browser", 1, true) and opened[#opened] == "https://example.com/a?b=1", "a confirmed URL goes to vim.ui.open: " .. text)
answer = "always"
show({ url = "https://example.com/2" })
show({ url = "https://example.com/3" })
check(#asked == 3 and opened[#opened] == "https://example.com/3", "`a` stops asking for the chat")
tools.reset_grants()
check(#asked == 3, "files never ask")
n = #opened
text, err = show({ path = lua, line = 2 })
check(not err and text:find("at line 2 in the editor", 1, true) and #opened == n, "text opens in the editor: " .. text)
check(vim.api.nvim_buf_get_name(0) == lua and vim.api.nvim_win_get_cursor(0)[1] == 2, "editor shows the file at the line")
text, err = show({ path = cmd })
check(not err and #opened == n and vim.fn.filereadable(tmp .. "/ran") == 0, "a script is shown as text, never handed to the system: " .. text)
open_err = "no handler"
text, err = show({ path = png })
check(err and text:find("no handler", 1, true), "vim.ui.open failing is an error: " .. text)
open_err = nil
-- the opener starts but fails (xdg-open without a display): not "opened"
open_exit = { code = 3, stderr = "Error: no display\n" }
text, err = show({ path = png })
check(err and text:find("Error: no display", 1, true), "a failing opener is an error: " .. text)
open_exit = { code = 0, stderr = "" }
text, err = show({ path = png })
check(not err and text:find("with the system viewer", 1, true), "an opener that exits 0 has opened: " .. text)
open_exit = nil
n = n + 2

-- 2. refusals
text, err = show({})
check(err and text:find("either path or url", 1, true), "neither path nor url: " .. text)
text, err = show({ path = md, url = "https://example.com" })
check(err and text:find("either path or url", 1, true), "both path and url: " .. text)
for _, bad in ipairs({ "file:///etc/passwd", "javascript:alert(1)", "ftp://example.com", "https://exa mple.com", "--html" }) do
  text, err = show({ url = bad })
  check(err and text:find("only http and https", 1, true), "refused URL " .. bad)
end
text, err = show({ path = tmp .. "/missing.md" })
check(err and text:find("no such file", 1, true), "missing file: " .. text)
text, err = show({ path = tmp })
check(err and text:find("is a directory", 1, true), "directory: " .. text)
text, err = show({ path = bin })
check(err and text:find("binary", 1, true), "binary file: " .. text)
check(#opened == n + 1, "nothing refused reached vim.ui.open")

-- 3. inside agterm: an overlay per kind
vim.env.AGTERM_ENABLED = "1"
vim.env.AGTERM_SESSION_ID = "SID-1"
vim.env.AGTERM_SOCKET = tmp .. "/sock"
term.reset()
n = #opened
local tail = " --target SID-1 --socket " .. tmp .. "/sock"
text, err = show({ path = md })
check(not err and text:find("in a terminal overlay", 1, true), "overlay result: " .. text)
check(last_call() == "session overlay open --markdown " .. md .. " --navigation --size-percent 90" .. tail, "markdown overlay: " .. last_call())
show({ path = html })
check(last_call() == "session overlay open --html " .. html .. " --cwd " .. tmp .. " --size-percent 90" .. tail, "html overlay, extension case ignored: " .. last_call())
show({ path = png })
check(last_call() == "session overlay open --image " .. png .. tail, "image overlay sizes itself: " .. last_call())
show({ path = lua, line = 3 })
check(last_call() == "session overlay open --text " .. lua .. " --line 3 --size-percent 90" .. tail, "text overlay at a line: " .. last_call())
show({ path = md, line = 3 })
check(not last_call():find("--line", 1, true), "line ignored for a page")
cfg.show_page.size = 500
show({ url = "http://localhost:8080/x" })
check(last_call() == "session overlay open --url http://localhost:8080/x --navigation --size-percent 100" .. tail, "url overlay, size clamped: " .. last_call())
cfg.show_page.size = 90
check(#opened == n and #asked == 3, "next to an overlay: no system viewer, no confirm for the URL")

-- 4. agtermctl failing is reported, not hidden
cfg.terminal.agtermctl = failing
term.reset()
text, err = show({ path = md })
check(err and text:find("no such session", 1, true), "overlay failure: " .. text)

vim.fn.delete(tmp, "rf")
t.finish()
