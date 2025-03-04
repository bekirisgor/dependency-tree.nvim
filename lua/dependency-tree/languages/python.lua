-----------------
-- languages/python.lua
-----------------
--[[
    Python-specific analysis utilities for dependency-tree.nvim

    This module handles:
    - Python import analysis (import, from ... import)
    - Python classes and methods
    - Special handling for decorators and magic methods
]]

local config = require("dependency-tree.config")
local utils = require("dependency-tree.utils")
local lsp = require("dependency-tree.lsp")
local ts_utils = require("dependency-tree.analyzer.treesitter")

local M = {}

---Process Python imports with different import styles
---@param bufnr number Buffer number to analyze
---@param pos table Position {line, character} to analyze
---@param node_id string Node ID in dependency tree
---@param tree table The dependency tree
---@param max_depth number Maximum recursion depth
---@param current_depth number|nil Current recursion depth
---@return boolean Success status
function M.process_imports(bufnr, pos, node_id, tree, max_depth, current_depth)
	-- Set default for current_depth
	current_depth = current_depth or 0

	-- Early termination check
	if current_depth >= max_depth - 1 then
		if config.debug_mode then
			vim.notify("Python process_imports: Max depth reached: " .. current_depth, vim.log.levels.DEBUG)
		end
		return false
	end

	-- Type validation with detailed error handling
	if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
		if config.debug_mode then
			vim.notify("process_python_imports: Invalid buffer", vim.log.levels.DEBUG)
		end
		return false
	end

	if type(pos) ~= "table" or type(pos.line) ~= "number" or type(pos.character) ~= "number" then
		if config.debug_mode then
			vim.notify("process_python_imports: Invalid position", vim.log.levels.DEBUG)
		end
		return false
	end

	if type(node_id) ~= "string" or not tree.nodes[node_id] then
		if config.debug_mode then
			vim.notify("process_python_imports: Invalid node_id", vim.log.levels.DEBUG)
		end
		return false
	end

	local file_path = vim.api.nvim_buf_get_name(bufnr)
	if not file_path or file_path == "" then
		if config.debug_mode then
			vim.notify("process_python_imports: Empty file path", vim.log.levels.DEBUG)
		end
		return false
	end

	-- Get all lines in the buffer
	local lines_success, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, 0, -1, false)
	if not lines_success or not lines or #lines == 0 then
		if config.debug_mode then
			vim.notify("process_python_imports: Failed to get buffer content", vim.log.levels.DEBUG)
		end
		return false
	end

	-- Process different types of imports
	local imports = {}

	-- Handle standard imports: import module, import module as alias
	local standard_imports = {}
	for _, line in ipairs(lines) do
		if type(line) ~= "string" then
			goto continue_line
		end

		-- Match "import module" or "import module as alias"
		local module_name, alias = line:match("^%s*import%s+([%w_.]+)%s*")
		if module_name then
			-- Check if there's an alias
			alias = line:match("^%s*import%s+[%w_.]+%s+as%s+([%w_]+)")

			standard_imports[alias or module_name] = {
				module = module_name,
				alias = alias,
				type = "standard",
			}
		end

		-- Match "from module import name1, name2"
		local from_module = line:match("^%s*from%s+([%w_.]+)%s+import%s+")
		if from_module then
			-- Extract all imported names
			local names_part = line:match("^%s*from%s+[%w_.]+%s+import%s+(.+)$")
			if names_part then
				-- Handle both comma-separated imports and parenthesized imports
				if names_part:match("%(") then
					-- Multi-line import: from module import (
					--                       name1,
					--                       name2,
					--                     )
					-- Currently just capturing the first part, would need more complex parsing for multi-line
					names_part = names_part:gsub("%(", ""):gsub("%)", "")
				end

				for name in names_part:gmatch("([^,]+)") do
					-- Clean up whitespace
					name = name:gsub("^%s*", ""):gsub("%s*$", "")

					-- Check for alias: name as alias
					local item_name, item_alias = name:match("([%w_]+)%s+as%s+([%w_]+)")

					if item_name then
						imports[item_alias] = {
							module = from_module,
							name = item_name,
							alias = item_alias,
							type = "from",
						}
					else
						-- No alias
						imports[name] = {
							module = from_module,
							name = name,
							type = "from",
						}
					end
				end
			end
		end

		::continue_line::
	end

	-- Add standard imports to the imports table
	for name, info in pairs(standard_imports) do
		imports[name] = info
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
	local function_lines = vim.api.nvim_buf_get_lines(bufnr, bounds.start_line, bounds.end_line, false)
	local function_text = table.concat(function_lines, "\n")

	-- Track if we found any imports that are used
	local found_used_imports = false

	-- Now check which imports are used in the function
	for symbol, import_info in pairs(imports) do
		-- Check if the symbol is used in the function
		local is_used = function_text:match("%f[%w_]" .. symbol .. "%f[^%w_]") ~= nil

		if is_used then
			found_used_imports = true

			-- Try to resolve the import based on Python's import system
			local resolved_module = M.resolve_python_import(import_info.module, file_path)

			if resolved_module then
				-- Try to find the module file
				local module_file = M.find_python_module(resolved_module)

				if module_file then
					-- Try to find the specific symbol in the module
					local found = false

					if import_info.type == "from" then
						-- For "from module import name", we need to find the specific name
						local symbol_info = M.find_symbol_in_python_file(module_file, import_info.name)

						if symbol_info then
							found = true
							local import_bufnr = vim.uri_to_bufnr("file://" .. module_file)

							-- Load the buffer if necessary
							if not vim.api.nvim_buf_is_loaded(import_bufnr) then
								pcall(vim.fn.bufload, import_bufnr)
							end

							-- Add this to the dependency tree
							local symbol_pos = { line = symbol_info.line, character = symbol_info.column }

							-- Add the import to the dependency tree with error handling and proper depth tracking
							pcall(function()
								local analyzer = require("dependency-tree.analyzer")
								analyzer.build_dependency_tree(
									import_bufnr,
									symbol_pos,
									current_depth + 1,
									max_depth,
									"down",
									tree,
									node_id
								)
							end)
						end
					else
						-- For "import module", we need to find the module itself
						found = true
						local import_bufnr = vim.uri_to_bufnr("file://" .. module_file)

						-- Load the buffer if necessary
						if not vim.api.nvim_buf_is_loaded(import_bufnr) then
							pcall(vim.fn.bufload, import_bufnr)
						end

						-- We'll use line 0 as a reference to the whole module
						local module_pos = { line = 0, character = 0 }

						-- Add the import to the dependency tree with error handling and proper depth tracking
						pcall(function()
							local analyzer = require("dependency-tree.analyzer")
							analyzer.build_dependency_tree(
								import_bufnr,
								module_pos,
								current_depth + 1,
								max_depth,
								"down",
								tree,
								node_id
							)
						end)
					end

					-- Add import usage to variables_used
					if found and tree.nodes[node_id] then
						-- Check for duplicates
						local is_duplicate = false
						for _, entry in ipairs(tree.nodes[node_id].variables_used) do
							if entry.name == symbol then
								is_duplicate = true
								break
							end
						end

						if not is_duplicate then
							table.insert(tree.nodes[node_id].variables_used, {
								name = symbol,
								is_import = true,
								import_info = {
									module = import_info.module,
									name = import_info.name,
									type = import_info.type,
									resolved_file = module_file,
								},
							})
						end
					end
				end
			end
		end
	end

	return found_used_imports
