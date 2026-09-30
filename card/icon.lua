--- Native application icon manager.
--
-- Obtains the real application's native macOS icon via
-- `hs.image.imageFromAppBundle(bundleID)` and caches it for the lifetime
-- of the Spoon (icons are cheap, immutable, and shared across every card
-- for that application, so there is no need to re-resolve per tuck).
--
-- Never downloads icons, never bundles a manual icon collection, never
-- falls back to a generic icon when the real one can be obtained. If the
-- real icon truly cannot be obtained, callers simply omit the icon
-- element from the card rather than substituting a placeholder graphic
-- (per spec: "do not use a generic icon when the application's own icon
-- can be obtained" -- the corollary is that we don't invent one when it
-- cannot).

local IconManager = {}
IconManager.__index = IconManager

function IconManager.new(hsRef, logger)
  local self = setmetatable({}, IconManager)
  self.hs = hsRef
  self.logger = logger
  self.cache = {} -- bundleID -> hs.image object (or false if resolution failed)
  return self
end

--- Returns an hs.image object, or nil if the icon could not be resolved.
function IconManager:iconFor(bundleID)
  if not bundleID then
    return nil
  end
  local cached = self.cache[bundleID]
  if cached ~= nil then
    if cached == false then
      return nil
    end
    return cached
  end

  local ok, image = pcall(function()
    return self.hs.image.imageFromAppBundle(bundleID)
  end)

  if ok and image then
    self.cache[bundleID] = image
    return image
  end

  self.cache[bundleID] = false
  if self.logger then
    self.logger.d("Tuck: no native icon available for bundle " .. tostring(bundleID))
  end
  return nil
end

--- Drop the whole cache. Not required for correctness (bundle icons do
-- not change at runtime), but exposed for a clean stop()/reload cycle
-- and for tests.
function IconManager:clear()
  self.cache = {}
end

return IconManager
