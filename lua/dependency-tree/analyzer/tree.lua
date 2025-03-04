-----------------
-- analyzer/tree.lua
-----------------
--[[
    Tree building and manipulation utilities for dependency-tree.nvim

    This module handles the creation and manipulation of the dependency tree structure.
]]

local ts_utils = require("dependency-tree.analyzer.treesitter")

local M = {}

-- Create a new node for the dependency tree
-- @param bufnr number: Buffer number
-- @param pos table: Position {line, character}
-- @param symbol string: Symbol name
-- @param file_path string: Full file path
-- @param is_root boolean: Whether this is the root node
-- @return table: The created node
function M.create_node(bufnr, pos, symbol, file_path, is_root)
	-- Validate parameters
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		vim.notify("Invalid buffer in create_node", vim.log.levels.ERROR)
		return nil
	end

	if not pos or type(pos) ~= "table" or not pos.line or not pos.character then
		vim.notify("Invalid position in create_node", vim.log.levels.ERROR)
		return nil
	end

	if not symbol or type(symbol) ~= "string" then
		vim.notify("Invalid symbol in create_node", vim.log.levels.ERROR)
		return nil
	end

	if not file_path or type(file_path) ~= "string" then
		vim.notify("Invalid file_path in create_node", vim.log.levels.ERROR)
		return nil
	end

	local short_path = file_path:match("([^/]+)$") or file_path
	local node_id = string.format("%s:%d:%d", file_path, pos.line, pos.character)

	-- Check if this is a React component
	local is_react_component = M.is_react_component(bufnr, pos, symbol)
	local component_props = {}
	if is_react_component then
		component_props = M.extract_component_props(bufnr, pos, symbol)
	end

	-- Create the node with all required properties
	return {
		id = node_id,
		symbol = symbol,
		file = short_path,
		line = pos.line + 1,
		column = pos.character + 1,
		full_path = file_path,
		children = {},
		parents = {},
		variables_used = {},
		is_root = is_root or false,
		is_implementation = false,
		source_code = ts_utils.extract_function_source(bufnr, pos),
		docblock = ts_utils.extract_function_docblock(bufnr, pos),
		is_react_component = is_react_component,
		component_props = component_props,
	}
end

-- Connect two nodes in the dependency tree
-- @param tree table: The dependency tree
-- @param node_id string: ID of the node to connect
-- @param other_id string: ID of the other node to connect
-- @param direction string: "up" for caller, "down" for callee, "both" for bidirectional
function M.connect_nodes(tree, node_id, other_id, direction)
	if not tree or not tree.nodes then
		vim.notify("Invalid tree in connect_nodes", vim.log.levels.ERROR)
		return
	end

	if not tree.nodes[node_id] then
		vim.notify("Node " .. node_id .. " not found in tree", vim.log.levels.ERROR)
		return
	end

	if not tree.nodes[other_id] then
		vim.notify("Node " .. other_id .. " not found in tree", vim.log.levels.ERROR)
		return
	end

	-- Connect based on direction
	if direction == "up" then
		-- node is used by other (node is callee, other is caller)
		if not vim.tbl_contains(tree.nodes[node_id].children, other_id) then
			table.insert(tree.nodes[node_id].children, other_id)
		end
		if not vim.tbl_contains(tree.nodes[other_id].parents, node_id) then
			table.insert(tree.nodes[other_id].parents, node_id)
		end
	elseif direction == "down" or direction == "both" then
		-- node uses other (node is caller, other is callee)
		if not vim.tbl_contains(tree.nodes[node_id].parents, other_id) then
			table.insert(tree.nodes[node_id].parents, other_id)
		end
		if not vim.tbl_contains(tree.nodes[other_id].children, node_id) then
			table.insert(tree.nodes[other_id].children, node_id)
		end
	end
end

-- Add a reference to the tree (node is referred to by ref_node)
-- @param tree table: The dependency tree
-- @param node_id string: ID of the node being referenced
-- @param ref_id string: ID of the referencing node
function M.add_reference(tree, node_id, ref_id)
	if not tree.nodes[node_id] or not tree.nodes[ref_id] then
		return
	end

	-- Add bidirectional connection
	if not vim.tbl_contains(tree.nodes[node_id].parents, ref_id) then
		table.insert(tree.nodes[node_id].parents, ref_id)
	end

	if not vim.tbl_contains(tree.nodes[ref_id].children, node_id) then
		table.insert(tree.nodes[ref_id].children, node_id)
	end
end

-- Add a dependency to the tree (node depends on dep_node)
-- @param tree table: The dependency tree
-- @param node_id string: ID of the dependent node
-- @param dep_id string: ID of the dependency node
function M.add_dependency(tree, node_id, dep_id)
	if not tree.nodes[node_id] or not tree.nodes[dep_id] then
		return
	end

	-- Add bidirectional connection
	if not vim.tbl_contains(tree.nodes[node_id].children, dep_id) then
		table.insert(tree.nodes[node_id].children, dep_id)
	end

	if not vim.tbl_contains(tree.nodes[dep_id].parents, node_id) then
		table.insert(tree.nodes[dep_id].parents, node_id)
	end
end

-- Check if a node is a React component
-- @param bufnr number: Buffer number
-- @param pos table: Position {line, character}
-- @param symbol_name string: Symbol name
-- @return boolean: Whether this is a React component
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
	local utils = require("dependency-tree.utils")
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
-- @param bufnr number: Buffer number
-- @param pos table: Position {line, character}
-- @param symbol_name string: Symbol name
-- @return table: Extracted props
function M.extract_component_props(bufnr, pos, symbol_name)
	local utils = require("dependency-tree.utils")
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

return M
