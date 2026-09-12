-- multi api compat
local compat = pfQuestCompat

-- Performance: cache frequently-used globals
local pairs, ipairs, next = pairs, ipairs, next
local strfind, strlower, strsub = strfind, strlower, strsub
local format = string.format
local min, max, abs = math.min, math.max, math.abs
local sqrt, sin, cos = sqrt or math.sqrt, sin or math.sin, cos or math.cos
local floor, ceil = floor or math.floor, ceil or math.ceil
local getn, insert = table.getn, table.insert
local tostring, tonumber, type, unpack = tostring, tonumber, type, unpack
local GetTime = GetTime
local MouseIsOver = MouseIsOver

-- fake the pfQuest minimap node names to Gatherer names,
-- if any minimap-breaking addon collector is found.
local nodename = "pfMiniMapPin"
local minimapbreakers = {
  ["ElvUI_MinimapButtons"] = true,
  ["MBB"] = true,
}

local compatnamefake = CreateFrame("Frame")
compatnamefake:RegisterEvent("PLAYER_ENTERING_WORLD")
compatnamefake:SetScript("OnEvent", function()
  -- only run once on login
  this:UnregisterAllEvents()

  -- scan through all addons to identify button collectors
  for i = 1, GetNumAddOns() do
    local name, title, notes, enabled = GetAddOnInfo(i)
    if enabled and minimapbreakers[name] then
      nodename = "GatherNoteCompatFake"
    end
  end
end)

-- checking for control key is very time expensive in 1.12
-- this loop puts it into one place and only updates it every .2 seconds
-- it also only updates the key if the mouse is over a relevant frame
local controlkey = CreateFrame("Frame", "pfQuestControlKey", UIParent)
controlkey:SetScript("OnUpdate", function()
  if (this.throttle or 0.2) > GetTime() then
    return
  else
    this.throttle = GetTime() + 0.2
  end
  if WorldMapFrame:IsShown() and MouseIsOver(WorldMapFrame) or MouseIsOver(pfMap.drawlayer) then
    controlkey.pressed = IsControlKeyDown()
  end
end)

local validmaps = setmetatable({}, { __mode = "kv" })
local rgbcache = setmetatable({}, { __mode = "kv" })
local minimap_sizes = pfDB["minimap"]
local minimap_zoom = {
  [0] = {
    [0] = 300,
    [1] = 240,
    [2] = 180,
    [3] = 120,
    [4] = 80,
    [5] = 50,
  },

  [1] = {
    [0] = 466 + 2 / 3,
    [1] = 400,
    [2] = 333 + 1 / 3,
    [3] = 266 + 2 / 6,
    [4] = 200,
    [5] = 133 + 1 / 3,
  },
}

local unifiedcache = {}

-- used to store/cache combined meta data across nodes of
-- the same kind to avoid duplicating data for each pin
-- the objects here get directly attached to the pfMap nodes
local similar_nodes = {}

-- Coordinate parse cache (shared between UpdateNodes and UpdateMinimap)
local coord_cache = {}

local function IsEmpty(tabl)
  for k, v in pairs(tabl) do
    return false
  end
  return true
end

-- Ensure pfQuestConfig.path exists (fallback if config.lua failed)
local addon_path = (pfQuestConfig and pfQuestConfig.path) or "Interface\\AddOns\\pfQuest"

local layers = {
  -- regular icons
  [addon_path .. "\\img\\available"] = 1,
  [addon_path .. "\\img\\available_c"] = 2,
  [addon_path .. "\\img\\complete"] = 3,
  [addon_path .. "\\img\\complete_c"] = 4,
  [addon_path .. "\\img\\icon_vendor"] = 5,
  [addon_path .. "\\img\\fav"] = 6,

  -- cluster textures
  [addon_path .. "\\img\\cluster_item"] = 9,
  [addon_path .. "\\img\\cluster_mob"] = 9,
  [addon_path .. "\\img\\cluster_misc"] = 9,
  [addon_path .. "\\img\\cluster_mob_mono"] = 9,
  [addon_path .. "\\img\\cluster_item_mono"] = 9,
  [addon_path .. "\\img\\cluster_misc_mono"] = 9,
}

-- Pre-computed texture paths (avoid string concatenation in hot paths)
local TEX_NODECUT = addon_path .. "\\img\\nodecut"
local TEX_NODE = addon_path .. "\\img\\node"

local function GetLayerByTexture(tex)
  if layers[tex] then
    return layers[tex]
  else
    return 1
  end
end

local function minimap_indoor()
  local tempzoom = 0
  local state = 1
  if GetCVar("minimapZoom") == GetCVar("minimapInsideZoom") then
    if GetCVar("minimapInsideZoom") + 0 >= 3 then
      pfMap.drawlayer:SetZoom(pfMap.drawlayer:GetZoom() - 1)
      tempzoom = 1
    else
      pfMap.drawlayer:SetZoom(pfMap.drawlayer:GetZoom() + 1)
      tempzoom = -1
    end
  end

  if GetCVar("minimapInsideZoom") + 0 == pfMap.drawlayer:GetZoom() then
    state = 0
  end

  pfMap.drawlayer:SetZoom(pfMap.drawlayer:GetZoom() + tempzoom)
  return state
end

local function str2rgb(text)
  if not text then
    return 1, 1, 1
  end
  if pfQuest_colors[text] then
    return unpack(pfQuest_colors[text])
  end
  if rgbcache[text] then
    return unpack(rgbcache[text])
  end
  local counter = 1
  local l = string.len(text)
  for i = 1, l, 3 do
    counter = compat.mod(counter * 8161, 4294967279)
      + (string.byte(text, i) * 16776193)
      + ((string.byte(text, i + 1) or (l - i + 256)) * 8372226)
      + ((string.byte(text, i + 2) or (l - i + 256)) * 3932164)
  end
  local hash = compat.mod(compat.mod(counter, 4294967291), 16777216)
  local r = (hash - (compat.mod(hash, 65536))) / 65536
  local g = ((hash - r * 65536) - (compat.mod((hash - r * 65536), 256))) / 256
  local b = hash - r * 65536 - g * 256
  rgbcache[text] = { r / 255, g / 255, b / 255 }
  return unpack(rgbcache[text])
end

local fpsmod, step
local function NodeAnimate(self, zoom, alpha, fps)
  local cur_zoom = self:GetWidth()
  local cur_alpha = self:GetAlpha()
  local change = nil
  self:EnableMouse(true)
  fpsmod = math.min(2 / fps, 2)
  step = fpsmod / 10

  -- update size
  if math.abs(cur_zoom - zoom) < 3 then
    self:SetWidth(zoom)
    self:SetHeight(zoom)
  elseif cur_zoom < zoom then
    self:SetWidth(cur_zoom + fpsmod)
    self:SetHeight(cur_zoom + fpsmod)
    change = true
  elseif cur_zoom > zoom then
    self:SetWidth(cur_zoom - fpsmod)
    self:SetHeight(cur_zoom - fpsmod)
    change = true
  end

  -- update alpha
  if math.abs(cur_alpha - alpha) < step then
    self:SetAlpha(alpha)

    -- disable mouse on hidden
    if alpha < 0.1 then
      self:EnableMouse(nil)
    end
  elseif cur_alpha < alpha then
    self:SetAlpha(cur_alpha + step)
    change = true
  elseif cur_alpha > alpha then
    self:SetAlpha(cur_alpha - step)
    change = true
  end

  return change
end

-- put player position above everything on worldmap
for k, v in pairs({ WorldMapFrame:GetChildren() }) do
  if v:IsObjectType("Model") and not v:GetName() then
    if string.find(strlower(v:GetModel()), "interface\\minimap\\minimaparrow") then
      v:SetFrameLevel(255)
      break
    end
  end
end

pfMap = CreateFrame("Frame", "pfQuestMap", WorldFrame)
pfMap.str2rgb = str2rgb
pfMap.tooltips = {}
pfMap.nodes = {}
pfMap.pins = {}
pfMap.mpins = {}
-- Minimap frames are retained by their node-table identity.  The old numeric
-- pool reassigned every following frame when a quest completion removed one
-- visible node, which made a small quest update rebuild a large marker set.
-- Weak keys allow deleted node tables to be collected normally.
pfMap.mpinNodeIndex = setmetatable({}, { __mode = "k" })
pfMap.drawlayer = Minimap
pfMap.unifiedcache = unifiedcache

-- Reverse indexes for O(1) DeleteNode lookups.
-- titleIndex[addon][title][map][coords] = true  — set by AddNode
-- tooltipIndex[title][spawn] = true             — set by AddNode
pfMap.titleIndex = {}
pfMap.tooltipIndex = {}

-- Set of node tables that have been modified since the last UpdateNodes call.
-- Keyed by node table reference so the node table itself stays clean.
-- AddNode/DeleteNode insert here; UpdateNodes reads and clears entries.
pfMap.dirtyNodes = {}

-- Set of map IDs that have at least one dirty node table.
-- Keyed by zone map ID (integer). Allows WORLD_MAP_UPDATE to cheaply check
-- whether the current zone has pending writes without scanning all dirtyNodes.
pfMap.dirtyMaps = {}

pfMap.minimap_indoor = minimap_indoor
pfMap.minimap_zoom = minimap_zoom
pfMap.minimap_sizes = minimap_sizes

