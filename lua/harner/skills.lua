-- Completion of `/skill` and `/command` names at the start of a prompt (the
-- popup and the chat input area). Two sources, merged:
--
-- * the `system/init` event of every run lists what claude itself resolved
--   (`skills`, `slash_commands`: plugins, built-ins, enabled state), kept per
--   cwd by `learn()`;
-- * a scan of the SKILL.md / command files (user, project dirs from cwd up,
--   installed plugins) for descriptions, and for the names before the first
--   run of a session.
--
-- The menu opens by itself (`vim.fn.complete()` on TextChangedI) once the
-- input starts with `/`; <Tab>/<S-Tab> move, <CR> accepts.

local M = {}

local learned = {} ---@type table<string, {skills:table<string, boolean>, commands:string[]}>
local scanned = {} ---@type table<string, {at:number, entries:table<string, {desc:string, kind:string}>}>
local SCAN_TTL = 5 -- seconds a scan is reused (the trigger runs on every keystroke)

local function enabled()
	return require("harner").config.prompt.complete ~= false
end

local function claude_dir()
	local dir = vim.env.CLAUDE_CONFIG_DIR
	return (dir and dir ~= "") and dir or vim.fs.joinpath(vim.uv.os_homedir(), ".claude")
end

---The YAML frontmatter fields of a skill / command file (flat keys, folded
---`>` / `|` values joined into one line).
---@param path string
---@return table<string, string>
function M.frontmatter(path)
	local ok, lines = pcall(vim.fn.readfile, path, "", 60)
	if not ok or lines[1] ~= "---" then
		local first = ok and vim.tbl_filter(function(l)
			return l:match("%S") ~= nil
		end, lines)[1]
		return { description = first and vim.trim((first:gsub("^#+%s*", ""))) or nil }
	end
	local fm, key = {}, nil
	for i = 2, #lines do
		local line = lines[i]
		if line == "---" then
			break
		end
		local k, v = line:match("^([%w_%-]+):%s*(.-)%s*$")
		if k then
			key = k
			fm[k] = v:match("^[>|][-+]?$") and "" or v:gsub("^([\"'])(.*)%1$", "%2")
		elseif key and line:match("^%s+%S") then
			fm[key] = vim.trim(fm[key] .. " " .. vim.trim(line))
		end
	end
	return fm
end

---Add the skills (`<dir>/skills/<name>/SKILL.md`) and commands
---(`<dir>/commands/**/<name>.md`) under `dir` to `out`.
local function scan_dir(out, dir, prefix)
	for _, path in ipairs(vim.fn.glob(dir .. "/skills/*/SKILL.md", true, true)) do
		local fm = M.frontmatter(path)
		local invocable = fm["user-invocable"] or fm.user_invocable
		local name = prefix .. vim.fn.fnamemodify(path, ":h:t")
		if invocable ~= "false" and not out[name] then
			out[name] = { desc = fm.description or "", kind = "skill" }
		end
	end
	for _, path in ipairs(vim.fn.glob(dir .. "/commands/**/*.md", true, true)) do
		local name = prefix .. vim.fn.fnamemodify(path, ":t:r")
		if not out[name] then
			out[name] = { desc = M.frontmatter(path).description or "", kind = "command" }
		end
	end
end

