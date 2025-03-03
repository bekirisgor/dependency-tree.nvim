-----------------
-- analyzer.lua
-----------------
--[[
    Core analysis module for dependency-tree.nvim

    This module is responsible for:
    - Building the dependency tree recursively
    - Detecting function calls and references
    - Analyzing TypeScript/JavaScript code patterns
    - Supporting async/await patterns
    - Resolving relative and aliased imports (@/ notation)
    - Extracting React component information
]]

local config = require("dependency-tree.config")
local lsp = require("dependency-tree.lsp")
local utils = require("dependency-tree.utils")

local M = {}

-- Diagnostic function to troubleshoot Treesitter issues
-- @param bufnr number: Buffer number to diagnose
-- @param pos table: Position {line, character} to examine
-- @return boolean: Whether Treesitter is working correctly
function M.diagnose_treesitter(bufnr, pos)
	vim.notify("Diagnosing Treesitter...", vim.log.levels.INFO)

	-- Check if Treesitter is available
	if not vim.treesitter then
		vim.notify("ERROR: Treesitter module not available", vim.log.levels.ERROR)
		return false
	end

	-- Buffer validation
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		vim.notify("ERROR: Invalid buffer", vim.log.levels.ERROR)
		return false
	end

	-- Get filetype safely (works with different Neovim versions)
	local filetype
	if vim.api.nvim_buf_get_option_value then -- Neovim 0.7+
		filetype = vim.api.nvim_buf_get_option_value(bufnr, "filetype", {})
	else
		filetype = vim.api.nvim_buf_get_option(bufnr, "filetype")
	end

	if not filetype or filetype == "" then
		vim.notify("ERROR: Could not determine filetype", vim.log.levels.ERROR)
		return false
	end

	vim.notify("Filetype: " .. filetype, vim.log.levels.INFO)

	-- Check if parser exists for this filetype
	local parser_ok = pcall(vim.treesitter.language.require_language, filetype, nil, true)
	if not parser_ok then
		vim.notify("ERROR: Parser not available for " .. filetype, vim.log.levels.ERROR)
		vim.notify("Run :TSInstall " .. filetype, vim.log.levels.INFO)
		return false
	end

	-- Try to get parser
	local parser_success, parser = pcall(vim.treesitter.get_parser, bufnr, filetype)
	if not parser_success or not parser then
		vim.notify("ERROR: Failed to get parser", vim.log.levels.ERROR)
		return false
	end

	-- Try to parse
	local tree_success, syntax_tree = pcall(function()
		return parser:parse()[1]
	end)

	if not tree_success or not syntax_tree then
		vim.notify("ERROR: Failed to parse buffer", vim.log.levels.ERROR)
		return false
	end

	local root = syntax_tree:root()
	if not root then
		vim.notify("ERROR: Failed to get root node", vim.log.levels.ERROR)
		return false
	end

	-- Try to get node at position
	local node_success = pcall(function()
		root:named_descendant_for_range(pos.line, pos.character, pos.line, pos.character)
	end)

	if not node_success then
		vim.notify("ERROR: Failed to get node at position", vim.log.levels.ERROR)
		return false
	end

	vim.notify("Success: Treesitter is working correctly!", vim.log.levels.INFO)
	return true
end

-- Setup Treesitter parsers required for the plugin
-- @return boolean: Whether setup was successful
function M.setup_treesitter()
	vim.notify("Setting up Treesitter parsers for dependency-tree.nvim...", vim.log.levels.INFO)

	if not vim.treesitter then
		vim.notify("ERROR: Treesitter not available", vim.log.levels.ERROR)
		return false
	end

	local required_parsers = {
		"typescript",
		"javascript",
		"tsx",
		"jsx",
		"python",
		"lua",
		"go",
		"rust",
	}

	local all_installed = true
	for _, parser in ipairs(required_parsers) do
		local is_installed = pcall(vim.treesitter.language.require_language, parser, nil, true)
		if not is_installed then
			vim.notify("Installing parser for " .. parser, vim.log.levels.INFO)
			local install_success = pcall(vim.cmd, "TSInstall " .. parser)
			if not install_success then
				vim.notify("Failed to install parser for " .. parser, vim.log.levels.ERROR)
				all_installed = false
			end
		else
			vim.notify("Parser for " .. parser .. " is already installed", vim.log.levels.INFO)
		end
	end

	if all_installed then
		vim.notify("Treesitter setup complete!", vim.log.levels.INFO)
	else
		vim.notify("Treesitter setup incomplete. Some parsers failed to install.", vim.log.levels.WARN)
	end

	return all_installed
end

-- Get filetype safely (works across Neovim versions)
-- @param bufnr number: Buffer number
-- @return string: Filetype or empty string if not determinable
local function get_filetype_safe(bufnr)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return ""
	end

	local filetype
	if vim.api.nvim_buf_get_option_value then -- Neovim 0.7+
		local success, result = pcall(vim.api.nvim_buf_get_option_value, bufnr, "filetype", {})
		if success then
			filetype = result
		else
			vim.notify("Error getting filetype: " .. tostring(result), vim.log.levels.DEBUG)
			filetype = ""
		end
	else
		local success, result = pcall(vim.api.nvim_buf_get_option, bufnr, "filetype")
		if success then
			filetype = result
		else
			vim.notify("Error getting filetype: " .. tostring(result), vim.log.levels.DEBUG)
			filetype = ""
		end
	end

	return filetype or ""
end

