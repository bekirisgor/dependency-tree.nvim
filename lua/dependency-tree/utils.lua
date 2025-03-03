-----------------
-- utils.lua
-----------------

local config = require("dependency-tree.config")

local M = {}

-- Cache structures
M.processed_cache = {}     -- Cache for already processed references to avoid circular dependencies
M.file_content_cache = {}  -- Cache for file content
M.gitignore_patterns = nil -- Cached gitignore patterns
M.analyzed_symbols = {}    -- Cache to track which symbols we've already analyzed

-- Helper function to safely check if a value exists in a table
function M.tbl_contains(tbl, value)
	if not tbl then
		return false
	end
	for _, v in ipairs(tbl) do
		if v == value then
			return true
		end
	end
	return false
end

-- Check if we've already analyzed this symbol
function M.has_analyzed_symbol(symbol_name, file_path)
	local key = symbol_name .. ":" .. file_path
	return M.analyzed_symbols[key] ~= nil
end

-- Mark a symbol as analyzed
function M.mark_symbol_analyzed(symbol_name, file_path)
	local key = symbol_name .. ":" .. file_path
	M.analyzed_symbols[key] = true
end

-- Check if a file should be excluded based on patterns and gitignore
function M.should_exclude(file_path)
	if not file_path then
		return false
	end

	-- Remove file:// prefix if present
	file_path = file_path:gsub("file://", "")

	-- Check against config exclude patterns
	for _, pattern in ipairs(config.exclude_patterns) do
		if file_path:match(pattern) then
			return true
		end
	end

	-- Check against gitignore patterns
	if M.gitignore_patterns == nil then
		M.gitignore_patterns = M.load_gitignore_patterns()
	end

	for _, pattern in ipairs(M.gitignore_patterns) do
		if M.matches_gitignore_pattern(file_path, pattern) then
			return true
		end
	end

	return false
end

-- Load gitignore patterns from project root
function M.load_gitignore_patterns()
	local patterns = {}
	local project_root = M.get_project_root()
	local gitignore_path = project_root .. "/.gitignore"

	local file = io.open(gitignore_path, "r")
	if not file then
		return patterns
	end

	for line in file:lines() do
		-- Skip comments and empty lines
		if line ~= "" and not line:match("^%s*#") then
			-- Convert gitignore pattern to Lua pattern
			local lua_pattern = M.gitignore_to_lua_pattern(line)
			table.insert(patterns, lua_pattern)
		end
	end

	file:close()
	return patterns
end

-- Convert gitignore pattern to Lua pattern
function M.gitignore_to_lua_pattern(pattern)
	-- Remove trailing slashes
	pattern = pattern:gsub("/$", "")

	-- Escape special characters
	pattern = pattern:gsub("([%.%-%+%[%]%(%)%$%^%%])", "%%%1")

	-- Handle * and **
	pattern = pattern:gsub("%*%*", ".*")
	pattern = pattern:gsub("%*", "[^/]*")

	-- Handle ? (single character match)
	pattern = pattern:gsub("%?", ".")

	return pattern
end

-- Check if path matches a gitignore pattern
function M.matches_gitignore_pattern(path, pattern)
	return path:match(pattern) ~= nil
end

