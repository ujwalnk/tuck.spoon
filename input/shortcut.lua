--- Shortcut registration.
--
-- The activation shortcut is registered with a plain `hs.hotkey` (the OS
-- matches the key combination; Tuck has no keyboard eventtap while idle).
-- Fn is not supported: it is not an hs.hotkey modifier and emulating it
-- needed a permanent global keyboard eventtap, which this Spoon
-- deliberately does not have.
--
-- A "shortcut spec" is `{ mods = {"alt", ...}, key = "f3" }` where mods
-- may include "cmd", "alt", "shift", "ctrl".
--
-- `Shortcut._flagsMatch` is also used by the temporary command-mode
-- eventtap to recognise (and ignore) a repeat of the activation
-- combination itself.

local Shortcut = {}
Shortcut.__index = Shortcut

local MODS = { "cmd", "alt", "shift", "ctrl" }

--- Does this event's flag set exactly match the required modifier set?
-- Exact (not "at least") so Option+F3 is not also matched while the user
-- holds an additional unrelated modifier.
local function flagsMatch(flags, requiredMods)
  local wanted = {}
  for _, m in ipairs(requiredMods) do
    wanted[m] = true
    if not flags[m] then
      return false
    end
  end
  for _, m in ipairs(MODS) do
    if flags[m] and not wanted[m] then
      return false
    end
  end
  return true
end

function Shortcut.new(hsRef)
  local self = setmetatable({}, Shortcut)
  self.hs = hsRef
  self.hotkeys = {} -- hs.hotkey objects we own
  self.logger = nil
  return self
end

function Shortcut:setLogger(logger)
  self.logger = logger
end

--- Register `spec` to call `handler()` on key-down. Re-binding first
-- removes anything previously bound, so a manager never owns duplicates.
function Shortcut:bind(spec, handler)
  assert(type(spec) == "table" and spec.key, "invalid shortcut spec")
  self:unbindAll()
  local hk = self.hs.hotkey.bind(spec.mods or {}, spec.key, handler)
  self.hotkeys[#self.hotkeys + 1] = hk
  return hk
end

--- Unbind everything this manager owns. Idempotent.
function Shortcut:unbindAll()
  for _, hk in ipairs(self.hotkeys) do
    hk:delete()
  end
  self.hotkeys = {}
end

Shortcut._flagsMatch = flagsMatch

return Shortcut