-- Fixed get_function_bounds function with enhanced error handling
-- @param bufnr number: Buffer number to analyze
-- @param pos table: Position {line, character} to start analysis
-- @return table: Function bounds {start_line, end_line} or fallback bounds
function M.get_function_bounds(bufnr, pos)
	-- Type validation with clear fallback
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		vim.notify("Invalid buffer in get_function_bounds", vim.log.levels.DEBUG)
		return {
			start_line = math.max(0, pos.line - 10),
			end_line = pos.line + 50,
		}
	end

	if not vim.treesitter then
		vim.notify("Treesitter not available", vim.log.levels.DEBUG)
		return {
			start_line = math.max(0, pos.line - 10),
			end_line = pos.line + 50,
		}
	end

	-- Get filetype safely
	local filetype = get_filetype_safe(bufnr)
	if filetype == "" then
		vim.notify("Could not determine filetype", vim.log.levels.DEBUG)
		return {
			start_line = math.max(0, pos.line - 10),
			end_line = pos.line + 50,
		}
	end

	-- Check if parser exists for this filetype
	local parser_ok = pcall(vim.treesitter.language.require_language, filetype, nil, true)
	if not parser_ok then
		vim.notify("Parser not available for " .. filetype, vim.log.levels.DEBUG)
		return {
			start_line = math.max(0, pos.line - 10),
			end_line = pos.line + 50,
		}
	end

	-- Get parser safely
	local parser_success, parser = pcall(vim.treesitter.get_parser, bufnr, filetype)
	if not parser_success or not parser then
		vim.notify("Failed to get parser: " .. tostring(parser), vim.log.levels.DEBUG)
		return {
			start_line = math.max(0, pos.line - 10),
			end_line = pos.line + 50,
		}
	end

	-- Parse buffer safely
	local tree_success, syntax_tree = pcall(function()
		return parser:parse()[1]
	end)

	if not tree_success or not syntax_tree then
		vim.notify("Failed to parse buffer", vim.log.levels.DEBUG)
		return {
			start_line = math.max(0, pos.line - 10),
			end_line = pos.line + 50,
		}
	end

	-- Get root node
	local root_success, root = pcall(function()
		return syntax_tree:root()
	end)

	if not root_success or not root then
		vim.notify("Failed to get root node", vim.log.levels.DEBUG)
		return {
			start_line = math.max(0, pos.line - 10),
			end_line = pos.line + 50,
		}
	end

	-- Get node at cursor position
	local node_success, cursor_node = pcall(function()
		return root:named_descendant_for_range(pos.line, pos.character, pos.line, pos.character)
	end)

	if not node_success or not cursor_node then
		vim.notify("Failed to get node at cursor position", vim.log.levels.DEBUG)
		return {
			start_line = math.max(0, pos.line - 10),
			end_line = pos.line + 50,
		}
	end

	-- Define function-like node types based on language
	local function_types = {
		-- Common types
		"function_declaration",
		"method_definition",
		"arrow_function",
		"function",
		-- TypeScript/JavaScript specific
		"export_statement",
		"variable_declaration",
		"lexical_declaration",
		"function_expression",
		"method_definition",
		"class_method",
		"generator_function",
		-- Other languages
		"function_item",
		"method",
		"class_declaration",
	}

	-- Check if a node is a function node
	local function is_function_node(node)
		if not node then
			return false
		end

		local node_type_success, node_type = pcall(function()
			return node:type()
		end)
		if not node_type_success or not node_type then
			return false
		end

		-- Direct type match
		for _, type_name in ipairs(function_types) do
			if node_type == type_name then
				return true
			end
		end

		-- Partial match for custom language types
		if node_type:match("function") or node_type:match("method") then
			return true
		end

		-- Check for variable declaration with function
		if node_type == "variable_declarator" or node_type == "lexical_declaration" then
			local child_count_success, child_count = pcall(function()
				return node:named_child_count()
			end)

			if child_count_success and child_count > 0 then
				for i = 0, child_count - 1 do
					local child_success, child = pcall(function()
						return node:named_child(i)
					end)

					if child_success and child then
						local child_type_success, child_type = pcall(function()
							return child:type()
						end)

						if
							child_type_success
							and child_type
							and (
								child_type == "arrow_function"
								or child_type == "function"
								or child_type:match("function")
							)
						then
							return true
						end
					end
				end
			end
		end

		return false
	end

	-- Find function node by walking up the tree
	local function_node = cursor_node
	while function_node do
		if is_function_node(function_node) then
			break
		end

		local parent_success, parent = pcall(function()
			return function_node:parent()
		end)

		if not parent_success or not parent then
			break
		end

		function_node = parent
	end

	if not function_node or not is_function_node(function_node) then
		vim.notify("No enclosing function found", vim.log.levels.DEBUG)
		return {
			start_line = math.max(0, pos.line - 10),
			end_line = pos.line + 50,
		}
	end

	-- Fix for the function range extraction in get_function_bounds function
	local range_success, range_data = pcall(function()
		return function_node:range()
	end)

	if not range_success then
		vim.notify("Failed to get function range: " .. tostring(range_data), vim.log.levels.DEBUG)
		return {
			start_line = math.max(0, pos.line - 10),
			end_line = pos.line + 50,
		}
	end

	-- Check if range_data is valid and has all required values
	local start_row, start_col, end_row, end_col
	if type(range_data) ~= "table" then
		-- Handle case where range_data is not a table
		vim.notify("Invalid range data type: " .. type(range_data), vim.log.levels.DEBUG)
		return {
			start_line = math.max(0, pos.line - 10),
			end_line = pos.line + 50,
		}
	else
		-- Need to handle both array-like returns and function returns
		if #range_data >= 4 then
			-- Array-like return
			start_row, start_col, end_row, end_col = range_data[1], range_data[2], range_data[3], range_data[4]
		else
			-- Direct function return - try to unpack safely
			start_row, start_col, end_row, end_col = range_data()
		end

		-- Final validation of unpacked values
		if not start_row or not end_row then
			vim.notify("Missing critical range values", vim.log.levels.DEBUG)
			return {
				start_line = math.max(0, pos.line - 10),
				end_line = pos.line + 50,
			}
		end
	end

	-- Now it's safe to use start_row and end_row
	return {
		start_line = start_row,
		end_line = end_row + 1, -- Make inclusive
	}
end

