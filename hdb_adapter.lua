-- Optional HearthDB backend shared by the standard and HDB packages.
-- Standard downloads retain their Lua databases and use them when native
-- support is unavailable; lean HDB bundles supply data through the companion.
local compat = pfQuestCompat
local questIdentityCache = {}
local questIdentityUnresolved = {}
local questIdentityPending = {}
local questIdentityFailed = {}

local function RefreshQuestIdentityUI()
  pfQuest.updateQuestLog = true
  -- HDB identity queries complete asynchronously. The ordinary internal
  -- quest-log refresh updates pins and tracker state but does not redraw the
  -- visible header controls, so schedule the established UI-safe refresh too.
  if QuestLogFrame and QuestLogFrame:IsShown() then
    pfQuest.questLogOpenRefreshAt = GetTime() + 0.01
  end
end

local function Enabled()
  return type(HDB_GetVersion) == "function"
    and type(HDB_OpenAddon) == "function"
    and type(HDB_QueryRawAsync) == "function"
    and type(HDB_ClearPoison) == "function"
    and type(pfQuestHearthDB) == "table"
    and type(pfQuestHearthDB.GetQuestMapPinsAsync) == "function"
end

function pfDatabase:IsHDBEnabled()
  return Enabled()
end

-- The browser consumes this small API instead of knowing which companion is
-- installed. It is intentionally read-only: callers retain their Lua result
-- until the asynchronous native answer arrives.
function pfDatabase:SearchQuestTitlesHDB(query, limit, callback)
  if not Enabled() or type(pfQuestHearthDB.SearchQuestTitlesAsync) ~= "function" then
    return false
  end
  local accepted = pfQuestHearthDB:SearchQuestTitlesAsync(query, limit, function(results, err)
    if callback then callback(results, err) end
  end)
  return accepted and true or false
end

function pfDatabase:SearchEntityTitlesHDB(kind, query, limit, callback)
  if not Enabled() or type(pfQuestHearthDB.SearchEntityTitlesAsync) ~= "function" then return false end
  local accepted = pfQuestHearthDB:SearchEntityTitlesAsync(kind, query, limit, function(results, err)
    if callback then callback(results, err) end
  end)
  return accepted and true or false
end

function pfDatabase:SearchItemTitlesHDB(query, limit, callback)
  if not Enabled() or type(pfQuestHearthDB.SearchItemTitlesAsync) ~= "function" then return false end
  local accepted = pfQuestHearthDB:SearchItemTitlesAsync(query, limit, function(results, err)
    if callback then callback(results, err) end
  end)
  return accepted and true or false
end

function pfDatabase:SearchItemTitleHDB(title, meta, allowedTypes, callback)
  if not Enabled() or type(pfQuestHearthDB.GetItemIDsByTitleAsync) ~= "function" then return false end
  local accepted = pfQuestHearthDB:GetItemIDsByTitleAsync(title, function(ids, err)
    if err or not ids then
      if callback then callback(nil, err or "HearthDB item lookup failed") end
      return
    end
    local pending, maps = 0, {}
    for _ in pairs(ids) do pending = pending + 1 end
    if pending == 0 then
      if callback then callback(maps) end
      return
    end
    local function finish(itemMaps)
      for zone, count in pairs(itemMaps or {}) do maps[zone] = (maps[zone] or 0) + count end
      pending = pending - 1
      if pending == 0 and callback then callback(maps) end
    end
    for id in pairs(ids) do
      if not pfDatabase:SearchItemIDHDB(id, meta, allowedTypes, finish) then
        finish(pfDatabase:SearchItemID(id, meta, nil, allowedTypes))
      end
    end
  end)
  return accepted and true or false
end

function pfDatabase:GetQuestTextHDB(id, callback)
  if not Enabled() or type(pfQuestHearthDB.GetQuestTextAsync) ~= "function" then
    return false
  end
  local accepted = pfQuestHearthDB:GetQuestTextAsync(id, function(record, err)
    if callback then callback(record, err) end
  end)
  return accepted and true or false
end

-- The static Lua quest table is intentionally incomplete in HDB installs.
-- Resolve the Show-button destination from the provider's direct start/end
-- hub query instead, preserving the established end-before-start behavior.
function pfDatabase:GetQuestHubMapHDB(id, callback)
  if not Enabled() or type(pfQuestHearthDB.GetQuestHubMapAsync) ~= "function" then
    return false
  end
  local accepted = pfQuestHearthDB:GetQuestHubMapAsync(id, callback)
  return accepted and true or false
end

function pfDatabase:GetQuestTitleByIDHDB(id)
  if not Enabled() or type(pfQuestHearthDB.GetCachedQuestTitleByID) ~= "function" then
    return nil, false, false
  end
  local active = pfQuest and pfQuest.hdbActiveQuestCache and pfQuest.hdbActiveQuestCache[tonumber(id)]
  if active and active.title then return active.title, true, true end
  local title, ready = pfQuestHearthDB:GetCachedQuestTitleByID(id)
  return title, ready, true
end

local function NormalizeQuestIdentityText(value)
  value = tostring(value or "")
  value = string.gsub(value, "|c%x%x%x%x%x%x%x%x", " ")
  value = string.gsub(value, "|r", " ")
  value = string.gsub(value, "%s+", " ")
  value = string.gsub(value, "^%s+", "")
  value = string.gsub(value, "%s+$", "")
  return string.lower(value)
end

local function CaptureQuestIdentityText(qlogid, preserveSelection)
  local description, objective = "", ""
  local oldID = compat.GetQuestLogSelection()
  -- Reading the row that is already selected is side-effect free. This is the
  -- normal quest-log UI path and provides the text needed to identify
  -- same-title quests without collapsing or expanding any headers.
  if oldID == qlogid then
    description, objective = compat.GetQuestLogQuestText()
  elseif not preserveSelection then
    compat.SelectQuestLogEntry(qlogid)
    description, objective = compat.GetQuestLogQuestText()
    compat.SelectQuestLogEntry(oldID)
  end
  local targets = {}
  for index = 1, (GetNumQuestLeaderBoards(qlogid) or 0) do
    local text, kind = compat.GetQuestLogLeaderBoard(index, qlogid)
    local _, _, name = string.find(text or "", "^(.-):")
    if name and kind then targets[string.lower(kind) .. ":" .. NormalizeQuestIdentityText(name)] = true end
  end
  return description or "", objective or "", targets
end

local function FilterQuestCandidates(candidates, predicate)
  local filtered = {}
  for index = 1, table.getn(candidates) do
    if predicate(candidates[index]) then table.insert(filtered, candidates[index]) end
  end
  return filtered
end

local function ObjectiveLabelSet(value)
  local labels = {}
  for label in string.gfind(value or "", "([^|]+)") do
    local normalizedLabel = NormalizeQuestIdentityText(label)
    if normalizedLabel ~= "" then labels[normalizedLabel] = true end
  end
  return labels
end

local function SameNonemptySet(first, second)
  local count = 0
  for key in pairs(first) do
    count = count + 1
    if not second[key] then return false end
  end
  if count == 0 then return false end
  for key in pairs(second) do
    if not first[key] then return false end
  end
  return true
end

local function RequiredPrerequisites(id)
  id = tonumber(id)
  if not id or not pfDB or not pfDB.quests then return nil end
  if pfDB.quests.preall and pfDB.quests.preall[id] then
    return pfDB.quests.preall[id]
  end
  local quest = pfDB.quests["data-turtle"] and pfDB.quests["data-turtle"][id]
    or pfDB.quests["data"] and pfDB.quests["data"][id]
  return type(quest) == "table" and quest.preall or nil
end

local function PrerequisitesSatisfied(value, id)
  local required = RequiredPrerequisites(id)
  if required then
    for _, prerequisite in pairs(required) do
      if not pfQuest_history[tonumber(prerequisite)] then return false end
    end
    return true
  end
  if not value or value == "" then return true end
  for prerequisite in string.gfind(value, "[^,]+") do
    if pfQuest_history[tonumber(prerequisite)] then return true end
  end
  return false
end

local function RestrictionMatches(mask, playerBit)
  local numericMask = tonumber(mask)
  if not numericMask or numericMask == 0 then return true end
  return playerBit and bit.band(numericMask, playerBit) == playerBit
end