-- Check if a symbol is a language keyword
function M.is_keyword(symbol)
	local keywords = {
		-- JavaScript/TypeScript
		"if",
		"else",
		"for",
		"while",
		"do",
		"switch",
		"case",
		"default",
		"break",
		"continue",
		"return",
		"function",
		"var",
		"let",
		"const",
		"class",
		"extends",
		"implements",
		"interface",
		"import",
		"export",
		"from",
		"as",
		"async",
		"await",
		"this",
		"super",
		"new",
		"try",
		"catch",
		"finally",
		"throw",
		"typeof",
		"instanceof",
		"true",
		"false",
		"null",
		"undefined",
		"void",
		"delete",

		-- Python
		"def",
		"class",
		"if",
		"else",
		"elif",
		"for",
		"while",
		"try",
		"except",
		"finally",
		"with",
		"as",
		"import",
		"from",
		"and",
		"or",
		"not",
		"is",
		"in",
		"lambda",
		"return",
		"yield",
		"None",
		"True",
		"False",
		"global",
		"nonlocal",
		"pass",
		"break",
		"continue",

		-- Lua
		"and",
		"break",
		"do",
		"else",
		"elseif",
		"end",
		"false",
		"for",
		"function",
		"if",
		"in",
		"local",
		"nil",
		"not",
		"or",
		"repeat",
		"return",
		"then",
		"true",
		"until",
		"while",

		-- Go
		"break",
		"case",
		"chan",
		"const",
		"continue",
		"default",
		"defer",
		"else",
		"fallthrough",
		"for",
		"func",
		"go",
		"goto",
		"if",
		"import",
		"interface",
		"map",
		"package",
		"range",
		"return",
		"select",
		"struct",
		"switch",
		"type",
		"var",

		-- Rust
		"as",
		"break",
		"const",
		"continue",
		"crate",
		"else",
		"enum",
		"extern",
		"false",
		"fn",
		"for",
		"if",
		"impl",
		"in",
		"let",
		"loop",
		"match",
		"mod",
		"move",
		"mut",
		"pub",
		"ref",
		"return",
		"self",
		"Self",
		"static",
		"struct",
		"super",
		"trait",
		"true",
		"type",
		"unsafe",
		"use",
		"where",
		"while",
	}

	for _, keyword in ipairs(keywords) do
		if symbol == keyword then
			return true
		end
	end

	return false
end

-- Get project root directory
function M.get_project_root()
	if config.project_root then
		return config.project_root
	end

	-- Try to get from LSP workspace
	local clients = vim.lsp.get_active_clients()
	if clients and #clients > 0 then
		for _, client in ipairs(clients) do
			if client.config and client.config.root_dir then
				return client.config.root_dir
			end
		end
	end

	-- Try to get from git
	local git_root = vim.fn.system("git rev-parse --show-toplevel 2>/dev/null"):gsub("\n", "")
	if git_root and git_root ~= "" then
		return git_root
	end

	-- Fallback to current directory
	return vim.fn.getcwd()
end

-- Helper for reading file contents
function M.read_file_contents(file_path)
	if M.file_content_cache[file_path] then
		return M.file_content_cache[file_path]
	end

	local file = io.open(file_path, "r")
	if not file then
		return nil
	end

	local lines = {}
	for line in file:lines() do
		table.insert(lines, line)
	end
	file:close()

	M.file_content_cache[file_path] = lines
	return lines
end

-- Helper function to copy text to clipboard
function M.copy_to_clipboard(text)
	-- Try different clipboard methods and fallback gracefully
	local success = false

	-- Try vim built-in clipboard
	local function try_vim_clipboard()
		local old_clipboard = vim.o.clipboard
		vim.o.clipboard = "unnamedplus"

		-- Save to register
		local lines = vim.split(text, "\n")
		vim.fn.setreg("+", lines)

		-- Restore clipboard setting
		vim.o.clipboard = old_clipboard

		-- Check if it worked
		return vim.fn.has("clipboard") == 1
	end

	-- Try using system commands
	local function try_system_clipboard()
		local tmpfile = vim.fn.tempname()
		local file = io.open(tmpfile, "w")
		if not file then
			return false
		end

		file:write(text)
		file:close()

		-- Try system specific clipboard commands
		local cmd = nil
		if vim.fn.has("mac") == 1 then
			cmd = "cat " .. tmpfile .. " | pbcopy"
		elseif vim.fn.has("unix") == 1 then
			if vim.fn.executable("xclip") == 1 then
				cmd = "cat " .. tmpfile .. " | xclip -selection clipboard"
			elseif vim.fn.executable("xsel") == 1 then
				cmd = "cat " .. tmpfile .. " | xsel --clipboard"
			end
		elseif vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
			cmd = "type " .. tmpfile .. " | clip"
		end

		if cmd then
			local result = os.execute(cmd)
			os.remove(tmpfile)
			return result == 0 or result == true
		end

		os.remove(tmpfile)
		return false
	end

	-- Try OSC 52 (works in many terminals, even over SSH)
	local function try_osc52()
		local encoded = vim.fn.system("base64", text):gsub("\n", "")
		local osc52 = string.format("\x1b]52;c;%s\x07", encoded)

		-- Try to send to terminal
		success = pcall(function()
			local stderr = vim.api.nvim_get_vvar("stderr")
			return vim.fn.chansend(stderr, osc52)
		end)

		return success
	end

	-- Try methods in order of preference
	success = try_vim_clipboard() or try_system_clipboard() or try_osc52()

	-- Fallback: create a file
	if not success then
		local filename = vim.fn.getcwd() .. "/dependency_tree_export.md"
		local file = io.open(filename, "w")
		if file then
			file:write(text)
			file:close()
			vim.notify("Export saved to file: " .. filename, vim.log.levels.INFO)
			return true
		end
		return false
	end

	return success