pfMap.tooltip = CreateFrame("Frame", "pfMapTooltip", GameTooltip)
pfMap.tooltip:SetScript("OnShow", function()
  local focus = GetMouseFocus()
  -- abort on pfQuest nodes
  if focus and focus.title then
    return
  end
  -- abort on quest timers
  if focus and focus.GetName and strsub((focus:GetName() or ""), 0, 10) == "QuestTimer" then
    return
  end
  -- abort if tooltips are disabled
  if pfQuest_config.showtooltips == "0" then
    return
  end

  local name = getglobal("GameTooltipTextLeft1") and getglobal("GameTooltipTextLeft1"):GetText() or "__NONE__"
  local zone = pfMap:GetMapID(GetCurrentMapContinent(), GetCurrentMapZone())

  -- remove all colors from received tooltip text
  name = string.gsub(name, "|c%x%x%x%x%x%x%x%x", "")
  name = string.gsub(name, "|r", "")

  if pfMap.tooltips[name] and pfMap.tooltips[name] then
    for title, obj in pairs(pfMap.tooltips[name]) do
      if obj[zone] then
        pfMap:ShowTooltip(obj[zone], GameTooltip)
        GameTooltip:Show()
      end
    end
  end
end)

-- dummy function that can be used by extensions
-- to avoid drawing the minimap at some locations
function pfMap:HasMinimap()
  return true
end

function pfMap.tooltip:GetColor(min, max)
  local max = max or 1
  local min = min or max or 1

  local perc = min / max
  local r1, g1, b1, r2, g2, b2
  if perc <= 0.5 then
    perc = perc * 2
    r1, g1, b1 = 1, 0, 0
    r2, g2, b2 = 1, 1, 0
  else
    perc = perc * 2 - 1
    r1, g1, b1 = 1, 1, 0
    r2, g2, b2 = 0, 1, 0
  end
  r = r1 + (r2 - r1) * perc
  g = g1 + (g2 - g1) * perc
  b = b1 + (b2 - b1) * perc

  return r, g, b
end