end

---Resolve a Python import path to a file system path
---@param module_path string Import path (e.g., "os.path")
---@param current_file_path string Path of the current file
---@return string|nil Resolved filesystem path or nil if not found
function M.resolve_python_import(module_path, current_file_path)
	if not module_path or module_path == "" then
		return nil
	end

	-- Handle relative imports
	if module_path:sub(1, 1) == "." then
		local current_dir = vim.fn.fnamemodify(current_file_path, ":h")
		local level = 0

		-- Count leading dots for relative imports
		for i = 1, #module_path do
			if module_path:sub(i, i) == "." then
				level = level + 1
			else
				break
			end
		end

		-- Remove the dots prefix
		module_path = module_path:sub(level + 1)

		-- Go up directories based on dot count
		for _ = 1, level do
			current_dir = vim.fn.fnamemodify(current_dir, ":h")
		end

		-- Calculate the relative path
		if module_path == "" then
			-- just ".." import, pointing to the package itself
			return current_dir
		else
			-- Convert module dots to directory separators
			local rel_path = module_path:gsub("%.", "/")
			return current_dir .. "/" .. rel_path
		end
	end

	-- Regular (absolute) imports

	-- First, try to find in the project root
	local project_root = utils.get_project_root()

	-- Convert module dots to directory separators
	local module_fs_path = module_path:gsub("%.", "/")

	-- Check common Python project structures
	local possible_paths = {
		project_root .. "/" .. module_fs_path,
		project_root .. "/src/" .. module_fs_path,
		project_root .. "/lib/" .. module_fs_path,
	}

	for _, path in ipairs(possible_paths) do
		-- Try with .py extension
		if vim.fn.filereadable(path .. ".py") == 1 then
			return path .. ".py"
		end

		-- Try as a directory with __init__.py (package)
		if vim.fn.isdirectory(path) == 1 and vim.fn.filereadable(path .. "/__init__.py") == 1 then
			return path .. "/__init__.py"
		end
	end

	-- For standard library modules, we can't easily resolve without runtime info
	-- Just return the module path for reference
	return module_path
end

