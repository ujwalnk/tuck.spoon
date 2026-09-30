--- Card manager.
--
-- Owns: create/destroy cards, positioning, hover and search-expanded
-- state, edge reveal, click handling. It does NOT own the application
-- window lifecycle.
--
-- VISUAL STATES
--   A card's target frame is decided from three inputs:
--     1. expanded  (hovered OR search-matched)  -> full expanded card,
--        anchored at the boundary-relative "anchor" frame, growing inward
--     2. rail revealed (pointer near the edge)  -> only `edgeRevealSize`
--        pixels of the card are inside the screen
--     3. otherwise parked                       -> only `peekSize` pixels
--   Steps 2/3 apply to rails with `peek = true` (left/right by default);
--   other rails keep the classic fully-visible resting position. Parking
--   and revealing only MOVE the card (its size never changes) and never
--   change its position along the rail, so neighbours never jump.
--
-- STABLE POINTER MODEL (no polling, no oscillation)
--   * One lightweight mouse-moved eventtap (running only while a peek rail
--     has cards) tests the pointer against each rail's trigger region.
--     A region is the edge strip `edgeTriggerSize` deep over the rail's
--     extent -- deeper than the revealed cards, so cards sliding inward
--     never move out from under the trigger.
--   * Each rail keeps a SET of pointer "sources" (its trigger region and
--     each hovered card). The rail is revealed while the set is non-empty.
--   * When the set becomes empty the rail retracts only after
--     `revealGraceDelay`; any re-entry in that window cancels it. Moving
--     between cards or between a card and the strip therefore never
--     flickers.
--   * Cards grow away from the pointer (inward), so expansion can never
--     cause the pointer to leave the card it just entered.
--
-- All motion goes through card/animator.lua (single ticker, time-based).

local geometry = require("space.geometry")
local Renderer = require("card.renderer")
local Animator = require("card.animator")

local CardManager = {}
CardManager.__index = CardManager

local TRIGGER_SPAN_PADDING = 24

local function railKeyOf(screenUUID, spaceID, edge)
  return tostring(screenUUID) .. "|" .. tostring(spaceID) .. "|" .. edge
end

function CardManager.new(hsRef, store, spaceManager, iconManager, logger, config)
  local self = setmetatable({}, CardManager)
  self.hs = hsRef
  self.store = store
  self.spaceManager = spaceManager
  self.iconManager = iconManager
  self.logger = logger
  self.config = config -- live reference

  self.animator = Animator.new(hsRef, logger)

  self.canvases = {} -- tuckID -> hs.canvas
  self.anchorFrames = {} -- tuckID -> fully-visible reference frame (expansion anchor)
  self.restFrames = {} -- tuckID -> resting (parked / revealed / full) frame
  self.hovered = {} -- tuckID -> true
  self.searchMatched = {} -- tuckID -> true

  self.railInfo = {} -- railKey -> { screenUUID, spaceID, edge }
  self.railRevealed = {} -- railKey -> true while edge-revealed
  self.railPointer = {} -- railKey -> { [sourceID] = true }
  self.retractTimers = {} -- railKey -> hs.timer (one-shot)
  self.railZones = {} -- railKey -> { frame = {..}, edge = ..., screenUUID, spaceID, inside = bool }
  self.moveTap = nil

  -- Set by init.lua: function(tuckID) -- invoked on card click.
  self.onCardClicked = nil
  return self
end

-- ---------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------

function CardManager:_peekEnabled(edge)
  local rail = self.config.rails[edge]
  return rail ~= nil and rail.peek == true
end

local function isExpanded(self, tuckID)
  return self.config.card.expansionEnabled and (self.hovered[tuckID] == true or self.searchMatched[tuckID] == true)
end

function CardManager:_duration(kind)
  local a = self.config.animation
  if kind == "hover" then
    return a.hoverDuration
  elseif kind == "reveal" then
    return a.revealDuration
  end
  return a.reflowDuration
end

