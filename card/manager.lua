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
-- EVENT-DRIVEN POINTER MODEL (no polling, no global mouse monitoring)
--   Hover and edge reveal are driven by the mouse enter/exit callbacks of
--   small STATIONARY hit canvases (hs.canvas canvasMouseEvents; verified
--   against Hammerspoon's canvas source: a canvas with a mouse callback
--   receives mouse events -- and therefore also blocks clicks -- over its
--   whole area, a canvas without one is click-through). There is NO
--   mouse-moved eventtap and no timer that inspects the pointer.
--
--   Why separate hit canvases instead of the visible card canvas: the
--   visible card slides under a resting pointer; enter/exit events from a
--   MOVING canvas are exactly what used to feed back into the animation
--   (card moves -> exit/enter -> retarget -> card moves ...). The visible
--   card canvas therefore has no mouse callback at all (click-through,
--   purely a picture), and the pointer is observed by canvases whose
--   frames only ever change to a TARGET region when a state changes:
--     * zone canvas (one per peek rail): the edge trigger strip,
--       `edgeTriggerSize` deep over the rail's extent. Fixed by the screen
--       and slot layout; it never moves with an animated card.
--     * hit canvas (one per card): the part of the card's current resting
--       slot that is on screen (parked sliver / revealed slot / fully
--       visible slot) -- and, while the card is hovered, its expanded
--       frame, which is flush with the screen edge and so always contains
--       the slot it grew from. That is the hysteresis: a card is entered
--       through its resting slot and left only by leaving its expanded
--       frame. The hovered card's hit canvas is raised above its
--       neighbours' so overlapping slots cannot steal the hover.
--   State handlers are idempotent (enter for the card already hovered, or
--   exit for a card that is not, do nothing), so a stray or duplicated
--   event can never restart an animation.
--   * At most one card is hovered at a time.
--   * Each rail keeps a SET of pointer "sources" (its zone and its hovered
--     card). The rail is revealed while the set is non-empty and retracts
--     only after `revealGraceDelay` (a one-shot timer that exists only
--     while the rail is revealed and the pointer is away); any re-entry
--     cancels it.
--   * With no cards there are no hit/zone canvases and no timers.
--
-- All motion goes through card/animator.lua (one ticker, alive only while
-- an animation runs; one animation per card, a new target supersedes the
-- old one, and an unchanged target is ignored).

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
  self.anchorFrames = {} -- tuckID -> fully-visible slot frame (inset from the boundary)
  self.expandAnchors = {} -- tuckID -> slot frame an expansion grows from (flush on peek rails)
  self.restFrames = {} -- tuckID -> resting (parked / revealed / full) frame
  self.hovered = {} -- tuckID -> true (at most one entry)
  self.hoveredID = nil
  self.searchMatched = {} -- tuckID -> true

  self.railInfo = {} -- railKey -> { screenUUID, spaceID, edge }
  self.railRevealed = {} -- railKey -> true while edge-revealed
  self.railPointer = {} -- railKey -> { [sourceID] = true }
  self.retractTimers = {} -- railKey -> hs.timer (one-shot)
  self.railZones = {} -- railKey -> { frame = {..}, edge = ..., screenUUID, spaceID, canvas = hs.canvas }
  self.hitCanvases = {} -- tuckID -> hs.canvas (stationary pointer sensor + click target)
  self.hitFrames = {} -- tuckID -> last frame assigned to its hit canvas
  -- While true (a Tuck command is in progress -- see setCommandRevealActive),
  -- every peek rail rests fully visible instead of parked/edge-revealed,
  -- so the whole shelf is visible while choosing a direction or searching.
  self.commandRevealActive = false

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
-- nil to use the classic inset positioning (fully visible).
function CardManager:_restDepth(edge, revealed)
  if not self:_peekEnabled(edge) then
    return nil
  end
  if self.commandRevealActive then
    return nil -- fully visible: a command is in progress, show every card
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
  -- No mouse callback: the visible card is click-through; pointer events
  -- come from its stationary hit canvas (see "EVENT-DRIVEN POINTER MODEL").
  canvas:show()
  self.canvases[record.tuckID] = canvas
  self:_render(record, canvas)
  self:_createHit(record)
end

local TRANSPARENT_HIT_ELEMENTS = {
  -- Almost-invisible fill: fully transparent pixels are not reliably hit
  -- by the window server, so a 1% fill keeps the region interactive.
  {
    type = "rectangle",
    action = "fill",
    fillColor = { red = 0, green = 0, blue = 0, alpha = 0.01 },
    frame = { x = "0%", y = "0%", w = "100%", h = "100%" },
  },
}

