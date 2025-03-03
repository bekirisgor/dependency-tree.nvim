-----------------
-- lsp.lua
-----------------

local utils = require("dependency-tree.utils")

local M = {}

-- Convert LSP position to buffer position
function M.lsp_to_buf_pos(pos)
	if not pos then
		return { line = 0, character = 0 }
	end

	return {
		line = pos.line,
		character = pos.character,
	}
end

-- Get symbol information using Treesitter
function M.get_symbol_info_at_cursor()
	local bufnr = vim.api.nvim_get_current_buf()
	local win = vim.api.nvim_get_current_win()
	local cursor_pos = vim.api.nvim_win_get_cursor(win)
	local pos = { line = cursor_pos[1] - 1, character = cursor_pos[2] }

	-- Use Treesitter for symbol extraction
	return M.get_symbol_at_pos(bufnr, pos)
end

-- Use Treesitter to get symbol info
function M.get_symbol_by_treesitter(bufnr, pos)
	-- Check if buffer exists
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return nil
	end

	-- Get filetype
	local filetype = vim.api.nvim_buf_get_option(bufnr, "filetype")
	if not filetype or filetype == "" then
		return nil
	end

	-- Map filetypes to treesitter language names
	local lang_map = {
		typescript = "typescript",
		javascript = "javascript",
		typescriptreact = "tsx",
		javascriptreact = "jsx",
		python = "python",
		lua = "lua",
		go = "go",
		rust = "rust",
	}

	local lang = lang_map[filetype]
	if not lang then
		return nil
	end

	-- Check if parser exists for this language
	if not vim.treesitter.language.require_language(lang, nil, true) then
		return nil
	end

	-- Get parser for the buffer
	local parser = vim.treesitter.get_parser(bufnr, lang)
	if not parser then
		return nil
	end

	-- Get syntax tree
	local tree = parser:parse()[1]
	if not tree then
		return nil
	end

	local root = tree:root()
	if not root then
		return nil
	end

	-- Find node at cursor position
	local node = root:named_descendant_for_range(pos.line, pos.character, pos.line, pos.character)
	if not node then
		return nil
	end

	-- Start with the current node
	local current = node

	-- First, try to get the identifier directly
	if current:type() == "identifier" then
		local text = vim.treesitter.get_node_text(current, bufnr)
		if text and text ~= "" then
			return text
		end
	end

	-- If not an identifier, try to find the parent function/method/class name
	current = node
	while current do
		local node_type = current:type()

		-- Check for common symbol-containing nodes
		if
			node_type == "function_declaration"
			or node_type == "method_definition"
			or node_type == "arrow_function"
			or node_type == "class_declaration"
		then
			-- Find the name field within this node
			for child_idx = 0, current:named_child_count() - 1 do
				local child = current:named_child(child_idx)
				if
					child:type() == "identifier"
					and (child:field("name")[1] == child or current:field("name")[1] == child)
				then
					local text = vim.treesitter.get_node_text(child, bufnr)
					if text and text ~= "" then
						return text
					end
				end
			end
		elseif node_type == "variable_declarator" then
			-- Handle variable declarations (const x = function() {})
			local name_node = current:field("name")[1]
			if name_node and name_node:type() == "identifier" then
				local text = vim.treesitter.get_node_text(name_node, bufnr)
				if text and text ~= "" then
					return text
				end
			end
		elseif node_type == "identifier" or node_type == "property_identifier" then
			-- Direct identifier or property
			local text = vim.treesitter.get_node_text(current, bufnr)
			if text and text ~= "" then
				return text
			end
		end

		-- Move up the tree
		current = current:parent()
	end

	return nil
end

