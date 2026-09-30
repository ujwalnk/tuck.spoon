--- Preview (thumbnail) manager.
--
-- Handles:
--  * determining whether Screen Recording permission is available
--    (`hs.screenRecordingState`, without prompting -- we never want a
--    tuck keystroke to unexpectedly trigger a system permission dialog);
--  * capturing a snapshot of a window immediately before it is minimized;
--  * returning nil when unavailable or on any capture failure;
--  * the caller (window/manager.lua) is responsible for caching the
--    resulting image on the TuckedWindow record -- this module never
--    recaptures or polls.
--
-- The rest of the Spoon never needs to understand Screen Recording
-- permission details; it only ever asks this module "give me a snapshot
-- (or nil)".

local PreviewManager = {}
PreviewManager.__index = PreviewManager

function PreviewManager.new(hsRef, logger)
  local self = setmetatable({}, PreviewManager)
  self.hs = hsRef
  self.logger = logger
  return self
end

--- Returns true/false. Never prompts (shouldPrompt = false) -- tucking a
-- window must never be interrupted by a permission dialog. Users grant
-- Screen Recording permission the normal way (System Settings), which
-- README.md documents.
function PreviewManager:hasPermission()
  local hs = self.hs
  local ok, enabled = pcall(function()
    return hs.screenRecordingState(false)
  end)
  if ok then
    return enabled == true
  end
  -- If the API itself is unavailable (unlikely, but defensive per spec:
  -- "graceful handling of Screen Recording permission problems"), treat
  -- as unavailable rather than erroring.
  if self.logger then
    self.logger.w("Tuck: hs.screenRecordingState unavailable; disabling thumbnail capture")
  end
  return false
end

--- Capture a snapshot of `window` (an hs.window object) if enabled and
-- permitted. Returns an hs.image object, or nil. Never raises: any
-- failure (permission denied, window already gone, snapshot API
-- unavailable) is logged at debug level and results in nil, never an
-- error that could abort the tuck operation in progress.
function PreviewManager:capture(window, enabled)
  if not enabled then
    return nil
  end
  if not self:hasPermission() then
    if self.logger then
      self.logger.d("Tuck: Screen Recording permission unavailable; using blank preview")
    end
    return nil
  end

  local ok, image = pcall(function()
    return window:snapshot()
  end)

  if ok and image then
    return image
  end

  if self.logger then
    self.logger.d("Tuck: window snapshot capture failed/unavailable; continuing without a thumbnail")
  end
  return nil
end

return PreviewManager