-- Enhanced function to detect function calls with robust TypeScript/Async support
-- @param bufnr number: Buffer number to analyze
-- @param pos table: Position {line, character} to analyze
-- @param node_id string: Node ID in the dependency tree
-- @param tree table: The dependency tree object
-- @param max_depth number: Maximum recursion depth
-- @return table: Table of detected function calls
function M.detect_function_calls(bufnr, pos, node_id, tree, max_depth)
	-- Type validation
	if type(bufnr) ~= "number" then
		vim.notify("detect_function_calls: Expected number for bufnr, got " .. type(bufnr), vim.log.levels.ERROR)
		return {}
	end

	if not vim.api.nvim_buf_is_valid(bufnr) then
		vim.notify("detect_function_calls: Invalid buffer: " .. tostring(bufnr), vim.log.levels.ERROR)
		return {}
	end

	if type(pos) ~= "table" or pos.line == nil or pos.character == nil then
		vim.notify("detect_function_calls: Invalid position object", vim.log.levels.ERROR)
		return {}
	end

	if type(node_id) ~= "string" then
		vim.notify("detect_function_calls: Expected string for node_id, got " .. type(node_id), vim.log.levels.ERROR)
		return {}
	end

	if type(tree) ~= "table" or type(tree.nodes) ~= "table" then
		vim.notify("detect_function_calls: Invalid tree object", vim.log.levels.ERROR)
		return {}
	end

	if not tree.nodes[node_id] then
		vim.notify("detect_function_calls: Node ID not found in tree: " .. node_id, vim.log.levels.ERROR)
		return {}
	end

	-- Normalize max_depth
	max_depth = tonumber(max_depth) or 3
	max_depth = math.min(math.max(max_depth, 1), 10) -- Clamp between 1 and 10

	local function_calls = {}
	local file_path = vim.api.nvim_buf_get_name(bufnr)

	-- Get function bounds safely
	local bounds = M.get_function_bounds(bufnr, pos)
	if not bounds then
		vim.notify("detect_function_calls: Could not determine function bounds", vim.log.levels.DEBUG)
		-- Fall back to a reasonable range
		bounds = {
			start_line = math.max(0, pos.line - 10),
			end_line = pos.line + 50,
		}
	end

	-- Get the entire function text for comprehensive analysis
	local lines = vim.api.nvim_buf_get_lines(bufnr, bounds.start_line, bounds.end_line, false)
	local function_text = table.concat(lines, "\n")

	-- Special handling for TypeScript async/await patterns
	local filetype = get_filetype_safe(bufnr)
	local is_typescript = filetype == "typescript" or filetype == "typescriptreact"

	if is_typescript then
		-- Find await expressions
		for await_expr in function_text:gmatch("await%s+([%w_%.]+)%s*%(") do
			function_calls[await_expr] = {
				name = await_expr,
				type = "function_call",
				discovered_by = "ts_await_pattern",
			}
		end

		-- Find try-catch blocks with await
		for try_block in function_text:gmatch("try%s*{([^}]*)") do
			for await_expr in try_block:gmatch("await%s+([%w_%.]+)%s*%(") do
				function_calls[await_expr] = {
					name = await_expr,
					type = "function_call",
					discovered_by = "ts_try_await_pattern",
				}
			end
		end
	end

	-- Standard function call detection using patterns
	for i, line in ipairs(lines) do
		if type(line) ~= "string" then
			goto continue_line
		end

		-- Comprehensive patterns for function calls
		local patterns = {
			"([%w_]+)%s*%(", -- Basic function calls: foo()
			"([%w_%.]+)%s*%(", -- Method calls: obj.method()
			"await%s+([%w_]+)%s*%(", -- Await expressions: await foo()
			"await%s+([%w_%.]+)%s*%(", -- Await method calls: await obj.method()
		}

		for _, pattern in ipairs(patterns) do
			for func_name in line:gmatch(pattern) do
				-- Skip language keywords and already processed names
				if not utils.is_keyword(func_name) and not function_calls[func_name] then
					function_calls[func_name] = {
						name = func_name,
						type = "function_call",
						line = bounds.start_line + i - 1,
						discovered_by = "regex",
					}
				end
			end
		end

		::continue_line::
	end

	-- Process each detected function call to find its definition
	for func_name, call_info in pairs(function_calls) do
		-- Skip processing if the name is invalid
		if type(func_name) ~= "string" or func_name == "" then
			goto continue_func
		end

		-- Find function position in the buffer
		local func_pos = nil
		for line_num = bounds.start_line, bounds.end_line do
			local line_content = vim.api.nvim_buf_get_lines(bufnr, line_num, line_num + 1, false)[1]
			if not line_content then
				goto continue_line_check
			end

			-- Look for exact function name match
			local pattern = "%f[%w_]" .. func_name .. "%f[^%w_]"
			local start_idx = line_content:find(pattern)
			if start_idx then
				func_pos = { line = line_num, character = start_idx - 1 }
				break
			end

			::continue_line_check::
		end

		if not func_pos then
			-- Fallback position
			func_pos = { line = bounds.start_line, character = 0 }
		end

		-- Create LSP parameters for definition lookup
		local params = {
			textDocument = { uri = vim.uri_from_bufnr(bufnr) },
			position = func_pos,
			context = { includeDeclaration = true },
		}

		-- Get definitions using LSP with error handling
		local definitions = {}
		local lsp_success, lsp_result = pcall(function()
			return lsp.get_definitions(params)
		end)

		if lsp_success and lsp_result then
			definitions = lsp_result
		end

		-- Process each definition
		for _, def in ipairs(definitions) do
			if not def or not def.range then
				goto continue_def
			end

			local def_uri = def.uri or def.targetUri
			if not def_uri then
				goto continue_def
			end

			local def_path = def_uri:gsub("file://", "")

			-- Handle relative paths for TypeScript
			if def_path:match("^%.") then
				local current_dir = file_path:match("(.*)/[^/]*$") or "."
				def_path = vim.fn.fnamemodify(current_dir .. "/" .. def_path, ":p")
			end

			-- Skip excluded paths
			if utils.should_exclude(def_path) then
				goto continue_def
			end

			-- Get buffer for definition
			local def_bufnr
			local buf_success, buf_result = pcall(function()
				return vim.uri_to_bufnr(def_uri)
			end)

			if not buf_success or not buf_result then
				goto continue_def
			end
			def_bufnr = buf_result

			-- Get position for definition
			local def_pos = lsp.lsp_to_buf_pos(def.range.start)
			if not def_pos then
				goto continue_def
			end

			local def_id = string.format("%s:%d:%d", def_path, def_pos.line, def_pos.character)

			-- Connect nodes if we already have this definition
			if tree.nodes[def_id] then
				-- Add bidirectional relationship
				if not vim.tbl_contains(tree.nodes[node_id].children, def_id) then
					table.insert(tree.nodes[node_id].children, def_id)
				end

				if not vim.tbl_contains(tree.nodes[def_id].parents, node_id) then
					table.insert(tree.nodes[def_id].parents, node_id)
				end
			else
				-- Recursively analyze this function definition
				if max_depth > 1 then
					local rec_success, _ = pcall(function()
						M.build_dependency_tree(def_bufnr, def_pos, 1, max_depth - 1, "down", tree, node_id)
					end)

					if not rec_success then
						vim.notify("Failed to recursively analyze: " .. func_name, vim.log.levels.DEBUG)
					end
				end
			end

			-- Record function call in variables_used
			local var_entry = {
				name = func_name,
				is_function_call = true,
				definition = {
					uri = def_uri,
					path = def_path,
					line = def_pos.line + 1,
					column = def_pos.character + 1,
				},
			}

			-- Check for duplicates
			local duplicate = false
			for _, entry in ipairs(tree.nodes[node_id].variables_used) do
				if entry.name == func_name and entry.is_function_call then
					duplicate = true
					break
				end
			end

			if not duplicate then
				table.insert(tree.nodes[node_id].variables_used, var_entry)
			end

			::continue_def::
		end

		::continue_func::
	end

	return function_calls
end

-- Process TypeScript imports to handle @ aliases and relative paths
-- @param bufnr number: Buffer number to analyze
-- @param pos table: Position {line, character} to analyze
-- @param node_id string: Node ID in dependency tree
-- @param tree table: The dependency tree
-- @param max_depth number: Maximum recursion depth
function M.process_typescript_imports(bufnr, pos, node_id, tree, max_depth)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	local file_path = vim.api.nvim_buf_get_name(bufnr)
	if not file_path or file_path == "" then
		return
	end

	-- Get all lines in the buffer
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	if not lines or #lines == 0 then
		return
	end

	-- Look for import statements
	local imports = {}
	local import_pattern = "import%s+{?%s*([^}]*)%s*}?%s+from%s+['\"]([^'\"]+)['\"]"
	local direct_import_pattern = "import%s+(%w+)%s+from%s+['\"]([^'\"]+)['\"]"

	for _, line in ipairs(lines) do
		-- Match import { x, y } from 'path' pattern
		for symbols, path in line:gmatch(import_pattern) do
			if path then
				-- Split multiple symbols if needed
				for symbol in symbols:gmatch("([^,%s]+)") do
					imports[symbol] = {
						path = path,
						type = "named",
					}
				end
			end
		end

		-- Match import x from 'path' pattern
		for symbol, path in line:gmatch(direct_import_pattern) do
			if path then
				imports[symbol] = {
					path = path,
					type = "default",
				}
			end
		end
	end

	-- Get the function bounds to determine usage
	local bounds = M.get_function_bounds(bufnr, pos)
	if not bounds then
		bounds = {
			start_line = math.max(0, pos.line - 10),
			end_line = pos.line + 50,
		}
	end

	-- Get function content
	local function_lines = vim.api.nvim_buf_get_lines(bufnr, bounds.start_line, bounds.end_line, false)
	local function_text = table.concat(function_lines, "\n")

	-- Now check which imports are used in the function
	for symbol, import_info in pairs(imports) do
		-- Check if the symbol is used in the function
		local is_used = function_text:match("%f[%w_]" .. symbol .. "%f[^%w_]") ~= nil

		if is_used then
			-- Resolve the import path
			local resolved_path = M.resolve_typescript_import(import_info.path, file_path)
			if resolved_path then
				-- Try to find the file with various extensions
				local extensions = { ".ts", ".js", ".tsx", ".jsx", "" }
				local found_file = nil

				for _, ext in ipairs(extensions) do
					local file_with_ext = resolved_path .. ext
					if vim.fn.filereadable(file_with_ext) == 1 then
						found_file = file_with_ext
						break
					end
				end

				if found_file then
					local import_bufnr = vim.uri_to_bufnr("file://" .. found_file)

					-- Load the buffer if necessary
					if not vim.api.nvim_buf_is_loaded(import_bufnr) then
						vim.fn.bufload(import_bufnr)
					end

					-- Find symbol in the file
					local symbol_pos = M.find_symbol_in_file(import_bufnr, symbol)
					if symbol_pos then
						-- Add the import to the dependency tree
						local success, _ = pcall(function()
							M.build_dependency_tree(import_bufnr, symbol_pos, 1, max_depth, "down", tree, node_id)
						end)

						if not success then
							vim.notify("Failed to process import for " .. symbol, vim.log.levels.DEBUG)
						end
					end
				end
			end
		end
	end
