-----------------
-- analyzer/treesitter.lua
-----------------
--[[
    Treesitter utilities for dependency-tree.nvim

    This module handles interactions with Neovim's Treesitter API for parsing
    and analyzing code structures.
]]

local M = {}

-- Get filetype safely (works across Neovim versions)
-- @param bufnr number: Buffer number
-- @return string: Filetype or empty string if not determinable
function M.get_filetype_safe(bufnr)
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

-- Check if Treesitter is properly set up
-- @return boolean: Whether Treesitter is available and working
function M.is_treesitter_available()
	if not vim.treesitter then
		return false
	end

	-- Check if we can get a language
	local success = pcall(vim.treesitter.language.get_lang, "lua")
	return success
end

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

	-- Get filetype safely
	local filetype = M.get_filetype_safe(bufnr)
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

-- Get function bounds using Treesitter with enhanced error handling
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
	local filetype = M.get_filetype_safe(bufnr)
	if filetype == "" then
		vim.notify("Could not determine filetype", vim.log.levels.DEBUG)
		return {
			start_line = math.max(0, pos.line - 10),
			end_line = pos.line + 50,
		}
	end

	-- Map filetypes to TreeSitter parser names
	local parser_map = {
		typescriptreact = "tsx",
		javascriptreact = "jsx",
	}

	-- Use the mapped parser name if available, otherwise use filetype
	local parser_name = parser_map[filetype] or filetype

	-- Check if parser exists for this filetype
	local parser_ok = pcall(vim.treesitter.language.require_language, parser_name, nil, true)
	if not parser_ok then
		vim.notify("Parser not available for " .. parser_name, vim.log.levels.DEBUG)
		return {
			start_line = math.max(0, pos.line - 10),
			end_line = pos.line + 50,
		}
	end

	-- Get parser safely
	local parser_success, parser = pcall(vim.treesitter.get_parser, bufnr, parser_name)
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

	-- Handle range extraction safely
	local start_row, end_row

	-- First try to get range data safely
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

	-- Initialize with fallback values
	start_row = math.max(0, pos.line - 10)
	end_row = pos.line + 50

	-- Handle different possible return types from range() with a more robust approach
	if type(range_data) == "table" then
		-- Array-like return (most common)
		if #range_data >= 4 then
			start_row = range_data[1]
			end_row = range_data[3]
		elseif type(range_data[1]) == "function" then
			-- Some versions might return a table with a function
			local sr, _, er, _ = range_data[1]()
			if sr and er then
				start_row = sr
				end_row = er
			end
		end
	elseif type(range_data) == "function" then
		-- Direct function return
		local sr, _, er, _ = range_data()
		if sr and er then
			start_row = sr
			end_row = er
		end
	elseif type(range_data) == "number" then
		-- If it's a number (likely a row number), use reasonable bounds around it
		start_row = range_data
		end_row = range_data + 30
	else
		vim.notify("Unhandled range_data type: " .. type(range_data), vim.log.levels.DEBUG)
	end

	-- Validate the values
	if type(start_row) ~= "number" or type(end_row) ~= "number" then
		start_row = math.max(0, pos.line - 10)
		end_row = pos.line + 50
		vim.notify("Invalid row values, using fallback", vim.log.levels.DEBUG)
	end

	-- Now it's safe to use start_row and end_row
	return {
		start_line = start_row,
		end_line = end_row + 1, -- Make inclusive
	}
end

-- Extract function source code
-- @param bufnr number: Buffer number
-- @param pos table: Position {line, character}
-- @return table: Array of source code lines
function M.extract_function_source(bufnr, pos)
	local bounds = M.get_function_bounds(bufnr, pos)
	if not bounds then
		return {}
	end

	-- Safely get the lines
	local lines_success, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, bounds.start_line, bounds.end_line, false)
	if not lines_success or not lines then
		return {}
	end

	return lines
end

-- Extract function docblock (comments before function)
-- @param bufnr number: Buffer number
-- @param pos table: Position {line, character}
-- @return table: Array of docblock lines
function M.extract_function_docblock(bufnr, pos)
	local bounds = M.get_function_bounds(bufnr, pos)
	if not bounds or bounds.start_line <= 0 then
		return {}
	end

	-- Look for docblock before the function (up to 20 lines)
	local max_lines = 20
	local start_search = math.max(0, bounds.start_line - max_lines)

	-- Safely get the lines
	local lines_success, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, start_search, bounds.start_line, false)
	if not lines_success or not lines then
		return {}
	end

	local docblock = {}
	local in_docblock = false

	-- Scan backwards
	for i = #lines, 1, -1 do
		local line = lines[i]
		if not line then
			goto continue
		end

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

		::continue::
	end

	return docblock
end

-- Ensure we return a table, not a boolean
return M
