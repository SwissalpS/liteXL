local keymap = require "core.keymap"

-- key binding:
keymap.add { ["ctrl+q"] = "core:quit" }
keymap.add({ ["keypad enter"] = { "command:submit", "doc:newline" } }, true)

