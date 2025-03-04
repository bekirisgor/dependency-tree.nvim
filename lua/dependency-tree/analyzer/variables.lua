-----------------
-- analyzer/variables.lua
-----------------
--[[
    Variable analysis utilities for dependency-tree.nvim

    This module is responsible for detecting and analyzing variable declarations,
    references, and dependencies within functions.
]]

local config = require("dependency-tree.config")
local utils = require("dependency-tree.utils")
local lsp = require("dependency-tree.lsp")
local ts_utils = require("dependency-tree.analyzer.treesitter")

local M = {}

---Find variable references in a function body
---@param bufnr number Buffer number to analyze
---@param pos table Position with line and character fields
---@param function_end_line number|nil Optional end line of function (defaults to end of buffer)
---@return string[] Array of variable names found in the function
function M.find_variable_references(bufnr, pos, function_end_line)
	-- Type validation with detailed error handling
	if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
		if config.debug_mode then
			vim.notify("find_variable_references: Invalid buffer: " .. tostring(bufnr), vim.log.levels.DEBUG)
		end
		return {}
	end

	if type(pos) ~= "table" or type(pos.line) ~= "number" or type(pos.character) ~= "number" then
		if config.debug_mode then
			vim.notify("find_variable_references: Invalid position object", vim.log.levels.DEBUG)
		end
		return {}
	end

	if function_end_line ~= nil and (type(function_end_line) ~= "number" or function_end_line < pos.line) then
		if config.debug_mode then
			vim.notify("find_variable_references: Invalid function_end_line", vim.log.levels.DEBUG)
		end
		function_end_line = nil -- Reset to default behavior
	end

	local file_path = vim.api.nvim_buf_get_name(bufnr)

	-- Get lines with proper error handling
	local lines_success, lines = pcall(function()
		if function_end_line then
			return vim.api.nvim_buf_get_lines(bufnr, pos.line, function_end_line, false)
		else
			return utils.read_file_contents(file_path)
		end
	end)

	if not lines_success or not lines or #lines == 0 then
		if config.debug_mode then
			vim.notify("find_variable_references: Failed to read function content", vim.log.levels.DEBUG)
		end
		return {}
	end

	local start_line = pos.line
	local end_line = function_end_line or #lines

	-- Try to use treesitter for better variable extraction if available
	if vim.treesitter then
		local has_parser, parser = pcall(vim.treesitter.get_parser, bufnr)
		if has_parser and parser then
			---@type table<string, boolean>
			local identifiers = {}

			-- Get syntax tree
			local tree_success, tree = pcall(function()
				return parser:parse()[1]
			end)

			if tree_success and tree then
				local root_success, root = pcall(function()
					return tree:root()
				end)

				if root_success and root then
					-- Query for variables with comprehensive pattern matching
					local query_str = [[
                      (identifier) @id
                      (property_identifier) @prop
                      (member_expression property: (property_identifier) @member)
                    ]]

					local ok, query = pcall(vim.treesitter.query.parse, parser:lang(), query_str)
					if ok and query then
						-- Filter to exclude invalid or keyword identifiers
						local capture_success, _ = pcall(function()
							for id, node in query:iter_captures(root, bufnr, start_line, end_line) do
								local name_success, name = pcall(function()
									return vim.treesitter.get_node_text(node, bufnr)
								end)

								if name_success and name and name ~= "" and not utils.is_keyword(name) then
									identifiers[name] = true
								end
							end
						end)

						if not capture_success and config.debug_mode then
							vim.notify("Error iterating treesitter captures", vim.log.levels.DEBUG)
						end

						return vim.tbl_keys(identifiers)
					end
				end
			end
		end
	end

	-- Fallback to regex-based extraction with enhanced pattern matching
	---@type table<string, boolean>
	local identifiers = {}

	-- Determine actual range to analyze
	local actual_start = start_line
	local actual_end = math.min(end_line, #lines)

	for i = actual_start + 1, actual_end do
		local line = lines[i - actual_start]
		if not line or type(line) ~= "string" then
			goto continue_line
		end

		-- Find all identifiers in the line with better pattern matching
		-- Look for standalone identifiers and member expressions
		for identifier in line:gmatch("[%a_][%a%d_%.]*") do
			-- Split complex expressions like "obj.method" into parts
			local parts = {}
			for part in identifier:gmatch("([^%.]+)") do
				if not utils.is_keyword(part) then
					parts[#parts + 1] = part
				end
			end

			-- Add individual parts and the full identifier
			for _, part in ipairs(parts) do
				identifiers[part] = true
			end

			-- Also add the full identifier if it's not just a keyword
			if not utils.is_keyword(identifier) then
				identifiers[identifier] = true
			end
		end

		::continue_line::
	end

	-- Filter out common keywords and language constructs
	local result = {}
	for identifier, _ in pairs(identifiers) do
		local should_include = true

		-- Skip very short identifiers that are likely not meaningful variables
		if #identifier <= 1 then
			should_include = false
		end

		if should_include and not utils.is_keyword(identifier) then
			table.insert(result, identifier)
		end
	end

	return result
end

---Analyze function symbols with proper error handling and type safety
---@param bufnr number Buffer number to analyze
---@param pos table Position with line and character fields
---@param tree table Dependency tree object
---@param node_id string Node ID in dependency tree
---@param current_depth number Current recursion depth
---@param max_depth number Maximum recursion depth
---@return boolean Success status
function M.analyze_function_symbols(bufnr, pos, tree, node_id, current_depth, max_depth)
	-- Default values with validation
	current_depth = current_depth or 0

	-- Early termination check for depth
	if current_depth >= max_depth - 1 then
		if config.debug_mode then
			vim.notify("analyze_function_symbols: Max depth reached: " .. current_depth, vim.log.levels.DEBUG)
		end
		return false
	end

	-- Type validation with detailed error handling
	if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
		if config.debug_mode then
			vim.notify("analyze_function_symbols: Invalid buffer", vim.log.levels.DEBUG)
		end
		return false
	end

	if type(pos) ~= "table" or type(pos.line) ~= "number" or type(pos.character) ~= "number" then
		if config.debug_mode then
			vim.notify("analyze_function_symbols: Invalid position", vim.log.levels.DEBUG)
		end
		return false
	end

	if type(tree) ~= "table" or type(tree.nodes) ~= "table" then
		if config.debug_mode then
			vim.notify("analyze_function_symbols: Invalid tree structure", vim.log.levels.DEBUG)
		end
		return false
	end

	if type(node_id) ~= "string" or not tree.nodes[node_id] then
		if config.debug_mode then
			vim.notify(
				"analyze_function_symbols: Invalid node_id or node not found: " .. tostring(node_id),
				vim.log.levels.DEBUG
			)
		end
		return false
	end

	if type(max_depth) ~= "number" or max_depth < 1 then
		if config.debug_mode then
			vim.notify("analyze_function_symbols: Invalid max_depth", vim.log.levels.DEBUG)
		end
		max_depth = 3 -- Default reasonable depth
	end

	-- Get function bounds to focus our search
	local function_bounds = ts_utils.get_function_bounds(bufnr, pos)
	if not function_bounds or type(function_bounds) ~= "table" then
		if config.debug_mode then
			vim.notify("analyze_function_symbols: Could not determine function bounds", vim.log.levels.DEBUG)
		end
		return false
	end

	local start_line = function_bounds.start_line
	local end_line = function_bounds.end_line

	-- Get function content
	local file_path = vim.api.nvim_buf_get_name(bufnr)
	local lines_success, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, start_line, end_line, false)

	if not lines_success or not lines or #lines == 0 then
		if config.debug_mode then
			vim.notify("analyze_function_symbols: Failed to get function content", vim.log.levels.DEBUG)
		end
		return false
	end

	-- Extract all symbols using Treesitter with comprehensive error handling
	---@type table<string, boolean>
	local symbols = {}
	local treesitter_success = false

	if vim.treesitter then
		local parser_success, parser = pcall(vim.treesitter.get_parser, bufnr)

		if parser_success and parser then
			local tree_success, tree_obj = pcall(function()
				return parser:parse()[1]
			end)

			if tree_success and tree_obj then
				local root_success, root = pcall(function()
					return tree_obj:root()
				end)

				if root_success and root then
					-- Query for identifiers with comprehensive pattern
					local query_str = [[
                        (identifier) @id
                        (property_identifier) @prop
                    ]]

					local query_success, query = pcall(vim.treesitter.query.parse, parser:lang(), query_str)

					if query_success and query then
						treesitter_success = true

						-- Safety wrapper around treesitter operations
						pcall(function()
							for id, node in query:iter_captures(root, bufnr, start_line, end_line) do
								local symbol_success, symbol_name = pcall(function()
									return vim.treesitter.get_node_text(node, bufnr)
								end)

								if
									symbol_success
									and symbol_name
									and symbol_name ~= ""
									and not utils.is_keyword(symbol_name)
									and not utils.has_analyzed_symbol(symbol_name, file_path)
								then
									symbols[symbol_name] = true

									-- Mark this symbol as processed in this file
									utils.mark_symbol_analyzed(symbol_name, file_path)
								end
							end
						end)
					end
				end
			end
		end
	end

	-- Fallback to regex-based extraction if Treesitter failed
	if not treesitter_success then
		-- Process content line by line with regex patterns
		for _, line in ipairs(lines) do
			if type(line) == "string" then
				-- Find identifiers with word boundaries
				for identifier in line:gmatch("[%a_][%a%d_]*") do
					if not utils.is_keyword(identifier) and not utils.has_analyzed_symbol(identifier, file_path) then
						symbols[identifier] = true
						utils.mark_symbol_analyzed(identifier, file_path)
					end
				end
			end
		end
	end

	-- For each symbol, find its definition
	for symbol_name, _ in pairs(symbols) do
		-- Find definitions for this symbol with error handling
		local definitions = {}
		local def_success, def_result = pcall(function()
			return lsp.find_symbol_definitions(symbol_name)
		end)

		if def_success and def_result and type(def_result) == "table" then
			definitions = def_result
		end

		for _, def in ipairs(definitions) do
			if type(def) == "table" and def.uri and type(def.uri) == "string" and type(def.range) == "table" then
				local def_uri = def.uri
				local def_path = def_uri:gsub("file://", "")

				-- Skip if this is a recursive reference to the same file
				if def_path == file_path then
					goto continue_def
				end

				-- Skip excluded paths
				if utils.should_exclude(def_path) then
					goto continue_def
				end

				local buf_success, def_bufnr = pcall(vim.uri_to_bufnr, def_uri)
				if not buf_success or type(def_bufnr) ~= "number" then
					goto continue_def
				end

				local def_pos = lsp.lsp_to_buf_pos(def.range.start)
				if not def_pos or type(def_pos) ~= "table" then
					goto continue_def
				end

				-- Skip if we've already processed this definition
				local def_id = string.format("%s:%d:%d", def_path, def_pos.line, def_pos.character)
				if tree.nodes[def_id] then
					goto continue_def
				end

				-- Load the buffer if needed with error handling
				if not vim.api.nvim_buf_is_loaded(def_bufnr) then
					pcall(vim.fn.bufload, def_bufnr)
				end

				-- Add this definition with limited recursion and proper depth tracking
				if current_depth < max_depth - 1 then
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

					if not analyze_success and config.debug_mode then
						vim.notify("Failed to analyze definition for symbol: " .. symbol_name, vim.log.levels.DEBUG)
					end
				end

				-- Record variable usage with comprehensive data
				if tree.nodes[node_id] then
					local var_entry = {
						name = symbol_name,
						definition = {
							uri = def_uri,
							path = def_path,
							line = def_pos.line + 1,
							column = def_pos.character + 1,
							symbol_kind = def.kind or "unknown",
						},
					}

					-- Check for duplicates
					local is_duplicate = false
					for _, existing in ipairs(tree.nodes[node_id].variables_used) do
						if type(existing) == "table" and existing.name == symbol_name then
							is_duplicate = true
							break
						end
					end

					if not is_duplicate then
						table.insert(tree.nodes[node_id].variables_used, var_entry)
					end
				end

				::continue_def::
			end
		end
	end

	return true
end

---Analyze variable dependencies with comprehensive error handling
---@param bufnr number Buffer number to analyze
---@param pos table Position with line and character
---@param node_id string Node ID in the dependency tree
---@param tree table The dependency tree object
---@param max_depth number|nil Maximum recursion depth (optional)
---@param current_depth number|nil Current recursion depth (optional)
---@return boolean Success status
function M.analyze_variable_dependencies(bufnr, pos, node_id, tree, max_depth, current_depth)
	-- Default values with validation
	current_depth = current_depth or 0
	max_depth = max_depth or (tonumber(config.max_depth) or 3)

	-- Early termination for depth control
	if current_depth >= max_depth - 1 then
		if config.debug_mode then
			vim.notify("analyze_variable_dependencies: Max depth reached: " .. current_depth, vim.log.levels.DEBUG)
		end
		return false
	end

	-- Type validation with detailed error handling
	if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
		if config.debug_mode then
			vim.notify("analyze_variable_dependencies: Invalid buffer", vim.log.levels.DEBUG)
		end
		return false
	end

	if type(pos) ~= "table" or type(pos.line) ~= "number" or type(pos.character) ~= "number" then
		if config.debug_mode then
			vim.notify("analyze_variable_dependencies: Invalid position", vim.log.levels.DEBUG)
		end
		return false
	end

	if type(node_id) ~= "string" or node_id == "" then
		if config.debug_mode then
			vim.notify("analyze_variable_dependencies: Invalid node_id", vim.log.levels.DEBUG)
		end
		return false
	end

	if type(tree) ~= "table" or type(tree.nodes) ~= "table" then
		if config.debug_mode then
			vim.notify("analyze_variable_dependencies: Invalid tree", vim.log.levels.DEBUG)
		end
		return false
	end

	-- Verify the node exists in the tree
	if not tree.nodes[node_id] then
		if config.debug_mode then
			vim.notify("Node ID not found in tree: " .. node_id, vim.log.levels.DEBUG)
		end
		return false
	end

	-- Wrap each call in pcall for resilience against isolated failures
	local success1, err1 = pcall(function()
		M.analyze_function_symbols(bufnr, pos, tree, node_id, current_depth, max_depth)
	end)

	if not success1 and config.debug_mode then
		vim.notify("Error in analyze_function_symbols: " .. tostring(err1), vim.log.levels.DEBUG)
	end

	local function_utils = require("dependency-tree.analyzer.functions")
	local success2, err2 = pcall(function()
		function_utils.detect_function_calls(bufnr, pos, node_id, tree, max_depth, current_depth)
	end)

	if not success2 and config.debug_mode then
		vim.notify("Error in detect_function_calls: " .. tostring(err2), vim.log.levels.DEBUG)
	end

	-- Add language-specific analysis
	local filetype = ts_utils.get_filetype_safe(bufnr)
	if
		filetype == "typescript"
		or filetype == "typescriptreact"
		or filetype == "javascript"
		or filetype == "javascriptreact"
	then
		local languages = require("dependency-tree.languages")
		local success3, err3 = pcall(function()
			languages.typescript.process_imports(bufnr, pos, node_id, tree, max_depth, current_depth + 1)
		end)

		if not success3 and config.debug_mode then
			vim.notify("Error in process_typescript_imports: " .. tostring(err3), vim.log.levels.DEBUG)
		end
	elseif filetype == "python" then
		local languages = require("dependency-tree.languages")
		pcall(function()
			languages.python.process_imports(bufnr, pos, node_id, tree, max_depth, current_depth + 1)
		end)
	elseif filetype == "lua" then
		local languages = require("dependency-tree.languages")
		pcall(function()
			languages.lua.process_requires(bufnr, pos, node_id, tree, max_depth, current_depth + 1)
		end)
	end

	-- Track analysis success
	return success1 or success2 -- Return true if any analysis succeeded
end

return M