function pfMap:HexDifficultyColor(level, force)
  -- Quest levels can include a suffix such as "19+". The color helper needs
  -- a number, while callers still retain the original value for display.
  local numericLevel = tonumber(level) or tonumber(string.match(tostring(level or ""), "%d+"))
  if not numericLevel then return "|cffffffff" end

  if force and UnitLevel("player") < numericLevel then
    return "|cffff5555"
  else
    local c = pfQuestCompat.GetDifficultyColor(numericLevel)
    return string.format("|cff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255)
  end
end

function pfMap:ShowTooltip(meta, tooltip)
  local catch = nil
  local catch_obj = nil
  local tooltip = tooltip or GameTooltip

  -- add quest data
  if meta["quest"] then
    -- scan all quest entries for matches
    for qid = 1, GetNumQuestLogEntries() do
      local qtitle, _, _, _, _, complete = compat.GetQuestLogTitle(qid)

      if meta["quest"] == qtitle then
        -- handle active quests
        local objectives = GetNumQuestLeaderBoards(qid)
        catch = true

        local symbol = (complete or objectives == 0) and "|cff555555[|cffffcc00?|cff555555]|r "
          or "|cff555555[|cffffcc00!|cff555555]|r "
        tooltip:AddLine(symbol .. meta["quest"], 1, 1, 0)

        if objectives then
          for i = 1, objectives, 1 do
            local text, type, finished = GetQuestLogLeaderBoard(i, qid)

            if type == "monster" then
              -- kill
              local i, j, monsterName, objNum, objNeeded =
                strfind(text, pfUI.api.SanitizePattern(QUEST_MONSTERS_KILLED))
              if monsterName and meta["spawn"] == monsterName then
                catch_obj = true
                local r, g, b = pfMap.tooltip:GetColor(objNum, objNeeded)
                tooltip:AddLine("|cffaaaaaa- |r" .. monsterName .. ": " .. objNum .. "/" .. objNeeded, r, g, b)
              end
            elseif table.getn(meta["item"]) > 0 and type == "item" and meta["droprate"] then
              -- loot
              local i, j, itemName, objNum, objNeeded = strfind(text, pfUI.api.SanitizePattern(QUEST_OBJECTS_FOUND))

              for mid, item in pairs(meta["item"]) do
                if item == itemName then
                  catch_obj = true
                  local r, g, b = pfMap.tooltip:GetColor(objNum, objNeeded)
                  local dr, dg, db = pfMap.tooltip:GetColor(tonumber(meta["droprate"]), 100)
                  local lootcolor = string.format("%02x%02x%02x", dr * 255, dg * 255, db * 255)
                  tooltip:AddLine(
                    "|cffaaaaaa- |r"
                      .. itemName
                      .. ": "
                      .. objNum
                      .. "/"
                      .. objNeeded
                      .. " |cff555555[|cff"
                      .. lootcolor
                      .. meta["droprate"]
                      .. "%|cff555555]",
                    r,
                    g,
                    b
                  )
                end
              end
            elseif table.getn(meta["item"]) > 0 and type == "item" and meta["sellcount"] then
              -- vendor
              local i, j, itemName, objNum, objNeeded = strfind(text, pfUI.api.SanitizePattern(QUEST_OBJECTS_FOUND))

              for mid, item in pairs(meta["item"]) do
                if item == itemName then
                  catch_obj = true
                  local r, g, b = pfMap.tooltip:GetColor(objNum, objNeeded)
                  local sellcount = tonumber(meta["sellcount"]) > 0
                      and " |cff555555[|cffcccccc" .. meta["sellcount"] .. "x" .. "|cff555555]"
                    or ""
                  tooltip:AddLine(
                    "|cffaaaaaa- |r"
                      .. pfQuest_Loc["Buy"]
                      .. ": "
                      .. itemName
                      .. ": "
                      .. objNum
                      .. "/"
                      .. objNeeded
                      .. sellcount,
                    r,
                    g,
                    b
                  )
                end
              end
            end
          end
        end
      end
    end

    if not catch then
      tooltip:AddLine("|cff555555[|cffffcc00!|cff555555]|r " .. meta["quest"], 1, 1, 0.7)
    end

    if not catch_obj then
      -- handle inactive quests
      local catchFallback = nil

      if meta["item"] and meta["item"][1] and meta["droprate"] then
        for mid, item in pairs(meta["item"]) do
          catchFallback = true
          local dr, dg, db = pfMap.tooltip:GetColor(tonumber(meta["droprate"]), 100)
          local lootcolor = string.format("%02x%02x%02x", dr * 255, dg * 255, db * 255)
          tooltip:AddLine(
            "|cffaaaaaa- |r" .. item .. " |cff555555[|cff" .. lootcolor .. meta["droprate"] .. "%|cff555555]",
            0.7,
            0.7,
            0.7
          )
        end
      end

      if meta["item"] and meta["item"][1] and meta["sellcount"] then
        for mid, item in pairs(meta["item"]) do
          catchFallback = true
          local sellcount = tonumber(meta["sellcount"]) > 0
              and " |cff555555[|cffcccccc" .. meta["sellcount"] .. "x" .. "|cff555555]"
            or ""
          tooltip:AddLine("|cffaaaaaa- |r" .. pfQuest_Loc["Buy"] .. ": " .. item .. sellcount, 0.7, 0.7, 0.7)
        end
      end

      if not catchFallback and meta["spawn"] and not meta["texture"] then
        catchFallback = true
        tooltip:AddLine(
          "|cffaaaaaa- |r"
            .. (meta["spawntype"] and meta["spawntype"] == "Trigger" and pfQuest_Loc["Explore"] or meta["spawn"]),
          0.7,
          0.7,
          0.7
        )
      end

      if not catchFallback and meta["texture"] and meta["qlvl"] then
        local texts = meta["questid"] and pfDB["quests"]["loc"][meta["questid"]] or nil

        if texts and texts["O"] and texts["O"] ~= "" then
          tooltip:AddLine(pfDatabase:FormatQuestText(texts["O"]), 1, 1, 0.9, true)
        end

        local qlvlstr = pfQuest_Loc["Level"] .. ": " .. pfMap:HexDifficultyColor(meta["qlvl"]) .. meta["qlvl"] .. "|r"
        local qminstr = meta["qmin"]
            and " / " .. pfQuest_Loc["Required"] .. ": " .. pfMap:HexDifficultyColor(meta["qmin"], true) .. meta["qmin"] .. "|r"
          or ""
        tooltip:AddLine("|cffaaaaaa- |r" .. qlvlstr .. qminstr, 0.8, 0.8, 0.8)
      end
    end
  else
    -- handle non-quest objects
    if meta["item"][1] and meta["itemid"] and not meta["itemlink"] then
      local _, _, itemQuality = GetItemInfo(meta["itemid"])
      if itemQuality then
        local itemColor = "|c"
          .. string.format(
            "%02x%02x%02x%02x",
            255,
            ITEM_QUALITY_COLORS[itemQuality].r * 255,
            ITEM_QUALITY_COLORS[itemQuality].g * 255,
            ITEM_QUALITY_COLORS[itemQuality].b * 255
          )

        meta["itemlink"] = itemColor .. "|Hitem:" .. meta["itemid"] .. ":0:0:0|h[" .. meta["item"][1] .. "]|h|r"
      end
    end

    if meta["sellcount"] then
      local item = meta["itemlink"] or "[" .. meta["item"][1] .. "]"
      local sellcount = tonumber(meta["sellcount"]) > 0
          and " |cff555555[|cffcccccc" .. meta["sellcount"] .. "x" .. "|cff555555]"
        or ""
      tooltip:AddLine(pfQuest_Loc["Vendor"] .. ": " .. item .. sellcount, 1, 1, 1)
    elseif meta["item"][1] then
      local item = meta["itemlink"] or "[" .. meta["item"][1] .. "]"
      local r, g, b = pfMap.tooltip:GetColor(tonumber(meta["droprate"]), 100)
      tooltip:AddLine(
        "|cffffffff" .. pfQuest_Loc["Loot"] .. ": " .. item .. " |cff555555[|r" .. meta["droprate"] .. "%|cff555555]",
        r,
        g,
        b
      )
    end
  end

  tooltip:Show()
end

function pfMap:GetMapNameByID(id)
  id = tonumber(id)
  return pfDB["zones"]["loc"][id] or nil
end

function pfMap:GetMapIDByName(search)
  for id, name in pairs(pfDB["zones"]["loc"]) do
    if name == search then
      return id
    end
  end
end

function pfMap:ShowMapID(map)
  if map then
    if ToggleWorldMap then
      -- vanilla & tbc
      if not WorldMapFrame:IsShown() then
        ToggleWorldMap()
      end
    else
      -- wotlk
      WorldMapFrame:Show()
    end

    pfMap:SetMapByID(map)
    pfMap:UpdateNodes()
    return true
  end

  return nil
end

function pfMap:SetMapByID(id)
  local search = pfDB["zones"]["loc"][id]

  for cid, cname in pairs({ GetMapContinents() }) do
    for mid, mname in pairs({ GetMapZones(cid) }) do
      if mname == search then
        SetMapZoom(cid, mid)
        return
      end
    end
  end
end

local customids = {
  ["AlteracValley"] = 2597,
}

local map_zone_cache = {}
function pfMap:GetMapID(cid, mid)
  cid = cid or GetCurrentMapContinent()
  mid = mid or GetCurrentMapZone()

  -- Capital maps are not listed by GetMapZones in the 1.12 client. Prefer
  -- ClassicAPI's direct area ID when available, then use the database name as
  -- a clean-client fallback.
  local apiMapID = pfQuestCompat.GetCurrentMapAreaID and pfQuestCompat.GetCurrentMapAreaID()
  if apiMapID then return apiMapID end

  -- GetMapZones() should always return the same amount
  -- of zones for each continent, so we can cache it to
  -- avoid further creations of the same table.
  if not map_zone_cache[cid] then
    map_zone_cache[cid] = { GetMapZones(cid) }
  end

  local list = map_zone_cache[cid]
  local name = list[mid]
  local id = pfMap:GetMapIDByName(name)
  id = id or pfMap:GetMapIDByName(GetMapInfo())
  id = id or customids[GetMapInfo()]

  return id
end

function pfMap:AddNode(meta)
  if not meta then
    return
  end
  if not meta["zone"] then
    return
  end
  if not meta["title"] then
    return
  end

  -- only compute description if the caller hasn't already done it
  -- (SearchMobID / SearchObjectID hoist this call outside their coord loops)
  if meta["description"] == nil then
    meta["description"] = pfDatabase:BuildQuestDescription(meta)
  end

  local addon = meta["addon"] or "PFDB"
  local map = meta["zone"]
  local coords = meta["x"] .. "|" .. meta["y"]
  local title = meta["title"]
  local layer = GetLayerByTexture(meta["texture"])
  local spawn = meta["spawn"]
  local item = meta["item"]

  local sindex = string.format(
    "%s:%s:%s:%s:%s:%s",
    (addon or ""),
    (map or ""),
    (coords or ""),
    (title or ""),
    (layer or ""),
    (spawn or ""),
    (item or "")
  )

  -- use prioritized clusters
  if layer >= 9 and meta["priority"] then
    layer = layer + (10 - min(meta["priority"], 10))
  end

  if not pfMap.nodes[addon] then
    pfMap.nodes[addon] = {}
  end
  if not pfMap.nodes[addon][map] then
    pfMap.nodes[addon][map] = {}
  end
  if not pfMap.nodes[addon][map][coords] then
    pfMap.nodes[addon][map][coords] = {}
  end

  -- skip early on existing nodes
  if pfMap.nodes[addon][map][coords][title] then
    if item and table.getn(pfMap.nodes[addon][map][coords][title].item) > 0 then
      -- check if item already exists
      for id, name in pairs(pfMap.nodes[addon][map][coords][title].item) do
        if name == item then
          -- Several creatures can share the exact same spawn coordinate and
          -- quest-item node (for example Tunnel Rat Vermin and Scout). Keep
          -- a tooltip alias for every matching creature even though the map
          -- pin itself is intentionally merged into one node.
          if spawn and title then
            local existing = pfMap.nodes[addon][map][coords][title]
            existing.sharedspawns = existing.sharedspawns or { [existing.spawn] = true }
            existing.sharedspawns[spawn] = true

            pfMap.tooltips[spawn] = pfMap.tooltips[spawn] or {}
            pfMap.tooltips[spawn][title] = pfMap.tooltips[spawn][title] or {}
            pfMap.tooltips[spawn][title][map] = existing

            pfMap.tooltipIndex[title] = pfMap.tooltipIndex[title] or {}
            pfMap.tooltipIndex[title][spawn] = true

            -- The map pin stays visually merged, but its tooltip needs to
            -- refresh so it can list every creature sharing this location.
            pfMap.dirtyNodes[pfMap.nodes[addon][map][coords]] = true
            pfMap.dirtyMaps[map] = true
          end
          return
        end
      end

      -- add new item and exit
      table.insert(pfMap.nodes[addon][map][coords][title].item, item)
      return
    end

    if
      pfMap.nodes[addon][map][coords][title]
      and pfMap.nodes[addon][map][coords][title].layer
      and layer
      and pfMap.nodes[addon][map][coords][title].layer >= layer
    then
      -- identical node already exists, exit here
      return
    end
  end

  -- create new combined data node from given meta data
  if not similar_nodes[sindex] then
    similar_nodes[sindex] = {}
    for key, val in pairs(meta) do
      similar_nodes[sindex][key] = val
    end
    similar_nodes[sindex].item = { [1] = item }
  end

  -- set current node to combined node
  pfMap.nodes[addon][map][coords][title] = similar_nodes[sindex]

  -- mark this coord's node table dirty so UpdateNodes knows to reprocess it
  pfMap.dirtyNodes[pfMap.nodes[addon][map][coords]] = true
  pfMap.dirtyMaps[map] = true

  -- maintain reverse title index for O(1) DeleteNode
  if not pfMap.titleIndex[addon] then
    pfMap.titleIndex[addon] = {}
  end
  if not pfMap.titleIndex[addon][title] then
    pfMap.titleIndex[addon][title] = {}
  end
  if not pfMap.titleIndex[addon][title][map] then
    pfMap.titleIndex[addon][title][map] = {}
  end
  pfMap.titleIndex[addon][title][map][coords] = true

  -- add node to unified cluster cache
  if not meta["cluster"] and not meta["texture"] then
    local node_index = meta.item or meta.spawn or UNKNOWN
    local x, y = tonumber(meta.x), tonumber(meta.y)

    -- create prerequisite table structure
    unifiedcache[title] = unifiedcache[title] or {}
    unifiedcache[title][map] = unifiedcache[title][map] or {}

    if not unifiedcache[title][map][node_index] then
      -- create new unified node from given meta data
      local unified_meta = {}
      for key, val in pairs(meta) do
        unified_meta[key] = val
      end

      -- save node to unified cache
      unifiedcache[title][map][node_index] = { meta = unified_meta, coords = {} }
    end

    -- append new coords to unified cache unified cache
    table.insert(unifiedcache[title][map][node_index].coords, { x, y })
  end

  -- add to gametooltips
  if spawn and title then
    pfMap.tooltips[spawn] = pfMap.tooltips[spawn] or {}
    pfMap.tooltips[spawn][title] = pfMap.tooltips[spawn][title] or {}
    pfMap.tooltips[spawn][title][map] = pfMap.tooltips[spawn][title][map] or similar_nodes[sindex]

    -- maintain reverse tooltip index for O(1) DeleteNode
    if not pfMap.tooltipIndex[title] then
      pfMap.tooltipIndex[title] = {}
    end
    pfMap.tooltipIndex[title][spawn] = true
  end

  pfMap.queue_update = GetTime()
end

function pfMap:GetNodes(addon, title)
  local nodes = {}

  if title and pfMap.nodes[addon] then
    for map, foo in pairs(pfMap.nodes[addon]) do
      for coords, node in pairs(pfMap.nodes[addon][map]) do
        if pfMap.nodes[addon][map][coords][title] then
          table.insert(nodes, pfMap.nodes[addon][map][coords][title])
        end
      end
    end
  end

  return nodes
end

function pfMap:DeleteNode(addon, title)
  if not addon then
    -- wipe everything
    pfMap.tooltips = {}
    pfMap.nodes = {}
    pfMap.titleIndex = {}
    pfMap.tooltipIndex = {}
    pfMap.dirtyNodes = {}
    pfMap.dirtyMaps = {}
  elseif not title then
    -- wipe all nodes for this addon; clean up both reverse indexes
    if pfMap.titleIndex[addon] then
      for t, maps in pairs(pfMap.titleIndex[addon]) do
        -- clean tooltipIndex entries that belonged to this addon's titles
        local spawns = pfMap.tooltipIndex[t]
        if spawns then
          for spawn in pairs(spawns) do
            if pfMap.tooltips[spawn] then
              pfMap.tooltips[spawn][t] = nil
              if IsEmpty(pfMap.tooltips[spawn]) then
                pfMap.tooltips[spawn] = nil
              end
            end
          end
          pfMap.tooltipIndex[t] = nil
        end
      end
      pfMap.titleIndex[addon] = nil
    end
    pfMap.nodes[addon] = nil
  elseif pfMap.titleIndex[addon] and pfMap.titleIndex[addon][title] then
    -- fast path: use reverse index to find exactly which (map, coords) to clear
    for map, coords_set in pairs(pfMap.titleIndex[addon][title]) do
      if pfMap.nodes[addon] and pfMap.nodes[addon][map] then
        for coords in pairs(coords_set) do
          if pfMap.nodes[addon][map][coords] then
            pfMap.nodes[addon][map][coords][title] = nil
            if IsEmpty(pfMap.nodes[addon][map][coords]) then
              pfMap.nodes[addon][map][coords] = nil
            else
              -- coord survives with remaining titles; reprocess on next UpdateNodes
              pfMap.dirtyNodes[pfMap.nodes[addon][map][coords]] = true
              pfMap.dirtyMaps[map] = true
            end
          end
        end
      end
    end
    pfMap.titleIndex[addon][title] = nil

    -- clean up tooltip entries for this title using the reverse tooltip index
    local spawns = pfMap.tooltipIndex[title]
    if spawns then
      for spawn in pairs(spawns) do
        if pfMap.tooltips[spawn] then
          pfMap.tooltips[spawn][title] = nil
          if IsEmpty(pfMap.tooltips[spawn]) then
            pfMap.tooltips[spawn] = nil
          end
        end
      end
      pfMap.tooltipIndex[title] = nil
    end
  end

  pfMap.queue_update = GetTime()
end

function pfMap:NodeClick()
  if IsShiftKeyDown() then
    if this.questid and this.texture and this.layer < 5 then
      -- mark questnode as done
      pfQuest_history[this.questid] = { time(), UnitLevel("player") }
    end

    if this.node and this.title and this.node[this.title] then
      -- delete node from map
      pfMap:DeleteNode(this.node[this.title].addon, this.title)
    end

    pfQuest.updateQuestGivers = true
  elseif
    this.texture
    and pfQuest.route
    and (
      (pfQuest_config["routecluster"] == "1" and this.layer >= 9)
      or (pfQuest_config["routeender"] == "1" and this.layer == 4)
      or (pfQuest_config["routestarter"] == "1" and this.layer == 1)
      or (pfQuest_config["routestarter"] == "1" and this.layer == 2)
    )
  then
    -- set as arrow target priority
    pfQuest.route.SetTarget((not pfQuest.route.IsTarget(this) and this))
    pfMap.queue_update = GetTime()
  else
    -- switch color
    pfQuest_colors[this.color] = { str2rgb(this.color .. GetTime()) }
    pfMap.queue_update = GetTime()
  end
end

function pfMap:NodeEnter()
  -- wotlk: need to disable blop tooltips first
  if compat.client >= 30300 then
    WorldMapPOIFrame.allowBlobTooltip = false
  end

  local tooltip = this.worldmap and WorldMapTooltip or GameTooltip
  tooltip:SetOwner(this, "ANCHOR_LEFT")
  this.spawn = this.spawn or UNKNOWN
  tooltip:SetText(
    this.spawn .. (pfQuest_config.showids == "1" and " |cffcccccc(" .. this.spawnid .. ")|r" or ""),
    0.3,
    1,
    0.8
  )
  tooltip:AddDoubleLine(pfQuest_Loc["Level"] .. ":", (this.level or UNKNOWN), 0.8, 0.8, 0.8, 1, 1, 1)
  tooltip:AddDoubleLine(pfQuest_Loc["Type"] .. ":", (this.spawntype or UNKNOWN), 0.8, 0.8, 0.8, 1, 1, 1)
  tooltip:AddDoubleLine(pfQuest_Loc["Respawn"] .. ":", (this.respawn or UNKNOWN), 0.8, 0.8, 0.8, 1, 1, 1)

  for title, meta in pairs(this.node) do
    pfMap:ShowTooltip(meta, tooltip)
  end

  -- add tooltip help if setting is enabled
  if pfQuest_config["tooltiphelp"] == "1" then
    local text = pfQuest_Loc["Use <Shift>-Click To Remove Nodes"]

    if this.cluster then
      text = pfQuest_Loc["Hold <Ctrl> To Hide Cluster"]
    elseif tooltip == GameTooltip then
      text = pfQuest_Loc["Hold <Ctrl> To Hide Minimap Nodes"]
    elseif not this.texture then
      text = pfQuest_Loc["Click Node To Change Color"]
    elseif this.questid and this.texture and this.layer < 5 then
      text = pfQuest_Loc["Use <Shift>-Click To Mark Quest As Done"]
    end

    -- update tooltip and sizes
    tooltip:AddLine(text, 0.6, 0.6, 0.6)
    tooltip:Show()
  end

  pfMap.highlight = pfQuest_config["mouseover"] == "1" and this.title
end

function pfMap:NodeLeave()
  -- wotlk: re-enable blop tooltips
  if compat.client >= 30300 then
    WorldMapPOIFrame.allowBlobTooltip = true
  end

  local tooltip = this.worldmap and WorldMapTooltip or GameTooltip
  tooltip:Hide()
  pfMap.highlight = nil
end

function pfMap:BuildNode(name, parent)
  local f = CreateFrame("Button", name, parent)
  f.worldmap = parent == WorldMapButton

  if parent == WorldMapButton then
    f.defalpha = tonumber(pfQuest_config["worldmaptransp"]) or 1
    f.defsize = 14
  else
    f.defalpha = tonumber(pfQuest_config["minimaptransp"]) or 1
    f.defsize = 14
    f.minimap = true
  end

  f:SetWidth(f.defsize)
  f:SetHeight(f.defsize)

  f.Animate = NodeAnimate
  f:SetScript("OnEnter", pfMap.NodeEnter)
  f:SetScript("OnLeave", pfMap.NodeLeave)

  f.tex = f:CreateTexture(nil, "BACKGROUND")
  f.tex:SetAllPoints(f)

  f.pic = f:CreateTexture(nil, "NORMAL")
  f.pic:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
  f.pic:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 1)

  f.hl = f:CreateTexture(nil, "BORDER")
  f.hl:SetTexture(pfQuestConfig.path .. "\\img\\track")
  f.hl:SetPoint("TOPLEFT", f, "TOPLEFT", -5, 5)
  f.hl:SetWidth(12)
  f.hl:SetHeight(12)
  return f
