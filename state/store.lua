--- Central TuckState store.
--
-- This module owns the two indexes described in the spec:
--   windows index:  windowID -> TuckedWindow
--   shelves index:  shelfKey (screenUUID .. "|" .. spaceID) -> Shelf
--
-- A Shelf is `{ left = {tuckIDs...}, right = {...}, top = {...}, bottom = {...} }`
-- where each rail is an ordered array of tuckIDs (NOT full records), per
-- the spec's instruction that rails hold ordered references.
--
-- TuckedWindow is the source of truth (Invariant 1); cards are views and
-- can always be recreated from this store.
--
-- This module has no Hammerspoon dependency: it is pure data-structure
-- bookkeeping so it can be unit tested in isolation. All spatial geometry
-- lives in space/geometry.lua; this module only tracks membership/order.

local Store = {}
Store.__index = Store

local EDGES = { "left", "right", "top", "bottom" }
local EDGE_SET = { left = true, right = true, top = true, bottom = true }

function Store.shelfKey(screenUUID, spaceID)
  assert(screenUUID ~= nil, "screenUUID required")
  assert(spaceID ~= nil, "spaceID required")
  return tostring(screenUUID) .. "|" .. tostring(spaceID)
end

function Store.new()
  local self = setmetatable({}, Store)
  self.windows = {} -- windowID -> TuckedWindow
  self.byTuckID = {} -- tuckID -> TuckedWindow (fast lookup for card manager)
  self.shelves = {} -- shelfKey -> Shelf
  self._tuckSeq = 0
  return self
end

--- Generate a new, stable tuckID. Monotonic + prefixed so it can never
-- collide with a windowID or be confused with one.
--
-- Persisted tuckIDs are re-registered after a restart while this counter
-- starts over, so a candidate that collides with a live record is skipped
-- rather than ever handed out twice.
function Store:nextTuckID()
  local id
  repeat
    self._tuckSeq = self._tuckSeq + 1
    id = string.format("tuck-%d-%d", os.time and os.time() or 0, self._tuckSeq)
  until self.byTuckID[id] == nil
  return id
end

local function emptyShelf()
  return { left = {}, right = {}, top = {}, bottom = {} }
end

function Store:shelfFor(screenUUID, spaceID)
  local key = Store.shelfKey(screenUUID, spaceID)
  local shelf = self.shelves[key]
  if not shelf then
    shelf = emptyShelf()
    self.shelves[key] = shelf
  end
  return shelf, key
end

function Store:getShelf(screenUUID, spaceID)
  return self.shelves[Store.shelfKey(screenUUID, spaceID)]
end

--- Insert a new TuckedWindow record. `record` must already contain
-- windowID, tuckID, screenUUID, spaceID, edge (and any of the other
-- documented fields). Returns the record for convenience.
--
-- `position` may be "start", "end" (default), or a 1-based index. Most
-- callers append (a freshly tucked window goes to the end of its rail);
-- explicit position support exists for reconciliation/testing.
function Store:addWindow(record, position)
  assert(record.windowID ~= nil, "windowID required")
  assert(record.tuckID ~= nil, "tuckID required")
  assert(EDGE_SET[record.edge], "invalid edge: " .. tostring(record.edge))
  assert(self.windows[record.windowID] == nil, "duplicate TuckedWindow for windowID " .. tostring(record.windowID))
  assert(self.byTuckID[record.tuckID] == nil, "duplicate TuckedWindow for tuckID " .. tostring(record.tuckID))

  record.state = record.state or "tucked"

  self.windows[record.windowID] = record
  self.byTuckID[record.tuckID] = record

  local shelf = self:shelfFor(record.screenUUID, record.spaceID)
  local rail = shelf[record.edge]

  if position == "start" then
    table.insert(rail, 1, record.tuckID)
  elseif type(position) == "number" then
    table.insert(rail, position, record.tuckID)
  else
    table.insert(rail, record.tuckID)
  end

  return record
end

function Store:getByWindowID(windowID)
  return self.windows[windowID]
end

function Store:getByTuckID(tuckID)
  return self.byTuckID[tuckID]
end

--- Remove a TuckedWindow (by windowID) from every index: windows table,
-- byTuckID table, and its rail. Idempotent -- calling this for a windowID
-- that is not present is a harmless no-op (returns nil).
-- Returns the removed record (or nil) and the shelfKey it was removed
-- from (or nil), so callers can trigger a reflow of just that rail.
function Store:removeWindow(windowID)
  local record = self.windows[windowID]
  if not record then
    return nil
  end

  self.windows[windowID] = nil
  self.byTuckID[record.tuckID] = nil

  local shelf = self:getShelf(record.screenUUID, record.spaceID)
  if shelf then
    local rail = shelf[record.edge]
    for i, tuckID in ipairs(rail) do
      if tuckID == record.tuckID then
        table.remove(rail, i)
        break
      end
    end
  end

  return record, Store.shelfKey(record.screenUUID, record.spaceID)
end

--- Same as removeWindow but looked up by tuckID (used by the card
-- manager / keyboard search, which only knows tuckIDs).
function Store:removeByTuckID(tuckID)
  local record = self.byTuckID[tuckID]
  if not record then
    return nil
  end
  return self:removeWindow(record.windowID)
end

--- Ordered list of TuckedWindow records currently on a given rail.
function Store:railRecords(screenUUID, spaceID, edge)
  local shelf = self:getShelf(screenUUID, spaceID)
  if not shelf then
    return {}
  end
  local out = {}
  for _, tuckID in ipairs(shelf[edge]) do
    local rec = self.byTuckID[tuckID]
    if rec then
      out[#out + 1] = rec
    end
  end
  return out
end

--- All TuckedWindow records anywhere (used for full-recovery / debugging
-- and for recreating orphaned cards).
function Store:allWindows()
  local out = {}
  for _, rec in pairs(self.windows) do
    out[#out + 1] = rec
  end
  return out
end

--- All TuckedWindow records belonging to a given spaceID, optionally
-- restricted to one screenUUID. Used to implement the two search-scope
-- modes (screenAndSpace vs space) without touching physical placement.
function Store:windowsForSpace(spaceID, screenUUID)
  local out = {}
  for _, rec in pairs(self.windows) do
    if rec.spaceID == spaceID and (screenUUID == nil or rec.screenUUID == screenUUID) then
      out[#out + 1] = rec
    end
  end
  return out
end

--- Every record in a stable, persistence-friendly order: shelf key, then
-- edge, then rail position. Each returned entry is `{ record, order }`
-- where `order` is the 1-based position on its rail.
function Store:orderedRecords()
  local keys = {}
  for key in pairs(self.shelves) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  local out = {}
  for _, key in ipairs(keys) do
    local shelf = self.shelves[key]
    for _, edge in ipairs(EDGES) do
      for i, tuckID in ipairs(shelf[edge]) do
        local rec = self.byTuckID[tuckID]
        if rec then
          out[#out + 1] = { record = rec, order = i }
        end
      end
    end
  end
  return out
end

--- Drop every record and shelf (used when the Spoon stops: runtime state
-- is rebuilt from the persisted file on the next start).
function Store:clear()
  self.windows = {}
  self.byTuckID = {}
  self.shelves = {}
end

function Store.edges()
  return EDGES
end

return Store
