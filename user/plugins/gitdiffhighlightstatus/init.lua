-- mod-version:3
--[[
  gitdiffhighlightstatus/init.lua
  Highlights changed lines, if file is in a git repository.
  - Also supports [minimap], if user has it installed and activated.
  - Can replace [gitstatus], at least to some extent:
    - [gitstatus] scans the entire tree while this plugin only acts on
      loaded/saved files
    - [gitstatus] does not detect changes in repositories in subdirectories
      that aren't registered as submodules
    - [gitstatus] shows inserts and deletes of entire project in status view
      while this plugin shows the changes of current file
  - Note: colouring the treeview will follow real directory path and not symlinks
  version: 20230705.1323 by SwissalpS
  original [gitdiff_highlight] by github.com/vincens2005
  original [gitstatus] by github.com/rxi ?
  license: MIT
--]]
local core = require "core"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local Doc = require "core.doc"
local DocView = require "core.docview"
local gitdiff = require "plugins.gitdiffhighlightstatus.gitdiff"
local style = require "core.style"

local lDump = require('plugins.dump')local d, pd = table.unpack(lDump)
local system, process, PATHSEP, PLATFORM = system, process, PATHSEP, PLATFORM

config.plugins.gitdiffhighlightstatus = common.merge({
  use_status = true,
  use_treeview = false,
  stop_at_base = true,
  -- The config specification used by the settings gui
  config_spec = {
    name = "Git Diff Highlight and Status",
    {
      label = "Show Info in Status View",
      description = "You may not want this if you also use [gitstatus]."
          .. "\n(Relaunch needed)",
      path = "use_status",
      type = "toggle",
      default = true
    },
    {
      label = "Colour Items in Tree View",
      description = "You may not want this if you also use [gitstatus]."
          .. "\n(Relaunch needed)",
      path = "use_treeview",
      type = "toggle",
      default = false
    },
    {
      label = "Stop Colouring Parent Items at Repository Base",
      description = "You may not want this if you also use [gitstatus].",
      path = "stop_at_base",
      type = "toggle",
      default = true
    }
  }
}, config.plugins.gitdiffhighlightstatus)

-- maximum size of git diff to read, multiplied by filesize
config.plugins.gitdiffhighlightstatus.max_diff_size = 2

-- vscode defaults
style.gitdiff_addition = style.gitdiff_addition or { common.color "#587c0c" }
style.gitdiff_modification = style.gitdiff_modification or { common.color "#0c7d9d" }
style.gitdiff_deletion = style.gitdiff_deletion or { common.color "#94151b" }

style.gitdiff_width = style.gitdiff_width or 3

-- The main object containing exposed functions and such.
---@type { [string]: function | any }
local g = {}

-- Table containing async functions.
---@type { [string]: function }
g.a = {}

-- Table containing deferred functions.
---@type { [string]: function }
g.d = {}

-- Holds alternative item colours for when TreeView is being used.
-- { [path] = colour }
---@type { [string]: integer[] }
g.cached_color_for_item = {}

-- Holds diff information per Doc.
-- Since Doc objects are used as keys, this table is marked to have weak keys.
-- { [Doc] = { [integer] = "addition" | "modification" | "deletion" } }
-- The info table also contains the fields "is_in_repo", "inserts", "deletes"
---@type { [Doc]: table }
g.diffs = setmetatable({}, { __mode = "k" })


-- Array holding information on found repositories.
---@type { [string]: { [string]: any } }[]
g.repos = {}

-- Dictionary index lookup for found repositories.
---@type { [string]: integer }
g.repos_index = {}

-- Add a repo to cache
---@param path string The absolute base path to repository.
---@return integer index
function g.add_repo(path)
  if g.repos_index[path] then return g.repos_index[path] end

  local index = #g.repos + 1
  g.repos[index] = {
    deletions = 0,
    insertions = 0,
    path = path,
    updated = 0,
  }
  g.repos_index[path] = index
  return index
