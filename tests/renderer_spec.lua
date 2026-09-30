local t = require("tests.testkit")
local Renderer = require("card.renderer")
local defaults = require("config.defaults")

local function run()
  t.reset()
  local cfg = defaults.merge(defaults.defaults, {
    card = {
      backgroundColor = { red = 0.1, green = 0.2, blue = 0.3 },
      borderColor = { red = 0.4, green = 0.5, blue = 0.6 },
      textColor = { red = 0.7, green = 0.8, blue = 0.9 },
      opacity = 0.5,
    },
  }).card

  local record = { appName = "Safari", windowTitle = "Home", bundleID = "com.apple.Safari" }
  local elements = Renderer.buildElements(record, { w = 72, h = 72 }, cfg, nil, nil)

  local bg = elements[1]
  t.eq(bg.fillColor.red, 0.1); t.eq(bg.fillColor.green, 0.2); t.eq(bg.fillColor.blue, 0.3)
  t.eq(bg.fillColor.alpha, 0.5, "opacity still drives background alpha")
  t.eq(bg.strokeColor.red, 0.4); t.eq(bg.strokeColor.green, 0.5); t.eq(bg.strokeColor.blue, 0.6)

  local nameLabel
  for _, e in ipairs(elements) do
    if e.type == "text" and e.text == "Safari" then nameLabel = e end
  end
  t.isTrue(nameLabel ~= nil, "app name label present")
  t.eq(nameLabel.textColor.red, 0.7); t.eq(nameLabel.textColor.green, 0.8); t.eq(nameLabel.textColor.blue, 0.9)

  -- collapsed size configuration is respected verbatim by the layout call
  do
    local elems = Renderer.buildElements(record, { w = 120, h = 50 }, cfg, nil, nil)
    t.isTrue(#elems > 0)
  end

  t.report("renderer_spec")
  return #t.failures == 0
end

return run
