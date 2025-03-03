-----------------
-- analyzer.lua
-----------------

local config = require("dependency-tree.config")
local lsp = require("dependency-tree.lsp")
local utils = require("dependency-tree.utils")

local M = {}

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

	-- Get filetype
	local filetype = vim.api.nvim_buf_get_option(bufnr, "filetype")
	if not filetype or filetype == "" then
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
			local def_id = string.format("%s:%d:%d", def_uri:gsub("file://", ""), def_pos.line, def_pos.character)

			if def_id ~= node_id then
				M.build_dependency_tree(def_bufnr, def_pos, depth + 1, max_depth, "down", tree, node_id)
			end

			::continue_def::
		end

		-- Special handling for React components - find components used by this component
		if tree.nodes[node_id].is_react_component and config.react and config.react.enabled then
			M.find_used_components(bufnr, pos, tree, node_id, max_depth, symbol)
		end
	end

	-- Find and process variable references and function calls (for functions only)
	if depth == 0 or (tree.nodes[node_id] and direction == "down") then
		-- This is a root node or we're analyzing downward dependencies

		-- First detect direct function calls using specialized detection
		if tree.nodes[node_id] then
			-- Enhanced detection of function calls with explicit types
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

-- Get source code snippets for a node with context
function M.get_node_snippets(node, context_lines)
	context_lines = context_lines or config.display_options.context_lines
	local file_path = node.full_path
	local line_num = node.line

	local lines = utils.read_file_contents(file_path)
	if not lines then
		return {}
	end

	local line_count = #lines

	local start_line = math.max(1, line_num - context_lines)
	local end_line = math.min(line_count, line_num + context_lines)

	local result = {}
	for i = start_line, end_line do
		local prefix = i == line_num and ">" or " "
		table.insert(result, string.format("%s %4d: %s", prefix, i, lines[i] or ""))
	end

	return result
end

