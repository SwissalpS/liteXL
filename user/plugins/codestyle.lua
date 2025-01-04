-- mod-version:3
--[[
  codestyle.lua
  provides very basic single-line codestyle checks
  version: 20230718.2356 by SwissalpS
  license: MIT
  known limitations:
    - Does not detect URIs in comments or quoted strings in comments.
    - Basically doesn't know about human text in comments.
      It does not ignore comments by design, as these are often parsed for
      documentation and we especially want correct style in there.
--]]

local cs = {}

local core = require "core"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local DocView = require "core.docview"
local style = require "core.style"
local syntax = require "core.syntax"

config.plugins.codestyle = common.merge({
  enabled = true,
  colour = { common.color "#207379D3" },
  -- The config specification used by the settings gui
  config_spec = {
    name = "Code Style Hinter",
    {
      label = "Enabled",
      description = "Activates Code Style Hints.",
      path = "enabled",
      type = "toggle",
      default = true
    },
    {
      label = "Highlight Colour",
      description = "The colour used to highlight the hints.",
      path = "custom_color",
      type = "color",
      default = { common.color "#207379D3" }
    }
  }
}, config.plugins.codestyle)


-- shamelessly copied from selectionhighlight plugin
function cs.draw_box(x, y, w, h, color)
  local r = renderer.draw_rect
  local s = math.ceil(SCALE)
  r(x, y, w, s, color)
  r(x, y + h - s, w, s, color)
  r(x, y + s, s, h - s * 2, color)
  r(x + w - s, y + s, s, h - s * 2, color)
end -- cs.draw_box


function cs.isLua(doc)
  local header = doc:get_text(1, 1, doc:position_offset(1, 1, 128))
  local tSyntax = syntax.get(doc.filename, header)
  return 'Lua' == tSyntax.name
end -- cs.isLua


-- shamelessly copied from bracketmatch (adjusted whitespace)
function cs.get_token_at(doc, line, col)
  local column = 0
  for _, type, text in doc.highlighter:each_token(line) do
    column = column + #text
    if column >= col then return type, text end
  end
end -- cs.get_token_at


function cs.exceptionInQuotes(oDoc, iLine, iStart)
  -- in quotes
  local sType = cs.get_token_at(oDoc, iLine, iStart)
  if 'string' == sType then return true end
end -- cs.exceptionInQuotes


function cs.exceptionsDashNoWSafter(oDoc, iLine, iStart, iEnd)
  -- in quotes
  if cs.exceptionInQuotes(oDoc, iLine, iStart) then return true end

  local sBefore = oDoc.lines[iLine]:sub(iStart - 1, iStart - 1)
--print('Before: '..sBefore)
--print('After: '..oDoc.lines[iLine]:sub(iEnd, iEnd))
  if
    -- just a comment
    '-' == sBefore
    or '-' == oDoc.lines[iLine]:sub(iEnd, iEnd)
    -- negative number after '(' or '[' (not usual but not illegal)
    or '(' == sBefore or '[' == sBefore
  then
    return true
  end

  -- negative number
  local sTwoBefore = (0 >= iStart - 2) and ''
      or oDoc.lines[iLine]:sub(iStart - 2, iStart - 2)

--print (sTwoBefore)
  if '+' == sTwoBefore or '/' == sTwoBefore or ',' == sTwoBefore
    or '*' == sTwoBefore or '^' == sTwoBefore or '%' == sTwoBefore
    or '-' == sTwoBefore or '{' == sTwoBefore or '=' == sTwoBefore
  then
    return true
  end

  return false
end -- cs.exceptionsDashNoWSafter


function cs.exceptionsDashNoWSbefore(oDoc, iLine, iStart, iEnd)
  -- in quotes
  if cs.exceptionInQuotes(oDoc, iLine, iStart) then return true end

  local sBefore = oDoc.lines[iLine]:sub(iStart, iStart)
