--- Window manager.
--
-- Exposes the small high-level API described in the spec:
--   capture(window)          -- gather all state before minimizing
--   tuck(window, edge)       -- coordinate state creation, minimize, shelf
--                                insertion, card creation, and reflow
--   restore(tuckedWindow)    -- THE single restore path (card click,
--                                keyboard search, and reconciliation all
--                                converge here)
--   forget(tuckedWindow)     -- safely remove state/card/shelf membership
--                                without touching the real window
--
-- HOW A WINDOW IS HIDDEN (why there are two mechanisms)
--   The user-facing goal is Cmd+H-style hiding. macOS/Hammerspoon only
--   expose hiding at APPLICATION level (hs.application:hide()/:unhide();
--   there is no per-window hide in hs.window or the Accessibility API),
--   and an unhide reveals every un-minimized window of that app. Tuck's
--   model is one record per WINDOW, so app-wide hiding is only used
--   where it is exactly equivalent to hiding that one window:
--
--     mechanism "hide"     - the window is the ONLY non-minimized window
--                            of its app (on any Space) AND the app has no
--                            other tuck record. Hide/unhide then affects
--                            exactly this one window.
--     mechanism "minimize" - otherwise. Minimizing is truly per-window, so
--                            sibling windows are never hidden or revealed
--                            as a side effect.
--
--   The mechanism is stored on the record; restore() reverses precisely
--   what tuck() did. Invariant: a hide-tucked window is always the ONLY
--   tuck record of its application, so an app-level unhide can never
--   reveal a window that is still supposed to be tucked, and restoring a
--   minimized sibling never needs the app to be unhidden.
--
-- FOCUS AFTER A TUCK (ported from MinimizeToPrevious.spoon)
--   MinimizeToPrevious does not let macOS choose what comes to the front
--   after a window leaves the screen: it finds the previous window,
--   focuses it FIRST, and only then minimizes the target. Tuck does the
--   same. Before anything is hidden it picks the window that was focused
--   immediately before the one being tucked and focuses that exact window
--   (never the application's "main window", never an app-wide activate),
--   then hides the target. Because the previous window is already
--   frontmost when the target disappears, macOS has nothing left to
--   choose. With no valid previous window focus is simply left alone.
--
--   "Previous" comes from two sources, both by exact window identity:
--     1. window/focus_history.lua, fed by windowFocused events. Those
--        events exist only while the tracker runs, i.e. while at least
--        one window is tucked (an idle Spoon has no window filter);
--     2. otherwise (the very first tuck, before any tracker exists) the
--        window directly behind the target in hs.window.orderedWindows():
--        macOS keeps that list in focus-recency order, so index 2 is the
--        window focused before the current one. One enumeration, at tuck
--        time only, never polled.
--
-- UNRELATED WINDOWS ARE NEVER TOUCHED
--   tuck() writes no frame at all. restore() writes the saved frame to
--   exactly one window: the record's own, after checking it still belongs
--   to the recorded process. Focusing never uses an app-wide "activate all
--   windows" (hs.application:activate(true) raises EVERY window of the
--   app, reshuffling windows the user never asked about).
--
-- Also owns the internal-restore guards that distinguish a Spoon-
-- initiated unminimize/unhide from a manual one (spec: "do not rely only on
-- arbitrary time delays or sleeps to guess which unminimize caused the
-- event" -- we use an explicit guard keyed by windowID, with only a
-- generous safety-net timer to prevent a permanent leak if an expected
-- event never arrives for some external reason).

local WindowManager = {}
WindowManager.__index = WindowManager

-- Safety-net duration for the internal-restore guard: if we ask macOS to
-- unminimize a window and, for whatever external reason, the expected
-- windowUnminimized event never arrives, this ensures the guard flag
-- cannot leak forever and silently swallow a later *manual* unminimize
-- of a window that happens to reuse the same windowID (exceedingly
-- unlikely in practice, but cheap to guard against).
local RESTORE_GUARD_SAFETY_NET_SECONDS = 3

function WindowManager.new(hsRef, store, cardManager, spaceManager, previewManager, logger, config, focusHistory)
  local self = setmetatable({}, WindowManager)
  self.hs = hsRef
  self.store = store
  self.cardManager = cardManager
  self.spaceManager = spaceManager
  self.previewManager = previewManager
  self.logger = logger
  self.config = config
  self.focusHistory = focusHistory

  self.restoring = {} -- windowID -> true while an internally-initiated unminimize is in flight
  self.hideRestoring = {} -- appKey -> true while an internally-initiated unhide is in flight
  -- Set by init.lua: function() -> array of every known hs.window (all Spaces).
  self.listWindows = nil
  -- Set by init.lua: function() invoked whenever persistent state changed
  -- (tuck created, tuck ended, window destroyed, ...). Coalescing is the
  -- receiver's job.
  self.onStateChanged = nil
  self.guardTimers = {} -- live safety-net timers, so stop() can cancel them
  -- Set by init.lua: function() -> true while windowFocused events are
  -- being delivered (the tracker is running). nil = assume yes.
  self.focusEventsActive = nil

  return self
