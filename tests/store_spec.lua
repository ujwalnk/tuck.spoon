local t = require("tests.testkit")
local Store = require("state.store")

local function makeRecord(overrides)
  local base = {
    windowID = 1001,
    tuckID = "tuck-1",
    bundleID = "com.apple.Safari",
    appName = "Safari",
    windowTitle = "Example",
    frame = { x = 0, y = 0, w = 800, h = 600 },
    screenUUID = "SCREEN-A",
    spaceID = 1,
    edge = "left",
    order = 1,
  }
  for k, v in pairs(overrides or {}) do
    base[k] = v
  end
  return base
end

local function run()
  t.reset()

  -- Basic add/get/remove round trip.
  do
    local store = Store.new()
    store:addWindow(makeRecord({}))
    local rec = store:getByWindowID(1001)
    t.isTrue(rec ~= nil, "record retrievable by windowID")
    t.eq(rec.tuckID, "tuck-1")

    local byTuck = store:getByTuckID("tuck-1")
    t.eq(byTuck.windowID, 1001, "record retrievable by tuckID")

    local rail = store:railRecords("SCREEN-A", 1, "left")
    t.eq(#rail, 1, "rail has one record")
    t.eq(rail[1].tuckID, "tuck-1")

    local removed, shelfKey = store:removeWindow(1001)
    t.eq(removed.windowID, 1001, "removeWindow returns the removed record")
    t.eq(shelfKey, "SCREEN-A|1")
    t.isNil(store:getByWindowID(1001), "windows index cleared after remove")
    t.isNil(store:getByTuckID("tuck-1"), "byTuckID index cleared after remove")
    t.eq(#store:railRecords("SCREEN-A", 1, "left"), 0, "rail empty after remove")
  end

  -- Idempotent removal: removing twice does not error and returns nil.
  do
    local store = Store.new()
    store:addWindow(makeRecord({}))
    store:removeWindow(1001)
    local removedAgain = store:removeWindow(1001)
    t.isNil(removedAgain, "second removeWindow call is a harmless no-op")
  end

  -- Multiple windows, same bundle ID, remain distinct (Safari A/B/C example).
  do
    local store = Store.new()
    store:addWindow(makeRecord({ windowID = 4812, tuckID = "tuck-A", edge = "left" }))
    store:addWindow(makeRecord({ windowID = 5179, tuckID = "tuck-B", edge = "left" }))
    store:addWindow(makeRecord({ windowID = 6243, tuckID = "tuck-C", edge = "left" }))

    local rail = store:railRecords("SCREEN-A", 1, "left")
    t.eq(#rail, 3, "three distinct Safari windows tracked independently")

    -- Removing the middle one by tuckID leaves the others, in order,
    -- with no gap (rail is a compacted array).
    store:removeByTuckID("tuck-B")
    local after = store:railRecords("SCREEN-A", 1, "left")
    t.eq(#after, 2)
    t.eq(after[1].tuckID, "tuck-A")
    t.eq(after[2].tuckID, "tuck-C")
  end

  -- Separate shelves per screen/space combination (multi-monitor / multi-space).
  do
    local store = Store.new()
    store:addWindow(makeRecord({ windowID = 1, tuckID = "t1", screenUUID = "MBP", spaceID = 1, edge = "left" }))
    store:addWindow(makeRecord({ windowID = 2, tuckID = "t2", screenUUID = "EXT", spaceID = 1, edge = "right" }))
    store:addWindow(makeRecord({ windowID = 3, tuckID = "t3", screenUUID = "MBP", spaceID = 2, edge = "bottom" }))

    t.eq(#store:railRecords("MBP", 1, "left"), 1)
    t.eq(#store:railRecords("EXT", 1, "right"), 1)
    t.eq(#store:railRecords("MBP", 2, "bottom"), 1)
    -- Cross-contamination check: MBP/space1/right should be empty.
    t.eq(#store:railRecords("MBP", 1, "right"), 0)
  end

  -- windowsForSpace: scope helper for keyboard search (space vs screenAndSpace).
  do
    local store = Store.new()
    store:addWindow(makeRecord({ windowID = 1, tuckID = "t1", screenUUID = "MBP", spaceID = 1, edge = "left" }))
    store:addWindow(makeRecord({ windowID = 2, tuckID = "t2", screenUUID = "EXT", spaceID = 1, edge = "right" }))
    store:addWindow(makeRecord({ windowID = 3, tuckID = "t3", screenUUID = "MBP", spaceID = 2, edge = "bottom" }))

    local wholeSpace = store:windowsForSpace(1)
    t.eq(#wholeSpace, 2, "space-wide scope returns windows across screens for that space")

    local screenAndSpace = store:windowsForSpace(1, "MBP")
    t.eq(#screenAndSpace, 1, "screenAndSpace scope restricts to one screen")
  end

  -- Duplicate insert guards (no duplicate tuck records for one window).
  do
    local store = Store.new()
    store:addWindow(makeRecord({}))
    local ok, err = pcall(function()
      store:addWindow(makeRecord({}))
    end)
    t.isFalse(ok, "adding the same windowID twice must error, not silently duplicate")
  end

  -- nextTuckID never collides and is stable/opaque.
  do
    local store = Store.new()
    local seen = {}
    for _ = 1, 50 do
      local id = store:nextTuckID()
      t.isNil(seen[id], "tuckID must be unique across calls")
      seen[id] = true
    end
  end

  t.report("store_spec")
  return #t.failures == 0
end

return run