--print('before: '..sBefore, ('(' == sBefore and 'true'or 'false'))
--print('after: '..oDoc.lines[iLine]:sub(iEnd + 1, iEnd + 1))
  if
    -- just a comment
    '-' == sBefore
    or '-' == oDoc.lines[iLine]:sub(iEnd + 1, iEnd + 1)
    -- negative number after '(' or '[' (not usual but not illegal)
    or '(' == sBefore or '[' == sBefore
  then
    return true
  end
  return false
end -- cs.exceptionsDashNoWSbefore


cs.lPatterns = {
  { p = '%S%-', e = cs.exceptionsDashNoWSbefore },
  { p = '%-%S', e = cs.exceptionsDashNoWSafter },
  { p = '%S[~%+/|*%%^]' },
  { p = '[%+/|*%%^,]%S' },
  { p = '[^~<>=%s]=' },
  { p = '=[^=%s]' },
  { p = '[^%s][<>]' },
  { p = '[<>][^=%s]' },
  { p = '{[^}%s]' },
  { p = '[^{%s]}' },
  { p = '[^%s%[%(]#' }
}


cs.tLastState = { lines = {} }
function cs.updateState(oDoc, iChangeID, iLine)
--pd(tLastState)
	if oDoc ~= cs.tLastState.doc then
    cs.tLastState.doc = oDoc
    cs.tLastState.lines = {}
  end
	if iChangeID ~= cs.tLastState.changeID then
    cs.tLastState.changeID = iChangeID
    -- TODO: only reset the line that actually got changed
    cs.tLastState.lines = {}
  end
	--if not cs.tLastState.lines[iLine] then cs.tLastState.lines[iLine] = true end
end -- cs.updateState


local draw_line_text = DocView.draw_line_text
function DocView:draw_line_text(line, x, y)
  local lh = draw_line_text(self, line, x, y)

  -- don't act on non-doc DocViews or when disabled or when not lua-file
  -- or when line is insanely long
  if not self.doc.filename
    or not config.plugins.codestyle.enabled
    or not cs.isLua(self.doc)
    or 180 < #self.doc.lines[line]
  then
    return lh
  end

  -- early exit if nothing has changed since the last call
  local iChangeID = self.doc:get_change_id()
  if cs.tLastState.doc == self.doc and cs.tLastState.changeID == iChangeID
    and cs.tLastState.lines[line]
  then
    return lh
  end
  cs.updateState(self.doc, iChangeID, line)

  local iEnd, iStart, x1, x2
  local sPattern, fException
  local sLine = self.doc.lines[line]
  local i = #cs.lPatterns
  repeat
    iEnd = 0
    sPattern = cs.lPatterns[i].p
    fException = cs.lPatterns[i].e or cs.exceptionInQuotes
    while true do
      iStart, iEnd = sLine:find(sPattern, iEnd + 1)
      if not iStart then break end
      x1 = x + self:get_col_x_offset(line, iStart)
      x2 = x + self:get_col_x_offset(line, iEnd + 1)
      if not fException(self.doc, line, iStart, iEnd) then
        cs.draw_box(x1, y, x2 - x1, self:get_line_height(),
            config.plugins.codestyle.colour)

      end
    end
    i = i - 1
  until 0 == i
  return lh
end -- DocView:draw_line_text

function cs.showStatus(s)
  if not core.status_view then return end

  local tS = style.log['INFO']
  core.status_view:show_message(tS.icon, tS.color, s)
end -- cs.showStatus


function cs.toggleEnabled()
	config.plugins.codestyle.enabled = not config.plugins.codestyle.enabled

  cs.showStatus("Code style hints are "
    .. (config.plugins.codestyle.enabled and 'en' or 'dis')
    .. 'abled')
end -- cs.toggleEnabled


command.add(nil, {
  ['code-style:toggle-enabled'] = cs.toggleEnabled
})


return cs

