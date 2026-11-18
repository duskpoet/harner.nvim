-- Terminal integration: mirrors what harner is doing (working, waiting for the
-- user, finished) into the terminal that hosts nvim. The rest of the plugin
-- only reports facts (`update`, `started`, `finished`); the state
-- is aggregated over all chats here and handed to a backend. Without a
-- backend every call is a no-op, so harner behaves the same in any terminal.
--
-- Backends today: agterm (`agtermctl session status` for the sidebar glyph,
-- `session info` for the activity line under the row). Everywhere else the
-- same facts can become desktop notification escapes (OSC 9 / 99 / 777 or
-- BEL) while the terminal is unfocused, see `notify` (opt-in).

local M = {}

local INFO_TTL = 45 -- seconds agterm keeps the info line without a refresh
local INFO_REFRESH = 20 -- seconds between refreshes while there is a line

local outcome = nil ---@type "completed"|"failed"|nil a run ended since the last one started
local backend = nil ---@type table|false|nil false: none, nil: not detected yet
local want = { status = nil, info = false } -- info false: no line
local sent = { status = "idle", info = false }
local busy = false -- an agtermctl call is in flight (one at a time, in order)
local inflight = nil ---@type vim.SystemObj|nil that call
local scheduled = false
local timer = nil ---@type uv.uv_timer_t|nil

local function config()
	return require("harner").config.terminal or {}
end

---The backend for this nvim, detected once.
---@return table|nil
local function detect()
	if backend ~= nil then
		return backend or nil
	end
	backend = false
	local cfg = config()
	if cfg.backend ~= "auto" and cfg.backend ~= "agterm" then
		return nil
	end
	local sid = vim.env.AGTERM_SESSION_ID
	local ctl = cfg.agtermctl or "agtermctl"
	if vim.env.AGTERM_ENABLED ~= "1" or not sid or sid == "" or vim.fn.executable(ctl) ~= 1 then
		return nil
	end
	-- options go after the subcommand; agtermctl never reads AGTERM_SOCKET itself
	local target = { "--target", sid }
	if (vim.env.AGTERM_SOCKET or "") ~= "" then
		vim.list_extend(target, { "--socket", vim.env.AGTERM_SOCKET })
	end
	-- which pane of the session nvim runs in: the role can be stale after a
	-- split is promoted, the id resolves the live slot
	local pane = {}
	if (vim.env.AGTERM_PANE or "") ~= "" then
		vim.list_extend(pane, { "--pane", vim.env.AGTERM_PANE })
	end
	if (vim.env.AGTERM_PANE_ID or "") ~= "" then
		vim.list_extend(pane, { "--pane-id", vim.env.AGTERM_PANE_ID })
	end
	backend = { name = "agterm", ctl = ctl, target = target, pane = pane }
	return backend
end

-- harner state -> agterm status and flags
local STATUS = {
	active = { "active", "--blink" },
	blocked = { "blocked", "--blink" },
	completed = { "completed", "--auto-reset" }, -- back to idle once the session is visited
	-- agterm has no error status: a failed run is a completed one with another glyph
	failed = { "completed", "--auto-reset", "--shape", "triangle" },
	idle = { "idle" },
}

local function status_argv(b, state)
	local argv = { b.ctl, "session", "status" }
	vim.list_extend(argv, STATUS[state])
	vim.list_extend(argv, b.target)
	return vim.list_extend(argv, b.pane)
end

local function info_argv(b, text)
	-- the line expires by itself, so it goes away if nvim dies
	local argv = text and { b.ctl, "session", "info", text, "--hide-after", tostring(INFO_TTL) }
		or { b.ctl, "session", "info", "--clear" }
	return vim.list_extend(argv, b.target)
end