end

-- Clear caches
function M.clear_caches()
	M.processed_cache = {}
	M.file_content_cache = {}
	M.gitignore_patterns = nil
	M.analyzed_symbols = {} -- Clear analyzed symbols cache
end

-- Helper for getting the source file containing an implementation using Treesitter
function M.find_file_containing_definition(symbol, max_files)
	local project_root = M.get_project_root()
	max_files = max_files or 100 -- Limit search to prevent excessive file reads

	-- First build a list of candidate files
	local find_cmd
	if vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
		-- Windows - use PowerShell
		find_cmd = string.format(
			'powershell -command "Get-ChildItem -Path %s -Recurse -Include *.ts,*.js,*.jsx,*.tsx | Select-Object -First %d | ForEach-Object { $_.FullName }"',
			project_root,
			max_files
		)
	else
		-- Unix/Linux/Mac - use find
		find_cmd = string.format(
			"find %s -type f -name '*.ts' -o -name '*.js' -o -name '*.jsx' -o -name '*.tsx' | head -%d",
			project_root,
			max_files
		)
	end

	-- Execute the command to get files
	local output = vim.fn.system(find_cmd)
	if vim.v.shell_error ~= 0 then
		return {}
	end

	-- Parse output into file list
	local files = {}
	for file in output:gmatch("[^\r\n]+") do
		table.insert(files, file)
	end

	-- Now search through each file with Treesitter
	local matching_files = {}
	for _, file_path in ipairs(files) do
		-- Skip excluded files
		if M.should_exclude(file_path) then
			goto continue_file
		end

		-- Create a buffer for the file
		local bufnr = vim.uri_to_bufnr("file://" .. file_path)

		-- Load the file if needed
		if not vim.api.nvim_buf_is_loaded(bufnr) then
			vim.fn.bufload(bufnr)
		end

		-- Try to get parser
		local parser = vim.treesitter.get_parser(bufnr)
		if not parser then
			goto continue_file
		end

		local ts_tree = parser:parse()[1]
		if not ts_tree then
			goto continue_file
		end

		local root = ts_tree:root()

		-- Create a query to find the symbol
		local query_str = string.format(
			[[
            (function_declaration
                name: (identifier) @name (#eq? @name "%s"))
            (variable_declarator
                name: (identifier) @name (#eq? @name "%s")
                value: [(function) (arrow_function)])
            (lexical_declaration
                (variable_declarator
                    name: (identifier) @name (#eq? @name "%s")
                    value: [(function) (arrow_function)]))
            (export_statement
                (variable_declarator
                    name: (identifier) @name (#eq? @name "%s")))
        ]],
			symbol,
			symbol,
			symbol,
			symbol
		)

		local query = vim.treesitter.query.parse(parser:lang(), query_str)

		-- Check if there's at least one match
		for id, node in query:iter_captures(root, bufnr, 0, -1) do
			table.insert(matching_files, file_path)
			goto continue_file -- Found a match, move to next file
		end

		::continue_file::
	end

	return matching_files
end

return M

