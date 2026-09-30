--- Standalone test runner for the pure/unit-testable parts of Tuck.spoon.
--
-- Usage (from the Tuck.spoon directory):
--   lua5.4 tests/run_tests.lua
--
-- This does not (and cannot) exercise anything that depends on the real
-- `hs.*` API surface (canvas rendering, window minimization, spaces,
-- eventtaps, etc). Those paths are covered by the manual OS-level
-- validation checklist in README.md. This runner covers every module
-- that was designed to have zero Hammerspoon dependency:
--   - config/defaults.lua   (validation)
--   - space/geometry.lua    (rail stacking math)
--   - state/store.lua       (TuckState indexes)
--   - input/state.lua       (input state machine)
--   - input/matcher.lua     (app-name prefix matching)

-- Make `require("tests.testkit")` / `require("space.geometry")` etc. work
-- when invoked as `lua5.4 tests/run_tests.lua` from the spoon root.
package.path = "./?.lua;./?/init.lua;" .. package.path

local suites = {
  { name = "config_defaults_spec", fn = require("tests.config_defaults_spec") },
  { name = "geometry_spec", fn = require("tests.geometry_spec") },
  { name = "store_spec", fn = require("tests.store_spec") },
  { name = "input_state_spec", fn = require("tests.input_state_spec") },
  { name = "matcher_spec", fn = require("tests.matcher_spec") },
  { name = "shortcut_flags_spec", fn = require("tests.shortcut_flags_spec") },
  { name = "animator_spec", fn = require("tests.animator_spec") },
  { name = "integration_spec", fn = require("tests.integration_spec") },
}

local allPassed = true
for _, suite in ipairs(suites) do
  local ok, passed = pcall(suite.fn)
  if not ok then
    print(string.format("[%s] CRASHED: %s", suite.name, tostring(passed)))
    allPassed = false
  elseif not passed then
    allPassed = false
  end
end

print("")
if allPassed then
  print("ALL SUITES PASSED")
  os.exit(0)
else
  print("SOME SUITES FAILED")
  os.exit(1)
end