end

-- Resolve TypeScript import paths (handles @ aliases and relative paths)
-- @param import_path string: Import path from code
-- @param current_file_path string: Path of the current file
-- @return string: Resolved filesystem path
function M.resolve_typescript_import(import_path, current_file_path)
	if not import_path or not current_file_path then
		return nil
	end

	local is_relative = import_path:match("^%.") ~= nil

	if is_relative then
		local dir = current_file_path:match("(.*)/[^/]*$") or "."
		return vim.fn.fnamemodify(dir .. "/" .. import_path, ":p"):gsub("/$", "")
	end

	-- Handle @ imports (TypeScript path aliases)
	if import_path:match("^@/") then
		local project_root = utils.get_project_root()
		local aliased_path = import_path:gsub("^@/", "")

		-- Try multiple common paths
		local possible_paths = {
			project_root .. "/src/" .. aliased_path,
			project_root .. "/" .. aliased_path,
		}

		for _, path in ipairs(possible_paths) do
			if vim.fn.isdirectory(vim.fn.fnamemodify(path, ":h")) == 1 then
				return path
			end
		end

		-- Fallback to src
		return project_root .. "/src/" .. aliased_path
	end

	-- Handle node_modules or other imports
	local project_root = utils.get_project_root()
	return project_root .. "/node_modules/" .. import_path
end

-- Find a symbol in a file
-- @param bufnr number: Buffer number to search
-- @param symbol string: Symbol name to find
-- @return table|nil: Position {line, character} or nil if not found
function M.find_symbol_in_file(bufnr, symbol)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	if not lines or #lines == 0 then
		return nil
	end

	-- Patterns to find symbol definitions
	local patterns = {
		"export%s+const%s+" .. symbol .. "%s*=",
		"export%s+function%s+" .. symbol .. "%s*%(",
		"export%s+default%s+function%s+" .. symbol .. "%s*%(",
		"export%s+default%s+const%s+" .. symbol .. "%s*=",
		"const%s+" .. symbol .. "%s*=",
		"function%s+" .. symbol .. "%s*%(",
		"class%s+" .. symbol,
	}

	for i, line in ipairs(lines) do
		for _, pattern in ipairs(patterns) do
			if line:match(pattern) then
				local col = line:find(symbol)
				if col then
					return { line = i - 1, character = col - 1 }
				end
			end
		end
	end

	-- Try using Treesitter for better accuracy
	if vim.treesitter then
		local success, parser = pcall(vim.treesitter.get_parser, bufnr)
		if success and parser then
			local tree = parser:parse()[1]
			if tree then
				local root = tree:root()
				if root then
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
                    ]],
						symbol,
						symbol,
						symbol,
						symbol
					)

					local lang = vim.treesitter.language.get_lang(bufnr) or "typescript"
					local query_success, query = pcall(vim.treesitter.query.parse, lang, query_str)

					if query_success and query then
						for id, node in query:iter_captures(root, bufnr, 0, -1) do
							local range_success, range = pcall(function()
								return node:range()
							end)
							if range_success then
								local start_row, start_col = range[1], range[2]
								return { line = start_row, character = start_col }
							end
						end
					end
				end
			end
		end
	end

	return nil
end