--- Create a stationary sensor canvas: `onEvent(eventName)` receives
-- "mouseEnter" | "mouseExit" | "mouseUp".
function CardManager:_newSensor(onEvent)
  local hs = self.hs
  local canvas = hs.canvas.new({ x = -10000, y = -10000, w = 1, h = 1 })
  canvas:level(hs.canvas.windowLevels.floating)
  canvas:clickActivating(false)
  canvas:canvasMouseEvents(true, true, true, false)
  canvas:replaceElements(TRANSPARENT_HIT_ELEMENTS)
  local this = self
  canvas:mouseCallback(function(_canvas, event)
    local ok, err = pcall(onEvent, event)
    if not ok and this.logger then
      this.logger.e("Tuck: pointer handler error: " .. tostring(err))
    end
  end)
  canvas:show()
  return canvas
end

function CardManager:_createHit(record)
  local tuckID = record.tuckID
  if self.hitCanvases[tuckID] then
    return
  end
  local this = self
  self.hitCanvases[tuckID] = self:_newSensor(function(event)
    if not this.store:getByTuckID(tuckID) then
      return
    end
    if event == "mouseEnter" then
      this:_onHitEnter(tuckID)
    elseif event == "mouseExit" then
      this:_onHitExit(tuckID)
    elseif event == "mouseUp" and this.onCardClicked then
      local ok, err = pcall(this.onCardClicked, tuckID)
      if not ok and this.logger then
        this.logger.e("Tuck: onCardClicked handler error: " .. tostring(err))
      end
    end
  end)
end

local function deleteCanvas(self, canvas, what)
  local ok, err = pcall(function()
    canvas:delete()
  end)
  if not ok and self.logger then
    self.logger.d("Tuck: " .. what .. " delete raised (tolerated): " .. tostring(err))
  end
end

--- Destroy a card (idempotent; tolerates a dead canvas/app).
function CardManager:destroy(tuckID)
  self.animator:cancel(tuckID)
  local record = self.store:getByTuckID(tuckID)
  local canvas = self.canvases[tuckID]
  if canvas then
    deleteCanvas(self, canvas, "canvas")
  end
  self.canvases[tuckID] = nil
  local hit = self.hitCanvases[tuckID]
  if hit then
    deleteCanvas(self, hit, "hit canvas")
  end
  self.hitCanvases[tuckID] = nil
  self.hitFrames[tuckID] = nil
  self.anchorFrames[tuckID] = nil
  self.expandAnchors[tuckID] = nil
  self.restFrames[tuckID] = nil
  self.hovered[tuckID] = nil
  if self.hoveredID == tuckID then
    self.hoveredID = nil
  end
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

--- The frame the card occupies when expanded (hover / search match).
function CardManager:_expandedFrame(record)
  local tuckID = record.tuckID
  local anchor = self.expandAnchors[tuckID] or self.anchorFrames[tuckID]
  if not anchor then
    return nil
  end
  local cardCfg = self.config.card
  local screen = self:_screenForUUID(record.screenUUID)
  local area = screen and self.spaceManager:areaForScreen(screen, self.config.screen.useWorkArea) or nil
  return geometry.expandedFrame(anchor, record.edge, { w = cardCfg.expandedWidth, h = cardCfg.expandedHeight }, area)
end

function CardManager:_targetFrame(record)
  local tuckID = record.tuckID
  if isExpanded(self, tuckID) and (self.expandAnchors[tuckID] or self.anchorFrames[tuckID]) then
    return self:_expandedFrame(record)
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
  -- The sensor follows the TARGET immediately (never the animating frame).
  self:_syncHit(record)
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

  local anchors, rests, expandAnchors
  if #records > 0 then
    anchors = geometry.frameForRail(base)
    local function variant(overrides)
      local p = {}
      for k, v in pairs(base) do
        p[k] = v
      end
      for k, v in pairs(overrides) do
        p[k] = v
      end
      return p
    end
    local peek = self:_peekEnabled(edge)
    local restDepth = self:_restDepth(edge, self.railRevealed[railKey] == true)
    rests = restDepth ~= nil and geometry.frameForRail(variant({ depth = restDepth })) or anchors
    -- A peek rail's expansion grows from a slot that is FLUSH with the
    -- boundary (inset 0), so the expanded frame always contains the
    -- parked/revealed slot the pointer entered through.
    expandAnchors = peek and geometry.frameForRail(variant({ inset = 0 })) or anchors
  end

  for i, record in ipairs(records) do
    self.anchorFrames[record.tuckID] = anchors[i]
    self.expandAnchors[record.tuckID] = expandAnchors[i]
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
function CardManager:reflowAll(kind)
  for shelfKey, shelf in pairs(self.store.shelves) do
    local screenUUID, spaceID = shelfKey:match("^(.-)|(.+)$")
    local numericSpaceID = tonumber(spaceID)
    for _, edge in ipairs({ "left", "right", "top", "bottom" }) do
      if #shelf[edge] > 0 then
        self:reflowRail(screenUUID, numericSpaceID or spaceID, edge, kind)
      end
    end
  end