-- Resolve only duplicate-title entries here. Unique titles retain the immediate
-- path until the rest of quest-log identity has moved off the Lua database.
-- A nil result with handled=true tells the caller not to run the legacy
-- score-based resolver. Once HDB identifies a duplicate title, failures and
-- ties must remain unresolved rather than selecting an arbitrary candidate.
function pfDatabase:ResolveQuestLogIDHDB(qlogid, title, level, preserveSelection)
  if not Enabled() or type(pfQuestHearthDB.GetQuestDisambiguationAsync) ~= "function"
    or type(pfQuestHearthDB.GetCachedQuestIDsByTitle) ~= "function" then
    return nil, false, false
  end
  local slotKey = tostring(qlogid) .. ":" .. tostring(title) .. ":" .. tostring(level or "")

  -- A visible Quest Log refresh deliberately avoids selecting background rows.
  -- Reuse the numeric identity already attached to this exact active row before
  -- starting an asynchronous duplicate-title lookup with no readable text.
  -- Matching both qlog index and title prevents an unrelated shifted row from
  -- inheriting the old identity after quest acceptance or turn-in.
  if preserveSelection then
    for activeID, state in pairs(pfQuest.questlog or {}) do
      if type(activeID) == "number" and state and state.qlogid == qlogid
          and state.title == title then
        return activeID, false, true
      end
    end
  end

  if questIdentityFailed[slotKey] then return nil, false, true end
  if questIdentityPending[slotKey] then return nil, true, true end
  local candidates, titleIndexReady = pfQuestHearthDB:GetCachedQuestIDsByTitle(title)
  if candidates and table.getn(candidates) == 1 then return candidates[1], false, true end
  if not candidates and not titleIndexReady then
    questIdentityPending[slotKey] = true
    local accepted = pfQuestHearthDB:GetQuestIDsByTitleAsync(title, function(ids, err)
      questIdentityPending[slotKey] = nil
      if err or not ids then questIdentityFailed[slotKey] = true end
      RefreshQuestIdentityUI()
    end)
    if accepted then return nil, true, true end
    questIdentityPending[slotKey] = nil
    return nil, false, true
  end
  if not candidates or table.getn(candidates) < 2 then return nil, false, false end

  local description, objective, liveTargets = CaptureQuestIdentityText(qlogid, preserveSelection)
  local targetKeys = {}
  for label in pairs(liveTargets) do table.insert(targetKeys, label) end
  table.sort(targetKeys)
  local observationKey = slotKey .. ":" .. NormalizeQuestIdentityText(objective)
    .. ":" .. NormalizeQuestIdentityText(description) .. ":" .. table.concat(targetKeys, "|")
  if questIdentityCache[observationKey] then return questIdentityCache[observationKey], false, true end
  if questIdentityUnresolved[observationKey] then return nil, false, true end
  questIdentityPending[slotKey] = true
  local accepted = pfQuestHearthDB:GetQuestDisambiguationAsync(title, function(records, err)
    questIdentityPending[slotKey] = nil
    if err or not records then
      questIdentityFailed[slotKey] = true
      RefreshQuestIdentityUI()
      return
    end
    local resolutionClass = records[1] and records[1].resolutionClass
    -- PARTIAL only means that not every stored row carries a discriminator.
    -- It must still be allowed to resolve when this live row has an exact,
    -- nonempty objective or description match. UNRESOLVABLE has no safe
    -- discriminator, so it remains deliberately unresolved.
    if resolutionClass == "UNRESOLVABLE" then
      questIdentityUnresolved[observationKey] = true
      RefreshQuestIdentityUI()
      return
    end

    local remaining = records
    local liveObjective = NormalizeQuestIdentityText(objective)
    local liveDescription = NormalizeQuestIdentityText(description)

    -- Apply exact nonempty text discriminators in order. Keep a discriminator
    -- only when it matches at least one candidate: a harmless server-side
    -- wording difference must not erase an otherwise unique objective match.
    -- Empty values never compare equal, and zero or tied results never guess.
    if liveObjective ~= "" then
      local objectiveMatches = FilterQuestCandidates(remaining, function(record)
        return record.objective and NormalizeQuestIdentityText(
          pfDatabase:FormatQuestText(record.objective)
        ) == liveObjective
      end)
      if table.getn(objectiveMatches) > 0 then remaining = objectiveMatches end
    end

    if table.getn(remaining) > 1 and liveDescription ~= "" then
      local descriptionMatches = FilterQuestCandidates(remaining, function(record)
        return record.description and NormalizeQuestIdentityText(
          pfDatabase:FormatQuestText(record.description)
        ) == liveDescription
      end)
      if table.getn(descriptionMatches) > 0 then remaining = descriptionMatches end
    end

    -- TEXT_UNIQUE groups are safe only when exact text leaves one candidate.
    if table.getn(remaining) ~= 1 and resolutionClass ~= "TEXT_UNIQUE" then
      if next(liveTargets) then
        remaining = FilterQuestCandidates(remaining, function(record)
          return SameNonemptySet(liveTargets, ObjectiveLabelSet(record.objectiveLabels))
        end)
      end

      if table.getn(remaining) > 1 then
        local eligible = FilterQuestCandidates(remaining, function(record)
          return PrerequisitesSatisfied(record.prerequisites, record.id)
        end)
        if table.getn(eligible) > 0 then remaining = eligible end
      end
    end

    -- STRUCTURAL_UNIQUE groups must be unique before conditional character
    -- restrictions are considered.
    if table.getn(remaining) ~= 1 and resolutionClass == "CONDITIONAL" then
      local _, race = UnitRace("player")
      local _, class = UnitClass("player")
      local raceBit = race and pfDatabase:GetBitByRace(race)
      local classBit = class and pfDatabase:GetBitByClass(class)
      remaining = FilterQuestCandidates(remaining, function(record)
        return RestrictionMatches(record.raceMask, raceBit)
          and RestrictionMatches(record.classMask, classBit)
      end)

      if table.getn(remaining) > 1 and tonumber(level) then
        remaining = FilterQuestCandidates(remaining, function(record)
          return tonumber(record.level) and tonumber(record.level) == tonumber(level)
        end)
      end
    end

    if table.getn(remaining) == 1 and remaining[1].id then
      questIdentityCache[observationKey] = remaining[1].id
    elseif liveObjective ~= "" or liveDescription ~= ""
        or (resolutionClass ~= "TEXT_UNIQUE" and next(liveTargets)) then
      -- Only lock this observation in as unresolved when it carried a signal
      -- that this resolution class can actually consume. TEXT_UNIQUE requires
      -- quest text; an unselected read-only background scan has only targets,
      -- so caching that pass would poison the row until the next reload.
      questIdentityUnresolved[observationKey] = true
    end
    RefreshQuestIdentityUI()
  end)
  if not accepted then
    questIdentityPending[slotKey] = nil
    return nil, false, true
  end
  return nil, true, true
end

