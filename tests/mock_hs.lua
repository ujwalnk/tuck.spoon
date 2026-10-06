--- A deliberately minimal, deliberately fake `hs` global.
--
-- This is NOT a claim that Tuck.spoon has been validated against real
-- Hammerspoon/macOS behavior -- it cannot be, outside of Hammerspoon
-- itself. Its purpose is narrower and still valuable: catch integration
-- bugs in init.lua's WIRING (wrong argument order, calling a method that
-- doesn't exist on a collaborator, a nil dereference in a code path the
-- pure unit tests never exercise, package.path/require mistakes, etc.)
-- by actually running :init()/:configure()/:start()/:stop() and a full
-- tuck -> restore cycle end to end.
--
-- Every mock method mirrors the *signature and return shape* documented
-- for the real API (per the citations gathered while writing this
-- Spoon), not real macOS behavior. See README.md's manual OS-level
-- validation checklist for what only real Hammerspoon can confirm.

local M = {}

-- ------------------------------------------------------------------
-- hs.logger
-- ------------------------------------------------------------------
M.logger = {
  new = function(_tag, _level)
    return {
      setLogLevel = function(_self, _level) end,
      d = function(...) end,
      i = function(...) end,
      w = function(...) end,
      e = function(...) end,
    }
  end,
}

-- ------------------------------------------------------------------
-- hs.timer -- synchronous-ish fake: doAfter stores the callback so the
-- test can fire it explicitly (no real event loop here).
-- ------------------------------------------------------------------
M._pendingTimers = {}
M._now = 1000
M.timer = {
  secondsSinceEpoch = function()
    return M._now
  end,
  doAfter = function(seconds, fn)
    local handle = { fn = fn, seconds = seconds, stopped = false }
    table.insert(M._pendingTimers, handle)
    return {
      stop = function()
        handle.stopped = true
      end,
    }
  end,
  doEvery = function(seconds, fn)
    -- Registered only; driven by M._advance() on the virtual clock (real
    -- timers fire asynchronously, never inside doEvery itself).
    local handle = { fn = fn, seconds = seconds, stopped = false, repeating = true }
    table.insert(M._pendingTimers, handle)
    return {
      stop = function()
        handle.stopped = true
      end,
    }
  end,
}

function M._activeRepeating()
  local n = 0
  for _, h in ipairs(M._pendingTimers) do
    if h.repeating and not h.stopped then
      n = n + 1
    end
  end
  return n
end

