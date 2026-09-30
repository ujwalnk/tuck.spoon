--- Tuck.spoon default configuration and validation.
--
-- This module is intentionally free of any `hs.*` dependency so it can be
-- required and unit tested outside of Hammerspoon.

local M = {}

--- The full set of documented, production defaults.
--
-- Every field here is user-configurable through `Tuck:configure({...})`
-- (a shallow-merged table). See README.md for the full description of
-- each option.
M.defaults = {
  shortcuts = {
    -- Table form: {mods = {"fn"}, key = "t"} so that Fn (which is not a
    -- normal hs.hotkey modifier) can be expressed uniformly. `mods` may
    -- contain any of: "cmd", "alt", "shift", "ctrl", "fn".
    tuck = { mods = { "fn" }, key = "t" },
    untuck = { mods = { "cmd", "shift" }, key = "t" },
  },

  input = {
    directionTimeout = 1.5, -- seconds
    searchTimeout = 1.5, -- seconds
  },

  card = {
    showAppIcon = true,
    showThumbnail = true,
    showAppName = true,
    showWindowTitle = false,

    collapsedWidth = 72,
    collapsedHeight = 72,
    expandedWidth = 220,
    expandedHeight = 160,

    cornerRadius = 14,
    opacity = 0.92,
    -- Distance from the screen/work-area edge to the card's outer edge.
    edgeInset = 8,

    -- Whether hover/search expansion is enabled at all.
    expansionEnabled = true,
    animationDuration = 0.12,
  },

  rails = {
    left = { origin = "center", margin = 12, padding = 10 },
    right = { origin = "center", margin = 12, padding = 10 },
    top = { origin = "center", margin = 12, padding = 10 },
    bottom = { origin = "center", margin = 12, padding = 10 },
  },

  screen = {
    -- "workarea" or "full"
    useWorkArea = true,
  },

  search = {
    -- "screenAndSpace" or "space"
    scope = "screenAndSpace",
  },

  animation = {
    hoverDuration = 0.12,
    tuckRestoreDuration = 0.0, -- 0 disables (no documented HS window animation is required)
  },

  logging = {
    level = "info", -- "debug" | "info" | "warning" | "error"
  },
}

local VALID_ORIGINS = { center = true, start = true, ["end"] = true }
local VALID_EDGES = { left = true, right = true, top = true, bottom = true }
local VALID_SCOPES = { screenAndSpace = true, space = true }
local VALID_LOG_LEVELS = { debug = true, info = true, warning = true, error = true }
local VALID_MODS = { cmd = true, alt = true, shift = true, ctrl = true, fn = true }

--- Deep-copy a plain table (no metatables, no cycles expected).
local function deepcopy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for k, v in pairs(value) do
    out[k] = deepcopy(v)
  end
  return out
end
M.deepcopy = deepcopy

--- Shallow-merge (recursively for nested tables) `overrides` onto a copy of
-- `base`. Unknown top-level keys in `overrides` are copied through as-is so
-- callers get a clear validation error rather than silent loss.
local function mergeConfig(base, overrides)
  local out = deepcopy(base)
  if overrides == nil then
    return out
  end
  for key, value in pairs(overrides) do
    if type(value) == "table" and type(out[key]) == "table" then
      out[key] = mergeConfig(out[key], value)
    else
      out[key] = deepcopy(value)
    end
  end
  return out
end
M.merge = mergeConfig

--- Validate a shortcut spec table. Returns true, or false + message.
local function validateShortcut(name, spec)
  if type(spec) ~= "table" then
    return false, name .. " shortcut must be a table"
  end
  if type(spec.key) ~= "string" or #spec.key == 0 then
    return false, name .. " shortcut requires a non-empty string `key`"
  end
  if spec.mods ~= nil then
    if type(spec.mods) ~= "table" then
      return false, name .. " shortcut `mods` must be a table"
    end
    for _, m in ipairs(spec.mods) do
      if not VALID_MODS[m] then
        return false, string.format("%s shortcut has unknown modifier %q", name, tostring(m))
      end
    end
  end
  return true
end

