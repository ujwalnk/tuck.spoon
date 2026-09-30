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
M.timer = {
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
    -- Real hs.timer.doEvery fires asynchronously, so by the time the
    -- callback runs, the caller's own `timer = hs.timer.doEvery(...)`
    -- assignment has already completed. Mirror that by only REGISTERING
    -- the repeating callback here; it is driven to completion later via
    -- M._fireAllTimers(), never synchronously inside this call.
    local handle = { fn = fn, stopped = false, repeating = true }
    table.insert(M._pendingTimers, handle)
    return {
      stop = function()
        handle.stopped = true
      end,
    }
  end,
}

function M._fireAllTimers()
  local timers = M._pendingTimers
  M._pendingTimers = {}
  for _, handle in ipairs(timers) do
    if not handle.stopped then
      if handle.repeating then
        local guard = 0
        while not handle.stopped and guard < 1000 do
          handle.fn()
          guard = guard + 1
        end
      else
        handle.fn()
      end
    end
  end
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
-- hs.screenRecordingState
-- ------------------------------------------------------------------
M.screenRecordingState = function(_shouldPrompt)
  return false -- simulate "no permission" -- the more defensive path
end

-- ------------------------------------------------------------------
-- hs.image
-- ------------------------------------------------------------------
M.image = {
  imageFromAppBundle = function(bundleID)
    return { __mockImage = true, bundleID = bundleID }
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
    types = { keyDown = 10 },
  },
  new = function(_types, fn)
    local tap = { fn = fn, running = false }
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
    if tap.running then
      local result = tap.fn(event)
      if result then
        consumed = true
      end
    end
  end
  return consumed
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
M.canvas = {
  windowLevels = { floating = 5, desktopIcon = 1 },
  new = function(frame)
    local mouseCallback = nil
    local currentFrame = { x = frame.x, y = frame.y, w = frame.w, h = frame.h }
    local elements = {}
    local deleted = false
    local c
    c = {
      level = function(_self, _lvl)
        return c
      end,
      clickActivating = function(_self, _v)
        return c
      end,
      canvasMouseEvents = function(_self, _down, _up, _enterExit, _move)
        return c
      end,
      mouseCallback = function(_self, fn)
        mouseCallback = fn
        return c
      end,
      show = function(_self)
        return c
      end,
      delete = function(_self)
        deleted = true
      end,
      replaceElements = function(_self, els)
        elements = els
      end,
      frame = function(_self, newFrame)
        if newFrame then
          currentFrame = { x = newFrame.x, y = newFrame.y, w = newFrame.w, h = newFrame.h }
          return c
        end
        return currentFrame
      end,
      _fireMouse = function(event)
        if mouseCallback then
          mouseCallback(c, event, 1, 0, 0)
        end
      end,
      _isDeleted = function()
        return deleted
      end,
      _elements = function()
        return elements
      end,
    }
    table.insert(M._canvases, c)
    return c
  end,
}

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

M.screen = {
  allScreens = function()
    return M._screens
  end,
  mainScreen = function()
    return M._screens[1]
  end,
  watcher = {
    new = function(fn)
      return {
        start = function() end,
        stop = function() end,
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
M.spaces = {
  activeSpaceOnScreen = function(_screen)
    return 1
  end,
  spacesForScreen = function(_screenUUID)
    return { 1 }
  end,
  windowSpaces = function(_window)
    return { 1 } -- single Space -- eligible
  end,
  watcher = {
    new = function(fn)
      return {
        start = function() end,
        stop = function() end,
        _fn = fn,
      }
    end,
  },
}

-- ------------------------------------------------------------------
-- hs.window / hs.window.filter
-- ------------------------------------------------------------------
M._windows = {} -- id -> mock window
M._nextWindowID = 1000

function M._makeWindow(opts)
  M._nextWindowID = M._nextWindowID + 1
  local id = opts.id or M._nextWindowID
  local minimized = false
  local frame = opts.frame or { x = 100, y = 100, w = 800, h = 600 }
  local win
  win = {
    id = function()
      return id
    end,
    isStandard = function()
      return opts.isStandard ~= false
    end,
    isMinimized = function()
      return minimized
    end,
    isVisible = function()
      return not minimized
    end,
    frame = function()
      return frame
    end,
    setFrame = function(_self, f)
      frame = f
    end,
    application = function()
      return {
        name = function()
          return opts.appName
        end,
        bundleID = function()
          return opts.bundleID
        end,
      }
    end,
    title = function()
      return opts.title
    end,
    screen = function()
      return opts.screen or M._screens[1]
    end,
    snapshot = function()
      return { __mockSnapshot = true }
    end,
    minimize = function()
      minimized = true
      M._fireWindowFilterEvent("windowMinimized", win, opts.appName)
    end,
    unminimize = function()
      minimized = false
      M._fireWindowFilterEvent("windowUnminimized", win, opts.appName)
    end,
    focus = function() end,
    raise = function() end,
    _destroy = function()
      M._fireWindowFilterEvent("windowDestroyed", win, opts.appName)
      M._windows[id] = nil
    end,
  }
  M._windows[id] = win
  return win
end

M._focusedWindow = nil
M._wfSubscribers = {}

function M._fireWindowFilterEvent(eventName, window, appName)
  for _, sub in ipairs(M._wfSubscribers) do
    if sub.event == eventName then
      sub.fn(window, appName)
    end
  end
end

M.window = {
  focusedWindow = function()
    return M._focusedWindow
  end,
  get = function(id)
    return M._windows[id]
  end,
  filter = {
    windowMinimized = "windowMinimized",
    windowUnminimized = "windowUnminimized",
    windowDestroyed = "windowDestroyed",
    windowMoved = "windowMoved",
    windowTitleChanged = "windowTitleChanged",
    new = function(_allowAll)
      return {
        subscribe = function(_self, eventName, fn)
          table.insert(M._wfSubscribers, { event = eventName, fn = fn })
        end,
        unsubscribeAll = function(_self)
          M._wfSubscribers = {}
        end,
      }
    end,
  },
}

return M
