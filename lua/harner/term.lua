-- Terminal integration: mirrors what harner is doing (working, waiting for the
-- user, finished) into the terminal that hosts nvim. The rest of the plugin
-- only reports facts (`update`, `started`, `finished`); the state
-- is aggregated over all chats here and handed to a backend. Without a
-- backend every call is a no-op, so harner behaves the same in any terminal.
--
-- Backends today: agterm (`agtermctl session status` for the sidebar glyph,
-- `session info` for the activity line under the row).

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

---Recompute the state and push it. Coalesced to once per main-loop tick, so
---a run that ends and starts the next queued one only reports the latter.
---@param force boolean|nil send the status even if it is the one sent last
function M.update(force)
	if not detect() then
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
		want.status = state
		want.info = config().info ~= false and info or false
		pump()
	end)
end

---A run started: an earlier run's "completed" no longer applies.
function M.started()
	outcome = nil
	M.update()
end

---A run ended. A cancelled one leaves nothing to look at.
---@param cancelled boolean|nil
---@param failed boolean|nil no result, or an error result
function M.finished(cancelled, failed)
	if not cancelled then
		outcome = failed and "failed" or "completed"
	end
	-- the terminal resets "completed" by itself when the session is visited:
	-- report it again even if it was the last status sent
	M.update(true)
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
	want = { status = nil, info = false }
	sent = { status = "idle", info = false }
end

return M