-- Build the dependency tree recursively
function M.build_dependency_tree(bufnr, pos, depth, max_depth, direction, tree, parent_id)
	if depth > max_depth then
		return
	end

	-- Protect against nil parameters
	if not bufnr or not pos then
		return
	end

	-- Check if buffer is valid
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	-- Get file path and check if it's valid
	local file_path = vim.api.nvim_buf_get_name(bufnr)
	if not file_path or file_path == "" then
		return
	end

	-- Get filetype safely
	local filetype = get_filetype_safe(bufnr)
	if filetype == "" then
		return
	end

	-- Only process supported filetypes
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
		return
	end

	local params = {
		textDocument = { uri = vim.uri_from_bufnr(bufnr) },
		position = {
			line = pos.line,
			character = pos.character,
		},
		context = { includeDeclaration = true },
	}

	local symbol = nil
	if depth == 0 then
		-- Save current cursor position
		local saved_win = vim.api.nvim_get_current_win()
		local saved_pos = vim.api.nvim_win_get_cursor(saved_win)

		-- Set cursor to the position we're analyzing
		local temp_buf = vim.api.nvim_get_current_buf()
		if temp_buf == bufnr then
			vim.api.nvim_win_set_cursor(saved_win, { pos.line + 1, pos.character })
			symbol = lsp.get_symbol_info_at_cursor()
			-- Restore cursor
			vim.api.nvim_win_set_cursor(saved_win, saved_pos)
		else
			-- Fallback to text-based extraction
			symbol = lsp.get_symbol_at_pos(bufnr, pos)
		end
	else
		-- For non-root nodes, use text-based extraction
		symbol = lsp.get_symbol_at_pos(bufnr, pos)
	end

	if not symbol then
		return
	end

	-- Check if we've already analyzed this symbol in this file
	if utils.has_analyzed_symbol(symbol, file_path) and depth > 0 then
		-- We've already processed this symbol in this file
		return
	end

	-- Mark this symbol as analyzed in this file
	utils.mark_symbol_analyzed(symbol, file_path)

	-- Ensure we have a valid file path
	if not file_path or file_path == "" then
		return
	end
	local node_id = string.format("%s:%d:%d", file_path, pos.line, pos.character)

	-- Check cache to avoid circular references
	local cache_key = node_id .. direction
	if utils.processed_cache[cache_key] then
		return
	end
	utils.processed_cache[cache_key] = true

	-- Create node if it doesn't exist
	if not tree.nodes[node_id] then
		local short_path = file_path:match("([^/]+)$") or file_path

		-- Check if this is a React component
		local is_react_component = M.is_react_component(bufnr, pos, symbol)
		local component_props = {}
		if is_react_component then
			component_props = M.extract_component_props(bufnr, pos, symbol)
		end

		tree.nodes[node_id] = {
			id = node_id,
			symbol = symbol,
			file = short_path,
			line = pos.line + 1,
			column = pos.character + 1,
			full_path = file_path,
			children = {},
			parents = {},
			variables_used = {},
			is_root = (depth == 0),
			is_implementation = false,
			source_code = M.extract_function_source(bufnr, pos),
			docblock = M.extract_function_docblock(bufnr, pos),
			is_react_component = is_react_component,
			component_props = component_props,
		}
	end

	-- Connect with parent
	if parent_id and parent_id ~= node_id then
		if direction == "up" then
			table.insert(tree.nodes[node_id].children, parent_id)
			table.insert(tree.nodes[parent_id].parents, node_id)
		else
			table.insert(tree.nodes[node_id].parents, parent_id)
			table.insert(tree.nodes[parent_id].children, node_id)
		end
	end

	-- Process references (callers) - upward direction
	if direction == "up" or direction == "both" then
		local references = lsp.get_references(params)
		for _, ref in ipairs(references) do
			-- Check if ref and ref.range exist
			if not ref or not ref.range then
				goto continue_ref
			end

			-- Skip self-references
			local ref_uri = ref.uri or ref.targetUri
			local ref_bufnr = vim.uri_to_bufnr(ref_uri)
			local ref_pos = lsp.lsp_to_buf_pos(ref.range.start)
			local ref_id = string.format("%s:%d:%d", ref_uri:gsub("file://", ""), ref_pos.line, ref_pos.character)

			if ref_id ~= node_id then
				M.build_dependency_tree(ref_bufnr, ref_pos, depth + 1, max_depth, "up", tree, node_id)
			end

			::continue_ref::
		end

		-- Special handling for React components - find where this component is imported
		if tree.nodes[node_id].is_react_component and config.react and config.react.enabled then
			M.find_component_imports(bufnr, symbol, tree, node_id)
		end
	end

	-- Process definitions (callees) - downward direction
	if direction == "down" or direction == "both" then
		local definitions = lsp.get_definitions(params)
		for _, def in ipairs(definitions) do
			-- Check if def and def.range exist
			if not def or not def.range then
				goto continue_def
			end

			local def_uri = def.uri or def.targetUri
			local def_bufnr = vim.uri_to_bufnr(def_uri)
			local def_pos = lsp.lsp_to_buf_pos(def.range.start)

			-- Handle relative paths in the URI
			local def_path = def_uri:gsub("file://", "")

			-- Normalize relative paths (important for TypeScript imports)
			if def_path:match("^%.") then
				local current_dir = file_path:match("(.*)/[^/]*$") or "."
				def_path = vim.fn.fnamemodify(current_dir .. "/" .. def_path, ":p")
			end

			local def_id = string.format("%s:%d:%d", def_path, def_pos.line, def_pos.character)

			if def_id ~= node_id then
				M.build_dependency_tree(def_bufnr, def_pos, depth + 1, max_depth, "down", tree, node_id)
			end

			::continue_def::
		end

		-- Special handling for React components - find components used by this component
		if tree.nodes[node_id].is_react_component and config.react and config.react.enabled then
			M.find_used_components(bufnr, pos, tree, node_id, max_depth, symbol)
		end

		-- Process TypeScript imports for better dependency tracking
		if filetype == "typescript" or filetype == "typescriptreact" then
			M.process_typescript_imports(bufnr, pos, node_id, tree, max_depth - depth)
		end
	end

	-- Find and process variable references and function calls
	if depth == 0 or (tree.nodes[node_id] and direction == "down") then
		-- First detect direct function calls with enhanced detection
		if tree.nodes[node_id] then
			M.detect_function_calls(bufnr, pos, node_id, tree, max_depth - depth)
		end

		-- Then process variable references
		local variable_refs = M.find_variable_references(bufnr, pos)

		for _, var_name in ipairs(variable_refs) do
			-- Skip already processed variables
			if utils.processed_cache[var_name .. node_id] then
				goto continue_var
			end
			utils.processed_cache[var_name .. node_id] = true

			-- Check if it's an imported module (to avoid exploring node_modules)
			if M.is_imported_type(bufnr, var_name) then
				if utils.should_exclude(file_path) then
					goto continue_var
				end
			end

			-- Try to find definition for this variable using LSP
			local var_params = {
				textDocument = { uri = vim.uri_from_bufnr(bufnr) },
				position = pos, -- Use current position as starting point
				context = { includeDeclaration = true },
			}

			-- Find all occurrences of the variable in the buffer
			local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
			for line_num, line in ipairs(lines) do
				if not line then
					goto continue_line
				end

				local col = 1
				while true do
					col = line:find(var_name, col)
					if not col then
						break
					end

					-- Check if it's a standalone identifier
					local before_char = col > 1 and line:sub(col - 1, col - 1) or " "
					local after_char = col + #var_name <= #line and line:sub(col + #var_name, col + #var_name) or " "

					if not before_char:match("[%w_]") and not after_char:match("[%w_]") then
						-- Found an occurrence, try to check its definition
						var_params.position = { line = line_num - 1, character = col - 1 }

						-- Use LSP to find definition
						local def_results = vim.lsp.buf_request_sync(bufnr, "textDocument/definition", var_params, 1000)
						if def_results then
							for _, res in pairs(def_results) do
								if res.result then
									local defs = type(res.result) == "table" and res.result or { res.result }
									for _, def in ipairs(defs) do
										if not def or not def.range then
											goto continue_result
										end

										local def_uri = def.uri or def.targetUri
										local def_path = def_uri:gsub("file://", "")

										-- Skip if from excluded path
										if utils.should_exclude(def_path) then
											goto continue_result
										end

										local def_bufnr = vim.uri_to_bufnr(def_uri)
										local def_pos = lsp.lsp_to_buf_pos(def.range.start)

										-- Skip if we've already processed this definition
										local def_symbol = lsp.get_symbol_at_pos(def_bufnr, def_pos)
										if def_symbol and utils.has_analyzed_symbol(def_symbol, def_path) then
											goto continue_result
										end

										-- Recursively explore this variable's definition
										if depth < max_depth then
											M.build_dependency_tree(
												def_bufnr,
												def_pos,
												depth + 1,
												max_depth,
												"down",
												tree,
												node_id
											)
										end

										-- Record that this variable was used
										table.insert(tree.nodes[node_id].variables_used, {
											name = var_name,
											line = line_num,
											column = col,
											definition = {
												uri = def_uri,
												line = def_pos.line + 1,
												column = def_pos.character + 1,
											},
										})

										::continue_result::
									end
								end
							end
						end
					end

					col = col + 1
				end

				::continue_line::
			end

			::continue_var::
		end
	end
end

-- Check if a node is a React component
function M.is_react_component(bufnr, pos, symbol_name)
	if not symbol_name then
		return false
	end

	-- Get file path and check React-specific patterns
	local file_path = vim.api.nvim_buf_get_name(bufnr)
	local ext = file_path:match("%.([^%.]+)$")

	-- Check file extension first
	local is_react_file = ext == "jsx" or ext == "tsx" or ext == "js" or ext == "ts"
	if not is_react_file then
		return false
	end

	-- Try to analyze the content for React component patterns
	local lines = utils.read_file_contents(file_path)
	if not lines then
		return false
	end

	local content = table.concat(lines, "\n")

	-- Check for common React imports and patterns
	if content:match("import%s+React") or content:match("from%s+['\"]react['\"]") then
		-- Look for component definition patterns
		if
			content:match("function%s+" .. symbol_name .. "%s*%(")
			or content:match("const%s+" .. symbol_name .. "%s*=%s*%(%s*%)%s*=>")
			or content:match("class%s+" .. symbol_name .. "%s+extends%s+React%.Component")
			or content:match("class%s+" .. symbol_name .. "%s+extends%s+Component")
		then
			-- Check if it returns JSX
			if content:match("return%s*%(%s*<") or content:match("render%s*%(%s*%)%s*{[^}]*<%s*%w+") then
				return true
			end
		end
	end

	return false