-- Get entire function source code for a node
function M.get_full_function_source(node)
	local file_path = node.full_path
	local line_num = node.line
	local bufnr = vim.uri_to_bufnr("file://" .. file_path)

	local lines = utils.read_file_contents(file_path)
	if not lines then
		return {}
	end

	-- Try to find function boundaries using treesitter if available
	local start_line = math.max(1, line_num - 10)
	local end_line = math.min(line_num + 50, #lines)

	if vim.treesitter then
		local has_parser, parser = pcall(vim.treesitter.get_parser, bufnr)
		if has_parser and parser then
			local ts_tree = parser:parse()[1]
			if ts_tree then
				local root = ts_tree:root()
				if root then
					-- Find the closest function node containing the cursor position
					local function_node = nil
					local cursor_pos = { line = line_num - 1, character = 0 }
					local cursor_node = root:named_descendant_for_range(
						cursor_pos.line,
						cursor_pos.character,
						cursor_pos.line,
						cursor_pos.character
					)

					-- Navigate up to find the enclosing function
					while cursor_node do
						local node_type = cursor_node:type()
						if
							node_type == "function_declaration"
							or node_type == "method_definition"
							or node_type == "arrow_function"
							or node_type == "function"
							or node_type:match("function")
							or node_type:match("method")
						then
							function_node = cursor_node
							break
						end
						cursor_node = cursor_node:parent()
					end

					if function_node then
						local s_row, _, e_row, _ = function_node:range()
						start_line = s_row + 1
						end_line = e_row + 1 -- Inclusive
					end
				end
			end
		end
	end

	-- Fallback to basic brace matching if treesitter didn't help
	if start_line >= line_num then
		-- Search backward to find a reasonable starting point
		start_line = math.max(1, line_num - 10)

		local brace_count = 0
		local found_opening = false

		-- Scan forward to find opening brace
		for i = start_line, #lines do
			if lines[i]:match("{") then
				found_opening = true
				brace_count = brace_count + 1
			end

			if found_opening and lines[i]:match("}") then
				brace_count = brace_count - 1
				if brace_count == 0 then
					end_line = i
					break
				end
			end
		end
	end

	-- Get the source lines
	local result = {}
	for i = start_line, end_line do
		if lines[i - 1] then -- Adjust for 0-based indexing
			table.insert(result, string.format("%4d: %s", i, lines[i - 1]))
		end
	end

	return result
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

-- Get function bounds using Treesitter
function M.get_function_bounds(bufnr, pos)
	if not vim.treesitter then
		return nil
	end

	local parser = vim.treesitter.get_parser(bufnr)
	if not parser then
		return nil
	end

	local ts_tree = parser:parse()[1]
	if not ts_tree or not ts_tree:root() then
		return nil
	end

	local root = ts_tree:root()

	-- Find the function node containing the position
	local cursor_node = root:named_descendant_for_range(pos.line, pos.character, pos.line, pos.character)
	if not cursor_node then
		return nil
	end

	-- Search upward for a function node
	local function_node = cursor_node
	while function_node do
		local node_type = function_node:type()
		if
			node_type:match("function")
			or node_type:match("method")
			or node_type == "arrow_function"
			or node_type == "class_declaration"
		then
			break
		end
		function_node = function_node:parent()
	end

	if not function_node then
		return nil
	end

	-- Get the function bounds
	local start_row, _, end_row, _ = function_node:range()
	return {
		start_line = start_row,
		end_line = end_row + 1,
	}
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

--- Specialized function to detect function calls with strong type safety.
--- Identifies all function calls within a given code block and adds them to the dependency tree.
---
--- @param bufnr number The buffer number to analyze
--- @param pos table Position table with {line, character} fields
--- @param node_id string ID of the current node in the dependency tree
--- @param tree table The dependency tree object with a nodes field
--- @param max_depth number Maximum recursion depth for analyzing found function calls
--- @return table Table of detected function calls
function M.detect_function_calls(bufnr, pos, node_id, tree, max_depth)
	-- Type validation with detailed error handling
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

	-- Normalize and validate max_depth
	max_depth = tonumber(max_depth) or 3
	max_depth = math.min(math.max(max_depth, 1), 10) -- Clamp between 1 and 10

	local function_calls = {}
	local file_path = vim.api.nvim_buf_get_name(bufnr)

	-- Get function bounds to limit our search area
	local bounds = M.get_function_bounds(bufnr, pos)
	if not bounds then
		vim.notify("detect_function_calls: Could not determine function bounds", vim.log.levels.WARN)
		-- Fall back to a reasonable range around the cursor position
		bounds = {
			start_line = math.max(0, pos.line - 10),
			end_line = pos.line + 50,
		}
	end

	-- Check if we have access to treesitter for precise function call detection
	local has_treesitter = (vim.treesitter ~= nil)

	if has_treesitter then
		local success, result = pcall(function()
			local parser = vim.treesitter.get_parser(bufnr)
			if not parser then
				return false
			end

			local syntax_tree = parser:parse()[1]
			if not syntax_tree or not syntax_tree:root() then
				return false
			end

			local root = syntax_tree:root()

			-- Query for function calls - covers standard function calls and method calls
			local call_query_str = [[
                (call_expression
                    function: (identifier) @func_name)

                (call_expression
                    function: (member_expression
                        property: (property_identifier) @method_name))
            ]]

			local query = vim.treesitter.query.parse(parser:lang(), call_query_str)
			if not query then
				return false
			end

			-- Iterate through matches and extract function names
			for id, node in query:iter_captures(root, bufnr, bounds.start_line, bounds.end_line) do
				local func_name = vim.treesitter.get_node_text(node, bufnr)
				if func_name and func_name ~= "" and not function_calls[func_name] then
					function_calls[func_name] = {
						name = func_name,
						type = "function_call",
						node_type = node:type(),
						discovered_by = "treesitter",
					}
				end
			end

			return true
		end)

		if not success then
			vim.notify("detect_function_calls: Treesitter analysis failed, falling back to regex", vim.log.levels.DEBUG)
		end
	end

	-- Fallback to regex-based detection when Treesitter fails or is unavailable
	if vim.tbl_isempty(function_calls) then
		local lines = vim.api.nvim_buf_get_lines(bufnr, bounds.start_line, bounds.end_line, false)
		for i, line in ipairs(lines) do
			if type(line) ~= "string" then
				goto continue_line
			end

			-- Patterns to match various function call forms
			local patterns = {
				"([%w_]+)%s*%(",    -- Basic function calls: foo()
				"([%w_%.]+)%s*%(",  -- Method calls or namespaced: obj.method() or ns.func()
				"([%w_]+)%s*:%s*([%w_]+)%s*%(", -- Lua method calls: obj:method()
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
	end

	-- Process each detected function call to find its definition
	for func_name, call_info in pairs(function_calls) do
		-- Skip processing if the name is invalid
		if type(func_name) ~= "string" or func_name == "" then
			goto continue_func
		end

		-- Helper to find position of the function identifier in the buffer
		local function find_function_pos()
			for line_num = bounds.start_line, bounds.end_line do
				-- Get single line using slice with nvim_buf_get_lines
				local lines = vim.api.nvim_buf_get_lines(bufnr, line_num, line_num + 1, false)
				if not lines or #lines == 0 then
					goto continue_line_check
				end

				local line = lines[1]
				if type(line) ~= "string" then
					goto continue_line_check
				end

				local pattern = "%f[%w_]" .. func_name .. "%f[^%w_]" -- Use Lua word boundaries for exact matches
				local start_idx = line:find(pattern)
				if start_idx then
					return { line = line_num, character = start_idx - 1 }
				end

				::continue_line_check::
			end
			return nil
		end

		-- Attempt to find the function in the buffer
		local func_pos = find_function_pos()
		if not func_pos then
			-- Log that we couldn't find the position but don't abort
			func_pos = { line = bounds.start_line, character = 0 } -- Fallback position
		end

		-- Create LSP parameters for definition lookup
		local params = {
			textDocument = { uri = vim.uri_from_bufnr(bufnr) },
			position = func_pos,
			context = { includeDeclaration = true },
		}

		-- Try to get definitions using LSP
		local definitions = {}
		local lsp_success, lsp_result = pcall(function()
			return lsp.get_definitions(params)
		end)

		if lsp_success and lsp_result then
			definitions = lsp_result
		end

		-- Process each definition found
		for _, def in ipairs(definitions) do
			if not def or not def.range then
				goto continue_def
			end

			local def_uri = def.uri or def.targetUri
			if not def_uri then
				goto continue_def
			end

			local def_path = def_uri:gsub("file://", "")

			-- Skip excluded paths like node_modules
			if utils.should_exclude(def_path) then
				goto continue_def
			end

			local def_bufnr
			local buf_success, buf_result = pcall(function()
				return vim.uri_to_bufnr(def_uri)
			end)

			if not buf_success or not buf_result then
				goto continue_def
			end
			def_bufnr = buf_result

			local def_pos = lsp.lsp_to_buf_pos(def.range.start)
			if not def_pos then
				goto continue_def
			end

			local def_id = string.format("%s:%d:%d", def_path, def_pos.line, def_pos.character)

			-- If we already have this node, just add the relationship
			if tree.nodes[def_id] then
				-- Add bidirectional relationship
				if not vim.tbl_contains(tree.nodes[node_id].children, def_id) then
					table.insert(tree.nodes[node_id].children, def_id)
				end

				if not vim.tbl_contains(tree.nodes[def_id].parents, node_id) then
					table.insert(tree.nodes[def_id].parents, node_id)
				end
			else
				-- Otherwise recursively analyze this function definition
				-- Make sure we don't exceed max_depth
				if max_depth > 1 then
					local rec_success, _ = pcall(function()
						M.build_dependency_tree(def_bufnr, def_pos, 1, max_depth - 1, "down", tree, node_id)
					end)

					if not rec_success then
						vim.notify("Failed to recursively analyze: " .. func_name, vim.log.levels.DEBUG)
					end
				end
			end

			-- Record this function call in variables_used for completeness
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

			-- Check if we already have this entry to avoid duplicates
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

	return success1 or success2 -- Return true if either analysis succeeded
end

return M
