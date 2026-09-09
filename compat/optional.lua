-- Optional client extensions. These are DLL-provided APIs, not addon
-- dependencies, so every call is guarded and the normal 1.12 path remains
-- the default when they are absent.
local optional = {}
pfQuestCompat.optional = optional

optional.classicapi = type(CLASSIC_API_VERSION) ~= "nil"
optional.hearthdb = type(HDB_GetVersion) == "function"

if optional.classicapi then
  optional.nameplates = type(C_NamePlate) == "table"
    and type(C_NamePlate.GetNamePlateForUnit) == "function"
    and type(C_NamePlate.GetNamePlates) == "function"
  optional.questEvents = true
end

-- Prefer ClassicAPI's direct item-ID lookup when present. Vanilla's
-- GetItemIcon and all existing tooltip fallbacks remain available otherwise.
pfQuestCompat.GetItemIcon = function(itemid)
  local icon
  if optional.classicapi and C_Item and type(C_Item.GetItemIconByID) == "function" then
    local ok, result = pcall(C_Item.GetItemIconByID, itemid)
    if ok and result then icon = result end
  end

  if not icon and GetItemIcon then
    local ok, result = pcall(GetItemIcon, itemid)
    if ok and result then icon = result end
  end

  return icon
end

pfQuestCompat.GetOptionalApiStatus = function()
  return optional.classicapi, optional.hearthdb
end
