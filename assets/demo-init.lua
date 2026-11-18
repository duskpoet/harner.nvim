-- Loaded only by assets/demo.tape (`nvim -c "luafile …"`): the two config
-- overrides of the recording and a chip that shows the keys being pressed.
local config = require("harner").config
config.width = 0.46 -- the whole winbar fits at the recording's width
config.model = "sonnet"

vim.api.nvim_set_hl(0, "DemoKeys", { fg = "#2E3440", bg = "#EBCB8B", bold = true })

local GAP_MS = 500 -- a longer pause between two keys puts a space between them
local CLEAR_MS = 1800 -- the chip goes away after this long without a key
local buf = vim.api.nvim_create_buf(false, true)
local ECHO_MS = 40 -- nobody types this fast; the tape's quickest is 55 ms
local win, text, last, gen, seen = nil, "", 0, 0, 0

local function close()
	if win and vim.api.nvim_win_is_valid(win) then
		vim.api.nvim_win_close(win, true)
	end
	win, text = nil, ""
end

local function draw()
	local line = "  " .. text .. "  "
	local width = vim.fn.strdisplaywidth(line)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
	local cfg = {
		relative = "editor",
		row = vim.o.lines - 3, -- the last text row above the statusline
		-- centred under the code window, left of the chat split
		col = math.max(0, math.floor(vim.o.columns * (1 - config.width) / 2 - width / 2)),
		width = width,
		height = 1,
		style = "minimal",
		focusable = false,
		zindex = 250,
	}
	if win and vim.api.nvim_win_is_valid(win) then
		vim.api.nvim_win_set_config(win, cfg)
	else
		cfg.noautocmd = true
		win = vim.api.nvim_open_win(buf, false, cfg)
		vim.wo[win].winhighlight = "Normal:DemoKeys"
	end
end

vim.on_key(function(_, typed)
	if not typed or typed == "" then
		return
	end
	local key = vim.fn.keytrans(typed)
	local mode = vim.api.nvim_get_mode().mode
	if mode:find("^[iRc]") then
		-- typed text is visible anyway: only show the keys that act
		if key ~= "<CR>" and key ~= "<Esc>" then
			return
		end
	elseif key == "<Space>" then
		key = "<leader>"
	elseif #key > 1 and not key:find("^<[CSM]%-") and key ~= "<CR>" and key ~= "<Esc>" then
		return -- terminal responses, focus events, mouse
	end
	local now = vim.uv.now()
	if now - seen < ECHO_MS then
		return -- which-key feeding a visual-mode key back in, not a keypress
	end
	seen = now
	text = text .. ((text ~= "" and now - last > GAP_MS) and " " or "") .. key
	last = now
	gen = gen + 1
	local mine = gen
	vim.schedule(draw) -- on_key runs under textlock
	vim.defer_fn(function()
		if mine == gen then
			close()
		end
	end, CLEAR_MS)
end)