end

pfMap.highlightdb = {}
function pfMap:UpdateNode(frame, node, color, obj, distance)
  -- clear node to title association table
  if pfMap.highlightdb[frame] then
    for k, v in pairs(pfMap.highlightdb[frame]) do
      pfMap.highlightdb[frame][k] = nil
    end
  else
    pfMap.highlightdb[frame] = {}
  end

  -- reset layer
  frame.layer = 0

  for title, tab in pairs(node) do
    pfMap.highlightdb[frame][title] = true

    tab.layer = GetLayerByTexture(tab.texture)

    -- use prioritized clusters
    if tab.cluster and tab.priority then
      tab.layer = tab.layer + (10 - min(tab.priority, 10))
    end

    if tab.spawn and (tab.layer > frame.layer or not frame.spawn) then
      frame.updateTexture = (frame.texture ~= tab.texture)
      frame.updateVertex = (frame.vertex ~= tab.vertex)
      frame.updateColor = (frame.color ~= tab.color)
      frame.updateLayer = (frame.layer ~= tab.layer)

      -- set title and texture to the entry with highest layer
      -- and add core information
      frame.layer = tab.layer
      frame.spawn = tab.spawn
      frame.spawnid = tab.spawnid
      frame.spawntype = tab.spawntype
      frame.respawn = tab.respawn
      frame.level = tab.level
      frame.questid = tab.questid
      frame.texture = tab.texture
      frame.vertex = tab.vertex
      frame.title = title
      frame.func = tab.func
      frame.cluster = tab.cluster
      frame.description = tab.description
      frame.priority = tab.priority
      frame.quest = tab.quest
      frame.qlvl = tab.qlvl
      frame.itemreq = tab.itemreq
      frame.arrow = tab.arrow
      frame.icon = tab.icon
      frame.fade_range = tab.fade_range
      frame.sharedspawns = tab.sharedspawns

      if pfQuest_config["spawncolors"] == "1" then
        frame.color = tab.spawn or tab.title
      else
        frame.color = tab.title
      end
    end
  end

  if (frame.updateTexture or frame.updateVertex or not frame.tex:GetTexture()) and frame.texture then
    frame.tex:SetTexture(frame.texture)
    frame.tex:SetVertexColor(1, 1, 1)
    frame.pic:Hide()

    if frame.updateVertex and frame.vertex then
      local r, g, b = unpack(frame.vertex)
      if r > 0 or g > 0 or b > 0 then
        frame.tex:SetVertexColor(r, g, b, 1)
      end
    end
  end

  if (frame.updateColor or frame.updateTexture or not frame.tex:GetTexture()) and not frame.texture then
    local r, g, b = str2rgb(frame.color)

    if (frame.title and pfQuest.icons[frame.title]) or frame.icon then
      local texture = (frame.title and pfQuest.icons[frame.title]) or frame.icon
      frame.pic:SetTexture(texture)
      frame.pic:Show()

      if obj == "minimap" then
        local halfsize = pfMap.drawlayer:GetWidth() / 2
        local fade_range = frame.fade_range or 8
        local fade_in = halfsize / 100 * (fade_range - 4)
        local fade_out = halfsize / 100 * (fade_range + 4)
        local alpha = ((distance or fade_out) - fade_in) / (fade_out - fade_in)
        alpha = math.max(alpha, 0)
        alpha = math.min(alpha, 1)
        frame.pic:SetAlpha(alpha)
      end
    else
      frame.pic:Hide()
    end

    if obj == "minimap" and pfQuest_config["cutoutminimap"] == "1" then
      frame.tex:SetTexture(TEX_NODECUT)
      frame.tex:SetVertexColor(r, g, b, 1)
    elseif obj ~= "minimap" and pfQuest_config["cutoutworldmap"] == "1" then
      frame.tex:SetTexture(TEX_NODECUT)
      frame.tex:SetVertexColor(r, g, b, 1)
    else
      frame.tex:SetTexture(TEX_NODE)
      frame.tex:SetVertexColor(r, g, b, 1)
    end
  end

  if frame.updateLayer then
    -- City maps such as Ironforge draw their detailed map artwork above the
    -- normal outdoor-map pin layer. Keep world-map pins above that artwork;
    -- minimap pins retain their existing compact layer range.
    frame:SetFrameLevel((obj == "minimap" and 4 or 240) + frame.layer)
  end

  if frame.updateTexture or frame.updateVertex or frame.updateColor or frame.updateLayer then
    frame:SetScript("OnClick", (frame.func or pfMap.NodeClick))
  end

  local highlight = frame.texture and pfMap.highlightdb[frame][pfMap.highlight] and true or nil
  local target = frame.texture and pfQuest.route and pfQuest.route.IsTarget(frame) or nil

  -- set default sizes for different node types
  frame.defsize = (frame.cluster or frame.layer == 4) and 18 or 14

  -- make the current route target visible
  if target then
    frame.hl:Show()
  else
    frame.hl:Hide()
  end

  -- reset frame size except for highlights
  if not highlight then
    frame:SetWidth(frame.defsize)
    frame:SetHeight(frame.defsize)
  end

  frame.node = node
