local config = require "core.config"
config.stonks = nil

require "lintplus"
-- Needs to be setup first in user/lsp.lua
config.plugins.lsp = false
--require "lsp"
require "keymap"
require "contextmenu"

