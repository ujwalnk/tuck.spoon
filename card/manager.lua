--- Card manager.
--
-- Owns: create card, update card, destroy card, hover state, search-
-- expanded state, click handling, positioning. Does NOT own the
-- application window lifecycle -- it only ever acts on the tuck
-- registry (state/store.lua) and the pure geometry module.
--
-- A card's expanded/collapsed visual state is the OR of two independent
-- flags: hovered and searchMatched. Both must clear before a card
-- collapses back down (spec: "If a card is both hovered and search-
-- matched, it remains expanded until both conditions end.").

local geometry = require("space.geometry")
local Renderer = require("card.renderer")

local CardManager = {}
CardManager.__index = CardManager

function CardManager.new(hsRef, store, spaceManager, iconManager, logger, config)
  local self = setmetatable({}, CardManager)
  self.hs = hsRef
  self.store = store
  self.spaceManager = spaceManager
  self.iconManager = iconManager
  self.logger = logger
  self.config = config -- live reference; card.* and screen.* sub-tables read fresh each render

  self.canvases = {} -- tuckID -> hs.canvas
  self.collapsedFrames = {} -- tuckID -> last-computed collapsed frame (for expansion anchor math)
  self.hovered = {} -- tuckID -> true
  self.searchMatched = {} -- tuckID -> true
  self._animTimers = {} -- tuckID -> hs.timer (in-flight expand/collapse tween)

  -- Callback set by init.lua: function(tuckID) -- invoked on card click.
  self.onCardClicked = nil

  return self
end

local function isExpanded(self, tuckID)
  return self.hovered[tuckID] == true or self.searchMatched[tuckID] == true
end

--- Cancel any in-flight tween for a card (idempotent).
function CardManager:_cancelAnim(tuckID)
  local timer = self._animTimers[tuckID]
  if timer then
    timer:stop()
    self._animTimers[tuckID] = nil
  end
end

--- Smoothly (or instantly, if duration <= 0) move+resize a canvas from
-- its current frame to `toFrame` over `duration` seconds. hs.canvas has
-- no documented native tween for :frame(), so this implements a minimal
-- manual interpolation using hs.timer, matching the configured
-- animationDuration. Always leaves the canvas at exactly `toFrame` when
-- finished, even if interrupted by a subsequent call.
function CardManager:_animateFrame(tuckID, canvas, toFrame, duration)
  self:_cancelAnim(tuckID)

  if not duration or duration <= 0 then
    canvas:frame(toFrame)
    return
  end

  local ok, fromFrame = pcall(function()
    return canvas:frame()
  end)
  if not ok or not fromFrame then
    canvas:frame(toFrame)
    return
  end

  local steps = math.max(1, math.floor(duration * 60))
  local stepDuration = duration / steps
  local i = 0

  local timer
  timer = self.hs.timer.doEvery(stepDuration, function()
    i = i + 1
    local t = i / steps
    if t >= 1 then
      canvas:frame(toFrame)
      timer:stop()
      self._animTimers[tuckID] = nil
      return
    end
    -- Simple ease-out for a slightly less mechanical feel.
    local eased = 1 - (1 - t) * (1 - t)
    canvas:frame({
      x = fromFrame.x + (toFrame.x - fromFrame.x) * eased,
      y = fromFrame.y + (toFrame.y - fromFrame.y) * eased,
      w = fromFrame.w + (toFrame.w - fromFrame.w) * eased,
      h = fromFrame.h + (toFrame.h - fromFrame.h) * eased,
    })
  end)
  self._animTimers[tuckID] = timer
end

--- Recompute and apply the on-screen frame (collapsed or expanded,
-- whichever currently applies) for a single card, WITHOUT touching its
-- neighbors. Used after a hover/search state change.
function CardManager:_applyVisualState(tuckID, animate)
  local record = self.store:getByTuckID(tuckID)
  local canvas = self.canvases[tuckID]
  if not record or not canvas then
    return
  end
  local collapsed = self.collapsedFrames[tuckID]
  if not collapsed then
    return
  end

  local cardCfg = self.config.card
  local duration = animate and cardCfg.animationDuration or 0

  if isExpanded(self, tuckID) and cardCfg.expansionEnabled then
    local screen = self:_screenForUUID(record.screenUUID)
    local area = screen and self.spaceManager:areaForScreen(screen, self.config.screen.useWorkArea) or nil
    local expandedSize = { w = cardCfg.expandedWidth, h = cardCfg.expandedHeight }
    local expanded = geometry.expandedFrame(collapsed, record.edge, expandedSize, area)
    self:_animateFrame(tuckID, canvas, expanded, duration)
    self:_render(record, canvas, { w = expanded.w, h = expanded.h })
  else
    self:_animateFrame(tuckID, canvas, collapsed, duration)
    self:_render(record, canvas, { w = collapsed.w, h = collapsed.h })
  end
end

function CardManager:_screenForUUID(screenUUID)
  for _, screen in ipairs(self.hs.screen.allScreens()) do
    if screen:getUUID() == screenUUID then
      return screen
    end
  end
  return nil
end

--- Rebuild the drawn content of `canvas` for `record` at `size`.
function CardManager:_render(record, canvas, size)
  local cardCfg = self.config.card
  local icon = cardCfg.showAppIcon and self.iconManager:iconFor(record.bundleID) or nil
  local thumbnail = cardCfg.showThumbnail and record.thumbnail or nil
  local elements = Renderer.buildElements(record, size, cardCfg, icon, thumbnail)
  local ok, err = pcall(function()
    canvas:replaceElements(elements)
  end)
  if not ok and self.logger then
    self.logger.e("Tuck: failed to render card for tuckID " .. tostring(record.tuckID) .. ": " .. tostring(err))
  end
end

--- Create a card (hs.canvas) for `record`. Does NOT position it against
-- its siblings -- call :reflowRail() immediately after (spec requires
-- reflow on every tuck anyway, so callers always do this).
function CardManager:create(record)
  if self.canvases[record.tuckID] then
    -- Never create a duplicate canvas for one tuck.
    return
  end

  local hs = self.hs
  local cardCfg = self.config.card
  local placeholderFrame = { x = -10000, y = -10000, w = cardCfg.collapsedWidth, h = cardCfg.collapsedHeight }

  local canvas = hs.canvas.new(placeholderFrame)
  -- "floating" keeps the card above ordinary application windows while
  -- remaining well above hs.canvas.windowLevels.desktopIcon + 1, which
  -- Hammerspoon documents as the minimum level for reliable click
  -- delivery. We deliberately do NOT set canJoinAllSpaces (or any other
  -- special collection behavior): a canvas's default behavior ties it to
  -- whichever single Space was active when it was created, which is
  -- exactly the per-Space card placement this Spoon requires.
  canvas:level(hs.canvas.windowLevels.floating)
  canvas:clickActivating(false)
  -- (mouseDown, mouseUp, mouseEnterExit, mouseMove) -- we only need
  -- click (mouseUp) and hover (enter/exit); mouseMove is left off to
  -- avoid generating a continuous stream of events we don't use.
  canvas:canvasMouseEvents(true, true, true, false)

  local this = self
  canvas:mouseCallback(function(_canvas, event, _id, _x, _y)
    if event == "mouseEnter" then
      this.hovered[record.tuckID] = true
      this:_applyVisualState(record.tuckID, true)
    elseif event == "mouseExit" then
      this.hovered[record.tuckID] = nil
      this:_applyVisualState(record.tuckID, true)
    elseif event == "mouseUp" then
      if this.onCardClicked then
        local ok, err = pcall(this.onCardClicked, record.tuckID)
        if not ok and this.logger then
          this.logger.e("Tuck: onCardClicked handler error: " .. tostring(err))
        end
      end
    end
  end)

  canvas:show()
  self.canvases[record.tuckID] = canvas
  self:_render(record, canvas, { w = cardCfg.collapsedWidth, h = cardCfg.collapsedHeight })
end

--- Destroy a card's canvas (idempotent -- safe even if the card never
-- existed, or was already destroyed, or the underlying app is already
-- gone).
function CardManager:destroy(tuckID)
  self:_cancelAnim(tuckID)
  local canvas = self.canvases[tuckID]
  if canvas then
    local ok, err = pcall(function()
      canvas:delete()
    end)
    if not ok and self.logger then
      self.logger.d("Tuck: canvas delete for " .. tostring(tuckID) .. " raised (tolerated): " .. tostring(err))
    end
  end
  self.canvases[tuckID] = nil
  self.collapsedFrames[tuckID] = nil
  self.hovered[tuckID] = nil
  self.searchMatched[tuckID] = nil