end

--- Toggle "show every tucked card" mode: while active, every peek rail's
-- resting cards sit fully on-screen (still at their collapsed size, not
-- expanded) instead of parked/edge-revealed, so the whole shelf is
-- visible while a Tuck command is in progress. Cards still hovered or
-- search-matched are unaffected (they already show fully expanded).
-- Idempotent; a no-op when already in the requested state.
function CardManager:setCommandRevealActive(active)
  active = active and true or false
  if self.commandRevealActive == active then
    return
  end
  self.commandRevealActive = active
  self:reflowAll("reveal")
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

-- ---- hit regions and edge trigger zones (event-driven sensors) ---------

local function intersect(a, b)
  local x1, y1 = math.max(a.x, b.x), math.max(a.y, b.y)
  local x2, y2 = math.min(a.x + a.w, b.x + b.w), math.min(a.y + a.h, b.y + b.h)
  if x2 <= x1 or y2 <= y1 then
    return nil
  end
  return { x = x1, y = y1, w = x2 - x1, h = y2 - y1 }
end

--- The on-screen region a card's sensor should cover right now (target
-- geometry, never the animating frame): its expanded frame while hovered,
-- otherwise the visible part of its resting slot. nil if unknown.
function CardManager:_hitRegion(record)
  local tuckID = record.tuckID
  local frame
  if self.hovered[tuckID] and self.config.card.expansionEnabled then
    frame = self:_expandedFrame(record)
  else
    frame = self.restFrames[tuckID]
  end
  if not frame then
    return nil
  end
  local screen = self:_screenForUUID(record.screenUUID)
  if not screen then
    return nil
  end
  local area = self.spaceManager:areaForScreen(screen, self.config.screen.useWorkArea)
  return intersect(frame, area)
end

--- Move the card's sensor to its current region (no-op when unchanged, so
-- repeated state evaluation never touches the window server).
function CardManager:_syncHit(record)
  local hit = self.hitCanvases[record.tuckID]
  if not hit then
    return
  end
  local region = self:_hitRegion(record)
  if not region then
    return
  end
  local last = self.hitFrames[record.tuckID]
  if last and last.x == region.x and last.y == region.y and last.w == region.w and last.h == region.h then
    return
  end
  self.hitFrames[record.tuckID] = region
  hit:frame(region)
end

function CardManager:_syncRailZone(railKey, screenUUID, spaceID, edge, records, area, anchors)
  if not self:_peekEnabled(edge) or #records == 0 then
    self:_removeZone(railKey)
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

  local zone = self.railZones[railKey]
  local created = false
  if not zone then
    zone = { screenUUID = screenUUID, spaceID = spaceID, edge = edge }
    local this = self
    zone.canvas = self:_newSensor(function(event)
      if event == "mouseEnter" then
        this:_onZone(railKey, true)
      elseif event == "mouseExit" then
        this:_onZone(railKey, false)
      end
    end)
    self.railZones[railKey] = zone
    created = true
  end
  local changed = created or not zone.frame or zone.frame.x ~= frame.x or zone.frame.y ~= frame.y
    or zone.frame.w ~= frame.w or zone.frame.h ~= frame.h
  zone.frame = frame
  if changed then
    zone.canvas:frame(frame)
  end
  if created then
    -- The zone sits BELOW this rail's card sensors: raise them above it.
    for _, record in ipairs(records) do
      local hit = self.hitCanvases[record.tuckID]
      if hit then
        hit:bringToFront()
      end
    end
  end
end

function CardManager:_removeZone(railKey)
  local zone = self.railZones[railKey]
  if not zone then
    return
  end
  self.railZones[railKey] = nil
  if zone.canvas then
    deleteCanvas(self, zone.canvas, "zone canvas")
  end
