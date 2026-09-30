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
    -- ONE shortcut for everything: press it, then an arrow key to tuck
    -- the focused window, or letters to search tucked apps and restore.
    tuck = { mods = { "fn" }, key = "t" },
  },

  input = {
    -- Seconds the command mode waits for input after the shortcut. It
    -- also restarts after every accepted search letter.
    commandTimeout = 1.5,
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
    -- Distance from the screen/work-area edge to the card's outer edge
    -- when a rail is NOT peeking (rails.<edge>.peek = false).
    edgeInset = 8,

    -- The three resting depths of a peeking rail (left/right by
    -- default). Each is "how many pixels of the card are visible inside
    -- the screen"; the card itself is never resized by these:
    --   peekSize        parked: only this much shows (edge hint)
    --   edgeRevealSize  pointer near the edge: this much shows
    -- and hovering/search-matching a card expands it fully
    -- (expandedWidth/expandedHeight).
    peekSize = 8,
    edgeRevealSize = 40,
    -- Thickness (px) of the invisible strip along a peeking edge that
    -- detects the pointer approaching. Must be >= peekSize.
    edgeTriggerSize = 64,
    -- Seconds the pointer may be away from a rail's cards/strip before
    -- the rail retracts. Prevents flicker while moving between cards.
    revealGraceDelay = 0.18,

    -- Whether hover/search expansion is enabled at all.
    expansionEnabled = true,
  },

  rails = {
    -- peek = true: cards sit mostly off-screen, reveal on approach.
    left = { origin = "center", margin = 12, padding = 10, peek = true },
    right = { origin = "center", margin = 12, padding = 10, peek = true },
    top = { origin = "center", margin = 12, padding = 10, peek = false },
    bottom = { origin = "center", margin = 12, padding = 10, peek = false },
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
    hoverDuration = 0.18, -- expand/collapse of a hovered or search-matched card
    revealDuration = 0.22, -- park <-> edge-reveal slide
    reflowDuration = 0.20, -- neighbours closing a gap / new card settling
    -- "easeOutCubic" | "easeInOutCubic" | "linear"
    easing = "easeOutCubic",
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

--- Translate configuration keys from earlier releases into the current
-- schema (on a copy; the caller's table is never modified).
--   shortcuts.untuck            -> removed (one shared shortcut now)
--   input.directionTimeout /
--   input.searchTimeout         -> input.commandTimeout
--   card.animationDuration      -> animation.hoverDuration
function M.migrate(overrides)
  if type(overrides) ~= "table" then
    return overrides
  end
  local out = deepcopy(overrides)
  if type(out.shortcuts) == "table" then
    out.shortcuts.untuck = nil
  end
  if type(out.input) == "table" then
    if out.input.commandTimeout == nil then
      out.input.commandTimeout = out.input.directionTimeout or out.input.searchTimeout
    end
    out.input.directionTimeout = nil
    out.input.searchTimeout = nil
  end
  if type(out.card) == "table" and out.card.animationDuration ~= nil then
    out.animation = out.animation or {}
    if out.animation.hoverDuration == nil then
      out.animation.hoverDuration = out.card.animationDuration
    end
    out.card.animationDuration = nil
  end
  return out
end

--- Shallow-merge (recursively for nested tables) `overrides` onto a copy of
-- `base`. Unknown top-level keys in `overrides` are copied through as-is so
-- callers get a clear validation error rather than silent loss.
local function mergeConfig(base, overrides, skipMigration)
  if not skipMigration then
    overrides = M.migrate(overrides)
  end
  local out = deepcopy(base)
  if overrides == nil then
    return out
  end
  for key, value in pairs(overrides) do
    if type(value) == "table" and type(out[key]) == "table" then
      out[key] = mergeConfig(out[key], value, true)
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

  if type(cfg.input) ~= "table" then
    return false, "configuration.input must be a table"
  end
  if type(cfg.input.commandTimeout) ~= "number" or cfg.input.commandTimeout <= 0 then
    return false, "configuration.input.commandTimeout must be a positive number"
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
  for _, k in ipairs({ "peekSize", "edgeRevealSize", "edgeTriggerSize", "revealGraceDelay" }) do
    if type(cfg.card[k]) ~= "number" or cfg.card[k] < 0 then
      return false, "configuration.card." .. k .. " must be a non-negative number"
    end
  end
  if cfg.card.edgeRevealSize < cfg.card.peekSize then
    return false, "configuration.card.edgeRevealSize must be >= peekSize"
  end
  if cfg.card.edgeTriggerSize < cfg.card.peekSize then
    return false, "configuration.card.edgeTriggerSize must be >= peekSize"
  end
  if cfg.card.edgeRevealSize > cfg.card.collapsedWidth or cfg.card.edgeRevealSize > cfg.card.collapsedHeight then
    return false, "configuration.card.edgeRevealSize must not exceed the collapsed card size"
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
    if type(rail.peek) ~= "boolean" then
      return false, "configuration.rails." .. edge .. ".peek must be a boolean"
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
  for _, k in ipairs({ "hoverDuration", "revealDuration", "reflowDuration" }) do
    if type(cfg.animation[k]) ~= "number" or cfg.animation[k] < 0 then
      return false, "configuration.animation." .. k .. " must be a non-negative number"
    end
  end
  if cfg.animation.easing ~= "easeOutCubic" and cfg.animation.easing ~= "easeInOutCubic" and cfg.animation.easing ~= "linear" then
    return false, "configuration.animation.easing must be one of easeOutCubic|easeInOutCubic|linear"
  end

  if type(cfg.logging) ~= "table" or not VALID_LOG_LEVELS[cfg.logging.level] then
    return false, "configuration.logging.level must be one of debug|info|warning|error"
  end

  return true
end

return M