end

--- Recompute collapsed positions for every card on one rail and apply
-- them (respecting any card currently expanded due to hover/search --
-- its rail anchor updates but it stays visually expanded). Call this
-- whenever the spec requires a reflow.
function CardManager:reflowRail(screenUUID, spaceID, edge)
  local screen = self:_screenForUUID(screenUUID)
  if not screen then
    -- Screen disconnected: leave existing canvases where they are (see
    -- space/manager screen-change reconciliation); nothing to reflow.
    return
  end

  local records = self.store:railRecords(screenUUID, spaceID, edge)
  local area = self.spaceManager:areaForScreen(screen, self.config.screen.useWorkArea)
  local railCfg = self.config.rails[edge]
  local cardCfg = self.config.card

  local frames = geometry.frameForRail({
    area = area,
    edge = edge,
    itemSize = { w = cardCfg.collapsedWidth, h = cardCfg.collapsedHeight },
    margin = railCfg.margin,
    padding = railCfg.padding,
    origin = railCfg.origin,
    inset = cardCfg.edgeInset,
    count = #records,
  })

  for i, record in ipairs(records) do
    self.collapsedFrames[record.tuckID] = frames[i]
    local isNew = self.canvases[record.tuckID] == nil
    if isNew then
      self:create(record)
    end
    -- A brand-new card should simply appear in its slot; only a card
    -- that already existed (being reflowed to a new slot because a
    -- sibling was added/removed) should smoothly slide there.
    self:_applyVisualState(record.tuckID, not isNew)
  end
