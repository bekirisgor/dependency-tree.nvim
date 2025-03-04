-----------------
-- languages/typescript.lua
-----------------
--[[
    TypeScript/JavaScript specific analysis utilities for dependency-tree.nvim

    This module handles:
    - TypeScript/JavaScript import analysis
    - React component detection and analysis
    - JSX/TSX handling
    - Path resolution for module imports
]]

local config = require("dependency-tree.config")
local utils = require("dependency-tree.utils")
local lsp = require("dependency-tree.lsp")
local ts_utils = require("dependency-tree.analyzer.treesitter")
local variable_utils = require("dependency-tree.analyzer.variables")

-- Type annotation aliases for documentation
---@alias ImportInfo {path: string, type: string, symbols: {[string]: {original: string}}}
---@alias NodePosition {line: number, character: number}
---@alias ComponentProp {name: string, type: string, isRequired: boolean}

local M = {}

---Process TypeScript imports to handle @ aliases and relative paths
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
			vim.notify("TypeScript process_imports: Max depth reached: " .. current_depth, vim.log.levels.DEBUG)
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
		max_depth = 3
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

	for _, line in ipairs(lines) do
		if type(line) ~= "string" and line:match("import") then
			goto continue_line
		end

		local import_info = M.process_import_statement(line, file_path)
		if import_info then
			for symbol_name, _ in pairs(import_info.symbols) do
				imports[symbol_name] = {
					path = import_info.path,
					type = import_info.type,
				}
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
	for symbol, import_info in pairs(imports) do
		-- Check if the symbol is used in the function with proper word boundaries
		local is_used = function_text:match("%f[%w_]" .. vim.pesc(symbol) .. "%f[^%w_]") ~= nil

		if is_used then
			-- Resolve the import path with robust error handling
			local resolved_path_success, resolved_path = pcall(M.resolve_import, import_info.path, file_path)
			if not resolved_path_success or not resolved_path then
				goto continue_import
			end

			-- Try to find the file with various extensions
			local extensions = { ".ts", ".tsx", ".js", ".jsx", "" }
			local found_file = nil

			for _, ext in ipairs(extensions) do
				local file_with_ext = resolved_path .. ext
				local readable_success, is_readable = pcall(vim.fn.filereadable, file_with_ext)
				if readable_success and is_readable == 1 then
					found_file = file_with_ext
					break
				end
			end

			if found_file then
				local import_bufnr
				local buf_success, buf_result = pcall(vim.uri_to_bufnr, "file://" .. found_file)
				if not buf_success or type(buf_result) ~= "number" then
					goto continue_import
				end

				import_bufnr = buf_result

				-- Load the buffer if necessary with error handling
				if not vim.api.nvim_buf_is_loaded(import_bufnr) then
					pcall(vim.fn.bufload, import_bufnr)
				end

				-- Find symbol in the file
				local symbol_pos = M.find_symbol_in_file(import_bufnr, symbol)
				if symbol_pos then
					-- Add the import to the dependency tree with proper error handling and depth tracking
					local analyzer_success, _ = pcall(function()
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

					if analyzer_success then
						found_count = found_count + 1
					elseif config.debug_mode then
						vim.notify("Failed to process import for " .. symbol, vim.log.levels.DEBUG)
					end
				end
			end
		end

		::continue_import::
	end

	return found_count > 0
end

---Process a TypeScript/JavaScript import statement
---@param import_line string The import statement line
---@param file_path string Current file path
---@return ImportInfo|nil Table with imported symbols and path, or nil if invalid
function M.process_import_statement(import_line, file_path)
	if type(import_line) ~= "string" or import_line == "" then
		return nil
	end

	if type(file_path) ~= "string" or file_path == "" then
		return nil
	end

	-- Match "import { x, y as z } from 'path'" pattern
	local symbols, path = import_line:match("import%s+{%s*(.-)%s*}%s+from%s+['\"]([^'\"]+)['\"]")
	if symbols and path then
		local result = { type = "named", path = path, symbols = {} }

		-- Process each symbol, handling aliases
		for symbol_str in symbols:gmatch("([^,]+)") do
			-- Trim whitespace
			symbol_str = symbol_str:gsub("^%s*(.-)%s*$", "%1")

			-- Handle aliases (x as y)
			local original, alias = symbol_str:match("(%S+)%s+as%s+(%S+)")
			if original and alias then
				result.symbols[alias] = { original = original }
			else
				result.symbols[symbol_str] = { original = symbol_str }
			end
		end

		return result
	end

	-- Match "import Name from 'path'" pattern
	local default_import, default_path = import_line:match("import%s+([%w_]+)%s+from%s+['\"]([^'\"]+)['\"]")
	if default_import and default_path then
		return {
			type = "default",
			path = default_path,
			symbols = {
				[default_import] = { original = "default" },
			},
		}
	end

	-- Match "import * as Name from 'path'" pattern
	local namespace, namespace_path = import_line:match("import%s+%*%s+as%s+([%w_]+)%s+from%s+['\"]([^'\"]+)['\"]")
	if namespace and namespace_path then
		return {
			type = "namespace",
			path = namespace_path,
			symbols = {
				[namespace] = { original = "*" },
			},
		}
	end

	-- Match "import 'path'" pattern (side-effect import)
	local side_effect_path = import_line:match("import%s+['\"]([^'\"]+)['\"]")
	if side_effect_path then
		return {
			type = "side-effect",
			path = side_effect_path,
			symbols = {},
		}
	end

	return nil
end

---Resolve TypeScript import paths (handles @ aliases and relative paths)
---@param import_path string Import path from code
---@param current_file_path string Path of the current file
---@return string|nil Resolved filesystem path or nil if resolution failed
function M.resolve_import(import_path, current_file_path)
	-- Type validation
	if type(import_path) ~= "string" or import_path == "" then
		error("resolve_import: Invalid import path")
	end

	if type(current_file_path) ~= "string" or current_file_path == "" then
		error("resolve_import: Invalid current file path")
	end

	-- Handle relative imports
	local is_relative = import_path:match("^%.") ~= nil
	if is_relative then
		local dir_match_success, dir = pcall(function()
			return current_file_path:match("(.*)/[^/]*$") or "."
		end)

		if not dir_match_success or not dir then
			error("resolve_import: Failed to extract directory from path")
		end

		local normalize_success, normalized_path = pcall(vim.fn.fnamemodify, dir .. "/" .. import_path, ":p")
		if not normalize_success or not normalized_path then
			error("resolve_import: Failed to normalize path")
		end

		-- Remove trailing slash if present
		return normalized_path:gsub("/$", "")
	end

	-- Handle @ imports (TypeScript path aliases)
	if import_path:match("^@/") then
		local project_root = utils.get_project_root()
		local aliased_path = import_path:gsub("^@/", "")

		-- Try multiple common paths with proper validation
		local possible_paths = {
			project_root .. "/src/" .. aliased_path,
			project_root .. "/" .. aliased_path,
		}

		for _, path in ipairs(possible_paths) do
			local dir_success, is_dir = pcall(vim.fn.isdirectory, vim.fn.fnamemodify(path, ":h"))
			if dir_success and is_dir == 1 then
				return path
			end
		end

		-- Fallback to src (with validation)
		return project_root .. "/src/" .. aliased_path
	end

	-- Handle node_modules or other imports
	local project_root = utils.get_project_root()
	return project_root .. "/node_modules/" .. import_path
end

---Find a symbol in a file
---@param bufnr integer Buffer number to search
---@param symbol string Symbol name to find
---@return NodePosition|nil Position {line, character} or nil if not found
function M.find_symbol_in_file(bufnr, symbol)
	-- Type validation
	if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
		if config.debug_mode then
			vim.notify("find_symbol_in_file: Invalid buffer", vim.log.levels.DEBUG)
		end
		return nil
	end

	if type(symbol) ~= "string" or symbol == "" then
		if config.debug_mode then
			vim.notify("find_symbol_in_file: Invalid symbol", vim.log.levels.DEBUG)
		end
		return nil
	end

	-- Get lines with proper error handling
	local lines_success, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, 0, -1, false)
	if not lines_success or not lines or #lines == 0 then
		if config.debug_mode then
			vim.notify("find_symbol_in_file: Failed to get buffer lines", vim.log.levels.DEBUG)
		end
		return nil
	end

	-- Patterns to find symbol definitions
	local safe_symbol = vim.pesc(symbol)
	local patterns = {
		"export%s+const%s+" .. safe_symbol .. "%s*=",
		"export%s+function%s+" .. safe_symbol .. "%s*%(",
		"export%s+default%s+function%s+" .. safe_symbol .. "%s*%(",
		"export%s+default%s+const%s+" .. safe_symbol .. "%s*=",
		"const%s+" .. safe_symbol .. "%s*=",
		"let%s+" .. safe_symbol .. "%s*=",
		"var%s+" .. safe_symbol .. "%s*=",
		"function%s+" .. safe_symbol .. "%s*%(",
		"class%s+" .. safe_symbol,
		"interface%s+" .. safe_symbol,
		"type%s+" .. safe_symbol,
		"enum%s+" .. safe_symbol,
	}

	for i, line in ipairs(lines) do
		if type(line) ~= "string" then
			goto continue_line
		end

		for _, pattern in ipairs(patterns) do
			if line:match(pattern) then
				local col = line:find(symbol)
				if col then
					return { line = i - 1, character = col - 1 }
				end
			end
		end

		::continue_line::
	end

	-- Try using Treesitter for better accuracy
	if vim.treesitter then
		local success, parser = pcall(vim.treesitter.get_parser, bufnr)
		if success and parser then
			local tree_success, tree = pcall(function()
				return parser:parse()[1]
			end)
			if tree_success and tree then
				local root_success, root = pcall(function()
					return tree:root()
				end)
				if root_success and root then
					local query_str = string.format(
						[[
                        ((function_declaration
                            name: (identifier) @name (#eq? @name "%s")))

                        ((variable_declarator
                            name: (identifier) @name (#eq? @name "%s")))

                        ((lexical_declaration
                            (variable_declarator
                                name: (identifier) @name (#eq? @name "%s"))))

                        ((export_statement
                            (variable_declarator
                                name: (identifier) @name (#eq? @name "%s"))))

                        ((export_statement
                            (function_declaration
                                name: (identifier) @name (#eq? @name "%s"))))

                        ((class_declaration
                            name: (identifier) @name (#eq? @name "%s")))

                        ((interface_declaration
                            name: (identifier) @name (#eq? @name "%s")))

                        ((type_alias_declaration
                            name: (identifier) @name (#eq? @name "%s")))
                        ]],
						symbol,
						symbol,
						symbol,
						symbol,
						symbol,
						symbol,
						symbol,
						symbol
					)

					local lang = vim.treesitter.language.get_lang(bufnr) or "typescript"
					local query_success, query = pcall(vim.treesitter.query.parse, lang, query_str)

					if query_success and query then
						local capture_success, _ = pcall(function()
							for id, node in query:iter_captures(root, bufnr, 0, -1) do
								local range_success, range = pcall(function()
									return { node:range() }
								end)

								if range_success and range and #range >= 2 then
									local start_row, start_col = range[1], range[2]
									return { line = start_row, character = start_col }
								end
							end
						end)
					end
				end
			end
		end
	end

	return nil
end

---Find files importing a specific component
---@param bufnr integer Buffer number
---@param component_name string Component name
---@param tree table Dependency tree
---@param node_id string Node ID
---@param max_depth number|nil Maximum recursion depth
---@param current_depth number|nil Current recursion depth
---@return boolean success Success status
function M.find_component_imports(bufnr, component_name, tree, node_id, max_depth, current_depth)
	-- Set default for current_depth
	current_depth = current_depth or 0
	max_depth = max_depth or 3

	-- Early termination check
	if current_depth >= max_depth - 1 then
		if config.debug_mode then
			vim.notify("find_component_imports: Max depth reached: " .. current_depth, vim.log.levels.DEBUG)
		end
		return false
	end

	-- Type validation
	if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
		if config.debug_mode then
			vim.notify("find_component_imports: Invalid buffer", vim.log.levels.DEBUG)
		end
		return false
	end

	if type(component_name) ~= "string" or component_name == "" then
		if config.debug_mode then
			vim.notify("find_component_imports: Invalid component name", vim.log.levels.DEBUG)
		end
		return false
	end

	if type(tree) ~= "table" or type(tree.nodes) ~= "table" then
		if config.debug_mode then
			vim.notify("find_component_imports: Invalid tree structure", vim.log.levels.DEBUG)
		end
		return false
	end

	if type(node_id) ~= "string" or not tree.nodes[node_id] then
		if config.debug_mode then
			vim.notify("find_component_imports: Invalid node_id or node not found", vim.log.levels.DEBUG)
		end
		return false
	end

	local file_path = vim.api.nvim_buf_get_name(bufnr)
	if not file_path or file_path == "" then
		if config.debug_mode then
			vim.notify("find_component_imports: Empty file path", vim.log.levels.DEBUG)
		end
		return false
	end

	-- Get directory of the current file
	local dir_path_success, dir_path = pcall(function()
		return file_path:match("(.*)/[^/]*$") or "."
	end)

	if not dir_path_success or dir_path == "." then
		if config.debug_mode then
			vim.notify("find_component_imports: Failed to extract directory", vim.log.levels.DEBUG)
		end
		return false
	end

	-- Go one level up to find parent directories
	local parent_dir_success, parent_dir = pcall(function()
		return dir_path:match("(.*)/[^/]*$") or "."
	end)

	if not parent_dir_success or parent_dir == "." then
		if config.debug_mode then
			vim.notify("find_component_imports: Failed to extract parent directory", vim.log.levels.DEBUG)
		end
		return false
	end

	-- Find all potential JavaScript/TypeScript files in parent directory with platform-compatible approach
	local find_cmd
	local is_windows = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1

	if is_windows then
		find_cmd = string.format(
			'powershell -command "Get-ChildItem -Path %s -Recurse -Include *.ts,*.tsx,*.js,*.jsx -File | Select-Object -First 50 | ForEach-Object { $_.FullName }"',
			parent_dir
		)
	else
		find_cmd = string.format(
			"find %s -type f \\( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' \\) -maxdepth 3 | head -50",
			parent_dir
		)
	end

	-- Execute command with error handling
	local cmd_success, output = pcall(vim.fn.system, find_cmd)
	if not cmd_success or vim.v.shell_error ~= 0 then
		if config.debug_mode then
			vim.notify("find_component_imports: Failed to execute file search command", vim.log.levels.DEBUG)
		end
		return false
	end

	-- Process each file with comprehensive error handling
	local found_count = 0

	for potential_file in output:gmatch("[^\r\n]+") do
		-- Skip the current file and excluded files with proper validation
		if potential_file ~= file_path and not utils.should_exclude(potential_file) then
			local content_success, content = pcall(utils.read_file_contents, potential_file)

			if content_success and content and #content > 0 then
				local file_content = table.concat(content, "\n")

				-- Check if file imports our component using precise patterns
				local safe_component = vim.pesc(component_name)
				local import_pattern = "import%s+{[^}]*%s*" .. safe_component .. "%s*[,}].-from%s+['\"]([^'\"]+)['\"]"
				local direct_import_pattern = "import%s+" .. safe_component .. "%s+from%s+['\"]([^'\"]+)['\"]"

				local has_import = file_content:match(import_pattern) ~= nil
					or file_content:match(direct_import_pattern) ~= nil

				if has_import then
					-- Check for usage of the component in JSX with proper validation
					local usage_pattern = "<%s*" .. safe_component .. "[%s/>]"
					if file_content:match(usage_pattern) then
						-- Found a file that imports and uses the component
						local new_bufnr
						local buf_success, buf_result = pcall(vim.uri_to_bufnr, "file://" .. potential_file)

						if not buf_success or type(buf_result) ~= "number" then
							goto continue_file
						end

						new_bufnr = buf_result

						-- Load file if necessary with error handling
						if not vim.api.nvim_buf_is_loaded(new_bufnr) then
							pcall(vim.fn.bufload, new_bufnr)
						end

						-- Find the line number where component is used
						local usage_line = 0
						for i, line in ipairs(content) do
							if type(line) == "string" and line:match(usage_pattern) then
								usage_line = i - 1
								break
							end
						end

						-- Add this usage to the tree with comprehensive validation
						if usage_line > 0 and current_depth < max_depth - 1 then
							local usage_pos = { line = usage_line, character = 0 }
							local usage_id = string.format("%s:%d:%d", potential_file, usage_line, 0)

							-- Create a node for the usage if it doesn't exist
							if not tree.nodes[usage_id] then
								local usage_symbol
								local symbol_success, symbol_result = pcall(lsp.get_symbol_at_pos, new_bufnr, usage_pos)

								if symbol_success and symbol_result and symbol_result ~= "" then
									usage_symbol = symbol_result
								else
									usage_symbol = "ComponentReference"
								end

								tree.nodes[usage_id] = {
									id = usage_id,
									symbol = usage_symbol,
									file = potential_file:match("([^/]+)$") or potential_file,
									line = usage_line + 1,
									column = 1,
									full_path = potential_file,
									children = { node_id }, -- This component is a child of the usage
									parents = {},
									variables_used = {},
									component_usage = true,
									used_component = component_name,
								}

								-- Connect the nodes
								if not vim.tbl_contains(tree.nodes[node_id].parents, usage_id) then
									table.insert(tree.nodes[node_id].parents, usage_id)
									found_count = found_count + 1
								end
							end
						end
					end
				end
			end
		end

		::continue_file::
	end

	return found_count > 0
end

---Find components used by a React component
---@param bufnr integer Buffer number
---@param pos {line: integer, character: integer} Position with line and character
---@param tree table Dependency tree
---@param node_id string Node ID
---@param max_depth integer Maximum depth
---@param component_name string Component name
---@param current_depth integer|nil Current recursion depth
---@return boolean Success status
function M.find_used_components(bufnr, pos, tree, node_id, max_depth, component_name, current_depth)
	-- Set default for current_depth
	current_depth = current_depth or 0

	-- Early termination check
	if current_depth >= max_depth - 1 then
		if config.debug_mode then
			vim.notify("find_used_components: Max depth reached: " .. current_depth, vim.log.levels.DEBUG)
		end
		return false
	end

	-- Skip if we're already at max depth
	if tree.nodes[node_id] and #tree.nodes[node_id].children >= max_depth - current_depth then
		return false
	end

	-- Type validation
	if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
		if config.debug_mode then
			vim.notify("find_used_components: Invalid buffer", vim.log.levels.DEBUG)
		end
		return false
	end

	if type(pos) ~= "table" or type(pos.line) ~= "number" or type(pos.character) ~= "number" then
		if config.debug_mode then
			vim.notify("find_used_components: Invalid position", vim.log.levels.DEBUG)
		end
		return false
	end

	if type(tree) ~= "table" or type(tree.nodes) ~= "table" then
		if config.debug_mode then
			vim.notify("find_used_components: Invalid tree structure", vim.log.levels.DEBUG)
		end
		return false
	end

	if type(node_id) ~= "string" or not tree.nodes[node_id] then
		if config.debug_mode then
			vim.notify("find_used_components: Invalid node_id or node not found", vim.log.levels.DEBUG)
		end
		return false
	end

	if type(max_depth) ~= "number" or max_depth < 1 then
		if config.debug_mode then
			vim.notify("find_used_components: Invalid max_depth", vim.log.levels.DEBUG)
		end
		max_depth = 3
	end

	if type(component_name) ~= "string" or component_name == "" then
		if config.debug_mode then
			vim.notify("find_used_components: Invalid component name", vim.log.levels.DEBUG)
		end
		return false
	end

	local file_path = vim.api.nvim_buf_get_name(bufnr)
	local content_success, lines = pcall(utils.read_file_contents, file_path)

	if not content_success or not lines or #lines == 0 then
		if config.debug_mode then
			vim.notify("find_used_components: Failed to read file content", vim.log.levels.DEBUG)
		end
		return false
	end

	-- Get source code
	local source_code = table.concat(lines, "\n")

	-- Find all imports that might be components with precise pattern matching
	---@type table<string, boolean>
	local imports = {}

	for _, line in ipairs(lines) do
		if type(line) ~= "string" then
			goto continue_line
		end

		-- Match named imports: import { Component1, Component2 } from '...'
		local import_list = line:match("import%s+{([^}]+)}")
		if import_list then
			for comp_name in import_list:gmatch("([%w_]+)") do
				-- Components usually start with uppercase
				if comp_name and comp_name:match("^[A-Z]") then
					imports[comp_name] = true
				end
			end
		end

		-- Match direct imports: import Component from '...'
		local direct_import = line:match("import%s+([%w_]+)%s+from")
		if direct_import and direct_import:match("^[A-Z]") then
			imports[direct_import] = true
		end

		::continue_line::
	end

	-- Now search for JSX usage of these components
	local found_count = 0

	for imported_comp, _ in pairs(imports) do
		local safe_comp = vim.pesc(imported_comp)
		local usage_pattern = "<%s*" .. safe_comp .. "[%s/>]"

		-- Find usages
		for i, line in ipairs(lines) do
			if type(line) ~= "string" or not line:match(usage_pattern) then
				goto continue_usage_line
			end

			-- Try to find the definition of this component using LSP
			local def_params = {
				textDocument = { uri = vim.uri_from_bufnr(bufnr) },
				position = {
					line = i - 1,
					character = line:find(imported_comp) or 0,
				},
				context = { includeDeclaration = true },
			}

			local def_success, definitions = pcall(function()
				return lsp.get_definitions(def_params)
			end)

			local found_definitions = false

			if def_success and definitions and #definitions > 0 then
				-- Process found definitions
				for _, def in ipairs(definitions) do
					if type(def) == "table" and def.range and type(def.range) == "table" then
						local def_uri = def.uri or def.targetUri

						if def_uri and type(def_uri) == "string" then
							local def_bufnr
							local buf_success, buf_result = pcall(vim.uri_to_bufnr, def_uri)

							if buf_success and type(buf_result) == "number" then
								def_bufnr = buf_result
								local def_pos = lsp.lsp_to_buf_pos(def.range.start)

								if def_pos and type(def_pos) == "table" then
									-- Recursive call to analyze the component
									local analyze_success, _ = pcall(function()
										local analyzer = require("dependency-tree.analyzer")
										analyzer.build_dependency_tree(
											def_bufnr,
											def_pos,
											current_depth + 1,
											max_depth,
											"down",
											tree,
											node_id
										)
									end)

									if analyze_success then
										found_definitions = true
										found_count = found_count + 1
									end
								end
							end
						end
					end
				end
			end

			-- If no definitions found through LSP, we might need to search files
			if not found_definitions then
				local find_success, found = pcall(function()
					return M.find_component_definition(imported_comp, tree, node_id, max_depth, current_depth + 1)
				end)

				if find_success and found then
					found_count = found_count + 1
				end
			end

			-- Mark this component as used
			if tree.nodes[node_id] then
				local is_duplicate = false

				for _, used_var in ipairs(tree.nodes[node_id].variables_used) do
					if type(used_var) == "table" and used_var.name == imported_comp and used_var.is_component then
						is_duplicate = true
						break
					end
				end

				if not is_duplicate then
					table.insert(tree.nodes[node_id].variables_used, {
						name = imported_comp,
						line = i,
						column = line:find(imported_comp) or 0,
						is_component = true,
					})
				end
			end

			::continue_usage_line::
		end
	end

	return found_count > 0
end

---Find a component definition file
---@param component_name string Component name
---@param tree table Dependency tree
---@param node_id string Node ID
---@param max_depth number|nil Maximum recursion depth
---@param current_depth number|nil Current recursion depth
---@return boolean Success status
function M.find_component_definition(component_name, tree, node_id, max_depth, current_depth)
	-- Set defaults with validation
	max_depth = max_depth or 3
	current_depth = current_depth or 0

	-- Early termination check
	if current_depth >= max_depth - 1 then
		if config.debug_mode then
			vim.notify("find_component_definition: Max depth reached: " .. current_depth, vim.log.levels.DEBUG)
		end
		return false
	end

	-- Type validation
	if type(component_name) ~= "string" or component_name == "" then
		if config.debug_mode then
			vim.notify("find_component_definition: Invalid component name", vim.log.levels.DEBUG)
		end
		return false
	end

	if type(tree) ~= "table" or type(tree.nodes) ~= "table" then
		if config.debug_mode then
			vim.notify("find_component_definition: Invalid tree structure", vim.log.levels.DEBUG)
		end
		return false
	end

	if type(node_id) ~= "string" or not tree.nodes[node_id] then
		if config.debug_mode then
			vim.notify("find_component_definition: Invalid node_id or node not found", vim.log.levels.DEBUG)
		end
		return false
	end

	local file_path = tree.nodes[node_id].full_path
	if not file_path or type(file_path) ~= "string" or file_path == "" then
		if config.debug_mode then
			vim.notify("find_component_definition: Node has no valid file path", vim.log.levels.DEBUG)
		end
		return false
	end

	local dir_success, dir_path = pcall(function()
		return file_path:match("(.*)/[^/]*$") or "."
	end)

	if not dir_success or dir_path == "." then
		if config.debug_mode then
			vim.notify("find_component_definition: Failed to extract directory", vim.log.levels.DEBUG)
		end
		return false
	end

	-- Common component file patterns with comprehensive path coverage
	---@type string[]
	local potential_paths = {
		dir_path .. "/" .. component_name .. ".tsx",
		dir_path .. "/" .. component_name .. ".jsx",
		dir_path .. "/" .. component_name .. ".js",
		dir_path .. "/" .. component_name .. ".ts",
		dir_path .. "/components/" .. component_name .. ".tsx",
		dir_path .. "/components/" .. component_name .. ".jsx",
		dir_path .. "/components/" .. component_name .. ".js",
		dir_path .. "/components/" .. component_name .. ".ts",
		dir_path .. "/../components/" .. component_name .. ".tsx",
		dir_path .. "/../components/" .. component_name .. ".jsx",
		dir_path .. "/../components/" .. component_name .. ".js",
		dir_path .. "/../components/" .. component_name .. ".ts",
		-- Add src directory patterns
		dir_path
			.. "/../src/components/"
			.. component_name
			.. ".tsx",
		dir_path .. "/../src/components/" .. component_name .. ".jsx",
		-- Add common UI component directory patterns
		dir_path
			.. "/ui/"
			.. component_name
			.. ".tsx",
		dir_path .. "/ui/" .. component_name .. ".jsx",
		dir_path .. "/../ui/" .. component_name .. ".tsx",
		dir_path .. "/../ui/" .. component_name .. ".jsx",
		dir_path .. "/../src/ui/" .. component_name .. ".tsx",
		dir_path .. "/../src/ui/" .. component_name .. ".jsx",
	}

	-- Check each potential path with robust error handling
	for _, path in ipairs(potential_paths) do
		local exists_success, exists = pcall(function()
			return vim.fn.filereadable(path) == 1
		end)

		if not exists_success then
			goto continue_path
		end

		if exists and not utils.should_exclude(path) then
			-- Found the file, now find the component definition inside
			local lines_success, lines = pcall(utils.read_file_contents, path)

			if not lines_success or not lines or #lines == 0 then
				goto continue_path
			end

			local safe_component = vim.pesc(component_name)
			local found_line_index = nil
			local found_line_content = nil

			-- Look for component definition patterns
			for i, line in ipairs(lines) do
				if type(line) ~= "string" then
					goto continue_line
				end

				-- Comprehensive pattern matching for different component definition styles
				if
					line:match("function%s+" .. safe_component .. "%s*%(")
					or line:match("const%s+" .. safe_component .. "%s*=%s*%(%s*%)%s*=>")
					or line:match("const%s+" .. safe_component .. "%s*:%s*React%.FC")
					or line:match("class%s+" .. safe_component .. "%s+extends")
					or line:match("export%s+function%s+" .. safe_component)
					or line:match("export%s+const%s+" .. safe_component)
					or line:match("export%s+default%s+function%s+" .. safe_component)
					or line:match("export%s+default%s+class%s+" .. safe_component)
				then
					found_line_index = i
					found_line_content = line
					break
				end

				::continue_line::
			end

			if found_line_index then
				-- Create a buffer for this file with comprehensive error handling
				local new_bufnr
				local buf_success, buf_result = pcall(vim.uri_to_bufnr, "file://" .. path)

				if not buf_success or type(buf_result) ~= "number" then
					if config.debug_mode then
						vim.notify(
							"find_component_definition: Failed to create buffer for: " .. path,
							vim.log.levels.DEBUG
						)
					end
					goto continue_path
				end

				new_bufnr = buf_result

				-- Load file if necessary with error handling
				if not vim.api.nvim_buf_is_loaded(new_bufnr) then
					local load_success = pcall(vim.fn.bufload, new_bufnr)
					if not load_success then
						if config.debug_mode then
							vim.notify(
								"find_component_definition: Failed to load buffer: " .. path,
								vim.log.levels.DEBUG
							)
						end
						goto continue_path
					end
				end

				-- Create a node for this component
				local col = found_line_content:find(component_name) or 0
				local comp_pos = { line = found_line_index - 1, character = col - 1 }
				local comp_id = string.format("%s:%d:%d", path, comp_pos.line, comp_pos.character)

				if not tree.nodes[comp_id] then
					-- Create the component node with comprehensive data
					tree.nodes[comp_id] = {
						id = comp_id,
						symbol = component_name,
						file = path:match("([^/]+)$") or path,
						line = found_line_index,
						column = col,
						full_path = path,
						children = {},
						parents = { node_id },
						variables_used = {},
						is_react_component = true,
						source_code = ts_utils.extract_function_source(new_bufnr, comp_pos),
						docblock = ts_utils.extract_function_docblock(new_bufnr, comp_pos),
						component_props = M.extract_component_props(new_bufnr, comp_pos, component_name),
					}

					-- Connect the nodes with duplicate checking
					if not vim.tbl_contains(tree.nodes[node_id].children, comp_id) then
						table.insert(tree.nodes[node_id].children, comp_id)
					end

					-- Process this component for deeper analysis
					local analyze_success, _ = pcall(function()
						local analyzer = require("dependency-tree.analyzer")
						analyzer.analyze_variable_dependencies(
							new_bufnr,
							comp_pos,
							comp_id,
							tree,
							max_depth,
							current_depth + 1
						)
					end)

					if not analyze_success and config.debug_mode then
						vim.notify(
							"find_component_definition: Failed to analyze variables for: " .. component_name,
							vim.log.levels.DEBUG
						)
					end

					return true
				else
					-- Component already exists in tree, just connect it
					if not vim.tbl_contains(tree.nodes[node_id].children, comp_id) then
						table.insert(tree.nodes[node_id].children, comp_id)
					end

					if not vim.tbl_contains(tree.nodes[comp_id].parents, node_id) then
						table.insert(tree.nodes[comp_id].parents, node_id)
					end

					return true
				end
			end
		end

		::continue_path::
	end

	return false
end

---Extract props from a React component with robust pattern matching
---@param bufnr integer Buffer number
---@param pos {line: integer, character: integer} Position with line and character fields
---@param symbol_name string Component name
---@return ComponentProp[] Array of extracted props
function M.extract_component_props(bufnr, pos, symbol_name)
	-- Type validation with detailed error handling
	if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
		if config.debug_mode then
			vim.notify("extract_component_props: Invalid buffer", vim.log.levels.DEBUG)
		end
		return {}
	end

	if type(pos) ~= "table" or type(pos.line) ~= "number" or type(pos.character) ~= "number" then
		if config.debug_mode then
			vim.notify("extract_component_props: Invalid position", vim.log.levels.DEBUG)
		end
		return {}
	end

	if type(symbol_name) ~= "string" or symbol_name == "" then
		if config.debug_mode then
			vim.notify("extract_component_props: Invalid symbol name", vim.log.levels.DEBUG)
		end
		return {}
	end

	---@type ComponentProp[]
	local props = {}
	local file_path = vim.api.nvim_buf_get_name(bufnr)

	local lines_success, lines = pcall(utils.read_file_contents, file_path)
	if not lines_success or not lines or #lines == 0 then
		if config.debug_mode then
			vim.notify("extract_component_props: Failed to read file content", vim.log.levels.DEBUG)
		end
		return props
	end

	-- Find component bounds
	local start_line = pos.line
	local end_line = #lines
	local safe_symbol = vim.pesc(symbol_name)

	-- Look for props pattern in function arguments or class props
	for i = start_line, math.min(start_line + 20, #lines) do
		local line = lines[i]
		if not line or type(line) ~= "string" then
			goto continue_line
		end

		-- Check function parameters for destructured props
		local props_pattern = "function%s+" .. safe_symbol .. "%s*%(%s*{(.-)}"
		local arrow_pattern = "const%s+" .. safe_symbol .. "%s*=%s*%({(.-)}%)"
		local fc_pattern = "const%s+" .. safe_symbol .. "%s*:%s*React%.FC<%s*(.-)%s*>"
		local interface_pattern = "interface%s+" .. safe_symbol .. "Props%s*{(.-)}%s*"

		local props_str = line:match(props_pattern) or line:match(arrow_pattern) or line:match(fc_pattern)

		if props_str then
			-- Parse destructured props with improved pattern matching
			for prop in props_str:gmatch("([%w_]+)[%s,:]") do
				if not utils.is_keyword(prop) and prop ~= "props" then
					if not vim.tbl_contains(props, function(p)
						return p.name == prop
					end) then
						table.insert(props, {
							name = prop,
							type = "unknown",
							isRequired = false,
						})
					end
				end
			end
			break
		end

		-- Check for props type definitions
		local type_str = line:match("type%s+" .. safe_symbol .. "Props%s*=%s*{(.-)}")
		if type_str then
			local type_end_line = i
			-- Find the end of the type definition
			for j = i, math.min(i + 20, #lines) do
				if lines[j] and type(lines[j]) == "string" and lines[j]:match("};") then
					type_end_line = j
					break
				end
			end

			-- Extract prop names from type definition with improved parsing
			for j = i, type_end_line do
				if lines[j] and type(lines[j]) == "string" then
					-- More precise prop pattern matching that handles optional props and types
					local prop, optional, prop_type = lines[j]:match("([%w_]+)(%??)%s*:%s*([^;]+)")
					if prop and not utils.is_keyword(prop) then
						if not vim.tbl_contains(props, function(p)
							return p.name == prop
						end) then
							table.insert(props, {
								name = prop,
								type = prop_type or "unknown",
								isRequired = optional ~= "?",
							})
						end
					end
				end
			end
			break
		end

		-- Look for interface props
		if line:match("interface%s+" .. safe_symbol .. "Props") then
			local interface_end_line = i
			local in_interface = true

			-- Find the end of the interface
			for j = i + 1, math.min(i + 30, #lines) do
				if lines[j] and type(lines[j]) == "string" then
					if lines[j]:match("}") then
						interface_end_line = j
						break
					end

					-- Extract props from interface lines with type information
					local prop, optional, prop_type = lines[j]:match("%s+([%w_]+)(%??)%s*:%s*([^;]+)")
					if prop and not utils.is_keyword(prop) then
						if not vim.tbl_contains(props, function(p)
							return p.name == prop
						end) then
							table.insert(props, {
								name = prop,
								type = prop_type or "unknown",
								isRequired = optional ~= "?",
							})
						end
					end
				end
			end
		end

		::continue_line::
	end

	-- If we have React.FC<Props>, try to find Props interface/type
	if #props == 0 then
		local fc_props_type = nil

		-- Find the React.FC<PropsType> declaration
		for i = start_line, math.min(start_line + 10, #lines) do
			if lines[i] and type(lines[i]) == "string" then
				local props_type = lines[i]:match("React%.FC<%s*([%w_]+)%s*>")
				if props_type then
					fc_props_type = props_type
					break
				end
			end
		end

		-- If we found a props type, search for its definition
		if fc_props_type then
			local type_pattern = "type%s+" .. fc_props_type .. "%s*=%s*{"
			local interface_pattern = "interface%s+" .. fc_props_type .. "%s*{"

			for i = 1, #lines do
				if
					lines[i]
					and type(lines[i]) == "string"
					and (lines[i]:match(type_pattern) or lines[i]:match(interface_pattern))
				then
					-- Find the end of the type/interface
					local end_line = i
					for j = i + 1, math.min(i + 30, #lines) do
						if lines[j] and type(lines[j]) == "string" and lines[j]:match("}") then
							end_line = j
							break
						end
					end

					-- Extract props with comprehensive type information
					for j = i + 1, end_line - 1 do
						if lines[j] and type(lines[j]) == "string" then
							local prop, optional, prop_type = lines[j]:match("%s+([%w_]+)(%??)%s*:%s*([^;]+)")
							if prop and not utils.is_keyword(prop) then
								if
									not vim.tbl_contains(props, function(p)
										return p.name == prop
									end)
								then
									table.insert(props, {
										name = prop,
										type = prop_type or "unknown",
										isRequired = optional ~= "?",
									})
								end
							end
						end
					end

					break
				end
			end
		end
	end

	return props
end

---Find implementation of a TypeScript/JavaScript function or component
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

	-- Comprehensive patterns to match different implementation styles
	local patterns = {
		{ pattern = "function%s+" .. safe_symbol .. "%s*%(", type = "function" },
		{ pattern = "const%s+" .. safe_symbol .. "%s*=%s*function", type = "function_expression" },
		{ pattern = "const%s+" .. safe_symbol .. "%s*=%s*async%s*function", type = "async_function_expression" },
		{ pattern = "const%s+" .. safe_symbol .. "%s*=%s*%(%s*%)%s*=>", type = "arrow_function" },
		{ pattern = "export%s+const%s+" .. safe_symbol .. "%s*=", type = "exported_constant" },
		{ pattern = "export%s+function%s+" .. safe_symbol, type = "exported_function" },
		{ pattern = "export%s+default%s+function%s+" .. safe_symbol, type = "default_exported_function" },
		{ pattern = "class%s+" .. safe_symbol, type = "class" },
		{ pattern = "export%s+class%s+" .. safe_symbol, type = "exported_class" },
		{ pattern = "export%s+default%s+class%s+" .. safe_symbol, type = "default_exported_class" },
		{ pattern = "interface%s+" .. safe_symbol, type = "interface" },
		{ pattern = "export%s+interface%s+" .. safe_symbol, type = "exported_interface" },
		{ pattern = "type%s+" .. safe_symbol, type = "type" },
		{ pattern = "export%s+type%s+" .. safe_symbol, type = "exported_type" },
	}

	for i, line in ipairs(lines) do
		if type(line) ~= "string" then
			goto continue_line
		end

		for _, pattern_info in ipairs(patterns) do
			if line:match(pattern_info.pattern) then
				local col = line:find(symbol_name) or 0
				return {
					line = i,
					column = col,
					type = pattern_info.type,
					content = line,
				}
			end
		end

		::continue_line::
	end

	return nil
end

---Check if a symbol is an imported/required type
---@param bufnr integer Buffer number
---@param symbol string Symbol name
---@return boolean Whether the symbol is imported
function M.is_imported_type(bufnr, symbol)
	-- Type validation
	if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
		if config.debug_mode then
			vim.notify("is_imported_type: Invalid buffer", vim.log.levels.DEBUG)
		end
		return false
	end

	if type(symbol) ~= "string" or symbol == "" then
		if config.debug_mode then
			vim.notify("is_imported_type: Invalid symbol", vim.log.levels.DEBUG)
		end
		return false
	end

	local file_path = vim.api.nvim_buf_get_name(bufnr)
	local lines_success, lines = pcall(utils.read_file_contents, file_path)

	if not lines_success or not lines or #lines == 0 then
		if config.debug_mode then
			vim.notify("is_imported_type: Failed to read file content", vim.log.levels.DEBUG)
		end
		return false
	end

	local content = table.concat(lines, "\n")
	local safe_symbol = vim.pesc(symbol)

	-- Check import patterns with precise matching
	if
		content:match("import%s+{[^}]*" .. safe_symbol .. "[^}]*}")
		or content:match("import%s+" .. safe_symbol .. "%s+from")
		or content:match("import%s+%*%s+as%s+" .. safe_symbol)
		or content:match("const%s+" .. safe_symbol .. "%s*=%s*require")
	then
		return true
	end

	return false
end

return M