end

-- Extract props from a React component
function M.extract_component_props(bufnr, pos, symbol_name)
	local props = {}
	local file_path = vim.api.nvim_buf_get_name(bufnr)
	local lines = utils.read_file_contents(file_path)

	if not lines or not symbol_name then
		return props
	end

	-- Find component bounds
	local start_line = pos.line
	local end_line = #lines

	-- Look for props pattern in function arguments or class props
	for i = start_line, math.min(start_line + 20, #lines) do
		local line = lines[i]
		if not line then
			goto continue_line
		end

		-- Check function parameters for destructured props
		local props_pattern = "function%s+" .. symbol_name .. "%s*%(%s*{(.-)}"
		local arrow_pattern = "const%s+" .. symbol_name .. "%s*=%s*%({(.-)}%)"

		local props_str = line:match(props_pattern) or line:match(arrow_pattern)

		if props_str then
			-- Parse destructured props
			for prop in props_str:gmatch("([%w_]+)") do
				if not utils.is_keyword(prop) and prop ~= "props" then
					table.insert(props, prop)
				end
			end
			break
		end

		-- Check for props type definitions
		local type_str = line:match("type%s+" .. symbol_name .. "Props%s*=%s*{(.-)}")
		if type_str then
			local type_end_line = i
			-- Find the end of the type definition
			for j = i, math.min(i + 20, #lines) do
				if lines[j] and lines[j]:match("};") then
					type_end_line = j
					break
				end
			end

			-- Extract prop names from type definition
			for j = i, type_end_line do
				local prop = lines[j] and lines[j]:match("([%w_]+)%s*:")
				if prop and not utils.is_keyword(prop) then
					table.insert(props, prop)
				end
			end
			break
		end

		::continue_line::
	end

	return props
end

-- Find files importing a specific component
function M.find_component_imports(bufnr, component_name, tree, node_id)
	local file_path = vim.api.nvim_buf_get_name(bufnr)
	if not file_path or file_path == "" or not component_name then
		return
	end

	-- Get directory of the current file
	local dir_path = file_path:match("(.*)/[^/]*$") or "."

	-- Skip if we're already at project root
	if dir_path == "." then
		return
	end

	-- Go one level up to find parent directories
	local parent_dir = dir_path:match("(.*)/[^/]*$") or "."

	-- Find all potential JavaScript/TypeScript files in parent directory
	local find_cmd
	if vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
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

	-- Execute command
	local output = vim.fn.system(find_cmd)
	if vim.v.shell_error ~= 0 then
		return
	end

	-- Process each file
	for potential_file in output:gmatch("[^\r\n]+") do
		-- Skip the current file and excluded files
		if potential_file ~= file_path and not utils.should_exclude(potential_file) then
			local content = utils.read_file_contents(potential_file)
			if content then
				local file_content = table.concat(content, "\n")

				-- Check if file imports our component
				-- Pattern for ES6 imports
				local import_pattern = "import%s+{[^}]*%s*" .. component_name .. "%s*[,}].-from%s+['\"]([^'\"]+)['\"]"
				local direct_import_pattern = "import%s+" .. component_name .. "%s+from%s+['\"]([^'\"]+)['\"]"

				local found_import = file_content:match(import_pattern) or file_content:match(direct_import_pattern)

				if found_import then
					-- Check for usage of the component in JSX
					local usage_pattern = "<%s*" .. component_name .. "[%s/>]"
					if file_content:match(usage_pattern) then
						-- Found a file that imports and uses the component
						local new_bufnr = vim.uri_to_bufnr("file://" .. potential_file)

						-- Load file if necessary
						if not vim.api.nvim_buf_is_loaded(new_bufnr) then
							vim.fn.bufload(new_bufnr)
						end

						-- Find the line number where component is used
						local usage_line = 0
						for i, line in ipairs(content) do
							if line:match(usage_pattern) then
								usage_line = i - 1
								break
							end
						end

						-- Add this usage to the tree
						if usage_line > 0 then
							local usage_pos = { line = usage_line, character = 0 }
							local usage_id = string.format("%s:%d:%d", potential_file, usage_line, 0)

							-- Create a node for the usage if it doesn't exist
							if not tree.nodes[usage_id] then
								local usage_symbol = lsp.get_symbol_at_pos(new_bufnr, usage_pos) or "ComponentReference"

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
								table.insert(tree.nodes[node_id].parents, usage_id)
							end
						end
					end
				end
			end
		end
	end
end

-- Find components used by a React component
function M.find_used_components(bufnr, pos, tree, node_id, max_depth, component_name)
	-- Skip if we're already at max depth
	if not tree.nodes[node_id] or #tree.nodes[node_id].children >= max_depth then
		return
	end

	local file_path = vim.api.nvim_buf_get_name(bufnr)
	local lines = utils.read_file_contents(file_path)

	if not lines then
		return
	end

	-- Get source code
	local source_code = table.concat(lines, "\n")

	-- Find all imports that might be components
	local imports = {}
	for line in source_code:gmatch("[^\r\n]+") do
		-- Match named imports: import { Component1, Component2 } from '...'
		local import_list = line:match("import%s+{([^}]+)}")
		if import_list then
			for comp_name in import_list:gmatch("([%w_]+)") do
				if comp_name and comp_name:match("^[A-Z]") then -- Components usually start with uppercase
					imports[comp_name] = true
				end
			end
		end

		-- Match direct imports: import Component from '...'
		local direct_import = line:match("import%s+([%w_]+)%s+from")
		if direct_import and direct_import:match("^[A-Z]") then
			imports[direct_import] = true
		end
	end

	-- Now search for JSX usage of these components
	for imported_comp, _ in pairs(imports) do
		local usage_pattern = "<%s*" .. imported_comp .. "[%s/>]"

		-- Find usages
		for i, line in ipairs(lines) do
			if line:match(usage_pattern) then
				-- Try to find the definition of this component
				local def_params = {
					textDocument = { uri = vim.uri_from_bufnr(bufnr) },
					position = { line = i - 1, character = line:find(imported_comp) or 0 },
					context = { includeDeclaration = true },
				}

				local definitions = lsp.get_definitions(def_params)

				-- If we found definitions, add them to the tree
				for _, def in ipairs(definitions) do
					if def and def.range then
						local def_uri = def.uri or def.targetUri
						local def_bufnr = vim.uri_to_bufnr(def_uri)
						local def_pos = lsp.lsp_to_buf_pos(def.range.start)

						-- Recursive call to analyze the component
						M.build_dependency_tree(def_bufnr, def_pos, 1, max_depth, "down", tree, node_id)
					end
				end

				-- If no definitions found through LSP, we might need to search files
				if #definitions == 0 then
					M.find_component_definition(imported_comp, tree, node_id)
				end

				-- Mark this component as used
				table.insert(tree.nodes[node_id].variables_used, {
					name = imported_comp,
					line = i,
					column = line:find(imported_comp) or 0,
					is_component = true,
				})

				-- Only process first usage
				break
			end
		end
	end
end

-- Find a component definition file
function M.find_component_definition(component_name, tree, node_id)
	if not component_name or not tree.nodes[node_id] then
		return
	end

	local file_path = tree.nodes[node_id].full_path
	local dir_path = file_path:match("(.*)/[^/]*$") or "."

	-- Common component file patterns
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
	}

	-- Check each potential path
	for _, path in ipairs(potential_paths) do
		local exists = vim.fn.filereadable(path) == 1
		if exists and not utils.should_exclude(path) then
			-- Found the file, now find the component definition inside
			local lines = utils.read_file_contents(path)
			if lines then
				for i, line in ipairs(lines) do
					-- Look for component definition patterns
					if
						line:match("function%s+" .. component_name .. "%s*%(")
						or line:match("const%s+" .. component_name .. "%s*=%s*%(%s*%)%s*=>")
						or line:match("class%s+" .. component_name .. "%s+extends")
					then
						-- Create a buffer for this file
						local new_bufnr = vim.uri_to_bufnr("file://" .. path)

						-- Load file if necessary
						if not vim.api.nvim_buf_is_loaded(new_bufnr) then
							vim.fn.bufload(new_bufnr)
						end

						-- Create a node for this component
						local comp_pos = { line = i - 1, character = line:find(component_name) or 0 }
						local comp_id = string.format("%s:%d:%d", path, comp_pos.line, comp_pos.character)

						if not tree.nodes[comp_id] then
							tree.nodes[comp_id] = {
								id = comp_id,
								symbol = component_name,
								file = path:match("([^/]+)$") or path,
								line = i,
								column = line:find(component_name) or 0,
								full_path = path,
								children = {},
								parents = { node_id },
								variables_used = {},
								is_react_component = true,
								source_code = M.extract_function_source(new_bufnr, comp_pos),
								docblock = M.extract_function_docblock(new_bufnr, comp_pos),
							}

							-- Connect the nodes
							table.insert(tree.nodes[node_id].children, comp_id)
						end

						return
					end
				end
			end
		end
	end
end

-- Find implementation of a function in other files
function M.find_function_implementation(root_node, tree)
	if not config.display_options.find_implementation then
		return
	end

	if not root_node or not root_node.symbol then
		return
	end

	-- First try LSP implementation finder
	local impl = lsp.find_implementation(root_node.symbol)
	if impl then
		local bufnr = vim.uri_to_bufnr(impl.uri)
		local pos = lsp.lsp_to_buf_pos(impl.range.start)
		local impl_id = string.format("%s:%d:%d", impl.uri:gsub("file://", ""), pos.line, pos.character)

		-- Add to tree if not already present
		if not tree.nodes[impl_id] then
			M.build_dependency_tree(bufnr, pos, 0, 1, "none", tree, nil)

			if tree.nodes[impl_id] then
				tree.nodes[impl_id].is_implementation = true
				tree.nodes[impl_id].implements = root_node.id
				root_node.implementation_id = impl_id
			end
		end
		return
	end

	-- Fallback to file search methods
	local files = utils.find_file_containing_definition(root_node.symbol, 20)

	-- Process found files
	for _, file_path in ipairs(files) do
		-- Skip the current file
		if file_path == root_node.full_path then
			goto continue_file
		end

		local lines = utils.read_file_contents(file_path)
		if not lines then
			goto continue_file
		end

		-- Look for potential implementation
		for line_num, line in ipairs(lines) do
			-- Check for function/const patterns that match our symbol
			if
				line:match("function%s+" .. root_node.symbol .. "%s*%(")
				or line:match("const%s+" .. root_node.symbol .. "%s*=%s*function")
				or line:match("const%s+" .. root_node.symbol .. "%s*=%s*async%s*function")
				or line:match("const%s+" .. root_node.symbol .. "%s*=%s*%(%s*%)%s*=>")
				or line:match("export%s+const%s+" .. root_node.symbol .. "%s*=")
			then
				-- Found a potential implementation
				local bufnr = vim.uri_to_bufnr("file://" .. file_path)
				local pos = { line = line_num - 1, character = line:find(root_node.symbol) - 1 }
				local impl_id = string.format("%s:%d:%d", file_path, pos.line, pos.character)

				-- Add to tree if not already present
				if not tree.nodes[impl_id] then
					-- Temporarily clear cache to force this build
					local saved_cache = utils.processed_cache
					utils.processed_cache = {}

					M.build_dependency_tree(bufnr, pos, 0, 1, "none", tree, nil)

					-- Restore cache
					utils.processed_cache = saved_cache

					if tree.nodes[impl_id] then
						tree.nodes[impl_id].is_implementation = true
						tree.nodes[impl_id].implements = root_node.id
						root_node.implementation_id = impl_id

						-- We found an implementation, analyze it further
						M.analyze_variable_dependencies(bufnr, pos, impl_id, tree)
						return
					end
				end

				-- If we found an implementation, no need to check more files
				return
			end
		end

		::continue_file::
	end
end

-- Check if a symbol is an imported/required type
function M.is_imported_type(bufnr, symbol)
	local file_path = vim.api.nvim_buf_get_name(bufnr)
	local lines = utils.read_file_contents(file_path)
	if not lines then
		return false
	end

	local content = table.concat(lines, "\n")

	-- Check import patterns
	if
		content:match("import%s+{[^}]*" .. symbol .. "[^}]*}")
		or content:match("import%s+" .. symbol .. "%s+from")
		or content:match("const%s+" .. symbol .. "%s*=%s*require")
	then
		return true
	end

	return false
end

-- Find variable references in function body
function M.find_variable_references(bufnr, pos, function_end_line)
	local file_path = vim.api.nvim_buf_get_name(bufnr)
	local lines = utils.read_file_contents(file_path)
	if not lines then
		return {}
	end

	local start_line = pos.line
	local end_line = function_end_line or #lines

	-- Try to use treesitter for better variable extraction if available
	if vim.treesitter then
		local has_parser, parser = pcall(vim.treesitter.get_parser, bufnr)
		if has_parser and parser then
			local identifiers = {}

			-- Get syntax tree
			local tree = parser:parse()[1]
			if tree and tree:root() then
				local root = tree:root()

				-- Query for variables
				local query_str = [[
          (identifier) @id
        ]]

				local ok, query = pcall(vim.treesitter.query.parse, parser:lang(), query_str)
				if ok and query then
					for id, node in query:iter_captures(root, bufnr, start_line, end_line) do
						local name = vim.treesitter.get_node_text(node, bufnr)
						if
							name
							and name ~= ""
							and not utils.tbl_contains({
								"if",
								"else",
								"return",
								"try",
								"catch",
								"for",
								"while",
								"switch",
								"case",
								"default",
								"break",
								"continue",
								"function",
								"const",
								"let",
								"var",
								"async",
								"await",
								"import",
								"export",
								"from",
								"true",
								"false",
								"null",
								"undefined",
								"class",
								"interface",
								"type",
								"enum",
								"string",
								"number",
								"boolean",
								"any",
								"this",
								"super",
							}, name)
						then
							identifiers[name] = true
						end
					end

					return vim.tbl_keys(identifiers)
				end
			end
		end
	end

	-- Fallback to regex-based extraction
	local identifiers = {}
	for i = start_line, end_line do
		local line = lines[i]
		if not line then
			goto continue_line
		end

		-- Find all identifiers in the line
		for identifier in line:gmatch("[%a_][%a%d_%.]*") do
			-- Filter out keywords and common types
			if
				not utils.tbl_contains({
					"if",
					"else",
					"return",
					"try",
					"catch",
					"for",
					"while",
					"switch",
					"case",
					"default",
					"break",
					"continue",
					"function",
					"const",
					"let",
					"var",
					"async",
					"await",
					"import",
					"export",
					"from",
					"true",
					"false",
					"null",
					"undefined",
					"class",
					"interface",
					"type",
					"enum",
					"string",
					"number",
					"boolean",
					"any",
					"this",
					"super",
				}, identifier)
			then
				identifiers[identifier] = true
			end
		end

		::continue_line::
	end

	return vim.tbl_keys(identifiers)
end

-- Extract function source
function M.extract_function_source(bufnr, pos)
	local bounds = M.get_function_bounds(bufnr, pos)
	if not bounds then
		return {}
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, bounds.start_line, bounds.end_line, false)
	return lines
