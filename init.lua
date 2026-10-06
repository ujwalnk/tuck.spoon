--- === Tuck ===
---
--- A per-Space, per-screen "tuck shelf" for macOS application windows.
---
--- One shortcut (default Option+F3, a plain hs.hotkey) drives everything. Press it, then an arrow
--- key to tuck the focused window: it is hidden (Cmd+H style where that
--- is exactly per-window, minimized otherwise) and a small card parks
--- against the chosen screen edge. Press it, then letters, to search the
--- tucked applications by name and bring one back exactly where it was.
--- Clicking a card restores it too. Tucks are persisted beside the Spoon
--- (state.json) and rebuilt after a Hammerspoon restart.
---
--- Resource model: while idle (no tucks, no command) the Spoon owns only the
--- activation hotkey. Everything else -- keyboard capture, window/app/screen/
--- Space watchers, card and hover canvases, animation ticker, persistence
--- timer -- exists only while something needs it. See README.md / CLAUDE.md.

local obj = {}
obj.__index = obj

-- Metadata (standard Spoon fields).
obj.name = "Tuck"
obj.version = "1.0"
obj.author = "Tuck contributors"
obj.homepage = "https://github.com/"
obj.license = "MIT - https://opensource.org/licenses/MIT"

-- Resolve this Spoon's own directory and make its internal submodules
-- resolvable via ordinary `require("card.manager")`-style dotted paths
-- (Lua's require() translates '.' to the platform directory separator
-- when searching package.path, so this one prepended template is enough
-- for every submodule -- including submodules that themselves require()
-- sibling submodules, e.g. card/manager.lua requiring space/geometry).
-- Guarded so re-loading this Spoon (or loading it more than once) never
-- accumulates duplicate package.path entries.
obj.spoonPath = debug.getinfo(1, "S").source:sub(2):match("(.*/)")
local pathTemplate = obj.spoonPath .. "?.lua"
if not package.path:find(pathTemplate, 1, true) then
  package.path = pathTemplate .. ";" .. package.path
end

local ConfigDefaults = require("config.defaults")
local Shortcut = require("input.shortcut")
local InputStateMachine = require("input.state")
local Matcher = require("input.matcher")
local Store = require("state.store")
local Persistence = require("state.persistence")
local SpaceManager = require("space.manager")
local IconManager = require("card.icon")
local PreviewManager = require("card.preview")
local CardManager = require("card.manager")
local Tracker = require("window.tracker")
local WindowManager = require("window.manager")
local FocusHistory = require("window.focus_history")

--- Tuck:configure(overrides)
--- Method
--- Merge `overrides` onto the default configuration. Must be called
--- before :start() to take effect (call again + :stop()/:start() to
--- change configuration at runtime). Validates the merged result and
--- raises a clear error (via hs.logger) rather than starting with a
--- broken configuration.
function obj:configure(overrides)
  local merged = ConfigDefaults.merge(ConfigDefaults.defaults, overrides)
  local ok, err = ConfigDefaults.validate(merged)
  if not ok then
    if self.logger then
      self.logger.e("Tuck: invalid configuration: " .. tostring(err))
    end
    error("Tuck: invalid configuration: " .. tostring(err))
  end
  self.config = merged
  return self
end

function obj:init()
  self.logger = hs.logger.new("Tuck", "info")
  self.config = ConfigDefaults.deepcopy(ConfigDefaults.defaults)
  self._started = false
  return self
end

--- Set the logging level ("debug"|"info"|"warning"|"error").
function obj:setLogLevel(level)
  self.config.logging.level = level
  if self.logger then
    self.logger.setLogLevel(level)
  end
  return self
end

-- ---------------------------------------------------------------------
-- Internal wiring
-- ---------------------------------------------------------------------

