-----------------
-- analyzer/functions.lua
-----------------
--[[
    Function analysis utilities for dependency-tree.nvim

    This module is responsible for detecting and analyzing function calls,
    relationships, and implementations.
]]

local config = require("dependency-tree.config")
local utils = require("dependency-tree.utils")
local lsp = require("dependency-tree.lsp")
local ts_utils = require("dependency-tree.analyzer.treesitter")

local M = {}

-- Enhanced function to detect function calls with robust TypeScript/Async support
---@param bufnr number Buffer number to analyze
---@param pos table Position with line and character fields
---@param node_id string Node ID in the dependency tree
---@param tree table The dependency tree object
---@param max_depth number|nil Maximum recursion depth (optional)
---@param current_depth number|nil Current recursion depth (optional)
---@return table Table of detected function calls
function M.detect_function_calls(bufnr, pos, node_id, tree, max_depth, current_depth)
	-- Add current_depth parameter with default
	current_depth = current_depth or 0

	-- Early termination for depth control
	if current_depth >= max_depth - 1 then
		if config.debug_mode then
			vim.notify("Max depth reached in detect_function_calls: " .. current_depth, vim.log.levels.DEBUG)
		end
		return {}
	end

	-- Type validation with detailed error handling
	if type(bufnr) ~= "number" then
		if config.debug_mode then
			vim.notify("detect_function_calls: Expected number for bufnr, got " .. type(bufnr), vim.log.levels.DEBUG)
		end
		return {}
	end

	if not vim.api.nvim_buf_is_valid(bufnr) then
		if config.debug_mode then
			vim.notify("detect_function_calls: Invalid buffer: " .. tostring(bufnr), vim.log.levels.DEBUG)
		end
		return {}
	end

	if type(pos) ~= "table" or type(pos.line) ~= "number" or type(pos.character) ~= "number" then
		if config.debug_mode then
			vim.notify("detect_function_calls: Invalid position object", vim.log.levels.DEBUG)
		end
		return {}
	end

	if type(node_id) ~= "string" or node_id == "" then
		if config.debug_mode then
			vim.notify("detect_function_calls: Expected non-empty string for node_id", vim.log.levels.DEBUG)
		end
		return {}
	end

	if type(tree) ~= "table" or type(tree.nodes) ~= "table" then
		if config.debug_mode then
			vim.notify("detect_function_calls: Invalid tree object", vim.log.levels.DEBUG)
		end
		return {}
	end

	if not tree.nodes[node_id] then
		if config.debug_mode then
			vim.notify("detect_function_calls: Node ID not found in tree: " .. node_id, vim.log.levels.DEBUG)
		end
		return {}
	end

	-- Normalize max_depth with strong validation
	if max_depth ~= nil and type(max_depth) ~= "number" then
		if config.debug_mode then
			vim.notify(
				"detect_function_calls: Expected number for max_depth, got " .. type(max_depth),
				vim.log.levels.DEBUG
			)
		end
		max_depth = 3 -- Sensible default
	end

	max_depth = tonumber(max_depth) or 3
	max_depth = math.min(math.max(max_depth, 1), 10) -- Clamp between 1 and 10

	-- Initialize structured data for function calls
	---@type table<string, {name: string, type: string, line: number|nil, column: number|nil, discovered_by: string}>
	local function_calls = {}

	local file_path = vim.api.nvim_buf_get_name(bufnr)
	if file_path == "" then
		if config.debug_mode then
			vim.notify("detect_function_calls: Empty file path for buffer: " .. tostring(bufnr), vim.log.levels.DEBUG)
		end
		return {}
	end

	-- Get function bounds safely with validated result
	local bounds = ts_utils.get_function_bounds(bufnr, pos)
	if
		not bounds
		or type(bounds) ~= "table"
		or type(bounds.start_line) ~= "number"
		or type(bounds.end_line) ~= "number"
	then
		if config.debug_mode then
			vim.notify("detect_function_calls: Could not determine valid function bounds", vim.log.levels.DEBUG)
		end
		-- Fall back to a reasonable range with safe boundary checks
		bounds = {
			start_line = math.max(0, pos.line - 10),
			end_line = math.min(pos.line + 50, vim.api.nvim_buf_line_count(bufnr) - 1),
		}
	end

	-- Get the entire function text for comprehensive analysis
	local lines_success, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, bounds.start_line, bounds.end_line, false)
	if not lines_success or not lines or #lines == 0 then
		if config.debug_mode then
			vim.notify("detect_function_calls: Failed to get function content", vim.log.levels.DEBUG)
		end
		return {}
	end

	local function_text = table.concat(lines, "\n")

	-- Special handling for TypeScript async/await patterns
	local filetype = ts_utils.get_filetype_safe(bufnr)
	local is_typescript = filetype == "typescript"
		or filetype == "typescriptreact"
		or filetype == "javascript"
		or filetype == "javascriptreact"

	if is_typescript then
		-- Find await expressions with more robust pattern matching
		for await_expr in function_text:gmatch("await%s+([%w_%.]+)%s*%(") do
			if type(await_expr) == "string" and await_expr ~= "" and not utils.is_keyword(await_expr) then
				function_calls[await_expr] = {
					name = await_expr,
					type = "function_call",
					discovered_by = "ts_await_pattern",
				}
			end
		end

		-- Find try-catch blocks with await, handling nested structures
		for try_block in function_text:gmatch("try%s*{([^}]*)") do
			if type(try_block) == "string" then
				for await_expr in try_block:gmatch("await%s+([%w_%.]+)%s*%(") do
					if type(await_expr) == "string" and await_expr ~= "" and not utils.is_keyword(await_expr) then
						function_calls[await_expr] = {
							name = await_expr,
							type = "function_call",
							discovered_by = "ts_try_await_pattern",
						}
					end
				end
			end
		end

		-- Handle promise chaining (.then, .catch patterns)
		for chain_expr in function_text:gmatch("([%w_%.]+)%s*%.%s*then%s*%(") do
			if type(chain_expr) == "string" and chain_expr ~= "" and not utils.is_keyword(chain_expr) then
				function_calls[chain_expr] = {
					name = chain_expr,
					type = "function_call",
					discovered_by = "ts_promise_chain",
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
			"new%s+([%w_%.]+)%s*%(", -- Constructor calls: new Class()
			"import%(([%w_%.\"']+)%)", -- Dynamic imports: import("module")
			"require%(([%w_%.\"']+)%)", -- CommonJS require: require("module")
		}

		for _, pattern in ipairs(patterns) do
			for func_name in line:gmatch(pattern) do
				-- Clean up the function name by removing quotes for imports/requires
				func_name = func_name:gsub("[\"']", "")

				-- Skip language keywords and already processed names
				if not utils.is_keyword(func_name) and not function_calls[func_name] then
					function_calls[func_name] = {
						name = func_name,
						type = "function_call",
						line = bounds.start_line + i - 1,
						column = line:find(func_name, 1, true) or 0,
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

		-- Find function position in the buffer using a more reliable approach
		local func_pos = nil
		for line_num = bounds.start_line, bounds.end_line do
			local line_content_success, line_content =
				pcall(vim.api.nvim_buf_get_lines, bufnr, line_num, line_num + 1, false)

			if not line_content_success or not line_content or #line_content == 0 then
				goto continue_line_check
			end

			line_content = line_content[1]
			if type(line_content) ~= "string" then
				goto continue_line_check
			end

			-- Look for exact function name match with word boundaries
			local pattern = "%f[%w_]" .. vim.pesc(func_name) .. "%f[^%w_]"
			local start_idx = line_content:find(pattern)
			if start_idx then
				func_pos = { line = line_num, character = start_idx - 1 }
				-- Save position in the call_info for reference
				call_info.line = line_num
				call_info.column = start_idx - 1
				break
			end

			::continue_line_check::
		end

		if not func_pos then
			-- Fallback position with validation
			func_pos = {
				line = math.min(bounds.start_line, vim.api.nvim_buf_line_count(bufnr) - 1),
				character = 0,
			}
		end

		-- Create LSP parameters for definition lookup
		local params = {
			textDocument = { uri = vim.uri_from_bufnr(bufnr) },
			position = func_pos,
			context = { includeDeclaration = true },
		}

		-- Get definitions using LSP with comprehensive error handling
		local definitions = {}
		local lsp_success, lsp_result = pcall(function()
			return lsp.get_definitions(params)
		end)

		if lsp_success and lsp_result and type(lsp_result) == "table" then
			definitions = lsp_result
		elseif config.debug_mode then
			vim.notify("Failed to get definitions for function: " .. func_name, vim.log.levels.DEBUG)
		end

		-- Process each definition with type validation at every step
		for _, def in ipairs(definitions) do
			if not def or type(def) ~= "table" or not def.range or type(def.range) ~= "table" then
				goto continue_def
			end

			local def_uri = def.uri or def.targetUri
			if not def_uri or type(def_uri) ~= "string" then
				goto continue_def
			end

			local def_path = def_uri:gsub("file://", "")

			-- Handle relative paths for TypeScript with path normalization
			if def_path:match("^%.") then
				local current_dir = file_path:match("(.*)/[^/]*$") or "."
				local norm_success, normalized_path = pcall(vim.fn.fnamemodify, current_dir .. "/" .. def_path, ":p")
				if norm_success and type(normalized_path) == "string" and normalized_path ~= "" then
					def_path = normalized_path
				elseif config.debug_mode then
					vim.notify("Failed to normalize path: " .. def_path, vim.log.levels.DEBUG)
				end
				goto continue_def
			end

			-- Skip excluded paths
			if utils.should_exclude(def_path) then
				goto continue_def
			end

			-- Get buffer for definition with error handling
			local def_bufnr
			local buf_success, buf_result = pcall(function()
				return vim.uri_to_bufnr(def_uri)
			end)

			if not buf_success or not buf_result or type(buf_result) ~= "number" then
				if config.debug_mode then
					vim.notify("Failed to get buffer for URI: " .. def_uri, vim.log.levels.DEBUG)
				end
				goto continue_def
			end

			def_bufnr = buf_result

			-- Get position for definition
			local def_pos = lsp.lsp_to_buf_pos(def.range.start)
			if
				not def_pos
				or type(def_pos) ~= "table"
				or type(def_pos.line) ~= "number"
				or type(def_pos.character) ~= "number"
			then
				if config.debug_mode then
					vim.notify("Invalid position from LSP definition", vim.log.levels.DEBUG)
				end
				goto continue_def
			end

			local def_id = string.format("%s:%d:%d", def_path, def_pos.line, def_pos.character)

			-- Connect nodes if we already have this definition
			if tree.nodes[def_id] then
				-- Add bidirectional relationship with duplicate check
				if not vim.tbl_contains(tree.nodes[node_id].children, def_id) then
					table.insert(tree.nodes[node_id].children, def_id)
				end

				if not vim.tbl_contains(tree.nodes[def_id].parents, node_id) then
					table.insert(tree.nodes[def_id].parents, node_id)
				end
			else
				-- Recursively analyze this function definition if we haven't reached max depth
				if current_depth < max_depth - 1 then
					local analyze_success, analyze_err = pcall(function()
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
						vim.notify(
							"Failed recursive analysis of " .. func_name .. ": " .. tostring(analyze_err),
							vim.log.levels.DEBUG
						)
					end
				end
			end

			-- Record function call in variables_used with comprehensive data
			local var_entry = {
				name = func_name,
				is_function_call = true,
				definition = {
					uri = def_uri,
					path = def_path,
					line = def_pos.line + 1,
					column = def_pos.character + 1,
				},
				call_location = {
					line = call_info.line or 0,
					column = call_info.column or 0,
				},
			}

			-- Check for duplicates with proper type validation
			local duplicate = false
			for _, entry in ipairs(tree.nodes[node_id].variables_used) do
				if type(entry) == "table" and entry.name == func_name and entry.is_function_call == true then
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

---@param bufnr number Buffer number containing the function
---@param pos table Position {line, character} of the function
---@param symbol_name string Name of the function or symbol
---@return table|nil Implementation information or nil if not found
function M.find_implementation(bufnr, pos, symbol_name)
	-- Validate inputs
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		if config.debug_mode then
			vim.notify("find_implementation: Invalid buffer", vim.log.levels.DEBUG)
		end
		return nil
	end

	if not pos or type(pos) ~= "table" or type(pos.line) ~= "number" or type(pos.character) ~= "number" then
		if config.debug_mode then
			vim.notify("find_implementation: Invalid position", vim.log.levels.DEBUG)
		end
		return nil
	end

	if not symbol_name or type(symbol_name) ~= "string" or symbol_name == "" then
		if config.debug_mode then
			vim.notify("find_implementation: Invalid symbol name", vim.log.levels.DEBUG)
		end
		return nil
	end

	-- Try using LSP implementation finder with error handling
	local params = {
		textDocument = { uri = vim.uri_from_bufnr(bufnr) },
		position = {
			line = pos.line,
			character = pos.character,
		},
	}

	local implementation = nil

	-- Try textDocument/implementation request
	local impl_success, impl_result = pcall(function()
		return vim.lsp.buf_request_sync(bufnr, "textDocument/implementation", params, 1000)
	end)

	if impl_success and impl_result then
		for _, res in pairs(impl_result) do
			if res.result and #res.result > 0 then
				implementation = {
					uri = res.result[1].uri,
					range = res.result[1].range,
				}
				break
			end
		end
	end

	-- If no implementation found, try workspace/symbol as fallback
	if not implementation then
		local ws_params = { query = symbol_name }

		local ws_success, ws_result = pcall(function()
			return vim.lsp.buf_request_sync(bufnr, "workspace/symbol", ws_params, 2000)
		end)

		if ws_success and ws_result then
			for _, res in pairs(ws_result) do
				if res.result then
					for _, symbol in ipairs(res.result) do
						-- Look for exact matches or implementations
						if symbol.name == symbol_name and symbol.kind == 4 then -- SymbolKind.Function
							implementation = {
								uri = symbol.location.uri,
								range = symbol.location.range,
							}
							break
						end
					end
				end
			end
		end
	end

	return implementation
end

return M
