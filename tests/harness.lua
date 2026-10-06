--- Shared helpers for the end-to-end specs (real init.lua + tests/mock_hs.lua).

local ConfigDefaults = require("config.defaults")

local H = {}

H.MODULES = {
  "config.defaults", "input.shortcut", "input.state", "input.matcher", "state.store",
  "state.persistence", "space.manager", "space.geometry", "card.icon", "card.preview",
  "card.manager", "card.renderer", "card.animator", "window.tracker", "window.manager",
  "window.focus_history",
}

H.K = { t = 17, left = 123, right = 124, down = 125, up = 126, escape = 53 }

function H.tmpDir()
  local name = os.tmpname()
  os.remove(name)
  os.execute("mkdir -p '" .. name .. "'")
  return name
end

function H.readFile(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local text = f:read("a")
  f:close()
  return text
end

function H.writeFile(path, text)
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

--- Build a fresh mock `hs` (unless `existingHS`), load init.lua against it
-- and start the Spoon. `opts`: { configure=, prepare=, dir=, hs= }.
-- Returns hs, Tuck, dir.
function H.boot(opts)
  opts = opts or {}
  local hs = opts.hs
  if not hs then
    package.loaded["tests.mock_hs"] = nil
    hs = require("tests.mock_hs")
  end
  if opts.prepare then
    opts.prepare(hs)
  end
  _G.hs = hs
  for _, m in ipairs(H.MODULES) do
    package.loaded[m] = nil
  end
  local dir = opts.dir or H.tmpDir()
  local Tuck = assert(loadfile("./init.lua"))():init()
  Tuck:configure(ConfigDefaults.merge({ persistence = { directory = dir } }, opts.configure))
  Tuck:start()
  return hs, Tuck, dir
end

--- Simulate a Hammerspoon reload: the old Lua state vanishes (no stop()),
-- real windows/apps survive, and a brand-new Spoon starts against the same
-- state directory. Pending debounced writes are flushed first, as the
-- passage of time would have done.
function H.reload(hs, Tuck, opts)
  opts = opts or {}
  hs._fireAllTimers()
  local dir = Tuck.config.persistence.directory
  hs._simulateReload()
  return H.boot({ hs = hs, dir = dir, configure = opts.configure, prepare = opts.prepare })
end

function H.newWin(hs, app, extra)
  local o = { appName = app, bundleID = "com." .. app:lower() }
  for k, v in pairs(extra or {}) do
    o[k] = v
  end
  return hs._makeWindow(o)
end

function H.shortcut(hs)
  return hs._sendKeyDown({ keyCode = H.K.t, flags = { fn = true } })
end

function H.arrow(hs, name)
  return hs._sendKeyDown({ keyCode = H.K[name], flags = { fn = true } })
end

function H.esc(hs)
  return hs._sendKeyDown({ keyCode = H.K.escape, flags = {} })
end

function H.letter(hs, ch)
  return hs._sendKeyDown({ keyCode = 99, flags = {}, chars = ch })
end

--- Focus `win` as the user would, then tuck it toward `edge`
-- ("left"|"right"|"up"|"down").
function H.tuck(hs, win, edge)
  hs._userFocus(win)
  H.shortcut(hs)
  H.arrow(hs, edge)
end

function H.settle(hs)
  hs._advance(0.6)
end

function H.canvasOf(Tuck, win)
  local rec = Tuck.store:getByWindowID(win.id())
  return Tuck.cardManager.canvases[rec.tuckID], rec
end

function H.frameOf(Tuck, win)
  local c, rec = H.canvasOf(Tuck, win)
  return c.frame(), rec
end

function H.countKeys(tbl)
  local n = 0
  for _ in pairs(tbl) do
    n = n + 1
  end
  return n
end

function H.liveCanvases(hs)
  local n = 0
  for _, c in ipairs(hs._canvases) do
    if not c._isDeleted() then
      n = n + 1
    end
  end
  return n
end

return H
