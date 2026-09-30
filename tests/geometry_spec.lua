local t = require("tests.testkit")
local geometry = require("space.geometry")

local function run()
  t.reset()

  -- Basic single-card centering on a left rail.
  do
    local area = { x = 0, y = 0, w = 1440, h = 900 }
    local frame = geometry.frameForIndex({
      area = area,
      edge = "left",
      itemSize = { w = 72, h = 72 },
      margin = 12,
      padding = 10,
      origin = "center",
      inset = 8,
      index = 1,
      count = 1,
    })
    t.eq(frame.x, 8, "single left card insets from left boundary")
    t.almostEq(frame.y, (900 - 72) / 2, 1e-6, "single card centers vertically on left rail")
    t.eq(frame.w, 72)
    t.eq(frame.h, 72)
  end

  -- Multiple cards on a left rail stay centered as a balanced block.
  do
    local area = { x = 0, y = 0, w = 1440, h = 900 }
    local frames = geometry.frameForRail({
      area = area,
      edge = "left",
      itemSize = { w = 72, h = 72 },
      margin = 12,
      padding = 10,
      origin = "center",
      inset = 8,
      count = 3,
    })
    t.eq(#frames, 3)
    local totalStack = 3 * 72 + 2 * 10
    local expectedStart = (900 - totalStack) / 2
    t.almostEq(frames[1].y, expectedStart, 1e-6, "first of 3 starts at centered offset")
    t.almostEq(frames[2].y, expectedStart + 72 + 10, 1e-6, "second card offset by item+padding")
    t.almostEq(frames[3].y, expectedStart + 2 * (72 + 10), 1e-6, "third card offset by 2x item+padding")
    -- All should share the same x (inset from left boundary).
    t.eq(frames[1].x, 8)
    t.eq(frames[2].x, 8)
    t.eq(frames[3].x, 8)
  end

  -- Start origin begins exactly at the margin from the start of the rail.
  do
    local area = { x = 0, y = 0, w = 1440, h = 900 }
    local frames = geometry.frameForRail({
      area = area,
      edge = "top",
      itemSize = { w = 72, h = 72 },
      margin = 12,
      padding = 10,
      origin = "start",
      inset = 8,
      count = 2,
    })
    t.eq(frames[1].x, 12, "start origin begins at margin")
    t.eq(frames[2].x, 12 + 72 + 10, "second card offset by item+padding from first")
    -- top edge: perpendicular offset is inset, y == area.y + inset
    t.eq(frames[1].y, 8)
  end

  -- End origin begins at margin from the end of the rail and grows back.
  do
    local area = { x = 0, y = 0, w = 1440, h = 900 }
    local frames = geometry.frameForRail({
      area = area,
      edge = "bottom",
      itemSize = { w = 72, h = 72 },
      margin = 12,
      padding = 10,
      origin = "end",
      inset = 8,
      count = 2,
    })
    -- railLength (w) = 1440, totalStack = 2*72+10=154
    -- startOffset = 1440 - 12 - 154 = 1274
    t.almostEq(frames[1].x, 1274, 1e-6, "end origin: first card starts at railLength-margin-stack")
    t.almostEq(frames[2].x, 1274 + 72 + 10, 1e-6, "second card follows first by item+padding")
    -- bottom edge: y = area.h - inset - itemAcross(h) = 900 - 8 - 72 = 820
    t.eq(frames[1].y, 820)
  end

  -- Right and bottom edges compute the perpendicular ("across") offset
  -- correctly, flush against their respective boundary.
  do
    local area = { x = 0, y = 0, w = 1440, h = 900 }
    local rightFrame = geometry.frameForIndex({
      area = area,
      edge = "right",
      itemSize = { w = 72, h = 72 },
      margin = 12,
      padding = 10,
      origin = "center",
      inset = 8,
      index = 1,
      count = 1,
    })
    t.eq(rightFrame.x, 1440 - 8 - 72, "right rail card flush against right boundary minus inset")

    local bottomFrame = geometry.frameForIndex({
      area = area,
      edge = "bottom",
      itemSize = { w = 72, h = 72 },
      margin = 12,
      padding = 10,
      origin = "center",
      inset = 8,
      index = 1,
      count = 1,
    })
    t.eq(bottomFrame.y, 900 - 8 - 72, "bottom rail card flush against bottom boundary minus inset")
  end

  -- Screens with negative coordinates (positioned left/above primary) are
  -- handled correctly -- the area's own origin is always respected.
  do
    local area = { x = -1920, y = -200, w = 1920, h = 1080 }
    local frame = geometry.frameForIndex({
      area = area,
      edge = "left",
      itemSize = { w = 72, h = 72 },
      margin = 12,
      padding = 10,
      origin = "start",
      inset = 8,
      index = 1,
      count = 1,
    })
    t.eq(frame.x, -1920 + 8, "negative-origin screen: left rail inset from area.x")
    t.eq(frame.y, -200 + 12, "negative-origin screen: start origin from area.y")
  end

  -- Reflow with a removed card leaves no gap: recomputing frameForRail
  -- with a smaller count re-balances every remaining card.
  do
    local area = { x = 0, y = 0, w = 1440, h = 900 }
    local before = geometry.frameForRail({
      area = area,
      edge = "left",
      itemSize = { w = 72, h = 72 },
      margin = 12,
      padding = 10,
      origin = "start",
      inset = 8,
      count = 3,
    })
    -- Simulate removing the middle card and reflowing the remaining 2.
    local after = geometry.frameForRail({
      area = area,
      edge = "left",
      itemSize = { w = 72, h = 72 },
      margin = 12,
      padding = 10,
      origin = "start",
      inset = 8,
      count = 2,
    })
    t.eq(before[1].y, after[1].y, "first card position unaffected by reflow")
    -- second remaining card should now sit where the old #2 used to be
    -- (immediately after #1), not leave a gap where old #3 was.
    t.eq(after[2].y, before[1].y + 72 + 10)
  end

  -- Expanded frame: left-edge card expands inward (rightward), anchor
  -- (left x, and rail flush edge) stays fixed.
  do
    local collapsed = { x = 8, y = 400, w = 72, h = 72 }
    local area = { x = 0, y = 0, w = 1440, h = 900 }
    local expanded = geometry.expandedFrame(collapsed, "left", { w = 220, h = 160 }, area)
    t.eq(expanded.x, 8, "left-edge expansion keeps left anchor fixed")
    t.eq(expanded.w, 220)
    t.eq(expanded.h, 160)
    -- vertical center should be preserved
    local collapsedCenterY = collapsed.y + collapsed.h / 2
    local expandedCenterY = expanded.y + expanded.h / 2
    t.almostEq(expandedCenterY, collapsedCenterY, 1e-6, "left expansion preserves vertical center")
  end

  -- Expanded frame: right-edge card expands leftward, right anchor fixed.
  do
    local collapsed = { x = 1440 - 8 - 72, y = 400, w = 72, h = 72 }
    local area = { x = 0, y = 0, w = 1440, h = 900 }
    local expanded = geometry.expandedFrame(collapsed, "right", { w = 220, h = 160 }, area)
    local rightEdge = collapsed.x + collapsed.w
    t.almostEq(expanded.x + expanded.w, rightEdge, 1e-6, "right-edge expansion keeps right anchor fixed")
  end

  -- Expanded frame never grows beyond the screen boundary: a card near
  -- the top of a top-rail (small y) clamps to area.y, not negative.
  do
    local collapsed = { x = 700, y = 0, w = 72, h = 72 }
    local area = { x = 0, y = 0, w = 1440, h = 900 }
    local expanded = geometry.expandedFrame(collapsed, "top", { w = 160, h = 220 }, area)
    t.isTrue(expanded.y >= area.y, "top expansion never crosses above the work area")
    t.isTrue(expanded.x >= area.x, "top expansion clamped within area horizontally (left)")
    t.isTrue(expanded.x + expanded.w <= area.x + area.w, "top expansion clamped within area horizontally (right)")
  end

  -- Depth-based positioning (parked / edge-reveal states).
  do
    local area = { x = 0, y = 0, w = 1440, h = 900 }
    local function frame(edge, depth, extra)
      local p = { area = area, edge = edge, itemSize = { w = 72, h = 72 }, margin = 12, padding = 10,
        origin = "start", inset = 8, index = 1, count = 1, depth = depth }
      for k, v in pairs(extra or {}) do p[k] = v end
      return geometry.frameForIndex(p)
    end
    -- Left: peek of 8px => only 8px of the 72px card is inside the screen.
    local left = frame("left", 8)
    t.eq(left.x, 8 - 72, "left parked: card hangs outside the left boundary")
    t.eq(left.x + left.w, 8, "left parked: exactly peek pixels visible")
    t.eq(left.w, 72, "parking never resizes the card")
    -- Right
    local right = frame("right", 8)
    t.eq(right.x, 1440 - 8, "right parked: only peek pixels inside")
    t.eq(right.w, 72)
    -- Edge reveal shows more, along-axis position identical.
    local leftReveal = frame("left", 40)
    t.eq(leftReveal.x + leftReveal.w, 40, "edge reveal exposes 40px")
    t.eq(leftReveal.y, left.y, "order/along position stable across depth states")
    -- depth == itemAcross + inset reproduces the classic inset frame.
    local classic = frame("left", nil)
    local viaDepth = frame("left", 72 + 8)
    t.eq(viaDepth.x, classic.x, "depth=size+inset matches inset form (left)")
    local classicR = frame("right", nil)
    local viaDepthR = frame("right", 72 + 8)
    t.eq(viaDepthR.x, classicR.x, "depth=size+inset matches inset form (right)")
    local classicB = frame("bottom", nil)
    local viaDepthB = frame("bottom", 72 + 8)
    t.eq(viaDepthB.y, classicB.y, "depth=size+inset matches inset form (bottom)")
    -- Negative-origin screen still respected for parked cards.
    local neg = geometry.frameForIndex({ area = { x = -1920, y = 0, w = 1920, h = 1080 }, edge = "right",
      itemSize = { w = 72, h = 72 }, index = 1, count = 1, depth = 8, origin = "start" })
    t.eq(neg.x, -1920 + 1920 - 8, "right parked on negative-coordinate screen")
  end

  -- Expansion anchors on the full-depth frame, growing inward and staying in bounds.
  do
    local area = { x = 0, y = 0, w = 1440, h = 900 }
    local full = geometry.frameForIndex({ area = area, edge = "left", itemSize = { w = 72, h = 72 },
      origin = "start", margin = 12, inset = 8, index = 1, count = 1 })
    local exp = geometry.expandedFrame(full, "left", { w = 220, h = 160 }, area)
    t.isTrue(exp.x >= area.x and exp.y >= area.y, "expanded card stays inside the usable area")
    t.eq(exp.x, full.x, "left expansion anchored at boundary-relative full frame")
  end

  -- Trigger zone strips.
  do
    local area = { x = 100, y = 50, w = 1000, h = 800 }
    local l = geometry.triggerZoneFrame(area, "left", 6)
    t.eq(l.x, 100); t.eq(l.w, 6); t.eq(l.h, 800)
    local r = geometry.triggerZoneFrame(area, "right", 6)
    t.eq(r.x, 1094); t.eq(r.w, 6)
    local tp = geometry.triggerZoneFrame(area, "top", 6)
    t.eq(tp.y, 50); t.eq(tp.h, 6)
    local b = geometry.triggerZoneFrame(area, "bottom", 6)
    t.eq(b.y, 844)
  end

  t.report("geometry_spec")
  return #t.failures == 0
end

return run
