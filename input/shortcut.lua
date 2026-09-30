--- Shortcut abstraction layer.
--
-- The rest of the application must not care whether a given shortcut is
-- registered through `hs.hotkey` or `hs.eventtap` (spec requirement). `Fn`
-- is not a normal hs.hotkey modifier, so any shortcut spec that includes
-- "fn" is registered via a shared `hs.eventtap` keyDown watcher that
-- inspects `event:getFlags()` (which does expose a boolean `fn` field);
-- every other shortcut is registered the conventional, cheaper way via
-- `hs.hotkey.bind`, which lets the OS do the matching for us.
--
-- A "shortcut spec" is `{ mods = {"cmd","shift",...}, key = "t" }` where
-- mods may include "cmd", "alt", "shift", "ctrl", "fn".
--
-- Only ONE eventtap is ever created per Shortcut instance (shared),
-- regardless of how many fn-based shortcuts are registered, to avoid
-- redundant global keyboard taps. Non-fn shortcuts never touch the
-- eventtap at all, and the eventtap callback only swallows (returns
-- true for) the exact key/modifier combinations that were bound through
-- it -- everything else passes through untouched, so we never swallow
-- unrelated global keyboard events.

local Shortcut = {}
Shortcut.__index = Shortcut

--- Does this event's flag set exactly match the required modifier set
-- for a bound fn-shortcut? We require an exact match (not just "at
-- least these") so that e.g. Fn+T does not also fire while the user is
-- additionally holding Cmd for some unrelated reason.
local function flagsMatch(flags, requiredMods)
  local wanted = {}
  for _, m in ipairs(requiredMods) do
    wanted[m] = true
    if not flags[m] then
      return false
    end
  end
  for _, m in ipairs({ "cmd", "alt", "shift", "ctrl", "fn" }) do
    if flags[m] and not wanted[m] then
      return false
    end
  end
  return true
end

--- Build the manager. `hsRef` is passed in (rather than required at
-- module load time) purely so this file can be loaded outside of
-- Hammerspoon for structural inspection/testing without erroring on a
-- missing global.
function Shortcut.new(hsRef)
  local self = setmetatable({}, Shortcut)
  self.hs = hsRef
  self.hotkeys = {} -- list of hs.hotkey objects we own
  self.fnBindings = {} -- list of { keyCode = ..., mods = {...}, handler = fn }
  self.eventtap = nil
  self.logger = nil
  return self
end

function Shortcut:setLogger(logger)
  self.logger = logger
end

local function containsFn(spec)
  if not spec.mods then
    return false
  end
  for _, m in ipairs(spec.mods) do
    if m == "fn" then
      return true
    end
  end
  return false
end

local function nonFnMods(spec)
  local out = {}
  for _, m in ipairs(spec.mods or {}) do
    if m ~= "fn" then
      out[#out + 1] = m
    end
  end
  return out
end

--- Register `spec` (a shortcut table) to call `handler()` on key-down.
-- Returns an opaque token (currently unused by callers, but kept for a
-- future selective-unbind feature); :unbindAll() is the supported way to
-- tear everything down.
function Shortcut:bind(spec, handler)
  assert(type(spec) == "table" and spec.key, "invalid shortcut spec")

  if containsFn(spec) then
    return self:_bindViaEventtap(spec, handler)
  end
  return self:_bindViaHotkey(spec, handler)
end

function Shortcut:_bindViaHotkey(spec, handler)
  local hk = self.hs.hotkey.bind(nonFnMods(spec), spec.key, handler)
  table.insert(self.hotkeys, hk)
  return { kind = "hotkey", ref = hk }
end

function Shortcut:_ensureEventtap()
  if self.eventtap then
    return
  end
  local hs = self.hs
  local this = self
  self.eventtap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(event)
    local flags = event:getFlags()
    local keyCode = event:getKeyCode()
    for _, binding in ipairs(this.fnBindings) do
      if binding.keyCode == keyCode and flagsMatch(flags, binding.mods) then
        local ok, err = pcall(binding.handler)
        if not ok and this.logger then
          this.logger.e("Tuck: error in fn-shortcut handler: " .. tostring(err))
        end
        -- We only ever swallow the specific key combination we bound;
        -- everything else passes through untouched.
        return true
      end
    end
    return false
  end)
  self.eventtap:start()
end

function Shortcut:_bindViaEventtap(spec, handler)
  self:_ensureEventtap()
  local hs = self.hs
  local keyCode = hs.keycodes.map[spec.key:lower()]
  if keyCode == nil then
    if self.logger then
      self.logger.e("Tuck: unknown key in shortcut spec: " .. tostring(spec.key))
    end
    return nil
  end
  local mods = {}
  for _, m in ipairs(spec.mods) do
    mods[#mods + 1] = m
  end
  local binding = { keyCode = keyCode, mods = mods, handler = handler }
  table.insert(self.fnBindings, binding)
  return { kind = "eventtap", ref = binding }
end

--- Unbind everything this manager owns. Idempotent -- safe to call on an
-- instance that was never bound to anything, and safe to call twice.
function Shortcut:unbindAll()
  for _, hk in ipairs(self.hotkeys) do
    hk:delete()
  end
  self.hotkeys = {}

  self.fnBindings = {}
  if self.eventtap then
    self.eventtap:stop()
    self.eventtap = nil
  end
end

-- Exposed for unit testing of the matching predicate without needing a
-- real hs.eventtap.
Shortcut._flagsMatch = flagsMatch

return Shortcut
