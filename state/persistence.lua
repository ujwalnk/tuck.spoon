--- Persistence: tucks survive Hammerspoon restarts.
--
-- The store of TuckedWindow records is mirrored to `state.json` beside the
-- Spoon (a directory derived from the Spoon's own location, never from the
-- process working directory). Only plain JSON data is written -- never an
-- hs.window / hs.canvas / hs.image, timer, function or any other userdata.
-- Transient interaction state (hover, edge reveal, search query, input
-- mode, timers, animations, pointer position) is never part of the file.
--
-- FILE FORMAT (schema version 1)
--   {
--     "version": 1,
--     "records": [
--       { "tuckID": "...", "windowID": 123, "pid": 456,
--         "bundleID": "...", "appName": "...", "windowTitle": "...",
--         "frame": {"x":..,"y":..,"w":..,"h":..},
--         "spaceID": 1, "screenUUID": "...", "edge": "left",
--         "order": 1,                  -- 1-based position on its rail
--         "mechanism": "hide"|"minimize",
--         "thumbnailFile": "cache/<tuckID>.png" }   -- optional
--     ]
--   }
--
-- WRITES are coalesced (one debounced write after the last change) and
-- atomic: a temporary file is written, flushed and closed, then renamed
-- over the old file, so a crash can never leave a half-written state.json.
-- Nothing is ever written while animations run: only the events that change
-- persistent state (tuck, restore, manual unhide, destroyed window, card
-- removal, rail order change) schedule a save.
--
-- A corrupt or unsupported state file is never silently destroyed: it is
-- renamed aside (state.json.corrupt-<time>) and the Spoon starts with an
-- empty runtime state.
--
-- Matching saved records to real windows after a restart is NOT done here
-- (see window/manager.lua :reconcile); this module only reads, validates
-- and writes data.

local Persistence = {}
Persistence.__index = Persistence

Persistence.SCHEMA_VERSION = 1

local STATE_FILE = "state.json"
local CACHE_DIR = "cache"

local VALID_EDGES = { left = true, right = true, top = true, bottom = true }

-- Schema migrations: MIGRATIONS[n] upgrades a version-n document to n+1.
-- (None are needed yet; the table is the extension point.)
local MIGRATIONS = {}

--- `opts`: { directory = <dir containing state.json>, enabled = bool,
-- debounce = seconds, persistThumbnails = bool }
function Persistence.new(hsRef, logger, opts)
  local self = setmetatable({}, Persistence)
  self.hs = hsRef
  self.logger = logger
  opts = opts or {}
  local dir = opts.directory or "./"
  if dir:sub(-1) ~= "/" then
    dir = dir .. "/"
  end
  self.dir = dir
  self.enabled = opts.enabled ~= false
  self.debounce = opts.debounce or 0.25
  self.persistThumbnails = opts.persistThumbnails ~= false
  self.store = nil
  self.previewManager = nil
  self.timer = nil
  self.lastDocument = nil -- encoded text of the last successful write
  self.warnedWrite = false
  return self
end

--- Attach the live collaborators (kept out of the constructor so the
-- module can be built before the store exists).
function Persistence:bind(store, previewManager)
  self.store = store
  self.previewManager = previewManager
end

function Persistence:path()
  return self.dir .. STATE_FILE
end

function Persistence:cacheDir()
  return self.dir .. CACHE_DIR .. "/"
end

function Persistence:_debug(msg)
  if self.logger then
    self.logger.d("Tuck: " .. msg)
  end
end

-- ---------------------------------------------------------------------
-- JSON
-- ---------------------------------------------------------------------

function Persistence:_encode(doc)
  local ok, text = pcall(function()
    return self.hs.json.encode(doc, true)
  end)
  if ok and type(text) == "string" then
    return text
  end
  return nil, tostring(text)
end

function Persistence:_decode(text)
  local ok, doc = pcall(function()
    return self.hs.json.decode(text)
  end)
  if ok and type(doc) == "table" then
    return doc
  end
  return nil
end

-- ---------------------------------------------------------------------
-- Validation
-- ---------------------------------------------------------------------

local function isNumber(v)
  return type(v) == "number" and v == v
end

