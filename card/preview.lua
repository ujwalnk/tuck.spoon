--- Preview (thumbnail) manager.
--
-- Handles:
--  * determining whether Screen Recording permission is available
--    (`hs.screenRecordingState`, without prompting -- we never want a
--    tuck keystroke to unexpectedly trigger a system permission dialog);
--  * capturing a snapshot of a window immediately before it is minimized;
--  * returning nil when unavailable or on any capture failure;
--  * the caller (window/manager.lua) is responsible for caching the
--    resulting image on the TuckedWindow record -- this module never
--    recaptures or polls.
--
-- The rest of the Spoon never needs to understand Screen Recording
-- permission details; it only ever asks this module "give me a snapshot
-- (or nil)".
--
-- ROUNDED CORNERS. A card shows its thumbnail with `scaleProportionally`,
-- which letterboxes the picture inside its frame, so clipping the frame
-- would round the frame and not the visible picture. Instead the snapshot
-- is redrawn once, off-screen, through a rounded clip path
-- (hs.canvas "clip" action + "resetClip" element, then
-- hs.canvas:imageFromCanvas()), producing an image whose own corners are
-- transparent and rounded. That image then scales with the card with no
-- re-rendering, so the corners stay clean while the card animates. The
-- radius comes from the card's configured cornerRadius (see
-- Renderer.thumbnailRadius). The same pass downsizes oversized snapshots.
-- If baking fails the plain snapshot is used: a thumbnail problem never
-- prevents tucking.

local Renderer = require("card.renderer")

-- Longest side (pixels) a stored thumbnail is downsized to, as a multiple
-- of the card's expanded size (covers a 2x display).
local MAX_SIZE_FACTOR = 2

local PreviewManager = {}
PreviewManager.__index = PreviewManager

function PreviewManager.new(hsRef, logger)
  local self = setmetatable({}, PreviewManager)
  self.hs = hsRef
  self.logger = logger
  return self
end

--- Returns true/false. Never prompts (shouldPrompt = false) -- tucking a
-- window must never be interrupted by a permission dialog. Users grant
-- Screen Recording permission the normal way (System Settings), which
-- README.md documents.
function PreviewManager:hasPermission()
  local hs = self.hs
  local ok, enabled = pcall(function()
    return hs.screenRecordingState(false)
  end)
  if ok then
    return enabled == true
  end
  -- If the API itself is unavailable (unlikely, but defensive per spec:
  -- "graceful handling of Screen Recording permission problems"), treat
  -- as unavailable rather than erroring.
  if self.logger then
    self.logger.w("Tuck: hs.screenRecordingState unavailable; disabling thumbnail capture")
  end
  return false
end

--- Redraw `image` with rounded, transparent corners (and downsized if
-- huge). Returns a new hs.image, or `image` itself if it cannot be
-- processed. `cardConfig` is the `card` configuration table.
function PreviewManager:roundedThumbnail(image, cardConfig)
  if not image or not cardConfig then
    return image
  end
  local ok, result = pcall(function()
    local size = image:size()
    if type(size) ~= "table" or not size.w or not size.h or size.w <= 0 or size.h <= 0 then
      return image
    end
    local maxDim = MAX_SIZE_FACTOR * math.max(cardConfig.expandedWidth, cardConfig.expandedHeight)
    local scale = math.min(1, maxDim / math.max(size.w, size.h))
    local tw = math.max(1, math.floor(size.w * scale + 0.5))
    local th = math.max(1, math.floor(size.h * scale + 0.5))

    -- Convert the card-derived radius (pixels) into pixels of this image
    -- using the picture's reference display width (see
    -- Renderer.referenceDisplayWidth), and never rounder than a quarter
    -- of its short side.
    local displayW = Renderer.referenceDisplayWidth(cardConfig, tw / th)
    local radius = Renderer.thumbnailRadius(cardConfig) * (tw / displayW)
    radius = math.min(radius, 0.25 * math.min(tw, th))

    local canvas = self.hs.canvas.new({ x = 0, y = 0, w = tw, h = th })
    local baked
    local okDraw, errDraw = pcall(function()
      canvas:replaceElements({
        {
          type = "rectangle",
          action = "clip",
          frame = { x = 0, y = 0, w = tw, h = th },
          roundedRectRadii = { xRadius = radius, yRadius = radius },
        },
        {
          type = "image",
          image = image,
          frame = { x = 0, y = 0, w = tw, h = th },
          imageScaling = "scaleToFit", -- same aspect as the frame: no distortion
        },
        { type = "resetClip" },
      })
      baked = canvas:imageFromCanvas()
    end)
    pcall(function()
      canvas:delete()
    end)
    if not okDraw then
      error(errDraw)
    end
    return baked or image
  end)
  if ok then
    return result
  end
  if self.logger then
    self.logger.d("Tuck: could not round thumbnail corners (using the plain snapshot): " .. tostring(result))
  end
  return image
end

--- Write `image` to `path` as PNG. Returns true on success. Never raises.
function PreviewManager:save(image, path)
  local ok, result = pcall(function()
    return image:saveToFile(path)
  end)
  if not ok or result == false then
    if self.logger then
      self.logger.d("Tuck: could not write thumbnail cache file " .. tostring(path))
    end
    return false
  end
  return true
end

--- Load a cached thumbnail, or nil. Never raises.
function PreviewManager:load(path)
  local ok, image = pcall(function()
    return self.hs.image.imageFromPath(path)
  end)
  if ok and image then
    return image
  end
  return nil
end

--- Capture a snapshot of `window` (an hs.window object) if enabled and
-- permitted, rounded per `cardConfig` when given. Returns an hs.image
-- object, or nil. Never raises: any failure (permission denied, window
-- already gone, snapshot API unavailable) is logged at debug level and
-- results in nil, never an error that could abort the tuck operation in
-- progress.
function PreviewManager:capture(window, enabled, cardConfig)
  if not enabled then
    return nil
  end
  if not self:hasPermission() then
    if self.logger then
      self.logger.d("Tuck: Screen Recording permission unavailable; using blank preview")
    end
    return nil
  end

  local ok, image = pcall(function()
    return window:snapshot()
  end)

  if ok and image then
    return self:roundedThumbnail(image, cardConfig)
  end

  if self.logger then
    self.logger.d("Tuck: window snapshot capture failed/unavailable; continuing without a thumbnail")
  end
  return nil
end

return PreviewManager
