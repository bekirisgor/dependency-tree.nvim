local config = require("dependency-tree.config")
local utils = require("dependency-tree.utils")
local lsp = require("dependency-tree.lsp")
local languages = require("dependency-tree.languages")

-- Fix circular dependency issue by using pcall to safely require modules
local tree_utils, ts_utils, function_utils, variable_utils

local success1, result1 = pcall(require, "dependency-tree.analyzer.tree")
tree_utils = success1 and result1 or {}

local success2, result2 = pcall(require, "dependency-tree.analyzer.treesitter")
ts_utils = success2 and result2 or {}

local success3, result3 = pcall(require, "dependency-tree.analyzer.functions")
function_utils = success3 and result3 or {}

local success4, result4 = pcall(require, "dependency-tree.analyzer.variables")
variable_utils = success4 and result4 or {}

local M = {}

-- Re-export key functions from submodules for backward compatibility
M.create_node = tree_utils.create_node
M.get_function_bounds = ts_utils.get_function_bounds
M.extract_function_source = ts_utils.extract_function_source
M.extract_function_docblock = ts_utils.extract_function_docblock
M.diagnose_treesitter = ts_utils.diagnose_treesitter
M.setup_treesitter = ts_utils.setup_treesitter
M.detect_function_calls = function_utils.detect_function_calls
M.find_variable_references = variable_utils.find_variable_references
M.analyze_variable_dependencies = variable_utils.analyze_variable_dependencies
M.analyze_function_symbols = variable_utils.analyze_function_symbols

-- Core building function for the dependency tree
-- @param bufnr number: Buffer number to analyze
-- @param pos table: Position {line, character} to start analysis
-- @param depth number: Current depth in recursion
-- @param max_depth number: Maximum recursion depth
-- @param direction string: Direction to analyze ("up", "down", "both", or "none")
-- @param tree table: The dependency tree being built
-- @param parent_id string|nil: ID of the parent node, if any
function M.build_dependency_tree(bufnr, pos, depth, max_depth, direction, tree, parent_id)
	-- Strictly enforce max depth limit
	if depth >= max_depth then
		if config.debug_mode then
			vim.notify("Max depth reached: " .. depth .. "/" .. max_depth, vim.log.levels.DEBUG)
		end
		return
	end

	-- Type checking and validation
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		if config.debug_mode then
			vim.notify("Invalid buffer in build_dependency_tree", vim.log.levels.DEBUG)
		end
		return
	end

	if not pos or type(pos) ~= "table" or not pos.line or not pos.character then
		if config.debug_mode then
			vim.notify("Invalid position in build_dependency_tree", vim.log.levels.DEBUG)
		end
		return
	end

	-- Get file path and check if it's valid
	local file_path = vim.api.nvim_buf_get_name(bufnr)
	if not file_path or file_path == "" then
		if config.debug_mode then
			vim.notify("Empty file path in build_dependency_tree", vim.log.levels.DEBUG)
		end
		return
	end

	-- Get filetype and check if it's supported
	local filetype
	if ts_utils.get_filetype_safe then
		filetype = ts_utils.get_filetype_safe(bufnr)
	else
		-- Fallback method if function not available
		local success, result = pcall(vim.api.nvim_buf_get_option, bufnr, "filetype")
		filetype = success and result or ""
	end

	if not languages.is_supported(filetype) then
		if config.debug_mode then
			vim.notify("Unsupported filetype in build_dependency_tree: " .. tostring(filetype), vim.log.levels.DEBUG)
		end
		return
	end

	-- Create LSP parameters for queries
	local params = {
		textDocument = { uri = vim.uri_from_bufnr(bufnr) },
		position = {
			line = pos.line,
			character = pos.character,
		},
		context = { includeDeclaration = true },
	}

	-- Get symbol information at cursor position
	local symbol = nil
	if depth == 0 then
		-- For root node, try to get more accurate symbol information
		symbol = lsp.get_symbol_info_at_cursor() or lsp.get_symbol_at_pos(bufnr, pos)
	else
		-- For non-root nodes, use standard method
		symbol = lsp.get_symbol_at_pos(bufnr, pos)
	end

	if not symbol then
		if config.debug_mode then
			vim.notify("No symbol found at position in build_dependency_tree", vim.log.levels.DEBUG)
		end
		return
	end

	-- Check if we've already analyzed this symbol in this file to prevent cycles
	if utils.has_analyzed_symbol(symbol, file_path) and depth > 0 then
		return
	end

	-- Mark this symbol as analyzed in this file
	utils.mark_symbol_analyzed(symbol, file_path)

	-- Create a unique node ID
	local node_id = string.format("%s:%d:%d", file_path, pos.line, pos.character)

	-- Check cache to avoid circular references with enhanced depth tracking
	local cache_key = node_id .. direction .. ":" .. depth
	if utils.processed_cache[cache_key] then
		return
	end
	utils.processed_cache[cache_key] = true

	-- Create or update the node in the tree
	if not tree.nodes[node_id] then
		tree.nodes[node_id] = M.create_node(bufnr, pos, symbol, file_path, depth == 0)
	end

	-- Connect with parent if provided
	if parent_id and parent_id ~= node_id then
		M.connect_nodes(tree, node_id, parent_id, direction)
	end

	-- Process references (callers) - upward direction
	if direction == "up" or direction == "both" then
		M.process_references(bufnr, params, node_id, tree, depth, max_depth)
	end

	-- Process definitions (callees) - downward direction
	if direction == "down" or direction == "both" then
		M.process_definitions(bufnr, pos, params, node_id, tree, depth, max_depth, file_path, symbol, filetype)
	end

	-- Analyze variables and function calls for more comprehensive understanding
	if depth == 0 or (tree.nodes[node_id] and direction == "down") then
		-- Detect function calls with proper error handling
		if function_utils.detect_function_calls then
			local success, err = pcall(function()
				function_utils.detect_function_calls(bufnr, pos, node_id, tree, max_depth, depth)
			end)

			if not success and config.debug_mode then
				vim.notify("Error in detect_function_calls: " .. tostring(err), vim.log.levels.DEBUG)
			end
		end

		-- Find and analyze variable references with proper error handling
		if variable_utils.analyze_variable_dependencies then
			local var_success, var_err = pcall(function()
				variable_utils.analyze_variable_dependencies(bufnr, pos, node_id, tree, max_depth, depth)
			end)

			if not var_success and config.debug_mode then
				vim.notify("Error in analyze_variable_dependencies: " .. tostring(var_err), vim.log.levels.DEBUG)
			end
		end
	end
