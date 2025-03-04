-----------------
-- languages/lua.lua
-----------------
--[[
    Lua-specific analysis utilities for dependency-tree.nvim

    This module handles:
    - Lua module system (require)
    - Function definitions and references in Lua
    - Metatable and inheritance patterns
]]

local config = require("dependency-tree.config")
local utils = require("dependency-tree.utils")
local lsp = require("dependency-tree.lsp")
local ts_utils = require("dependency-tree.analyzer.treesitter")

local M = {}

---Process Lua requires for dependency tracking
---@param bufnr number Buffer number to analyze
---@param pos table Position {line, character} to analyze
---@param node_id string Node ID in dependency tree
---@param tree table The dependency tree
---@param max_depth number Maximum recursion depth
---@return boolean Success status
function M.process_requires(bufnr, pos, node_id, tree, max_depth)
	-- Type validation with detailed error handling
	if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
		vim.notify("process_lua_requires: Invalid buffer", vim.log.levels.ERROR)
		return false
	end

	if type(pos) ~= "table" or type(pos.line) ~= "number" or type(pos.character) ~= "number" then
		vim.notify("process_lua_requires: Invalid position", vim.log.levels.ERROR)
		return false
	end

	if type(node_id) ~= "string" or not tree.nodes[node_id] then
		vim.notify("process_lua_requires: Invalid node_id", vim.log.levels.ERROR)
		return false
	end

	local file_path = vim.api.nvim_buf_get_name(bufnr)
	if not file_path or file_path == "" then
		vim.notify("process_lua_requires: Empty file path", vim.log.levels.ERROR)
		return false
	end

	-- Get all lines in the buffer
	local lines_success, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, 0, -1, false)
	if not lines_success or not lines or #lines == 0 then
		vim.notify("process_lua_requires: Failed to get buffer content", vim.log.levels.ERROR)
		return false
	end

	-- Process different types of requires
	local requires = {}

	for _, line in ipairs(lines) do
		if type(line) == "string" then
			-- Match standard require: local module = require("module")
			local var_name, module_path = line:match("local%s+([%w_]+)%s*=%s*require%s*%(%s*[\"']([^\"']+)[\"']%s*%)")
			if var_name and module_path then
				requires[var_name] = {
					path = module_path,
					type = "standard",
				}
			end

			-- Match direct require: require("module")
			local direct_module = line:match("require%s*%(%s*[\"']([^\"']+)[\"']%s*%)")
			if direct_module and not module_path then -- Avoid duplicates with standard requires
				requires["_direct_" .. direct_module] = {
					path = direct_module,
					type = "direct",
				}
			end

			-- Match destructured require: local func1, func2 = require("module").func1, require("module").func2
			local destructured = line:match("local%s+([^=]+)%s*=%s*require%s*%(%s*[\"']([^\"']+)[\"']%s*%)%.")
			if destructured then
				-- This is a complex pattern, might need refinement for all cases
				local var_list = destructured:match("([^=]+)")
				if var_list then
					for var in var_list:gmatch("([%w_]+)%s*,?") do
						requires[var] = {
							path = module_path,
							type = "destructured",
							member = var,
						}
					end
				end
			end

			-- Match module dot notation: local func = require("module").func
			local single_var, dot_module, member =
				line:match("local%s+([%w_]+)%s*=%s*require%s*%(%s*[\"']([^\"']+)[\"']%s*%)%.([%w_]+)")
			if single_var and dot_module and member then
				requires[single_var] = {
					path = dot_module,
					type = "member",
					member = member,
				}
			end
		end
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

	-- Track if we found any requires that are used
	local found_used_requires = false

	-- Now check which requires are used in the function
	for var_name, require_info in pairs(requires) do
		-- Check if the variable is used in the function
		local is_used = function_text:match("%f[%w_]" .. var_name .. "%f[^%w_]") ~= nil

		-- For direct requires without a variable assignment, assume they're used
		if require_info.type == "direct" and var_name:sub(1, 8) == "_direct_" then
			is_used = true
		end

		if is_used then
			found_used_requires = true

			-- Resolve the module path
			local resolved_module = M.resolve_lua_require(require_info.path, file_path)

			if resolved_module then
				-- Check if the module file exists
				if vim.fn.filereadable(resolved_module) == 1 then
					local module_bufnr = vim.uri_to_bufnr("file://" .. resolved_module)

					-- Load the buffer if necessary
					if not vim.api.nvim_buf_is_loaded(module_bufnr) then
						pcall(vim.fn.bufload, module_bufnr)
					end

					-- Find the specific symbol if needed
					if require_info.type == "member" or require_info.type == "destructured" then
						local symbol_info = M.find_symbol_in_lua_file(resolved_module, require_info.member)

						if symbol_info then
							local symbol_pos = { line = symbol_info.line, character = symbol_info.column }

							-- Add the module member to the dependency tree
							pcall(function()
								local analyzer = require("dependency-tree.analyzer")
								analyzer.build_dependency_tree(
									module_bufnr,
									symbol_pos,
									1,
									max_depth,
									"down",
									tree,
									node_id
								)
							end)
						end
					else
						-- For standard requires, we reference the entire module
						-- Find the module's "return" statement or main function
						local module_pos = M.find_lua_module_entry(resolved_module)

						if not module_pos then
							-- Default to the first line
							module_pos = { line = 0, character = 0 }
						end

						-- Add the module to the dependency tree
						pcall(function()
							local analyzer = require("dependency-tree.analyzer")
							analyzer.build_dependency_tree(
								module_bufnr,
								module_pos,
								1,
								max_depth,
								"down",
								tree,
								node_id
							)
						end)
					end

					-- Add require usage to variables_used
					if tree.nodes[node_id] then
						-- Check for duplicates
						local is_duplicate = false
						for _, entry in ipairs(tree.nodes[node_id].variables_used) do
							if entry.name == var_name then
								is_duplicate = true
								break
							end
						end

						if not is_duplicate then
							table.insert(tree.nodes[node_id].variables_used, {
								name = var_name,
								is_require = true,
								require_info = {
									path = require_info.path,
									type = require_info.type,
									member = require_info.member,
									resolved_file = resolved_module,
								},
							})
						end
					end
				end
			end
		end
	end

	return found_used_requires