end

local function GetExploredBounds(mapid)
  -- ClassicAPI reads fog data for any zone by ID. This makes the unexplored
  -- filter immediately accurate on continent maps without calling SetMapZoom
  -- or disturbing the map a player is viewing.
  local apiOverlays = pfQuestCompat.GetExploredMapTextures and pfQuestCompat.GetExploredMapTextures(mapid)
  if apiOverlays then
    -- Capitals and a few special maps have no exploration-overlay geometry at
    -- all. They are fully readable map art, not an unexplored blank area, so
    -- leave their quest pins alone.
    local allOverlays = C_Map and type(C_Map.GetMapOverlays) == "function"
      and C_Map.GetMapOverlays(mapid)
    if type(allOverlays) ~= "table" then return nil end
    if type(allOverlays) == "table" and table.getn(allOverlays) == 0 then return nil, true end

    -- Overlay rectangles use the fixed 1002x668 World Map canvas, rather
    -- than C_Map.GetMapWorldSize's yard coordinates.
    local bounds = {}
    for _, overlay in ipairs(apiOverlays) do
      -- The art rectangle often contains transparent padding. ClassicAPI's
      -- hit rect follows the actual clickable landmass and avoids allowing
      -- pins at the loose edges of an otherwise explored overlay.
      if overlay.hitRectLeft and overlay.hitRectRight and overlay.hitRectTop and overlay.hitRectBottom then
        table.insert(bounds, {
          left = overlay.hitRectLeft / 1002 * 100,
          right = overlay.hitRectRight / 1002 * 100,
          top = overlay.hitRectTop / 668 * 100,
          bottom = overlay.hitRectBottom / 668 * 100,
        })
      else
        local width, height = overlay.textureWidth, overlay.textureHeight
        local offsetX, offsetY = overlay.offsetX, overlay.offsetY
        if width and height and offsetX and offsetY then
          table.insert(bounds, {
            left = offsetX / 1002 * 100,
            right = (offsetX + width) / 1002 * 100,
            top = offsetY / 668 * 100,
            bottom = (offsetY + height) / 668 * 100,
          })
        end
      end
    end
    return bounds, true
  end

  if not GetNumMapOverlays or not GetMapOverlayInfo or not GetMapInfo then return nil end

  local _, mapHeight, mapWidth = GetMapInfo()
  if not mapWidth or not mapHeight or mapWidth == 0 or mapHeight == 0 then return nil end

  local bounds = {}
  for index = 1, GetNumMapOverlays() do
    local texture, width, height, offsetX, offsetY = GetMapOverlayInfo(index)
    if texture and texture ~= "" and width and height and offsetX and offsetY then
      table.insert(bounds, {
        left = offsetX / mapWidth * 100,
        right = (offsetX + width) / mapWidth * 100,
        top = offsetY / mapHeight * 100,
        bottom = (offsetY + height) / mapHeight * 100,
      })
    end
  end
  -- Vanilla can report zero overlays while a map is still initializing. An
  -- empty result is not evidence that every coordinate is unexplored; keep
  -- pins visible until it supplies actual explored rectangles.
  if table.getn(bounds) == 0 then return nil end
  return bounds
end

-- pfQuest-turtle uses this for projected continent pins. Its callers only use
-- the direct form when ClassicAPI advertises map-exploration support.
pfMap.GetExploredBounds = GetExploredBounds

local function IsExploredPosition(bounds, x, y)
  if not bounds then return true end
  for _, area in pairs(bounds) do
    if x >= area.left and x <= area.right and y >= area.top and y <= area.bottom then
      return true
    end
  end
  return false
end

-- The Turtle database extension also draws projected continent pins. Keep the
-- most recently known exploration overlays by source zone so it can apply the
-- same visibility rule there without changing the map the player is viewing.
-- Persist discoveries made during ordinary map browsing. We never switch maps
-- ourselves: each zone enters this cache only after the player has opened it.
pfQuest_config.exploredareas = pfQuest_config.exploredareas or {}
pfMap.exploredAreas = pfQuest_config.exploredareas
-- Older builds could save an empty table when vanilla had not populated map
-- overlays yet. That means "unknown", never "nothing explored"; remove such
-- stale records once so they cannot keep hiding an entire zone after upgrade.
for mapID, bounds in pairs(pfMap.exploredAreas) do
  if type(bounds) ~= "table" or not next(bounds) then
    pfMap.exploredAreas[mapID] = nil
  end
end
pfQuest_config.visitedmaps = pfQuest_config.visitedmaps or {}
pfMap.visitedMaps = pfQuest_config.visitedmaps
pfMap.IsExploredPosition = IsExploredPosition

-- Capital maps do not have meaningful regional fog for quest filtering. Some
-- clients still expose decorative overlay rows for them, so use the character
-- visit record rather than interpreting those rows as unexplored terrain.
local cityMaps = {
  [1497] = true, -- Undercity
  [1519] = true, -- Stormwind City
  [1537] = true, -- Ironforge
  [1637] = true, -- Orgrimmar
  [1638] = true, -- Thunder Bluff
  [1657] = true, -- Darnassus
}

function pfMap:IsMapVisited(mapID)
  return mapID and self.visitedMaps[mapID] and true or false
end

function pfMap:MarkMapVisited(mapID)
  if mapID then self.visitedMaps[mapID] = true end
end

function pfMap:IsVisitedCityPosition(mapID, x, y)
  for cityMapID in pairs(cityMaps) do
    if self:IsMapVisited(cityMapID) then
      local left, right, top, bottom = pfQuestCompat.GetMapRectOnMap
        and pfQuestCompat.GetMapRectOnMap(cityMapID, mapID)
      if left and right and top and bottom
        and x >= left * 100 and x <= right * 100
        and y >= top * 100 and y <= bottom * 100 then
        return true
      end
    end
  end
  return false
end

function pfMap:GetPlayerMapID()
  -- SetMapToCurrentZone resolves capitals (for example Orgrimmar) correctly,
  -- while GetRealZoneText can report their surrounding outdoor zone (Durotar).
  -- Prefer the ID captured on the player's actual zone-change event so Current
  -- Zone Only follows the same map the client uses for the character.
  if pfMap.playerMapID then
    return pfMap.playerMapID
  end

  -- Fallback for the short period before the first zone-change event fires.
  return GetRealZoneText and pfMap:GetMapIDByName(GetRealZoneText()) or nil
end

function pfMap:CacheCurrentExploration(mapID)
  local bounds = GetExploredBounds(mapID)
  if mapID and bounds then
    self.exploredAreas[mapID] = bounds
  end
end

