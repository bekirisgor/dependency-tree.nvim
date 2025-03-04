-----------------
-- languages/init.lua
-----------------
--[[
    Language-specific utilities for dependency-tree.nvim

    This module serves as an entry point for language-specific analysis
    and delegates to specialized language modules.
]]

local M = {}

-- Require language modules with lazy loading
local typescript = nil
local python = nil
local lua = nil
local go = nil
local rust = nil

-- Supported language mapping to module names
local language_map = {
	typescript = "typescript",
	javascript = "typescript",
	typescriptreact = "tsx",
	javascriptreact = "jsx",
	python = "python",
	lua = "lua",
	go = "go",
	rust = "rust",
}

---Check if a language is supported
---@param filetype string The filetype to check
---@return boolean True if the language is supported
function M.is_supported(filetype)
	return language_map[filetype] ~= nil
end

---Get the appropriate language module for a filetype
---@param filetype string The filetype to get the module for
---@return table|nil The language module or nil if not supported
function M.get_module(filetype)
	local module_name = language_map[filetype]
	if not module_name then
		return nil
	end

	-- Lazy-load the module
	if module_name == "typescript" then
		if not typescript then
			typescript = require("dependency-tree.languages.typescript")
		end
		return typescript
	elseif module_name == "python" then
		if not python then
			python = require("dependency-tree.languages.python")
		end
		return python
	elseif module_name == "lua" then
		if not lua then
			lua = require("dependency-tree.languages.lua")
		end
		return lua
	elseif module_name == "go" then
		if not go then
			go = require("dependency-tree.languages.go")
		end
		return go
	elseif module_name == "rust" then
		if not rust then
			rust = require("dependency-tree.languages.rust")
		end
		return rust
	end

	return nil
end

---Find implementation in a language-specific way
---@param filetype string The filetype
---@param file_path string Path to the file
---@param symbol_name string Name of the symbol
---@param lines table Array of file content lines
---@return table|nil Implementation info or nil if not found
function M.find_implementation(filetype, file_path, symbol_name, lines)
	local module = M.get_module(filetype)
	if module and module.find_implementation then
		return module.find_implementation(file_path, symbol_name, lines)
	end

	-- Fallback to generic pattern matching
	for i, line in ipairs(lines) do
		if type(line) == "string" then
			-- Look for potential implementation based on common patterns
			if
				line:match("function%s+" .. symbol_name .. "%s*%(")
				or line:match("class%s+" .. symbol_name)
				or line:match(symbol_name .. "%s*=%s*function")
				or line:match("def%s+" .. symbol_name .. "%s*%(")
				or line:match("fn%s+" .. symbol_name .. "%s*%(")
				or line:match("func%s+" .. symbol_name .. "%s*%(")
			then
				return {
					line = i,
					column = line:find(symbol_name) or 0,
					type = "function",
				}
			end
		end
	end

	return nil
end

-- Direct export of language modules (for backward compatibility)
M.typescript = require("dependency-tree.languages.typescript")
M.python = require("dependency-tree.languages.python")
M.lua = require("dependency-tree.languages.lua")
M.go = require("dependency-tree.languages.go")
M.rust = require("dependency-tree.languages.rust")

return M
