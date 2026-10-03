-- Decide once, before any large Lua database table is constructed.
-- TOCs still list the files for stock-client compatibility; each native-owned
-- file returns before its table declaration when the HDB backend is selected.
pfQuestBackend = { mode = "lua", reason = "HearthDB is unavailable" }
local backend = pfQuestBackend
local function IsEnabled(name)
  if type(GetAddOnInfo) ~= "function" then return false end
  local addon, _, _, enabled = GetAddOnInfo(name)
  return addon and (enabled == true or enabled == 1) or false
end

-- Native provider data currently targets Vanilla and English. Other clients
-- retain their existing Lua expansion/localization data.
local version = GetBuildInfo and GetBuildInfo() or ""
if not string.find(version, "^1%.") or (GetLocale and GetLocale() ~= "enUS") then
  backend.reason = "Lua database required for this client or locale"
  return
end
if type(HDB_GetVersion) ~= "function" or type(HDB_OpenAddon) ~= "function"
  or type(HDB_QueryRawAsync) ~= "function" or type(HDB_ClearPoison) ~= "function"
  or type(HDB_Close) ~= "function" then return end

local turtle = IsEnabled("pfQuest-turtle")
local provider = turtle and "pfQuest-HearthDB-turtle" or "pfQuest-HearthDB"
local path = turtle and "data/pfquest-turtle.sqlite" or "data/pfquest.sqlite"
if not IsEnabled(provider) then
  backend.reason = "Matching HearthDB provider is missing or disabled"
  return
end

-- Probe the real database before skipping Lua. Hand this handle to the
-- companion when it loads so there is only one native open for this session.
local ok, handle = pcall(HDB_OpenAddon, provider, path)
if not ok or not handle then
  backend.reason = "HearthDB database could not be opened"
  return
end
backend.mode = "hdb"
backend.reason = "Matching HearthDB database opened"
backend.provider = provider
backend.handle = handle