end -- g.add_repo


-- Get repo of given base path or index or nil if invalid.
---@param index_or_path integer | string
---@return { [string]: { [string]: any  }}
---@return nil
function g.get_repo(index_or_path)
	if 'string' == type(index_or_path) then
    return g.repos_index[index_or_path] and
        g.repos[g.repos_index[index_or_path]] or nil

  elseif 'number' == type(index_or_path) then
    return g.repos[index_or_path]
  end
  return nil
end -- g.get_repo


-- Return colour for diff type
---@param diff string
---| "addition" Some line was added
---| "modification" Something was changed in this line
---| "deletion" Line(s) have been removed
---@return table colour
function g.color_for_diff(diff)
  if "addition" == diff then
    return style.gitdiff_addition
  elseif "modification" == diff then
    return style.gitdiff_modification
  else
    return style.gitdiff_deletion
  end
end -- g.color_for_diff


-- Return diff info table for Doc.
---@param doc Doc
---@return table diff-info
function g.get_diff(doc)
  return g.diffs[doc] or { is_in_repo = false }
end


-- Calculate and return padding.
---@param dv DocView
---@return number padding
function g.padding(dv)
  return style.padding.x * 1.5 + dv:get_font():get_width(#dv.doc.lines)
end


-- Execute a shell command in the background.
-- Must be called from within a function executed with core.add_thread().
---@param cmd string[] The command line arguments
---@param max_len? integer The maximum length to read.
---@param yield? number 0 to math.huge, defaults to 0.1
---@return string
---@return number | nil
---@async
function g.a.exec(cmd, max_len, yield)
  local proc = process.start(cmd)
  while proc:running() do
    coroutine.yield(yield or .1)
  end
  return proc:read_stdout(max_len) or "", proc:returncode()
end -- g.a.exec


-- Update diff info for given Doc.
-- Called whenever a Doc is saved or loaded.
-- Aborts if a file is not added to a repo.
-- Must be called from within core.add_thread().
---@param doc Doc
---@async
function g.a.update_diff(doc)
  if not doc or not doc.abs_filename then return end

  local full_path = doc.abs_filename
  core.log_quiet("[gitdiffhighlightstatus] updating diff for " .. full_path)

  local path = full_path:match("(.*" .. PATHSEP .. ")")

  if not g.get_diff(doc).is_in_repo then
    local _, exit_code = g.a.exec({
      "git", "-C", path, "ls-files", "--error-unmatch", full_path
    })
    if 0 ~= exit_code then
      core.log_quiet("[gitdiffhighlightstatus] file "
          .. full_path .. " is not in a git repository")

      return
    end
  end

  -- get repo's base path
  local path_base = g.a.exec({
    "git", "-C", path, "rev-parse", "--show-toplevel"
  }):match("[^\n]*")

  -- get diff
  local max_size = system.get_file_info(doc.filename).size
  max_size = max_size * config.plugins.gitdiffhighlightstatus.max_diff_size
  local diff_string = g.a.exec({
    "git", "-C", path_base, "diff", "HEAD", "--word-diff",
    "--unified=1", "--no-color", full_path
  }, max_size)
  g.diffs[doc] = gitdiff.changed_lines(diff_string)

  -- get branch name
  local branch = g.a.exec({
    "git", "-C", path_base, "rev-parse", "--abbrev-ref", "HEAD"
  }) or ""
  g.diffs[doc].branch = branch:match("[^\n]*")

  -- get insert/delete statistics
  local inserts, deletes = 0, 0
  local numstat = g.a.exec({
    "git", "-C", path_base, "diff", "--numstat"
  })
--pd({branch=branch,file=doc.filename,full_path=full_path,path=path, path_base=path_base, numstat=numstat})
  local ins, dels, p, abs_path
  for line in string.gmatch(numstat, "[^\n]+") do
    ins, dels, p = line:match("(%d+)%s+(%d+)%s+(.+)")
    -- check if this stat is about this file
--pd({p=p or '<nil>'})
    if p and full_path == path_base .. PATHSEP .. p then
      inserts = inserts + (tonumber(ins) or 0)
      deletes = deletes + (tonumber(dels) or 0)
      if 0 == inserts + deletes then
        -- this is unlikely to ever happen, since git numstat
        -- only lists changes
        g.cached_color_for_item[full_path] = nil
        -- since this plugin avoids scanning entire trees,
        -- we can't reliably check if we can clear treeview colours for
        -- parent folders. We could scan cached_color_for_item to check on
        -- neighbour files that have been opened, but at this time SwissalpS
        -- doesn't consider that good enough and not worth the effort. Time
        -- would be better spent to implement a way to scan the entire tree like
        -- [gitstatus] does, but also find repos in subdirectories.
      else
        abs_path = full_path
        -- Color this file, and each parent folder. Too simple to not do it.
        while abs_path do
--pd(abs_path)
          g.cached_color_for_item[abs_path] = style.gitdiff_modification
          if config.plugins.gitdiffhighlightstatus.stop_at_base
            and abs_path == path_base then break end

          abs_path = common.dirname(abs_path)
        end
      end
    end -- found matching filename
  end -- loop lines
  g.diffs[doc].inserts = inserts
  g.diffs[doc].deletes = deletes
  g.diffs[doc].is_in_repo = true
end -- g.a.update_diff


------------- OVERRIDES -------------


local docview_get_gutter_width = DocView.get_gutter_width
function DocView:get_gutter_width()
  local gw, gpad = docview_get_gutter_width(self)
  if not g.get_diff(self.doc).is_in_repo then return gw, gpad end

  return gw + style.padding.x * style.gitdiff_width / 12, gpad
end -- DocView:get_gutter_width


local docview_draw_line_gutter = DocView.draw_line_gutter
function DocView:draw_line_gutter(line, x, y, width)
  if not g.get_diff(self.doc).is_in_repo then
    return docview_draw_line_gutter(self, line, x, y, width)
  end

  local lh = self:get_line_height()
  local gw, gpad = docview_get_gutter_width(self)

  docview_draw_line_gutter(self, line, x, y, gpad and gw - gpad or gw)

  if not g.diffs[self.doc][line] then
    return
  end

  local color = g.color_for_diff(g.diffs[self.doc][line])

  -- add margin in between highlight and text
  x = x + g.padding(self)

  local yoffset = self:get_line_text_y_offset()
  if "deletion" ~= g.diffs[self.doc][line] then
    renderer.draw_rect(x, y + yoffset, style.gitdiff_width,
        self:get_line_height(), color)

    return
  end

  renderer.draw_rect(x - style.gitdiff_width * 2,
      y + yoffset, style.gitdiff_width * 4, 2, color)

  return lh
end -- DocView:draw_line_gutter


local doc_on_text_change = Doc.on_text_change
function g.on_text_change(doc)
  doc.gitdiffhighlightstatus_last_doc_lines = #doc.lines
  return doc_on_text_change(doc, type)
end
-- Fired when text in document has changed
---@param type string
---@return nothing
function Doc:on_text_change(type)
  if not g.get_diff(self).is_in_repo then return g.on_text_change(self) end

  local line = self:get_selection()
  if "addition" == g.diffs[self][line] then return g.on_text_change(self) end
  -- TODO figure out how to detect an addition

  local last_doc_lines = self.gitdiffhighlightstatus_last_doc_lines or 0
  if "insert" == type
    or ("remove" == type and #self.lines == last_doc_lines)
  then
    g.diffs[self][line] = "modification"
  elseif "remove" == type then
    g.diffs[self][line] = "deletion"
  end
  return g.on_text_change(self)
end -- Doc:on_text_change


------------- MAIN OVERRIDES -------------


local doc_save = Doc.save
function Doc:save(...)
  doc_save(self, ...)
  core.add_thread(g.a.update_diff, nil, self)
end -- Doc.save


local doc_load = Doc.load
function Doc:load(...)
  doc_load(self, ...)
  self.gitdiffhighlightstatus_last_doc_lines = #self.lines
  core.add_thread(g.a.update_diff, nil, self)
end


-------------     DEFERRED LOADING     -------------
------------- DEPENDENCIES / ADDITIONS -------------


-- add status bar info after all plugins have loaded
function g.d.status()
  if not config.plugins.gitdiffhighlightstatus.use_status
    or not core.status_view
  then return end

  local StatusView = require "core.statusview"
  core.status_view:add_item({
    name = "gitdiffhighlightstatus:status",
    alignment = StatusView.Item.RIGHT,
    get_item = function()
      if not core.active_view:is(DocView) then return {} end

      local t = g.get_diff(core.active_view.doc)
      if not t.is_in_repo then return {} end

      return {
        (t.inserts ~= 0 or t.deletes ~= 0) and style.accent or style.text,
        t.branch,
        style.dim, "  ",
        t.inserts ~= 0 and style.accent or style.text, "+", t.inserts,
        style.dim, " / ",
        t.deletes ~= 0 and style.accent or style.text, "-", t.deletes,
      }
    end,
    position = -1,
    tooltip = "branch and changes",
    separator = core.status_view.separator2
  })
end
core.add_thread(g.d.status)


-- add treeview info after all plugins have loaded
function g.d.treeview()
  if not config.plugins.gitdiffhighlightstatus.use_treeview
    or false == config.plugins.treeview
  then return end

  -- abort if TreeView isn't installed
  local found, TreeView = pcall(require, "plugins.treeview")
  if not found then return end

  local treeview_get_item_text = TreeView.get_item_text
  function TreeView:get_item_text(item, active, hovered)
    local text, font, color = treeview_get_item_text(self, item, active, hovered)
    if g.cached_color_for_item[item.abs_filename] then
      color = g.cached_color_for_item[item.abs_filename]
    end
    return text, font, color
  end
end
core.add_thread(g.d.treeview)


-- add minimap support only after all plugins are loaded
function g.d.minimap()
  -- don't load minimap if user has disabled it
  if false == config.plugins.minimap then return end

  -- abort if MiniMap isn't installed
  local found, MiniMap = pcall(require, "plugins.minimap")
  if not found then return end

  -- Override MiniMap's line_highlight_color
  local minimap_line_highlight_color = MiniMap.line_highlight_color
  function MiniMap:line_highlight_color(line)
    local diff = g.get_diff(core.active_view.doc)
    if diff.is_in_repo and diff[line] then
      return g.color_for_diff(diff[line])
    end
    return minimap_line_highlight_color(line)
  end
end
core.add_thread(g.d.minimap)


------------- COMMANDS -------------


function g.jump_to_next_change()
  local doc = core.active_view.doc
  if not g.get_diff(doc).is_in_repo then return end

  local line, col = doc:get_selection()

  while g.diffs[doc][line] do
    line = line + 1
  end

  while line < #doc.lines do
    if g.diffs[doc][line] then
      doc:set_selection(line, col, line, col)
      return
    end
    line = line + 1
  end

  -- TODO: loop around?
end -- g.jump_to_next_change


function g.jump_to_previous_change()
  local doc = core.active_view.doc
  if not g.get_diff(doc).is_in_repo then return end

  local line, col = doc:get_selection()

  while g.diffs[doc][line] do
    line = line - 1
  end

  while 0 < line do
    if g.diffs[doc][line] then
      doc:set_selection(line, col, line, col)
      return
    end
    line = line - 1
  end

  -- TODO: loop around?

end -- g.jump_to_previous_change


command.add("core.docview", {
  ["git-diff:previous-change"] = g.jump_to_previous_change,
  ["gitdiff:next-change"] = g.jump_to_next_change
})

return g