-- Get symbol at position using text
function M.get_symbol_by_text(bufnr, pos)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return nil
	end

	-- Get line content
	local lines = vim.api.nvim_buf_get_lines(bufnr, pos.line, pos.line + 1, false)
	local line = lines[1]
	if not line or line == "" then
		return nil
	end

	-- Find word at cursor position
	local col = pos.character
	local word_start = col
	local word_end = col

	-- Find word start
	while word_start > 0 and line:sub(word_start, word_start):match("[%w_]") do
		word_start = word_start - 1
	end

	-- Find word end
	while word_end <= #line and line:sub(word_end, word_end):match("[%w_]") do
		word_end = word_end + 1
	end

	-- Extract the word
	local word = line:sub(word_start + 1, word_end - 1)

	-- Check if it's a valid identifier
	if word:match("^[%a_][%w_]*$") then
		return word
	end

	return nil
end

-- Get symbol at position using either method
function M.get_symbol_at_pos(bufnr, pos)
	return M.get_symbol_by_treesitter(bufnr, pos) or M.get_symbol_by_text(bufnr, pos)
end

-- Safely call LSP for references
function M.get_references(params)
	local result = vim.lsp.buf_request_sync(0, "textDocument/references", params, 1000)
	local references = {}

	if not result then
		return references
	end

	for _, res in pairs(result) do
		if res.result then
			for _, ref in ipairs(res.result) do
				-- Skip invalid references
				if not ref then
					goto continue_ref
				end

				local uri = ref.uri or ref.targetUri
				if not uri then
					goto continue_ref
				end

				local file_path = uri:gsub("file://", "")

				if not utils.should_exclude(file_path) then
					table.insert(references, ref)
				end

				::continue_ref::
			end
		end
	end

	return references
end

-- Safely call LSP for definitions
function M.get_definitions(params)
	local result = vim.lsp.buf_request_sync(0, "textDocument/definition", params, 1000)
	local definitions = {}

	if not result then
		return definitions
	end

	for _, res in pairs(result) do
		if res.result then
			-- Handle both arrays and single result
			local defs = type(res.result) == "table" and res.result or { res.result }
			for _, def in ipairs(defs) do
				-- Skip invalid definitions
				if not def then
					goto continue_def
				end

				local uri = def.uri or def.targetUri
				if not uri then
					goto continue_def
				end

				local file_path = uri:gsub("file://", "")

				if not utils.should_exclude(file_path) then
					table.insert(definitions, def)
				end

				::continue_def::
			end
		end
	end

	return definitions
end

-- Find implementation based on definition
function M.find_implementation(symbol_name)
	-- Try using LSP workspace/symbol
	local params = {
		query = symbol_name,
	}

	local result = vim.lsp.buf_request_sync(0, "workspace/symbol", params, 2000)
	if result then
		for _, res in pairs(result) do
			if res.result then
				for _, symbol in ipairs(res.result) do
					if symbol.name == symbol_name then
						-- Found a potential match
						return {
							uri = symbol.location.uri,
							range = symbol.location.range,
						}
					end
				end
			end
		end
	end

	return nil
end

-- Find definitions for a symbol using workspace/symbol
function M.find_symbol_definitions(symbol_name)
	local params = {
		query = symbol_name,
	}

	local result = vim.lsp.buf_request_sync(0, "workspace/symbol", params, 2000)
	local definitions = {}

	if result then
		for _, res in pairs(result) do
			if res.result then
				for _, symbol in ipairs(res.result) do
					if
						symbol.name == symbol_name
						and symbol.location
						and not utils.should_exclude(symbol.location.uri)
					then
						table.insert(definitions, symbol.location)
					end
				end
			end
		end
	end

	return definitions
end

-- Find implementations using workspace search
function M.find_implementations(symbol_name)
	local params = {
		query = symbol_name,
	}

	local result = vim.lsp.buf_request_sync(0, "workspace/symbol", params, 2000)
	local implementations = {}

	if result then
		for _, res in pairs(result) do
			if res.result then
				for _, symbol in ipairs(res.result) do
					if
						symbol.name == symbol_name
						and symbol.location
						and not utils.should_exclude(symbol.location.uri)
					then
						table.insert(implementations, symbol.location)
					end
				end
			end
		end
	end

	return implementations
end

return M

