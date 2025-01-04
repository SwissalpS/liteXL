local config = require "core.config"
if false == config.plugins.lintplus then return end

local lintplus = require "plugins.lintplus"
lintplus.load("luacheck")
--lintplus.setup.lint_on_doc_load()
lintplus.setup.lint_on_doc_save()