function pfDatabase:ShowExtendedTooltipHDB(id, tooltip, parent, anchor, offx, offy, postRender)
  if not Enabled() or type(pfQuestHearthDB.GetQuestMapPinsAsync) ~= "function" then return false end
  local accepted = pfQuestHearthDB:GetQuestMapPinsAsync(id, function(record, err)
    if err or not record or not parent or not MouseIsOver(parent) then return end
    tooltip = tooltip or GameTooltip
    tooltip:SetOwner(parent, anchor or "ANCHOR_LEFT", offx, offy)
    tooltip:ClearLines()
    tooltip:SetText(record.title or UNKNOWN, 0.3, 1, 0.8)
    tooltip:AddLine(" ")

    local queststate = pfQuest_history[id] and 2 or 0
    queststate = pfQuest.questlog[id] and 1 or queststate
    if queststate == 0 then tooltip:AddLine(pfQuest_Loc["You don't have this quest."] .. "\n\n", 1, 0.5, 0.5)
    elseif queststate == 1 then tooltip:AddLine(pfQuest_Loc["You are on this quest."] .. "\n\n", 1, 1, 0.5)
    else tooltip:AddLine(pfQuest_Loc["You already did this quest."] .. "\n\n", 0.5, 1, 0.5) end

    local sources, seen = { start = {}, ["end"] = {} }, { start = {}, ["end"] = {} }
    for index = 1, table.getn(record.pins or {}) do
      local pin = record.pins[index]
      if sources[pin.phase] and pin.title and not seen[pin.phase][pin.title] then
        seen[pin.phase][pin.title] = true
        table.insert(sources[pin.phase], pin.title)
      end
    end
    -- GameTooltip doesn't wrap AddDoubleLine text, so an unbounded name list
    -- (a widely-shared quest giver/turn-in template can have dozens of
    -- distinct titles) renders as one line wider than the screen. Cap what's
    -- actually listed; the tooltip's job is identifying a few names, not
    -- enumerating every possible source.
    local SOURCE_LIST_CAP = 8
    local function FormatSourceList(list)
      local count = table.getn(list)
      if count <= SOURCE_LIST_CAP then return table.concat(list, ", ") end
      local shown = {}
      for i = 1, SOURCE_LIST_CAP do shown[i] = list[i] end
      return table.concat(shown, ", ") .. " (+" .. (count - SOURCE_LIST_CAP) .. " more)"
    end
    if table.getn(sources.start) > 0 then tooltip:AddDoubleLine(pfQuest_Loc["Quest Start"] .. ":", FormatSourceList(sources.start), 1, 1, 1, 1, 1, 0.8) end
    if table.getn(sources["end"]) > 0 then tooltip:AddDoubleLine(pfQuest_Loc["Quest End"] .. ":", FormatSourceList(sources["end"]), 1, 1, 1, 1, 1, 0.8) end
    if record.objective and record.objective ~= "" then tooltip:AddLine(" "); tooltip:AddLine(pfDatabase:FormatQuestText(record.objective), 1, 1, 1, true) end
    if record.description and record.description ~= "" then
      local text = pfDatabase:FormatQuestText(record.description)
      if strlen(text) > 500 then text = strsub(text, 1, 500) .. "..." end
      tooltip:AddLine(" "); tooltip:AddLine(text, 0.6, 0.6, 0.6, true)
    end
    if record.level or record.minLevel then tooltip:AddLine(" ") end
    if record.level then local level = tonumber(record.level); local color = pfQuestCompat.GetDifficultyColor(level); tooltip:AddLine("|cffffffff" .. pfQuest_Loc["Quest Level"] .. ": |r" .. level, color.r, color.g, color.b) end
    if record.minLevel then local level = tonumber(record.minLevel); local color = pfQuestCompat.GetDifficultyColor(level); tooltip:AddLine("|cffffffff" .. pfQuest_Loc["Required Level"] .. ": |r" .. level, color.r, color.g, color.b) end
    if postRender then postRender(tooltip) end
    tooltip:Show()
  end)
  return accepted and true or false
end

function pfDatabase:SearchQuestTitleHDB(title, meta, callback)
  if not Enabled() or type(pfQuestHearthDB.GetQuestIDsByTitleAsync) ~= "function" then return false end
  local accepted = pfQuestHearthDB:GetQuestIDsByTitleAsync(title, function(ids, err)
    if err or not ids then
      if callback then callback(nil, err or "HearthDB quest lookup failed") end
      return
    end
    local pending, maps = table.getn(ids), {}
    if pending == 0 then
      if callback then callback(maps, nil, ids) end
      return
    end
    local function finish(questMaps)
      for zone, count in pairs(questMaps or {}) do maps[zone] = (maps[zone] or 0) + count end
      pending = pending - 1
      if pending == 0 and callback then callback(maps, nil, ids) end
    end
    for index = 1, table.getn(ids) do
      local id = ids[index]
      if not pfDatabase:SearchQuestPreviewHDB(id, meta, finish) then
        finish(pfDatabase:SearchQuestID(id, meta))
      end
    end
  end)
  return accepted and true or false
end

function pfDatabase:GetQuestIDsByTitleHDB(title, callback)
  if not Enabled() or type(pfQuestHearthDB.GetQuestIDsByTitleAsync) ~= "function" then return false end
  local accepted = pfQuestHearthDB:GetQuestIDsByTitleAsync(title, function(ids, err)
    if callback then callback(ids, err) end
  end)
  return accepted and true or false
end

function pfDatabase:GetQuestTextByTitleHDB(title, callback)
  if not Enabled() or type(pfQuestHearthDB.GetQuestTextByTitleAsync) ~= "function" then return false end
  local accepted = pfQuestHearthDB:GetQuestTextByTitleAsync(title, function(record, err)
    if callback then callback(record, err) end
  end)
  return accepted and true or false
end

function pfDatabase:GetItemSourcesHDB(id, callback)
  if not Enabled() or type(pfQuestHearthDB.GetItemSourcesAsync) ~= "function" then return false end
  local accepted = pfQuestHearthDB:GetItemSourcesAsync(id, function(record, err)
    if callback then callback(record, err) end
  end)
  return accepted and true or false
end

function pfDatabase:GetEntityInfoHDB(kind, id, callback)
  if not Enabled() or type(pfQuestHearthDB.GetEntityInfoAsync) ~= "function" then return false end
  local accepted = pfQuestHearthDB:GetEntityInfoAsync(kind, id, function(record, err)
    if callback then callback(record, err) end
  end)
  return accepted and true or false
end

local function RenderEntityHDBRecord(kind, record, meta, maps)
  local id = record.id
  if kind == "U" and record.rank and record.rank ~= "" then
    pfDB.units.data[id] = pfDB.units.data[id] or {}
    pfDB.units.data[id].rnk = record.rank
  end
  local skill, skillCaption
  if kind == "O" then
    skill = record.requiredSkill
    skillCaption = record.profession == "mines" and pfQuest_Loc["Mining"]
      or record.profession == "herbs" and pfQuest_Loc["Herbalism"]
    if not skill then skill, skillCaption = pfDatabase:SearchObjectSkill(id) end
  end
  for index = 1, table.getn(record.spawns or {}) do
    local spawn = record.spawns[index]
    if spawn.zoneID and spawn.x and spawn.y then
      local nodeMeta = {}
      if meta then for key, value in pairs(meta) do nodeMeta[key] = value end end
      nodeMeta.spawn, nodeMeta.spawnid = record.title or UNKNOWN, id
      nodeMeta.title = nodeMeta.quest or nodeMeta.item or nodeMeta.spawn
      nodeMeta.level = skill and string.format("%s [%s]", skill, skillCaption) or record.level or UNKNOWN
      nodeMeta.spawntype = kind == "O" and pfQuest_Loc["Object"] or pfQuest_Loc["Unit"]
      nodeMeta.zone, nodeMeta.x, nodeMeta.y = spawn.zoneID, spawn.x, spawn.y
      nodeMeta.respawn = spawn.respawn and spawn.respawn > 0 and SecondsToTime(spawn.respawn) or nil
      nodeMeta.description = nil
      maps[spawn.zoneID] = maps[spawn.zoneID] and maps[spawn.zoneID] + 1 or 1
      pfMap:AddNode(nodeMeta)
    end
  end
end

function pfDatabase:SearchEntityIDHDB(kind, id, meta, callback)
  if not pfDatabase:GetEntityInfoHDB(kind, id, function(record, err)
    if err or not record then
      local fallback = kind == "U" and pfDatabase:SearchMobID(id, meta) or pfDatabase:SearchObjectID(id, meta)
      pfMap.queue_update = GetTime()
      if callback then callback(fallback) end
      return
    end
    local maps = {}
    RenderEntityHDBRecord(kind, record, meta, maps)
    if not next(maps) then
      local fallback = kind == "U" and pfDatabase:SearchMobID(id, meta) or pfDatabase:SearchObjectID(id, meta)
      pfMap.queue_update = GetTime()
      if callback then callback(fallback) end
      return
    end
    pfMap.queue_update = GetTime()
    if callback then callback(maps) end
  end) then return false end
  return true
end

function pfDatabase:SearchEntityTitleHDB(kind, title, meta, callback)
  if not Enabled() or type(pfQuestHearthDB.GetEntitiesByTitleAsync) ~= "function" then return false end
  local accepted = pfQuestHearthDB:GetEntitiesByTitleAsync(kind, title, function(records, err)
    if err or not records then
      local fallback = kind == "U" and pfDatabase:SearchMob(title, meta) or pfDatabase:SearchObject(title, meta)
      if callback then callback(fallback) end
      return
    end
    local maps = {}
    for index = 1, table.getn(records) do RenderEntityHDBRecord(kind, records[index], meta, maps) end
    if not next(maps) then
      local fallback = kind == "U" and pfDatabase:SearchMob(title, meta) or pfDatabase:SearchObject(title, meta)
      pfMap.queue_update = GetTime()
      if callback then callback(fallback) end
      return
    end
    pfMap.queue_update = GetTime()
    if callback then callback(maps) end
  end)
  return accepted and true or false
end

