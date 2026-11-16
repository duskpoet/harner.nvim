-- Confirm float for actions Claude asks to take (run_command, bash,
-- write_file, save_file, and edit_file's save/drop question). Unlike
-- vim.ui.select, whose frontends put the prompt in a one-line title that gets
-- truncated, the full request is shown as wrapped body text so the user sees
-- exactly what they approve.
--
-- Keys: y / <CR> approve, a approve and stop asking for this kind of action
-- in the current chat, extra `choices` answer their own value, n / q / <Esc> /
-- <C-c> decline. Leaving the float declines too.

local M = {}

-- Own highlight groups so the float stands out even where NormalFloat and
-- FloatBorder match Normal. `default = true` lets colorschemes and users
-- override them; ColorScheme re-links them after `:hi clear`.
local function set_highlights()
	local links = {
		HarnerConfirmNormal = "NormalFloat",
		HarnerConfirmBorder = "DiagnosticInfo",
		HarnerConfirmTitle = "DiagnosticInfo",
		HarnerConfirmKey = "DiagnosticInfo",
		HarnerConfirmFooter = "Comment",
	}
	for group, link in pairs(links) do
		vim.api.nvim_set_hl(0, group, { link = link, default = true })
	end
end
set_highlights()
vim.api.nvim_create_autocmd("ColorScheme", {
	group = vim.api.nvim_create_augroup("harner_confirm_hl", { clear = true }),
	callback = set_highlights,
})

-- Minimizing: the float covers the chat and the code the question is about,
-- and leaving it declines. `m` (or config.keys.minimize from anywhere) hides
-- it without answering, leaving a one-line chip in the top right corner; the
-- global key brings it back. One float is open at a time (tools.lua queues
-- them), so `current` is the one the global key acts on.
---@class HarnerConfirmState
---@field win integer
---@field prev integer window focus returns to
---@field title string
---@field insert boolean|nil restore in insert mode (the free-text float)
---@field minimized boolean|nil
---@field chip integer|nil
local current ---@type HarnerConfirmState|nil

---@param st HarnerConfirmState
local function close_chip(st)
	if st.chip and vim.api.nvim_win_is_valid(st.chip) then
		pcall(vim.api.nvim_win_close, st.chip, true)
	end
	st.chip = nil
end

---@param st HarnerConfirmState
local function minimize(st)
	if st.minimized or not vim.api.nvim_win_is_valid(st.win) then
		return
	end
	st.minimized = true -- before leaving: WinLeave must not decline
	if vim.api.nvim_get_current_win() == st.win then
		vim.cmd("stopinsert")
		local to = st.prev
		if not vim.api.nvim_win_is_valid(to) then
			for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
				if vim.api.nvim_win_get_config(w).relative == "" then
					to = w
					break
				end
			end
		end
		pcall(vim.api.nvim_set_current_win, to)
	end
	vim.api.nvim_win_set_config(st.win, { hide = true, focusable = false })

	local key = (require("harner").config.keys or {}).minimize
	local text = string.format(" ▸ %s · %s restore ", st.title, key and key ~= "" and key or ":HarnerMinimize")
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
	local width = math.min(vim.fn.strdisplaywidth(text), vim.o.columns)
	st.chip = vim.api.nvim_open_win(buf, false, {
		relative = "editor",
		row = 0,
		col = vim.o.columns - width,
		width = width,
		height = 1,
		style = "minimal",
		focusable = false,
		noautocmd = true,
		zindex = 60,
	})
	vim.wo[st.chip].winhighlight = "NormalFloat:HarnerConfirmTitle"
end

---@param st HarnerConfirmState
local function restore(st)
	if not st.minimized or not vim.api.nvim_win_is_valid(st.win) then
		return
	end
	close_chip(st)
	st.prev = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_config(st.win, { hide = false, focusable = true })
	vim.api.nvim_set_current_win(st.win)
	st.minimized = false
	if st.insert then
		vim.cmd("startinsert!")
	end
end

---Shared end of both floats' close(): drop the chip, close the window and
---give focus back, unless the float was minimized (the user is elsewhere).
---@param st HarnerConfirmState
local function dismiss(st)
	local was_minimized = st.minimized
	close_chip(st)
	if current == st then
		current = nil
	end
	if vim.api.nvim_win_is_valid(st.win) then
		if vim.api.nvim_get_current_win() == st.win then
			vim.cmd("stopinsert")
		end
		vim.api.nvim_win_close(st.win, true)
	end
	if not was_minimized and vim.api.nvim_win_is_valid(st.prev) and vim.api.nvim_get_current_win() ~= st.prev then
		pcall(vim.api.nvim_set_current_win, st.prev)
	end
end

---Register a float: `m` minimizes it, leaving it any other way calls `leave`.
---@param st HarnerConfirmState
---@param buf integer
---@param leave fun()
local function track(st, buf, leave)
	current = st
	vim.keymap.set("n", "m", function()
		minimize(st)
	end, { buffer = buf, nowait = true })
	vim.api.nvim_create_autocmd("WinLeave", {
		buffer = buf,
		callback = function()
			if st.minimized then
				return
			end
			vim.schedule(function()
				if not st.minimized then
					leave()
				end
			end)
		end,
	})
	-- a minimized float is not current, so closing it from outside (:only,
	-- :fclose!, :tabclose) fires no WinLeave; without this the call would
	-- wait for an answer nobody can give. No-op after a normal close.
	vim.api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(st.win),
		once = true,
		callback = function()
			vim.schedule(leave)
		end,
	})
