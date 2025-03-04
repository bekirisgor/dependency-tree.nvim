-----------------
-- config.lua
-----------------

local M = {
	max_depth = 3, -- Default depth for recursion (integer, 1-10)
	min_depth = 1, -- Minimum depth to ensure some results (integer, 1-5)
	exclude_patterns = { -- Patterns to exclude (e.g., node_modules)
		"node_modules",
		"dist",
		"build",
		"vendor",
	},
	keymap = "<leader>dt", -- Default keymap for triggering the dependency tree
	export_keymap = "<leader>de", -- Default keymap for exporting tree to clipboard
	float_opts = { -- Floating window options
		width = 100, -- Increased width for better code visibility
		height = 40, -- Increased height for more context
		border = "rounded",
	},
	project_root = nil, -- Will be auto-detected if nil
	include_imports = true, -- Include imports in the exported file
	debug_mode = false, -- Set to true to enable debug logging
	display_options = {
		expand_root = true, -- Show expanded version of root function
		find_implementation = true, -- Find function implementation
		show_internal_vars = true, -- Show internal variables
		show_line_numbers = true, -- Show line numbers
		context_lines = 5, -- Number of context lines around functions
		recursive_vars = true, -- Show recursive internal variables and functions
		implementation_search_max_depth = 20, -- Max search depth for implementation lookup
		show_folder_tree = true, -- Show folder tree structure in output
		show_module_exports = true, -- Show exported functions/variables from modules
	},
	treesitter = {
		-- Configure languages for which treesitter should be used
		enabled_languages = {
			"typescript",
			"javascript",
			"tsx",
			"jsx",
			"python",
			"lua",
			"go",
			"rust",
			"c",
			"cpp",
			"java",
			"php",
		},
	},
	react = {
		enabled = true, -- Enable specialized React component handling
		max_parent_search_depth = 2, -- Search up to 2 levels up for component usage
		max_child_component_depth = 3, -- Search up to 3 levels down for child components
		show_props = true, -- Show component props in analysis
		show_jsx_usage = true, -- Show where JSX components are used in templates
	},
	ai_prompt = {
		-- Settings for AI-specific prompt generation
		include_folder_structure = true, -- Include folder tree in AI prompts
		include_implementation = true, -- Include implementation details
		include_usage_context = true, -- Include context of how functions are used
		format = "markdown", -- Output format for AI prompting
		detailed_relations = true, -- Show detailed relationship explanations
	},
}

-- Function to update config with user options
function M.update(opts)
	M = vim.tbl_deep_extend("force", M, opts or {})
	return M
end

return M