-- Browser-only quest preview. Active quests retain SearchQuestIDHDB so their
-- pins can apply live objective state; this preview mirrors the static
-- SearchQuestID view for a quest that is not in the player's log.
function pfDatabase:SearchQuestPreviewHDB(id, meta, callback)
  if not Enabled() then return false end
  local accepted = pfQuestHearthDB:GetQuestMapPinsAsync(id, function(record, err)
    if err or not record then
      local fallback = pfDatabase:SearchQuestID(id, meta)
      if callback then callback(fallback) end
      return
    end
    local maps = {}
    for index = 1, table.getn(record.pins or {}) do
      local pin = record.pins[index]
      local render = pin.phase == "obj" or pfQuest_config["currentquestgivers"] == "1"
      local requirement = pin.originKind == "IR" and (pin.itemTitle or pfDB.items.loc[pin.originID])
      if render and (not requirement or (pfDatabase.itemlist and pfDatabase.itemlist.db and pfDatabase.itemlist.db[requirement])) then
        local nodeMeta = {}
        if meta then for key, value in pairs(meta) do nodeMeta[key] = value end end
        nodeMeta.questid, nodeMeta.quest = id, record.title
        nodeMeta.qlvl, nodeMeta.qmin = record.level, record.minLevel
        nodeMeta.title = record.title
        nodeMeta.spawn, nodeMeta.spawnid = pin.title, pin.targetID
        nodeMeta.zone, nodeMeta.x, nodeMeta.y = pin.zoneID, pin.x, pin.y
        nodeMeta.level = pin.level or UNKNOWN
        nodeMeta.respawn = pin.respawn and SecondsToTime(pin.respawn) or nil
        nodeMeta.spawntype = pin.targetKind == "O" and pfQuest_Loc["Object"]
          or (pin.targetKind == "A" and pfQuest_Loc["Trigger"])
          or (pin.targetKind == "Z" and pfQuest_Loc["Area/Zone"])
          or pfQuest_Loc["Unit"]
        if pin.phase == "start" then
          nodeMeta.QTYPE, nodeMeta.texture = pin.targetKind == "O" and "OBJECT_START" or "NPC_START",
            pfQuestConfig.path .. "\\img\\available_c"
        elseif pin.phase == "end" then
          nodeMeta.QTYPE, nodeMeta.texture = pin.targetKind == "O" and "OBJECT_END" or "NPC_END",
            pfQuestConfig.path .. "\\img\\complete_c"
        elseif pin.targetKind == "A" then nodeMeta.QTYPE = "AREATRIGGER_OBJECTIVE"
        elseif pin.targetKind == "Z" then nodeMeta.QTYPE = "ZONE_OBJECTIVE"
        elseif pin.originKind == "I" then
          nodeMeta.QTYPE, nodeMeta.item = "ITEM_OBJECTIVE_LOOT", pin.itemTitle or pfDB.items.loc[pin.originID]
          if pin.sourceKind == "V" then
            nodeMeta.texture = pfQuestConfig.path .. "\\img\\icon_vendor"
            nodeMeta.sellcount = pin.chance
          else
            nodeMeta.droprate = pin.chance
          end
        elseif pin.originKind == "IR" then
          nodeMeta.QTYPE, nodeMeta.itemreq = pin.targetKind == "O" and "OBJECT_OBJECTIVE_ITEMREQ" or "UNIT_OBJECTIVE_ITEMREQ", requirement
        else nodeMeta.QTYPE = pin.targetKind == "O" and "OBJECT_OBJECTIVE" or "UNIT_OBJECTIVE" end
        maps[pin.zoneID] = maps[pin.zoneID] and maps[pin.zoneID] + 1 or 1
        pfMap:AddNode(nodeMeta)
      end
    end
    pfMap.queue_update = GetTime()
    if callback then callback(maps) end
  end)
  return accepted and true or false
end

-- Native equivalent of the browser's standalone item lookup. Active quest
-- item objectives already use GetQuestMapPinsAsync, so this only serves item
-- browser pins and never changes quest-progress rendering.
function pfDatabase:SearchItemIDHDB(id, meta, allowedTypes, callback, ignoreDropChance)
  if not Enabled() or type(pfQuestHearthDB.GetItemSourcesAsync) ~= "function" then return false end
  id = tonumber(id)
  if not id then return false end
  local accepted = pfQuestHearthDB:GetItemSourcesAsync(id, function(record, err)
    if err or not record then
      local fallbackMaps = pfDatabase:SearchItemID(id, meta, nil, allowedTypes)
      pfMap.queue_update = GetTime()
      if callback then callback(fallbackMaps) end
      return
    end
    local minChance = tonumber(pfQuest_config.mindropchance) or 0
    local maps = {}
    for index = 1, table.getn(record.sources or {}) do
      local source = record.sources[index]
      local permitted = not allowedTypes or allowedTypes[source.kind]
      -- Some container sources omit a chance entirely. The Lua database treats
      -- those as valid sources, so native pins must do the same.
      local chanceOK = ignoreDropChance or source.kind == "V" or source.chance == nil
        or source.chance == 0 or source.chance >= minChance
      if permitted and chanceOK and source.zoneID and source.x and source.y then
        local nodeMeta = {}
        if meta then for key, value in pairs(meta) do nodeMeta[key] = value end end
        nodeMeta.itemid = id
        nodeMeta.item = record.title
        nodeMeta.title = record.title
        nodeMeta.spawn = source.title or UNKNOWN
        nodeMeta.spawnid = source.id
        nodeMeta.spawntype = source.kind == "O" and pfQuest_Loc["Object"] or pfQuest_Loc["Unit"]
        nodeMeta.level = source.level or UNKNOWN
        nodeMeta.zone = source.zoneID
        nodeMeta.x, nodeMeta.y = source.x, source.y
        nodeMeta.respawn = source.respawn and SecondsToTime(source.respawn) or "N/A"
        nodeMeta.droprate = source.kind == "V" and nil or source.chance
        nodeMeta.sellcount = source.kind == "V" and source.chance or nil
        nodeMeta.texture = source.kind == "V" and pfQuestConfig.path .. "\\img\\icon_vendor" or nil
        nodeMeta.description = nil
        maps[source.zoneID] = maps[source.zoneID] and maps[source.zoneID] + 1 or 1
        pfMap:AddNode(nodeMeta)
      end
    end
    -- A source may exist in HearthDB without a usable world spawn (for
    -- example, an unmapped object template). Keep the browser action useful
    -- by letting the mature Lua lookup supply its pins in that case.
    if not next(maps) then
      local fallbackMaps = pfDatabase:SearchItemID(id, meta, nil, allowedTypes)
      pfMap.queue_update = GetTime()
      if callback then callback(fallbackMaps) end
      return
    end
    pfMap.queue_update = GetTime()
    if callback then callback(maps) end
  end)
  return accepted and true or false
end

local function IsCurrentQuest(id, qlogid)
  local active = pfQuest and pfQuest.questlog and pfQuest.questlog[id]
  return active and active.qlogid == qlogid
end

-- Phase-one backend: retain one compact, normalized HDB snapshot per active
-- quest. The normal pfQuest search and all UI consumers remain unchanged until
-- each of them can read this cache directly.
local activeQuestCache = {}
local function GetActiveQuestCache()
  if pfQuest then
    pfQuest.hdbActiveQuestCache = pfQuest.hdbActiveQuestCache or activeQuestCache
    return pfQuest.hdbActiveQuestCache
  end
  return activeQuestCache
end

local RestoreMissingEnder
local HasActiveNodes
local AddPin

local function IndexPins(pins)
  local targets = { U = {}, O = {}, I = {}, A = {}, Z = {} }
  local spawns = { U = {}, O = {} }
  for index = 1, table.getn(pins or {}) do
    local pin = pins[index]
    local kind = pin.originKind or pin.targetKind
    local id = pin.originID or pin.targetID
    if kind and id then
      targets[kind] = targets[kind] or {}
      targets[kind][id] = true
    end
    if pin.targetKind and pin.targetID then
      spawns[pin.targetKind] = spawns[pin.targetKind] or {}
      spawns[pin.targetKind][pin.targetID] = true
    end
  end
  return targets, spawns
end

function pfDatabase:RefreshQuestHDBState(id, qlogid)
  local record = GetActiveQuestCache()[id]
  if not record or record.qlogid ~= qlogid or not IsCurrentQuest(id, qlogid) then
    return nil
  end
  local states, complete = pfDatabase:GetQuestObjectiveStates(qlogid, record)
  record.states = states
  record.complete = complete
  record.stateUpdatedAt = GetTime()
  return record
end

