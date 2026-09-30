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

--- Build the element list for `record`, honoring `cardConfig` for which
-- optional pieces to draw. `icon`/`thumbnail` are hs.image or nil.
--
-- Every element frame is expressed in PERCENT of the canvas (hs.canvas
-- accepts percentage strings for element frames and adjusts elements when
-- the canvas is resized). The layout therefore scales continuously while
-- the card animates between its parked / revealed / expanded sizes, and
-- the content never has to be re-rendered (no pop) during motion.
-- `size` is the reference (collapsed) size used only to convert the fixed
-- pixel height of the text labels into a percentage.
function Renderer.buildElements(record, size, cardConfig, icon, thumbnail)
  local elements = {}
  local h = size.h

  elements[#elements + 1] = {
    type = "rectangle",
    action = "fill",
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

  local labelLines = (hasName and 1 or 0) + (hasTitle and 1 or 0)
  local labelPx = labelLines > 0 and math.min(h * 0.32, 15 * labelLines + 6) or 0
  local labelFrac = labelPx / h

  local pad = 0.04
  local mediaH = 1 - labelFrac - 2 * pad
  if mediaH < 0.1 then
    mediaH = 0.1
  end
  local function pct(f)
    return string.format("%.4f%%", f * 100)
  end
  local media = { x = pct(pad), y = pct(pad), w = pct(1 - 2 * pad), h = pct(mediaH) }

  if hasThumbnail then
    elements[#elements + 1] = {
      type = "image",
      image = thumbnail,
      frame = media,
      imageAlignment = "center",
      imageScaling = "scaleProportionally",
    }
  elseif hasIcon then
    -- No thumbnail (no permission, capture failed, or disabled): the
    -- native icon becomes the centred primary image.
    elements[#elements + 1] = {
      type = "image",
      image = icon,
      frame = { x = pct(0.2), y = pct(pad + mediaH * 0.1), w = pct(0.6), h = pct(mediaH * 0.8) },
      imageAlignment = "center",
      imageScaling = "scaleProportionally",
    }
  end

  if hasThumbnail and hasIcon then
    -- Icon badge overlapping the thumbnail's bottom-left corner.
    elements[#elements + 1] = {
      type = "image",
      image = icon,
      frame = { x = pct(pad + 0.01), y = pct(pad + mediaH * 0.62), w = pct(0.28), h = pct(mediaH * 0.36) },
      imageAlignment = "bottomLeft",
      imageScaling = "scaleProportionally",
    }
  end

  if hasName or hasTitle then
    local y = 1 - labelFrac - pad * 0.25
    local lineFrac = labelFrac / labelLines
    if hasName then
      elements[#elements + 1] = {
        type = "text",
        text = record.appName,
        frame = { x = pct(0.03), y = pct(y), w = pct(0.94), h = pct(lineFrac) },
        textSize = 11,
        textColor = { white = 1, alpha = 0.95 },
        textAlignment = "center",
        textLineBreak = "truncateTail",
      }
      y = y + lineFrac
    end
    if hasTitle then
      elements[#elements + 1] = {
        type = "text",
        text = record.windowTitle or "",
        frame = { x = pct(0.03), y = pct(y), w = pct(0.94), h = pct(lineFrac) },
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
