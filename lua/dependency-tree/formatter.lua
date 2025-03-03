-----------------
-- formatter.lua
-----------------

local config = require("dependency-tree.config")
local utils = require("dependency-tree.utils")
local analyzer = require("dependency-tree.analyzer")

local M = {}

-- Format tree as text with improved formatting for root node and implementation
local function format_tree_text(tree, root_id)
	local lines = {}

	-- Helper to format paths to be shorter
	local function format_path(path)
		local short_path = path:match("([^/\\]+)$") or path
		return short_path
	end

	-- Function to add a dependency node to the output
	local function add_node(id, indent, visited)
		if not tree.nodes[id] then
			return
		end

		if visited[id] then
			table.insert(lines, indent .. "└─ " .. tree.nodes[id].symbol .. " (circular ref)")
			return
		end

		visited[id] = true
		local node = tree.nodes[id]
		local prefix = indent .. "└─ "

		-- Include file name and line number in a consistent format
		local node_text = string.format("%s%s (%s:%d)", prefix, node.symbol, format_path(node.file), node.line)
		table.insert(lines, node_text)

		-- Process children (callees) with increased indent
		local next_indent = indent .. "   "
		for _, child_id in ipairs(node.children) do
			add_node(child_id, next_indent, vim.deepcopy(visited))
		end
	end

	-- Add title
	local root = tree.nodes[root_id]
	if not root then
		table.insert(lines, "Error: Root node not found")
		return lines
	end

	table.insert(lines, "# Dependency Tree for: " .. root.symbol)
	table.insert(lines, "")

	-- Check if we have an implementation node and display it first
	if root.implementation_id and tree.nodes[root.implementation_id] then
		local impl_node = tree.nodes[root.implementation_id]
		table.insert(lines, "## Implementation found in: " .. impl_node.full_path)
		table.insert(lines, "")

		-- Add the actual source code
		table.insert(lines, "```")
		if impl_node.source_code and #impl_node.source_code > 0 then
			for _, line in ipairs(impl_node.source_code) do
				table.insert(lines, line)
			end
		else
			table.insert(lines, "// Implementation source code not available")
		end
		table.insert(lines, "```")
		table.insert(lines, "")

		-- Add internal variables section for implementation if available
		if config.display_options.show_internal_vars and impl_node.variables and next(impl_node.variables) then
			table.insert(lines, "### Internal Variables in Implementation:")

			-- Get sorted variable names for consistent display
			local var_names = {}
			for var_name, _ in pairs(impl_node.variables) do
				table.insert(var_names, var_name)
			end
			table.sort(var_names)

			for _, var_name in ipairs(var_names) do
				local var_info = impl_node.variables[var_name]
				table.insert(lines, "   └─ " .. var_name .. " (line " .. var_info.line .. ")")

				-- Add usage information
				if #var_info.used_by > 0 then
					for _, usage in ipairs(var_info.used_by) do
						table.insert(lines, "      └─ " .. usage.context .. " (line " .. usage.line .. ")")
					end
				end
			end
			table.insert(lines, "")
		end

		-- Add internal functions section for implementation if available
		if
			config.display_options.show_internal_vars
			and impl_node.internal_functions
			and next(impl_node.internal_functions)
		then
			table.insert(lines, "### Internal Functions in Implementation:")

			-- Get sorted function names for consistent display
			local func_names = {}
			for func_name, _ in pairs(impl_node.internal_functions) do
				table.insert(func_names, func_name)
			end
			table.sort(func_names)

			for _, func_name in ipairs(func_names) do
				local func_info = impl_node.internal_functions[func_name]
				table.insert(
					lines,
					"   └─ "
					.. func_name
					.. " ("
					.. (func_info.node_type or "function")
					.. " at line "
					.. func_info.line
					.. ")"
				)

				-- Add usage information
				if #func_info.used_by > 0 then
					for _, usage in ipairs(func_info.used_by) do
						table.insert(lines, "      └─ " .. usage.context .. " (line " .. usage.line .. ")")
					end
				end
			end
			table.insert(lines, "")
		end
	end

	-- Add usage information for the root node
	table.insert(lines, "## Usage in: " .. root.full_path)
	table.insert(lines, "")

	-- Add the actual source code
	table.insert(lines, "```")
	if root.source_code and #root.source_code > 0 then
		for _, line in ipairs(root.source_code) do
			table.insert(lines, line)
		end
	else
		local source_lines = analyzer.get_full_function_source(root)
		for _, line in ipairs(source_lines) do
			table.insert(lines, line)
		end
	end
	table.insert(lines, "```")
	table.insert(lines, "")

	-- Add internal variables section if available and configured
	if config.display_options.show_internal_vars and root.variables and next(root.variables) then
		table.insert(lines, "## Internal Variables:")

		-- Get sorted variable names for consistent display
		local var_names = {}
		for var_name, _ in pairs(root.variables) do
			table.insert(var_names, var_name)
		end
		table.sort(var_names)

		for _, var_name in ipairs(var_names) do
			local var_info = root.variables[var_name]
			table.insert(lines, "- " .. var_name .. " (Line " .. var_info.line .. ")")

			-- Add usage information
			if #var_info.used_by > 0 then
				for _, usage in ipairs(var_info.used_by) do
					table.insert(lines, "  - Usage: " .. usage.context .. " (Line " .. usage.line .. ")")
				end
			end
		end
		table.insert(lines, "")
	end

	-- Add internal functions section if available and configured
	if config.display_options.show_internal_vars and root.internal_functions and next(root.internal_functions) then
		table.insert(lines, "## Internal Functions:")

		-- Get sorted function names for consistent display
		local func_names = {}
		for func_name, _ in pairs(root.internal_functions) do
			table.insert(func_names, func_name)
		end
		table.sort(func_names)

		for _, func_name in ipairs(func_names) do
			local func_info = root.internal_functions[func_name]
			table.insert(
				lines,
				"- " .. func_name .. " (" .. (func_info.node_type or "function") .. " at line " .. func_info.line .. ")"
			)

			-- Add usage information
			if #func_info.used_by > 0 then
				for _, usage in ipairs(func_info.used_by) do
					table.insert(lines, "  - Usage: " .. usage.context .. " (Line " .. usage.line .. ")")
				end
			end
		end
		table.insert(lines, "")
	end

	return lines
