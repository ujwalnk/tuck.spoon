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
-- Also owns the internal-restore guard that distinguishes a Spoon-
-- initiated unminimize from a manual one (spec: "do not rely only on
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

function WindowManager.new(hsRef, store, cardManager, spaceManager, previewManager, logger, config)
  local self = setmetatable({}, WindowManager)
  self.hs = hsRef
  self.store = store
  self.cardManager = cardManager
  self.spaceManager = spaceManager
  self.previewManager = previewManager
  self.logger = logger
  self.config = config

  self.restoring = {} -- windowID -> true while an internally-initiated unminimize is in flight

  return self
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
    thumbnail = self.previewManager:capture(window, true)
  end

  return {
    windowID = windowID,
    frame = { x = frame.x, y = frame.y, w = frame.w, h = frame.h },
    appName = appName,
    bundleID = bundleID,
    title = title,
    screenUUID = screenUUID,
    spaceID = spaceID,
    thumbnail = thumbnail,
  }
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

  local okMinimize, err = pcall(function()
    window:minimize()
  end)
  if not okMinimize then
    -- Minimization failed: never create state for a window that was not
    -- actually minimized (spec: never leave the state model believing a
    -- window was tucked when minimizing actually failed).
    self:_feedback("Tuck failed: could not minimize window (" .. tostring(err) .. ")")
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

  return true
end

--- THE single restore implementation. Accepts either a tuckID (string)
-- or an already-resolved TuckedWindow record. Every restore path (card
-- click, keyboard search, reconciliation) must call this.
function WindowManager:restore(tuckIDOrRecord)
  local record
  if type(tuckIDOrRecord) == "table" then
    record = tuckIDOrRecord
  else
    record = self.store:getByTuckID(tuckIDOrRecord)
  end
  if not record then
    -- Nothing to do: already restored/removed by another path. Restore
    -- must be safe to call redundantly (e.g. a click racing a keyboard
    -- restore of the same card).
    return false, "no such tuck record"
  end

  local hs = self.hs
  local windowID = record.windowID
  local win = hs.window.get(windowID)

  if not win then
    -- The window is gone without us having seen a windowDestroyed
    -- event (edge case). Clean up defensively rather than leaving an
    -- orphaned card/record.
    self:forget(record)
    return false, "window no longer exists"
  end

  self.restoring[windowID] = true
  hs.timer.doAfter(RESTORE_GUARD_SAFETY_NET_SECONDS, function()
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

  -- Restore the exact saved frame. Tolerate failure (log only): the
  -- window is still meaningfully restored (unminimized) even if this
  -- step has trouble, and a UI/geometry error here must never re-corrupt
  -- the state model.
  local okFrame, frameErr = pcall(function()
    win:setFrame(record.frame)
  end)
  if not okFrame and self.logger then
    self.logger.w("Tuck: could not restore exact frame for " .. tostring(record.appName) .. ": " .. tostring(frameErr))
  end

  local okFocus, focusErr = pcall(function()
    win:focus()
    win:raise()
  end)
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
  local record = self.store:getByWindowID(windowID)
  if not record then
    return -- not a tracked tuck; nothing to do
  end

  if self.restoring[windowID] then
    -- Our own restore() call is already handling this exact record.
    self.restoring[windowID] = nil
    return
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
  local record = self.store:getByWindowID(windowID)
  if not record then
    return
  end
  if self.logger then
    self.logger.i("Tuck: tucked window destroyed (" .. tostring(record.appName) .. "); cleaning up")
  end
  self:_cleanupRecord(record)
end

return WindowManager
