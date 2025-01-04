local config = require "core.config"
if false == config.plugins.lsp then return end

config.plugins.lsp.stop_unneeded_servers = true
config.plugins.lsp.show_diagnostics = true
config.plugins.lsp.mouse_hover_delay = 300
config.plugins.lsp.mouse_hover = false

local lspconfig = require "plugins.lsp.config"
lspconfig.sumneko_lua.setup({
	command = {
		"/your/path/to/luaLanguageServer/bin/lua-language-server",
		"-E",
		"/your/path/to/luaLanguageServer/bin/main.lua"
	},
	settings = {
		Lua = {
			diagnostics = {
				enable = false
			}
		}
	}
})