---Skills and commands on disk visible from `cwd`: project `.claude` dirs from
---cwd up (nearest wins), the user's, then installed plugins as `plugin:name`.
---@param cwd string
---@return table<string, {desc:string, kind:string}>
function M.scan(cwd)
	local hit = scanned[cwd]
	if hit and vim.uv.now() / 1000 - hit.at < SCAN_TTL then
		return hit.entries
	end
	local out = {}
	local home = vim.uv.os_homedir()
	local dir = vim.fs.normalize(cwd)
	while dir and dir ~= home do
		scan_dir(out, dir .. "/.claude", "")
		local parent = vim.fs.dirname(dir)
		dir = parent ~= dir and parent or nil
	end
	local base = claude_dir()
	scan_dir(out, base, "")
	local ok, data = pcall(function()
		return vim.json.decode(table.concat(vim.fn.readfile(base .. "/plugins/installed_plugins.json"), "\n"))
	end)
	if ok and type(data) == "table" and type(data.plugins) == "table" then
		local here = vim.fs.normalize(cwd)
		-- user installs, and project / local ones made for cwd or a parent of it
		local function applies(install)
			if type(install) ~= "table" or type(install.installPath) ~= "string" then
				return false
			end
			local root = type(install.projectPath) == "string" and vim.fs.normalize(install.projectPath)
			return install.scope == "user"
				or install.scope == nil
				or (root and (here == root or vim.startswith(here, root .. "/"))) == true
		end
		for key, installs in pairs(data.plugins) do
			for _, install in ipairs(type(installs) == "table" and installs or {}) do
				if applies(install) then
					scan_dir(out, install.installPath, key:match("^[^@]+") .. ":")
					break
				end
			end
		end
	end
	scanned[cwd] = { at = vim.uv.now() / 1000, entries = out }
	return out
end

---Remember what a run's `system/init` event lists for `cwd`.
---@param cwd string
---@param ev table
function M.learn(cwd, ev)
	local skills = {}
	for _, name in ipairs(type(ev.skills) == "table" and ev.skills or {}) do
		skills[name] = true
	end
	local commands = type(ev.slash_commands) == "table" and ev.slash_commands or {}
	if next(skills) or #commands > 0 then
		learned[cwd] = { skills = skills, commands = commands }
	end
end

