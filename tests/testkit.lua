--- Minimal test kit: no external dependency (busted is not available in
-- every environment this Spoon will be developed/CI'd in), so tests run
-- directly under `lua5.4 tests/run_tests.lua`.

local M = {}
M.failures = {}
M.count = 0

local function locationPrefix()
  local info = debug.getinfo(3, "Sl")
  if info then
    return string.format("%s:%d: ", info.short_src, info.currentline)
  end
  return ""
end

function M.eq(actual, expected, msg)
  M.count = M.count + 1
  if actual ~= expected then
    table.insert(
      M.failures,
      string.format(
        "%s%s: expected %s, got %s",
        locationPrefix(),
        msg or "assertion failed",
        tostring(expected),
        tostring(actual)
      )
    )
  end
end

function M.almostEq(actual, expected, tolerance, msg)
  M.count = M.count + 1
  tolerance = tolerance or 1e-6
  if math.abs(actual - expected) > tolerance then
    table.insert(
      M.failures,
      string.format(
        "%s%s: expected ~%s, got %s",
        locationPrefix(),
        msg or "assertion failed",
        tostring(expected),
        tostring(actual)
      )
    )
  end
end

function M.isTrue(actual, msg)
  M.eq(actual, true, msg)
end

function M.isFalse(actual, msg)
  M.eq(actual, false, msg)
end

function M.isNil(actual, msg)
  M.count = M.count + 1
  if actual ~= nil then
    table.insert(M.failures, string.format("%s%s: expected nil, got %s", locationPrefix(), msg or "assertion failed", tostring(actual)))
  end
end

function M.report(suiteName)
  print(string.format("[%s] %d assertions, %d failures", suiteName, M.count, #M.failures))
  for _, f in ipairs(M.failures) do
    print("  FAIL: " .. f)
  end
end

function M.reset()
  M.failures = {}
  M.count = 0
end

return M
