--- Case-insensitive application-name prefix matcher.
--
-- Pure data-in/data-out module: given a list of candidate records (each
-- with at least `tuckID` and `appName`) and a query string, returns the
-- subset whose appName starts with the query, case-insensitively.
--
-- No fuzzy matching, no substring matching -- exactly what the spec
-- requires for v1.

local M = {}

--- candidates: array of { tuckID = ..., appName = ..., ... (anything else) }
--- query: string, already expected to be letters only (A-Z), but this
---        function itself does not validate that -- callers (input/state.lua)
---        are responsible for restricting input to A-Z before calling.
function M.match(candidates, query)
  if query == nil or query == "" then
    return {}
  end
  local upperQuery = query:upper()
  local out = {}
  for _, candidate in ipairs(candidates) do
    local name = candidate.appName or ""
    if name:upper():sub(1, #upperQuery) == upperQuery then
      out[#out + 1] = candidate
    end
  end
  return out
end

return M
