-----------------
-- languages/go.lua
-----------------
--[[
    Go-specific analysis utilities for dependency-tree.nvim

    This module handles:
    - Go import analysis
    - Package structure detection
    - Interface implementations
    - Method analysis
]]

local config = require("dependency-tree.config")
local utils = require("dependency-tree.utils")
local lsp = require("dependency-tree.lsp")
local ts_utils = require("dependency-tree.analyzer.treesitter")

-- Type annotation aliases for documentation
---@alias ImportInfo {package_path: string, alias: string|nil}
---@alias NodePosition {line: integer, character: integer}

local M = {}

---Process Go imports to analyze package dependencies
---@param bufnr integer Buffer number to analyze
---@param pos {line: integer, character: integer} Position to analyze
---@param node_id string Node ID in dependency tree
---@param tree table The dependency tree
---@param max_depth integer Maximum recursion depth
---@param current_depth integer|nil Current recursion depth
---@return boolean success Success status
function M.process_imports(bufnr, pos, node_id, tree, max_depth, current_depth)
	-- Set default for current_depth
	current_depth = current_depth or 0

	-- Early termination check
	if current_depth >= max_depth - 1 then
		if config.debug_mode then
			vim.notify("Go process_imports: Max depth reached: " .. current_depth, vim.log.levels.DEBUG)
		end
		return false
	end

	-- Type validation with detailed error handling
	if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
		if config.debug_mode then
			vim.notify("process_imports: Invalid buffer", vim.log.levels.DEBUG)
		end
		return false
	end

	if type(pos) ~= "table" or type(pos.line) ~= "number" or type(pos.character) ~= "number" then
		if config.debug_mode then
			vim.notify("process_imports: Invalid position", vim.log.levels.DEBUG)
		end
		return false
	end

	if type(node_id) ~= "string" or node_id == "" then
		if config.debug_mode then
			vim.notify("process_imports: Invalid node_id", vim.log.levels.DEBUG)
		end
		return false
	end

	if type(tree) ~= "table" or type(tree.nodes) ~= "table" or not tree.nodes[node_id] then
		if config.debug_mode then
			vim.notify("process_imports: Invalid tree or node not found", vim.log.levels.DEBUG)
		end
		return false
	end

	if type(max_depth) ~= "number" or max_depth < 1 then
		if config.debug_mode then
			vim.notify("process_imports: Invalid max_depth, using default", vim.log.levels.DEBUG)
		end
		max_depth = 3 -- Default reasonable depth
	end

	local file_path = vim.api.nvim_buf_get_name(bufnr)
	if not file_path or file_path == "" then
		if config.debug_mode then
			vim.notify("process_imports: Empty file path", vim.log.levels.DEBUG)
		end
		return false
	end

	-- Get all lines in the buffer with proper error handling
	local lines_success, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, 0, -1, false)
	if not lines_success or not lines or #lines == 0 then
		if config.debug_mode then
			vim.notify("process_imports: Failed to get buffer lines", vim.log.levels.DEBUG)
		end
		return false
	end

	-- Process import statements
	---@type table<string, ImportInfo>
	local imports = {}

	-- Find the import block(s)
	local in_import_block = false
	local import_start = 0

	for i, line in ipairs(lines) do
		if type(line) ~= "string" then
			goto continue_line
		end

		-- Check for single line import: import "package"
		local single_import = line:match('import%s+"([^"]+)"')
		if single_import then
			local package_name = single_import:match("([^/]+)$") or single_import
			imports[package_name] = {
				package_path = single_import,
			}
			goto continue_line
		end

		-- Check for single line import with alias: import alias "package"
		local alias, aliased_import = line:match('import%s+([%w_]+)%s+"([^"]+)"')
		if alias and aliased_import then
			imports[alias] = {
				package_path = aliased_import,
				alias = alias,
			}
			goto continue_line
		end

		-- Check for start of import block: import (
		if line:match("import%s+%(") then
			in_import_block = true
			import_start = i
			goto continue_line
		end

		-- Check for end of import block: )
		if in_import_block and line:match("%)") then
			in_import_block = false
			goto continue_line
		end

		-- Process imports within the block
		if in_import_block then
			-- Pattern 1: "package/path"
			local package_path = line:match('%s*"([^"]+)"')
			if package_path then
				local package_name = package_path:match("([^/]+)$") or package_path
				imports[package_name] = {
					package_path = package_path,
				}
				goto continue_line
			end

			-- Pattern 2: alias "package/path"
			local block_alias, block_package = line:match('%s*([%w_]+)%s+"([^"]+)"')
			if block_alias and block_package then
				imports[block_alias] = {
					package_path = block_package,
					alias = block_alias,
				}
				goto continue_line
			end
		end

		::continue_line::
	end

	-- Get the function bounds to determine usage
	local bounds = ts_utils.get_function_bounds(bufnr, pos)
	if not bounds then
		bounds = {
			start_line = math.max(0, pos.line - 10),
			end_line = math.min(pos.line + 50, #lines),
		}
	end

	-- Get function content
	local function_lines_success, function_lines =
		pcall(vim.api.nvim_buf_get_lines, bufnr, bounds.start_line, bounds.end_line, false)

	if not function_lines_success or not function_lines or #function_lines == 0 then
		if config.debug_mode then
			vim.notify("process_imports: Failed to get function content", vim.log.levels.DEBUG)
		end
		return false
	end

	local function_text = table.concat(function_lines, "\n")

	-- Now check which imports are used in the function
	local found_count = 0
	for package_name, import_info in pairs(imports) do
		-- Check if the package is used in the function with proper word boundaries
		local safe_pkg = vim.pesc(package_name)
		local is_used = function_text:match("%f[%w_]" .. safe_pkg .. "%.") ~= nil

		if is_used then
			-- Convert Go package import to filesystem path
			local resolved_path_success, resolved_path = pcall(M.resolve_import, import_info.package_path, file_path)
			if not resolved_path_success or not resolved_path then
				goto continue_import
			end

			-- Check if the file/directory exists
			local file_exists_success, file_exists = pcall(function()
				return vim.fn.isdirectory(resolved_path) == 1 or vim.fn.filereadable(resolved_path) == 1
			end)

			if not file_exists_success or not file_exists then
				goto continue_import
			end

			-- If it's a directory, try to find the package main file
			if vim.fn.isdirectory(resolved_path) == 1 then
				-- Look for common Go files in the package directory
				local main_files = { "main.go", "package.go", vim.fn.fnamemodify(resolved_path, ":t") .. ".go" }
				local found_main = false

				for _, main_file in ipairs(main_files) do
					local main_path = resolved_path .. "/" .. main_file
					if vim.fn.filereadable(main_path) == 1 then
						resolved_path = main_path
						found_main = true
						break
					end
				end

				-- If no main file found, try to find any .go file
				if not found_main then
					local cmd
					if vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
						cmd = string.format('dir /b "%s\\*.go" 2>nul', resolved_path)
					else
						cmd = string.format('ls -1 "%s"/*.go 2>/dev/null | head -1', resolved_path)
					end

					local any_go_file = vim.fn.system(cmd):gsub("\n", "")
					if any_go_file ~= "" then
						if vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
							resolved_path = resolved_path .. "\\" .. any_go_file
						else
							resolved_path = resolved_path .. "/" .. any_go_file
						end
					else
						goto continue_import
					end
				end
			end

			-- Create a buffer for the Go file
			local import_bufnr
			local buf_success, buf_result = pcall(vim.uri_to_bufnr, "file://" .. resolved_path)

			if not buf_success or type(buf_result) ~= "number" then
				if config.debug_mode then
					vim.notify("process_imports: Failed to create buffer for: " .. resolved_path, vim.log.levels.DEBUG)
				end
				goto continue_import
			end

			import_bufnr = buf_result

			-- Load file if necessary with error handling
			if not vim.api.nvim_buf_is_loaded(import_bufnr) then
				local load_success = pcall(vim.fn.bufload, import_bufnr)
				if not load_success then
					if config.debug_mode then
						vim.notify("process_imports: Failed to load buffer: " .. resolved_path, vim.log.levels.DEBUG)
					end
					goto continue_import
				end
			end

			-- Find which functions from this package are used in the function
			local functions_used = {}

			-- Extract all package.Function patterns
			for _, func_line in ipairs(function_lines) do
				if type(func_line) ~= "string" then
					goto continue_func_line
				end

				-- Find all occurrences of package.Function pattern
				for func_name in func_line:gmatch(package_name .. "%.([%w_]+)") do
					if func_name and func_name ~= "" and not functions_used[func_name] then
						functions_used[func_name] = true
					end
				end

				::continue_func_line::
			end

			-- If we found specific functions used, try to find them in the package
			if next(functions_used) then
				for func_name, _ in pairs(functions_used) do
					local func_pos = M.find_function_in_package(import_bufnr, func_name)
					if func_pos then
						-- Add this function to the dependency tree with proper depth tracking
						local analyzer_success, _ = pcall(function()
							local analyzer = require("dependency-tree.analyzer")
							analyzer.build_dependency_tree(
								import_bufnr,
								func_pos,
								current_depth + 1,
								max_depth,
								"down",
								tree,
								node_id
							)
						end)

						if analyzer_success then
							found_count = found_count + 1
						end
					end
				end
			else
				-- If no specific functions were found but the package is used, add package-level dependency
				-- Find exported functions in the file
				local exported_func_pos = M.find_exported_function(import_bufnr)
				if exported_func_pos then
					local analyzer_success, _ = pcall(function()
						local analyzer = require("dependency-tree.analyzer")
						analyzer.build_dependency_tree(
							import_bufnr,
							exported_func_pos,
							current_depth + 1,
							max_depth,
							"down",
							tree,
							node_id
						)
					end)

					if analyzer_success then
						found_count = found_count + 1
					end
				end
			end

			-- Record the package usage in variables_used
			if tree.nodes[node_id] then
				local is_duplicate = false
				for _, var_used in ipairs(tree.nodes[node_id].variables_used) do
					if type(var_used) == "table" and var_used.name == package_name then
						is_duplicate = true
						break
					end
				end

				if not is_duplicate then
					table.insert(tree.nodes[node_id].variables_used, {
						name = package_name,
						package_path = import_info.package_path,
						is_package = true,
						definition = {
							path = resolved_path,
							uri = "file://" .. resolved_path,
						},
					})
				end
			end
		end

		::continue_import::
	end

	return found_count > 0
end

---Resolve Go import to filesystem path
---@param package_path string Go package import path
---@param current_file_path string Current file path
---@return string|nil Resolved filesystem path or nil
function M.resolve_import(package_path, current_file_path)
	-- Type validation
	if type(package_path) ~= "string" or package_path == "" then
		error("resolve_import: Invalid package path")
	end

	if type(current_file_path) ~= "string" or current_file_path == "" then
		error("resolve_import: Invalid current file path")
	end

	-- Check for standard library packages
	local stdlib_packages = {
		"fmt",
		"os",
		"io",
		"bufio",
		"bytes",
		"strings",
		"strconv",
		"math",
		"time",
		"errors",
		"sync",
		"context",
		"encoding",
		"net",
		"http",
		"path",
		"reflect",
		"sort",
		"runtime",
		"database",
	}

	for _, std_pkg in ipairs(stdlib_packages) do
		if package_path == std_pkg or package_path:match("^" .. std_pkg .. "/") then
			-- Standard library package - can't analyze directly
			return nil
		end
	end

	-- Handle relative imports in the same module (rare in Go but possible)
	if package_path:match("^%.") then
		local dir = vim.fn.fnamemodify(current_file_path, ":h")
		return dir .. "/" .. package_path:gsub("^%.", "")
	end

	-- Try to find GOPATH
	local gopath = os.getenv("GOPATH")
	if not gopath or gopath == "" then
		-- Default GOPATH fallback
		if vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
			gopath = vim.fn.expand("$HOME") .. "\\go"
		else
			gopath = vim.fn.expand("$HOME") .. "/go"
		end
	end

	-- Try to find the Go module root
	local go_mod_root = ""
	local current_dir = vim.fn.fnamemodify(current_file_path, ":h")
	while current_dir ~= "/" do
		if vim.fn.filereadable(current_dir .. "/go.mod") == 1 then
			go_mod_root = current_dir
			break
		end
		current_dir = vim.fn.fnamemodify(current_dir, ":h")
	end

	-- Possible locations:
	-- 1. In the module's vendor directory
	-- 2. In the GOPATH/src
	-- 3. In the GOPATH/pkg/mod (for downloaded modules)
	local possible_paths = {}

	if go_mod_root ~= "" then
		table.insert(possible_paths, go_mod_root .. "/vendor/" .. package_path)
	end

	-- Add GOPATH paths using proper platform separators
	if vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
		table.insert(possible_paths, gopath .. "\\src\\" .. package_path:gsub("/", "\\"))
		table.insert(possible_paths, gopath .. "\\pkg\\mod\\" .. package_path:gsub("/", "\\"))
	else
		table.insert(possible_paths, gopath .. "/src/" .. package_path)
		table.insert(possible_paths, gopath .. "/pkg/mod/" .. package_path)
	end

	-- Check each path
	for _, path in ipairs(possible_paths) do
		local exists_success, exists = pcall(function()
			return vim.fn.isdirectory(path) == 1 or vim.fn.filereadable(path) == 1
		end)

		if exists_success and exists then
			return path
		end
	end

	-- Fallback: use LSP to try to find the file
	local bufnr = vim.api.nvim_get_current_buf()
	local lsp_clients = vim.lsp.get_active_clients({ bufnr = bufnr })

	for _, client in ipairs(lsp_clients) do
		if client.name == "gopls" then
			-- Create a temporary position for lookup
			local pos = { line = 0, character = 0 }

			-- Try to get definition through LSP
			local params = {
				textDocument = { uri = vim.uri_from_bufnr(bufnr) },
				position = pos,
				text = package_path,
			}

			local def_result = vim.lsp.buf_request_sync(bufnr, "textDocument/definition", params, 1000)
			if def_result then
				for _, res in pairs(def_result) do
					if res.result and #res.result > 0 then
						local def_uri = res.result[1].uri
						if def_uri then
							return def_uri:gsub("file://", "")
						end
					end
				end
			end

			break
		end
	end

	-- Last resort: just construct a path based on GOPATH
	if vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
		return gopath .. "\\src\\" .. package_path:gsub("/", "\\")
	else
		return gopath .. "/src/" .. package_path
	end
end

---Find a function in a Go package
---@param bufnr integer Buffer number to search
---@param function_name string Function name to find
---@return NodePosition|nil Position {line, character} or nil if not found
function M.find_function_in_package(bufnr, function_name)
	-- Type validation
	if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
		if config.debug_mode then
			vim.notify("find_function_in_package: Invalid buffer", vim.log.levels.DEBUG)
		end
		return nil
	end

	if type(function_name) ~= "string" or function_name == "" then
		if config.debug_mode then
			vim.notify("find_function_in_package: Invalid function name", vim.log.levels.DEBUG)
		end
		return nil
	end

	-- Get lines with proper error handling
	local lines_success, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, 0, -1, false)
	if not lines_success or not lines or #lines == 0 then
		if config.debug_mode then
			vim.notify("find_function_in_package: Failed to get buffer lines", vim.log.levels.DEBUG)
		end
		return nil
	end

	-- Go specific: check for exported function (first letter capitalized)
	local is_exported = function_name:sub(1, 1):match("%u") ~= nil

	if not is_exported then
		-- Function is not exported, won't be able to find it
		if config.debug_mode then
			vim.notify(
				"find_function_in_package: Function '" .. function_name .. "' is not exported (not capitalized)",
				vim.log.levels.DEBUG
			)
		end
		return nil
	end

	-- Go function patterns
	local safe_fn = vim.pesc(function_name)

	local patterns = {
		-- Function definition patterns
		"func%s+"
			.. safe_fn
			.. "%s*%(",
		"func%s+%([^)]+%)%s*" .. safe_fn .. "%s*%(", -- method
	}

	-- Find the function definition
	for i, line in ipairs(lines) do
		if type(line) ~= "string" then
			goto continue_line
		end

		for _, pattern in ipairs(patterns) do
			if line:match(pattern) then
				local col = line:find(function_name)
				if col then
					return { line = i - 1, character = col - 1 }
				end
			end
		end

		::continue_line::
	end

	-- Try using treesitter for better accuracy
	if vim.treesitter then
		local parser_success, parser = pcall(vim.treesitter.get_parser, bufnr)
		if parser_success and parser then
			local tree_success, tree = pcall(function()
				return parser:parse()[1]
			end)

			if tree_success and tree then
				local root_success, root = pcall(function()
					return tree:root()
				end)

				if root_success and root then
					-- Construct Go-specific query
					local query_str = string.format(
						[[
                        (function_declaration
                            name: (identifier) @name (#eq? @name "%s"))

                        (method_declaration
                            name: (field_identifier) @name (#eq? @name "%s"))
                    ]],
						function_name,
						function_name
					)

					local query_success, query = pcall(vim.treesitter.query.parse, "go", query_str)
					if query_success and query then
						for id, node in query:iter_captures(root, bufnr, 0, -1) do
							local range_success, range = pcall(function()
								return { node:range() }
							end)

							if range_success and range and #range >= 2 then
								local start_row, start_col = range[1], range[2]
								return { line = start_row, character = start_col }
							end
						end
					end
				end
			end
		end
	end

	-- Not found
	return nil
end

---Find an exported function in a Go file
---@param bufnr integer Buffer number
---@return NodePosition|nil Position of first exported function or nil
function M.find_exported_function(bufnr)
	-- Type validation
	if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
		if config.debug_mode then
			vim.notify("find_exported_function: Invalid buffer", vim.log.levels.DEBUG)
		end
		return nil
	end

	-- Get lines with proper error handling
	local lines_success, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, 0, -1, false)
	if not lines_success or not lines or #lines == 0 then
		if config.debug_mode then
			vim.notify("find_exported_function: Failed to get buffer lines", vim.log.levels.DEBUG)
		end
		return nil
	end

	-- Scan for exported function (capitalized first letter)
	for i, line in ipairs(lines) do
		if type(line) ~= "string" then
			goto continue_line
		end

		-- Look for func ExportedFunc(
		local exported_func = line:match("func%s+([A-Z][%w_]*)%s*%(")
		if exported_func then
			local col = line:find(exported_func)
			if col then
				return { line = i - 1, character = col - 1 }
			end
		end

		-- Also check for methods on exported types: func (t Type) ExportedMethod(
		local receiver_type, exported_method = line:match("func%s+%([^)]+%)%s+([A-Z][%w_]*)%s*%.%s*([A-Z][%w_]*)%s*%(")
		if exported_method then
			local col = line:find(exported_method)
			if col then
				return { line = i - 1, character = col - 1 }
			end
		end

		::continue_line::
	end

	-- If no exported functions found, return the first function as fallback
	for i, line in ipairs(lines) do
		if type(line) == "string" and line:match("func%s+") then
			return { line = i - 1, character = 0 }
		end
	end

	-- No functions found at all, just return first line
	return { line = 0, character = 0 }
end

---Find implementation of a Go function or method
---@param file_path string Path to the file
---@param symbol_name string Symbol name to find
---@param lines string[] Array of file content lines
---@return {line: integer, column: integer, type: string, content: string}|nil Implementation info or nil if not found
function M.find_implementation(file_path, symbol_name, lines)
	-- Type validation
	if type(file_path) ~= "string" or file_path == "" then
		if config.debug_mode then
			vim.notify("find_implementation: Invalid file path", vim.log.levels.DEBUG)
		end
		return nil
	end

	if type(symbol_name) ~= "string" or symbol_name == "" then
		if config.debug_mode then
			vim.notify("find_implementation: Invalid symbol name", vim.log.levels.DEBUG)
		end
		return nil
	end

	if type(lines) ~= "table" or #lines == 0 then
		if config.debug_mode then
			vim.notify("find_implementation: Invalid lines array", vim.log.levels.DEBUG)
		end
		return nil
	end

	local safe_symbol = vim.pesc(symbol_name)

	-- Patterns to detect different kinds of Go definitions
	local patterns = {
		-- Function definitions
		{ pattern = "func%s+" .. safe_symbol .. "%s*%(", type = "function" },

		-- Method definitions
		{ pattern = "func%s+%([^)]+%)%s+" .. safe_symbol .. "%s*%(", type = "method" },

		-- Interface definitions
		{ pattern = "type%s+" .. safe_symbol .. "%s+interface%s*{", type = "interface" },

		-- Struct definitions
		{ pattern = "type%s+" .. safe_symbol .. "%s+struct%s*{", type = "struct" },

		-- Type aliases
		{ pattern = "type%s+" .. safe_symbol .. "%s+[%w_%.]+", type = "type_alias" },

		-- Variables and constants
		{ pattern = "var%s+" .. safe_symbol .. "%s+", type = "variable" },
		{ pattern = "const%s+" .. safe_symbol .. "%s+", type = "constant" },
	}

	for i, line in ipairs(lines) do
		if type(line) ~= "string" then
			goto continue_line
		end

		for _, pattern_info in ipairs(patterns) do
			if line:match(pattern_info.pattern) then
				local col = line:find(symbol_name)
				if col then
					return {
						line = i,
						column = col,
						type = pattern_info.type,
						content = line,
					}
				end
			end
		end

		::continue_line::
	end

	return nil
end

---Check if a symbol is an imported package
---@param bufnr integer Buffer number
---@param symbol string Symbol name to check
---@return boolean Whether the symbol is an imported package
function M.is_imported_package(bufnr, symbol)
	-- Type validation
	if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
		if config.debug_mode then
			vim.notify("is_imported_package: Invalid buffer", vim.log.levels.DEBUG)
		end
		return false
	end

	if type(symbol) ~= "string" or symbol == "" then
		if config.debug_mode then
			vim.notify("is_imported_package: Invalid symbol", vim.log.levels.DEBUG)
		end
		return false
	end

	local lines_success, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, 0, -1, false)
	if not lines_success or not lines or #lines == 0 then
		return false
	end

	local safe_symbol = vim.pesc(symbol)

	-- Check for import with this name/alias
	local in_import_block = false

	for _, line in ipairs(lines) do
		if type(line) ~= "string" then
			goto continue_line
		end

		-- Check for single line imports with the symbol as an alias
		if line:match("import%s+" .. safe_symbol .. '%s+"') then
			return true
		end

		-- Check for import block start
		if line:match("import%s+%(") then
			in_import_block = true
			goto continue_line
		end

		-- Check for import block end
		if in_import_block and line:match("%)") then
			in_import_block = false
			goto continue_line
		end

		-- Inside import block, check for the specific alias
		if in_import_block and line:match("%s*" .. safe_symbol .. '%s+"') then
			return true
		end

		-- Check if the symbol matches the last part of a package path
		if in_import_block then
			local package_path = line:match('%s*"([^"]+)"')
			if package_path then
				local package_name = package_path:match("([^/]+)$") or package_path
				if package_name == symbol then
					return true
				end
			end
		end

		::continue_line::
	end

	return false
end

return M
