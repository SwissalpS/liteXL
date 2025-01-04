local config = require "core.config"
if false == config.plugins.contextmenu then return end

if false ~= config.plugins.lintplus then
	local contextmenu = require "plugins.contextmenu"
	contextmenu:register('core.docview', {
		{ text = 'lint', command = 'lint+:check' }
	})
end -- add lintplus context-item


local core = require 'core'
--local tDump = require('plugins.dump')local d, pd = table.unpack(tDump)

-- modify contextmenu if available
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

