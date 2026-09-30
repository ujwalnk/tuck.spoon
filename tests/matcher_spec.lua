local t = require("tests.testkit")
local matcher = require("input.matcher")

local function run()
  t.reset()

  local candidates = {
    { tuckID = "1", appName = "Safari" },
    { tuckID = "2", appName = "Slack" },
    { tuckID = "3", appName = "Spotify" },
    { tuckID = "4", appName = "Terminal" },
    { tuckID = "5", appName = "Visual Studio Code" },
  }

  do
    local m = matcher.match(candidates, "S")
    t.eq(#m, 3, "S matches Safari, Slack, Spotify")
  end

  do
    local m = matcher.match(candidates, "SA")
    t.eq(#m, 1, "SA matches only Safari")
    t.eq(m[1].appName, "Safari")
  end

  do
    local m = matcher.match(candidates, "TE")
    t.eq(#m, 1)
    t.eq(m[1].appName, "Terminal")
  end

  do
    local m = matcher.match(candidates, "V")
    t.eq(#m, 1)
    t.eq(m[1].appName, "Visual Studio Code")
  end

  do
    local m = matcher.match(candidates, "s")
    t.eq(#m, 3, "matching is case-insensitive on the query")
  end

  do
    local m = matcher.match(candidates, "Z")
    t.eq(#m, 0, "no match for a prefix nobody has")
  end

  do
    local m = matcher.match(candidates, "")
    t.eq(#m, 0, "empty query matches nothing (search hasn't really started)")
  end

  -- Case-insensitivity on the candidate side too.
  do
    local mixedCase = { { tuckID = "1", appName = "sAfArI" } }
    local m = matcher.match(mixedCase, "SA")
    t.eq(#m, 1, "candidate app names matched case-insensitively too")
  end

  t.report("matcher_spec")
  return #t.failures == 0
end

return run
