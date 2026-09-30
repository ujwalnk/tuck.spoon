--- Card renderer.
--
-- Accepts a TuckedWindow record plus card configuration and (re)builds the
-- element list of an existing `hs.canvas` object to represent it. Does
-- NOT know how the real window is minimized or restored, and does not
-- own the canvas's frame/position (that is the card manager's job, using
-- space/geometry.lua) -- this module only owns *what is drawn inside*
-- the canvas at whatever size the canvas currently is.
--
-- Element order (back to front): background, thumbnail, app icon
-- (overlapping the thumbnail, bottom-left, "parked application" style),
-- app name, window title.

local Renderer = {}

local function clamp01(n)
  if n < 0 then
    return 0
  end
  if n > 1 then
    return 1
  end
  return n
end

--- Build the element list for `record` at `size` = {w, h} (the canvas's
-- own current size -- collapsed or expanded, the renderer does not care
-- which), honoring `cardConfig` (the `card` sub-table of the Spoon's
-- configuration) for which optional pieces to draw.
--
-- `icon` is an hs.image or nil. `thumbnail` is an hs.image or nil.
function Renderer.buildElements(record, size, cardConfig, icon, thumbnail)
  local elements = {}
  local w, h = size.w, size.h

  -- Background: rounded rect communicating "parked/tucked", not a normal
  -- window chrome.
  elements[#elements + 1] = {
    type = "rectangle",
    action = "fill",
    frame = { x = 0, y = 0, w = w, h = h },
    roundedRectRadii = { xRadius = cardConfig.cornerRadius, yRadius = cardConfig.cornerRadius },
    fillColor = { red = 0.13, green = 0.13, blue = 0.15, alpha = clamp01(cardConfig.opacity) },
    strokeColor = { white = 1, alpha = 0.08 },
    strokeWidth = 1,
    withShadow = true,
  }

  local hasThumbnail = cardConfig.showThumbnail and thumbnail ~= nil
  local hasIcon = cardConfig.showAppIcon and icon ~= nil
  local hasName = cardConfig.showAppName and record.appName ~= nil and record.appName ~= ""
  local hasTitle = cardConfig.showWindowTitle and record.windowTitle ~= nil and record.windowTitle ~= ""

  -- Reserve space at the bottom for text labels, if any are enabled.
  local labelLines = (hasName and 1 or 0) + (hasTitle and 1 or 0)
  local labelHeight = labelLines > 0 and math.min(h * 0.32, 16 * labelLines + 6) or 0

  local mediaFrame = { x = 3, y = 3, w = w - 6, h = h - labelHeight - 6 }
  if mediaFrame.h < 4 then
    mediaFrame.h = 4
  end

  if hasThumbnail then
    elements[#elements + 1] = {
      type = "image",
      image = thumbnail,
      frame = mediaFrame,
      imageAlignment = "center",
      imageScaling = "scaleProportionally",
      roundedRectRadii = { xRadius = cardConfig.cornerRadius * 0.6, yRadius = cardConfig.cornerRadius * 0.6 },
      clipToPath = true,
    }
  elseif hasIcon then
    -- No thumbnail (permission unavailable or capture failed, or
    -- disabled): the icon becomes the primary media element, centered
    -- and reasonably large, rather than tiny in a corner.
    local iconSize = math.min(mediaFrame.w, mediaFrame.h) * 0.62
    elements[#elements + 1] = {
      type = "image",
      image = icon,
      frame = {
        x = mediaFrame.x + (mediaFrame.w - iconSize) / 2,
        y = mediaFrame.y + (mediaFrame.h - iconSize) / 2,
        w = iconSize,
        h = iconSize,
      },
      imageAlignment = "center",
      imageScaling = "scaleProportionally",
    }
  end

  -- If we drew a thumbnail AND an icon is available, overlay the icon in
  -- the bottom-left corner of the media area, integrated/overlapping
  -- style, per spec ("visually overlap or integrate with the thumbnail").
  if hasThumbnail and hasIcon then
    local badgeSize = math.max(14, math.min(w, h) * 0.28)
    elements[#elements + 1] = {
      type = "rectangle",
      action = "fill",
      frame = {
        x = mediaFrame.x - 1,
        y = mediaFrame.y + mediaFrame.h - badgeSize + 1,
        w = badgeSize + 2,
        h = badgeSize + 2,
      },
      roundedRectRadii = { xRadius = 6, yRadius = 6 },
      fillColor = { red = 0.13, green = 0.13, blue = 0.15, alpha = 0.95 },
    }
    elements[#elements + 1] = {
      type = "image",
      image = icon,
      frame = {
        x = mediaFrame.x + 1,
        y = mediaFrame.y + mediaFrame.h - badgeSize + 2,
        w = badgeSize - 2,
        h = badgeSize - 2,
      },
      imageAlignment = "center",
      imageScaling = "scaleProportionally",
    }
  end

  if hasName or hasTitle then
    local textY = h - labelHeight
    if hasName then
      elements[#elements + 1] = {
        type = "text",
        text = record.appName,
        frame = { x = 4, y = textY, w = w - 8, h = 15 },
        textSize = 11,
        textColor = { white = 1, alpha = 0.95 },
        textAlignment = "center",
        textLineBreak = "truncateTail",
      }
      textY = textY + 15
    end
    if hasTitle then
      elements[#elements + 1] = {
        type = "text",
        text = record.windowTitle or "",
        frame = { x = 4, y = textY, w = w - 8, h = 14 },
        textSize = 9.5,
        textColor = { white = 1, alpha = 0.65 },
        textAlignment = "center",
        textLineBreak = "truncateTail",
      }
    end
  end

  return elements
end

return Renderer