end

---Resolve a Lua require path to a file system path
---@param require_path string The require path (e.g., "dependency-tree.config")
---@param current_file_path string Path of the current file
---@return string|nil Resolved filesystem path or nil if not found
function M.resolve_lua_require(require_path, current_file_path)
	if not require_path or require_path == "" then
		return nil
	end

	-- Convert Lua module dots to directory separators
	local fs_path = require_path:gsub("%.", "/")

	-- For Neovim plugins, try to resolve based on common patterns
	local project_root = utils.get_project_root()

	-- Check common Lua module locations
	local possible_paths = {
		-- Direct module file
		project_root
			.. "/lua/"
			.. fs_path
			.. ".lua",
		project_root .. "/" .. fs_path .. ".lua",

		-- init.lua in directory
		project_root
			.. "/lua/"
			.. fs_path
			.. "/init.lua",
		project_root .. "/" .. fs_path .. "/init.lua",
	}

	for _, path in ipairs(possible_paths) do
		if vim.fn.filereadable(path) == 1 then
			return path
		end
	end

	-- Try to find in Neovim runtime path
	local runtime_success, runtime_path = pcall(vim.api.nvim_get_runtime_file, fs_path .. ".lua", false)
	if runtime_success and runtime_path and #runtime_path > 0 then
		return runtime_path[1]
	end

	-- Try to find init.lua in runtime path
	local init_success, init_path = pcall(vim.api.nvim_get_runtime_file, fs_path .. "/init.lua", false)
	if init_success and init_path and #init_path > 0 then
		return init_path[1]
	end

	-- If all else fails, make an educated guess based on file structure
	local current_dir = vim.fn.fnamemodify(current_file_path, ":h")

	-- Handle relative requires from current directory
	if fs_path:sub(1, 1) == "." then
		-- This is a relative require
		fs_path = fs_path:gsub("^%.", "")
		return current_dir .. "/" .. fs_path .. ".lua"
	end

	return nil
end