end

function CardManager:_setSource(railKey, sourceID, present)
  local set = self.railPointer[railKey]
  if present then
    if not set then
      set = {}
      self.railPointer[railKey] = set
    end
    set[sourceID] = true
  elseif set then
    set[sourceID] = nil
  end
end

--- The pointer entered/left a rail's trigger zone (event from its sensor).
function CardManager:_onZone(railKey, inside)
  if not self.railZones[railKey] then
    return
  end
  local set = self.railPointer[railKey]
  if ((set and set.zone) == true) == inside then
    return -- idempotent
  end
  self:_setSource(railKey, "zone", inside)
  self:_afterPointerChange(railKey)
end

--- Make `newID` (or nothing) the hovered card. Computes every change
-- first and applies each once; a no-op when nothing changes.
function CardManager:_setHover(newID)
  local oldID = self.hoveredID
  if newID == oldID then
    return
  end
  local touchedRails = {}
  if oldID then
    self.hovered[oldID] = nil
    local oldRec = self.store:getByTuckID(oldID)
    if oldRec then
      local rk = self:_railKeyOfRecord(oldRec)
      self:_setSource(rk, oldID, false)
      touchedRails[#touchedRails + 1] = rk
    end
  end
  self.hoveredID = newID
  if newID then
    self.hovered[newID] = true
    local newRec = self.store:getByTuckID(newID)
    if newRec then
      local rk = self:_railKeyOfRecord(newRec)
      self:_setSource(rk, newID, true)
      touchedRails[#touchedRails + 1] = rk
    end
    local hit = self.hitCanvases[newID]
    if hit then
      hit:bringToFront() -- the hovered card keeps priority over neighbours
    end
  end
  for _, rk in ipairs(touchedRails) do
    self:_afterPointerChange(rk)
  end
  -- The animator ignores a request for the target a card is already
  -- heading to, so a card touched by both steps is animated once.
  if oldID then
    self:_applyCard(oldID, "hover", true)
  end
  if newID then
    self:_applyCard(newID, "hover", true)
  end
end

function CardManager:_onHitEnter(tuckID)
  if self.canvases[tuckID] then
    self:_setHover(tuckID)
  end
end

function CardManager:_onHitExit(tuckID)
  if self.hoveredID == tuckID then
    self:_setHover(nil)
  end
end

--- Forget all transient pointer state and park every rail (used after a
-- Space change, when a sensor on the Space just left may never deliver its
-- exit). Touches no records and no persisted data.
function CardManager:resetInteraction()
  for railKey in pairs(self.retractTimers) do
    self:_cancelRetract(railKey)
  end
  local hadHover = self.hoveredID ~= nil
  local hoveredID = self.hoveredID
  self.hoveredID = nil
  self.hovered = {}
  self.railPointer = {}
  local changed = {}
  for railKey in pairs(self.railRevealed) do
    changed[#changed + 1] = railKey
  end
  self.railRevealed = {}
  for _, railKey in ipairs(changed) do
    local info = self.railInfo[railKey]
    if info then
      self:reflowRail(info.screenUUID, info.spaceID, info.edge, "reveal")
    end
  end
  if hadHover then
    self:_applyCard(hoveredID, "hover", true)
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

--- Release everything that only exists while cards exist: sensors, zones,
-- timers, animation ticker, geometry caches. Called when the last tuck is
-- removed (cards themselves are already gone by then). Idempotent.
function CardManager:releaseIdleResources()
  self.animator:stopAll()
  for railKey in pairs(self.retractTimers) do
    self:_cancelRetract(railKey)
  end
  for railKey in pairs(self.railZones) do
    self:_removeZone(railKey)
  end
  for tuckID, hit in pairs(self.hitCanvases) do
    deleteCanvas(self, hit, "hit canvas")
    self.hitCanvases[tuckID] = nil
  end
  self.hitFrames = {}
  self.railInfo = {}
  self.railRevealed = {}
  self.railPointer = {}
  self.hovered = {}
  self.hoveredID = nil
  self.searchMatched = {}
end

--- Tear down every canvas, timer and animation (idempotent).
function CardManager:stop()
  for tuckID, canvas in pairs(self.canvases) do
    deleteCanvas(self, canvas, "canvas")
    self.canvases[tuckID] = nil
  end
  self:releaseIdleResources()
  self.anchorFrames = {}
  self.expandAnchors = {}
  self.restFrames = {}
  self.commandRevealActive = false
end

return CardManager
