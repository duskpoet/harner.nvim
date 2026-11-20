-- /skill completion: frontmatter parsing, the disk scan (user, project,
-- plugins), names learned from the init event, and the menu opening in the
-- popup only at the start of the prompt.

-- nvim 0.10 segfaults drawing the completion menu under `nvim -l` (the script
-- runs before the screen is set up); the same script run by `-c luafile` is
-- fine, so on 0.10 re-run this file that way and pass on its output and exit code
-- (HARNER_SKILLS_CHILD marks the child: `arg` is set under luafile too)
if vim.fn.has("nvim-0.11") == 0 and not vim.env.HARNER_SKILLS_CHILD then
	local self = debug.getinfo(1, "S").source:sub(2)
	local cmd = { vim.v.progpath, "--headless", "-u", "NONE", "-c", "luafile " .. vim.fn.fnameescape(self) }
	local r = vim.system(cmd, { env = { HARNER_SKILLS_CHILD = "1" }, timeout = 60000 }):wait()
	io.stderr:write(r.stderr or "")
	if r.code ~= 0 or r.signal ~= 0 then
		io.stderr:write(("skills_test child failed (code %d, signal %d)\n"):format(r.code, r.signal))
	end
	os.exit((r.code == 0 and r.signal == 0) and 0 or 1)
end

local t = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/helper.lua")
local check = t.check

local tmp = vim.fn.tempname()
local function write(path, lines)
	vim.fn.mkdir(vim.fs.dirname(path), "p")
	vim.fn.writefile(lines, path)
end

local base = tmp .. "/claude"
vim.env.CLAUDE_CONFIG_DIR = base
write(base .. "/skills/review/SKILL.md", { "---", "name: review", "description: >", "  Review the", "  current diff", "---", "body" })
write(base .. "/skills/hidden/SKILL.md", { "---", "description: internal", "user-invocable: false", "---" })
write(base .. "/commands/deploy.md", { "# Deploy the app", "steps" })
write(base .. "/plugins/cache/p/slack/skills/digest/SKILL.md", { "---", 'description: "Channel digest"', "---" })
write(base .. "/plugins/cache/p/other/skills/elsewhere/SKILL.md", { "---", "description: x", "---" })
write(base .. "/plugins/cache/p/mine/skills/local/SKILL.md", { "---", "description: y", "---" })
local project = tmp .. "/project"
write(base .. "/plugins/installed_plugins.json", {
	vim.json.encode({
		plugins = {
			["slack@market"] = { { scope = "user", installPath = base .. "/plugins/cache/p/slack" } },
			["other@market"] = {
				{ scope = "project", projectPath = tmp .. "/proj", installPath = base .. "/plugins/cache/p/other" },
			},
			["mine@market"] = {
				{ scope = "local", projectPath = project, installPath = base .. "/plugins/cache/p/mine" },
			},
		},
	}),
})
write(project .. "/.claude/skills/release/SKILL.md", { "---", "description: Cut a release", "---" })
write(project .. "/.claude/skills/review/SKILL.md", { "---", "description: project review", "---" })

local skills = require("harner.skills")

local fm = skills.frontmatter(base .. "/skills/review/SKILL.md")
check(fm.description == "Review the current diff", "folded description joined: " .. tostring(fm.description))

local disk = skills.scan(project)
check(disk.review and disk.review.desc == "project review", "project skill wins over the user's")
check(disk.release and disk.release.kind == "skill", "project skill found")
check(disk.deploy and disk.deploy.desc == "Deploy the app" and disk.deploy.kind == "command", "command with a heading")
check(disk["slack:digest"] and disk["slack:digest"].desc == "Channel digest", "plugin skill namespaced, quotes stripped")
check(disk.hidden == nil, "user-invocable: false skipped")
check(disk["mine:local"] and not disk["other:elsewhere"], "project-scoped plugins only for their project")

local function words(items)
	return table.concat(vim.tbl_map(function(i)
		return i.word
	end, items), " ")
end
check(words(skills.items(project, "")) == "/deploy /release /review /mine:local /slack:digest", "own first, plugins last: " .. words(skills.items(project, "")))
check(words(skills.items(project, "RE")) == "/release /review", "prefix, ignoring case")

skills.learn(project, { skills = { "review", "loop" }, slash_commands = { "review", "loop", "compact", "__internal" } })
local items = skills.items(project, "")
check(words(items) == "/compact /deploy /loop /release /review /mine:local /slack:digest", "learned names merged: " .. words(items))
local by = {}
for _, i in ipairs(items) do
	by[i.word] = i
end
check(by["/loop"].kind == "skill" and by["/compact"].kind == "command", "kinds from the init event")
check(by["/review"].info == "project review", "disk description kept for learned names")

-- the popup: menu at the start of the prompt, not after other text
vim.cmd.cd(project)
require("harner").setup({ keys = false })
local prompt = require("harner.prompt")
local seen = {}
_G.harner_probe = function()
	local info = vim.fn.complete_info({ "pum_visible", "items" })
	seen[#seen + 1] = { visible = info.pum_visible == 1, n = #info.items }
end
-- TextChangedI does not fire inside feedkeys, so call the trigger the way it would
local function probe(keys)
	seen = {}
	prompt.open({ text = "" })
	local buf = vim.api.nvim_get_current_buf()
	_G.harner_buf = buf
	vim.api.nvim_feedkeys(
		vim.keycode(keys .. "<Cmd>lua require('harner.skills').trigger(_G.harner_buf, 1)<CR><Cmd>lua harner_probe()<CR><Esc>"),
		"tx",
		false
	)
	local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
	prompt.close(true)
	return seen[1] or {}, text
end
local r = probe("i/re")
check(r.visible and r.n == 2, "menu opens for /re (" .. tostring(r.n) .. " items)")
r = probe("ifix /re")
check(not r.visible, "no menu after other text")
r = probe("i<CR>/re")
check(r.visible, "menu on a later line when the lines above are blank")
r = probe("i/review")
check(not r.visible, "no menu once the name is complete")
local _, text = probe("i/rel<Cmd>lua require('harner.skills').trigger(_G.harner_buf, 1)<CR><C-y>")
check(text == "/release", "<C-y> accepts: " .. text)
local trig = "<Cmd>lua require('harner.skills').trigger(_G.harner_buf, 1)<CR>"
_, text = probe("i/re" .. trig .. "<Tab><C-y>")
check(text == "/release", "first <Tab> inserts the first item: " .. text)
_, text = probe("i/re" .. trig .. "<Tab><Tab><C-y>")
check(text == "/review", "second <Tab> moves on: " .. text)

-- menu keys exist only while the menu is open; <CR> is the popup's send again
local function buf_map(lhs)
	local m = vim.fn.maparg(lhs, "i", false, true)
	return m.buffer == 1 and m or nil
end
prompt.open({ text = "" })
_G.harner_buf = vim.api.nvim_get_current_buf()
check(not buf_map("<Tab>") and buf_map("<CR>"), "no <Tab> map before the menu, <CR> sends")
local during
_G.harner_probe = function()
	during = buf_map("<Tab>") ~= nil
end
vim.api.nvim_feedkeys(vim.keycode("i/re" .. trig .. "<Cmd>lua harner_probe()<CR><C-y><Esc>"), "tx", false)
check(during, "<Tab> mapped while the menu is open")
check(not buf_map("<Tab>") and buf_map("<CR>") and buf_map("<CR>").desc == "harner: send", "menu maps gone after it closes")
prompt.close(true)

vim.fn.delete(tmp, "rf")
t.finish()