---Completion items for names starting with `typed` (without the slash).
---@param cwd string
---@param typed string
---@return table[]
function M.items(cwd, typed)
	local disk = M.scan(cwd)
	local all = {}
	for name, e in pairs(disk) do
		all[name] = { desc = e.desc, kind = e.kind }
	end
	local known = learned[cwd]
	if known then
		for _, name in ipairs(known.commands) do
			all[name] = all[name] or { desc = "", kind = known.skills[name] and "skill" or "command" }
		end
		for name in pairs(known.skills) do
			all[name] = all[name] or { desc = "", kind = "skill" }
		end
	end
	local names = {}
	for name in pairs(all) do
		if vim.startswith(name:lower(), typed:lower()) and not name:match("^__") then
			names[#names + 1] = name
		end
	end
	-- own skills before plugin-namespaced ones, then alphabetical
	table.sort(names, function(a, b)
		local pa, pb = a:find(":", 1, true) ~= nil, b:find(":", 1, true) ~= nil
		if pa ~= pb then
			return pb
		end
		return a < b
	end)
	return vim.tbl_map(function(name)
		local e = all[name]
		local short = e.desc:gsub("%s+", " ")
		if vim.fn.strchars(short) > 60 then
			short = vim.fn.strcharpart(short, 0, 59) .. "…"
		end
		return { word = "/" .. name, kind = e.kind, menu = short, info = e.desc, icase = 1, dup = 0 }
	end, names)
end

local saved_cot = nil -- global completeopt replaced on nvim 0.10 (no buffer-local value)
local on_crs = {} ---@type table<integer, fun()|false> `on_cr` per attached buffer

local function pum()
	return vim.fn.pumvisible() == 1
end

local function imap(buf, lhs, rhs, opts)
	vim.keymap.set("i", lhs, rhs, vim.tbl_extend("force", { buffer = buf, nowait = true }, opts or {}))
end

---<Tab>/<S-Tab>/<CR> for the menu. They only exist while it is open, so the
---user's own insert maps (Copilot, snippets, autopairs) work everywhere else.
local function menu_maps(buf)
	local function expr(lhs, rhs)
		imap(buf, lhs, rhs, { expr = true, desc = "harner: complete skills" })
	end
	expr("<Tab>", function()
		if not pum() then
			return "<Tab>"
		end
		-- noinsert pre-selects the first item without inserting it: the first
		-- <Tab> puts that one in (down and back up, since <C-n> alone would
		-- skip to the second), later ones move on
		local info = vim.fn.complete_info({ "selected", "items" })
		local first = info.items[1]
		local before = vim.api.nvim_get_current_line():sub(1, vim.api.nvim_win_get_cursor(0)[2])
		if info.selected == 0 and first and not vim.endswith(before, first.word) then
			return "<C-n><C-p>"
		end
		return "<C-n>"
	end)
	expr("<S-Tab>", function()
		return pum() and "<C-p>" or "<S-Tab>"
	end)
	imap(buf, "<CR>", function()
		if pum() then
			vim.api.nvim_feedkeys(vim.keycode("<C-y>"), "n", false)
		elseif on_crs[buf] then
			on_crs[buf]()
		else
			vim.api.nvim_feedkeys(vim.keycode("<CR>"), "n", false)
		end
	end, { desc = "harner: accept completion or send" })
end

---Menu closed: drop its maps (<CR> goes back to `on_cr`), restore completeopt.
local function menu_done(buf)
	for _, lhs in ipairs({ "<Tab>", "<S-Tab>", "<CR>" }) do
		pcall(vim.keymap.del, "i", lhs, { buffer = buf })
	end
	if on_crs[buf] then
		imap(buf, "<CR>", on_crs[buf], { desc = "harner: send" })
	end
	if saved_cot then
		vim.o.completeopt = saved_cot
		saved_cot = nil
	end
end

---Open the menu when the input so far (from line `first`) is `/<partial>`.
---@param buf integer
---@param first integer|fun():integer|nil 1-based first line of the input area
---(nil = none), or a function returning it, called only once the cursor line
---looks like `/<partial>` (the chat's scans the whole buffer)
function M.trigger(buf, first)
	if not first or not enabled() or pum() or vim.api.nvim_get_current_buf() ~= buf then
		return
	end
	local row, col = unpack(vim.api.nvim_win_get_cursor(0))
	local lead, typed = vim.api.nvim_get_current_line():sub(1, col):match("^(%s*)/([%w_:%.%-]*)$")
	if not lead then
		return
	end
	if type(first) == "function" then
		first = first()
	end
	if not first or row < first then
		return
	end
	for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, first - 1, row - 1, false)) do
		if line:match("%S") then
			return -- only the start of the prompt invokes a skill
		end
	end
	local items = M.items(vim.fn.getcwd(), typed)
	if #items == 0 or (#items == 1 and items[1].word == "/" .. typed) then
		return
	end
	if vim.fn.has("nvim-0.11") == 0 then
		saved_cot = saved_cot or vim.o.completeopt
		vim.o.completeopt = "menuone,noinsert"
	end
	vim.fn.complete(#lead + 1, items)
	if pum() then
		menu_maps(buf)
	end
end

---Hook completion into `buf`. `input_start()` returns the first line of the
---input area (nil while there is none, e.g. a chat run streaming).
---`on_cr` is the buffer's insert <CR> while no menu is open (nil: unmapped).
---@param buf integer
---@param input_start fun():integer|nil
---@param on_cr fun()|nil
function M.attach(buf, input_start, on_cr)
	on_crs[buf] = on_cr or false
	if on_cr then
		imap(buf, "<CR>", on_cr, { desc = "harner: send" })
	end
	if not enabled() then
		return
	end
	if vim.fn.has("nvim-0.11") == 1 then
		vim.bo[buf].completeopt = "menuone,noinsert,popup"
	end
	local group = vim.api.nvim_create_augroup("harner_skills_" .. buf, { clear = true })
	vim.api.nvim_create_autocmd("TextChangedI", {
		group = group,
		buffer = buf,
		callback = function()
			M.trigger(buf, input_start)
		end,
	})
	vim.api.nvim_create_autocmd({ "CompleteDone", "InsertLeave" }, {
		group = group,
		buffer = buf,
		callback = function()
			menu_done(buf)
		end,
	})
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		buffer = buf,
		callback = function()
			on_crs[buf] = nil
		end,
	})
end

return M
