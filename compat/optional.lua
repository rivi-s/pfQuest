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
  optional.mapExploration = type(C_MapExplorationInfo) == "table"
    and type(C_MapExplorationInfo.GetExploredMapTextures) == "function"
end

-- ClassicAPI can read a zone's exploration bitfield without changing the
-- World Map selection. Keep the call here so map.lua has one guarded source
-- for optional client data and clean 1.12 clients never touch this API.
pfQuestCompat.GetExploredMapTextures = function(mapid)
  if not optional.mapExploration then return nil end

  local ok, overlays = pcall(C_MapExplorationInfo.GetExploredMapTextures, mapid)
  if ok and type(overlays) == "table" then
    return overlays
  end
end

-- Stock GetMapZones omits capital-city maps. ClassicAPI exposes the current
-- map folder's AreaTable ID, which lets pfQuest use the same zone key for a
-- city map as it does for that city's database nodes.
pfQuestCompat.GetCurrentMapAreaID = function()
  if not optional.classicapi or not C_Map or type(C_Map.GetMapAreaIDs) ~= "function" then return nil end
  local mapName = GetMapInfo and GetMapInfo()
  if not mapName then return nil end

  local ok, areas = pcall(C_Map.GetMapAreaIDs)
  if ok and type(areas) == "table" then
    return areas[mapName]
  end
end

pfQuestCompat.GetMapRectOnMap = function(mapid, topmapid)
  if not optional.classicapi or not C_Map or type(C_Map.GetMapRectOnMap) ~= "function" then return nil end
  local ok, left, right, top, bottom = pcall(C_Map.GetMapRectOnMap, mapid, topmapid)
  if ok and left and right and top and bottom then
    return left, right, top, bottom
  end
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