end

--- Is `windowID` an appropriate focus target: it still exists, is
-- currently visible (not minimized, not part of a hidden application --
-- focusing either would have unwanted side effects, like silently
-- un-minimizing an unrelated window), is NOT itself a currently tucked
-- window, and lives on a Space that is currently showing (focusing a
-- window on an inactive Space would yank the user to that Space).
function WindowManager:_isValidFocusTarget(windowID)
  if windowID == nil then
    return false
  end
  if self.store:getByWindowID(windowID) ~= nil then
    return false
  end
  local ok, win = pcall(function()
    return self.hs.window.get(windowID)
  end)
  if not ok or not win then
    return false
  end
  local okVis, visible = pcall(function()
    return win:isVisible()
  end)
  if not okVis or visible ~= true then
    return false
  end
  return self:_isOnActiveSpace(win)
end

--- True unless the window is known to be on a Space that is not showing.
-- hs.spaces is experimental, so any failure to query it means "unknown",
-- which does not disqualify the window.
function WindowManager:_isOnActiveSpace(win)
  local okSpaces, spaces = pcall(function()
    return self.hs.spaces.windowSpaces(win)
  end)
  if not okSpaces or type(spaces) ~= "table" or #spaces == 0 then
    return true
  end
  local okActive, active = pcall(function()
    return self.hs.spaces.activeSpaces()
  end)
  if not okActive or type(active) ~= "table" then
    return true
  end
  for _, sid in ipairs(spaces) do
    for _, activeID in pairs(active) do
      if activeID == sid then
        return true
      end
    end
  end
  return false
end

--- The window to refocus when `capture`'s window is tucked, as
-- (hs.window, windowID) -- or nil when there is no valid previous window.
--   1. the window focused immediately before it, per focus history;
--   2. else the next visible standard window behind it in the
--      front-to-back order,
--      (macOS orders windows by focus recency, so that IS the previously
--      focused window; see "FOCUS AFTER A TUCK" at the top of this file).
function WindowManager:_choosePreviousWindow(capture)
  if self.focusHistory then
    local id = self.focusHistory:previousWindowID(capture.windowID, function(candidate)
      return self:_isValidFocusTarget(candidate)
    end)
    if id ~= nil then
      local ok, win = pcall(function()
        return self.hs.window.get(id)
      end)
      if ok and win then
        return win, id
      end
    end
  end

  -- No usable history: the window directly behind the target in the
  -- front-to-back (focus-recency) order. Standard windows only.
  local okList, ordered = pcall(function()
    return self.hs.window.orderedWindows()
  end)
  if not okList or type(ordered) ~= "table" then
    return nil
  end
  local targetIndex
  for i, w in ipairs(ordered) do
    local okID, wid = pcall(function()
      return w:id()
    end)
    if okID and wid == capture.windowID then
      targetIndex = i
      break
    end
  end
  if not targetIndex then
    return nil
  end
  for i = targetIndex + 1, #ordered do
    local w = ordered[i]
    local okID, wid = pcall(function()
      return w:id()
    end)
    if okID and wid ~= nil and self:_isValidFocusTarget(wid) then
      local okStd, standard = pcall(function()
        return w:isStandard()
      end)
      if okStd and standard then
        return w, wid
      end
    end
  end
  return nil
end

--- Run `fn` once after `seconds`, tracked so stop() can cancel it.
function WindowManager:_guardAfter(seconds, fn)
  local handle
  handle = self.hs.timer.doAfter(seconds, function()
    self.guardTimers[handle] = nil
    fn()
  end)
  self.guardTimers[handle] = true
  return handle
end

--- Cancel every pending safety-net timer (Spoon stop).
function WindowManager:stop()
  for handle in pairs(self.guardTimers) do
    pcall(function()
      handle:stop()
    end)
  end
  self.guardTimers = {}
  self.restoring = {}
  self.hideRestoring = {}
end

function WindowManager:_notifyStateChanged()
  if self.onStateChanged then
    self.onStateChanged()
  end
end

--- Bring `win` (with known `windowID`) to the front and focus it,
-- recording the resulting state in focus history WITHOUT depending on
-- the OS's own focus-changed event (see window/focus_history.lua). This
-- is the one place Tuck ever calls window:focus() -- used both to
-- restore a tucked window and to return focus to whichever window was
-- focused immediately before the one just tucked.
function WindowManager:_focusExactWindow(win, windowID)
  local events = self.focusEventsActive == nil or self.focusEventsActive()
  if self.focusHistory and events then
    self.focusHistory:suppressNextFocus(windowID)
  end
  local ok, err = pcall(function()
    -- Activate the application WITHOUT bringing all of its windows
    -- forward (activate(true) would raise every sibling window), then
    -- raise/focus exactly this window.
    local okApp, app = pcall(function()
      return win:application()
    end)
    if okApp and app then
      app:activate()
    end
    win:raise()
    win:focus()
  end)
  if ok then
    if self.focusHistory then
      self.focusHistory:record(windowID)
      if events then
        -- Safety net: if the OS never delivers the focus event we
        -- expected (e.g. the window was already frontmost), the
        -- suppression must not linger and swallow a later, genuine focus
        -- change. One-shot, only while events are being tracked.
        local history = self.focusHistory
        self:_guardAfter(RESTORE_GUARD_SAFETY_NET_SECONDS, function()
          history:clearSuppression(windowID)
        end)
      end
    end
  else
    if self.focusHistory then
      self.focusHistory:clearSuppression(windowID)
    end
  end
  return ok, err