function pfDatabase:StoreQuestHDBCache(id, qlogid, result)
  local targets, spawns = IndexPins(result.pins)
  local _, liveLevel = compat.GetQuestLogTitle(qlogid)
  local record = {
    id = id,
    qlogid = qlogid,
    title = result.title,
    objective = result.objective,
    description = result.description,
    level = tonumber(liveLevel) or result.level,
    hasObjectives = result.hasObjectives,
    pins = result.pins or {},
    targets = targets,
    spawns = spawns,
    loadedAt = GetTime(),
  }
  GetActiveQuestCache()[id] = record
  pfDatabase:RefreshQuestHDBState(id, qlogid)
  if pfQuest.tracker and pfQuest.tracker.buttons then
    for _, button in pairs(pfQuest.tracker.buttons) do
      if button and button.title == record.title then pfQuest.tracker.ButtonEvent(button) end
    end
  end
  pfMap.queue_update = GetTime()
  return record
end

-- Warms the native result without changing the currently rendered nodes.
function pfDatabase:PrimeQuestHDBCache(id, meta)
  if not Enabled() or not meta or not meta.qlogid then return false end
  local qlogid = meta.qlogid
  if not IsCurrentQuest(id, qlogid) then return false end

  local record = GetActiveQuestCache()[id]
  if record and record.qlogid == qlogid then
    pfDatabase:RefreshQuestHDBState(id, qlogid)
    return true
  end

  local accepted = pfQuestHearthDB:GetQuestMapPinsAsync(id, function(result, err)
    if err or not result or not IsCurrentQuest(id, qlogid) then return end
    record = pfDatabase:StoreQuestHDBCache(id, qlogid, result)
    pfQuest:Debug("HearthDB cached active quest: " .. id .. " (" .. table.getn(record.pins) .. " pins)")
  end)
  return accepted and true or false
end

function pfDatabase:ClearQuestHDBCache(id)
  GetActiveQuestCache()[id] = nil
end

-- Quest Log row numbers are positional and can all shift when one quest is
-- accepted. Preserve the cached database result and only retarget its live
-- objective reads to the quest's new row.
function pfDatabase:ReindexQuestHDBCache(id, qlogid)
  id, qlogid = tonumber(id), tonumber(qlogid)
  local record = id and GetActiveQuestCache()[id]
  if not record or not qlogid or not IsCurrentQuest(id, qlogid) then return false end
  record.qlogid = qlogid
  local _, liveLevel = compat.GetQuestLogTitle(qlogid)
  record.level = tonumber(liveLevel) or record.level
  pfDatabase:RefreshQuestHDBState(id, qlogid)
  return true
end

function pfDatabase:GetQuestTitleHDB(id)
  local record = GetActiveQuestCache()[tonumber(id)]
  return record and record.title or nil
end

function pfDatabase:GetQuestObjectiveHDB(id)
  local record = GetActiveQuestCache()[tonumber(id)]
  return record and record.objective or nil
end

-- Consumer boundary for the HDB map renderer. It consumes the cached record
-- only; it never opens SQLite or re-runs a Lua database search. `replace`
-- must be true on every live call: it clears this quest's existing PFQUEST
-- pins before re-adding only the ones still eligible, which is what actually
-- removes a pin once its objective's `states` entry flips to DONE. Skipping
-- the clear only stops new pins being added for a finished objective; it
-- leaves the stale one already on the map in place indefinitely.
function pfDatabase:RenderQuestHDBCache(id, qlogid, replace)
  local record = GetActiveQuestCache()[id]
  if not record or record.qlogid ~= qlogid or not IsCurrentQuest(id, qlogid) then
    return false
  end
  pfDatabase:RefreshQuestHDBState(id, qlogid)
  if replace then pfMap:DeleteNode("PFQUEST", record.title) end
  local states = record.states or { U = {}, O = {}, I = {} }
  for index = 1, table.getn(record.pins) do
    local pin = record.pins[index]
    local origin = states[pin.originKind or pin.targetKind]
    local objectiveDone = origin and origin[pin.originID or pin.targetID] == "DONE"
    local requirement = pin.originKind == "IR" and (pin.itemTitle or pfDB.items.loc[pin.originID]) or nil
    -- An IR link means a carried quest item enables a target interaction.
    -- Match normal SearchQuestID: do not display that target until the item
    -- is present, and watch it so bag updates trigger a quest refresh.
    local requirementReady = not requirement
      or (pfDatabase.itemlist and pfDatabase.itemlist.db and pfDatabase.itemlist.db[requirement])
    if requirement then pfDatabase:TrackQuestItemDependency(requirement, id) end
    if ((pin.phase == "end" and pfQuest_config["currentquestgivers"] == "1")
      or (pin.phase == "obj" and not record.complete and not objectiveDone))
      and requirementReady
    then
      AddPin(id, qlogid, record, pin, record.complete)
    end
  end
  return true
end

-- Applies the dynamic player state that cannot be stored in the companion:
-- active quests, completed history, prerequisite chains, and professions.
-- This is intentionally renderer-neutral until it has parity coverage.
function pfDatabase:FilterHDBAvailableStartPins(pins)
  local visible = {}
  local activeTitles = {}
  for key, state in pairs((pfQuest and pfQuest.questlog) or {}) do
    if type(key) == "string" then activeTitles[key] = true end
    if state and state.title then activeTitles[state.title] = true end
  end
  local levelRange = pfQuest_config["questpinlevelrange"] or "off"
  if levelRange == "all" then levelRange = "off" end
  local threshold = ({ red = 5, orange = 4, yellow = 3, green = 2, gray = 1 })[levelRange]
  local direction = pfQuest_config["questpinleveldirection"] == "higher" and "higher" or "lower"
  local plevel = UnitLevel("player")
  for index = 1, table.getn(pins or {}) do
    local pin = pins[index]
    local eligible = pin.questID and not (pfQuest.questlog and pfQuest.questlog[pin.questID])
      and not activeTitles[pin.quest]
      and not pfQuest_history[pin.questID]
    if eligible and threshold then
      local color = pfQuestCompat.GetDifficultyColor(tonumber(pin.qlvl) or 0)
      local rank
      if color.r > .9 and color.g < .15 then rank = 5
      elseif color.r > .9 and color.g < .9 then rank = 4
      elseif color.r > .9 then rank = 3
      elseif color.g > color.r then rank = 2
      else rank = 1 end
      if direction == "higher" then
        eligible = rank >= threshold
      else
        eligible = rank <= threshold
      end
    elseif eligible then
      -- No selected Level Range follows normal pfQuest available-quest rules.
      eligible = not (tonumber(pin.qlvl) and tonumber(pin.qlvl) < plevel - 4
        and pfQuest_config["showlowlevel"] == "0")
      if eligible and tonumber(pin.qmin) and tonumber(pin.qmin) > plevel
        + (pfQuest_config["showhighlevel"] == "1" and 3 or 0) then
        eligible = false
      end
    end
    -- The map's optional difficulty range only limits the upper end of the
    -- displayed range. The established low-level checkbox remains
    -- authoritative, matching QuestFilter() for the non-HDB path.
    if eligible and tonumber(pin.qlvl) and tonumber(pin.qlvl) < plevel - 4
      and pfQuest_config["showlowlevel"] == "0" then
      eligible = false
    end
    if eligible and pin.prerequisites and pin.prerequisites ~= "" then
      eligible = PrerequisitesSatisfied(pin.prerequisites, pin.questID)
    end
    if eligible then
      eligible = pfDatabase:MeetsQuestProfession(pin.questID, pin.skill)
    end
    if eligible then table.insert(visible, pin) end
  end
  return visible
end

function pfDatabase:QuestHDBHasMapPin(id, qlogid, map)
  local record = pfDatabase:RefreshQuestHDBState(id, qlogid)
  if not record then return false end
  for index = 1, table.getn(record.pins) do
    if record.pins[index].zoneID == map then return true end
  end
  return false
end

function pfDatabase:GetQuestHDBCacheReport(id)
  local record = GetActiveQuestCache()[id]
  if not record then return nil end

  local normal = { U = {}, O = {} }
  for _, coords in pairs((pfMap.nodes and pfMap.nodes.PFQUEST) or {}) do
    for _, titles in pairs(coords) do
      local node = titles[record.title]
      if node and node.questid == id and node.spawnid and node.spawntype then
        local kind = node.spawntype == pfQuest_Loc["Object"] and "O" or "U"
        normal[kind][node.spawnid] = true
      end
    end
  end

  local cached, normalCount, missing = 0, 0, {}
  for _, kind in pairs({ "U", "O" }) do
    for targetID in pairs(record.spawns[kind] or {}) do
      cached = cached + 1
      if not normal[kind][targetID] then
        table.insert(missing, kind .. ":" .. targetID)
      end
    end
    for _ in pairs(normal[kind]) do normalCount = normalCount + 1 end
  end
  return {
    id = id, pins = table.getn(record.pins), cachedSources = cached,
    normalSources = normalCount, missing = missing, complete = record.complete,
  }
