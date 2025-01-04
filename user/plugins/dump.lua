-- mod-version:3
--[[
  dump.lua
  provides basic dump facility for var inspection and debugging
  - handles recursive tables
  - use with care on small tables (don't use on _G)
  - will not work on tables that don't return a string with __tostring()
  version: 20230624.1518 by SwissalpS
  license: MIT
--]]

local function dump(mValue, iMaxDepth, iDepth, tVisited)
  iMaxDepth = iMaxDepth or math.huge
  local m = mValue
  local i = iDepth or 0
  local t = tVisited or {}
  local sID
  local sOut = ''
  local sT = type(m)
  if 'string' == sT then
    return '"' .. m .. '"'
  elseif 'boolean' == sT then
    return tostring(m)
  elseif 'number' == sT then
    return tostring(m)
  elseif 'function' == sT then
    return '<' .. tostring(m) .. '>'
  elseif 'nil' == sT then
    return '<nil>'
  elseif 'table' == sT then
    sID = tostring(m)
    if t[sID] then return sID .. ' <recursion>' end

    if i >= iMaxDepth then return sID .. ' <max depth reached>' end

    i = i + 1
    t[sID] = true
    sOut = sOut .. sID .. ' {'
    for k, v in pairs(m) do
      sOut = sOut .. '\n' .. string.rep(' ', i * 2) .. '[' .. k .. '] = '
          .. dump(v, iMaxDepth, i, t) .. ','
    end
    sOut = sOut .. '\n' .. string.rep(' ', i * 2 - 2) .. '}'
  elseif 'userdata' == sT then
    return tostring(m)
  else
    return '<' .. sT .. '>'
  end
  return sOut
end -- dump


return { dump, function(m, i) print(dump(m, i)) end }