end

function WindowManager:_feedback(message)
  if self.logger then
    self.logger.i("Tuck: " .. message)
  end
  local ok = pcall(function()
    self.hs.alert.show(message, 1.2)
  end)
  if not ok and self.logger then
    self.logger.d("Tuck: hs.alert unavailable for feedback message")
  end
end

--- Is `window` eligible to be tucked? Returns true, or false + a
-- human-readable reason. Uses only documented Hammerspoon eligibility
-- properties (isStandard()) plus the spec's own All-Spaces rule; never
-- maintains a hardcoded per-application blacklist.
function WindowManager:isEligible(window)
  if not window then
    return false, "no focused window"
  end

  local ok, standard = pcall(function()
    return window:isStandard()
  end)
  if not ok then
    return false, "could not determine window eligibility"
  end
  if not standard then
    return false, "window is not a standard application window"
  end

  local okMin, minimized = pcall(function()
    return window:isMinimized()
  end)
  if okMin and minimized then
    return false, "window is already minimized"
  end

  -- All Spaces rejection. hs.spaces is documented as relying on private
  -- APIs; we treat any failure to query it as "cannot verify, so do not
  -- reject" (fail open on the query, never silently mis-tuck though --
  -- see below) but treat a window reported on more than one Space as
  -- unsupported, per spec.
  local okSpaces, spaces = pcall(function()
    return self.hs.spaces.windowSpaces(window)
  end)
  if okSpaces and type(spaces) == "table" and #spaces > 1 then
    return false, "window is assigned to All Spaces, which is unsupported"
  end

  return true
end

--- Gather all state needed to tuck `window`, WITHOUT minimizing it or
-- creating any registry state. Returns a plain capture table, or nil +
-- reason on ineligibility/failure. Order matches the spec: frame, app
-- metadata, icon identity, thumbnail (if enabled/permitted), Space,
-- screen.
function WindowManager:capture(window)
  local eligible, reason = self:isEligible(window)
  if not eligible then
    return nil, reason
  end

  local windowID = window:id()
  if windowID == nil then
    return nil, "window has no id"
  end
  if self.store:getByWindowID(windowID) then
    return nil, "window is already tucked"
  end

  local okFrame, frame = pcall(function()
    return window:frame()
  end)
  if not okFrame or not frame then
    return nil, "could not capture window frame"
  end

  local app = nil
  local okApp
  okApp, app = pcall(function()
    return window:application()
  end)
  if not okApp then
    app = nil
  end

  local appName = nil
  if app then
    local okName, name = pcall(function()
      return app:name()
    end)
    if okName then
      appName = name
    end
  end

  local bundleID = nil
  if app then
    local okBundle, bid = pcall(function()
      return app:bundleID()
    end)
    if okBundle then
      bundleID = bid
    end
  end

  local pid = nil
  if app then
    local okPid, p = pcall(function()
      return app:pid()
    end)
    if okPid then
      pid = p
    end
  end

  local okTitle, title = pcall(function()
    return window:title()
  end)
  if not okTitle then
    title = nil
  end

  local okScreen, screen = pcall(function()
    return window:screen()
  end)
  if not okScreen or not screen then
    return nil, "could not determine window's screen"
  end
  local screenUUID = screen:getUUID()
  if not screenUUID then
    return nil, "could not determine screen identity"
  end

  local spaceID = self.spaceManager:currentSpaceID(screen)
  if spaceID == nil then
    return nil, "could not determine current Space"
  end

  local thumbnail = nil
  if self.config.card.showThumbnail then
    thumbnail = self.previewManager:capture(window, true, self.config.card)
  end

  return {
    windowID = windowID,
    frame = { x = frame.x, y = frame.y, w = frame.w, h = frame.h },
    appName = appName,
    bundleID = bundleID,
    pid = pid,
    appObject = app, -- transient: used by tuck() only, never stored on the record
    title = title,
    screenUUID = screenUUID,
    spaceID = spaceID,
    thumbnail = thumbnail,
  }
end

--- Identity used to key app-level guards: pid when known, else bundle ID.
local function appKey(pid, bundleID)
  return pid or bundleID
end