end

-- Extract function docblock
function M.extract_function_docblock(bufnr, pos)
	local bounds = M.get_function_bounds(bufnr, pos)
	if not bounds or bounds.start_line <= 0 then
		return {}
	end

	-- Look for docblock before the function (up to 20 lines)
	local max_lines = 20
	local start_search = math.max(0, bounds.start_line - max_lines)
	local lines = vim.api.nvim_buf_get_lines(bufnr, start_search, bounds.start_line, false)

	local docblock = {}
	local in_docblock = false

	-- Scan backwards
	for i = #lines, 1, -1 do
		local line = lines[i]

		if not in_docblock and line:match("%*/") then
			-- Found the end of a docblock
			in_docblock = true
			table.insert(docblock, 1, line)
		elseif in_docblock then
			-- Inside a docblock
			table.insert(docblock, 1, line)
			if line:match("/%*%*") then
				-- Found the start
				break
			end
		elseif not in_docblock and line:match("^%s*//") then
			-- Line comment
			table.insert(docblock, 1, line)
		elseif not in_docblock and line:match("%S") and not line:match("^%s*//") and not line:match("^%s*/%*") then
			-- Non-comment line - stop looking
			break
		end
	end

	return docblock
end

-- Analyze function symbols (new method)
function M.analyze_function_symbols(bufnr, pos, tree, node_id, current_depth, max_depth)
	-- Get function bounds to focus our search
	local function_bounds = M.get_function_bounds(bufnr, pos)
	if not function_bounds then
		return
	end

	local start_line = function_bounds.start_line
	local end_line = function_bounds.end_line

	-- Get function content
	local file_path = vim.api.nvim_buf_get_name(bufnr)
	local lines = vim.api.nvim_buf_get_lines(bufnr, start_line, end_line, false)
	if not lines or #lines == 0 then
		return
	end

	-- Extract all symbols using Treesitter
	local symbols = {}
	if vim.treesitter then
		local parser = vim.treesitter.get_parser(bufnr)
		if parser then
			local tree_obj = parser:parse()[1]
			if tree_obj and tree_obj:root() then
				-- Query for identifiers
				local query_str = "(identifier) @id"
				local query = vim.treesitter.query.parse(parser:lang(), query_str)

				for id, node in query:iter_captures(tree_obj:root(), bufnr, start_line, end_line) do
					local symbol_name = vim.treesitter.get_node_text(node, bufnr)
					if
						symbol_name
						and symbol_name ~= ""
						and not utils.is_keyword(symbol_name)
						and not utils.has_analyzed_symbol(symbol_name, file_path)
					then
						symbols[symbol_name] = true
						-- Mark this symbol as processed in this file
						utils.mark_symbol_analyzed(symbol_name, file_path)
					end
				end
			end
		end
	end

	-- For each symbol, find its definition
	for symbol_name, _ in pairs(symbols) do
		-- Find definitions for this symbol
		local definitions = lsp.find_symbol_definitions(symbol_name)

		for _, def in ipairs(definitions) do
			if def.uri and def.range then
				local def_uri = def.uri
				local def_path = def_uri:gsub("file://", "")

				-- Skip if this is a recursive reference to the same file
				if def_path == file_path then
					goto continue_def
				end

				local def_bufnr = vim.uri_to_bufnr(def_uri)
				local def_pos = lsp.lsp_to_buf_pos(def.range.start)

				-- Skip if we've already processed this definition
				local def_id = string.format("%s:%d:%d", def_path, def_pos.line, def_pos.character)
				if tree.nodes[def_id] then
					goto continue_def
				end

				-- Load the buffer if needed
				if not vim.api.nvim_buf_is_loaded(def_bufnr) then
					vim.fn.bufload(def_bufnr)
				end

				-- Add this definition with limited recursion
				if current_depth < max_depth then
					M.build_dependency_tree(def_bufnr, def_pos, current_depth + 1, max_depth, "down", tree, node_id)
				end

				-- Record variable usage
				if tree.nodes[node_id] then
					table.insert(tree.nodes[node_id].variables_used, {
						name = symbol_name,
						definition = {
							uri = def_uri,
							path = def_path,
							line = def_pos.line + 1,
							column = def_pos.character + 1,
						},
					})
				end

				::continue_def::
			end
		end
	end