end

--- Reflow every rail on every known shelf. Used after a screen/Space
-- layout change where many shelves may be affected at once.
function CardManager:reflowAll()
  for shelfKey, shelf in pairs(self.store.shelves) do
    local screenUUID, spaceID = shelfKey:match("^(.-)|(.+)$")
    -- spaceID was stored via tostring(); convert back to number if it
    -- looks numeric so table lookups elsewhere stay consistent.
    local numericSpaceID = tonumber(spaceID)
    for _, edge in ipairs({ "left", "right", "top", "bottom" }) do
      if #shelf[edge] > 0 then
        self:reflowRail(screenUUID, numericSpaceID or spaceID, edge)
      end
    end
  end
end

--- Mark `tuckIDs` (an array) as search-matched (expanded), and every
-- other currently-known card as NOT search-matched. Cards that remain
-- expanded only because they are hovered are unaffected.
function CardManager:setSearchMatches(tuckIDs)
  local matchedSet = {}
  for _, id in ipairs(tuckIDs) do
    matchedSet[id] = true
  end

  -- Clear matches no longer in the set.
  for tuckID in pairs(self.searchMatched) do
    if not matchedSet[tuckID] then
      self.searchMatched[tuckID] = nil
      self:_applyVisualState(tuckID, true)
    end
  end
  -- Apply new matches.
  for tuckID in pairs(matchedSet) do
    if not self.searchMatched[tuckID] then
      self.searchMatched[tuckID] = true
      self:_applyVisualState(tuckID, true)
    end
  end
end

--- Collapse every search-expanded card (used on cancel/restore/timeout).
function CardManager:clearSearchExpansion()
  self:setSearchMatches({})
end

--- Recreate a card from the store if it is missing (used for recovery:
-- "if a card disappears unexpectedly, it should be possible to recreate
-- it from the TuckState model").
function CardManager:ensureCardExists(tuckID)
  if self.canvases[tuckID] then
    return
  end
  local record = self.store:getByTuckID(tuckID)
  if record then
    self:reflowRail(record.screenUUID, record.spaceID, record.edge)
  end
end

--- Tear down every canvas and timer this manager owns. Idempotent.
function CardManager:stop()
  for tuckID in pairs(self.canvases) do
    self:destroy(tuckID)
  end
  self.canvases = {}
  self.collapsedFrames = {}
  self.hovered = {}
  self.searchMatched = {}
  for tuckID, timer in pairs(self._animTimers) do
    timer:stop()
  end
  self._animTimers = {}
end

return CardManager
