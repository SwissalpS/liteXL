local config = require "core.config"
if false == config.plugins.contextmenu then return end

if false ~= config.plugins.lintplus then
	local contextmenu = require "plugins.contextmenu"
	contextmenu:register('core.docview', {
		{ text = 'lint', command = 'lint+:check' }
	})
end -- add lintplus context-item


local core = require 'core'
local command = require "core.command"
--local tDump = require('plugins.dump')local d, pd = table.unpack(tDump)

-- Add treeview contextmenu items: open as project and open with git-cola
if false ~= config.plugins.treeview and false ~= config.plugins.contextmenu then
	core.add_thread(function()
		-- Make sure other deferred loads have run.
		-- i.e. TreeView deferring ContextMenu
		coroutine.yield(.3)

		local _, treeview, treemenu
		_, treeview = pcall(require, "plugins.treeview")
		treemenu = treeview and treeview.contextmenu

		if not treemenu then
			return
		end

		command.add(function()
			return treeview.hovered_item ~= nil, treeview.hovered_item
		end, {
			["user-contextmenu:open-as-project"] = function(item)
				if not (item and item.abs_filename) then
					core.error("Cannot open location")
					return
				end
				system.exec(string.format("%q %q", EXEFILE, item.abs_filename))
			end
		})

		treemenu:register(nil, {
			{
				text = "Open as project",
				command = "user-contextmenu:open-as-project",
			},
		})

		command.add(function()
			return treeview.hovered_item ~= nil, treeview.hovered_item
		end, {
			["user-contextmenu:open-with-git-cola"] = function(item)
				if not (item and item.abs_filename) then
					core.error("Cannot open location")
					return
				end
				system.exec(string.format("git-cola -r %q", item.abs_filename))
			end
		})

		treemenu:register(nil, {
			{
				text = "Open with git-cola",
				command = "user-contextmenu:open-with-git-cola",
			},
		})
	end)
end


-- Modify contextmenu if available.
-- Remove never used entries because the keybindings are second
-- nature or there are other easier ways to get the job done.
local iCountRuns = 0
local cm = nil
core.add_thread(function()
	--print('thread of SwissalpS has started')
	while 4 > iCountRuns do
		--print('thread of SwissalpS is running')
		iCountRuns = iCountRuns + 1
		cm = cm or require 'plugins.contextmenu'
		if cm and nil ~= cm.itemset and 2 < iCountRuns then
			break;
		end
		coroutine.yield(1.3)
	end
	if nil == cm or nil == cm.itemset then
		core.warn 'failed to get contextmenu items'
	else
		-- purge these commands out of contextmenu
		local tSkip = {
			['scale:increase'] = true,
			['scale:decrease'] = true,
			['scale:reset'] = true,
			['find-replace:find'] = true,
			['find-replace:replace'] = true,
			['spell-check:add-to-dictionary'] = false,
		}
		local lNewSet = {}
		--pd(cm.itemset)
		for i, t in ipairs(cm.itemset) do
			local lGroup = { predicate = t.predicate }
			local lNewItems = {}
			for _, t2 in ipairs(t.items) do
				if not t2.command or not tSkip[t2.command] then
					table.insert(lNewItems, t2)
				end
			end
			lNewItems.height = t.items.height
			lNewItems.width = t.items.width
			lGroup.items = lNewItems
			lNewSet[i] = lGroup
		end
		cm.itemset = lNewSet
	end
	--print('thread of SwissalpS has run')
end)