--- Fire every pending ONE-SHOT timer (direction/search timeouts, guards).
function M._fireAllTimers()
  local timers = M._pendingTimers
  local keep = {}
  M._pendingTimers = keep
  for _, handle in ipairs(timers) do
    if handle.repeating then
      if not handle.stopped then
        keep[#keep + 1] = handle
      end
    elseif not handle.stopped then
      handle.fn()
    end
  end
end

--- Advance the virtual clock by `dt` seconds, firing repeating timers
-- once per 1/60s step (simulates the run loop).
function M._advance(dt)
  local step = 1 / 60
  local remaining = dt
  while remaining > 1e-9 do
    local d = math.min(step, remaining)
    M._now = M._now + d
    remaining = remaining - d
    local snapshot = {}
    for _, h in ipairs(M._pendingTimers) do
      snapshot[#snapshot + 1] = h
    end
    for _, h in ipairs(snapshot) do
      if h.repeating and not h.stopped then
        h.fn()
      end
    end
  end
  -- prune stopped repeaters
  local keep = {}
  for _, h in ipairs(M._pendingTimers) do
    if not (h.repeating and h.stopped) then
      keep[#keep + 1] = h
    end
  end
  M._pendingTimers = keep
end

-- ------------------------------------------------------------------
-- hs.alert
-- ------------------------------------------------------------------
M.alert = {
  show = function(_msg, _duration) end,
}

-- ------------------------------------------------------------------
-- hs.settings
-- ------------------------------------------------------------------
M._settingsStore = {}
M.settings = {
  set = function(key, value)
    M._settingsStore[key] = value
  end,
  get = function(key)
    return M._settingsStore[key]
  end,
}

-- ------------------------------------------------------------------
-- hs.json / hs.fs (real files under a temp directory, like the real APIs)
-- ------------------------------------------------------------------
local MiniJSON = require("tests.mini_json")
M.json = {
  encode = function(value, _pretty)
    return MiniJSON.encode(value)
  end,
  decode = function(text)
    local ok, result = pcall(MiniJSON.decode, text)
    if ok then
      return result
    end
    return nil -- the real hs.json.decode logs an error and returns nil
  end,
}

local function shellQuote(path)
  return "'" .. path:gsub("'", "'\\''") .. "'"
end

M.fs = {
  attributes = function(path, attr)
    local ok = os.execute("test -d " .. shellQuote(path))
    if ok then
      if attr == "mode" then
        return "directory"
      end
      return { mode = "directory" }
    end
    local f = io.open(path, "rb")
    if f then
      f:close()
      if attr == "mode" then
        return "file"
      end
      return { mode = "file" }
    end
    return nil
  end,
  mkdir = function(path)
    return os.execute("mkdir -p " .. shellQuote(path)) and true or nil
  end,
  dir = function(path)
    local p = io.popen("ls -1 " .. shellQuote(path) .. " 2>/dev/null")
    local names = {}
    if p then
      for line in p:lines() do
        names[#names + 1] = line
      end
      p:close()
    end
    local i = 0
    return function()
      i = i + 1
      return names[i]
    end
  end,
}

-- ------------------------------------------------------------------
-- hs.screenRecordingState
-- ------------------------------------------------------------------
M.screenRecordingState = function(_shouldPrompt)
  return false -- simulate "no permission" -- the more defensive path
end

-- ------------------------------------------------------------------
-- hs.image
-- ------------------------------------------------------------------
local function makeImage(fields)
  local img = fields or {}
  img.__mockImage = true
  img.size = function()
    return { w = img.w or 128, h = img.h or 128 }
  end
  img.saveToFile = function(_self, path)
    local f = io.open(path, "wb")
    if not f then
      return false
    end
    f:write(string.format("MOCKPNG %d %d %s", img.w or 0, img.h or 0, img.baked and "baked" or "raw"))
    f:close()
    return true
  end
  return img
end
M._makeImage = makeImage

M.image = {
  imageFromAppBundle = function(bundleID)
    return makeImage({ bundleID = bundleID })
  end,
  imageFromPath = function(path)
    local f = io.open(path, "rb")
    if not f then
      return nil
    end
    local text = f:read("a")
    f:close()
    local w, h, kind = text:match("^MOCKPNG (%d+) (%d+) (%a+)")
    if not w then
      return nil
    end
    return makeImage({ w = tonumber(w), h = tonumber(h), baked = kind == "baked", fromCache = path })
  end,
}

-- ------------------------------------------------------------------
-- hs.keycodes
-- ------------------------------------------------------------------
M.keycodes = {
  map = {
    escape = 53,
    left = 123,
    right = 124,
    down = 125,
    up = 126,
    t = 17,
    f3 = 99,
    s = 1,
    a = 0,
  },
}

-- ------------------------------------------------------------------
-- hs.eventtap
-- ------------------------------------------------------------------
M._eventtaps = {}
M.eventtap = {
  event = {
    types = { keyDown = 10, mouseMoved = 5 },
  },
  new = function(types, fn)
    local tap = { fn = fn, running = false, types = types }
    return {
      start = function()
        tap.running = true
        table.insert(M._eventtaps, tap)
      end,
      stop = function()
        tap.running = false
      end,
      _tap = tap,
    }
  end,
}

--- Test helper: simulate a key event across every currently-active
-- eventtap (mirrors how multiple real macOS eventtaps can all observe
-- the same physical keystroke). `spec` = { keyCode=, flags={cmd=,...},
-- chars= }.
function M._sendKeyDown(spec)
  local flags = spec.flags or {}
  local event = {
    getKeyCode = function()
      return spec.keyCode
    end,
    getFlags = function()
      return flags
    end,
    getCharacters = function()
      return spec.chars
    end,
  }
  local consumed = false
  for _, tap in ipairs(M._eventtaps) do
    if tap.running and tap.types[1] == 10 then
      local result = tap.fn(event)
      if result then
        consumed = true
      end
    end
  end
  return consumed
end

function M._runningTaps(kind)
  local n = 0
  for _, tap in ipairs(M._eventtaps) do
    if tap.running and tap.types[1] == kind then
      n = n + 1
    end
  end
  return n
end

-- ------------------------------------------------------------------
-- hs.hotkey
-- ------------------------------------------------------------------
M._hotkeys = {}
M.hotkey = {
  bind = function(mods, key, fn)
    local hk = { mods = mods, key = key, fn = fn, deleted = false }
    table.insert(M._hotkeys, hk)
    return {
      delete = function()
        hk.deleted = true
      end,
      _hk = hk,
    }
  end,
}

--- Test helper: simulate pressing a hotkey combo (mods = array of
-- strings, key = single-char string). Finds the matching, non-deleted
-- binding and invokes it.
function M._pressHotkey(mods, key)
  local wantSet = {}
  for _, m in ipairs(mods) do
    wantSet[m:lower()] = true
  end
  for _, hk in ipairs(M._hotkeys) do
    if not hk.deleted and hk.key:lower() == key:lower() then
      local haveSet = {}
      for _, m in ipairs(hk.mods) do
        haveSet[m:lower()] = true
      end
      local same = true
      for m in pairs(wantSet) do
        if not haveSet[m] then
          same = false
        end
      end
      for m in pairs(haveSet) do
        if not wantSet[m] then
          same = false
        end
      end
      if same then
        hk.fn()
        return true
      end
    end
  end
  return false
end

-- ------------------------------------------------------------------
-- hs.canvas
-- ------------------------------------------------------------------
M._canvases = {}
M._bakeLog = {} -- every off-screen thumbnail bake (elements + size)
M._zCounter = 0
M.canvas = {
  windowLevels = { floating = 5, desktopIcon = 1 },
  new = function(frame)
    local mouseCallback = nil
    local currentFrame = { x = frame.x, y = frame.y, w = frame.w, h = frame.h }
    local elements = {}
    local deleted = false
    local shown = false
    local writes = {}
    local flags = { down = false, up = false, enterExit = false, move = false }
    local z = 0
    local c
    c = {
      level = function(_self, _lvl)
        return c
      end,
      clickActivating = function(_self, _v)
        return c
      end,
      canvasMouseEvents = function(_self, down, up, enterExit, move)
        if down ~= nil then flags.down = down end
        if up ~= nil then flags.up = up end
        if enterExit ~= nil then flags.enterExit = enterExit end
        if move ~= nil then flags.move = move end
        return c
      end,
      mouseCallback = function(_self, fn)
        mouseCallback = fn
        return c
      end,
      show = function(_self)
        shown = true
        M._zCounter = M._zCounter + 1
        z = M._zCounter
        return c
      end,
      bringToFront = function(_self)
        M._zCounter = M._zCounter + 1
        z = M._zCounter
        return c
      end,
      delete = function(_self)
        deleted = true
        elements = {} -- a deleted canvas releases its images (as the real one does)
      end,
      replaceElements = function(_self, els)
        elements = els
      end,
      frame = function(_self, newFrame)
        if newFrame then
          currentFrame = { x = newFrame.x, y = newFrame.y, w = newFrame.w, h = newFrame.h }
          writes[#writes + 1] = currentFrame
          return c
        end
        return currentFrame
      end,
      imageFromCanvas = function(_self)
        M._bakeLog[#M._bakeLog + 1] = { elements = elements, size = { w = currentFrame.w, h = currentFrame.h } }
        return makeImage({ w = currentFrame.w, h = currentFrame.h, baked = true })
      end,
      _writes = function()
        return writes
      end,
      _fireMouse = function(event)
        if mouseCallback then
          mouseCallback(c, event, "_canvas_", 0, 0)
        end
      end,
      -- Mock-only introspection used by M._sendMouseMove.
      _isSensor = function()
        return mouseCallback ~= nil and shown and not deleted and flags.enterExit
      end,
      _isInteractive = function()
        return mouseCallback ~= nil and shown and not deleted
      end,
      _z = function()
        return z
      end,
      _isDeleted = function()
        return deleted
      end,
      _hasMouseCallback = function()
        return mouseCallback ~= nil
      end,
      _elements = function()
        return elements
      end,
    }
    table.insert(M._canvases, c)
    return c
  end,
}

M._pointer = { x = -1e9, y = -1e9 }
M._pointerOwner = nil -- canvas currently under the pointer (topmost interactive)

--- Test helper: simulate the pointer moving to (x, y). Mirrors macOS
-- tracking-area behaviour: the TOPMOST interactive canvas under the pointer
-- receives mouseEnter, the previous owner receives mouseExit. Canvases
-- without a mouse callback are click-through and never own the pointer.
function M._sendMouseMove(x, y)
  M._pointer = { x = x, y = y }
  local top
  for _, c in ipairs(M._canvases) do
    if c._isSensor() then
      local f = c.frame()
      if x >= f.x and x < f.x + f.w and y >= f.y and y < f.y + f.h then
        if not top or c._z() > top._z() then
          top = c
        end
      end
    end
  end
  local old = M._pointerOwner
  if old == top then
    return
  end
  M._pointerOwner = top
  if old and not old._isDeleted() then
    old._fireMouse("mouseExit")
  end
  if top then
    top._fireMouse("mouseEnter")
  end
end

--- Test helper: a click at (x, y) delivered to the topmost interactive
-- canvas under it (none = click passes through to the app below).
function M._click(x, y)
  local top
  for _, c in ipairs(M._canvases) do
    if c._isInteractive() then
      local f = c.frame()
      if x >= f.x and x < f.x + f.w and y >= f.y and y < f.y + f.h then
        if not top or c._z() > top._z() then
          top = c
        end
      end
    end
  end
  if top then
    top._fireMouse("mouseUp")
  end
  return top ~= nil
end

-- ------------------------------------------------------------------
-- hs.screen
-- ------------------------------------------------------------------
local function makeScreen(uuid, frame)
  return {
    getUUID = function()
      return uuid
    end,
    frame = function()
      return frame
    end,
    fullFrame = function()
      return frame
    end,
  }
end

M._screens = {
  makeScreen("SCREEN-MAIN", { x = 0, y = 0, w = 1440, h = 900 }),
}
M._makeScreen = makeScreen

--- Test helper: attach another screen (e.g. negative-coordinate external).
function M._addScreen(uuid, frame)
  local sc = makeScreen(uuid, frame)
  table.insert(M._screens, sc)
  return sc
end

M._screenWatchers = {}
M.screen = {
  allScreens = function()
    return M._screens
  end,
  mainScreen = function()
    return M._screens[1]
  end,
  watcher = {
    new = function(fn)
      local w = { running = false, fn = fn }
      table.insert(M._screenWatchers, w)
      return {
        start = function() w.running = true end,
        stop = function() w.running = false end,
        _fn = fn,
      }
    end,
  },
}

M.mouse = {
  getCurrentScreen = function()
    return M._screens[1]
  end,
}

-- ------------------------------------------------------------------
-- hs.spaces
-- ------------------------------------------------------------------
M._spaceWatchers = {}
M._activeSpaces = {} -- screenUUID -> active space id (default 1)
M.spaces = {
  activeSpaceOnScreen = function(screen)
    return M._activeSpaces[screen:getUUID()] or 1
  end,
  spacesForScreen = function(_screenUUID)
    return { 1 }
  end,
  windowSpaces = function(window)
    return (window and window._spaces) or { 1 } -- single Space -- eligible
  end,
  activeSpaces = function()
    local out = {}
    for _, sc in ipairs(M._screens) do
      out[sc:getUUID()] = M._activeSpaces[sc:getUUID()] or 1
    end
    return out
  end,
  watcher = {
    new = function(fn)
      local w = { running = false, fn = fn }
      table.insert(M._spaceWatchers, w)
      return {
        start = function() w.running = true end,
        stop = function() w.running = false end,
        _fn = fn,
      }
    end,
  },
}

-- ------------------------------------------------------------------
-- hs.application (+ watcher) / hs.window / hs.window.filter
-- ------------------------------------------------------------------
M._windows = {} -- id -> mock window
M._apps = {} -- pid -> mock app
M._nextWindowID = 1000
M._nextPID = 500
M._appWatchers = {}

M.application = {
  watcher = {
    activated = "activated",
    deactivated = "deactivated",
    hidden = "hidden",
    unhidden = "unhidden",
    launched = "launched",
    launching = "launching",
    terminated = "terminated",
    new = function(fn)
      local w = { fn = fn, running = false }
      return {
        start = function(self)
          w.running = true
          table.insert(M._appWatchers, w)
          return self
        end,
        stop = function(self)
          w.running = false
          return self
        end,
      }
    end,
  },
  applicationForPID = function(pid)
    return M._apps[pid]
  end,
}

local function fireAppEvent(app, ev)
  for _, w in ipairs(M._appWatchers) do
    if w.running then
      w.fn(app._name, ev, app)
    end
  end
end

local function getApp(opts)
  for _, app in pairs(M._apps) do
    if app._bundleID == opts.bundleID and app._name == opts.appName and not app._dead then
      return app
    end
  end
  M._nextPID = M._nextPID + 1
  local app
  app = {
    _name = opts.appName,
    _bundleID = opts.bundleID,
    _pid = M._nextPID,
    _hidden = false,
    _windows = {},
    _dead = false,
    name = function() return app._name end,
    bundleID = function() return app._bundleID end,
    pid = function() return app._pid end,
    isHidden = function() return app._hidden end,
    hide = function()
      if not app._hidden then
        app._hidden = true
        fireAppEvent(app, "hidden")
      end
      return true
    end,
    unhide = function()
      if app._hidden then
        app._hidden = false
        fireAppEvent(app, "unhidden")
      end
      return true
    end,
    activate = function(_self, allWindows)
      M._activateLog[#M._activateLog + 1] = { pid = app and app._pid, all = allWindows == true }
      return true
    end,
    allWindows = function()
      local out = {}
      for _, w in ipairs(app._windows) do
        if M._windows[w.id()] then out[#out + 1] = w end
      end
      return out
    end,
    visibleWindows = function()
      local out = {}
      for _, w in ipairs(app.allWindows()) do
        if w.isVisible() then out[#out + 1] = w end
      end
      return out
    end,
  }
  M._apps[app._pid] = app
  return app
end

--- Test helper: the app quits; its windows are destroyed, then terminated.
function M._terminateApp(app)
  for _, w in ipairs(app.allWindows()) do
    w._destroy()
  end
  app._dead = true
  fireAppEvent(app, "terminated")
  M._apps[app._pid] = nil
end

function M._makeWindow(opts)
  M._nextWindowID = M._nextWindowID + 1
  local id = opts.id or M._nextWindowID
  local minimized = false
  local frame = opts.frame or { x = 100, y = 100, w = 800, h = 600 }
  local app = getApp(opts)
  local win
  win = {
    id = function() return id end,
    isStandard = function() return opts.isStandard ~= false end,
    isMinimized = function() return minimized end,
    isVisible = function() return (not minimized) and (not app._hidden) end,
    frame = function() return frame end,
    setFrame = function(_self, f)
      frame = f
      M._frameWrites[#M._frameWrites + 1] = id
    end,
    application = function() return app end,
    title = function() return opts.title end,
    screen = function() return opts.screen or M._screens[1] end,
    snapshot = function() return makeImage({ w = 1600, h = 1000, snapshot = true }) end,
    _spaces = opts.spaces,
    minimize = function()
      minimized = true
      M._fireWindowFilterEvent("windowMinimized", win, opts.appName)
    end,
    unminimize = function()
      minimized = false
      M._fireWindowFilterEvent("windowUnminimized", win, opts.appName)
    end,
    focus = function()
      M._focusedWindow = win
      M._touchRecency(id)
      M._focusLog[#M._focusLog + 1] = id
      -- Real Hammerspoon fires windowFocused for any focus change,
      -- Tuck-initiated or not; the production suppression logic is what
      -- tells them apart, so the mock must not special-case this.
      M._fireWindowFilterEvent("windowFocused", win, opts.appName)
    end,
    raise = function() M._raiseLog[#M._raiseLog + 1] = id end,
    _destroy = function()
      M._fireWindowFilterEvent("windowDestroyed", win, opts.appName)
      M._windows[id] = nil
    end,
  }
  table.insert(app._windows, win)
  M._windows[id] = win
  return win
end

M._activateLog = {}
M._frameWrites = {} -- ids of every window that was given a frame
M._focusedWindow = nil
M._focusLog = {}
M._raiseLog = {}

--- Test helper: simulate the USER (not Tuck) focusing `win` directly --
-- e.g. clicking it, Cmd-Tabbing to it. Fires the same windowFocused
-- event a real focus change would.
function M._userFocus(win)
  M._focusedWindow = win
  win.focus()
end
M._wfSubscribers = {}

function M._fireWindowFilterEvent(eventName, window, appName)
  for _, sub in ipairs(M._wfSubscribers) do
    if sub.event == eventName then
      sub.fn(window, appName)
    end
  end
end

M._zOrder = nil -- optional explicit front-to-back list of mock windows
M._focusRecency = {} -- window ids, most recently focused LAST (models macOS z-order)

local function touchRecency(id)
  for i = #M._focusRecency, 1, -1 do
    if M._focusRecency[i] == id then table.remove(M._focusRecency, i) end
  end
  M._focusRecency[#M._focusRecency + 1] = id
end
M._touchRecency = touchRecency

M.window = {
  focusedWindow = function() return M._focusedWindow end,
  get = function(id) return M._windows[id] end,
  orderedWindows = function()
    M._enumerations = (M._enumerations or 0) + 1
    local out = {}
    if M._zOrder then
      for _, w in ipairs(M._zOrder) do
        if M._windows[w.id()] and w.isVisible() then out[#out + 1] = w end
      end
      return out
    end
    local seen = {}
    for i = #M._focusRecency, 1, -1 do
      local w = M._windows[M._focusRecency[i]]
      if w and w.isVisible() and not seen[w.id()] then out[#out + 1] = w; seen[w.id()] = true end
    end
    local ids = {}
    for id, w in pairs(M._windows) do
      if w.isVisible() and not seen[id] then ids[#ids + 1] = id end
    end
    table.sort(ids, function(a, b) return a > b end)
    for _, id in ipairs(ids) do out[#out + 1] = M._windows[id] end
    return out
  end,
  filter = {
    windowMinimized = "windowMinimized",
    windowUnminimized = "windowUnminimized",
    windowDestroyed = "windowDestroyed",
    windowFocused = "windowFocused",
    windowMoved = "windowMoved",
    windowTitleChanged = "windowTitleChanged",
    new = function(_allowAll)
      M._filtersCreated = (M._filtersCreated or 0) + 1
      return {
        subscribe = function(_self, eventName, fn)
          table.insert(M._wfSubscribers, { event = eventName, fn = fn })
        end,
        unsubscribeAll = function(_self)
          M._wfSubscribers = {}
        end,
        getWindows = function(_self)
          local out = {}
          for _, w in pairs(M._windows) do
            if not w.isMinimized() then
              out[#out + 1] = w
            end
          end
          return out
        end,
      }
    end,
  },
}

--- Simulate Hammerspoon reloading its Lua state: every hs object created by
-- the old Spoon (canvases, taps, timers, watchers, hotkeys, window-filter
-- subscriptions) disappears WITHOUT the Spoon's stop() being called, while
-- the real applications/windows keep existing.
function M._simulateReload()
  for _, c in ipairs(M._canvases) do
    c.delete()
  end
  M._canvases = {}
  M._eventtaps = {}
  M._pendingTimers = {}
  M._wfSubscribers = {}
  for _, w in ipairs(M._appWatchers) do
    w.running = false
  end
  M._appWatchers = {}
  for _, w in ipairs(M._screenWatchers) do w.running = false end
  for _, w in ipairs(M._spaceWatchers) do w.running = false end
  M._screenWatchers, M._spaceWatchers = {}, {}
  for _, hk in ipairs(M._hotkeys) do
    hk.deleted = true
  end
  M._hotkeys = {}
end

return M