end

AddPin = function(id, qlogid, quest, pin, complete)
  local texture
  local qtype
  local item
  local spawn = pin.title
  local spawntype = pin.targetKind == "O" and pfQuest_Loc["Object"] or pfQuest_Loc["Unit"]
  if pin.sourceKind == "V" then texture = pfQuestConfig.path .. "\\img\\icon_vendor" end
  if pin.targetKind == "U" and pin.rank and pin.rank ~= "" then
    pfDB.units.data[pin.targetID] = pfDB.units.data[pin.targetID] or {}
    pfDB.units.data[pin.targetID].rnk = pin.rank
  end
  if pin.phase == "end" then
    texture = complete and pfQuestConfig.path .. "\\img\\complete_c"
      or pfQuestConfig.path .. "\\img\\complete"
    qtype = pin.targetKind == "O" and "OBJECT_END" or "NPC_END"
  elseif pin.targetKind == "A" then
    qtype = "AREATRIGGER_OBJECTIVE"
    spawn = pfQuest_Loc["Exploration Mark"]
    spawntype = pfQuest_Loc["Trigger"]
  elseif pin.targetKind == "Z" then
    qtype = "ZONE_OBJECTIVE"
    spawntype = pfQuest_Loc["Area/Zone"]
  elseif pin.originKind == "I" then
    qtype = "ITEM_OBJECTIVE_LOOT"
    item = pin.itemTitle or pfDB.items.loc[pin.originID]
  elseif pin.originKind == "IR" then
    qtype = pin.targetKind == "O" and "OBJECT_OBJECTIVE_ITEMREQ" or "UNIT_OBJECTIVE_ITEMREQ"
  elseif pin.targetKind == "O" then
    qtype = "OBJECT_OBJECTIVE"
  else
    qtype = "UNIT_OBJECTIVE"
  end

  pfMap:AddNode({
    addon = "PFQUEST",
    title = quest.title,
    quest = quest.title,
    questid = id,
    qlogid = qlogid,
    qlvl = quest.level,
    questObjective = quest.objective,
    level = pin.level or UNKNOWN,
    spawn = spawn,
    spawnid = pin.targetID,
    spawntype = spawntype,
    zone = pin.zoneID,
    x = pin.x,
    y = pin.y,
    respawn = pin.respawn and SecondsToTime(pin.respawn) or "N/A",
    droprate = pin.sourceKind == "V" and nil or pin.chance,
    sellcount = pin.sourceKind == "V" and pin.chance or nil,
    texture = texture,
    item = item,
    itemreq = pin.originKind == "IR" and (pin.itemTitle or pfDB.items.loc[pin.originID]) or nil,
    sharedspawns = pin.sharedSpawns,
    relatedobjectives = pin.relatedObjectives,
    -- Match normal pfQuest types so map/minimap tooltips retain their
    -- established description and progress formatting.
    QTYPE = qtype,
  })
end

local function HasActiveNodeType(id, title, ender)
  for _, coords in pairs((pfMap.nodes and pfMap.nodes.PFQUEST) or {}) do
    for _, titles in pairs(coords) do
      local node = titles[title]
      if node and node.questid == id then
        local isEnder = node.QTYPE == "NPC_END" or node.QTYPE == "OBJECT_END"
        local isObjective = node.QTYPE == "UNIT_OBJECTIVE" or node.QTYPE == "OBJECT_OBJECTIVE"
          or node.QTYPE == "ITEM_OBJECTIVE_LOOT" or node.QTYPE == "ITEM_OBJECTIVE_USE"
        if (ender and isEnder) or (not ender and isObjective) then return true end
      end
    end
  end
  return false
end

HasActiveNodes = function(id, title)
  return HasActiveNodeType(id, title, true) or HasActiveNodeType(id, title, false)
end


-- Restore the entire active set only when normal pfQuest did not rebuild any
-- of its active nodes after login. This removes an old available marker first,
-- then gives map and minimap pins normal pfQuest metadata.
RestoreMissingEnder = function(id, qlogid, record)
  local hasEnder = HasActiveNodeType(id, record.title, true)
  local hasObjectives = HasActiveNodeType(id, record.title, false)
  -- No normal active nodes at all means an old available marker may be left.
  if not hasEnder and not hasObjectives then
    pfMap:DeleteNode("PFQUEST", record.title)
  end
  local states = record.states or { U = {}, O = {}, I = {} }
  for index = 1, table.getn(record.pins) do
    local pin = record.pins[index]
    local origin = states[pin.originKind or pin.targetKind]
    local objectiveDone = origin and origin[pin.originID or pin.targetID] == "DONE"
    if pin.phase == "end" and not hasEnder and pfQuest_config["currentquestgivers"] == "1" then
      AddPin(id, qlogid, record, pin, record.complete)
    elseif pin.phase == "obj" and not hasObjectives and not record.complete and not objectiveDone then
      AddPin(id, qlogid, record, pin, record.complete)
    end
  end
end

-- Returns true only when the HDB request was accepted. The normal caller can
-- immediately keep its Lua fallback when HearthDB is missing or disabled.
function pfDatabase:SearchQuestIDHDB(id, meta)
  if not Enabled() or not meta or not meta.qlogid then return false end
  local qlogid = meta.qlogid
  if not IsCurrentQuest(id, qlogid) then return false end

  local record = GetActiveQuestCache()[id]
  if record and record.qlogid == qlogid then
    pfDatabase:RenderQuestHDBCache(id, qlogid, true)
    -- Cached quests are the normal path for objective and completion updates.
    -- Rendering mutates the node database, but it must also wake the map's
    -- always-on update driver so the tracker, minimap, and route refresh while
    -- the world map is closed.
    pfMap.queue_update = GetTime()
    return true
  end

  local accepted = pfQuestHearthDB:GetQuestMapPinsAsync(id, function(result, err)
    if not IsCurrentQuest(id, qlogid) then return end
    if err or not result then
      -- HearthDB is optional: keep the established renderer as the safe
      -- fallback whenever the native provider cannot answer.
      pfDatabase:SearchQuestID(id, { addon = "PFQUEST", qlogid = qlogid })
      pfMap.queue_update = GetTime()
      return
    end

    pfDatabase:StoreQuestHDBCache(id, qlogid, result)
    pfDatabase:RenderQuestHDBCache(id, qlogid, true)
    pfMap.queue_update = GetTime()
  end)
  return accepted and true or false
end

local hdbQuestGiverSet = {}
local hdbQuestGiverPins = {}
local hdbQuestGiverRequest = 0

function pfDatabase:ClearHDBQuestGiverCache()
  for id in pairs(hdbQuestGiverSet) do hdbQuestGiverSet[id] = nil end
  for id in pairs(hdbQuestGiverPins) do hdbQuestGiverPins[id] = nil end
  hdbQuestGiverRequest = hdbQuestGiverRequest + 1
end

local function CollapseHDBItemStartPins(pins)
  local ordinary, groups = {}, {}
  for index = 1, table.getn(pins or {}) do
    local pin = pins[index]
    if pin.originKind ~= "I" then
      table.insert(ordinary, pin)
    else
      local key = tostring(pin.questID) .. ":" .. tostring(pin.originID)
      local group = groups[key]
      if not group then
        group = { sources = {}, sourceOrder = {} }
        groups[key] = group
      end
      local sourceKey = tostring(pin.targetKind) .. ":" .. tostring(pin.targetID)
      local source = group.sources[sourceKey]
      if not source then
        source = { pins = {}, title = pin.title or UNKNOWN, level = pin.level, chance = pin.chance }
        group.sources[sourceKey] = source
        table.insert(group.sourceOrder, sourceKey)
      end
      table.insert(source.pins, pin)
    end
  end

  for _, group in pairs(groups) do
    table.sort(group.sourceOrder)
    local best, bestKey
    local sourceLevels, sourceNames = {}, {}
    for _, sourceKey in ipairs(group.sourceOrder) do
      local source = group.sources[sourceKey]
      table.insert(sourceNames, source.title)
      sourceLevels[source.title] = {
        level = source.level or "?",
        chance = source.chance or 0,
      }
      if not best or table.getn(source.pins) > table.getn(best.pins) then
        best, bestKey = source, sourceKey
      end
    end
    local shown = {}
    for index = 1, math.min(3, table.getn(sourceNames)) do table.insert(shown, sourceNames[index]) end
    local sourceText = table.concat(shown, ", ")
    if table.getn(sourceNames) > 3 then sourceText = sourceText .. " (+" .. (table.getn(sourceNames) - 3) .. " more)" end
    local zones = {}
    for _, pin in ipairs(best and best.pins or {}) do
      if pin.zoneID and not zones[pin.zoneID] then
        zones[pin.zoneID] = true
        pin.dropsources, pin.dropsources_levels = sourceText, sourceLevels
        table.insert(ordinary, pin)
      end
    end
  end
  return ordinary
