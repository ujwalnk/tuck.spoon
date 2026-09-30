--- Pure geometry module for rail stacking.
--
-- This module has zero dependency on Hammerspoon, application concepts,
-- window IDs, or thumbnails. It only knows about frames, edges, item
-- dimensions, and stacking rules, so it can be exercised by ordinary Lua
-- unit tests.
--
-- A "frame" here is always {x, y, w, h} in screen coordinates.

local M = {}

--- Compute a card's collapsed frame for `index` (1-based) among `count`
-- total cards, given:
--   area       - {x, y, w, h} work-area (or full-frame) rectangle
--   edge       - "left" | "right" | "top" | "bottom"
--   itemSize   - {w, h} size of a single (collapsed) card
--   margin     - distance from the start/end of the rail to the boundary
--   padding    - distance between adjacent cards
--   origin     - "center" | "start" | "end"
--   inset      - distance from the card's outer edge to the screen boundary
--                perpendicular to the rail (e.g. how far a left-rail card
--                sits from the left edge of the screen)
--
-- Returns a frame {x, y, w, h} for the requested index.
function M.frameForIndex(params)
  local area = params.area
  local edge = params.edge
  local itemSize = params.itemSize
  local margin = params.margin or 0
  local padding = params.padding or 0
  local origin = params.origin or "center"
  local inset = params.inset or 0
  local index = params.index
  local count = params.count

  assert(area and area.x and area.y and area.w and area.h, "area frame required")
  assert(edge == "left" or edge == "right" or edge == "top" or edge == "bottom", "invalid edge")
  assert(itemSize and itemSize.w and itemSize.h, "itemSize required")
  assert(index and index >= 1, "index must be >= 1")
  assert(count and count >= index, "count must be >= index")

  local vertical = (edge == "left" or edge == "right")
  -- Length of the rail axis (the axis along which cards stack) and the
  -- size of a single item along that axis.
  local railLength = vertical and area.h or area.w
  local itemAlong = vertical and itemSize.h or itemSize.w
  local itemAcross = vertical and itemSize.w or itemSize.h

  local totalStackLength = count * itemAlong + math.max(0, count - 1) * padding

  -- Compute the starting offset (from the beginning of the rail axis,
  -- i.e. top for left/right rails, left for top/bottom rails) of the
  -- first card in the stack.
  local startOffset
  if origin == "center" then
    startOffset = (railLength - totalStackLength) / 2
    -- Clamp so a stack that overflows the rail still begins within the
    -- margin rather than drifting past the screen boundary.
    if startOffset < margin then
      startOffset = margin
    end
  elseif origin == "start" then
    startOffset = margin
  else -- "end": stack grows from the end of the rail back toward the start
    startOffset = railLength - margin - totalStackLength
  end

  local alongOffset = startOffset + (index - 1) * (itemAlong + padding)

  -- Position across the rail axis (perpendicular): flush against the
  -- screen/work-area boundary for that edge, offset inward by `inset`.
  local acrossOffset
  if edge == "left" then
    acrossOffset = inset
  elseif edge == "right" then
    acrossOffset = area.w - inset - itemAcross
  elseif edge == "top" then
    acrossOffset = inset
  else -- bottom
    acrossOffset = area.h - inset - itemAcross
  end

  local frame
  if vertical then
    frame = {
      x = area.x + acrossOffset,
      y = area.y + alongOffset,
      w = itemAcross,
      h = itemAlong,
    }
  else
    frame = {
      x = area.x + alongOffset,
      y = area.y + acrossOffset,
      w = itemAlong,
      h = itemAcross,
    }
  end

  return frame
end

--- Compute frames for every card (1..count) on a rail in one call.
-- Same params as frameForIndex, minus `index`.
function M.frameForRail(params)
  local count = params.count
  local frames = {}
  for i = 1, count do
    local p = {}
    for k, v in pairs(params) do
      p[k] = v
    end
    p.index = i
    frames[i] = M.frameForIndex(p)
  end
  return frames
end

--- Compute the expanded frame for a card at collapsed frame `collapsed`,
-- given the edge it belongs to and its expanded size. The card's rail
-- anchor (the point flush against the work-area boundary) stays fixed;
-- expansion grows inward, away from the boundary, and is clamped so it
-- never grows toward/beyond the opposite screen boundary.
--
--   collapsed    - {x, y, w, h} collapsed frame, as produced above
--   edge         - "left" | "right" | "top" | "bottom"
--   expandedSize - {w, h}
--   area         - {x, y, w, h} bounding area (work-area or full frame),
--                  used to clamp growth so the card never crosses the
--                  far boundary.
function M.expandedFrame(collapsed, edge, expandedSize, area)
  assert(collapsed and edge and expandedSize)

  local dw = expandedSize.w - collapsed.w
  local dh = expandedSize.h - collapsed.h

  local frame = {
    x = collapsed.x,
    y = collapsed.y,
    w = expandedSize.w,
    h = expandedSize.h,
  }

  if edge == "left" then
    -- anchor stays at collapsed.x (flush left); grows rightward.
    frame.x = collapsed.x
    -- keep vertically centered on the collapsed card's vertical center
    frame.y = collapsed.y - dh / 2
  elseif edge == "right" then
    -- anchor is the right edge (collapsed.x + collapsed.w); grows leftward.
    local rightEdge = collapsed.x + collapsed.w
    frame.x = rightEdge - expandedSize.w
    frame.y = collapsed.y - dh / 2
  elseif edge == "top" then
    frame.y = collapsed.y
    frame.x = collapsed.x - dw / 2
  else -- bottom
    local bottomEdge = collapsed.y + collapsed.h
    frame.y = bottomEdge - expandedSize.h
    frame.x = collapsed.x - dw / 2
  end

  if area then
    -- Clamp so the expanded card never grows beyond the bounding area.
    if frame.x < area.x then
      frame.x = area.x
    end
    if frame.y < area.y then
      frame.y = area.y
    end
    if frame.x + frame.w > area.x + area.w then
      frame.x = area.x + area.w - frame.w
    end
    if frame.y + frame.h > area.y + area.h then
      frame.y = area.y + area.h - frame.h
    end
  end

  return frame
end

return M