--- Validate one persisted entry and return a clean copy containing only
-- the known fields, or nil + reason.
function Persistence.validateEntry(e)
  if type(e) ~= "table" then
    return nil, "entry is not an object"
  end
  if type(e.tuckID) ~= "string" or e.tuckID == "" then
    return nil, "missing tuckID"
  end
  if not isNumber(e.windowID) then
    return nil, "missing windowID"
  end
  if not VALID_EDGES[e.edge] then
    return nil, "invalid edge"
  end
  if type(e.screenUUID) ~= "string" or e.screenUUID == "" then
    return nil, "missing screenUUID"
  end
  if e.spaceID == nil or not (isNumber(e.spaceID) or type(e.spaceID) == "string") then
    return nil, "missing spaceID"
  end
  local f = e.frame
  if type(f) ~= "table" or not (isNumber(f.x) and isNumber(f.y) and isNumber(f.w) and isNumber(f.h)) then
    return nil, "invalid frame"
  end
  local mechanism = e.mechanism
  if mechanism ~= "hide" then
    mechanism = "minimize"
  end
  local pid = isNumber(e.pid) and e.pid or nil
  return {
    tuckID = e.tuckID,
    windowID = e.windowID,
    pid = pid,
    bundleID = type(e.bundleID) == "string" and e.bundleID or nil,
    appName = type(e.appName) == "string" and e.appName or "Unknown",
    windowTitle = type(e.windowTitle) == "string" and e.windowTitle or nil,
    frame = { x = f.x, y = f.y, w = f.w, h = f.h },
    spaceID = e.spaceID,
    screenUUID = e.screenUUID,
    edge = e.edge,
    order = isNumber(e.order) and e.order or 0,
    mechanism = mechanism,
    thumbnailFile = type(e.thumbnailFile) == "string" and e.thumbnailFile or nil,
  }
end

-- ---------------------------------------------------------------------
-- Loading
-- ---------------------------------------------------------------------

--- Move a bad state file aside so it is preserved for inspection.
function Persistence:_quarantineFile(reason)
  local src = self:path()
  local dst = string.format("%s.%s-%d", src, reason, os.time())
  local ok = os.rename(src, dst)
  if self.logger then
    if ok then
      self.logger.w("Tuck: state file " .. reason .. "; preserved as " .. dst .. " and starting empty")
    else
      self.logger.w("Tuck: state file " .. reason .. " and could not be moved aside; starting empty")
    end
  end
end