function pfMap:UpdateNodes()
  pfQuest:Debug("Update Nodes")

  local color = pfQuest_config["spawncolors"] == "1" and "spawn" or "title"
  local map = pfMap:GetMapID(GetCurrentMapContinent(), GetCurrentMapZone())
  local i = 1

  -- reset tracker
  pfQuest.tracker.Reset()

  -- Continent and world views do not resolve to a zone map ID. Extensions can
  -- render their own pins there, but the core zone-node renderer must not use
  -- nil as a dirty-map key.
  if not map then
    pfQuest.route:Clear()
    pfMap.lastRouteMap = nil
    for _, pin in pairs(pfMap.pins) do
      pin:Hide()
    end
    pfMap.lastUpdateZone = nil
    pfMap.mapJustOpened = nil
    if pfQuest.tracker and pfQuest.tracker.DoLayout then
      pfQuest.tracker.DoLayout()
    end
    return
  end

  -- Current Zone Only follows the player's zone, not a different zone selected
  -- while browsing the World Map.
  if tonumber(pfQuest_config["trackingmethod"]) == 5 and pfMap:GetPlayerMapID() and map ~= pfMap:GetPlayerMapID() then
    pfQuest.route:Clear()
    for _, pin in pairs(pfMap.pins) do pin:Hide() end
    if pfQuest.tracker and pfQuest.tracker.DoLayout then pfQuest.tracker.DoLayout() end
    return
  end

  local exploredBounds, explorationHandled = GetExploredBounds(map)
  if cityMaps[map] then
    if pfMap:IsMapVisited(map) then
      exploredBounds, explorationHandled = nil, nil
    else
      exploredBounds, explorationHandled = {}, true
    end
  end
  if exploredBounds then
    pfMap:CacheCurrentExploration(map)
  end

  -- Some item/object quests resolve to this zone but do not leave a rendered
  -- spawn pin in every map refresh. Preserve their confirmed, map-scoped
  -- tracker entry in Current Zone Only mode. Entries vanish as soon as the
  -- quest is no longer active.
  if tonumber(pfQuest_config["trackingmethod"]) == 5 and pfMap.currentZoneTracker and pfMap.currentZoneTracker[map] then
    for questid, title in pairs(pfMap.currentZoneTracker[map]) do
      local quest = pfQuest.questlog and pfQuest.questlog[questid]
      if quest then
        -- The Current Zone fallback can be added before the real ender pin.
        -- Use the quest-log state here so simple report/talk turn-ins do not
        -- leave the tracker with the fallback's unfinished grey question mark.
        local _, _, _, _, _, complete = compat.GetQuestLogTitle(quest.qlogid)
        local objectives = GetNumQuestLeaderBoards(quest.qlogid)
        local texture = (complete or not objectives or objectives == 0)
          and pfQuestConfig.path .. "\\img\\complete_c"
          or pfQuestConfig.path .. "\\img\\complete"
        pfQuest.tracker.ButtonAdd(title, {
          dummy = true,
          addon = "PFQUEST",
          questid = questid,
          texture = texture,
        })
      else
        pfMap.currentZoneTracker[map][questid] = nil
      end
    end
  end

  -- A tracker/UI refresh can call UpdateNodes without changing any map node.
  -- Keep the existing route in that case; resetting it redraws the path every
  -- couple of seconds even though its inputs are unchanged.
  if pfMap.lastRouteMap ~= map or pfMap.dirtyMaps[map] then
    pfQuest.route:Reset()
    pfMap.lastRouteMap = map
  end

  -- refresh all nodes
  local n_pins, n_skipped = 0, 0
  -- hoist map dimensions: same for every pin this call, and if the map
  -- is resized between calls the new values will invalidate cached px/py.
  local mapW = WorldMapButton:GetWidth()
  local mapH = WorldMapButton:GetHeight()
  -- The enhanced client renders certain capital-city maps on DetailFrame and
  -- hides WorldMapButton. Pins parented to the hidden button still receive
  -- valid coordinates but can never be drawn. Use the visible detail surface
  -- in that case, then return to WorldMapButton for ordinary outdoor maps.
  local mapParent = WorldMapButton
  if not WorldMapButton:IsVisible() and WorldMapDetailFrame and WorldMapDetailFrame:IsVisible() then
    mapParent = WorldMapDetailFrame
  end
  for addon, _ in pairs(pfMap.nodes) do
    if pfMap.nodes[addon][map] then
      for coords, node in pairs(pfMap.nodes[addon][map]) do
        if not pfMap.pins[i] then
          pfMap.pins[i] = pfMap:BuildNode("pfMapPin" .. i, WorldMapButton)
        end
        if pfMap.pins[i]:GetParent() ~= mapParent then
          pfMap.pins[i]:SetParent(mapParent)
          pfMap.pins[i].lastX = nil
          pfMap.pins[i].lastY = nil
        end

        -- skip UpdateNode if this pin is already bound to this exact node table
        -- and nothing has been added/removed from it since the last UpdateNodes call.
        -- pfMap.dirtyNodes[node] is set by AddNode/DeleteNode on any real write.
        -- frame.node ~= node catches coord-slot shifts from insertions/removals.
        if pfMap.pins[i].node ~= node or pfMap.dirtyNodes[node] then
          pfMap:UpdateNode(pfMap.pins[i], node, color)
          pfMap.dirtyNodes[node] = nil
        else
          n_skipped = n_skipped + 1
        end

        -- set position (use cached coord parse to avoid strfind alloc)
        local x, y
        if coord_cache[coords] then
          x, y = coord_cache[coords][1], coord_cache[coords][2]
        else
          local _, _, strx, stry = strfind(coords, "(.*)|(.*)")
          x, y = strx + 0, stry + 0
          coord_cache[coords] = { x, y }
        end

        -- Route eligibility is determined here, but the point is only added
        -- after the final map-visibility checks below. Otherwise the route
        -- can lead to an objective that is hidden by fog or a display filter.
        local routeEligible =
          (pfQuest_config["routecluster"] == "1" and pfMap.pins[i].layer >= 9)
          or (pfQuest_config["routeender"] == "1" and pfMap.pins[i].layer == 4)
          or (pfQuest_config["routestarter"] == "1" and pfMap.pins[i].layer == 1 and pfMap.pins[i].texture)
          or (pfQuest_config["routestarter"] == "1" and pfMap.pins[i].layer == 2)
          or pfMap.pins[i].arrow == true

        -- Populate the tracker even when the matching map pin is hidden by a
        -- display preference. Hidden objective spawns are still active quests
        -- and must remain visible in Current Zone Only mode.
        for title, node in pairs(pfMap.pins[i].node) do
          pfQuest.tracker.ButtonAdd(title, node)
        end

        -- Hide pfQuest pins outside the character's discovered map overlays.
        if addon == "PFQUEST" and pfQuest_config["hideunexplored"] == "1"
          and ((explorationHandled and not exploredBounds and not pfMap:IsMapVisited(map))
            or not IsExploredPosition(exploredBounds, x, y))
          and not pfMap:IsVisitedCityPosition(map, x, y) then
          pfMap.pins[i]:Hide()
        -- hide cluster nodes if set
        elseif pfQuest_config["showcluster"] == "0" and pfMap.pins[i].cluster then
          pfMap.pins[i]:Hide()
        -- hide individual quest spawns
        elseif pfQuest_config["showspawn"] == "0" and addon == "PFQUEST" and not pfMap.pins[i].texture then
          pfMap.pins[i]:Hide()
        else
          local px = x / 100 * mapW
          local py = y / 100 * mapH

          -- skip layout calls when the pin hasn't moved; ClearAllPoints +
          -- SetPoint are the dominant cost in UpdateNodes for large pin counts
          if pfMap.pins[i].lastX ~= px or pfMap.pins[i].lastY ~= py then
            pfMap.pins[i].lastX = px
            pfMap.pins[i].lastY = py
            pfMap.pins[i]:ClearAllPoints()
            pfMap.pins[i]:SetPoint("CENTER", mapParent, "TOPLEFT", px, -py)
          end

          pfMap.pins[i]:Show()
          if routeEligible then
            pfQuest.route:AddPoint({ x, y, pfMap.pins[i] })
          end
        end

        n_pins = n_pins + 1
        i = i + 1
      end
    end
  end
  pfQuest:Debug(format("UpdateNodes pins=%d skipped=%d", n_pins, n_skipped))

  -- hide remaining pins
  for j = i, table.getn(pfMap.pins) do
    if pfMap.pins[j] then
      pfMap.pins[j]:Hide()
      pfMap.pins[j].lastX = nil
      pfMap.pins[j].lastY = nil
    end
  end

  -- Perform tracker layout once after all ButtonAdd calls complete
  if pfQuest.tracker and pfQuest.tracker.DoLayout then
    pfQuest.tracker.DoLayout()
  end

  -- record which zone was rendered so WORLD_MAP_UPDATE can skip no-op opens
  pfMap.lastUpdateZone = map
  pfMap.dirtyMaps[map] = nil
  -- map has fully rendered; subsequent zone changes are deliberate user actions
  pfMap.mapJustOpened = nil
end

