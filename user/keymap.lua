local keymap = require "core.keymap"
local core = require "core"

-- key binding:
keymap.add { ["ctrl+q"] = "core:quit" }
keymap.add({ ["keypad enter"] = { "command:submit", "doc:newline" } }, true)

-- remove snippets' anoying keybinds that disable quick indent change
core.add_thread(function()
	keymap.unbind('shift+tab', 'snippets:previous')
	keymap.unbind('tab', 'snippets:next-or-exit')
	keymap.unbind('escape', 'snippets.exit')
end)