--- Records currently hidden via app-level hide for this app.
function WindowManager:_hideTuckedRecordsFor(pid, bundleID)
  local out = {}
  for _, rec in ipairs(self.store:allWindows()) do
    if rec.mechanism == "hide" and appKey(rec.pid, rec.bundleID) == appKey(pid, bundleID) then
      out[#out + 1] = rec
    end
  end
  return out
end

--- Any tuck record (either mechanism) for this app.
function WindowManager:_recordsForApp(pid, bundleID)
  local out = {}
  for _, rec in ipairs(self.store:allWindows()) do
    if appKey(rec.pid, rec.bundleID) == appKey(pid, bundleID) then
      out[#out + 1] = rec
    end
  end
  return out
end

--- Number of OTHER windows of the app that are not minimized, on ANY
-- Space. App-level hiding would hide all of them, so any such window
-- rules hiding out. Returns nil when the answer cannot be determined
-- (callers must then assume it is unsafe).
--
-- Enumeration prefers the window filter (sees every Space) via
-- `self.listWindows`; hs.application:allWindows() only sees the current
-- Space and is used solely as a fallback.
function WindowManager:_countOtherLiveWindows(capture)
  local list
  if self.listWindows then
    local ok, l = pcall(self.listWindows)
    if ok and type(l) == "table" then
      list = l
    end
  end
  if not list and capture.appObject then
    local ok, l = pcall(function()
      return capture.appObject:allWindows()
    end)
    if ok and type(l) == "table" then
      list = l
    end
  end
  if not list then
    return nil
  end
  local n = 0
  for _, w in ipairs(list) do
    local okID, wid = pcall(function()
      return w:id()
    end)
    if okID and wid ~= capture.windowID then
      local okApp, wapp = pcall(function()
        return w:application()
      end)
      local samePid, sameBundle = false, false
      if okApp and wapp then
        local okP, wp = pcall(function()
          return wapp:pid()
        end)
        samePid = okP and capture.pid ~= nil and wp == capture.pid
        if capture.pid == nil then
          local okB, wb = pcall(function()
            return wapp:bundleID()
          end)
          sameBundle = okB and wb ~= nil and wb == capture.bundleID
        end
      end
      if samePid or sameBundle then
        local okMin, minimized = pcall(function()
          return w:isMinimized()
        end)
        if not okMin or not minimized then
          n = n + 1
        end
      end
    end
  end
  return n
end

--- Choose how to take `capture`'s window out of view. Returns "hide"
-- only when app-level hiding is exactly equivalent to hiding this one
-- window: it is the app's only non-minimized window (on any Space) and
-- the app has no other tuck record. Otherwise "minimize".
function WindowManager:_chooseMechanism(capture)
  if not capture.appObject or not (capture.pid or capture.bundleID) then
    return "minimize"
  end
  if #self:_recordsForApp(capture.pid, capture.bundleID) > 0 then
    return "minimize"
  end
  local others = self:_countOtherLiveWindows(capture)
  if others == nil or others > 0 then
    return "minimize"
  end
  return "hide"
end

--- Find the live hs.window for a record. hs.window.get() is tried first;
-- if it cannot see the (hidden) window, fall back to the owning
-- application's window list, matched by the stored windowID -- never by
-- app name or "main window".
function WindowManager:_resolveWindow(record)
  local hs = self.hs
  local okGet, win = pcall(function()
    return hs.window.get(record.windowID)
  end)
  if okGet and win then
    return win
  end
  if record.pid then
    local okApp, app = pcall(function()
      return hs.application.applicationForPID(record.pid)
    end)
    if okApp and app then
      local okWins, wins = pcall(function()
        return app:allWindows()
      end)
      if okWins and type(wins) == "table" then
        for _, w in ipairs(wins) do
          local okID, wid = pcall(function()
            return w:id()
          end)
          if okID and wid == record.windowID then
            return w
          end
        end
      end
    end
  end
  return nil
end

--- Tuck `window` into `edge` ("left"|"right"|"top"|"bottom"). Returns
-- true on success, or false + reason. This is the single entry point
-- used by the direction-selection flow.
function WindowManager:tuck(window, edge)
  local capture, reason = self:capture(window)
  if not capture then
    if reason then
      self:_feedback("Can't tuck: " .. reason)
    end
    return false, reason
  end

  local tuckID = self.store:nextTuckID()
  local record = {
    tuckID = tuckID,
    windowID = capture.windowID,
    bundleID = capture.bundleID,
    appName = capture.appName or "Unknown",
    windowTitle = capture.title,
    frame = capture.frame,
    screenUUID = capture.screenUUID,
    spaceID = capture.spaceID,
    edge = edge,
    order = 0,
    thumbnail = capture.thumbnail,
    state = "tucked",
  }

  local mechanism = self:_chooseMechanism(capture)
  record.mechanism = mechanism
  record.pid = capture.pid

  -- MinimizeToPrevious order: decide the previous window and focus it
  -- BEFORE hiding the current one, so macOS never gets to pick (and
  -- activate) an arbitrary window when the current one disappears. The
  -- thumbnail and every other piece of state were captured above, while
  -- the window was still on screen (a hidden window cannot be captured).
  local previousWindow, previousWindowID = self:_choosePreviousWindow(capture)
  if previousWindow then
    local okFocusPrev, focusPrevErr = self:_focusExactWindow(previousWindow, previousWindowID)
    if not okFocusPrev then
      if self.logger then
        self.logger.w("Tuck: could not focus the previous window before tucking: " .. tostring(focusPrevErr))
      end
      previousWindow = nil
    end
  end

  local okHide, err = pcall(function()
    if mechanism == "hide" then
      local ret = capture.appObject:hide()
      -- Some apps report false even when hide worked (see Hammerspoon
      -- issue #3580), so the return value is deliberately not trusted.
      return ret
    end
    window:minimize()
  end)
  if not okHide then
    -- Hiding failed: never create state for a window that was not
    -- actually hidden (never leave the model believing it was tucked).
    -- Put focus back where it was, since we moved it ahead of the hide.
    if previousWindow then
      self:_focusExactWindow(window, capture.windowID)
    end
    self:_feedback("Tuck failed: could not hide window (" .. tostring(err) .. ")")
    return false, err
  end

  -- Recovery: if anything below fails, the window is already minimized
  -- by macOS but we may not have a card. We still commit the state
  -- record FIRST (before creating the card), so that even if card
  -- creation throws, the window remains recoverable via keyboard search
  -- / a future reconciliation pass rather than becoming an orphaned
  -- minimized window with no Tuck record at all.
  self.store:addWindow(record)

  local okCard, cardErr = pcall(function()
    self.cardManager:reflowRail(record.screenUUID, record.spaceID, record.edge)
  end)
  if not okCard then
    if self.logger then
      self.logger.e("Tuck: card creation failed after minimize; window remains tucked in the registry: " .. tostring(cardErr))
    end
    self:_feedback("Tucked " .. record.appName .. " (card display had a problem, but it can still be restored by name)")
  end

  if self.focusHistory then
    -- The just-tucked window can never be a valid "previous window" for
    -- a future tuck while it remains hidden.
    self.focusHistory:forget(record.windowID)
  end

  self:_notifyStateChanged()
  return true
end

--- Does `win` still belong to the process recorded for `record`? Unknown
-- (no recorded pid / no readable pid) counts as belonging, so a quirky
-- application cannot make restore fail; a KNOWN mismatch does not.
function WindowManager:_belongsToRecord(win, record)
  if not record.pid then
    return true
  end
  local okApp, app = pcall(function()
    return win:application()
  end)
  if not okApp or not app then
    return true
  end
  local okPid, pid = pcall(function()
    return app:pid()
  end)
  if not okPid or pid == nil then
    return true
  end
  return pid == record.pid
end

--- THE single restore implementation. Accepts either a tuckID (string)
-- or an already-resolved TuckedWindow record. Every restore path (card
-- click, keyboard search, reconciliation) must call this.
--
-- Reverses exactly the mechanism tuck() used (record.mechanism), then
-- brings THIS window (by windowID, never by app/bundle/"main window") to
-- the front, restores its saved frame, and removes the tuck state.
function WindowManager:restore(tuckIDOrRecord)
  local record
  if type(tuckIDOrRecord) == "table" then
    record = tuckIDOrRecord
  else
    record = self.store:getByTuckID(tuckIDOrRecord)
  end
  if not record then
    -- Already restored/removed by another path (e.g. a click racing a
    -- keyboard restore of the same card): safe no-op.
    return false, "no such tuck record"
  end

  local hs = self.hs
  local windowID = record.windowID
  local win = self:_resolveWindow(record)
  if not win then
    -- Gone without a destroy event (edge case): clean up rather than
    -- leave an orphaned card/record.
    self:forget(record)
    return false, "window no longer exists"
  end

  local app = nil
  if record.mechanism == "hide" then
    local okApp, a = pcall(function()
      return win:application()
    end)
    if okApp then
      app = a
    end
    if not app and record.pid then
      local okPid, a2 = pcall(function()
        return hs.application.applicationForPID(record.pid)
      end)
      if okPid then
        app = a2
      end
    end
    if not app then
      self:_feedback("Failed to restore " .. tostring(record.appName) .. ": application not found")
      return false, "application not found"
    end

    local key = appKey(record.pid, record.bundleID)
    self.hideRestoring[key] = true
    self:_guardAfter(RESTORE_GUARD_SAFETY_NET_SECONDS, function()
      self.hideRestoring[key] = nil
    end)
    local okUnhide, unhideErr = pcall(function()
      app:unhide()
    end)
    if not okUnhide then
      self.hideRestoring[key] = nil
      self:_feedback("Failed to restore " .. tostring(record.appName) .. ": " .. tostring(unhideErr))
      return false, unhideErr
    end
  else
    self.restoring[windowID] = true
    self:_guardAfter(RESTORE_GUARD_SAFETY_NET_SECONDS, function()
      self.restoring[windowID] = nil
    end)
    local okUnmin, unminErr = pcall(function()
      win:unminimize()
    end)
    if not okUnmin then
      self.restoring[windowID] = nil
      self:_feedback("Failed to restore " .. tostring(record.appName) .. ": " .. tostring(unminErr))
      return false, unminErr
    end
  end

  -- Exact saved frame, written to THIS record's window only, and only
  -- after confirming it still belongs to the recorded process (a frame is
  -- never written to a window we merely resolved by a possibly reused
  -- ID). Failure is logged only: the window is restored either way and a
  -- geometry hiccup must not corrupt state.
  if self:_belongsToRecord(win, record) then
    local okFrame, frameErr = pcall(function()
      win:setFrame(record.frame)
    end)
    if not okFrame and self.logger then
      self.logger.w("Tuck: could not restore exact frame for " .. tostring(record.appName) .. ": " .. tostring(frameErr))
    end
  elseif self.logger then
    self.logger.w("Tuck: resolved window no longer matches the tuck record for " .. tostring(record.appName) .. "; frame left untouched")
  end

  -- Front + focus THIS exact window (never "the app's main window").
  local okFocus, focusErr = self:_focusExactWindow(win, windowID)
  if not okFocus and self.logger then
    self.logger.w("Tuck: could not focus/raise restored window: " .. tostring(focusErr))
  end

  self:_cleanupRecord(record)
  return true
end

--- Remove state/card/shelf membership for `tuckIDOrRecord` WITHOUT
-- touching the real application window. Safe to call even if the
-- window/application is already gone.
function WindowManager:forget(tuckIDOrRecord)
  local record
  if type(tuckIDOrRecord) == "table" then
    record = tuckIDOrRecord
  else
    record = self.store:getByTuckID(tuckIDOrRecord)
  end
  if not record then
    return
  end
  self:_cleanupRecord(record)
end

--- Shared cleanup: remove from store, destroy card, reflow the rail.
-- Idempotent -- safe even if some of this has already happened.
-- `_cleanupRecord` is the shared tail of every path that ENDS a tuck:
-- a successful restore, a manual reveal, or the window being destroyed.
-- It must NOT forget the window from focus history on its own: for a
-- restore or manual reveal the window is visible/focusable again and
-- belongs in history (restore already :record()s it explicitly via
-- _focusExactWindow; a manual reveal's own genuine windowFocused event,
-- if any, will record it through the normal event path). Only the
-- "window is truly gone" callers (handleDestroyed, handleAppTerminated)
-- forget it themselves, directly, alongside calling this.
function WindowManager:_cleanupRecord(record)
  local removed = self.store:removeWindow(record.windowID)
  local tuckID = record.tuckID
  local screenUUID = record.screenUUID
  local spaceID = record.spaceID
  local edge = record.edge

  self.cardManager:destroy(tuckID)

  local okReflow, reflowErr = pcall(function()
    self.cardManager:reflowRail(screenUUID, spaceID, edge)
  end)
  if not okReflow and self.logger then
    self.logger.e("Tuck: reflow after cleanup failed: " .. tostring(reflowErr))
  end

  if removed then
    self:_notifyStateChanged()
  end
end

--- Called by the window tracker on a windowUnminimized event. Determines
-- whether this was a Spoon-initiated restore (in which case the guard
-- flag is simply cleared -- restore() already did the real cleanup) or a
-- manual user restore (in which case we honor it: remove our state/card
-- but do NOT re-minimize, re-focus, or re-position the window -- the
-- Spoon never fights a user's manual restoration).
function WindowManager:handleUnminimized(window)
  local ok, windowID = pcall(function()
    return window:id()
  end)
  if not ok or windowID == nil then
    return
  end
  if self.restoring[windowID] then
    -- Our own restore() call is already handling this exact record (the
    -- event may arrive before or after the record was removed).
    self.restoring[windowID] = nil
    return
  end
  local record = self.store:getByWindowID(windowID)
  if not record then
    return -- not a tracked tuck; nothing to do
  end

  if self.logger then
    self.logger.i("Tuck: manual unminimize detected for " .. tostring(record.appName) .. "; releasing tuck state")
  end
  self:_cleanupRecord(record)
end

--- Called by the window tracker on a windowDestroyed event. Idempotent
-- and safe even if the card/record no longer exists.
function WindowManager:handleDestroyed(window)
  local ok, windowID = pcall(function()
    return window:id()
  end)
  if not ok or windowID == nil then
    return
  end
  if self.focusHistory then
    self.focusHistory:forget(windowID)
  end
  local record = self.store:getByWindowID(windowID)
  if not record then
    return
  end
  if self.logger then
    self.logger.i("Tuck: tucked window destroyed (" .. tostring(record.appName) .. "); cleaning up")
  end
  self:_cleanupRecord(record)
end

--- Application-level unhide (tracker: hs.application.watcher "unhidden").
-- Only matters for a hide-tucked window of that app. If the unhide came
-- from our own restore() the guard is cleared; otherwise the user revealed
-- the app themselves, so the tuck is released WITHOUT re-hiding or
-- repositioning anything.
function WindowManager:handleAppUnhidden(app)
  local okPid, pid = pcall(function()
    return app:pid()
  end)
  local okBundle, bundleID = pcall(function()
    return app:bundleID()
  end)
  pid = okPid and pid or nil
  bundleID = okBundle and bundleID or nil
  if pid == nil and bundleID == nil then
    return
  end
  local key = appKey(pid, bundleID)
  -- Our own restore() sets this guard before unhiding. The event can
  -- arrive before OR after restore() has removed the record, so it is
  -- consumed here regardless of whether a record still exists (otherwise a
  -- stale guard could swallow a later, genuine manual unhide).
  if self.hideRestoring[key] then
    self.hideRestoring[key] = nil
    return
  end
  local records = self:_hideTuckedRecordsFor(pid, bundleID)
  if #records == 0 then
    return -- unrelated app
  end
  for _, record in ipairs(records) do
    if self.logger then
      self.logger.i("Tuck: manual unhide detected for " .. tostring(record.appName) .. "; releasing tuck state")
    end
    self:_cleanupRecord(record)
  end
end

--- Application-level hide. Hides initiated by tuck() are already fully
-- recorded synchronously; a hide the user performs themselves creates
-- no tuck (only the explicit shortcut flow ever creates one).
function WindowManager:handleAppHidden(_app)
end

--- The application quit: every record for it (either mechanism) is stale.
-- Normally each window's destroy event already removed its record; this
-- is the safety net that guarantees no orphaned cards.
function WindowManager:handleAppTerminated(app)
  local okPid, pid = pcall(function()
    return app:pid()
  end)
  local okBundle, bundleID = pcall(function()
    return app:bundleID()
  end)
  pid = okPid and pid or nil
  bundleID = okBundle and bundleID or nil
  local victims = {}
  for _, rec in ipairs(self.store:allWindows()) do
    if (pid ~= nil and rec.pid == pid) or (pid == nil and bundleID ~= nil and rec.bundleID == bundleID) then
      victims[#victims + 1] = rec
    end
  end
  for _, rec in ipairs(victims) do
    if self.focusHistory then
      self.focusHistory:forget(rec.windowID) -- the process is gone; this window no longer exists
    end
    self:_cleanupRecord(rec)
  end
  if pid or bundleID then
    self.hideRestoring[appKey(pid, bundleID)] = nil
  end
end

-- ---------------------------------------------------------------------
-- Startup reconciliation (persisted tucks -> real windows)
-- ---------------------------------------------------------------------

local FRAME_TOLERANCE = 2 -- pixels

local function framesClose(a, b)
  return a and b
    and math.abs(a.x - b.x) <= FRAME_TOLERANCE and math.abs(a.y - b.y) <= FRAME_TOLERANCE
    and math.abs(a.w - b.w) <= FRAME_TOLERANCE and math.abs(a.h - b.h) <= FRAME_TOLERANCE
end

local function safe(fn)
  local ok, v = pcall(fn)
  if ok then
    return v
  end
  return nil
end

--- The running application a persisted entry belongs to, or nil. The
-- process ID must still exist AND be the same application (bundle ID).
-- A changed process ID means the application was relaunched: its windows
-- are new windows, so the old record is stale -- never re-attached by
-- guesswork.
function WindowManager:_applicationForEntry(entry)
  if not entry.pid then
    return nil
  end
  local app = safe(function()
    return self.hs.application.applicationForPID(entry.pid)
  end)
  if not app then
    return nil
  end
  if entry.bundleID then
    local bundleID = safe(function()
      return app:bundleID()
    end)
    if bundleID ~= entry.bundleID then
      return nil
    end
  end
  return app
end

--- Does live window `w` correspond to the persisted metadata? The
-- window's title must match (when one was saved) or its frame must be the
-- saved frame -- a window's frame does not change while it is tucked.
local function metadataMatches(w, entry, requireBoth)
  local title = safe(function()
    return w:title()
  end)
  local frame = safe(function()
    return w:frame()
  end)
  local titleOK = (entry.windowTitle == nil and title == nil) or (entry.windowTitle ~= nil and title == entry.windowTitle)
  local frameOK = framesClose(frame, entry.frame)
  if requireBoth then
    return titleOK and frameOK
  end
  return titleOK or frameOK
end

--- Is the persisted window still in the state Tuck left it in?
function WindowManager:_stillTucked(entry, app, w)
  if entry.mechanism == "hide" then
    return safe(function()
      return app:isHidden()
    end) == true
  end
  return safe(function()
    return w:isMinimized()
  end) == true
end

--- Reconcile persisted entries (array from Persistence:load()) against the
-- real windows and rebuild runtime state for the ones that are still
-- tucked. Idempotent: an entry whose tuckID/windowID is already tracked
-- is skipped, so repeated calls never duplicate records or cards.
--
-- Per entry:
--   * window resolved and still hidden/minimized -> record, shelf slot and
--     card are rebuilt (parked); the window is NOT unhidden.
--   * window resolved but already visible        -> manually restored
--     while Tuck was not running: the record is dropped, the window is
--     left alone.
--   * application/window gone                    -> record dropped.
--   * several windows could be it and the right one cannot be determined
--     confidently                                 -> record dropped
--     ("quarantined"), nothing is hidden or attached.
-- A saved windowID is trusted only after the resolved window passes the
-- metadata check (same application, plus matching title or frame). When it
-- does not resolve, a window is matched by metadata only if exactly one
-- unclaimed window of that process matches title AND frame, is still in the
-- tucked state, and no other record competes for it.
--
-- `loadThumbnail(entry)` (optional) returns a cached hs.image or nil.
-- Returns a summary table of counts.
function WindowManager:reconcile(entries, loadThumbnail)
  local summary = { restored = 0, staleVisible = 0, gone = 0, ambiguous = 0, duplicate = 0 }
  local resolved = {} -- entry -> { win=, app= }
  local claimed = {} -- windowID -> entry that owns it
  local pending = {}

  -- Stage 1: verified resolution by saved windowID.
  for _, entry in ipairs(entries) do
    if self.store:getByTuckID(entry.tuckID) or self.store:getByWindowID(entry.windowID) then
      summary.duplicate = summary.duplicate + 1
    else
      local app = self:_applicationForEntry(entry)
      if not app then
        summary.gone = summary.gone + 1
        if self.logger then
          self.logger.d("Tuck: persisted tuck for " .. tostring(entry.appName) .. " dropped: application is gone")
        end
      else
        local wins = safe(function()
          return app:allWindows()
        end) or {}
        local found
        for _, w in ipairs(wins) do
          if safe(function()
            return w:id()
          end) == entry.windowID then
            found = w
            break
          end
        end
        if found and metadataMatches(found, entry, false) and not claimed[entry.windowID] then
          resolved[entry] = { win = found, app = app }
          claimed[entry.windowID] = entry
        else
          pending[#pending + 1] = { entry = entry, app = app, windows = wins }
        end
      end
    end
  end

  -- Stage 2: conservative metadata matching for entries whose saved
  -- windowID did not verify.
  local candidatesOf = {} -- pending item -> array of windows
  local claimCount = {} -- candidate windowID -> number of pending entries wanting it
  for _, item in ipairs(pending) do
    local list = {}
    for _, w in ipairs(item.windows) do
      local wid = safe(function()
        return w:id()
      end)
      if wid ~= nil and not claimed[wid] and metadataMatches(w, item.entry, true)
        and self:_stillTucked(item.entry, item.app, w) then
        list[#list + 1] = w
      end
    end
    candidatesOf[item] = list
    for _, w in ipairs(list) do
      local wid = w:id()
      claimCount[wid] = (claimCount[wid] or 0) + 1
    end
  end
  for _, item in ipairs(pending) do
    local list = candidatesOf[item]
    if #list == 1 and claimCount[list[1]:id()] == 1 then
      resolved[item.entry] = { win = list[1], app = item.app }
      claimed[list[1]:id()] = item.entry
    elseif #list == 0 then
      summary.gone = summary.gone + 1
      if self.logger then
        self.logger.d("Tuck: persisted tuck for " .. tostring(item.entry.appName) .. " dropped: no matching window")
      end
    else
      summary.ambiguous = summary.ambiguous + 1
      if self.logger then
        self.logger.w(string.format(
          "Tuck: persisted tuck for %s (%s) matches %d windows; not attaching it to any of them",
          tostring(item.entry.appName), tostring(item.entry.windowTitle), #list
        ))
      end
    end
  end

  -- Stage 3: rebuild runtime state, in persisted rail order.
  for _, entry in ipairs(entries) do
    local res = resolved[entry]
    if res then
      if not self:_stillTucked(entry, res.app, res.win) then
        summary.staleVisible = summary.staleVisible + 1
        if self.logger then
          self.logger.d("Tuck: persisted tuck for " .. tostring(entry.appName) .. " dropped: window is already visible")
        end
      else
        local windowID = safe(function()
          return res.win:id()
        end)
        local thumbnail = loadThumbnail and loadThumbnail(entry) or nil
        local record = {
          tuckID = entry.tuckID,
          windowID = windowID,
          pid = entry.pid,
          bundleID = entry.bundleID,
          appName = entry.appName,
          windowTitle = entry.windowTitle,
          frame = entry.frame,
          screenUUID = entry.screenUUID,
          spaceID = entry.spaceID,
          edge = entry.edge,
          order = entry.order,
          mechanism = entry.mechanism,
          thumbnail = thumbnail,
          thumbnailFile = thumbnail and entry.thumbnailFile or nil,
          state = "tucked",
        }
        self.store:addWindow(record)
        summary.restored = summary.restored + 1
      end
    end
  end

  -- Cards for every rebuilt record (all start parked: no hover/reveal
  -- state is ever restored).
  if summary.restored > 0 then
    local okCards, cardsErr = pcall(function()
      self.cardManager:reflowAll()
    end)
    if not okCards and self.logger then
      self.logger.e("Tuck: card reconstruction failed (records kept): " .. tostring(cardsErr))
    end
  end
  return summary
end

return WindowManager