--- Validate a fully-merged configuration table.
-- Returns true on success, or false, "message" on the first problem found.
function M.validate(cfg)
  if type(cfg) ~= "table" then
    return false, "configuration must be a table"
  end

  if type(cfg.shortcuts) ~= "table" then
    return false, "configuration.shortcuts must be a table"
  end
  local ok, err = validateShortcut("tuck", cfg.shortcuts.tuck)
  if not ok then
    return false, err
  end
  ok, err = validateShortcut("untuck", cfg.shortcuts.untuck)
  if not ok then
    return false, err
  end

  if type(cfg.input) ~= "table" then
    return false, "configuration.input must be a table"
  end
  if type(cfg.input.directionTimeout) ~= "number" or cfg.input.directionTimeout <= 0 then
    return false, "configuration.input.directionTimeout must be a positive number"
  end
  if type(cfg.input.searchTimeout) ~= "number" or cfg.input.searchTimeout <= 0 then
    return false, "configuration.input.searchTimeout must be a positive number"
  end

  if type(cfg.card) ~= "table" then
    return false, "configuration.card must be a table"
  end
  for _, dim in ipairs({ "collapsedWidth", "collapsedHeight", "expandedWidth", "expandedHeight" }) do
    if type(cfg.card[dim]) ~= "number" or cfg.card[dim] <= 0 then
      return false, "configuration.card." .. dim .. " must be a positive number"
    end
  end
  if cfg.card.expandedWidth < cfg.card.collapsedWidth or cfg.card.expandedHeight < cfg.card.collapsedHeight then
    return false, "configuration.card expanded dimensions must be >= collapsed dimensions"
  end
  if type(cfg.card.cornerRadius) ~= "number" or cfg.card.cornerRadius < 0 then
    return false, "configuration.card.cornerRadius must be a non-negative number"
  end
  if type(cfg.card.opacity) ~= "number" or cfg.card.opacity < 0 or cfg.card.opacity > 1 then
    return false, "configuration.card.opacity must be between 0 and 1"
  end
  if type(cfg.card.edgeInset) ~= "number" or cfg.card.edgeInset < 0 then
    return false, "configuration.card.edgeInset must be a non-negative number"
  end
  if type(cfg.card.animationDuration) ~= "number" or cfg.card.animationDuration < 0 then
    return false, "configuration.card.animationDuration must be a non-negative number"
  end

  if type(cfg.rails) ~= "table" then
    return false, "configuration.rails must be a table"
  end
  for edge in pairs(VALID_EDGES) do
    local rail = cfg.rails[edge]
    if type(rail) ~= "table" then
      return false, "configuration.rails." .. edge .. " must be a table"
    end
    if not VALID_ORIGINS[rail.origin] then
      return false, "configuration.rails." .. edge .. ".origin must be one of center|start|end"
    end
    if type(rail.margin) ~= "number" or rail.margin < 0 then
      return false, "configuration.rails." .. edge .. ".margin must be a non-negative number"
    end
    if type(rail.padding) ~= "number" or rail.padding < 0 then
      return false, "configuration.rails." .. edge .. ".padding must be a non-negative number"
    end
  end

  if type(cfg.screen) ~= "table" or type(cfg.screen.useWorkArea) ~= "boolean" then
    return false, "configuration.screen.useWorkArea must be a boolean"
  end

  if type(cfg.search) ~= "table" or not VALID_SCOPES[cfg.search.scope] then
    return false, "configuration.search.scope must be one of screenAndSpace|space"
  end

  if type(cfg.animation) ~= "table" then
    return false, "configuration.animation must be a table"
  end
  if type(cfg.animation.hoverDuration) ~= "number" or cfg.animation.hoverDuration < 0 then
    return false, "configuration.animation.hoverDuration must be a non-negative number"
  end
  if type(cfg.animation.tuckRestoreDuration) ~= "number" or cfg.animation.tuckRestoreDuration < 0 then
    return false, "configuration.animation.tuckRestoreDuration must be a non-negative number"
  end

  if type(cfg.logging) ~= "table" or not VALID_LOG_LEVELS[cfg.logging.level] then
    return false, "configuration.logging.level must be one of debug|info|warning|error"
  end

  return true
end

return M
