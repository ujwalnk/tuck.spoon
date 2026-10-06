--- Tiny JSON encoder/decoder used only by tests/mock_hs.lua (real
-- Hammerspoon provides hs.json). Supports exactly what Tuck writes:
-- objects, arrays, strings, numbers, booleans, null.

local M = {}

local escapes = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function encodeString(s)
  return '"' .. s:gsub('[%c"\\]', function(c)
    return escapes[c] or string.format("\\u%04x", c:byte())
  end) .. '"'
end

local function isArray(t)
  local n = 0
  for _ in pairs(t) do
    n = n + 1
  end
  if n == 0 then
    return true
  end
  for i = 1, n do
    if t[i] == nil then
      return false
    end
  end
  return true
end

local function encode(v)
  local tv = type(v)
  if tv == "nil" then
    return "null"
  elseif tv == "boolean" then
    return tostring(v)
  elseif tv == "number" then
    if v ~= v or v == math.huge or v == -math.huge then
      error("cannot encode non-finite number")
    end
    if math.type(v) == "integer" or v % 1 == 0 then
      return string.format("%d", v)
    end
    return string.format("%.14g", v)
  elseif tv == "string" then
    return encodeString(v)
  elseif tv == "table" then
    local parts = {}
    if isArray(v) then
      for i = 1, #v do
        parts[#parts + 1] = encode(v[i])
      end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for k in pairs(v) do
      keys[#keys + 1] = k
    end
    table.sort(keys, function(a, b)
      return tostring(a) < tostring(b)
    end)
    for _, k in ipairs(keys) do
      parts[#parts + 1] = encodeString(tostring(k)) .. ":" .. encode(v[k])
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  error("cannot encode a " .. tv .. " (userdata/functions must never be persisted)")
end

function M.encode(v)
  return encode(v)
end

function M.decode(text)
  local pos = 1
  local function skip()
    pos = text:find("%S", pos) or #text + 1
  end
  local value
  local function parseString()
    local out = {}
    pos = pos + 1
    while true do
      local c = text:sub(pos, pos)
      if c == "" then
        error("unterminated string")
      elseif c == '"' then
        pos = pos + 1
        return table.concat(out)
      elseif c == "\\" then
        local n = text:sub(pos + 1, pos + 1)
        local map = { n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
        if n == "u" then
          out[#out + 1] = utf8.char(tonumber(text:sub(pos + 2, pos + 5), 16))
          pos = pos + 6
        else
          out[#out + 1] = map[n] or n
          pos = pos + 2
        end
      else
        out[#out + 1] = c
        pos = pos + 1
      end
    end
  end
  function value()
    skip()
    local c = text:sub(pos, pos)
    if c == "{" then
      local obj = {}
      pos = pos + 1
      skip()
      if text:sub(pos, pos) == "}" then
        pos = pos + 1
        return obj
      end
      while true do
        skip()
        if text:sub(pos, pos) ~= '"' then
          error("expected key")
        end
        local k = parseString()
        skip()
        if text:sub(pos, pos) ~= ":" then
          error("expected colon")
        end
        pos = pos + 1
        obj[k] = value()
        skip()
        local d = text:sub(pos, pos)
        pos = pos + 1
        if d == "}" then
          return obj
        elseif d ~= "," then
          error("expected , or }")
        end
      end
    elseif c == "[" then
      local arr = {}
      pos = pos + 1
      skip()
      if text:sub(pos, pos) == "]" then
        pos = pos + 1
        return arr
      end
      while true do
        arr[#arr + 1] = value()
        skip()
        local d = text:sub(pos, pos)
        pos = pos + 1
        if d == "]" then
          return arr
        elseif d ~= "," then
          error("expected , or ]")
        end
      end
    elseif c == '"' then
      return parseString()
    elseif text:sub(pos, pos + 3) == "true" then
      pos = pos + 4
      return true
    elseif text:sub(pos, pos + 4) == "false" then
      pos = pos + 5
      return false
    elseif text:sub(pos, pos + 3) == "null" then
      pos = pos + 4
      return nil
    end
    local num = text:match("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
    if not num or num == "" then
      error("unexpected character at " .. pos)
    end
    pos = pos + #num
    return tonumber(num)
  end
  local result = value()
  skip()
  if pos <= #text then
    error("trailing characters")
  end
  return result
end

return M