--- Read and validate the state file.
-- Returns `entries, status` where status is one of "disabled", "missing",
-- "ok", "corrupt", "unsupported". `entries` is always an array (possibly
-- empty), ordered by (screen/Space shelf, edge, rail order) so that adding
-- them in sequence reproduces each rail's order. Never raises.
function Persistence:load()
  if not self.enabled then
    return {}, "disabled"
  end
  local f = io.open(self:path(), "rb")
  if not f then
    return {}, "missing"
  end
  local text = f:read("a")
  f:close()
  if type(text) ~= "string" or text:match("^%s*$") then
    self:_quarantineFile("corrupt")
    return {}, "corrupt"
  end

  local doc = self:_decode(text)
  if not doc or type(doc.version) ~= "number" or type(doc.records) ~= "table" then
    self:_quarantineFile("corrupt")
    return {}, "corrupt"
  end
  if doc.version > Persistence.SCHEMA_VERSION then
    self:_quarantineFile("unsupported")
    return {}, "unsupported"
  end
  while doc.version < Persistence.SCHEMA_VERSION do
    local migrate = MIGRATIONS[doc.version]
    if not migrate then
      self:_quarantineFile("unsupported")
      return {}, "unsupported"
    end
    doc = migrate(doc)
  end

  local entries = {}
  for i, raw in ipairs(doc.records) do
    local entry, reason = Persistence.validateEntry(raw)
    if entry then
      entries[#entries + 1] = entry
    else
      self:_debug("dropping invalid persisted entry #" .. i .. " (" .. tostring(reason) .. ")")
    end
  end

  -- Re-establish a deterministic rail order. Stable w.r.t. file order.
  local indexed = {}
  for i, entry in ipairs(entries) do
    indexed[i] = { entry = entry, i = i }
  end
  table.sort(indexed, function(a, b)
    local ka = tostring(a.entry.screenUUID) .. "|" .. tostring(a.entry.spaceID) .. "|" .. a.entry.edge
    local kb = tostring(b.entry.screenUUID) .. "|" .. tostring(b.entry.spaceID) .. "|" .. b.entry.edge
    if ka ~= kb then
      return ka < kb
    end
    if a.entry.order ~= b.entry.order then
      return a.entry.order < b.entry.order
    end
    return a.i < b.i
  end)
  local ordered = {}
  for i, item in ipairs(indexed) do
    ordered[i] = item.entry
  end
  return ordered, "ok"
end

-- ---------------------------------------------------------------------
-- Thumbnail cache
-- ---------------------------------------------------------------------

function Persistence:_ensureDir(path)
  local fs = self.hs.fs
  if not fs then
    return false
  end
  local okAttr, mode = pcall(function()
    return fs.attributes(path, "mode")
  end)
  if okAttr and mode == "directory" then
    return true
  end
  pcall(function()
    return fs.mkdir(path)
  end)
  local okAttr2, mode2 = pcall(function()
    return fs.attributes(path, "mode")
  end)
  return okAttr2 and mode2 == "directory"
end

--- Load the cached thumbnail named by a persisted entry, or nil.
function Persistence:loadThumbnail(entry)
  if not self.persistThumbnails or not entry.thumbnailFile or not self.previewManager then
    return nil
  end
  -- Only ever read from this Spoon's cache folder.
  local name = entry.thumbnailFile:match("^" .. CACHE_DIR .. "/([%w%._%-]+)$")
  if not name then
    return nil
  end
  return self.previewManager:load(self:cacheDir() .. name)
end

function Persistence:_writeThumbnails(records)
  if not self.persistThumbnails or not self.previewManager then
    return
  end
  local needsDir = false
  for _, rec in ipairs(records) do
    if rec.thumbnail and not rec.thumbnailFile then
      needsDir = true
      break
    end
  end
  if needsDir and not self:_ensureDir(self:cacheDir()) then
    self:_debug("thumbnail cache directory unavailable; previews will not persist")
    return
  end
  for _, rec in ipairs(records) do
    if rec.thumbnail and not rec.thumbnailFile then
      local name = rec.tuckID .. ".png"
      if self.previewManager:save(rec.thumbnail, self:cacheDir() .. name) then
        rec.thumbnailFile = CACHE_DIR .. "/" .. name
      end
    end
  end
end

--- Delete cached images no live record references.
function Persistence:_pruneCache(records)
  local fs = self.hs.fs
  if not fs or not fs.dir then
    return
  end
  local keep = {}
  for _, rec in ipairs(records) do
    if rec.thumbnailFile then
      keep[rec.thumbnailFile:match("([^/]+)$")] = true
    end
  end
  local ok, iter, state = pcall(function()
    return fs.dir(self:cacheDir())
  end)
  if not ok or type(iter) ~= "function" then
    return
  end
  local stale = {}
  for name in iter, state do
    if name:match("%.png$") and not keep[name] then
      stale[#stale + 1] = name
    end
  end
  for _, name in ipairs(stale) do
    os.remove(self:cacheDir() .. name)
  end
end

-- ---------------------------------------------------------------------
-- Saving
-- ---------------------------------------------------------------------

--- Build the persistable document from the live store. Plain data only.
-- Returns the document and the live records it was built from.
function Persistence:snapshot()
  local ordered = self.store:orderedRecords()
  local records = {}
  for _, item in ipairs(ordered) do
    records[#records + 1] = item.record
  end
  self:_writeThumbnails(records)
  local entries = {}
  for _, item in ipairs(ordered) do
    local r = item.record
    entries[#entries + 1] = {
      tuckID = r.tuckID,
      windowID = r.windowID,
      pid = r.pid,
      bundleID = r.bundleID,
      appName = r.appName,
      windowTitle = r.windowTitle,
      frame = { x = r.frame.x, y = r.frame.y, w = r.frame.w, h = r.frame.h },
      spaceID = r.spaceID,
      screenUUID = r.screenUUID,
      edge = r.edge,
      order = item.order,
      mechanism = r.mechanism,
      thumbnailFile = r.thumbnailFile,
    }
  end
  return { version = Persistence.SCHEMA_VERSION, records = entries }, records
end

--- Write the state now (atomic replace). Returns true on success.
function Persistence:flush()
  self:_cancelTimer()
  if not self.enabled or not self.store then
    return false
  end
  local doc, records = self:snapshot()
  local text, err = self:_encode(doc)
  if not text then
    if self.logger then
      self.logger.e("Tuck: could not encode state: " .. tostring(err))
    end
    return false
  end

  if text ~= self.lastDocument then
    local tmp = self:path() .. ".tmp"
    local f, openErr = io.open(tmp, "wb")
    if not f then
      if not self.warnedWrite and self.logger then
        self.logger.w("Tuck: cannot write state file (tucks will not survive a restart): " .. tostring(openErr))
      end
      self.warnedWrite = true
      return false
    end
    local okWrite, writeErr = f:write(text)
    local okFlush = f:flush()
    local okClose = f:close()
    if not okWrite or not okFlush or not okClose then
      os.remove(tmp)
      if self.logger then
        self.logger.w("Tuck: failed writing state file: " .. tostring(writeErr))
      end
      return false
    end
    local okRename, renameErr = os.rename(tmp, self:path())
    if not okRename then
      os.remove(tmp)
      if self.logger then
        self.logger.w("Tuck: failed replacing state file: " .. tostring(renameErr))
      end
      return false
    end
    self.lastDocument = text
    self.warnedWrite = false
  end
  self:_pruneCache(records)
  return true
end

function Persistence:_cancelTimer()
  if self.timer then
    self.timer:stop()
    self.timer = nil
  end
end

--- Request a write. Coalesced: any number of requests within the debounce
-- window produce one write.
function Persistence:schedule()
  if not self.enabled or not self.store then
    return
  end
  if self.timer then
    return -- a write is already pending and will capture the latest state
  end
  local this = self
  self.timer = self.hs.timer.doAfter(self.debounce, function()
    this.timer = nil
    this:flush()
  end)
end

--- Cancel any pending write (the caller flushes explicitly if needed).
function Persistence:stop()
  self:_cancelTimer()
end

return Persistence
