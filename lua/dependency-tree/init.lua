-----------------
-- init.lua
-----------------

--[[
  dependency-tree.nvim

  A Neovim plugin for advanced code navigation and dependency analysis.

  PURPOSE:
  This plugin helps developers understand code relationships by visualizing dependencies
  between functions, methods, and variables. It analyzes both callers (who calls this function?)
  and callees (what does this function call?), creating a comprehensive dependency tree.

  FEATURES:
  - Analyzes function/method dependencies using LSP and Treesitter
  - Displays both callers (upward) and callees (downward) relationships
  - Shows implementation details and source code
  - Tracks variable usage within functions
  - Supports TypeScript, JavaScript, Python, Lua, Go, and Rust
  - Exports dependency information to clipboard for documentation or AI prompting
  - Special support for React components and their relationships
  - Folder tree visualization for better project context

  ARCHITECTURE:
  - analyzer.lua: Core logic for building dependency trees and analyzing code
  - formatter.lua: Formats the analysis results for display and export
  - lsp.lua: Interfaces with Language Server Protocol for code navigation
  - ui.lua: Handles the visualization in Neovim floating windows
  - utils.lua: Provides utility functions for file handling and caching
  - config.lua: Manages plugin configuration options

  WORKFLOW:
  1. User places cursor on a function/variable and triggers the plugin
  2. Plugin identifies the symbol under cursor using Treesitter
  3. LSP is used to find references and definitions recursively
  4. A dependency tree is built showing both callers and callees
  5. Tree is displayed in a floating window with source code context

  This plugin is especially useful for:
  - Understanding complex codebases
  - Preparing comprehensive code context for AI tools
  - Documenting function relationships
  - Refactoring with confidence
  - Code reviews and knowledge sharing
]]
--

local config = require("dependency-tree.config")
local lsp = require("dependency-tree.lsp")
local analyzer = require("dependency-tree.analyzer")
local formatter = require("dependency-tree.formatter")
local ui = require("dependency-tree.ui")
local utils = require("dependency-tree.utils")

local M = {}

-- Check if Treesitter is available
local function check_treesitter()
	if not vim.treesitter then
		vim.notify(
			"Dependency Tree plugin requires Neovim with Treesitter support. Please upgrade your Neovim or install Treesitter.",
			vim.log.levels.ERROR
		)
		return false
	end
	return true
end

-- Main function to create and display the dependency tree
function M.show_dependency_tree()
	-- Check for Treesitter
	if not check_treesitter() then
		return
	end

	local bufnr = vim.api.nvim_get_current_buf()

	-- Check if buffer is valid
	if not vim.api.nvim_buf_is_valid(bufnr) then
		vim.notify("Invalid buffer", vim.log.levels.ERROR)
		return
	end

	-- Get and validate filetype
	local filetype = vim.api.nvim_buf_get_option(bufnr, "filetype")
	if not filetype or filetype == "" then
		vim.notify("Could not determine file type", vim.log.levels.ERROR)
		return
	end

	-- Check if filetype is supported
	local supported_types = {
		typescript = true,
		javascript = true,
		typescriptreact = true,
		javascriptreact = true,
		python = true,
		lua = true,
		go = true,
		rust = true,
	}

	if not supported_types[filetype] then
		vim.notify("Unsupported file type: " .. filetype, vim.log.levels.ERROR)
		return
	end

	local pos = vim.api.nvim_win_get_cursor(0)
	pos = { line = pos[1] - 1, character = pos[2] }

	-- Initialize the tree and cache
	local tree = { nodes = {} }
	utils.clear_caches()

	-- Get symbol at cursor using Treesitter
	local symbol = lsp.get_symbol_info_at_cursor()
	if not symbol then
		vim.notify(
			"No symbol found at cursor position. Please place cursor on a function, method, or variable.",
			vim.log.levels.ERROR
		)
		return
	end

	vim.notify("Analyzing dependencies for '" .. symbol .. "'...", vim.log.levels.INFO)

	-- Get maximum depth from config with type safety
	local max_depth = tonumber(config.max_depth) or 3

	-- Ensure max_depth is within reasonable bounds
	if max_depth < 1 then
		max_depth = 1
	elseif max_depth > 10 then
		max_depth = 10
	end

	-- Use pcall to catch and handle any errors during tree building
	local success, err = pcall(function()
		-- Build the tree starting from current position
		analyzer.build_dependency_tree(bufnr, pos, 0, max_depth, "both", tree, nil)

		-- Find implementation of the root function if it exists elsewhere
		local root_id = string.format("%s:%d:%d", vim.api.nvim_buf_get_name(bufnr), pos.line, pos.character)
		local root = tree.nodes[root_id]
		if root then
			analyzer.find_function_implementation(root, tree)
		end
	end)

	if not success then
		vim.notify("Error building dependency tree: " .. tostring(err), vim.log.levels.ERROR)
		return
	end

	-- Get the root ID
	local root_id = string.format("%s:%d:%d", vim.api.nvim_buf_get_name(bufnr), pos.line, pos.character)

	-- Check if the tree is empty
	if not tree.nodes[root_id] then
		vim.notify(
			"No references found for '" .. symbol .. "'. Make sure your LSP server is configured correctly.",
			vim.log.levels.WARN
		)
		return
	end

	-- Analyze variable dependencies
	analyzer.analyze_variable_dependencies(bufnr, pos, root_id, tree)

	-- Display the tree
	ui.show_dependency_tree(tree, root_id)