function CardManager:_screenForUUID(screenUUID)
  for _, screen in ipairs(self.hs.screen.allScreens()) do
    if screen:getUUID() == screenUUID then
      return screen
    end
  end
  return nil
end

--- Rest depth (pixels of the card inside the usable area) for a rail, or
-- nil to use the classic inset positioning.
function CardManager:_restDepth(edge, revealed)
  if not self:_peekEnabled(edge) then
    return nil
  end
  local card = self.config.card
  return revealed and card.edgeRevealSize or card.peekSize
end

-- ---------------------------------------------------------------------
-- create / render / destroy
-- ---------------------------------------------------------------------

function CardManager:_render(record, canvas)
  local cardCfg = self.config.card
  local icon = cardCfg.showAppIcon and self.iconManager:iconFor(record.bundleID) or nil
  local thumbnail = cardCfg.showThumbnail and record.thumbnail or nil
  local elements = Renderer.buildElements(record, { w = cardCfg.collapsedWidth, h = cardCfg.collapsedHeight }, cardCfg, icon, thumbnail)
  local ok, err = pcall(function()
    canvas:replaceElements(elements)
  end)
  if not ok and self.logger then
    self.logger.e("Tuck: failed to render card for " .. tostring(record.tuckID) .. ": " .. tostring(err))
  end
end

--- Create the canvas for `record` (idempotent -- never a duplicate).
-- Positioning is done by reflowRail().
function CardManager:create(record)
  if self.canvases[record.tuckID] then
    return
  end
  local hs = self.hs
  local cardCfg = self.config.card
  local canvas = hs.canvas.new({ x = -10000, y = -10000, w = cardCfg.collapsedWidth, h = cardCfg.collapsedHeight })
  -- "floating" is well above hs.canvas.windowLevels.desktopIcon + 1, the
  -- documented minimum for reliable click delivery. No canJoinAllSpaces:
  -- a default canvas stays on the Space it was created on, which is the
  -- per-Space placement this Spoon needs.
  canvas:level(hs.canvas.windowLevels.floating)
  canvas:clickActivating(false)
  canvas:canvasMouseEvents(true, true, true, false)

  local this = self
  local tuckID = record.tuckID
  canvas:mouseCallback(function(_canvas, event)
    local rec = this.store:getByTuckID(tuckID)
    if not rec then
      return
    end
    if event == "mouseEnter" then
      this:_cardPointerEnter(rec)
    elseif event == "mouseExit" then
      this:_cardPointerExit(rec)
    elseif event == "mouseUp" then
      if this.onCardClicked then
        local ok, err = pcall(this.onCardClicked, tuckID)
        if not ok and this.logger then
          this.logger.e("Tuck: onCardClicked handler error: " .. tostring(err))
        end
      end
    end
  end)

  canvas:show()
  self.canvases[tuckID] = canvas
  self:_render(record, canvas)
end

--- Destroy a card (idempotent; tolerates a dead canvas/app).
function CardManager:destroy(tuckID)
  self.animator:cancel(tuckID)
  local record = self.store:getByTuckID(tuckID)
  local canvas = self.canvases[tuckID]
  if canvas then
    local ok, err = pcall(function()
      canvas:delete()
    end)
    if not ok and self.logger then
      self.logger.d("Tuck: canvas delete raised (tolerated): " .. tostring(err))
    end
  end
  self.canvases[tuckID] = nil
  self.anchorFrames[tuckID] = nil
  self.restFrames[tuckID] = nil
  self.hovered[tuckID] = nil
  self.searchMatched[tuckID] = nil
  -- Drop it from every rail's pointer set so a vanished card can never
  -- hold a rail open.
  for railKey, set in pairs(self.railPointer) do
    if set[tuckID] then
      set[tuckID] = nil
      self:_afterPointerChange(railKey)
    end
  end
  return record
end

-- ---------------------------------------------------------------------
-- target frames
-- ---------------------------------------------------------------------

