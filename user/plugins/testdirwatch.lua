-- mod-version:3
-- name suggestions: giti (there is a node.js backend or lib)
--     gitay Like good day
--     gitaware
--     gitspy
--     giteye
--     gitlight - might imply that it can do more than it can
--     gitview - may also imply showing git tree or similar
local lDump = require('plugins.dump')local d, pd = table.unpack(lDump)
local renderer, system, process, PATHSEP, PLATFORM = renderer, system, process, PATHSEP, PLATFORM
--pd = function () return end
local core = require "core"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local Doc = require "core.doc"
local DocView = require "core.docview"
local gitdiff = require "plugins.gitdiffhighlightstatus.gitdiff"
local style = require "core.style"

-- vscode defaults
style.gitdiff_addition = style.gitdiff_addition or { common.color "#587c0c" }
style.gitdiff_modification = style.gitdiff_modification or { common.color "#0c7d9d" }
style.gitdiff_deletion = style.gitdiff_deletion or { common.color "#94151b" }

style.gitdiff_width = style.gitdiff_width or 3

config.plugins.git____ = common.merge({
  use_status = true,
  use_treeview = true,
  stop_at_base = true,
  max_diff_size = 2048,
  autoscan = true,
  scan_rate = 25,
  status_shows_branch = false,
  status_shows_repo_stats = false,
  -- The config specification used by the settings gui
  config_spec = {
    name = "Git Diff Highlight and Status",
    {
      label = "Show Info in Status View",
      description = "Shows insertions and modification info.",
      path = "use_status",
      type = "toggle",
      default = true
    },
    {
      label = "Show Branch in Status View",
      description = "Shows current branch, if above toggle is active.",
      path = "status_shows_branch",
      type = "toggle",
      default = false
    },
    {
      label = "Colour Items in Tree View",
      description = "Highlight changed files and their parent directories "
          .. "in tree view.",
      path = "use_treeview",
      type = "toggle",
      default = true
    },
    {
      label = "Stop Colouring Parent Items at Repository Base",
      description = 'Only has effect if "Colour Items in Tree View" '
          .. 'is also active.',
      path = "stop_at_base",
      type = "toggle",
      default = true
    },
    {
      label = "Periodically Scan Project Tree for Repositories.",
      description = 'Recommended, not sure why this merits a toggle.',
      path = "autoscan",
      type = "toggle",
      default = true
    },
    {
      label = "Scan Interval",
      description = "Frequency, in seconds, to scan project tree.",
      path = "max_diff_size",
      type = "number",
      default = 25,
      min = 5,
      step = 5
    },
    {
      label = "Max Diff Size",
      description = "Maximum size of diffs to process. Currently limited to 2048.",
      path = "max_diff_size",
      type = "number",
      default = 2048,
      min = 512,
      step = 128
    }
  }
}, config.plugins.git____)


-- Amount of time to yield between steps.
---@type number
local nYield = math.abs(config.plugins.git____.yield or .001)

-- Depth of project tree to scan for repositories.
local iTreeDepth = math.abs(config.plugins.git____.treeDepth or 15)

-- The main object containing exposed functions and such.
---@type { [string]: any }
local g = {}

-- Table containing async functions.
---@type { [string]: fun }
g.a = {}

-- Table containing deferred functions.
---@type { [string]: fun }
g.d = {}

-------------         SCANNING         -------------

-- system.list_dir gives us a list without metadata to filter out easily.
-- dirwatch gives us that data but ignores .git directories.
-- So we roll our own using a process with `find` to detect directories
-- containing .git directories

-- Paths containing .git directories or project directory.
-- In other words, directories to check if they are valid repositories.
---@type string[]
g.lPossibleGitRepos = {}
-- Paths that have been checked and didn't seem to be valid repositories
-- or parts of repositories in the case of file paths.
---@type { [string]: boolean }
g.tNotGitRepos = {}
-- Paths that have been checked to be git repositories.
-- Project dir can be in here because a parent folder is a git repository.
---@type { [string]: table }
g.tGitRepos = {}
-- Information about files, such as additions, deletions and repository path.
---@type { [string]: table }
g.tFiles = {}

-- Holds alternative item colours for when TreeView is being used.
-- { [path] = colour }
---@type { [string]: integer[] }
g.tColours = {}