end

---Minimize the open confirm float, or restore the minimized one.
---@return boolean acted false when no confirm is waiting
function M.toggle()
	local st = current
	if not st or not vim.api.nvim_win_is_valid(st.win) then
		return false
	end
	if st.minimized then
		restore(st)
	else
		minimize(st)
	end
	return true
end

---Answer keys a confirm offers besides `n` (decline) and the item digits:
---y (yes), a (always), then `opts.choices`.
---@param opts HarnerConfirmOpts
---@return {key:string, label:string, value:string}[]
function M.keys(opts)
	local keys = {}
	if opts.yes then
		keys[#keys + 1] = { key = "y", label = opts.yes, value = "yes" }
	end
	if opts.always then
		keys[#keys + 1] = { key = "a", label = opts.always, value = "always" }
	end
	return vim.list_extend(keys, opts.choices or {})
end

---@class HarnerConfirmOpts
---@field title string short question, shown on the border
---@field body string[] what is being approved (full text, wrapped)
---@field filetype string|nil highlighting for the body
---@field yes string|nil label of the approve key (y / <CR>), e.g. "run"
---@field always string|nil label of the `a` key; omitted means no `a` choice
---@field choices {key:string, label:string, value:string}[]|nil extra keys,
---       each answering its `value` (used instead of or next to yes/always)
---@field note string|nil shown dimmed under the body (auto mode's reason for asking)
---@field items string[]|nil answers to pick from (ask_user): listed numbered under
---       the body, `1`-`9` or <CR> on an item's line answer "item" with its index

---Ask the user; `cb` gets "yes", "always", a choice's value, "item" (plus the
---item's index) or "no" exactly once.
---Returns the float's close function: calling it with "no" declines it.
---@param opts HarnerConfirmOpts
---@param cb fun(choice:string, index:integer|nil)
---@return fun(choice:string) close
function M.ask(opts, cb)
	local prev = vim.api.nvim_get_current_win()
	vim.cmd("stopinsert")
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	local lines = vim.list_extend({}, opts.body)
	local first_item -- 1-based buffer line of items[1]
	if opts.items then
		lines[#lines + 1] = ""
		first_item = #lines + 1
		for i, item in ipairs(opts.items) do
			lines[#lines + 1] = string.format("%d. %s", i, (item:gsub("\n", " ")))
		end
	end
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	if opts.filetype then
		vim.bo[buf].filetype = opts.filetype
	end

	local choices = M.keys(opts)
	-- Footer as highlighted chunks: keys stand out from their labels.
	local footer = { { " ", "HarnerConfirmFooter" } }
	local function add_key(key, label)
		if #footer > 1 then
			footer[#footer + 1] = { " · ", "HarnerConfirmFooter" }
		end
		footer[#footer + 1] = { key, "HarnerConfirmKey" }
		footer[#footer + 1] = { " " .. label, "HarnerConfirmFooter" }
	end
	for _, c in ipairs(choices) do
		add_key(c.key, c.label)
	end
	if opts.items then
		local n = math.min(#opts.items, 9)
		add_key(n == 1 and "1" or ("1-" .. n), "pick")
		add_key("<CR>", "pick line")
	end
	add_key("n", "skip")
	add_key("m", "minimize")
	footer[#footer + 1] = { " ", "HarnerConfirmFooter" }
	local footer_text = table.concat(vim.tbl_map(function(c)
		return c[1]
	end, footer))

	local longest = vim.fn.strdisplaywidth(opts.title) + 4
	for _, l in ipairs(lines) do
		longest = math.max(longest, vim.fn.strdisplaywidth(l) + 2)
	end
	longest = math.max(longest, vim.fn.strdisplaywidth(footer_text) + 4)
	if opts.note then
		longest = math.max(longest, vim.fn.strdisplaywidth(opts.note) + 2)
		local ns = vim.api.nvim_create_namespace("harner_confirm")
		vim.api.nvim_buf_set_extmark(buf, ns, math.max(#lines - 1, 0), 0, {
			virt_lines = { { { opts.note, "HarnerConfirmFooter" } } },
		})
	end
	local width = math.max(20, math.min(longest, vim.o.columns - 8))
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		row = math.floor(vim.o.lines * 0.3),
		col = math.floor((vim.o.columns - width) / 2),
		width = width,
		height = 1,
		style = "minimal",
		border = "rounded",
		title = { { " " .. opts.title .. " ", "HarnerConfirmTitle" } },
		title_pos = "center",
		footer = footer,
		footer_pos = "center",
		zindex = 60,
	})
	vim.wo[win].winhighlight = "NormalFloat:HarnerConfirmNormal,FloatBorder:HarnerConfirmBorder"
	vim.wo[win].wrap = true
	vim.wo[win].linebreak = true
	vim.wo[win].breakindent = true
	local height = vim.api.nvim_win_text_height(win, {}).all
	vim.api.nvim_win_set_height(win, math.max(1, math.min(height, vim.o.lines - 8)))
	if first_item then
		vim.wo[win].cursorline = true
		vim.api.nvim_win_set_cursor(win, { first_item, 0 })
	end

	local st = { win = win, prev = prev, title = opts.title }
	local done = false
	local function close(choice, index)
		if done then
			return
		end
		done = true
		dismiss(st)
		cb(choice, index)
	end
	track(st, buf, function()
		close("no")
	end)

	local function map(lhs, choice)
		vim.keymap.set("n", lhs, function()
			close(choice)
		end, { buffer = buf, nowait = true })
	end
	for _, c in ipairs(choices) do
		map(c.key, c.value)
	end
	if opts.yes then
		map("<CR>", "yes")
	end
	if opts.items then
		for i = 1, math.min(#opts.items, 9) do
			vim.keymap.set("n", tostring(i), function()
				close("item", i)
			end, { buffer = buf, nowait = true })
		end
		if not opts.yes then
			vim.keymap.set("n", "<CR>", function()
				local i = vim.api.nvim_win_get_cursor(0)[1] - first_item + 1
				if opts.items[i] then
					close("item", i)
				end
			end, { buffer = buf, nowait = true })
		end
	end
	for _, lhs in ipairs({ "n", "q", "<Esc>", "<C-c>" }) do
		map(lhs, "no")
	end
	return close
end

local RULE = string.rep("─", 20)

---Free-text question (ask_user without choices). Unlike vim.ui.input, whose
---default frontend is a blocking cmdline prompt, this float leaves the main
---loop free, so the call can also be answered or cancelled from elsewhere.
---The question sits above a rule; the answer is everything typed below it.
---`cb` gets "text" plus the answer, or "no", exactly once. Keys: <CR> in
---normal mode or <C-s> sends, q / <Esc> (normal) / <C-c> dismiss, and so
---does leaving the float.
---@param opts { title: string, body: string[] }
---@param cb fun(choice:string, text:string|nil)
---@return fun(choice:string, text:string|nil) close
function M.input(opts, cb)
	local prev = vim.api.nvim_get_current_win()
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = "markdown"
	local lines = vim.list_extend({}, opts.body)
	vim.list_extend(lines, { RULE, "" })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

	local footer = {
		{ " ", "HarnerConfirmFooter" },
		{ "<CR>", "HarnerConfirmKey" },
		{ "/", "HarnerConfirmFooter" },
		{ "<C-s>", "HarnerConfirmKey" },
		{ " send · ", "HarnerConfirmFooter" },
		{ "q", "HarnerConfirmKey" },
		{ " skip · ", "HarnerConfirmFooter" },
		{ "m", "HarnerConfirmKey" },
		{ " minimize ", "HarnerConfirmFooter" },
	}
	local longest = vim.fn.strdisplaywidth(opts.title) + 4
	for _, l in ipairs(opts.body) do
		longest = math.max(longest, vim.fn.strdisplaywidth(l) + 2)
	end
	local width = math.max(50, math.min(longest, vim.o.columns - 8))
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		row = math.floor(vim.o.lines * 0.3),
		col = math.floor((vim.o.columns - width) / 2),
		width = width,
		height = 1,
		style = "minimal",
		border = "rounded",
		title = { { " " .. opts.title .. " ", "HarnerConfirmTitle" } },
		title_pos = "center",
		footer = footer,
		footer_pos = "center",
		zindex = 60,
	})
	vim.wo[win].winhighlight = "NormalFloat:HarnerConfirmNormal,FloatBorder:HarnerConfirmBorder"
	vim.wo[win].wrap = true
	vim.wo[win].linebreak = true
	local function fit()
		if vim.api.nvim_win_is_valid(win) then
			local h = vim.api.nvim_win_text_height(win, {}).all
			vim.api.nvim_win_set_height(win, math.max(1, math.min(h, vim.o.lines - 8)))
		end
	end
	fit()
	vim.api.nvim_win_set_cursor(win, { #lines, 0 })
	vim.cmd("startinsert")

	local function answer()
		local all = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		for i = #all, 1, -1 do
			if all[i] == RULE then
				return vim.trim(table.concat(all, "\n", i + 1))
			end
		end
		return vim.trim(table.concat(all, "\n"))
	end

	local st = { win = win, prev = prev, title = opts.title, insert = true }
	local done = false
	local function close(choice, text)
		if done then
			return
		end
		done = true
		dismiss(st)
		cb(choice, text)
	end
	track(st, buf, function()
		close("no")
	end)
	local function send()
		close("text", answer())
	end
	local o = { buffer = buf, nowait = true }
	vim.keymap.set("n", "<CR>", send, o)
	vim.keymap.set({ "n", "i" }, "<C-s>", send, o)
	for _, lhs in ipairs({ "q", "<Esc>" }) do
		vim.keymap.set("n", lhs, function()
			close("no")
		end, o)
	end
	vim.keymap.set({ "n", "i" }, "<C-c>", function()
		close("no")
	end, o)
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, { buffer = buf, callback = fit })
	return close
end

return M