end

local function AddAvailablePin(pin, plevel, addon)
  local itemStart = pin.originKind == "I"
  local high = tonumber(pin.qmin) and tonumber(pin.qmin) > plevel
  local low = tonumber(pin.qlvl) and tonumber(pin.qlvl) + 10 < plevel
  local texture = pfQuestConfig.path .. "\\img\\available_c"
  local vertex, layer = { 0, 0, 0 }, itemStart and 4 or 3
  if high then
    texture, vertex, layer = pfQuestConfig.path .. "\\img\\available", { 1, 0.6, 0.6 }, 2
  elseif low then
    texture, vertex, layer = pfQuestConfig.path .. "\\img\\available", { 1, 1, 1 }, 2
  elseif pin.event and pin.event ~= "" then
    texture, vertex, layer = pfQuestConfig.path .. "\\img\\available", { 0.2, 0.8, 1 }, 2
  end
  pfMap:AddNode({
    addon = addon or "PFQUEST", title = pin.quest, quest = pin.quest, questid = pin.questID,
    questObjective = pin.objective, qlvl = pin.qlvl, qmin = pin.qmin,
    texture = texture, vertex = vertex, layer = layer,
    QTYPE = itemStart and "ITEM_START" or (pin.targetKind == "O" and "OBJECT_START" or "NPC_START"),
    spawn = itemStart and (pin.itemTitle or UNKNOWN) or pin.title,
    spawnid = itemStart and pin.originID or pin.targetID,
    item = itemStart and pin.itemTitle or nil,
    dropsources = itemStart and pin.dropsources or nil,
    dropsources_levels = itemStart and pin.dropsources_levels or nil,
    spawntype = itemStart and "Item Drop" or (pin.targetKind == "O" and pfQuest_Loc["Object"] or pfQuest_Loc["Unit"]),
    level = itemStart and pfQuest_Loc["N/A"] or (pin.level or UNKNOWN),
    zone = pin.zoneID, x = pin.x, y = pin.y,
    respawn = itemStart and pfQuest_Loc["N/A"] or (pin.respawn and SecondsToTime(pin.respawn) or "N/A"),
  })
end

-- Returns true only after the native request was accepted. Nodes remain intact
-- while the query is in flight, so a provider failure never leaves the map empty.
function pfDatabase:SearchQuestGiversHDB(meta)
  if not Enabled() or type(pfQuestHearthDB.GetQuestStartPinsAsync) ~= "function" then return false end
  local faction = UnitFactionGroup("player") == "Horde" and "H" or "A"
  local _, race = UnitRace("player")
  local _, class = UnitClass("player")
  local request = hdbQuestGiverRequest + 1
  hdbQuestGiverRequest = request
  local levelRange = pfQuest_config["questpinlevelrange"] or "off"
  if levelRange == "all" then levelRange = "off" end
  local options = {
    level = UnitLevel("player"),
    highOffset = pfQuest_config["showhighlevel"] == "1" and 3 or 0,
    includeLow = pfQuest_config["showlowlevel"] == "1",
    -- Normal mode can apply the ordinary high/low-level limits in SQLite and
    -- avoid materializing thousands of pins that Lua will immediately reject.
    -- An explicit difficulty range still needs the wider population because
    -- its color rules are applied by FilterHDBAvailableStartPins below.
    includeAllLevels = levelRange ~= "off",
    includeEvents = pfQuest_config["showfestival"] == "1",
    raceMask = pfDatabase:GetBitByRace(race),
    classMask = pfDatabase:GetBitByClass(class),
    faction = faction,
  }
  local accepted = pfQuestHearthDB:GetQuestStartPinsAsync(options, function(pins, err)
    if request ~= hdbQuestGiverRequest or err or not pins then return end
    pfDatabase:BuildSkillCache()
    -- Retain starter pins even for quests filtered out because they are
    -- currently active. Turtle players can reload with a quest in progress
    -- and then abandon it; keeping this internal cache lets that starter
    -- return synchronously instead of waiting for another SQLite request.
    local cachedByQuest = {}
    local cachedPins = CollapseHDBItemStartPins(pins)
    for index = 1, table.getn(cachedPins) do
      local pin = cachedPins[index]
      cachedByQuest[pin.questID] = cachedByQuest[pin.questID] or {}
      table.insert(cachedByQuest[pin.questID], pin)
    end
    local visible = CollapseHDBItemStartPins(pfDatabase:FilterHDBAvailableStartPins(pins))
    local current, byQuest = {}, {}
    for index = 1, table.getn(visible) do
      local pin = visible[index]
      current[pin.questID] = pin.quest
      byQuest[pin.questID] = byQuest[pin.questID] or {}
      table.insert(byQuest[pin.questID], pin)
    end

    for id in pairs(hdbQuestGiverPins) do hdbQuestGiverPins[id] = nil end
    for id, list in pairs(cachedByQuest) do hdbQuestGiverPins[id] = list end

    local rebuild = {}
    for id in pairs(hdbQuestGiverSet) do
      if not current[id] then
        local title = hdbQuestGiverSet[id] or (pfDB.quests.loc[id] and pfDB.quests.loc[id].T)
        if title then pfMap:DeleteNode("PFQUEST", title) end
        local active = pfQuest.questlog and pfQuest.questlog[id]
        if active and active.qlogid then rebuild[id] = active.qlogid end
      end
    end
    local plevel = UnitLevel("player")
    for id, list in pairs(byQuest) do
      if not hdbQuestGiverSet[id] then
        for index = 1, table.getn(list) do AddAvailablePin(list[index], plevel, meta and meta.addon) end
      end
    end
    for id, qlogid in pairs(rebuild) do
      local activeMeta = { addon = "PFQUEST", qlogid = qlogid }
      if not pfDatabase:SearchQuestIDHDB(id, activeMeta) then
        pfDatabase:SearchQuestID(id, activeMeta)
      end
    end
    for id in pairs(hdbQuestGiverSet) do hdbQuestGiverSet[id] = nil end
    for id, title in pairs(current) do hdbQuestGiverSet[id] = title end
    pfMap.queue_update = GetTime()
  end)
  return accepted and true or false
end

-- Accepting or abandoning one quest must not rebuild the complete available
-- quest population. The most recent full refresh already holds the eligible
-- start pins grouped by quest, so update only the affected entry.
function pfDatabase:MarkQuestAcceptedHDB(id)
  if not Enabled() then return false end
  local questID = tonumber(id)
  if questID then
    hdbQuestGiverSet[questID] = nil
    -- A reload can discover the quest only after it is already active, so the
    -- normal available-giver query may never have cached its starter (notably
    -- for low-level Turtle quests hidden by the configured level range).
    -- Prefetch only this starter for a future abandon without drawing it now.
    if not hdbQuestGiverPins[questID]
      and type(pfQuestHearthDB.GetQuestStartPinsAsync) == "function" then
      local _, race = UnitRace("player")
      local _, class = UnitClass("player")
      pfQuestHearthDB:GetQuestStartPinsAsync({
        questID = questID,
        level = UnitLevel("player"),
        includeAllLevels = true,
        includeEvents = pfQuest_config["showfestival"] == "1",
        raceMask = pfDatabase:GetBitByRace(race),
        classMask = pfDatabase:GetBitByClass(class),
        faction = UnitFactionGroup("player") == "Horde" and "H" or "A",
      }, function(pins, err)
        if err or not pins then return end
        local cached = CollapseHDBItemStartPins(pins)
        if table.getn(cached) > 0 then hdbQuestGiverPins[questID] = cached end
      end)
    end
    return true
  end

  -- The first quest-log scan can run before an asynchronous title lookup has
  -- resolved the numeric ID. In that case the queue deliberately carries the
  -- visible title as its temporary identity. Remove the matching cached giver
  -- entries by title and keep their pin lists available in case the quest is
  -- abandoned later.
  if type(id) == "string" and id ~= "" then
    for cachedID, title in pairs(hdbQuestGiverSet) do
      if title == id then hdbQuestGiverSet[cachedID] = nil end
    end
    return true
  end

  return false
