-----------------
-- ui.lua
-----------------
local config = require("dependency-tree.config")
local formatter = require("dependency-tree.formatter")
local M = {}

-- Display the dependency tree in a floating window
function M.show_dependency_tree(tree, root_id)
	local lines = formatter.format_tree_for_display(tree, root_id)

	-- Create the floating window
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

	-- Set buffer options
	vim.api.nvim_buf_set_option(buf, "modifiable", false)
	vim.api.nvim_buf_set_option(buf, "filetype", "markdown")

	-- Calculate window dimensions
	local width = math.min(vim.o.columns - 4, config.float_opts.width)
	local height = math.min(vim.o.lines - 4, config.float_opts.height)

	-- Calculate position (centered)
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)

	-- Window options
	local win_opts = {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = config.float_opts.border,
		title = "Dependency Tree", -- Set title directly in the options
		title_pos = "center", -- Position the title (if supported)
	}

	local win = vim.api.nvim_open_win(buf, true, win_opts)

	-- Set mappings to close the window
	vim.api.nvim_buf_set_keymap(buf, "n", "q", "<cmd>close<CR>", { noremap = true, silent = true })
	vim.api.nvim_buf_set_keymap(buf, "n", "<Esc>", "<cmd>close<CR>", { noremap = true, silent = true })

	-- Set window appearance (Neovim version-compatible)
	if vim.fn.has("nvim-0.9") == 1 then
		-- Neovim 0.9+ API
		vim.api.nvim_win_set_option(win, "winhl", "Normal:Normal,FloatBorder:SpecialComment")
		-- Title is now set via the win_opts
	else
		-- Fallback for older Neovim versions
		vim.wo[win].winhl = "Normal:Normal,FloatBorder:SpecialComment"
		-- Note: title handling for pre-0.9 might need different approach
	end
end

return M
