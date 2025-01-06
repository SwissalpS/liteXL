local config = require "core.config"
config.stonks = nil

require "lintplus"
config.plugins.lsp = false
-- Needs to be setup first in user/lsp.lua
--require "lsp"
require "keymap"
require "contextmenu"