-- Holds thread ids of processes. They may or may not be active and valid.
---@type { [string]: integer }
g.tThread = {}

-- Reset the caches so scanning will not take shortcuts.
---@return boolean
function g.resetRepoInformation()
-- TODO: what happens if an async job is active and this is called?
-- probably should not be exposed
  g.tFiles = {}
  g.tColours = {}
  g.tGitRepos = {}
  g.tNotGitRepos = {}
  g.lPossibleGitRepos = {}
  return true
end -- g.resetRepoInformation


-- Returns a scaffold for a repository entry in g.tGitRepos
---@return table
function g.emptyRepoTable()
  return {
    ---@type integer
    additions = 0,
    ---@type string
    branch = '',
    ---@type integer
    deletions = 0,
    -- Last system.get_time() value that this file showed up in numstat.
    ---@type { [string]: integer }
    files = {},
    -- OS time stamp of last change.
    ---@type integer
    modified = 0
  }
end -- g.emptyRepoTable


-- Execute a shell command in the background.
-- Must be called from within a function executed with core.add_thread().
---@param cmd string[] The command line arguments
---@param max_len? integer The maximum length to read.
---@param yield? number 0 to math.huge, defaults to 0.1
---@return string
---@return number | nil
---@async
function g.a.exec1(cmd, max_len, yield)
  local proc = process.start(cmd)
  while proc:running() do
    coroutine.yield(yield or nYield)
  end
  return proc:read_stdout(max_len) or "", proc:returncode()
end -- g.a.exec1


-- Placeholder echo function for g.a.exec with minimal arguments.
---@param s string
---@return string
local function oneShot(s) return s end


-- Options that can be passed to g.a.exec()
---@class exec.options
---@field public max_buffer integer
---@field public yield number
---@field public options process.options


-- Execute a shell command in the background.
-- Must be called from within a function executed with core.add_thread().
-- Loops calling callback function until callback returns other than true.
-- Each loop the next portion of output is passed to callback.
---@param cmd string[] The command line arguments.
---@param callback? fun
---@param options? exec.options
---@param ...? unknown Optional arguments passed to callback.
---@return string
---@return process.errortype | integer errcode
function g.a.exec(cmd, callback, options, ...)
  local worker = 'function' == type(callback) and callback or oneShot
  local max_buffer = 2048
  local yield = nYield
  local tProcessOptions = {}
  if 'table' == type(options) then
    max_buffer = options.max_buffer or max_buffer
    yield = options.yield or yield
    if 'table' == type(options.options) then
      tProcessOptions = options.options
    end
  end

  local proc = process.start(cmd, tProcessOptions)
  -- the commands I tried, don't output until process is complete,
  -- so we loop and wait for that to happen
  while proc:running() do
    coroutine.yield(yield)
  end

  local mResult
  local exitcode = proc:returncode()
  repeat
    mResult = worker(proc:read_stdout(max_buffer) or "", exitcode, ...)
    coroutine.yield(yield)
  until true ~= mResult
  return mResult, exitcode
end -- g.a.exec


function g.a.lookupFileDiff(repo_base, file_path)
  local sAll = ''
  return g.a.exec({
    "git", "-C", repo_base, "diff", "HEAD", "--word-diff",
    "--unified=1", "--no-color", file_path
  }, function(s)
    if '' == s then return gitdiff.changed_lines(sAll) end

    sAll = sAll .. s
    return true
  end)
end -- g.a.lookupFileDiff


-- Runs `git rev-parse --show-toplevel` to determine base path
-- of repository and returns it.
---@param path string
---@return string
function g.a.lookupRepoBasePath(path)
  return g.a.exec({
    "git", "-C", path, "rev-parse", "--show-toplevel"
  }):match("[^\n]*")
end -- g.a.lookupRepoBasePath


-- Runs `git rev-parse --abbrev-ref HEAD` to determine the currently
-- checked out branch/commit of repository and returns it.
---@param path string
---@return string branch or commit
function g.a.lookupRepoBranch(path)
  local sOut, exitcode = (g.a.exec({
    "git", "-C", path, "rev-parse", "--abbrev-ref", "HEAD"
  }) or ""):match("[^\n]*")
  if 'HEAD' ~= sOut then return sOut, exitcode end

  -- checked out at an arbitarry commit, get its hash
  return (g.a.exec({
    "git", "-C", path, "rev-parse", "HEAD"
  }) or ""):match("[^\n]*")