end

-- Process LSP references (callers of the current symbol)
function M.process_references(bufnr, params, node_id, tree, depth, max_depth)
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

	-- Special handling for React components if applicable
	if tree.nodes[node_id].is_react_component and config.react and config.react.enabled then
		local typescript = require("dependency-tree.languages.typescript")
		if typescript.find_component_imports then
			typescript.find_component_imports(bufnr, tree.nodes[node_id].symbol, tree, node_id, max_depth, depth + 1)
		end
	end
end

-- Process LSP definitions (what the current symbol depends on)
function M.process_definitions(bufnr, pos, params, node_id, tree, depth, max_depth, file_path, symbol, filetype)
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

	-- Language-specific handling
	if
		filetype == "typescript"
		or filetype == "typescriptreact"
		or filetype == "javascript"
		or filetype == "javascriptreact"
	then
		-- Handle TypeScript/JavaScript specific functionality
		local typescript = require("dependency-tree.languages.typescript")

		if
			tree.nodes[node_id].is_react_component
			and config.react
			and config.react.enabled
			and typescript.find_used_components
		then
			typescript.find_used_components(bufnr, pos, tree, node_id, max_depth, symbol, depth + 1)
		end

		-- Process imports for better dependency tracking
		if typescript.process_imports then
			typescript.process_imports(bufnr, pos, node_id, tree, max_depth, depth + 1)
		end
	elseif filetype == "python" then
		-- Python-specific functionality
		local python = require("dependency-tree.languages.python")
		if python.process_imports then
			python.process_imports(bufnr, pos, node_id, tree, max_depth, depth + 1)
		end
	elseif filetype == "lua" then
		-- Lua-specific functionality
		local lua = require("dependency-tree.languages.lua")
		if lua.process_requires then
			lua.process_requires(bufnr, pos, node_id, tree, max_depth, depth + 1)
		end
	elseif filetype == "go" then
		-- Go-specific functionality
		local go = require("dependency-tree.languages.go")
		if go.process_imports then
			go.process_imports(bufnr, pos, node_id, tree, max_depth, depth + 1)
		end
	elseif filetype == "rust" then
		-- Rust-specific functionality
		local rust = require("dependency-tree.languages.rust")
		if rust.process_imports then
			rust.process_imports(bufnr, pos, node_id, tree, max_depth, depth + 1)
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

		-- Look for potential implementation based on language patterns
		local filetype = vim.filetype.match({ filename = file_path }) or ""
		local impl_info = languages.find_implementation(filetype, file_path, root_node.symbol, lines)

		if impl_info then
			-- Found a potential implementation
			local bufnr = vim.uri_to_bufnr("file://" .. file_path)
			local pos = { line = impl_info.line - 1, character = impl_info.column - 1 }
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
					if variable_utils.analyze_variable_dependencies then
						variable_utils.analyze_variable_dependencies(bufnr, pos, impl_id, tree, 1, 0)
					end
					return
				end
			end

			-- If we found an implementation, no need to check more files
			return
		end

		::continue_file::
	end
end

M.create_node = function(bufnr, pos, symbol, file_path, is_root)
	return tree_utils.create_node(bufnr, pos, symbol, file_path, is_root)
end
return M
