--- Persistence module.
--
-- Runtime correctness has priority over persistence (spec). A raw
-- windowID is NOT durable across an application or system restart, so
-- this module deliberately does NOT attempt to automatically re-attach a
-- persisted record to a new window on the next Hammerspoon start --
-- doing so risks restoring the wrong window's frame onto some other,
-- unrelated window that happens to reuse a similar identity.
--
-- What this module DOES do, and it is disabled by default:
--   * on every state change, write a plain, human-inspectable snapshot
--     of current TuckedWindow metadata (bundleID, appName, windowTitle,
--     screenUUID, spaceID, edge, frame -- explicitly NOT windowID, since
--     it is not meaningfully durable) to `hs.settings`;
--   * on start, if a snapshot exists, surface it via a single log line
--     (and, optionally, a concise on-screen notice) so the user is aware
--     that N windows were tucked in a previous session and can manually
--     find/re-tuck them -- Tuck never silently claims a new window is
--     "the same" tucked window from before.
--
-- This is intentionally conservative. See README.md's "Persistence /
-- restart limitations" section.

local Persistence = {}
Persistence.__index = Persistence

local SETTINGS_KEY = "Tuck.spoon.lastSessionSnapshot"

function Persistence.new(hsRef, logger)
  local self = setmetatable({}, Persistence)
  self.hs = hsRef
  self.logger = logger
  self.enabled = false
  return self
end

function Persistence:setEnabled(enabled)
  self.enabled = enabled and true or false
end

--- Write a snapshot of every currently-tucked window's non-runtime
-- metadata. Safe/no-op when disabled. Never raises.
function Persistence:save(store)
  if not self.enabled then
    return
  end
  local ok, err = pcall(function()
    local snapshot = {}
    for _, record in ipairs(store:allWindows()) do
      snapshot[#snapshot + 1] = {
        bundleID = record.bundleID,
        appName = record.appName,
        windowTitle = record.windowTitle,
        screenUUID = record.screenUUID,
        spaceID = record.spaceID,
        edge = record.edge,
        frame = record.frame,
      }
    end
    self.hs.settings.set(SETTINGS_KEY, snapshot)
  end)
  if not ok and self.logger then
    self.logger.w("Tuck: failed to write persistence snapshot: " .. tostring(err))
  end
end

--- Read back whatever was last saved (for diagnostics/manual review
-- only -- see module header). Returns an array (possibly empty).
function Persistence:load()
  local ok, snapshot = pcall(function()
    return self.hs.settings.get(SETTINGS_KEY)
  end)
  if ok and type(snapshot) == "table" then
    return snapshot
  end
  return {}
end

--- Log a one-line, informational summary of the previous session's
-- snapshot (if any). Never auto-restores anything.
function Persistence:reportPreviousSession()
  if not self.enabled then
    return
  end
  local snapshot = self:load()
  if #snapshot > 0 and self.logger then
    self.logger.i(string.format(
      "Tuck: %d window(s) were tucked at the end of the previous session (not auto-restored; see README)",
      #snapshot
    ))
  end
end

function Persistence:clear()
  local ok, err = pcall(function()
    self.hs.settings.set(SETTINGS_KEY, {})
  end)
  if not ok and self.logger then
    self.logger.w("Tuck: failed to clear persistence snapshot: " .. tostring(err))
  end
end

return Persistence