function pfMap:UpdateMinimap()
  -- check for disabled minimap nodes
  if pfQuest_config["minimapnodes"] == "0" then
    return
  end

  -- Holding Ctrl over the minimap is an interaction gesture, not a normal map
  -- refresh.  Handle it before the selected refresh mode can defer work for
  -- several hundred milliseconds, then force one redraw on release.
  local hideMinimapNodes = controlkey.pressed and MouseIsOver(pfMap.drawlayer)
  if hideMinimapNodes then
    this.xPlayer = nil
    this.minimapHiddenByCtrl = true
    for _, pin in pairs(pfMap.mpins) do
      pin:Hide()
    end
    return
  elseif this.minimapHiddenByCtrl then
    this.minimapHiddenByCtrl = nil
    this.minimapTick = nil
  end

  -- Smooth preserves the original high-end behavior. The other modes reduce
  -- repeated pin placement in dense areas, especially at wide minimap zoom.
  local mZoom = pfMap.drawlayer:GetZoom()
  local refreshMode = pfQuest_config["minimaprefresh"] or "smooth"
  local interval
  if refreshMode == "performance" then
    interval = WorldMapFrame:IsShown() and 0.6 or (mZoom <= 1 and 0.75 or 0.4)
  elseif refreshMode == "balanced" then
    interval = WorldMapFrame:IsShown() and 0.4 or (mZoom <= 1 and 0.5 or 0.25)
  else
    interval = 0
  end
  if (this.minimapTick or 0) > GetTime() then
    return
  end
  this.minimapTick = GetTime() + interval

  -- The 1.12 API reports the player in the coordinates of whichever World Map
  -- view is currently selected. While a continent map is open that is not the
  -- player's zone, so use the last real-zone position for minimap placement.
  -- It is refreshed continuously whenever the World Map is closed.
  local xPlayer, yPlayer
  if WorldMapFrame:IsShown() then
    xPlayer, yPlayer = pfMap.minimapPlayerX, pfMap.minimapPlayerY
  else
    xPlayer, yPlayer = GetPlayerMapPosition("player")
    if xPlayer and yPlayer and not (xPlayer == 0 and yPlayer == 0) then
      pfMap.minimapPlayerX, pfMap.minimapPlayerY = xPlayer, yPlayer
      -- The World Map changes the active map context, including on the
      -- opposite continent. Retain the player's actual map ID with the
      -- coordinates so minimap nodes continue to use the real zone.
      pfMap.minimapMapID = pfMap.playerMapID
        or pfMap:GetMapIDByName(GetRealZoneText())
    end
  end

  -- hide nodes and skip further processing in dungeons or before a usable
  -- real-zone position has been captured.
  if xPlayer == 0 and yPlayer == 0 then
    for pins, pin in pairs(pfMap.mpins) do
      pin:Hide()
    end
    return
  end
  if not xPlayer or not yPlayer then return end

  xPlayer, yPlayer = xPlayer * 100, yPlayer * 100

  -- force refresh every second even without changed values, otherwise skip
  if this.xPlayer == xPlayer and this.yPlayer == yPlayer and this.mZoom == mZoom then
    if (this.tick or 1) > GetTime() then
      return
    else
      this.tick = GetTime() + 1
    end
  end

  this.xPlayer, this.yPlayer, this.mZoom = xPlayer, yPlayer, mZoom
  local color = pfQuest_config["spawncolors"] == "1" and "spawn" or "title"
  local mapID = WorldMapFrame:IsShown() and pfMap.minimapMapID
    or pfMap:GetMapIDByName(GetRealZoneText())
  local mapZoom = minimap_zoom[minimap_indoor()][mZoom]
  local mapWidth = minimap_sizes[mapID] and minimap_sizes[mapID][1] or 0
  local mapHeight = minimap_sizes[mapID] and minimap_sizes[mapID][2] or 0

  local xScale = mapZoom / mapWidth
  local yScale = mapZoom / mapHeight

  local xDraw = pfMap.drawlayer:GetWidth() / xScale / 100
  local yDraw = pfMap.drawlayer:GetHeight() / yScale / 100

  -- At a zoomed-out minimap scale, ordinary movement often shifts every pin
  -- by less than a screen pixel. Keep the last layout until that shift is
  -- visible (or the next scheduled refresh has elapsed), rather than
  -- re-anchoring a large visible marker set on every polling interval.
  local anchorX, anchorY = xPlayer * xDraw, yPlayer * yDraw
  if this.minimapAnchorX and math.abs(anchorX - this.minimapAnchorX) < 1
    and math.abs(anchorY - this.minimapAnchorY) < 1
    and (this.minimapAnchorAt or 0) + interval > GetTime() then
    return
  end
  this.minimapAnchorX, this.minimapAnchorY = anchorX, anchorY
  this.minimapAnchorAt = GetTime()

  -- Keep marker coordinates in a shared moving layer. Player movement now
  -- moves this one layer instead of ClearAllPoints/SetPoint on every visible
  -- minimap pin, which is vital when a zoomed-out map has many quest spawns.
  local minimapLayer = pfMap.minimapLayer
  if not minimapLayer then
    minimapLayer = CreateFrame("Frame", nil, pfMap.drawlayer)
    minimapLayer:SetFrameStrata(pfMap.drawlayer:GetFrameStrata())
    pfMap.minimapLayer = minimapLayer
  end
  minimapLayer:SetWidth(pfMap.drawlayer:GetWidth())
  minimapLayer:SetHeight(pfMap.drawlayer:GetHeight())
  minimapLayer:ClearAllPoints()
  minimapLayer:SetPoint("CENTER", pfMap.drawlayer, "CENTER", -anchorX, anchorY)

  -- Nodes outside the minimap cannot be seen. Updating their anchors every
  -- time the player moves is especially expensive in dense quest zones, so
  -- cull them before texture or layout work. Keep a small margin for icons
  -- entering from the edge.
  local visibleHalfWidth = pfMap.drawlayer:GetWidth() / 2 + 24
  local visibleHalfHeight = pfMap.drawlayer:GetHeight() / 2 + 24

  -- Mark visible pins for this pass. A separate node-to-pin index prevents a
  -- removal from shifting and rebuilding every later visual pin.
  for _, pin in pairs(pfMap.mpins) do
    pin.minimapUsed = nil
  end
  local freePin = 1

  -- refresh all nodes
  for addon, data in pairs(pfMap.nodes) do
    -- hide minimap nodes in continent view
    if data[mapID] and minimap_sizes[mapID] and pfMap:HasMinimap(mapID) then
      for coords, node in pairs(data[mapID]) do
        local x, y
        if coord_cache[coords] then
          x, y = coord_cache[coords][1], coord_cache[coords][2]
        else
          local _, _, strx, stry = strfind(coords, "(.*)|(.*)")
          x, y = strx + 0, stry + 0
          coord_cache[coords] = { x, y }
        end

        local xPos = (x - xPlayer) * xDraw
        local yPos = (y - yPlayer) * yDraw

        if pfQuestCompat.rotateMinimap then
          -- TODO: this part is broken and does not work yet.
          local sinFacing = sin(pfQuestCompat.GetPlayerFacing())
          local cosFacing = cos(pfQuestCompat.GetPlayerFacing())

          local dx, dy = xPos, -yPos
          xPos = (dx * cosFacing) + (dy * sinFacing)
          yPos = -((-dx * sinFacing) + (dy * cosFacing))
        end

        local isVisible = math.abs(xPos) <= visibleHalfWidth
          and math.abs(yPos) <= visibleHalfHeight

        if not isVisible then
          -- Keep the visible-pin pool compact; remaining old pins are hidden
          -- together after the scan.
        else

        local display = nil
        local distance = sqrt(xPos * xPos + yPos * yPos)

        if pfUI.minimap then
          display = (abs(xPos) + 8 < pfMap.drawlayer:GetWidth() / 2 and abs(yPos) + 8 < pfMap.drawlayer:GetHeight() / 2)
              and true
            or nil
        else
          display = (distance + 8 < pfMap.drawlayer:GetWidth() / 2) and true or nil
        end

        if display then
          local pin = pfMap.mpinNodeIndex[node]
          if not pin or pin.minimapUsed then
            while pfMap.mpins[freePin] and pfMap.mpins[freePin].minimapUsed do
              freePin = freePin + 1
            end
            pin = pfMap.mpins[freePin]
            if not pin then
              pin = pfMap:BuildNode(nodename .. freePin, pfMap.drawlayer)
              pfMap.mpins[freePin] = pin
            elseif pin.node then
              pfMap.mpinNodeIndex[pin.node] = nil
            end
            pfMap.mpinNodeIndex[node] = pin
            -- Force one visual update when this reusable frame changes owner.
            pin.node = nil
            freePin = freePin + 1
          end
          pin.minimapUsed = true

          if pin:GetParent() ~= minimapLayer then
            pin:SetParent(minimapLayer)
            pin.minimapX = nil
            pin.minimapY = nil
          end

          -- skip expensive UpdateNode work (highlightdb rebuild, node iteration,
          -- size calls) when this pin is already showing the correct node and
          -- nothing has been added or removed from it since the last render.
          if pin.node ~= node or pfMap.dirtyNodes[node] then
            pfMap:UpdateNode(pin, node, color, "minimap", distance)
            pfMap.dirtyNodes[node] = nil
          end

          if pin.hl:IsShown() then
            pin.hl:Hide()
          end

          if pfQuest_config["showclustermini"] == "0" and pin.cluster then
            if pin:IsShown() then pin:Hide() end
          elseif pfQuest_config["showspawnmini"] == "0" and addon == "PFQUEST" and not pin.texture then
            if pin:IsShown() then pin:Hide() end
          else
            -- Anchor against absolute map coordinates. The shared layer above
            -- supplies the player-position offset, so walking does not touch
            -- this pin's anchors.
            if pin.minimapX ~= x or pin.minimapY ~= y
              or pin.minimapXDraw ~= xDraw or pin.minimapYDraw ~= yDraw then
              pin.minimapX = x
              pin.minimapY = y
              pin.minimapXDraw = xDraw
              pin.minimapYDraw = yDraw
              pin:ClearAllPoints()
              pin:SetPoint("CENTER", minimapLayer, "CENTER", x * xDraw, -y * yDraw)
            end
            if not pin:IsShown() then
              pin:Show()
            end
          end
        end
        end
      end
    end
  end

  -- hide remaining pins
  for _, pin in pairs(pfMap.mpins) do
    if not pin.minimapUsed and pin:IsShown() then
      pin:Hide()
    end
  end
end