end

-- Export dependency tree to clipboard for AI prompting
function M.export_dependency_tree()
	-- Check for Treesitter
	if not check_treesitter() then
		return
	end

	local bufnr = vim.api.nvim_get_current_buf()
	local pos = vim.api.nvim_win_get_cursor(0)
	pos = { line = pos[1] - 1, character = pos[2] }

	-- Initialize the tree and cache
	local tree = { nodes = {} }
	utils.clear_caches()

	-- Get symbol at cursor using Treesitter
	local symbol = lsp.get_symbol_info_at_cursor()
	if not symbol then
		vim.notify(
			"No symbol found at cursor position. Please place cursor on a function, method, or variable.",
			vim.log.levels.ERROR
		)
		return
	end

	-- Notify user
	vim.notify("Analyzing dependencies for '" .. symbol .. "'...", vim.log.levels.INFO)

	-- Get maximum depth from config
	local max_depth = config.max_depth

	-- Use pcall to catch and handle any errors during tree building
	local success, err = pcall(function()
		-- Build the tree starting from current position
		analyzer.build_dependency_tree(bufnr, pos, 0, max_depth, "both", tree, nil)

		-- Find implementation of the root function if it exists elsewhere
		local root_id = string.format("%s:%d:%d", vim.api.nvim_buf_get_name(bufnr), pos.line, pos.character)
		local root = tree.nodes[root_id]
		if root then
			analyzer.find_function_implementation(root, tree)
		end
	end)

	if not success then
		vim.notify("Error building dependency tree: " .. tostring(err), vim.log.levels.ERROR)
		return
	end

	-- Get the root ID
	local root_id = string.format("%s:%d:%d", vim.api.nvim_buf_get_name(bufnr), pos.line, pos.character)

	-- Check if the tree is empty
	if not tree.nodes[root_id] then
		vim.notify(
			"No references found for '" .. symbol .. "'. Make sure your LSP server is configured correctly.",
			vim.log.levels.WARN
		)
		return
	end

	-- Analyze variable dependencies
	analyzer.analyze_variable_dependencies(bufnr, pos, root_id, tree)

	-- Generate export content with folder tree structure
	local content = formatter.generate_export_content(tree, root_id, config.ai_prompt.include_folder_structure)

	-- Copy to clipboard
	if utils.copy_to_clipboard(content) then
		vim.notify("Dependency tree for '" .. symbol .. "' exported to clipboard", vim.log.levels.INFO)
	else
		vim.notify("Failed to export to clipboard. Check if you have clipboard access.", vim.log.levels.ERROR)
	end
end

