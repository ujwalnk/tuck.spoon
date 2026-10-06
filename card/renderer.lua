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
-- (a badge overlapping the thumbnail, anchored toward the INWARD side of
-- the card -- the side facing the usable screen area), app name, window
-- title.
--
-- Thumbnails arrive already rounded (card/preview.lua bakes transparent
-- rounded corners into the image, because an image element letterboxes
-- inside its frame and clipping the frame would not round the visible
-- picture). `Renderer.thumbnailRadius` is the single place that derives
-- that radius from the card's configured corner radius.

local Renderer = {}

-- Padding between the card edge and its media area, as a fraction of the
-- canvas. Shared by buildElements and the thumbnail radius derivation.
local PAD = 0.04
-- Badge geometry (fractions of the canvas) and its gap to the inward edge.
local BADGE_W = 0.28
local BADGE_INWARD_MARGIN = 0.02

--- Which side of the card faces the usable screen area, expressed as the
-- anchor the app-icon badge uses. Left rail -> inward is RIGHT; right
-- rail -> inward is LEFT; top rail -> inward is BOTTOM; bottom rail ->
-- inward is TOP. Along the other axis the badge is centred for top and
-- bottom rails (so those cards stay balanced) and sits on the bottom for
-- left/right rails.
--   returns { h = "left"|"right"|"center", v = "top"|"bottom" }
function Renderer.inwardAnchor(edge)
  if edge == "left" then
    return { h = "right", v = "bottom" }
  elseif edge == "right" then
    return { h = "left", v = "bottom" }
  elseif edge == "top" then
    return { h = "center", v = "bottom" }
  end
  return { h = "center", v = "top" } -- bottom rail
end

local function alignmentName(anchor)
  local v, h = anchor.v, anchor.h
  if h == "center" then
    return v -- "top" | "bottom"
  end
  return v .. h:sub(1, 1):upper() .. h:sub(2) -- e.g. "bottomRight"
end

--- Layout of the media area for a card configuration. Returns the label
-- fraction, the media height fraction, and the media size in pixels at
-- the collapsed card size.
local function mediaLayout(cardConfig, size, hasName, hasTitle)
  local h = size.h
  local labelLines = (hasName and 1 or 0) + (hasTitle and 1 or 0)
  local labelPx = labelLines > 0 and math.min(h * 0.32, 15 * labelLines + 6) or 0
  local labelFrac = labelPx / h
  local mediaH = 1 - labelFrac - 2 * PAD
  if mediaH < 0.1 then
    mediaH = 0.1
  end
  return {
    labelLines = labelLines,
    labelFrac = labelFrac,
    mediaH = mediaH,
    mediaPxW = (1 - 2 * PAD) * size.w,
    mediaPxH = mediaH * size.h,
  }
end

--- Radius (pixels, at the collapsed card size) of the thumbnail's
-- corners: concentric with the card's own rounded corner, i.e. the card's
-- configured radius minus the padding between card edge and thumbnail.
function Renderer.thumbnailRadius(cardConfig)
  local pad = PAD * math.min(cardConfig.collapsedWidth, cardConfig.collapsedHeight)
  return math.max(0, cardConfig.cornerRadius - pad)
end

--- Width (pixels) at which a picture of `aspect` (w/h) is shown, a
-- reference used to turn the card-derived corner radius into the baked
-- image's pixels. The picture is baked ONCE yet displayed at every card
-- size (parked/revealed compact card, expanded card), and scaling an image
-- scales its corners with it, so a radius tuned for one size would look
-- too square at the small size or too blobby at the large one. The
-- geometric mean of the compact and expanded display widths keeps the
-- corner within the same ~1.7x factor of the intended radius at both.
function Renderer.referenceDisplayWidth(cardConfig, aspect)
  local function displayWidth(size)
    local layout = mediaLayout(cardConfig, size, cardConfig.showAppName, cardConfig.showWindowTitle)
    return math.min(layout.mediaPxW, layout.mediaPxH * aspect)
  end
  local compact = displayWidth({ w = cardConfig.collapsedWidth, h = cardConfig.collapsedHeight })
  local expanded = displayWidth({ w = cardConfig.expandedWidth, h = cardConfig.expandedHeight })
  return math.sqrt(compact * expanded)
end

--- Size (pixels) in which a thumbnail is shown on a collapsed card; the
-- preview baker uses it to convert Renderer.thumbnailRadius into image
-- pixels for an image of a given size.
function Renderer.collapsedMediaSize(cardConfig)
  local layout = mediaLayout(
    cardConfig,
    { w = cardConfig.collapsedWidth, h = cardConfig.collapsedHeight },
    cardConfig.showAppName,
    cardConfig.showWindowTitle
  )
  return layout.mediaPxW, layout.mediaPxH
end

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

  elements[#elements + 1] = {
    type = "rectangle",
    action = "fill",
    roundedRectRadii = { xRadius = cardConfig.cornerRadius, yRadius = cardConfig.cornerRadius },
    fillColor = {
      red = cardConfig.backgroundColor.red,
      green = cardConfig.backgroundColor.green,
      blue = cardConfig.backgroundColor.blue,
      alpha = clamp01(cardConfig.opacity),
    },
    strokeColor = {
      red = cardConfig.borderColor.red,
      green = cardConfig.borderColor.green,
      blue = cardConfig.borderColor.blue,
      alpha = 0.08,
    },
    strokeWidth = 1,
    withShadow = true,
  }

  local hasThumbnail = cardConfig.showThumbnail and thumbnail ~= nil
  local hasIcon = cardConfig.showAppIcon and icon ~= nil
  local hasName = cardConfig.showAppName and record.appName ~= nil and record.appName ~= ""
  local hasTitle = cardConfig.showWindowTitle and record.windowTitle ~= nil and record.windowTitle ~= ""

  local layout = mediaLayout(cardConfig, size, hasName, hasTitle)
  local labelLines, labelFrac, mediaH = layout.labelLines, layout.labelFrac, layout.mediaH
  local pad = PAD
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
    -- Icon badge overlapping the thumbnail, anchored toward the inward
    -- side of the card (see Renderer.inwardAnchor). Only the badge moves;
    -- the rest of the card is identical for every edge.
    local anchor = Renderer.inwardAnchor(record.edge)
    local bw = BADGE_W
    local bh = mediaH * 0.36
    local bx
    if anchor.h == "right" then
      bx = 1 - BADGE_INWARD_MARGIN - bw
    elseif anchor.h == "left" then
      bx = BADGE_INWARD_MARGIN
    else
      bx = (1 - bw) / 2
    end
    local by
    if anchor.v == "bottom" then
      by = pad + mediaH * 0.98 - bh
    else
      by = pad + mediaH * 0.02
    end
    elements[#elements + 1] = {
      type = "image",
      image = icon,
      frame = { x = pct(bx), y = pct(by), w = pct(bw), h = pct(bh) },
      imageAlignment = alignmentName(anchor),
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
        textColor = {
          red = cardConfig.textColor.red,
          green = cardConfig.textColor.green,
          blue = cardConfig.textColor.blue,
          alpha = 0.95,
        },
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
        textColor = {
          red = cardConfig.textColor.red,
          green = cardConfig.textColor.green,
          blue = cardConfig.textColor.blue,
          alpha = 0.65,
        },
        textAlignment = "center",
        textLineBreak = "truncateTail",
      }
    end
  end

  return elements
end

return Renderer
