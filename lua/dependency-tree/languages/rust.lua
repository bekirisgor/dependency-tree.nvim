-----------------
-- languages/rust.lua
-----------------
--[[
    Rust-specific analysis utilities for dependency-tree.nvim

    This module handles:
    - Rust use/import analysis
    - Crate structure detection
    - Trait implementations
    - Module relationships
]]

local config = require("dependency-tree.config")
local utils = require("dependency-tree.utils")
local lsp = require("dependency-tree.lsp")
local ts_utils = require("dependency-tree.analyzer.treesitter")

-- Type annotation aliases for documentation
---@alias UseInfo {path: string, components: string[], alias: string|nil}
---@alias NodePosition {line: integer, character: integer}

local M = {}

---Process Rust use statements (imports) to analyze module dependencies
---@param bufnr integer Buffer number to analyze
---@param pos {line: integer, character: integer} Position to analyze
---@param node_id string Node ID in dependency tree
---@param tree table The dependency tree
---@param max_depth integer Maximum recursion depth
---@return boolean success Success status
function M.process_imports(bufnr, pos, node_id, tree, max_depth)
	-- Type validation with detailed error handling
	if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
		vim.notify("process_imports: Invalid buffer", vim.log.levels.ERROR)
		return false
	end

	if type(pos) ~= "table" or type(pos.line) ~= "number" or type(pos.character) ~= "number" then
		vim.notify("process_imports: Invalid position", vim.log.levels.ERROR)
		return false
	end

	if type(node_id) ~= "string" or node_id == "" then
		vim.notify("process_imports: Invalid node_id", vim.log.levels.ERROR)
		return false
	end

	if type(tree) ~= "table" or type(tree.nodes) ~= "table" or not tree.nodes[node_id] then
		vim.notify("process_imports: Invalid tree or node not found", vim.log.levels.ERROR)
		return false
	end

	if type(max_depth) ~= "number" or max_depth < 1 then
		vim.notify("process_imports: Invalid max_depth, using default", vim.log.levels.WARN)
		max_depth = 3
	end

	local file_path = vim.api.nvim_buf_get_name(bufnr)
	if not file_path or file_path == "" then
		vim.notify("process_imports: Empty file path", vim.log.levels.ERROR)
		return false
	end

	-- Get all lines in the buffer with proper error handling
	local lines_success, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, 0, -1, false)
	if not lines_success or not lines or #lines == 0 then
		return false
	end

	local safe_symbol = vim.pesc(symbol)

	-- Check for use statements with this symbol
	for _, line in ipairs(lines) do
		if type(line) == "string" then
			-- Check for direct use
			if line:match("use%s+[%w_:]+::" .. safe_symbol .. "%s*;") then
				return true
			end

			-- Check for use with alias
			if line:match("use%s+[%w_:]+::" .. safe_symbol .. "%s+as%s+") then
				return true
			end

			-- Check for use in braces
			if line:match("use%s+[%w_:]+::%{[^}]*" .. safe_symbol .. "[^}]*%}") then
				return true
			end

			-- Check for glob imports that might include this symbol
			if line:match("use%s+[%w_:]+::%*%s*;") then
				-- We'd need more context to determine if this actually imports the symbol
				-- For now, we'll return true if there's any glob import
				return true
			end
		end
	end

	return false
end

return M