---Find a symbol (function, variable) in a Lua file
---@param file_path string Path to the Lua file
---@param symbol_name string Name of the symbol to find
---@return table|nil {line: number, column: number} or nil if not found
function M.find_symbol_in_lua_file(file_path, symbol_name)
	if not file_path or not symbol_name then
		return nil
	end

	-- Read the file contents
	local lines = utils.read_file_contents(file_path)
	if not lines or #lines == 0 then
		return nil
	end

	-- In Lua, we need to check various function and variable definition patterns
	for i, line in ipairs(lines) do
		if type(line) == "string" then
			-- Local function: local function name(...)
			local local_func = line:match("local%s+function%s+" .. vim.pesc(symbol_name) .. "%s*%(")
			if local_func then
				local col = line:find("function%s+" .. vim.pesc(symbol_name)) or 0
				return { line = i - 1, column = col }
			end

			-- Module function: M.name = function(...) or function M.name(...)
			local module_func1 = line:match("[%w_%.]+%." .. vim.pesc(symbol_name) .. "%s*=%s*function")
			if module_func1 then
				local col = line:find("%." .. vim.pesc(symbol_name)) or 0
				return { line = i - 1, column = col + 1 } -- +1 to skip the dot
			end

			local module_func2 = line:match("function%s+[%w_%.]+%." .. vim.pesc(symbol_name) .. "%s*%(")
			if module_func2 then
				local col = line:find("%." .. vim.pesc(symbol_name)) or 0
				return { line = i - 1, column = col + 1 } -- +1 to skip the dot
			end

			-- Direct function: name = function(...) or function name(...)
			local direct_func1 = line:match(vim.pesc(symbol_name) .. "%s*=%s*function")
			if direct_func1 then
				local col = line:find(vim.pesc(symbol_name)) or 0
				return { line = i - 1, column = col - 1 }
			end

			local direct_func2 = line:match("function%s+" .. vim.pesc(symbol_name) .. "%s*%(")
			if direct_func2 then
				local col = line:find(vim.pesc(symbol_name)) or 0
				return { line = i - 1, column = col - 1 }
			end

			-- Variable assignments
			local var_assign = line:match(vim.pesc(symbol_name) .. "%s*=")
			if var_assign and not direct_func1 then
				local col = line:find(vim.pesc(symbol_name)) or 0
				return { line = i - 1, column = col - 1 }
			end

			-- For module return tables: return { name = value }
			local return_table = line:match("return%s*{")
			if return_table then
				-- Search the following lines for the symbol
				for j = i, math.min(i + 20, #lines) do -- Check up to 20 lines after return
					local table_line = lines[j]
					if type(table_line) == "string" then
						local table_entry = table_line:match(vim.pesc(symbol_name) .. "%s*=")
						if table_entry then
							local col = table_line:find(vim.pesc(symbol_name)) or 0
							return { line = j - 1, column = col - 1 }
						end
					end
				end
			end
		end
	end

	return nil
end

---Find the main entry point of a Lua module
---@param file_path string Path to the Lua module file
---@return table|nil {line: number, character: number} or nil if not found
function M.find_lua_module_entry(file_path)
	if not file_path then
		return nil
	end

	-- Read the file contents
	local lines = utils.read_file_contents(file_path)
	if not lines or #lines == 0 then
		return nil
	end

	-- First, check for the return statement at the end
	for i = #lines, math.max(1, #lines - 20), -1 do
		local line = lines[i]
		if type(line) == "string" then
			-- Look for the return statement
			local return_match = line:match("^%s*return%s+")
			if return_match then
				return { line = i - 1, character = 0 }
			end
		end
	end

	-- Next, look for a module table declaration
	for i, line in ipairs(lines) do
		if type(line) == "string" then
			-- Look for common module patterns
			local module_match = line:match("local%s+[%w_]+%s*=%s*{}")
			if module_match then
				return { line = i - 1, character = 0 }
			end
		end
	end

	-- If we can't find anything specific, return the first line
	return { line = 0, character = 0 }
end

---Find implementation of a Lua function
---@param file_path string Path to the file
---@param symbol_name string Name of the symbol
---@param lines table Array of file content lines
---@return table|nil Implementation info or nil if not found
function M.find_implementation(file_path, symbol_name, lines)
	if not file_path or not symbol_name or not lines then
		return nil
	end

	for i, line in ipairs(lines) do
		if type(line) == "string" then
			-- Local function declarations
			local local_func = line:match("local%s+function%s+" .. vim.pesc(symbol_name) .. "%s*%(")
			if local_func then
				local col = line:find("function%s+" .. vim.pesc(symbol_name)) or 0
				return {
					line = i,
					column = col,
					type = "local_function",
				}
			end

			-- Module function declarations
			local module_func = line:match("function%s+[%w_%.]+%." .. vim.pesc(symbol_name) .. "%s*%(")
			if module_func then
				local col = line:find("%." .. vim.pesc(symbol_name)) or 0
				return {
					line = i,
					column = col + 1, -- +1 to skip the dot
					type = "module_function",
				}
			end

			-- Function assignments
			local func_assign = line:match("[%w_%.]+%." .. vim.pesc(symbol_name) .. "%s*=%s*function")
			if func_assign then
				local col = line:find("%." .. vim.pesc(symbol_name)) or 0
				return {
					line = i,
					column = col + 1, -- +1 to skip the dot
					type = "function_assignment",
				}
			end

			-- Direct function declarations
			local direct_func = line:match("function%s+" .. vim.pesc(symbol_name) .. "%s*%(")
			if direct_func then
				local col = line:find(vim.pesc(symbol_name)) or 0
				return {
					line = i,
					column = col,
					type = "function",
				}
			end

			-- Variable assignments with function
			local var_func = line:match(vim.pesc(symbol_name) .. "%s*=%s*function")
			if var_func then
				local col = line:find(vim.pesc(symbol_name)) or 0
				return {
					line = i,
					column = col,
					type = "variable_function",
				}
			end
		end
	end

	return nil
end

return M