function CardManager:_targetFrame(record)
  local tuckID = record.tuckID
  if isExpanded(self, tuckID) and self.anchorFrames[tuckID] then
    local cardCfg = self.config.card
    local screen = self:_screenForUUID(record.screenUUID)
    local area = screen and self.spaceManager:areaForScreen(screen, self.config.screen.useWorkArea) or nil
    return geometry.expandedFrame(
      self.anchorFrames[tuckID],
      record.edge,
      { w = cardCfg.expandedWidth, h = cardCfg.expandedHeight },
      area
    )
  end
  return self.restFrames[tuckID]
end

--- Move one card to its current target frame.
-- `kind`: "hover" | "reveal" | "reflow" (selects the duration);
-- `animate=false` jumps (used for a brand-new card).
function CardManager:_applyCard(tuckID, kind, animate)
  local record = self.store:getByTuckID(tuckID)
  local canvas = self.canvases[tuckID]
  if not record or not canvas then
    return
  end
  local target = self:_targetFrame(record)
  if not target then
    return
  end
  if not animate then
    self.animator:jump(tuckID, canvas, target)
    return
  end
  self.animator:animate(tuckID, canvas, target, self:_duration(kind), self.config.animation.easing)
end

-- ---------------------------------------------------------------------
-- rails
-- ---------------------------------------------------------------------

--- Recompute geometry for one rail and move its cards. `kind` selects the
-- animation duration for cards that already exist ("reflow" default,
-- "reveal" when only the reveal state changed).
function CardManager:reflowRail(screenUUID, spaceID, edge, kind)
  local railKey = railKeyOf(screenUUID, spaceID, edge)
  local screen = self:_screenForUUID(screenUUID)
  if not screen then
    return -- disconnected screen: leave cards and records untouched
  end

  local records = self.store:railRecords(screenUUID, spaceID, edge)
  self.railInfo[railKey] = { screenUUID = screenUUID, spaceID = spaceID, edge = edge }

  local area = self.spaceManager:areaForScreen(screen, self.config.screen.useWorkArea)
  local railCfg = self.config.rails[edge]
  local cardCfg = self.config.card
  local base = {
    area = area,
    edge = edge,
    itemSize = { w = cardCfg.collapsedWidth, h = cardCfg.collapsedHeight },
    margin = railCfg.margin,
    padding = railCfg.padding,
    origin = railCfg.origin,
    inset = cardCfg.edgeInset,
    count = #records,
  }

  if #records == 0 then
    -- Empty rail: forget its transient interaction state so the next
    -- card starts parked, and release its trigger region.
    self:_cancelRetract(railKey)
    self.railRevealed[railKey] = nil
    self.railPointer[railKey] = nil
  end

  local anchors, rests
  if #records > 0 then
    anchors = geometry.frameForRail(base)
    local restParams = {}
    for k, v in pairs(base) do
      restParams[k] = v
    end
    restParams.depth = self:_restDepth(edge, self.railRevealed[railKey] == true)
    rests = restParams.depth ~= nil and geometry.frameForRail(restParams) or anchors
  end

  for i, record in ipairs(records) do
    self.anchorFrames[record.tuckID] = anchors[i]
    self.restFrames[record.tuckID] = rests[i]
    local isNew = self.canvases[record.tuckID] == nil
    if isNew then
      self:create(record)
    end
    -- A new card simply appears in its slot; existing cards slide.
    self:_applyCard(record.tuckID, kind or "reflow", not isNew)
  end

  self:_syncRailZone(railKey, screenUUID, spaceID, edge, records, area, anchors)
end

--- Reflow every rail that has cards (screen / Space / config changes).
function CardManager:reflowAll()
  for shelfKey, shelf in pairs(self.store.shelves) do
    local screenUUID, spaceID = shelfKey:match("^(.-)|(.+)$")
    local numericSpaceID = tonumber(spaceID)
    for _, edge in ipairs({ "left", "right", "top", "bottom" }) do
      if #shelf[edge] > 0 then
        self:reflowRail(screenUUID, numericSpaceID or spaceID, edge)
      end
    end
  end