end

-- Completing one quest normally changes only quests that list it as a direct
-- prerequisite. Query that small set instead of rebuilding every available
-- quest giver; the full refresh remains the caller's fallback if this request
-- cannot be submitted.
function pfDatabase:RefreshCompletedQuestGiversHDB(id, meta)
  if not Enabled() or type(pfQuestHearthDB.GetQuestStartPinsAsync) ~= "function" then return false end
  id = tonumber(id)
  if not id then return false end

  -- The fast path used to add only quests directly unlocked by this turn-in.
  -- It left the completed quest's cached start pins in place, so NPC tooltips
  -- could keep advertising earlier chain steps until a later full refresh.
  local completedTitle = hdbQuestGiverSet[id]
    or (pfDB.quests.loc[id] and pfDB.quests.loc[id].T)
  hdbQuestGiverPins[id] = nil
  hdbQuestGiverSet[id] = nil
  if completedTitle then pfMap:DeleteNode("PFQUEST", completedTitle) end

  local _, race = UnitRace("player")
  local _, class = UnitClass("player")
  local levelRange = pfQuest_config["questpinlevelrange"] or "off"
  if levelRange == "all" then levelRange = "off" end
  local options = {
    prerequisiteID = id,
    level = UnitLevel("player"),
    highOffset = pfQuest_config["showhighlevel"] == "1" and 3 or 0,
    includeLow = pfQuest_config["showlowlevel"] == "1",
    includeAllLevels = levelRange ~= "off",
    includeEvents = pfQuest_config["showfestival"] == "1",
    raceMask = pfDatabase:GetBitByRace(race),
    classMask = pfDatabase:GetBitByClass(class),
    faction = UnitFactionGroup("player") == "Horde" and "H" or "A",
  }
  local accepted = pfQuestHearthDB:GetQuestStartPinsAsync(options, function(pins, err)
    if err or not pins then return end
    pfDatabase:BuildSkillCache()
    local visible = CollapseHDBItemStartPins(pfDatabase:FilterHDBAvailableStartPins(pins))
    local byQuest = {}
    for index = 1, table.getn(visible) do
      local pin = visible[index]
      byQuest[pin.questID] = byQuest[pin.questID] or {}
      table.insert(byQuest[pin.questID], pin)
    end
    local plevel = UnitLevel("player")
    for questID, list in pairs(byQuest) do
      hdbQuestGiverPins[questID] = list
      if not hdbQuestGiverSet[questID] then
        for index = 1, table.getn(list) do AddAvailablePin(list[index], plevel, meta and meta.addon) end
        if list[1] then hdbQuestGiverSet[questID] = list[1].quest end
      end
    end
    pfMap.queue_update = GetTime()
  end)
  return accepted and true or false
end

function pfDatabase:RestoreAbandonedQuestGiverHDB(id, meta)
  if not Enabled() then return false end
  id = tonumber(id)
  local cached = id and hdbQuestGiverPins[id]
  if pfQuest.TraceAbandon then
    pfQuest:TraceAbandon("RESTORE id=" .. tostring(id)
      .. " cachedPins=" .. tostring(cached and table.getn(cached) or 0))
  end
  -- These pins were already filtered immediately before the quest was
  -- accepted. Restore them directly after abandonment: running them through
  -- the availability filter again can still see the client's stale active
  -- quest row and discard every starter until the next background refresh.
  if cached and table.getn(cached) > 0 then
    local plevel = UnitLevel("player")
    for index = 1, table.getn(cached) do
      AddAvailablePin(cached[index], plevel, meta and meta.addon)
    end
    hdbQuestGiverSet[id] = cached[1].quest
    pfMap.queue_update = GetTime()
    pfQuest.immediateAbandonRefresh = true
    if pfQuest.TraceAbandon then pfQuest:TraceAbandon("RESTORE cached starter added") end
    return true
  end

  -- Profiles loaded with the quest already active may not have a retained
  -- starter list. Query only that quest as the fallback in that case.
  if id and type(pfQuestHearthDB.GetQuestStartPinsAsync) == "function" then
    local _, race = UnitRace("player")
    local _, class = UnitClass("player")
    local options = {
      questID = id,
      level = UnitLevel("player"),
      includeAllLevels = true,
      includeEvents = pfQuest_config["showfestival"] == "1",
      raceMask = pfDatabase:GetBitByRace(race),
      classMask = pfDatabase:GetBitByClass(class),
      faction = UnitFactionGroup("player") == "Horde" and "H" or "A",
    }
    local accepted = pfQuestHearthDB:GetQuestStartPinsAsync(options, function(pins, err)
      if pfQuest.TraceAbandon then
        pfQuest:TraceAbandon("RESTORE async result pins=" .. tostring(pins and table.getn(pins) or 0)
          .. " err=" .. tostring(err))
      end
      if err or not pins then return end
      pfDatabase:BuildSkillCache()
      local visible = CollapseHDBItemStartPins(pfDatabase:FilterHDBAvailableStartPins(pins))
      hdbQuestGiverPins[id] = visible
      local plevel = UnitLevel("player")
      for index = 1, table.getn(visible) do
        AddAvailablePin(visible[index], plevel, meta and meta.addon)
      end
      if visible[1] then hdbQuestGiverSet[id] = visible[1].quest end
      pfMap.queue_update = GetTime()
    end)
    if pfQuest.TraceAbandon then pfQuest:TraceAbandon("RESTORE async accepted=" .. tostring(accepted and true or false)) end
    return accepted and true or false
  end
  return false
end

function pfDatabase:SearchMetaRelationHDB(query, meta, callback)
  if not Enabled() or type(pfQuestHearthDB.GetMetaRelationAsync) ~= "function" then return false end
  local relation = query and query.name
  local aliases = { flightmaster="flight", taxi="flight", flights="flight", raremobs="rares" }
  relation = aliases[relation] or relation
  local accepted = pfQuestHearthDB:GetMetaRelationAsync(relation, function(rows, err)
    if err or not rows then if callback then callback(nil, err) end return end
    local maps, faction = {}, query.faction or UnitFactionGroup("player")
    faction = faction == "Horde" and "H" or faction == "Alliance" and "A" or ""
    -- Several gathering nodes have distinct object IDs but the same localized
    -- name. The static database used to spread the canonical custom icon by
    -- name, so rebuild that small alias map from the native result set.
    local resultIcons = {}
    for i=1,table.getn(rows) do local r=rows[i]
      local icon = pfDatabase.iconsByID[r.kind .. r.id]
      if icon and r.title then resultIcons[r.title] = icon end
    end
    for i=1,table.getn(rows) do local r=rows[i]
      local skillRelations = pfDatabase.metaSkillRelations or {}
      local skill = skillRelations[relation]
      local pass = (not skill or (not query.min or tonumber(r.value)>=tonumber(query.min)) and (not query.max or tonumber(r.value)<=tonumber(query.max)))
      if not skill then pass = string.find(r.value or "", faction) and true or false end
      if pass and r.zoneID and r.x and r.y then
        local n={} for k,v in pairs(meta or {}) do n[k]=v end
        n.tracking=true;n.spawn=r.title or UNKNOWN;n.spawnid=r.id;n.title=n.quest or n.item or n.spawn
        local skillCaption = pfDatabase.metaSkillCaptions and pfDatabase.metaSkillCaptions[relation]
        n.level = (skillCaption and string.format("%s [%s]", r.value, skillCaption))
          or (relation == "herbs" and string.format("%s [%s]", r.value, pfQuest_Loc["Herbalism"]))
          or (relation == "mines" and string.format("%s [%s]", r.value, pfQuest_Loc["Mining"]))
          or r.level or UNKNOWN
        n.spawntype=r.kind=="O" and pfQuest_Loc["Object"] or pfQuest_Loc["Unit"]
        if pfQuest_config.trackingicons ~= "0" then
          n.icon = pfDatabase.iconsByID[r.kind .. r.id] or resultIcons[n.spawn] or pfDatabase.icons[n.spawn] or n.icon
        end
        if n.icon and skill then n.fade_range = 85 elseif n.icon then n.fade_range = 10 end
        n.zone=r.zoneID;n.x=r.x;n.y=r.y;n.respawn=r.respawn and r.respawn > 0 and SecondsToTime(r.respawn) or pfQuest_Loc["N/A"]
        maps[r.zoneID]=(maps[r.zoneID] or 0)+1;pfMap:AddNode(n)
      end end
    pfMap.queue_update=GetTime();if callback then callback(maps) end
  end)
  return accepted and true or false
end