---Find a Python module file in the file system
---@param module_path string Module path (can be a path or a module name)
---@return string|nil Path to the module file or nil if not found
function M.find_python_module(module_path)
	if not module_path or module_path == "" then
		return nil
	end

	-- If it's already a file path ending with .py, just return it
	if module_path:sub(-3) == ".py" and vim.fn.filereadable(module_path) == 1 then
		return module_path
	end

	-- Try as a directory with __init__.py
	if vim.fn.isdirectory(module_path) == 1 and vim.fn.filereadable(module_path .. "/__init__.py") == 1 then
		return module_path .. "/__init__.py"
	end

	-- Try with .py extension
	if vim.fn.filereadable(module_path .. ".py") == 1 then
		return module_path .. ".py"
	end

	-- For module names, we'd need to check Python's import path
	-- This is a simplified approximation
	local project_root = utils.get_project_root()

	-- Convert dots to path separators
	local fs_path = module_path:gsub("%.", "/")

	-- Check common locations
	local possible_paths = {
		project_root .. "/" .. fs_path .. ".py",
		project_root .. "/src/" .. fs_path .. ".py",
		project_root .. "/" .. fs_path .. "/__init__.py",
		project_root .. "/src/" .. fs_path .. "/__init__.py",
	}

	for _, path in ipairs(possible_paths) do
		if vim.fn.filereadable(path) == 1 then
			return path
		end
	end

	return nil
end

---Find a symbol (function, class, variable) in a Python file
---@param file_path string Path to the Python file
---@param symbol_name string Name of the symbol to find
---@return table|nil {line: number, column: number} or nil if not found
function M.find_symbol_in_python_file(file_path, symbol_name)
	if not file_path or not symbol_name then
		return nil
	end

	-- Read the file contents
	local lines = utils.read_file_contents(file_path)
	if not lines or #lines == 0 then
		return nil
	end

	-- Pattern matching for different Python constructs
	for i, line in ipairs(lines) do
		if type(line) ~= "string" then
			goto continue_line
		end

		-- Function definition: def name(
		local func_match = line:match("^%s*def%s+" .. vim.pesc(symbol_name) .. "%s*%(")
		if func_match then
			local col = line:find("def%s+" .. vim.pesc(symbol_name)) or 0
			return { line = i - 1, column = col }
		end

		-- Class definition: class name(
		local class_match = line:match("^%s*class%s+" .. vim.pesc(symbol_name) .. "%s*[%(:]")
		if class_match then
			local col = line:find("class%s+" .. vim.pesc(symbol_name)) or 0
			return { line = i - 1, column = col }
		end

		-- Variable assignment: name =
		local var_match = line:match("^%s*" .. vim.pesc(symbol_name) .. "%s*=")
		if var_match then
			local col = line:find(vim.pesc(symbol_name))
			if col then
				return { line = i - 1, column = col - 1 }
			end
		end

		-- Import with alias: import X as symbol_name
		local import_alias = line:match("import%s+[%w_.]+%s+as%s+" .. vim.pesc(symbol_name))
		if import_alias then
			local col = line:find("as%s+" .. vim.pesc(symbol_name)) or 0
			return { line = i - 1, column = col }
		end

		::continue_line::
	end

	-- If we didn't find the exact symbol, it might be a re-export or a property
	-- Try using LSP if available
	local bufnr = vim.uri_to_bufnr("file://" .. file_path)
	if vim.api.nvim_buf_is_loaded(bufnr) then
		-- Use workspace symbol search
		local params = { query = symbol_name }
		local result = vim.lsp.buf_request_sync(bufnr, "workspace/symbol", params, 1000)

		if result then
			for _, res in pairs(result) do
				if res.result then
					for _, sym in ipairs(res.result) do
						if sym.name == symbol_name then
							local uri = sym.location.uri or sym.location.targetUri
							if uri:gsub("file://", "") == file_path then
								local range = sym.location.range
								return {
									line = range.start.line,
									column = range.start.character,
								}
							end
						end
					end
				end
			end
		end
	end

	return nil
end

---Find implementation of a Python function or method
---@param file_path string Path to the file
---@param symbol_name string Name of the symbol
---@param lines table Array of file content lines
---@return table|nil Implementation info or nil if not found
function M.find_implementation(file_path, symbol_name, lines)
	if not file_path or not symbol_name or not lines then
		return nil
	end

	for i, line in ipairs(lines) do
		if type(line) ~= "string" then
			goto continue_line
		end

		-- Function definition
		local func_match = line:match("^%s*def%s+" .. vim.pesc(symbol_name) .. "%s*%(")
		if func_match then
			local col = line:find("def%s+" .. vim.pesc(symbol_name)) or 0
			return {
				line = i,
				column = col,
				type = "function",
			}
		end

		-- Method definition (inside a class)
		local method_match = line:match("^%s*def%s+" .. vim.pesc(symbol_name) .. "%s*%(self")
		if method_match then
			local col = line:find("def%s+" .. vim.pesc(symbol_name)) or 0
			return {
				line = i,
				column = col,
				type = "method",
			}
		end

		-- Class definition
		local class_match = line:match("^%s*class%s+" .. vim.pesc(symbol_name) .. "%s*[%(:]")
		if class_match then
			local col = line:find("class%s+" .. vim.pesc(symbol_name)) or 0
			return {
				line = i,
				column = col,
				type = "class",
			}
		end

		-- Lambda assignment
		local lambda_match = line:match(vim.pesc(symbol_name) .. "%s*=%s*lambda")
		if lambda_match then
			local col = line:find(vim.pesc(symbol_name)) or 0
			return {
				line = i,
				column = col,
				type = "lambda",
			}
		end

		::continue_line::
	end

	return nil
end

return M