end

-- ---------------------------------------------------------------------
-- pointer model
-- ---------------------------------------------------------------------

function CardManager:_railKeyOfRecord(record)
  return railKeyOf(record.screenUUID, record.spaceID, record.edge)
end

function CardManager:_cancelRetract(railKey)
  local timer = self.retractTimers[railKey]
  if timer then
    timer:stop()
    self.retractTimers[railKey] = nil
  end
end

local function setIsEmpty(set)
  return set == nil or next(set) == nil
end

function CardManager:_setRevealed(railKey, revealed)
  if (self.railRevealed[railKey] == true) == revealed then
    return
  end
  self.railRevealed[railKey] = revealed or nil
  local info = self.railInfo[railKey]
  if info then
    self:reflowRail(info.screenUUID, info.spaceID, info.edge, "reveal")
  end
end

--- Called whenever a rail's pointer set changed.
function CardManager:_afterPointerChange(railKey)
  local info = self.railInfo[railKey]
  if not info or not self:_peekEnabled(info.edge) then
    return
  end
  if setIsEmpty(self.railPointer[railKey]) then
    if self.railRevealed[railKey] and not self.retractTimers[railKey] then
      local this = self
      self.retractTimers[railKey] = self.hs.timer.doAfter(self.config.card.revealGraceDelay, function()
        this.retractTimers[railKey] = nil
        if setIsEmpty(this.railPointer[railKey]) then
          this:_setRevealed(railKey, false)
        end
      end)
    end
  else
    self:_cancelRetract(railKey)
    self:_setRevealed(railKey, true)
  end
end

function CardManager:_pointerEnter(railKey, sourceID)
  local set = self.railPointer[railKey]
  if not set then
    set = {}
    self.railPointer[railKey] = set
  end
  set[sourceID] = true
  self:_afterPointerChange(railKey)
end

function CardManager:_pointerExit(railKey, sourceID)
  local set = self.railPointer[railKey]
  if set then
    set[sourceID] = nil
  end
  self:_afterPointerChange(railKey)
end

function CardManager:_cardPointerEnter(record)
  self.hovered[record.tuckID] = true
  self:_pointerEnter(self:_railKeyOfRecord(record), record.tuckID)
  self:_applyCard(record.tuckID, "hover", true)
end

function CardManager:_cardPointerExit(record)
  self.hovered[record.tuckID] = nil
  self:_pointerExit(self:_railKeyOfRecord(record), record.tuckID)
  self:_applyCard(record.tuckID, "hover", true)
end

-- ---- edge trigger regions (mouse-moved eventtap, no polling) ----------

--- Is `point` inside the trigger region `zone` = { frame = {x,y,w,h} }?
function CardManager.pointInFrame(point, frame)
  return point.x >= frame.x and point.x < frame.x + frame.w and point.y >= frame.y and point.y < frame.y + frame.h
end

function CardManager:_syncRailZone(railKey, screenUUID, spaceID, edge, records, area, anchors)
  if not self:_peekEnabled(edge) or #records == 0 then
    self.railZones[railKey] = nil
    self:_updateMoveTap()
    return
  end
  -- Region: `edgeTriggerSize` deep at the edge, spanning the rail's cards
  -- (plus a little padding) so only that stretch of the edge reacts.
  local size = self.config.card.edgeTriggerSize
  local frame = geometry.triggerZoneFrame(area, edge, size)
  local lo, hi
  for _, f in ipairs(anchors) do
    if edge == "left" or edge == "right" then
      lo = math.min(lo or f.y, f.y)
      hi = math.max(hi or (f.y + f.h), f.y + f.h)
    else
      lo = math.min(lo or f.x, f.x)
      hi = math.max(hi or (f.x + f.w), f.x + f.w)
    end
  end
  lo = lo - TRIGGER_SPAN_PADDING
  hi = hi + TRIGGER_SPAN_PADDING
  if edge == "left" or edge == "right" then
    lo, hi = math.max(lo, area.y), math.min(hi, area.y + area.h)
    frame.y, frame.h = lo, hi - lo
  else
    lo, hi = math.max(lo, area.x), math.min(hi, area.x + area.w)
    frame.x, frame.w = lo, hi - lo
  end
  local existing = self.railZones[railKey]
  self.railZones[railKey] = {
    frame = frame,
    screenUUID = screenUUID,
    spaceID = spaceID,
    edge = edge,
    inside = existing and existing.inside or false,
  }
  self:_updateMoveTap()