end

-- Format tree text for display in UI
function M.format_tree_for_display(tree, root_id)
	return format_tree_text(tree, root_id)
end

-- Generate a folder tree representation from file paths
-- @param files table: List of file paths
-- @return table: Lines of folder tree representation
function M.generate_folder_tree(files)
	local lines = {}
	local tree = {}

	-- Build tree structure
	for _, file_path in ipairs(files) do
		local parts = {}
		for part in file_path:gmatch("[^/\\]+") do
			table.insert(parts, part)
		end

		local current = tree
		for i, part in ipairs(parts) do
			if i == #parts then
				-- This is a file
				if not current._files then
					current._files = {}
				end
				table.insert(current._files, part)
			else
				-- This is a directory
				if not current[part] then
					current[part] = {}
				end
				current = current[part]
			end
		end
	end

	-- Helper function to print tree
	local function print_tree(node, prefix, is_last)
		-- Print directories first, then files
		local dirs = {}
		local node_files = node._files or {}

		for dir, _ in pairs(node) do
			if dir ~= "_files" then
				table.insert(dirs, dir)
			end
		end
		table.sort(dirs)
		table.sort(node_files)

		-- Print directories
		for i, dir in ipairs(dirs) do
			local is_dir_last = (i == #dirs and #node_files == 0)
			if is_dir_last then
				table.insert(lines, prefix .. "└── " .. dir .. "/")
				print_tree(node[dir], prefix .. "    ", true)
			else
				table.insert(lines, prefix .. "├── " .. dir .. "/")
				print_tree(node[dir], prefix .. "│   ", false)
			end
		end

		-- Print files
		for i, file in ipairs(node_files) do
			local is_file_last = (i == #node_files)
			if is_file_last then
				table.insert(lines, prefix .. "└── " .. file)
			else
				table.insert(lines, prefix .. "├── " .. file)
			end
		end
	end

	-- Start printing from root
	table.insert(lines, "## Project Folder Structure")
	table.insert(lines, "```")
	print_tree(tree, "", true)
	table.insert(lines, "```")
	table.insert(lines, "")

	return lines
end

-- Generate detailed export content with standardized project structure
function M.generate_export_content(tree, root_id, show_project_structure)
	local lines = {}

	-- Add project structure if requested
	if show_project_structure then
		-- Collect unique file paths in the dependency tree
		local file_paths = {}
		for _, node in pairs(tree.nodes) do
			if node and node.full_path then
				file_paths[node.full_path] = true
			end
		end

		-- Get sorted list of files
		local project_files = {}
		for file_path, _ in pairs(file_paths) do
			table.insert(project_files, file_path)
		end
		table.sort(project_files)

		-- Generate folder tree
		local folder_tree_lines = M.generate_folder_tree(project_files)
		for _, line in ipairs(folder_tree_lines) do
			table.insert(lines, line)
		end

		table.insert(lines, "## Files in Dependency Tree:")
		for _, file_path in ipairs(project_files) do
			table.insert(lines, "- " .. file_path)
		end
		table.insert(lines, "")

		-- Format and add each file with its functions
		local already_processed = {}
		for _, file_path in ipairs(project_files) do
			-- Get all functions in this file
			local functions_in_file = {}
			for id, node in pairs(tree.nodes) do
				if node.full_path == file_path and not already_processed[node.symbol] then
					table.insert(functions_in_file, node)
					already_processed[node.symbol] = true
				end
			end

			if #functions_in_file > 0 then
				table.insert(lines, "## File: " .. file_path)
				table.insert(lines, "")

				-- Sort functions by line number
				table.sort(functions_in_file, function(a, b)
					return a.line < b.line
				end)

				-- Add each function with its source
				for _, node in ipairs(functions_in_file) do
					table.insert(lines, "### Function: " .. node.symbol)

					-- Add docblock comment if available
					if node.docblock and #node.docblock > 0 then
						table.insert(lines, "")
						table.insert(lines, "**Documentation:**")
						table.insert(lines, "```")
						for _, doc_line in ipairs(node.docblock) do
							table.insert(lines, doc_line)
						end
						table.insert(lines, "```")
					end

					-- Add function source code with syntax highlighting
					table.insert(lines, "")
					table.insert(lines, "**Source Code:**")
					table.insert(lines, "```" .. (vim.api.nvim_buf_get_option(0, "filetype") or ""))
					if node.source_code and #node.source_code > 0 then
						for _, source_line in ipairs(node.source_code) do
							table.insert(lines, source_line)
						end
					else
						local source = analyzer.get_full_function_source(node)
						for _, source_line in ipairs(source) do
							-- Remove line numbers from the source
							local clean_line = source_line:gsub("^ *%d+: ", "")
							table.insert(lines, clean_line)
						end
					end
					table.insert(lines, "```")

					-- Add relationship information
					if #node.children > 0 or #node.parents > 0 then
						table.insert(lines, "")
						table.insert(lines, "**Dependencies:**")

						if #node.children > 0 then
							table.insert(lines, "- **Calls:**")
							for _, child_id in ipairs(node.children) do
								if tree.nodes[child_id] then
									local child = tree.nodes[child_id]
									table.insert(
										lines,
										string.format("  - %s (%s:%d)", child.symbol, child.file, child.line)
									)
								end
							end
						end

						if #node.parents > 0 then
							table.insert(lines, "- **Called by:**")
							for _, parent_id in ipairs(node.parents) do
								if tree.nodes[parent_id] then
									local parent = tree.nodes[parent_id]
									table.insert(
										lines,
										string.format("  - %s (%s:%d)", parent.symbol, parent.file, parent.line)
									)
								end
							end
						end
					end

					-- Add variable usage information
					if #node.variables_used > 0 then
						table.insert(lines, "")
						table.insert(lines, "**Variables Used:**")
						for _, var in ipairs(node.variables_used) do
							table.insert(lines, string.format("- %s (line %d)", var.name, var.line or 0))
						end
					end

					table.insert(lines, "")
					table.insert(lines, "---")
					table.insert(lines, "")
				end
			end
		end

		-- Append the detailed dependency tree
		local tree_lines = format_tree_text(tree, root_id)
		table.insert(lines, "## Dependency Tree")
		table.insert(lines, "")
		for _, line in ipairs(tree_lines) do
			table.insert(lines, line)
		end
	else
		-- Just use the formatted tree text
		lines = format_tree_text(tree, root_id)
	end

	return table.concat(lines, "\n")
end

return M
