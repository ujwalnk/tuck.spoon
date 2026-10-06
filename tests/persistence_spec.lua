--- Persistence, startup reconciliation, multi-window identity across a
-- Hammerspoon restart, and lifecycle cleanup of persisted state.

local t = require("tests.testkit")
local H = require("tests.harness")
local Persistence = require("state.persistence")

local function statePath(dir)
  return dir .. "/state.json"
end

local function readState(hs, dir)
  local text = H.readFile(statePath(dir))
  if not text then
    return nil
  end
  return hs.json.decode(text)
end

local function flush(hs)
  hs._fireAllTimers()
end

local function recordCount(Tuck)
  return #Tuck.store:allWindows()
end

local function listDir(dir)
  local out = {}
  local p = io.popen("ls -1 '" .. dir .. "'")
  for line in p:lines() do
    out[#out + 1] = line
  end
  p:close()
  return out
end

local function withScreenRecording(hs)
  hs.screenRecordingState = function()
    return true
  end
end

local function run()
  t.reset()

  -- ===== A tuck creates a valid, versioned, userdata-free state file =====
  do
    local hs, Tuck, dir = H.boot()
    local win = H.newWin(hs, "Safari", { title = "Home", frame = { x = 50, y = 60, w = 700, h = 500 } })
    H.tuck(hs, win, "left")
    t.isNil(H.readFile(statePath(dir)), "writes are debounced, not synchronous with the tuck")
    local pending = 0
    for _, h in ipairs(hs._pendingTimers) do
      if not h.repeating and not h.stopped and h.seconds == Tuck.config.persistence.debounce then pending = pending + 1 end
    end
    t.eq(pending, 1, "exactly one coalesced write is pending")
    flush(hs)
    local doc = readState(hs, dir)
    t.isTrue(doc ~= nil, "state.json is valid JSON")
    t.eq(doc.version, Persistence.SCHEMA_VERSION, "schema is versioned")
    t.eq(#doc.records, 1)
    local r = doc.records[1]
    local rec = Tuck.store:getByWindowID(win.id())
    t.eq(r.tuckID, rec.tuckID); t.eq(r.windowID, win.id())
    t.eq(r.pid, win.application().pid()); t.eq(r.bundleID, "com.safari"); t.eq(r.appName, "Safari")
    t.eq(r.windowTitle, "Home"); t.eq(r.spaceID, 1); t.eq(r.screenUUID, "SCREEN-MAIN")
    t.eq(r.edge, "left"); t.eq(r.order, 1); t.eq(r.mechanism, "hide")
    t.eq(r.frame.x, 50); t.eq(r.frame.w, 700)
    for k in pairs(r) do
      local allowed = { tuckID = 1, windowID = 1, pid = 1, bundleID = 1, appName = 1, windowTitle = 1, frame = 1,
        spaceID = 1, screenUUID = 1, edge = 1, order = 1, mechanism = 1, thumbnailFile = 1 }
      t.isTrue(allowed[k] ~= nil, "only plain whitelisted fields persisted (found " .. k .. ")")
    end
    local text = H.readFile(statePath(dir))
    t.isNil(text:find("hover"), "no transient state in the file")
    t.isNil(text:find("searchMatched"))
    local listing = table.concat(listDir(dir), ",")
    t.isNil(listing:find("%.tmp"), "atomic replace leaves no temp file behind")
    Tuck:stop()
  end

  -- ===== Reload reconstructs records, shelves and cards; never unhides =====
  do
    local hs, Tuck, dir = H.boot({ prepare = function(h) h._addScreen("EXT", { x = -1920, y = 0, w = 1920, h = 1080 }) end })
    local ext = hs._screens[2]
    local a = H.newWin(hs, "Safari", { title = "A", frame = { x = 10, y = 10, w = 600, h = 400 } })
    local b = H.newWin(hs, "Safari", { title = "B", frame = { x = 20, y = 20, w = 610, h = 410 }, screen = ext })
    local c = H.newWin(hs, "Safari", { title = "C", frame = { x = 30, y = 30, w = 620, h = 420 } })
    H.tuck(hs, a, "left"); H.tuck(hs, b, "right")
    hs._activeSpaces["SCREEN-MAIN"] = 2
    H.tuck(hs, c, "up")
    hs._activeSpaces["SCREEN-MAIN"] = 1
    local before = {}
    for _, w in ipairs({ a, b, c }) do
      local rec = Tuck.store:getByWindowID(w.id())
      before[w.id()] = { tuckID = rec.tuckID, edge = rec.edge, screenUUID = rec.screenUUID, spaceID = rec.spaceID, mech = rec.mechanism }
    end

    local hs2, T2 = H.reload(hs, Tuck)
    t.eq(recordCount(T2), 3, "all three tucks reconstructed")
    for _, w in ipairs({ a, b, c }) do
      local rec = T2.store:getByWindowID(w.id())
      t.isTrue(rec ~= nil, "record for window " .. w.id())
      local was = before[w.id()]
      t.eq(rec.tuckID, was.tuckID, "tuckID preserved")
      t.eq(rec.edge, was.edge); t.eq(rec.screenUUID, was.screenUUID); t.eq(rec.spaceID, was.spaceID)
      t.eq(rec.mechanism, was.mech)
      t.isTrue(T2.cardManager.canvases[rec.tuckID] ~= nil, "card recreated")
    end
    t.eq(H.liveCanvases(hs2), 3, "exactly one live card per tuck (no duplicates)")
    t.isFalse(a.isVisible() or b.isVisible() or c.isVisible(), "hidden windows stay hidden after the restart")
    t.eq(#T2.store:railRecords("SCREEN-MAIN", 1, "left"), 1)
    t.eq(#T2.store:railRecords("EXT", 1, "right"), 1, "same app, other screen = its own shelf")
    t.eq(#T2.store:railRecords("SCREEN-MAIN", 2, "top"), 1, "same app, other Space = its own shelf")
    -- cards start parked: no hover / reveal / search state is restored
    local fa = H.frameOf(T2, a)
    t.eq(fa.x + fa.w, 8, "card starts parked")
    t.isNil(next(T2.cardManager.hovered)); t.isNil(next(T2.cardManager.searchMatched))
    t.isNil(next(T2.cardManager.railRevealed))
    T2:stop()
  end

  -- ===== Rail order survives =====
  do
    local hs, Tuck = H.boot()
    local w1 = H.newWin(hs, "One", { title = "1" }); local w2 = H.newWin(hs, "Two", { title = "2" })
    local w3 = H.newWin(hs, "Three", { title = "3" })
    H.tuck(hs, w1, "left"); H.tuck(hs, w2, "left"); H.tuck(hs, w3, "left")
    local _, T2 = H.reload(hs, Tuck)
    local order = {}
    for _, r in ipairs(T2.store:railRecords("SCREEN-MAIN", 1, "left")) do order[#order + 1] = r.windowID end
    t.eq(order[1], w1.id()); t.eq(order[2], w2.id()); t.eq(order[3], w3.id(), "rail order preserved")
    T2:stop()
  end

  -- ===== Repeated reload never duplicates anything =====
  do
    local hs, Tuck = H.boot()
    local win = H.newWin(hs, "Safari", { title = "S" })
    H.tuck(hs, win, "left")
    local T = Tuck
    for _ = 1, 4 do
      local h2, T2 = H.reload(hs, T)
      T = T2
      t.eq(recordCount(T), 1, "no duplicate record")
      t.eq(H.liveCanvases(h2), 1, "no duplicate card")
      t.eq(h2._runningTaps(10), 2, "no duplicate keyboard taps")
      t.eq(h2._runningTaps(5), 1, "no duplicate mouse tap")
      t.eq(#h2._wfSubscribers, 6, "window filter subscribed once")
    end
    local doc = readState(hs, T.config.persistence.directory)
    t.eq(#doc.records, 1, "state file holds one record")
    T:start() -- idempotent start in the same state
    t.eq(recordCount(T), 1)
    t.eq(H.liveCanvases(hs), 1)
    T:stop()
  end

  -- ===== stop() writes the final state; start() rebuilds from it =====
  do
    local hs, Tuck, dir = H.boot()
    local win = H.newWin(hs, "Safari", { title = "S" })
    H.tuck(hs, win, "right")
    Tuck:stop()
    t.eq(recordCount(Tuck), 0, "runtime records dropped at stop")
    t.eq(H.liveCanvases(hs), 0)
    t.isTrue(readState(hs, dir) ~= nil and #readState(hs, dir).records == 1, "final state persisted by stop()")
    Tuck:start(); Tuck:start()
    t.eq(recordCount(Tuck), 1, "start() rebuilds the tuck")
    t.eq(H.liveCanvases(hs), 1)
    local rec = Tuck.store:getByWindowID(win.id())
    t.eq(rec.edge, "right")
    Tuck:stop(); Tuck:stop()
  end

  -- ===== Ending a tuck removes it from the state file (all four ways) =====
  do
    -- restore by card click
    local hs, Tuck, dir = H.boot()
    local win = H.newWin(hs, "Safari", { title = "S" })
    H.tuck(hs, win, "left"); flush(hs)
    t.eq(#readState(hs, dir).records, 1)
    H.canvasOf(Tuck, win)._fireMouse("mouseUp")
    flush(hs)
    t.eq(#readState(hs, dir).records, 0, "restore removes the persisted record")
    t.eq(H.liveCanvases(hs), 0)
    Tuck:stop()

    -- manual unminimize
    local hs2, T2, dir2 = H.boot()
    local a = H.newWin(hs2, "Safari", { title = "A" }); local b = H.newWin(hs2, "Safari", { title = "B" })
    H.tuck(hs2, a, "left"); flush(hs2)
    t.eq(a.application()._hidden, false); t.isTrue(a.isMinimized())
    a.unminimize()
    flush(hs2)
    t.eq(#readState(hs2, dir2).records, 0, "manual unhide removes the persisted record")
    t.eq(H.liveCanvases(hs2), 0, "and its card")
    T2:stop()

    -- manual app unhide (hide mechanism)
    local hs3, T3, dir3 = H.boot()
    local only = H.newWin(hs3, "Notes", { title = "N" })
    H.tuck(hs3, only, "left"); flush(hs3)
    only.application().unhide()
    flush(hs3)
    t.eq(#readState(hs3, dir3).records, 0, "manual app unhide removes the persisted record")
    T3:stop()

    -- destroyed window
    local hs4, T4, dir4 = H.boot()
    local x = H.newWin(hs4, "Safari", { title = "X" }); local y = H.newWin(hs4, "Safari", { title = "Y" })
    H.tuck(hs4, x, "left"); flush(hs4)
    x._destroy()
    flush(hs4)
    t.eq(#readState(hs4, dir4).records, 0, "destroyed window removes the persisted record")
    t.eq(H.liveCanvases(hs4), 0)
    T4:stop()

    -- application quit
    local hs5, T5, dir5 = H.boot()
    local q = H.newWin(hs5, "Quitter", { title = "Q" })
    H.tuck(hs5, q, "left"); flush(hs5)
    hs5._terminateApp(q.application())
    flush(hs5)
    t.eq(#readState(hs5, dir5).records, 0, "closing the application removes the persisted record")
    T5:stop()
  end

  -- ===== Reconciliation: visible / gone windows are dropped, never re-hidden =====
  do
    local hs, Tuck, dir = H.boot()
    local a = H.newWin(hs, "Safari", { title = "A" }); local b = H.newWin(hs, "Safari", { title = "B" })
    local gone = H.newWin(hs, "Gone", { title = "G" })
    H.tuck(hs, a, "left"); H.tuck(hs, b, "left"); H.tuck(hs, gone, "right")
    flush(hs)
    hs._simulateReload()
    -- while Hammerspoon was not running: the user restored A, and Gone quit
    a.unminimize()
    hs._terminateApp(gone.application())
    local hs2, T2 = H.boot({ hs = hs, dir = dir })
    t.eq(recordCount(T2), 1, "only the still-tucked window survives reconciliation")
    t.isTrue(T2.store:getByWindowID(b.id()) ~= nil)
    t.isNil(T2.store:getByWindowID(a.id()), "manually restored window: record dropped")
    t.isTrue(a.isVisible() and not a.isMinimized(), "…and it is NOT hidden again")
    t.eq(H.liveCanvases(hs2), 1)
    t.eq(#readState(hs2, dir).records, 1, "reconciled state is persisted immediately")
    T2:stop()
  end

  -- ===== Window identity across restarts =====
  do
    -- (a) the saved windowID is gone but exactly one safe candidate exists
    local hs, Tuck, dir = H.boot()
    local f = { x = 100, y = 120, w = 640, h = 480 }
    local a = H.newWin(hs, "Safari", { title = "Alpha", frame = f })
    local b = H.newWin(hs, "Safari", { title = "Beta", frame = { x = 5, y = 5, w = 500, h = 500 } })
    local c = H.newWin(hs, "Safari", { title = "Gamma", frame = { x = 9, y = 9, w = 400, h = 300 } })
    H.tuck(hs, a, "left"); H.tuck(hs, b, "left")
    flush(hs)
    local idA, idB = a.id(), b.id()
    hs._simulateReload()
    a._destroy()
    local a2 = H.newWin(hs, "Safari", { title = "Alpha", frame = { x = 100, y = 120, w = 640, h = 480 } })
    a2.minimize()
    t.isTrue(a2.id() ~= idA)
    local hs2, T2 = H.boot({ hs = hs, dir = dir })
    t.eq(recordCount(T2), 2)
    local ra = T2.store:getByWindowID(a2.id())
    t.isTrue(ra ~= nil, "record re-attached to the single safe candidate")
    t.eq(ra.windowTitle, "Alpha")
    t.eq(T2.store:getByWindowID(b.id()).windowTitle, "Beta", "Beta untouched")
    t.isTrue(c.isVisible(), "unrelated Safari window never hidden")
    T2:stop()

    -- (b) two identical candidates: ambiguous -> nothing attached, nothing hidden
    local hs3, T3, dir3 = H.boot()
    local p = H.newWin(hs3, "Safari", { title = "Same", frame = { x = 1, y = 2, w = 300, h = 200 } })
    local keep = H.newWin(hs3, "Safari", { title = "Keep" })
    H.tuck(hs3, p, "left"); flush(hs3)
    hs3._simulateReload()
    p._destroy()
    local c1 = H.newWin(hs3, "Safari", { title = "Same", frame = { x = 1, y = 2, w = 300, h = 200 } })
    local c2 = H.newWin(hs3, "Safari", { title = "Same", frame = { x = 1, y = 2, w = 300, h = 200 } })
    c1.minimize(); c2.minimize()
    local _, T3b = H.boot({ hs = hs3, dir = dir3 })
    t.eq(recordCount(T3b), 0, "ambiguous record is dropped, not attached arbitrarily")
    t.isTrue(c1.isMinimized() and c2.isMinimized(), "candidates left exactly as they were")
    t.isTrue(keep.isVisible(), "no unrelated window hidden")
    T3b:stop()

    -- (c) a sibling with a different title is never adopted
    local hs4, T4, dir4 = H.boot()
    local u = H.newWin(hs4, "Safari", { title = "Mine", frame = { x = 3, y = 3, w = 333, h = 222 } })
    local v = H.newWin(hs4, "Safari", { title = "Other", frame = { x = 50, y = 50, w = 444, h = 333 } })
    H.tuck(hs4, u, "left"); flush(hs4)
    hs4._simulateReload()
    u._destroy()
    v.minimize()
    local _, T4b = H.boot({ hs = hs4, dir = dir4 })
    t.eq(recordCount(T4b), 0, "Safari B's window is not attached to Safari A's record")
    t.isTrue(v.isMinimized())
    T4b:stop()

    -- (d) two persisted records, one stand-in window: it is not claimed by both
    local hs5, T5, dir5 = H.boot()
    local g1 = H.newWin(hs5, "Safari", { title = "Dup", frame = { x = 7, y = 7, w = 300, h = 300 } })
    local g2 = H.newWin(hs5, "Safari", { title = "Dup", frame = { x = 7, y = 7, w = 300, h = 300 } })
    local anchor = H.newWin(hs5, "Safari", { title = "Anchor" })
    H.tuck(hs5, g1, "left"); H.tuck(hs5, g2, "left"); flush(hs5)
    hs5._simulateReload()
    g1._destroy(); g2._destroy()
    local only = H.newWin(hs5, "Safari", { title = "Dup", frame = { x = 7, y = 7, w = 300, h = 300 } })
    only.minimize()
    local _, T5b = H.boot({ hs = hs5, dir = dir5 })
    t.eq(recordCount(T5b), 0, "competing records never both claim (or arbitrarily win) one window")
    T5b:stop()
  end

  -- ===== Same app, several windows, screens and Spaces stay independent =====
  do
    local hs, Tuck, dir = H.boot({ prepare = function(h) h._addScreen("EXT", { x = -1920, y = 0, w = 1920, h = 1080 }) end })
    local ext = hs._screens[2]
    local wins = {}
    for i, spec in ipairs({
      { "S1", hs._screens[1], 1 }, { "S2", hs._screens[1], 1 }, { "S3", ext, 1 }, { "S4", hs._screens[1], 2 },
    }) do
      hs._activeSpaces["SCREEN-MAIN"] = spec[3]
      wins[i] = H.newWin(hs, "Safari", { title = spec[1], screen = spec[2], frame = { x = i * 10, y = i * 10, w = 500 + i, h = 400 } })
      H.tuck(hs, wins[i], "left")
    end
    hs._activeSpaces["SCREEN-MAIN"] = 1
    local _, T2 = H.reload(hs, Tuck)
    t.eq(recordCount(T2), 4)
    local seen = {}
    for i, w in ipairs(wins) do
      local rec = T2.store:getByWindowID(w.id())
      t.isTrue(rec ~= nil)
      t.eq(rec.windowTitle, "S" .. i, "record still bound to its own window")
      t.eq(seen[rec.tuckID], nil); seen[rec.tuckID] = true
    end
    t.eq(T2.store:getByWindowID(wins[3].id()).screenUUID, "EXT")
    t.eq(T2.store:getByWindowID(wins[4].id()).spaceID, 2)
    T2:stop()
  end

  -- ===== hide-mechanism tuck survives and still restores =====
  do
    local hs, Tuck = H.boot()
    local only = H.newWin(hs, "Notes", { title = "N", frame = { x = 11, y = 22, w = 333, h = 444 } })
    H.tuck(hs, only, "left")
    local _, T2 = H.reload(hs, Tuck)
    local rec = T2.store:getByWindowID(only.id())
    t.eq(rec.mechanism, "hide")
    t.isTrue(only.application()._hidden, "app is still hidden after the restart")
    H.canvasOf(T2, only)._fireMouse("mouseUp")
    t.isFalse(only.application()._hidden, "restoring after a restart unhides it")
    t.eq(only.frame().x, 11); t.eq(only.frame().w, 333)
    t.eq(recordCount(T2), 0)
    T2:stop()
  end

  -- ===== Thumbnails: cached, rounded, restored; missing cache is harmless =====
  do
    local hs, Tuck, dir = H.boot({ prepare = withScreenRecording })
    local win = H.newWin(hs, "Safari", { title = "S" })
    H.tuck(hs, win, "left")
    local rec = Tuck.store:getByWindowID(win.id())
    t.isTrue(rec.thumbnail ~= nil and rec.thumbnail.baked == true, "thumbnail is the rounded (baked) image")
    flush(hs)
    local doc = readState(hs, dir)
    t.eq(doc.records[1].thumbnailFile, "cache/" .. rec.tuckID .. ".png")
    t.isTrue(H.readFile(dir .. "/cache/" .. rec.tuckID .. ".png") ~= nil, "cache file written")

    local hs2, T2 = H.reload(hs, Tuck, { prepare = withScreenRecording })
    local rec2 = T2.store:getByWindowID(win.id())
    t.isTrue(rec2.thumbnail ~= nil and rec2.thumbnail.fromCache ~= nil, "thumbnail restored from the cache")
    t.isTrue(T2.cardManager.canvases[rec2.tuckID] ~= nil)
    H.canvasOf(T2, win)._fireMouse("mouseUp") -- restore -> state/cache cleaned
    flush(hs2)
    t.isNil(H.readFile(dir .. "/cache/" .. rec.tuckID .. ".png"), "orphaned cache file pruned")
    T2:stop()

    -- cache file deleted behind our back: the tuck survives with a placeholder
    local hs3, T3, dir3 = H.boot({ prepare = withScreenRecording })
    local w3 = H.newWin(hs3, "Safari", { title = "S" })
    H.tuck(hs3, w3, "left"); flush(hs3)
    local id3 = T3.store:getByWindowID(w3.id()).tuckID
    os.remove(dir3 .. "/cache/" .. id3 .. ".png")
    local _, T3b = H.reload(hs3, T3)
    local r3 = T3b.store:getByWindowID(w3.id())
    t.isTrue(r3 ~= nil, "a valid tuck is never discarded for a missing thumbnail")
    t.isNil(r3.thumbnail)
    t.isTrue(T3b.cardManager.canvases[r3.tuckID] ~= nil, "card still created")
    T3b:stop()
  end

  -- ===== Corrupt / unsupported / partially invalid files =====
  do
    local hs, _, dir = H.boot()
    hs._simulateReload()
    H.writeFile(statePath(dir), "{ this is not json")
    local ok, T = pcall(function()
      local _, tk = H.boot({ hs = hs, dir = dir })
      return tk
    end)
    t.isTrue(ok, "corrupt JSON does not crash startup")
    t.eq(recordCount(T), 0, "starts with an empty runtime state")
    local found = false
    for _, name in ipairs(listDir(dir)) do
      if name:find("^state%.json%.corrupt%-") then found = true end
    end
    t.isTrue(found, "the corrupt file is preserved, not destroyed")
    -- still fully functional
    local win = H.newWin(hs, "Safari", { title = "Fine" })
    H.tuck(hs, win, "left"); flush(hs)
    t.eq(#readState(hs, dir).records, 1, "normal operation continues and writes a fresh state file")
    T:stop()

    -- future schema version
    local hs2, _, dir2 = H.boot()
    hs2._simulateReload()
    H.writeFile(statePath(dir2), '{"version":99,"records":[]}')
    local _, T2 = H.boot({ hs = hs2, dir = dir2 })
    t.eq(recordCount(T2), 0)
    local keptFuture = false
    for _, name in ipairs(listDir(dir2)) do
      if name:find("^state%.json%.unsupported%-") then keptFuture = true end
    end
    t.isTrue(keptFuture, "unsupported-version file preserved")
    T2:stop()

    -- one invalid entry among valid ones
    local hs3, T3, dir3 = H.boot()
    local win3 = H.newWin(hs3, "Safari", { title = "Ok" })
    H.tuck(hs3, win3, "left"); flush(hs3)
    local doc = readState(hs3, dir3)
    doc.records[#doc.records + 1] = { tuckID = "bogus", windowID = 1, edge = "diagonal" }
    doc.records[#doc.records + 1] = "junk"
    hs3._simulateReload()
    H.writeFile(statePath(dir3), hs3.json.encode(doc))
    local _, T3b = H.boot({ hs = hs3, dir = dir3 })
    t.eq(recordCount(T3b), 1, "invalid entries are skipped, valid ones kept")
    T3b:stop()
  end

  -- ===== Persistence can be switched off =====
  do
    local hs, Tuck, dir = H.boot({ configure = { persistence = { enabled = false } } })
    local win = H.newWin(hs, "Safari", { title = "S" })
    H.tuck(hs, win, "left"); flush(hs)
    t.isNil(H.readFile(statePath(dir)), "no state file when disabled")
    Tuck:stop(); Tuck:start()
    t.eq(recordCount(Tuck), 1, "in-memory records survive stop/start when persistence is off")
    Tuck:stop()
  end

  -- ===== Unit: entry validation =====
  do
    local good = { tuckID = "x", windowID = 1, edge = "left", screenUUID = "S", spaceID = 1, frame = { x = 0, y = 0, w = 1, h = 1 } }
    t.isTrue(Persistence.validateEntry(good) ~= nil)
    for _, field in ipairs({ "tuckID", "windowID", "edge", "screenUUID", "spaceID", "frame" }) do
      local bad = {}
      for k, v in pairs(good) do bad[k] = v end
      bad[field] = nil
      t.isNil(Persistence.validateEntry(bad), "missing " .. field .. " rejected")
    end
    t.isNil(Persistence.validateEntry({}), "empty entry rejected")
  end

  t.report("persistence_spec")
  return #t.failures == 0
end

return run