--- Build every collaborator object. Safe to call once; :start() ensures
-- this only happens the first time (idempotent start).
function obj:_build()
  if self._built then
    return
  end

  self.store = Store.new()

  self.spaceManager = SpaceManager.new(hs, self.logger)
  self.iconManager = IconManager.new(hs, self.logger)
  self.previewManager = PreviewManager.new(hs, self.logger)
  self.cardManager = CardManager.new(hs, self.store, self.spaceManager, self.iconManager, self.logger, self.config)
  self.focusHistory = FocusHistory.new(self.config.input.focusHistorySize)
  self.windowManager = WindowManager.new(
    hs, self.store, self.cardManager, self.spaceManager, self.previewManager,
    self.logger, self.config, self.focusHistory
  )
  -- Every change to persistent state (tuck created/ended, window destroyed,
  -- ...) asks the persistence layer for one coalesced write. The layer is
  -- created in :start() from the then-current configuration.
  self.windowManager.onStateChanged = function()
    if self.persistence then
      self.persistence:schedule()
    end
    self:_syncResources()
  end
  self.tracker = Tracker.new(hs, self.logger)
  self.windowManager.focusEventsActive = function()
    return self.tracker:isRunning()
  end
  self.windowManager.listWindows = function()
    return self.tracker:allWindows()
  end
  self.shortcutManager = Shortcut.new(hs)
  self.shortcutManager:setLogger(self.logger)
  self.inputStateMachine = InputStateMachine.new()

  self.commandTimer = nil
  self.inputTap = nil

  -- Card clicks flow through the state machine too (so a click during an
  -- active keyboard search correctly cancels/collapses the search), then
  -- converge on the same dispatch table as every other input path.
  local this = self
  self.cardManager.onCardClicked = function(tuckID)
    local res = this.inputStateMachine:cardClicked(tuckID)
    this:_dispatch(res)
  end

  self.tracker.onUnminimized = function(window, _appName)
    this.windowManager:handleUnminimized(window)
  end
  self.tracker.onAppHidden = function(app, _appName)
    this.windowManager:handleAppHidden(app)
  end
  self.tracker.onAppUnhidden = function(app, _appName)
    this.windowManager:handleAppUnhidden(app)
  end
  self.tracker.onAppTerminated = function(app, _appName)
    this.windowManager:handleAppTerminated(app)
  end
  self.tracker.onFocused = function(window, _appName)
    local ok, windowID = pcall(function()
      return window:id()
    end)
    if ok then
      this.focusHistory:onWindowFocused(windowID)
    end
  end
  self.tracker.onDestroyed = function(window, _appName)
    this.windowManager:handleDestroyed(window)
  end

  self._built = true
end

--- Cancel the command timer. Idempotent.
function obj:_cancelTimers()
  if self.commandTimer then
    self.commandTimer:stop()
    self.commandTimer = nil
  end
end

--- (Re)start the single command timeout (shortcut accepted, and after
-- every accepted search letter). One-shot; exists only during a command.
function obj:_startCommandTimer()
  if self.commandTimer then
    self.commandTimer:stop()
  end
  local this = self
  self.commandTimer = hs.timer.doAfter(self.config.input.commandTimeout, function()
    this.commandTimer = nil
    this:_dispatch(this.inputStateMachine:timeoutFired())
  end)
end

--- Command mode begins: the temporary keyboard capture and the timeout
-- exist from here until _endCommand().
function obj:_beginCommand()
  self:_startCommandTimer()
  self:_ensureInputTap()
end

--- Command mode ended (tuck, restore, cancel, timeout, Esc, stop): every
-- temporary resource is destroyed immediately.
function obj:_endCommand()
  self:_cancelTimers()
  self:_teardownInputTap()
end