---@return string state, string|nil info
local function compute()
	local running = vim.tbl_filter(function(c)
		return c.run ~= nil
	end, vim.tbl_values(require("harner.chat").chats))
	local tools = package.loaded["harner.tools"] -- not loaded: nothing can be asking
	if tools and tools.asking() then
		return "blocked", "harner: waiting for you"
	elseif #running == 1 then
		return "active", ("harner #%d %s"):format(running[1].id, running[1].state or "thinking…")
	elseif #running > 1 then
		return "active", ("harner: %d chats running"):format(#running)
	end
	return outcome or "idle", nil
end

local pump -- forward

local function stop_timer()
	if timer then
		timer:stop()
		timer:close()
		timer = nil
	end
end

local function refresh_info()
	if want.info then
		sent.info = nil -- send the same line again before it expires
		pump()
	else
		stop_timer()
	end
end

---Send what changed, the status first, one call at a time.
pump = function()
	local b = detect()
	if busy or not b then
		return
	end
	local argv
	if want.status and want.status ~= sent.status then
		sent.status = want.status
		argv = status_argv(b, want.status)
	elseif want.info ~= sent.info then
		sent.info = want.info
		argv = info_argv(b, want.info or nil)
		if want.info and not timer then
			timer = vim.uv.new_timer()
			timer:start(INFO_REFRESH * 1000, INFO_REFRESH * 1000, vim.schedule_wrap(refresh_info))
		elseif not want.info then
			stop_timer()
		end
	end
	if not argv then
		return
	end
	busy = true
	local ok, proc = pcall(vim.system, argv, { timeout = 5000 }, function()
		vim.schedule(function()
			busy, inflight = false, nil
			pump()
		end)
	end)
	if ok then
		inflight = proc
	else
		busy = false
	end
end

-- Notifications: a desktop notification escape written to the terminal when
-- harner needs the user or a run ended. Independent of the status backend and
-- of where nvim runs (the escape travels through ssh and dtach).

local function notify_config()
	local n = config().notify
	return type(n) == "table" and n or {}
end

local ESC, ST = "\027", "\027\\"

-- no control characters inside an escape
local function clean(text)
	return (tostring(text):gsub("%c", " "))
end

local PROTOCOLS = {
	-- iTerm2's; also kitty, Ghostty, WezTerm, foot. One string, no title.
	-- (`9;4;…` is ConEmu's progress report: the message never starts with a digit.)
	osc9 = function(title, body)
		return ESC .. "]9;" .. title .. ": " .. body .. ST
	end,
	-- urxvt's: WezTerm, foot
	osc777 = function(title, body)
		return ESC .. "]777;notify;" .. title:gsub(";", ",") .. ";" .. body .. ST
	end,
	-- kitty's: title, then the body completing the same notification
	osc99 = function(title, body)
		return ESC .. "]99;i=harner:d=0;" .. title .. ST .. ESC .. "]99;i=harner:p=body;" .. body .. ST
	end,
	bell = function()
		return "\007"
	end,
}

---The notification protocol for the terminal nvim's UI is attached to, guessed
---from the environment. Variables a terminal sets itself come first: `TERM`
---is weak evidence (agterm runs with `xterm-kitty`), and over ssh it is often
---all there is, so it only ever selects OSC 9, which those terminals share.
---@return string|nil
local function protocol()
	local p = notify_config().protocol or "auto"
	if p ~= "auto" then
		return PROTOCOLS[p] and p or nil
	end
	local env = vim.env
	local program, name = env.TERM_PROGRAM or "", env.TERM or ""
	if env.AGTERM_ENABLED == "1" or program == "agterm" or env.GHOSTTY_RESOURCES_DIR or program == "ghostty" then
		return "osc9"
	elseif env.KITTY_WINDOW_ID then
		return "osc99"
	elseif env.WEZTERM_PANE or program == "WezTerm" then
		return "osc9"
	elseif env.ITERM_SESSION_ID or program == "iTerm.app" or env.LC_TERMINAL == "iTerm2" then
		return "osc9"
	elseif name == "xterm-kitty" or name == "xterm-ghostty" or name == "wezterm" then
		return "osc9"
	elseif name:find("^foot") then
		return "osc777"
	end
	return "bell" -- Alacritty, Terminal.app, Windows Terminal, …: no notification escape
end

---Write raw bytes to the terminal. Replaced in tests.
---@param data string
function M.send(data)
	local tty = false
	for _, ui in ipairs(vim.api.nvim_list_uis()) do
		tty = tty or ui.stdout_tty == true
	end
	if not tty then
		return -- headless or a GUI: no terminal to tell
	end
	if vim.api.nvim_ui_send then
		pcall(vim.api.nvim_ui_send, data)
	else
		pcall(vim.api.nvim_chan_send, 2, data) -- nvim 0.10 / 0.11: the TUI's tty
	end
end

local MESSAGES = {
	blocked = "waiting for your answer",
	done = "finished",
	error = "run failed",
}

local focused = true -- until a FocusLost says otherwise
local was_blocked = false
local ended = nil ---@type "done"|"error"|nil a run ended since the last pass

---@param event "blocked"|"done"|"error"
local function notify(event)
	local cfg = notify_config()
	if cfg.enabled ~= true or not vim.tbl_contains(cfg.events or {}, event) then
		return
	end
	if cfg.when ~= "always" and focused then
		return
	end
	local auto = (cfg.protocol or "auto") == "auto"
	if auto and detect() then
		return -- the status backend already shows it
	end
	local name = protocol()
	if not name then
		return
	end
	local title = clean("harner · " .. vim.fn.fnamemodify(vim.fn.getcwd(), ":t"))
	local data = PROTOCOLS[name](title, clean(MESSAGES[event]))
	if name ~= "bell" and (vim.env.TMUX or "") ~= "" then
		-- tmux drops unknown escapes unless wrapped (needs `allow-passthrough on`)
		data = ESC .. "Ptmux;" .. data:gsub(ESC, ESC .. ESC) .. ST
	end
	M.send(data)
end

---What happened since the last pass that the user should hear about.
local function announce(state)
	local blocked = state == "blocked"
	if blocked and not was_blocked then
		notify("blocked")
	end
	was_blocked = blocked
	if ended then
		local event = ended
		ended = nil
		notify(event)
	end
end

---FocusGained / FocusLost of the terminal nvim runs in.
---@param gained boolean
function M.focus(gained)
	focused = gained
end

---Recompute the state and push it. Coalesced to once per main-loop tick, so
---a run that ends and starts the next queued one only reports the latter.
---@param force boolean|nil send the status even if it is the one sent last
function M.update(force)
	local b = detect()
	if not b and notify_config().enabled ~= true then
		ended = nil -- nobody to tell: not later either
		return
	end
	if force then
		sent.status = nil
	end
	if scheduled then
		return
	end
	scheduled = true
	vim.schedule(function()
		scheduled = false
		local state, info = compute()
		announce(state)
		if b then
			want.status = state
			want.info = config().info ~= false and info or false
			pump()
		end
	end)
end

---A run started: an earlier run's "completed" no longer applies, and a run
---that ended in the same tick only made room for this one (queued message).
function M.started()
	outcome, ended = nil, nil
	M.update()
end

---A run ended. A cancelled one leaves nothing to look at.
---@param cancelled boolean|nil
---@param failed boolean|nil no result, or an error result
function M.finished(cancelled, failed)
	if not cancelled then
		outcome = failed and "failed" or "completed"
		ended = failed and "error" or "done"
	end
	-- the terminal resets "completed" by itself when the session is visited:
	-- report it again even if it was the last status sent
	M.update(true)
end

---Show a page (the show_page tool) in the hosting terminal: an agterm overlay
---over the session, floating at `opts.size` percent (a picture sizes itself).
---@param kind "markdown"|"html"|"image"|"text"|"url"
---@param what string absolute file path, or the URL
---@param opts { line?: integer, size?: integer }
---@param cb fun(ok: boolean, err: string) called on the main loop
---@return boolean handled false: no terminal that can, nothing was started
function M.show_page(kind, what, opts, cb)
	local b = detect()
	if not b then
		return false
	end
	local argv = { b.ctl, "session", "overlay", "open", "--" .. kind, what }
	if kind == "html" then
		-- the page may read beside itself (its css, pictures); scripts stay off
		vim.list_extend(argv, { "--cwd", vim.fs.dirname(what) })
	elseif kind == "url" or kind == "markdown" then
		table.insert(argv, "--navigation")
	elseif kind == "text" and opts.line then
		vim.list_extend(argv, { "--line", tostring(opts.line) })
	end
	if kind ~= "image" then
		local size = math.max(10, math.min(100, math.floor(tonumber(opts.size) or 90)))
		vim.list_extend(argv, { "--size-percent", tostring(size) })
	end
	vim.list_extend(argv, b.target)
	local ok, err = pcall(vim.system, argv, { text = true, timeout = 10000 }, function(r)
		vim.schedule(function()
			local out = vim.trim((r.stderr or "") ~= "" and r.stderr or r.stdout or "")
			cb(r.code == 0, out ~= "" and out or ("agtermctl exited with code " .. r.code))
		end)
	end)
	if not ok then
		vim.schedule(function()
			cb(false, tostring(err))
		end)
	end
	return true
end

---Environment for the `claude -p` a run spawns. Terminal agent-status hooks
---in the user's Claude settings would paint the same indicator as this module
---(and get overlapping chats, confirms and cancels wrong), so they are
---silenced for harner's own claude: agterm's hook exits on an empty session id.
---@return table<string, string>
function M.env()
	local b = detect()
	return b and b.name == "agterm" and { AGTERM_SESSION_ID = "" } or {}
end

---VimLeavePre: nothing is working or waiting any more. Synchronous, timers
---and callbacks no longer run.
function M.leave()
	local b = backend
	if not b then
		return
	end
	stop_timer()
	-- a call started just before must land first, or it would undo the reset
	if inflight then
		pcall(inflight.wait, inflight, 500)
		busy, inflight = false, nil
	end
	if sent.status == "active" or sent.status == "blocked" then
		pcall(function()
			vim.system(status_argv(b, "idle"), { timeout = 1000 }):wait()
		end)
	end
	if sent.info ~= false then
		pcall(function()
			vim.system(info_argv(b, nil), { timeout = 1000 }):wait()
		end)
	end
	want = { status = nil, info = false }
	sent = { status = "idle", info = false }
end

---Forget the detected backend and all state (tests).
function M.reset()
	stop_timer()
	outcome, backend, busy, scheduled, inflight = nil, nil, false, false, nil
	focused, was_blocked, ended = true, false, nil
	want = { status = nil, info = false }
	sent = { status = "idle", info = false }
end

return M
