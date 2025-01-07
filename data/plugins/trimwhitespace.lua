-- mod-version:3
local common = require "core.common"
local config = require "core.config"
local command = require "core.command"
local Doc = require "core.doc"

---@class config.plugins.trimwhitespace
---@field enabled boolean
---@field trim_trailing boolean
---@field trim_empty_end_lines boolean
---@field leave_last boolean
config.plugins.trimwhitespace = common.merge({
  enabled = false,
  trim_trailing = true,
  trim_empty_end_lines = false,
  leave_last = false,
  config_spec = {
    name = "Trim Whitespace",
    {
      label = "Enabled",
      description = "Enable trimming of white space when saving file.",
      path = "enabled",
      type = "toggle",
      defalt = false
    },
    {
      label = "Trim Lines",
      description = "Remove any trailing whitespace from lines.",
      path = "trim_trailing",
      type = "toggle",
      default = true
    },
    {
      label = "Trim Empty End Lines",
      description = "Remove any empty new lines at the end of documents.",
      path = "trim_empty_end_lines",
      type = "toggle",
      default = false
    },
    {
      label = "Leave One Empty End Line",
      description = "VIM-compatibility, leaves one NL at EOF (If \"Trim Empty End Lines\" is active.",
      path = "leave_last",
      type = "toggle",
      default = false
    }
  }
}, config.plugins.trimwhitespace)

---@class plugins.trimwhitespace
local trimwhitespace = {}

---Disable whitespace trimming for a specific document.
---@param doc core.doc
function trimwhitespace.disable(doc)
  doc.disable_trim_whitespace = true
end

---Re-enable whitespace trimming if previously disabled.
---@param doc core.doc
function trimwhitespace.enable(doc)
  doc.disable_trim_whitespace = nil
end

---Disable trim NL at EOF for a specific document.
---@param doc core.doc
function trimwhitespace.disable_trim_empty_NL(doc)
  doc.disable_trim_whitespace_empty_NL = true
end

---Re-enable trim NL at EOF if previously disabled.
---@param doc core.doc
function trimwhitespace.enable_trim_empty_NL(doc)
  doc.disable_trim_whitespace_empty_NL = nil
end

---Disable leave last for a specific document.
---@param doc core.doc
function trimwhitespace.disable_leave_last(doc)
  doc.disable_trim_whitespace_leave_last = true
end

---Re-enable leave last if previously disabled.
---@param doc core.doc
function trimwhitespace.enable_leave_last(doc)
  doc.disable_trim_whitespace_leave_last = nil
end

---Perform whitespace trimming in all lines of a document except the
---line where the caret is currently positioned.
---@param doc core.doc
function trimwhitespace.trim(doc)
  local cline, ccol = doc:get_selection()
  for i = 1, #doc.lines do
    local old_text = doc:get_text(i, 1, i, math.huge)
    local new_text = old_text:gsub("%s*$", "")

    -- don't remove whitespace which would cause the caret to reposition
    if cline == i and ccol > #new_text then
      new_text = old_text:sub(1, ccol - 1)
    end

    if old_text ~= new_text then
      doc:insert(i, 1, new_text)
      doc:remove(i, #new_text + 1, i, math.huge)
    end
  end
end

---Removes empty new lines at the end of the document.
---@param doc core.doc
---@param raw_remove? boolean Perform the removal not registering to undo stack
function trimwhitespace.trim_empty_end_lines(doc, raw_remove)
  for _ = #doc.lines, 1, -1 do
    local l = #doc.lines
    if l > 1 and doc.lines[l] == "\n" then
      local current_line = doc:get_selection()
      if current_line == l then
        doc:set_selection(l - 1, math.huge, l - 1, math.huge)
      end
      if raw_remove then
        table.remove(doc.lines, l)
      else
        doc:remove(l - 1, math.huge, l, math.huge)
      end
    else
      break
    end
  end
  if config.plugins.trimwhitespace.leave_last
    and not doc.disable_trim_whitespace_leave_last
  then
    if raw_remove then
      doc.lines[#doc.lines + 1] = "\n"
    else
      doc:insert(math.huge, math.huge, "\n")
    end
  end
end


command.add("core.docview", {
  ["trim-whitespace:trim-trailing-whitespace"] = function(dv)
    trimwhitespace.trim(dv.doc)
  end,

  ["trim-whitespace:trim-empty-end-lines"] = function(dv)
    trimwhitespace.trim_empty_end_lines(dv.doc)
  end,

  ["trim-whitespace:disable-trimming-this-document"] = function(dv)
    trimwhitespace.disable(dv.doc)
  end,

  ["trim-whitespace:enable-trimming-this-document"] = function(dv)
    trimwhitespace.enable(dv.doc)
  end,

  ["trim-whitespace:disable-trimming-NL-at-EOF-this-document"] = function(dv)
    trimwhitespace.disable_trim_empty_NL(dv.doc)
  end,

  ["trim-whitespace:enable-trimming-NL-at-EOF-this-document"] = function(dv)
    trimwhitespace.enable_trim_empty_NL(dv.doc)
  end,

  ["trim-whitespace:disable-leaving-last-NL-this-document"] = function(dv)
    trimwhitespace.disable_leave_last(dv.doc)
  end,

  ["trim-whitespace:enable-leaving-last-NL-this-document"] = function(dv)
    trimwhitespace.enable_leave_last(dv.doc)
  end
})


local doc_save = Doc.save
function Doc:save(...)
  if not config.plugins.trimwhitespace.enabled then
    return doc_save(self, ...)
  end

  if config.plugins.trimwhitespace.trim_trailing
    and not self.disable_trim_whitespace
  then
    trimwhitespace.trim(self)
  end
  if config.plugins.trimwhitespace.trim_empty_end_lines
    and not self.disable_trim_empty_NL
  then
      trimwhitespace.trim_empty_end_lines(self)
  end
  doc_save(self, ...)
end


return trimwhitespace