-- Export dependency tree to a file
function M.export_dependency_tree_to_file()
	-- Check for Treesitter
	if not check_treesitter() then
		return
	end

	local bufnr = vim.api.nvim_get_current_buf()
	local pos = vim.api.nvim_win_get_cursor(0)
	pos = { line = pos[1] - 1, character = pos[2] }

	-- Initialize the tree and cache
	local tree = { nodes = {} }
	utils.clear_caches()

	-- Get symbol at cursor using Treesitter
	local symbol = lsp.get_symbol_info_at_cursor()
	if not symbol then
		vim.notify(
			"No symbol found at cursor position. Please place cursor on a function, method, or variable.",
			vim.log.levels.ERROR
		)
		return
	end

	-- Notify user
	vim.notify("Analyzing dependencies for '" .. symbol .. "'...", vim.log.levels.INFO)

	-- Get maximum depth from config
	local max_depth = config.max_depth

	-- Use pcall to catch and handle any errors during tree building
	local success, err = pcall(function()
		-- Build the tree starting from current position
		analyzer.build_dependency_tree(bufnr, pos, 0, max_depth, "both", tree, nil)

		-- Find implementation of the root function if it exists elsewhere
		local root_id = string.format("%s:%d:%d", vim.api.nvim_buf_get_name(bufnr), pos.line, pos.character)
		local root = tree.nodes[root_id]
		if root then
			analyzer.find_function_implementation(root, tree)
		end
	end)

	if not success then
		vim.notify("Error building dependency tree: " .. tostring(err), vim.log.levels.ERROR)
		return
	end

	-- Get the root ID
	local root_id = string.format("%s:%d:%d", vim.api.nvim_buf_get_name(bufnr), pos.line, pos.character)

	-- Check if the tree is empty
	if not tree.nodes[root_id] then
		vim.notify(
			"No references found for '" .. symbol .. "'. Make sure your LSP server is configured correctly.",
			vim.log.levels.WARN
		)
		return
	end

	-- Analyze variable dependencies
	analyzer.analyze_variable_dependencies(bufnr, pos, root_id, tree)

	-- Generate export content with folder tree structure
	local content = formatter.generate_export_content(tree, root_id, true)

	-- Sanitize symbol name for filename
	local safe_symbol = symbol:gsub("[^%w_%-]", "_")
	local filename = string.format("%s_dependency_tree.md", safe_symbol)
	local current_dir = vim.fn.getcwd()
	local filepath = current_dir .. "/" .. filename

	-- Write to file
	local file = io.open(filepath, "w")
	if file then
		file:write(content)
		file:close()
		vim.notify("Dependency tree exported to " .. filepath, vim.log.levels.INFO)
	else
		vim.notify("Failed to write to file " .. filepath, vim.log.levels.ERROR)
	end
end

-- Set up the plugin with user configuration
function M.setup(opts)
	-- Check for Treesitter
	if not check_treesitter() then
		vim.notify(
			"Dependency Tree plugin installed but requires Treesitter. Some functionality may not work correctly.",
			vim.log.levels.WARN
		)
	end

	-- Merge user options with defaults
	config.update(opts or {})

	-- Set up the keymap for showing tree
	vim.api.nvim_set_keymap(
		"n",
		config.keymap,
		"<cmd>lua require('dependency-tree').show_dependency_tree()<CR>",
		{ noremap = true, silent = true, desc = "Show dependency tree" }
	)

	-- Set up the keymap for exporting tree
	vim.api.nvim_set_keymap(
		"n",
		config.export_keymap,
		"<cmd>lua require('dependency-tree').export_dependency_tree()<CR>",
		{ noremap = true, silent = true, desc = "Export dependency tree to clipboard" }
	)

	-- Set up the keymap for exporting tree to file
	vim.api.nvim_set_keymap(
		"n",
		config.export_keymap .. "f",
		"<cmd>lua require('dependency-tree').export_dependency_tree_to_file()<CR>",
		{ noremap = true, silent = true, desc = "Export dependency tree to file" }
	)

	-- Clear caches on buffer reload
	vim.api.nvim_create_autocmd({ "BufWritePost" }, {
		callback = function()
			utils.clear_caches()
		end,
	})
end

return M