end

-- Backward compatibility function for previous API with enhanced robustness
-- @param bufnr number: Buffer number to analyze
-- @param pos table: Position {line, character} to start analysis
-- @param node_id string: ID of the node in the dependency tree
-- @param tree table: The dependency tree object
-- @return boolean: Success status
function M.analyze_variable_dependencies(bufnr, pos, node_id, tree)
	-- Type validation with detailed error handling
	if not bufnr or type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
		vim.notify("Invalid buffer in analyze_variable_dependencies", vim.log.levels.WARN)
		return false
	end

	if not pos or type(pos) ~= "table" or pos.line == nil or pos.character == nil then
		vim.notify("Invalid position in analyze_variable_dependencies", vim.log.levels.WARN)
		return false
	end

	if not node_id or type(node_id) ~= "string" then
		vim.notify("Invalid node_id in analyze_variable_dependencies", vim.log.levels.WARN)
		return false
	end

	if not tree or type(tree) ~= "table" or not tree.nodes then
		vim.notify("Invalid tree in analyze_variable_dependencies", vim.log.levels.WARN)
		return false
	end

	-- Verify the node exists in the tree
	if not tree.nodes[node_id] then
		vim.notify("Node ID not found in tree: " .. node_id, vim.log.levels.WARN)
		return false
	end

	-- Get maximum recursion depth from config with fallback and boundary check
	local max_depth = tonumber(config.max_depth) or 3
	max_depth = math.min(math.max(max_depth, 1), 10) -- Clamp between 1 and 10

	-- Wrap each call in pcall for resilience against isolated failures
	local success1, err1 = pcall(function()
		M.analyze_function_symbols(bufnr, pos, tree, node_id, 0, 1)
	end)

	if not success1 then
		vim.notify("Error in analyze_function_symbols: " .. tostring(err1), vim.log.levels.WARN)
	end

	local success2, err2 = pcall(function()
		M.detect_function_calls(bufnr, pos, node_id, tree, max_depth)
	end)

	if not success2 then
		vim.notify("Error in detect_function_calls: " .. tostring(err2), vim.log.levels.WARN)
	end

	-- Add TypeScript-specific analysis
	local filetype = get_filetype_safe(bufnr)
	if filetype == "typescript" or filetype == "typescriptreact" then
		local success3, err3 = pcall(function()
			M.process_typescript_imports(bufnr, pos, node_id, tree, max_depth)
		end)

		if not success3 then
			vim.notify("Error in process_typescript_imports: " .. tostring(err3), vim.log.levels.WARN)
		end
	end

	return success1 or success2 -- Return true if any analysis succeeded
end

return M
