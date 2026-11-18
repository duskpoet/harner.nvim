-- Saved chats, so a conversation survives closing nvim. One JSON file
-- (`config.persist.path`, default stdpath("state")/harner/chats.json):
--   { version = 1, projects = { [cwd] = { {session_id, title, lines, updated}, ... } } }
-- Chats are filed under the cwd their Claude session ran in, because
-- `claude --resume <id>` only finds a session from that directory. Only that
-- project's chats are offered again (`:HarnerChats`); each project keeps the
-- `config.persist.max` most recent ones.

local M = {}

local function cfg()
	return require("harner").config.persist or {}
end

---@return string
function M.path()
	return cfg().path or (vim.fn.stdpath("state") .. "/harner/chats.json")
end

---@return boolean
function M.enabled()
	return cfg().enabled ~= false
end

---@return table projects
local function load_all()
	local f = io.open(M.path(), "r")
	if not f then
		return {}
	end
	local text = f:read("*a")
	f:close()
	local ok, data = pcall(vim.json.decode, text)
	if ok and type(data) == "table" and type(data.projects) == "table" then
		return data.projects
	end
	return {}
end

---Saved chats of a project, newest first.
---@param cwd string|nil defaults to the current directory
---@return {session_id:string, title:string|nil, lines:string[], updated:integer}[]
function M.list(cwd)
	if not M.enabled() then
		return {}
	end
	local out = {}
	for _, e in ipairs(load_all()[cwd or vim.fn.getcwd()] or {}) do
		if type(e) == "table" and type(e.session_id) == "string" and type(e.lines) == "table" then
			out[#out + 1] = e
		end
	end
	table.sort(out, function(a, b)
		return (a.updated or 0) > (b.updated or 0)
	end)
	return out
end

---Write or update one chat. Reads the file again first, so two nvim
---instances in the same project only replace their own chats. Never raises.
---@param cwd string
---@param entry {session_id:string, title:string|nil, lines:string[]}
function M.save(cwd, entry)
	if not M.enabled() or not cwd or cwd == "" then
		return
	end
	pcall(function()
		local projects = load_all()
		local list = {}
		for _, e in ipairs(projects[cwd] or {}) do
			if type(e) == "table" and e.session_id == entry.session_id then
				-- unchanged (a chat only looked at): keep its place, skip the write
				if e.title == entry.title and vim.deep_equal(e.lines, entry.lines) then
					return
				end
			elseif type(e) == "table" then
				list[#list + 1] = e
			end
		end
		entry.updated = os.time()
		list[#list + 1] = entry
		table.sort(list, function(a, b)
			return (a.updated or 0) > (b.updated or 0)
		end)
		for i = #list, math.max(cfg().max or 20, 1) + 1, -1 do
			list[i] = nil
		end
		projects[cwd] = list

		-- transcripts hold whatever was discussed: private file in a private dir
		local path = M.path()
		vim.fn.mkdir(vim.fs.dirname(path), "p", 448)
		local tmp = path .. "." .. vim.uv.os_getpid() .. ".tmp"
		local fd = assert(vim.uv.fs_open(tmp, "w", 384))
		vim.uv.fs_write(fd, vim.json.encode({ version = 1, projects = projects }))
		vim.uv.fs_close(fd)
		assert(vim.uv.fs_rename(tmp, path))
	end)
end

return M