end -- g.a.lookupRepoBranch


-- Scans project tree for .git directories. Depth is limited to 15 for now.
-- The parsed output of `find` is placed in g.lPossibleGitRepos.
-- Scan step 1 of 4
function g.a.scanTree()
  if g.bScanningTree then return end

  -- mark that busy scanning
  g.bScanningTree = true

  local cmd
  if 'Linux' == PLATFORM then
    cmd = {
    'find', core.project_dir, '-maxdepth', iTreeDepth, '-mount',
    '-type', 'd', '-name', '\\.git'}
  else
    -- on OSX and Windows add -noleaf
    cmd = {
    'find', core.project_dir, '-maxdepth', iTreeDepth, '-mount',
    '-noleaf',
    '-type', 'd', '-name', '\\.git'}
  end
  local tResult = g.a.exec(cmd, function(sBuff, _, t)
    if '' == sBuff then return t end

    t.sList = t.sList .. sBuff
    local iLast, iNext, path
    iLast = 1
    repeat
      iNext = t.sList:find('\n', iLast, true)
      if not iNext then
        -- incomplete line, keep it so rest gets appended
        -- on next read
        t.sList = t.sList:sub(iLast, -1)
        break
      else
        path = t.sList:sub(iLast, iNext - 6)
        -- only add paths not previously marked as not being git repos
        -- also skip paths previously identified to be repos
        if not g.tNotGitRepos[path] and not g.tGitRepos[path] then
          t.l[#t.l + 1] = path
          if not t.bProjectDirIsGitRepo and path == core.project_dir then
            t.bProjectDirIsGitRepo = true
          end
        end
      end
      iLast = iNext + 1
    until false -- done parsing portion
    return true
  end, nil, { l = {}, sList = '' })

  if not tResult.bProjectDirIsGitRepo
    and not g.tNotGitRepos[core.project_dir]
    and not g.tGitRepos[core.project_dir]
  then
    -- add project dir to paths that need to be checked
    tResult.l[#tResult.l + 1] = core.project_dir
  end

  g.lPossibleGitRepos = tResult.l
  -- mark that done scanning the tree
  g.bScanningTree = nil
end -- g.a.scanTree


-- Loops through g.lPossibleGitRepos and checks whether the paths are part of
-- a git repository or not. Populates g.tGitRepos with scaffold entries or
-- adds entry to g.tNotGitRepos when not a valid git repository.
-- Scan step 2 of 4
function g.a.checkForRepos()
  if g.bCheckingForRepos then return end

  local iIndex = #g.lPossibleGitRepos
  if 0 == iIndex then return end

  g.bCheckingForRepos = true

  local path, path_base
  repeat
    path = g.lPossibleGitRepos[iIndex]
    -- no need to re-check if previosly checked or marked as non repo
    if not g.tNotGitRepos[path] and not g.tGitRepos[path] then
      -- get repo's base path
      path_base = g.a.lookupRepoBasePath(path)
      -- if the paths don't match, it's not a repo or damaged
      if path ~= path_base then
        -- add to 'is not a repo' dictionary
        g.tNotGitRepos[path] = true
      else
        -- add to 'is a repo' cache
        g.tGitRepos[path] = g.emptyRepoTable()
      end
    end
    coroutine.yield(nYield)
    iIndex = iIndex - 1
  until 0 == iIndex
  -- mark that no longer checking
  g.bCheckingForRepos = nil
end -- g.a.checkForRepos


-- Populates entries in g.tGitRepos with branch, additions and deletion counts.
-- Also updates entries in g.tFiles with counts and rebuilds g.tColours.
-- Scan step 3 of 4
function g.a.updateRepos()
  -- abort if another thread is already working on this
  if g.bUpdatingRepos then return end

  g.bUpdatingRepos = true

  -- we don't have sibling directory changed indexing, so we just rebuild all
  -- colours and reset the colours dictionary
  g.tColours = {}

  local info, file_item, file_path, numstat, path, tmp_path
  local iAdd, iDel, total_add, total_del, tFiles
  for path_base, item in pairs(g.tGitRepos) do
    info = system.get_file_info(path_base)
    -- when using TreeView highlighting, we can't skip unchanged directories
    -- as that would mess with highlights. I haven't come up with an efficient
    -- way to detect sibling dir structure changes, so this seems to be most
    -- straightforward thing to do.
    if info --and (info.modified ~= item.modified
        --or config.plugins.git____.use_treeview)
    then
      item.modified = info.modified
      tFiles = {}

      -- check for checked out branch/commit
      item.branch = g.a.lookupRepoBranch(path_base)


      -- get insert/delete statistics
      total_add, total_del = 0, 0
      numstat = g.a.exec({
        "git", "-C", path_base, "diff", "--numstat"
      })

      for sLine in string.gmatch(numstat, "[^\n]+") do
        iAdd, iDel, path = sLine:match("(%d+)%s+(%d+)%s+(.+)")
        if path and '' ~= path then
          iAdd = tonumber(iAdd) or 0
          iDel = tonumber(iDel) or 0
          total_add = total_add + iAdd
          total_del = total_del + iDel

          file_path = path_base .. PATHSEP .. path
          item.files[file_path] = nil
          tFiles[file_path] = true

          file_item = g.tFiles[file_path] or { base = path_base }
          file_item.additions = iAdd
          file_item.deletions = iDel
          g.tFiles[file_path] = file_item

          if 0 < iAdd + iDel then
            tmp_path = file_path
            -- Colour this file, and each parent folder. Too simple to not do it.
            repeat
              g.tColours[tmp_path] = style.gitdiff_modification
              if config.plugins.git____.stop_at_base
                and tmp_path == path_base
              then break end

              tmp_path = common.dirname(tmp_path)
            until not tmp_path
          end -- if modified
        end -- if parsed a path
      end -- loop lines

      -- update totals
      item.additions = total_add
      item.deletions = total_del

      -- update no longer changed files
      for p, _ in pairs(item.files) do
        file_item = g.tFiles[p]
        if file_item then
          file_item.changedLines = {}
          file_item.additions = 0
          file_item.deletions = 0
        else
          core.warning('[git____] previously indexed file ('
              .. p .. ') is no longer in g.tFiles')
        end
      end -- loop known files
      item.files = tFiles
    elseif not info then
      -- for now, just mark it as not a repo and log a warning
      item.error = true
      g.tNotGitRepos[path] = true
      core.warning('[git____] could not get info for ' .. path .. ' deleted?')
    end -- if needs update
    coroutine.yield(nYield)
  end -- loop g.tGitRepos

  g.bUpdatingRepos = nil
end -- g.a.updateRepos


-- Updates the diff in g.tFiles and if, e.g. file is from outside the project
-- tree, checks if that is a repository. If so adds it to be scanned on next
-- scan cycle.
-- Scan step 4 of 4. Is also called when a document is opened or saved.
function g.a.updateDoc(file_path)
  if not file_path or '' == file_path
    or g.tNotGitRepos[file_path]
  then return end

  local file_item = g.tFiles[file_path]
  if not file_item then
    -- check for repo etc.
    -- file could be from outside project tree
    file_item = { base = g.a.lookupRepoBasePath(file_path) }
    if '' == file_item.base then
      -- add to 'non repo' list, doesn't matter if not a dir,
      -- would still work and save a system call etc.
      g.tNotGitRepos[file_path] = true
      return
    end

    -- add base to repos to be analyzed
    --g.lPossibleGitRepos[#g.lPossibleGitRepos + 1] = file_item.base
    g.tGitRepos[file_item.base] = g.emptyRepoTable()

    -- until then, just use placeholders
    file_item.additions = 0
    file_item.deletions = 0
    g.tFiles[file_path] = file_item
  end -- if not yet indexed

  -- get parsed diff
  file_item.changedLines = g.a.lookupFileDiff(file_item.base, file_path)
end -- g.a.updateDoc


-- Calls g.a.updateDoc on each open document.
-- Scan step 4 of 4.
function g.a.updateOpenDocs()
  if g.bUpdatingOpenDocs then return end

  local iIndex = #core.docs
  if 0 == iIndex then return end

  g.bUpdatingDocs = true

  repeat
    g.a.updateDoc(core.docs[iIndex].abs_filename)
    coroutine.yield(nYield)
    iIndex = iIndex - 1
  until 0 == iIndex

  g.bUpdatingOpenDocs = nil
end -- g.a.updateOpenDocs


-- TODO: make sure this promise is kept
-- Scan the tree and refresh entries.
-- Is launched on intervals or manually with a command.
-- Scan step 0 of 4
function g.a.scan()
  if g.bScanning then return end

  local dScanStart = system.get_time()
  g.bScanning = true

	g.tThread.scanTree = core.add_thread(g.a.scanTree)
	repeat coroutine.yield(nYield) until not g.bScanningTree
	g.tThread.checkForRepos = core.add_thread(g.a.checkForRepos)
  repeat coroutine.yield(nYield) until not g.bCheckingForRepos
  g.tThread.updateRepos = core.add_thread(g.a.updateRepos)
  repeat coroutine.yield(nYield) until not g.bUpdatingRepos
  g.tThread.updateOpenDocs = core.add_thread(g.a.updateOpenDocs)

  g.bScanning = nil
  g.bFirstScanComplete = true

  core.log_quiet('Scanned git repositories in %.1fms',
      (system.get_time() - dScanStart) * 1000)
end -- g.a.scan


function g.a.autoscan()
  if g.bAutoScanning then return end

  g.bAutoScanning = true

	repeat
    g.tThread.scan = core.add_thread(g.a.scan)
    if config.plugins.git____.autoscan then
      coroutine.yield(config.plugins.git____.scan_rate or 45 * 60)
    else
      break
    end
  until false

  g.bAutoScanning = nil
end -- g.a.autoscan


-------------      DEFERRED LAUNCH     -------------

-- start autoscan if user wants it
core.add_thread(function()
  if config.plugins.git____.autoscan then
    g.tThread.autoscan = core.add_thread(g.a.autoscan)
  end
end)


-------------          HELPERS         -------------


-- Truncate string s to length i and add ellipsis if needed
-- at beginning: b == true (or anything but false and nil)
-- in the middle: b == false
-- at end: b == nil
---@param s string
---@param i integer
---@param b boolean | nil
---@return string
 function g.ellipsis(s, i, b)
	-- invalid or too short -> nothing to do
	if 'string' ~= type(s) or string.len(s) <= i then return s end
	if 'number' ~= type(i) then return nil end

	-- we don't want any negativity nor fractions
	i = math.abs(math.floor(i))
	-- silly
	if 0 == i then return '' end

	-- ridiculous
	if 2 >= i then return string.sub(s, 1, i) end

	if nil == b then
		-- add to end
		return string.sub(s, 1, i - 1) .. '…'

	elseif b then
		-- add to beginning
		return '…' .. string.sub(s, -1 * (i - 1))

	else
		-- insert in middle
		local j = math.floor((i - 1) * .5)
		return string.sub(s, 1, j) .. '…' .. string.sub(s, -j)
	end
end -- g.ellipsis


function g.getChangedLines(path)
  if not g.tFiles[path] then return nil end

  return g.tFiles[path].changedLines or {}
end -- g.getChangedLines


function g.getRepo(path)
  if g.tNotGitRepos[path] or not g.tGitRepos[path] then
    return g.emptyRepoTable()
  end

  return g.tGitRepos[path]
end -- g.getRepo


function g.jump_to_next_change()
  local doc = core.active_view.doc
  local changedLines = g.getChangedLines(doc.abs_filename)
  if not changedLines then return end

  local line, col = doc:get_selection()
  local startLine = line

  -- if current selection is in a changed portion, move downwards out of it
  while changedLines[line] do
    line = line + 1
  end

  -- moving down the document, find next portion that has changes
  while #doc.lines >= line  do
    if changedLines[line] then
      doc:set_selection(line, col, line, col)
      return
    end

    line = line + 1
  end

  -- nothing found, loop around from top
  line = 1

  -- moving down the document, find next portion that has changes
  while startLine > line do
    if changedLines[line] then
      doc:set_selection(line, col, line, col)
      return
    end

    line = line + 1
  end

  -- nothing found, give up
end -- g.jump_to_next_change


function g.jump_to_previous_change()
  local doc = core.active_view.doc
  local changedLines = g.getChangedLines(doc.abs_filename)
  if not changedLines then return end

  local line, col = doc:get_selection()
  local startLine = line

  -- if current selection is in a changed portion, move upwards out of it
  while changedLines[line] do
    line = line - 1
  end

  -- moving up the document, find next portion that has changes
  while 0 < line do
    if changedLines[line] then
      doc:set_selection(line, col, line, col)
      return
    end

    line = line - 1
  end

  -- nothing found, loop around from bottom
  line = #doc.lines

  -- moving up the document, find next portion that has changes
  while startLine < line do
    if changedLines[line] then
      doc:set_selection(line, col, line, col)
      return
    end

    line = line - 1
  end

  -- nothing found, give up
end -- g.jump_to_previous_change


-------------          COMMANDS        -------------


-- TODO: add scan command here
command.add("core.docview", {
  ["git____:previous-change"] = g.jump_to_previous_change,
  ["git____:next-change"] = g.jump_to_next_change
})


-------------     DOCVIEW HELPERS      -------------


-- Calculate and return padding.
---@param dv DocView
---@return number padding
function g.padding(dv)
  return style.padding.x * 1.5 + dv:get_font():get_width(#dv.doc.lines)
end


-- Return colour for change type.
---@param type string
---| "addition" Some line was added
---| "modification" Something was changed in this line
---| "deletion" Line(s) have been removed
---@return table colour
function g.colourForChange(type)
  if "addition" == type then
    return style.gitdiff_addition
  elseif "modification" == type then
    return style.gitdiff_modification
  else
    return style.gitdiff_deletion
  end
end -- g.colourForChange


-------------        OVERRIDES         -------------

-------------     DOCVIEW OVERRIDES    -------------


local docview_get_gutter_width = DocView.get_gutter_width
function DocView:get_gutter_width()
  local gw, gpad = docview_get_gutter_width(self)
  if not g.getChangedLines(self.doc.abs_filename) then return gw, gpad end

  return gw + style.padding.x * style.gitdiff_width / 12, gpad
end -- DocView:get_gutter_width


local docview_draw_line_gutter = DocView.draw_line_gutter
function DocView:draw_line_gutter(line, x, y, width)
  local changedLines = g.getChangedLines(self.doc.abs_filename)
  if not changedLines then
    return docview_draw_line_gutter(self, line, x, y, width)
  end

  local lh = self:get_line_height()
  local gw, gpad = docview_get_gutter_width(self)

  docview_draw_line_gutter(self, line, x, y, gpad and gw - gpad or gw)

  if not changedLines[line] then
    return
  end

  local color = g.colourForChange(changedLines[line])

  -- add margin in between highlight and text
  x = x + g.padding(self)

  local yoffset = self:get_line_text_y_offset()
  if "deletion" ~= changedLines[line] then
    renderer.draw_rect(x, y + yoffset, style.gitdiff_width,
        self:get_line_height(), color)

    return
  end

  renderer.draw_rect(x - style.gitdiff_width * 2,
      y + yoffset, style.gitdiff_width * 4, 2, color)

  return lh
end -- DocView:draw_line_gutter


-------------       DOC OVERRIDES      -------------


local doc_on_text_change = Doc.on_text_change
function g.on_text_change(doc)
  doc.git_____last_doc_lines = #doc.lines
  return doc_on_text_change(doc, type)
end
-- Fired when text in document has changed
---@param type string
---@return nothing
function Doc:on_text_change(type)
  local changedLines = g.getChangedLines(self.abs_filename)
  if not changedLines then return g.on_text_change(self) end

  -- TODO: test multi selection changes
  local line = self:get_selection()
  if "addition" == changedLines[line] then return g.on_text_change(self) end
  -- TODO figure out how to detect an addition

  local last_doc_lines = self.git_____last_doc_lines or 0
  if "insert" == type
    or ("remove" == type and #self.lines == last_doc_lines)
  then
    changedLines[line] = "modification"
  elseif "remove" == type then
    changedLines[line] = "deletion"
  end
  return g.on_text_change(self)
end -- Doc:on_text_change


local doc_save = Doc.save
function Doc:save(...)
  doc_save(self, ...)
  -- TODO: fix this hack so it works even if no autoscan is active
  if g.bFirstScanComplete then
    core.add_thread(g.a.updateDoc, nil, self.abs_filename)
  end
end -- Doc.save


local doc_load = Doc.load
function Doc:load(...)
  doc_load(self, ...)
  self.git_____last_doc_lines = #self.lines
  -- TODO: fix this hack so it works even if no autoscan is active
  if g.bFirstScanComplete then
    core.add_thread(g.a.updateDoc, nil, self.abs_filename)
  end
end


-------------     DEFERRED LOADING     -------------
------------- DEPENDENCIES / ADDITIONS -------------


-------------         STATUSVIEW       -------------

-- add status bar info after all plugins have loaded
function g.d.status()
  if not config.plugins.git____.use_status
    or not core.status_view
  then return end

  function g.toggleStatusStats()
    config.plugins.git____.status_shows_repo_stats =
        not config.plugins.git____.status_shows_repo_stats
  end
  command.add("core.docview", {
    ["git____:toggle-status-shows-repository-statistics"] = g.toggleStatusStats
  })

  local StatusView = require "core.statusview"
  core.status_view:add_item({
    name = "git____:status",
    predicate = function()
      return  core.active_view:is(DocView)
        and g.tFiles[core.active_view.doc.abs_filename]
        and true
    end,
    command = "git____:toggle-status-shows-repository-statistics",
    alignment = StatusView.Item.RIGHT,
    get_item = function()
      local f = g.tFiles[core.active_view.doc.abs_filename]
      local r = g.getRepo(f.base)
      local l = {}
      local me = core.status_view:get_item('git____:status')

      if config.plugins.git____.status_shows_repo_stats then
        me.tooltip = string.format('%s +%d / -%d',
            g.ellipsis(r.branch, 66, false), f.additions, f.deletions)

        if config.plugins.git____.status_shows_branch then
          l = {
            (0 < r.additions + r.deletions) and style.accent or style.text,
            g.ellipsis(r.branch, 9, false),
            style.dim, "  ",
          }
        end
        -- ugh, ugly way to give a simple option to user :/
        table.insert(l, 0 < r.additions and style.accent or style.text)
        table.insert(l, "Total: +")
        table.insert(l, r.additions)
        table.insert(l, style.dim)
        table.insert(l, " / ")
        table.insert(l, 0 < r.deletions and style.accent or style.text)
        table.insert(l, "-")
        table.insert(l, r.deletions)
      else
        me.tooltip = string.format('%s Total: +%d / -%d',
            g.ellipsis(r.branch, 66, false), r.additions, r.deletions)

        if config.plugins.git____.status_shows_branch then
          l = {
            (0 < f.additions + f.deletions) and style.accent or style.text,
            g.ellipsis(r.branch, 9, false),
            style.dim, "  ",
          }
        end
        -- ugh, ugly way to give a simple option to user :/
        table.insert(l, 0 < f.additions and style.accent or style.text)
        table.insert(l, "+")
        table.insert(l, f.additions)
        table.insert(l, style.dim)
        table.insert(l, " / ")
        table.insert(l, 0 < f.deletions and style.accent or style.text)
        table.insert(l, "-")
        table.insert(l, f.deletions)
      end
      return l
    end,
    position = -1,
    tooltip = "git____",
    separator = core.status_view.separator2
  })
end
core.add_thread(g.d.status)


-------------          TREEVIEW        -------------


-- add treeview info after all plugins have loaded
function g.d.treeview()
  if not config.plugins.git____.use_treeview
    or false == config.plugins.treeview
  then return end

  -- abort if TreeView isn't installed
  local found, TreeView = pcall(require, "plugins.treeview")
  if not found then return end

  local treeview_get_item_text = TreeView.get_item_text
  function TreeView:get_item_text(item, active, hovered)
    local text, font, color = treeview_get_item_text(self, item, active, hovered)
    if g.tColours[item.abs_filename] then
      color = g.tColours[item.abs_filename]
    end
    return text, font, color
  end
end
core.add_thread(g.d.treeview)


-------------          MINIMAP         -------------


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
    local changedLines = g.getChangedLines(core.active_view.doc.abs_filename)
    if changedLines and changedLines[line] then
      return g.colourForChange(changedLines[line])
    end
    return minimap_line_highlight_color(self, line)
  end
end
core.add_thread(g.d.minimap)


return g