end

function CardManager:_onMouseMoved(point)
  for railKey, zone in pairs(self.railZones) do
    local inside = CardManager.pointInFrame(point, zone.frame)
    if inside ~= zone.inside then
      if inside then
        -- Only react on the Space that is actually showing these cards.
        local screen = self:_screenForUUID(zone.screenUUID)
        local active = screen and self.spaceManager:currentSpaceID(screen)
        if active == zone.spaceID then
          zone.inside = true
          self:_pointerEnter(railKey, "zone")
        end
      else
        zone.inside = false
        self:_pointerExit(railKey, "zone")
      end
    end
  end
end

function CardManager:_updateMoveTap()
  local hs = self.hs
  local any = next(self.railZones) ~= nil
  if any and not self.moveTap then
    local this = self
    self.moveTap = hs.eventtap.new({ hs.eventtap.event.types.mouseMoved }, function(event)
      local ok, err = pcall(function()
        this:_onMouseMoved(event:location())
      end)
      if not ok and this.logger then
        this.logger.d("Tuck: mouse-move handler error: " .. tostring(err))
      end
      return false -- never consume mouse events
    end)
    self.moveTap:start()
  elseif not any and self.moveTap then
    self.moveTap:stop()
    self.moveTap = nil
  end
end

-- ---------------------------------------------------------------------
-- search expansion
-- ---------------------------------------------------------------------

--- Mark `tuckIDs` as search-matched (expanded); all others unmatched.
-- Cards still hovered stay expanded.
function CardManager:setSearchMatches(tuckIDs)
  local matchedSet = {}
  for _, id in ipairs(tuckIDs) do
    matchedSet[id] = true
  end
  local changed = {}
  for tuckID in pairs(self.searchMatched) do
    if not matchedSet[tuckID] then
      self.searchMatched[tuckID] = nil
      changed[#changed + 1] = tuckID
    end
  end
  for tuckID in pairs(matchedSet) do
    if not self.searchMatched[tuckID] then
      self.searchMatched[tuckID] = true
      changed[#changed + 1] = tuckID
    end
  end
  for _, tuckID in ipairs(changed) do
    self:_applyCard(tuckID, "hover", true)
  end
end

function CardManager:clearSearchExpansion()
  self:setSearchMatches({})
end

--- Recreate a missing card from the model (recovery).
function CardManager:ensureCardExists(tuckID)
  if self.canvases[tuckID] then
    return
  end
  local record = self.store:getByTuckID(tuckID)
  if record then
    self:reflowRail(record.screenUUID, record.spaceID, record.edge)
  end
end

--- Tear down every canvas, timer, animation and tap (idempotent).
function CardManager:stop()
  self.animator:stopAll()
  for railKey in pairs(self.retractTimers) do
    self:_cancelRetract(railKey)
  end
  for tuckID, canvas in pairs(self.canvases) do
    pcall(function()
      canvas:delete()
    end)
    self.canvases[tuckID] = nil
  end
  self.anchorFrames = {}
  self.restFrames = {}
  self.hovered = {}
  self.searchMatched = {}
  self.railInfo = {}
  self.railRevealed = {}
  self.railPointer = {}
  self.railZones = {}
  if self.moveTap then
    self.moveTap:stop()
    self.moveTap = nil
  end
end

return CardManager