local zone
local function CapturePlayerMapID()
  -- SetMapToCurrentZone gives city maps their own ID. Keep this independent of
  -- the map currently selected by the player in the World Map window.
  if WorldMapFrame:IsShown() then
    -- Do not change a map the player is browsing, but real-zone text remains
    -- safe to read and lets us retain capital visits made with the map open.
    if GetRealZoneText then
      pfMap:MarkMapVisited(pfMap:GetMapIDByName(GetRealZoneText()))
    end
    return
  end

  -- MINIMAP_ZONE_CHANGED also fires while moving between named subareas in a
  -- city. If the real map has not changed, calling SetMapToCurrentZone again
  -- creates a WORLD_MAP_UPDATE burst and rebuilds the map for no benefit.
  -- Keep the existing map ID in that common movement path.
  local realMapID = GetRealZoneText and pfMap:GetMapIDByName(GetRealZoneText())
  if realMapID and pfMap.playerMapID == realMapID then
    pfMap:MarkMapVisited(realMapID)
    return
  end

  SetMapToCurrentZone()
  pfMap.playerMapID = pfMap:GetMapID(GetCurrentMapContinent(), GetCurrentMapZone())
    or (GetRealZoneText and pfMap:GetMapIDByName(GetRealZoneText()))
  pfMap:MarkMapVisited(pfMap.playerMapID)
  -- Some clients draw a capital as its surrounding zone map, but still report
  -- the capital's real zone text. Preserve that city visit as well.
  if GetRealZoneText then
    pfMap:MarkMapVisited(pfMap:GetMapIDByName(GetRealZoneText()))
  end
end

pfMap:RegisterEvent("PLAYER_LOGIN")
pfMap:RegisterEvent("ZONE_CHANGED")
pfMap:RegisterEvent("ZONE_CHANGED_NEW_AREA")
pfMap:RegisterEvent("MINIMAP_ZONE_CHANGED")
pfMap:RegisterEvent("WORLD_MAP_UPDATE")
pfMap:SetScript("OnEvent", function()
  -- Darnassus and other dense cities can emit MINIMAP_ZONE_CHANGED repeatedly
  -- while the player moves. Once the real map is known, do not even query map
  -- state for those cosmetic subarea notifications.
  if event == "MINIMAP_ZONE_CHANGED" and pfMap.playerMapID then
    return
  end

  -- save current zone
  zone = GetCurrentMapZone()

  -- set map to current zone when possible
  if event == "PLAYER_LOGIN" or event == "ZONE_CHANGED" or event == "ZONE_CHANGED_NEW_AREA" then
    -- Read the map immediately after SetMapToCurrentZone. This preserves a
    -- capital's own map ID rather than replacing it with its parent zone.
    CapturePlayerMapID()
  elseif event == "MINIMAP_ZONE_CHANGED" and not pfMap.playerMapID then
    -- This event can fire repeatedly while walking through named subareas.
    -- It is only useful before the initial player map has been established;
    -- real zone transitions emit the zone-change events above.
    CapturePlayerMapID()
  end

  -- update nodes on world map changes.
  -- Three distinct cases:
  -- (1) Map just opened (burst of ~100 events while frame renders): use the
  --     debounce to coalesce them into one call once rendering settles.
  -- (2) Zone changed by user (deliberate click): call UpdateNodes immediately.
  -- (3) Continent view (newzone == nil): hide all pins immediately.
  -- (4) Same zone, dirty nodes: stamp debounce.
  if event == "WORLD_MAP_UPDATE" then
    local newzone = pfMap:GetMapID(GetCurrentMapContinent(), GetCurrentMapZone())

    -- Let the selected zone finish drawing before reading its overlay data.
    -- The first WORLD_MAP_UPDATE arrives before 1.12 has populated fog data.
    if newzone and WorldMapFrame:IsShown() then
      pfMap.explorationCacheMap = newzone
      pfMap.explorationCacheAt = GetTime() + 0.35
    end

    if newzone == nil then
      -- continent view: hide all worldmap pins immediately
      for j = 1, table.getn(pfMap.pins) do
        if pfMap.pins[j] then
          pfMap.pins[j]:Hide()
        end
      end
      pfMap.lastUpdateZone = nil
    elseif pfMap.mapJustOpened then
      -- Map opens and map selections emit a short event burst. Render after
      -- the normal settle period. Even enhanced clients emit a burst while
      -- the map view changes. Ordinary
      -- filter and quest-data updates retain the full debounce below.
      pfMap.queue_update = GetTime()
    elseif newzone ~= pfMap.lastUpdateZone then
      -- deliberate zone change: update immediately, no debounce
      pfMap.queue_update = nil
      pfMap:UpdateNodes()
    elseif pfMap.dirtyMaps[newzone] then
      -- same zone, pending writes: coalesce via debounce
      pfMap.queue_update = GetTime()
    end
  end
end)

local hlstate, shiftstate, transition, hidecluster, fps, resetmap
pfMap:SetScript("OnUpdate", function()
  -- handle highlights and animations
  if pfMap.queue_update or transition or pfMap.highlight ~= hlstate or shiftstate ~= hidecluster then
    hlstate, shiftstate, transition = pfMap.highlight, hidecluster, nil
    fps = math.max(0.2, GetFramerate() / 30)

    for frame, data in pairs(pfMap.highlightdb) do
      local highlight = pfMap.highlightdb[frame][pfMap.highlight] and true or nil

      if hidecluster and frame.cluster then
        -- hide clusters
        transition = frame:Animate(frame.defsize, 0, fps) or transition
      elseif highlight then
        -- zoom node
        transition = frame:Animate((frame.texture and frame.defsize + 4 or frame.defsize), 1, fps) or transition
      elseif not highlight and pfMap.highlight then
        -- fade node
        transition = frame:Animate(frame.defsize, tonumber(pfQuest_config["nodefade"]) or 0.3, fps) or transition
      elseif frame.texture or frame.cluster then
        -- defaults for textured nodes
        transition = frame:Animate(frame.defsize, 1, fps) or transition
      else
        -- defaults
        transition = frame:Animate(frame.defsize, frame.defalpha, fps) or transition
      end
    end
  end

  -- limit all map updates to once per .05 seconds
  if (this.throttle or 0.2) > GetTime() then
    return
  else
    this.throttle = GetTime() + 0.05
  end

  -- process node updates if required
  if pfMap.queue_update and pfMap.queue_update + 0.25 < GetTime() then
    -- don't fire while the quest system still has work pending: each queue entry
    -- and SearchQuests/UpdateQuestlog call will push queue_update to a newer time,
    -- so the debounce will settle naturally once the whole batch is done.
    -- This prevents UpdateNodes from firing between queue entries when a prior
    -- queue_update stamp happens to be 0.25s old mid-drain.
    local questBusy = pfQuest and ((pfQuest.queueCount or 0) > 0 or pfQuest.updateQuestGivers or pfQuest.updateQuestLog)
    if not questBusy then
      pfMap.queue_update = nil
      pfMap:UpdateNodes()
    end
  end

  if pfMap.explorationCacheAt and pfMap.explorationCacheAt <= GetTime() then
    local map = pfMap:GetMapID(GetCurrentMapContinent(), GetCurrentMapZone())
    if WorldMapFrame:IsShown() and map == pfMap.explorationCacheMap then
      pfMap:CacheCurrentExploration(map)
      -- Map overlays arrive after the initial WORLD_MAP_UPDATE on many maps.
      -- The first render may therefore have treated every pin as unexplored.
      -- Rebuild once the client has populated its fog data so the display and
      -- saved cache use the same bounds.
      if pfQuest_config["hideunexplored"] == "1" then
        pfMap.queue_update = GetTime()
      end
    end
    pfMap.explorationCacheMap = nil
    pfMap.explorationCacheAt = nil
  end

  -- reset map to current zone once map is closed
  -- also flag the frame as just-opened so the WORLD_MAP_UPDATE handler
  -- knows to use the debounce instead of calling UpdateNodes immediately
  -- (the burst of ~100 events during map-open rendering would otherwise
  -- trigger multiple immediate UpdateNodes calls)
  if WorldMapFrame:IsShown() then
    if not resetmap then
      pfMap.mapJustOpened = true
    end
    resetmap = true
  elseif resetmap == true then
    SetMapToCurrentZone()
    -- Do not call GetPlayerMapID here: it intentionally returns the cached
    -- value first, which would preserve the map the player was browsing.
    -- Read the client map context we just restored instead.
    pfMap.playerMapID = pfMap:GetMapID(GetCurrentMapContinent(), GetCurrentMapZone())
      or (GetRealZoneText and pfMap:GetMapIDByName(GetRealZoneText()))
    pfMap:MarkMapVisited(pfMap.playerMapID)
    resetmap = nil
  end

  -- refresh minimap
  pfMap:UpdateMinimap()

  -- update hidecluster detection
  if controlkey.pressed then
    hidecluster = MouseIsOver(WorldMapFrame)
  else
    hidecluster = nil
  end
end)

-- only hook for 3.3.5
if compat.client >= 30300 then
  -- Initialize a variable to track the previous clicked title
  local previousTitle = nil
  -- Highlight Map Quest Log Selection Nodes
  local pfHookWorldMapQuestFrame_OnMouseUp = WorldMapQuestFrame_OnMouseUp
  WorldMapQuestFrame_OnMouseUp = function(self)
    pfHookWorldMapQuestFrame_OnMouseUp(self)
    WorldMapBlobFrame:Hide()
    WorldMapFrame_ClearQuestPOIs()
    if not IsShiftKeyDown() then
      pfMap.highlight = nil
      local questLogIndex = GetQuestLogSelection()
      local title = GetQuestLogTitle(questLogIndex)

      if title then
        if previousTitle == title then
          -- Reset the highlight if the same title is clicked again
          pfMap.highlight = nil
          previousTitle = nil
        else
          -- Logic for highlighting nodes associated with the clicked quest
          pfMap.highlight = title
          previousTitle = title
          pfMap.queue_update = GetTime()
        end
      end
    end
  end
end