--- Candidate list for the current keyboard-search scope, honoring the
-- screenAndSpace vs space configuration. Physical card placement is
-- untouched by this -- it only affects which records are visible to the
-- matcher (spec: search scope and physical placement are separate).
function obj:_searchCandidates()
  local screenUUID, spaceID = self.spaceManager:currentShelfIdentity()
  if spaceID == nil then
    return {}
  end
  local records
  if self.config.search.scope == "space" then
    records = self.store:windowsForSpace(spaceID)
  else
    records = self.store:windowsForSpace(spaceID, screenUUID)
  end
  local out = {}
  for _, r in ipairs(records) do
    out[#out + 1] = { tuckID = r.tuckID, appName = r.appName or "" }
  end
  return out
end

function obj:_matchCandidates(query)
  return Matcher.match(self:_searchCandidates(), query)
end

--- Central dispatch: turns an input/state.lua instruction into concrete
-- action against the window/card managers. Every input path (shortcuts,
-- the temporary command-mode eventtap, and card clicks) funnels through here.
function obj:_dispatch(res)
  if not res or res.action == "none" then
    return
  elseif res.action == "startCommandTimer" then
    self:_beginCommand()
    -- Bring every tucked card fully on-screen while the command is open,
    -- so the user can see everything tucked before choosing an arrow or
    -- typing a search letter.
    self.cardManager:setCommandRevealActive(true)
  elseif res.action == "restartCommandTimer" then
    self:_startCommandTimer()
    local tuckIDs = {}
    for _, m in ipairs(res.matches or {}) do
      tuckIDs[#tuckIDs + 1] = m.tuckID
    end
    self.cardManager:setSearchMatches(tuckIDs)
  elseif res.action == "tuck" then
    self:_endCommand()
    self.cardManager:setCommandRevealActive(false)
    local win = hs.window.focusedWindow()
    self.windowManager:tuck(win, res.edge)
  elseif res.action == "restore" then
    self:_endCommand()
    self.cardManager:setCommandRevealActive(false)
    if res.collapseSearch then
      self.cardManager:clearSearchExpansion()
    end
    self.windowManager:restore(res.tuckID)
  elseif res.action == "cancel" then
    self:_endCommand()
    self.cardManager:setCommandRevealActive(false)
    if res.collapseSearch then
      self.cardManager:clearSearchExpansion()
    end
  end
end

-- ---------------------------------------------------------------------
-- Global keyboard handling for direction-selection / app-letter search
-- ---------------------------------------------------------------------

--- The TEMPORARY command-mode keyboard capture. Created when a command
-- starts (_beginCommand) and destroyed the moment it ends (_endCommand);
-- it never exists while idle. It only intercepts what the command uses:
-- arrows (to tuck, before any search letter), bare letters (to search)
-- and Esc. Every other key passes through untouched.
function obj:_ensureInputTap()
  if self.inputTap then
    return
  end
  local this = self
  self.inputTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(event)
    local sm = this.inputStateMachine
    if sm:current() == "idle" then
      return false
    end

    local keyCode = event:getKeyCode()
    local flags = event:getFlags()

    -- The keystroke that opened the command (the shared shortcut) must
    -- never be re-read as command input.
    local spec = this.config.shortcuts.tuck
    if keyCode == hs.keycodes.map[spec.key:lower()] and Shortcut._flagsMatch(flags, spec.mods or {}) then
      return false
    end

    if keyCode == hs.keycodes.map["escape"] then
      this:_dispatch(sm:escPressed())
      return true
    end

    -- Ignore key auto-repeat so a held letter cannot spam the search.
    local okRep, isRepeat = pcall(function()
      return event:getProperty(hs.eventtap.event.properties.keyboardEventAutorepeat)
    end)
    if okRep and isRepeat == 1 then
      return true
    end

    local arrowNames = {
      [hs.keycodes.map["left"]] = "Left",
      [hs.keycodes.map["right"]] = "Right",
      [hs.keycodes.map["up"]] = "Up",
      [hs.keycodes.map["down"]] = "Down",
    }
    local arrowName = arrowNames[keyCode]
    if arrowName then
      -- Arrows only ever tuck (never restore), and only before a search
      -- letter has been typed; during a search they pass through.
      if sm:isSearching() then
        return false
      end
      this:_dispatch(sm:arrowPressed(arrowName))
      return true
    end

    -- Letters: bare keys only (Shift is fine); Cmd/Alt/Ctrl combos are
    -- other shortcuts and are left alone.
    if flags.cmd or flags.alt or flags.ctrl then
      return false
    end
    local ok, chars = pcall(function()
      return event:getCharacters()
    end)
    if ok and type(chars) == "string" and chars:match("^[A-Za-z]$") then
      this:_dispatch(sm:letterPressed(chars, function(query)
        return this:_matchCandidates(query)
      end))
      return true
    end
    return false
  end)
  self.inputTap:start()
end

function obj:_teardownInputTap()
  if self.inputTap then
    self.inputTap:stop()
    self.inputTap = nil
  end
end

-- ---------------------------------------------------------------------
-- Space/screen change reconciliation
-- ---------------------------------------------------------------------

function obj:_onScreensChanged()
  -- Screen layout changed: recompute geometry for every shelf whose
  -- screen still exists. A disconnected screen's cards are left alone
  -- (space/manager and card/manager both tolerate a missing screen
  -- lookup) -- the underlying TuckedWindow records are never discarded
  -- just because their screen is temporarily gone.
  local ok, err = pcall(function()
    self.cardManager:reflowAll()
  end)
  if not ok and self.logger then
    self.logger.e("Tuck: error reconciling after screen change: " .. tostring(err))
  end
end

function obj:_onSpaceChanged()
  -- Cards are ordinary (non-canJoinAllSpaces) canvases, so macOS shows
  -- each only on its own Space and nothing needs repositioning. What can
  -- go stale is transient pointer state: a canvas on the Space we just
  -- left may never deliver its mouse-exit. Reset it (cards park; no
  -- record or persisted data is touched).
  local ok, err = pcall(function()
    self.cardManager:resetInteraction()
  end)
  if not ok and self.logger then
    self.logger.e("Tuck: error reconciling after Space change: " .. tostring(err))
  end
end

--- Start/stop everything that is only needed while windows are tucked.
-- Called whenever the set of tucks changes. Idempotent.
--   * tucks exist  -> window filter + application watcher (tracker) and
--                     the screen/Space watchers are running;
--   * no tucks     -> all of them are stopped, caches are released and the
--                     Spoon is back to "activation hotkey only".
function obj:_syncResources()
  if not self._started then
    return
  end
  if self.store:count() > 0 then
    if not self.tracker:isRunning() then
      self.tracker:start()
    end
    if not self.spaceManager:isRunning() then
      self.spaceManager:start(function()
        self:_onScreensChanged()
      end, function()
        self:_onSpaceChanged()
      end)
    end
  else
    self.tracker:stop()
    self.spaceManager:stop()
    self.focusHistory:clear()
    self.iconManager:clear()
    self.cardManager:releaseIdleResources()
  end
end

-- ---------------------------------------------------------------------
-- Public lifecycle
-- ---------------------------------------------------------------------

--- Where state.json lives: configured directory, else the Spoon's own
-- directory (derived from this file's location, never the working dir).
function obj:_stateDirectory()
  return self.config.persistence.directory or self.spoonPath
end

--- Load state.json and reconcile it against the real windows (see
-- window/manager.lua :reconcile), rebuilding records and parked cards for
-- tucks whose windows are still hidden, then persist the cleaned result.
-- Idempotent: already-tracked records are skipped.
function obj:_restorePersistedTucks()
  local pcfg = self.config.persistence
  self.persistence = Persistence.new(hs, self.logger, {
    directory = self:_stateDirectory(),
    enabled = pcfg.enabled,
    debounce = pcfg.debounce,
    persistThumbnails = pcfg.persistThumbnails,
  })
  self.persistence:bind(self.store, self.previewManager)

  if not pcfg.enabled then
    -- Without persistence a stop()/start() cycle keeps the in-memory
    -- records; just rebuild their cards.
    self.cardManager:reflowAll()
    self:_syncResources()
    return
  end

  local entries, status = self.persistence:load()
  local summary
  if status == "ok" then
    summary = self.windowManager:reconcile(entries, function(entry)
      return self.persistence:loadThumbnail(entry)
    end)
    self.logger.i(string.format(
      "Tuck: restored %d tuck(s) (%d already visible, %d gone, %d ambiguous dropped)",
      summary.restored, summary.staleVisible, summary.gone, summary.ambiguous
    ))
  end
  if status == "ok" or self.store:count() > 0 then
    self.persistence:flush() -- persist the reconciled (cleaned) state
  end
  self:_syncResources()
end

--- Tuck:start()
--- Method
--- Start the Spoon: bind the activation hotkey and rebuild any tucks saved
--- in state.json whose windows are still hidden. Nothing else is created
--- up front: watchers, hover canvases and keyboard capture appear only
--- when tucks exist / a command is active.
--- Idempotent -- calling this more than once has no additional effect.
function obj:start()
  if self._started then
    return self
  end

  local ok, err = ConfigDefaults.validate(self.config)
  if not ok then
    error("Tuck: cannot start with invalid configuration: " .. tostring(err))
  end

  self:_build()

  -- ONE shortcut: what follows it (arrow vs letter) decides tuck vs search.
  self.shortcutManager:bind(self.config.shortcuts.tuck, function()
    self:_dispatch(self.inputStateMachine:commandShortcutPressed())
  end)

  self._started = true -- before restore: _syncResources is a no-op otherwise
  self:_restorePersistedTucks()

  self.logger.i("Tuck: started")
  return self
end

--- Tuck:stop()
--- Method
--- Stop the Spoon: unbind the hotkey, stop the tracker/watchers, cancel
--- all timers, destroy every card canvas, and write the final state to
--- state.json. A later :start() rebuilds tucks and cards from that file
--- (reconciled against the real windows). Idempotent -- calling this on an already-stopped (or
--- never-started) Spoon is a harmless no-op.
function obj:stop()
  if not self._started then
    return self
  end

  self:_endCommand()

  if self.shortcutManager then
    self.shortcutManager:unbindAll()
  end
  if self.tracker then
    self.tracker:stop()
  end
  if self.spaceManager then
    self.spaceManager:stop()
  end
  if self.iconManager then
    self.iconManager:clear()
  end
  if self.windowManager then
    self.windowManager:stop()
  end
  if self.cardManager then
    self.cardManager:stop()
  end
  if self.inputStateMachine then
    self.inputStateMachine:reset()
  end

  -- Write the final state, then drop runtime records: while stopped the
  -- window tracker is not watching, so the next :start() rebuilds
  -- everything from state.json and reconciles it against reality.
  if self.persistence then
    if self.persistence.enabled then
      self.persistence:flush()
      self.store:clear()
    end
    self.persistence:stop()
  end
  if self.focusHistory then
    self.focusHistory:clear()
  end

  self._started = false
  if self.logger then
    self.logger.i("Tuck: stopped")
  end
  return self
end

--- Tuck:tuckFocusedWindow(edge)
--- Method
--- Programmatic convenience: tuck the currently focused window to
--- `edge` directly, bypassing the two-stage shortcut UI. Primarily
--- useful for scripting/testing.
function obj:tuckFocusedWindow(edge)
  self:_build()
  local win = hs.window.focusedWindow()
  return self.windowManager:tuck(win, edge)
end

--- Tuck:restoreByTuckID(tuckID)
--- Method
--- Programmatic convenience mirroring the card-click/keyboard-search
--- restore path.
function obj:restoreByTuckID(tuckID)
  self:_build()
  return self.windowManager:restore(tuckID)
end

return obj
