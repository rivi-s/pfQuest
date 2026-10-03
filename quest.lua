-- multi api compat
local compat = pfQuestCompat
local _, _, _, client = GetBuildInfo()
client = client or 11200
local _G = client == 11200 and getfenv(0) or _G

-- Performance: cache frequently-used globals
local pairs, ipairs, next = pairs, ipairs, next
local strfind = strfind
local format = string.format
local getn, insert, concat = table.getn, table.insert, table.concat
local tostring, tonumber, type = tostring, tonumber, type
local GetTime = GetTime
local UnitLevel = UnitLevel

pfQuest = CreateFrame("Frame")
pfQuest.RebuildConfigUI = function()
  return pfQuestConfig:RebuildConfigUI()
end
pfQuest.icons = {}
pfQuest_global = pfQuest_global or {}

pfQuest.defaultdburl = "https://database.ravencraft.io/?quest="

-- The Quest Log's Show button should lead to the quest hub when one is
-- known. Objective spawn density can otherwise send it to a nearby zone
-- with more creatures, even when the quest begins and ends elsewhere.
function pfQuest:GetQuestHubMap(id)
  local quest = pfDB.quests and pfDB.quests.data and pfDB.quests.data[id]
  if not quest then
    return
  end

  local function findMap(relation)
    local maps, bestMap, bestCount = {}, nil, 0
    if not relation then
      return
    end

    for _, kind in ipairs({ "U", "O" }) do
      local entries = relation[kind]
      local database = kind == "U" and pfDB.units and pfDB.units.data or pfDB.objects and pfDB.objects.data
      if entries and database then
        for _, entry in ipairs(entries) do
          local record = database[entry]
          if record and record.coords then
            for _, coord in ipairs(record.coords) do
              local zone = coord[3]
              if zone and zone > 0 then
                maps[zone] = (maps[zone] or 0) + 1
                -- Turtle can add a second copy of an existing quest NPC in a
                -- custom zone. Keep the data's first location when counts tie.
                if maps[zone] > bestCount then
                  bestMap, bestCount = zone, maps[zone]
                end
              end
            end
          end
        end
      end
    end

    return bestMap
  end

  return findMap(quest["end"]) or findMap(quest["start"])
end

function pfQuest:GetDatabaseURL()
  local url = pfQuest_global["dburl"]
  url = url and url ~= "" and url or self.defaultdburl
  -- A plain database homepage links directly to the matching quest ID;
  -- custom query prefixes continue to work as entered.
  if strsub(url, -1) == "/" then
    url = url .. "?quest="
  end
  return url
end

function pfQuest:Debug(msg)
  -- only show debug output if enabled
  if not pfQuest_config.debug and pfQuest.debugwin then
    pfQuest.debugwin:Hide()
    return
  elseif not pfQuest_config.debug then
    return
  end

  if not pfQuest.debugwin then
    pfQuest.debugwin = CreateFrame("ScrollingMessageFrame", nil, UIParent)
    pfQuest.debugwin:SetWidth(320)
    pfQuest.debugwin:SetHeight(320)
    pfQuest.debugwin:SetPoint("RIGHT", -42, 0)
    local font = pfUI and pfUI.font_default or STANDARD_TEXT_FONT
    local size = tonumber(pfQuest_config["trackerfontsize"]) or 12
    pfQuest.debugwin:SetFont(font, size, "OUTLINE")
    pfQuest.debugwin:SetFading(false)
    pfQuest.debugwin:SetMaxLines(150)
    pfQuest.debugwin:SetJustifyH("RIGHT")
    pfQuest.debugwin:SetJustifyV("CENTER")
  end

  local font = pfUI and pfUI.font_default or STANDARD_TEXT_FONT
  local size = tonumber(pfQuest_config["trackerfontsize"]) or 12
  pfQuest.debugwin:SetFont(font, size, "OUTLINE")
  pfQuest.debugwin:AddMessage(msg)
  pfQuest.debugwin:Show()
end

-- Small always-on ring buffer for diagnosing the multi-event abandon path.
-- It records strings only and performs no map/database work.
pfQuest.abandonTrace = {}
function pfQuest:TraceAbandon(msg)
  table.insert(self.abandonTrace, format("%.3f %s", GetTime(), tostring(msg)))
  if table.getn(self.abandonTrace) > 24 then table.remove(self.abandonTrace, 1) end
end

function pfQuest:SortedPairs(t, index, reverse)
  -- collect the keys
  local keys = {}
  for k, v in pairs(t) do
    if v then
      keys[table.getn(keys) + 1] = k
    end
  end

  local order
  if reverse then
    order = function(t, a, b)
      return t[a][index] < t[b][index]
    end
  else
    order = function(t, a, b)
      return t[a][index] > t[b][index]
    end
  end
  table.sort(keys, function(a, b)
    return order(t, a, b)
  end)

  -- return the iterator function
  local i = 0
  return function()
    i = i + 1
    if keys[i] then
      return keys[i], t[keys[i]]
    end
  end
end

pfQuest.queue = {}
pfQuest.queueCount = 0 -- Track queue size to avoid O(n) tsize() calls
pfQuest.abandon = ""
pfQuest.abandonID = nil
pfQuest.turnedInQuestIDs = {}
pfQuest.questlog = {}
pfQuest.questlog_tmp = {}

-- Quest history is keyed by numeric database ID. Older HDB alpha builds could
-- accidentally record a temporary same-title identity as a string.
if not next(pfDB.quests.data or {}) then
  for historyID in pairs(pfQuest_history or {}) do
    if type(historyID) ~= "number" then pfQuest_history[historyID] = nil end
  end
end

local function GetCanonicalQuestTitle(id)
  if pfDatabase and type(pfDatabase.GetQuestTitleHDB) == "function" then
    local title = pfDatabase:GetQuestTitleHDB(id)
    if title then return title end
  end
  local locale = id and pfDB and pfDB.quests and pfDB.quests.loc and pfDB.quests.loc[id]
  return locale and locale.T or nil
end

-- Helper to add to queue with count tracking
local function queueAdd(entry)
  insert(pfQuest.queue, entry)
  pfQuest.queueCount = pfQuest.queueCount + 1
end

local skillstate = ""
pfQuest:RegisterEvent("QUEST_WATCH_UPDATE")
pfQuest:RegisterEvent("QUEST_LOG_UPDATE")
pfQuest:RegisterEvent("QUEST_FINISHED")
pfQuest:RegisterEvent("PLAYER_LEVEL_UP")
pfQuest:RegisterEvent("PLAYER_ENTERING_WORLD")
pfQuest:RegisterEvent("SKILL_LINES_CHANGED")
pfQuest:RegisterEvent("ADDON_LOADED")
-- ClassicAPI supplies explicit accept/turn-in notifications. The legacy
-- QUEST_LOG_UPDATE route remains registered for ordinary 1.12 clients.
if pfQuestCompat.optional and pfQuestCompat.optional.questEvents then
  pfQuest:RegisterEvent("QUEST_ACCEPTED")
  pfQuest:RegisterEvent("QUEST_TURNED_IN")
  pfQuest:RegisterEvent("QUEST_REMOVED")
end
pfQuest:SetScript("OnEvent", function()
  if event == "ADDON_LOADED" then
    if arg1 == "pfQuest" or arg1 == "pfQuest-tbc" or arg1 == "pfQuest-wotlk" then
      pfQuest:AddQuestLogIntegration()
      pfQuest:AddWorldMapIntegration()
      this.lock = GetTime() + 10
    else
      return
    end
  elseif event == "QUEST_TURNED_IN" then
    -- ClassicAPI reports the completed quest ID directly. Record it here so
    -- instant auto turn-ins are not lost when a quest enters and leaves the
    -- log between two legacy QUEST_LOG_UPDATE scans.
    local questid = tonumber(arg1)
    pfQuest:TraceAbandon("EVENT TURNED_IN id=" .. tostring(questid))
    if questid then
      pfQuest.turnedInQuestIDs[questid] = true
      pfQuest_history[questid] = { time(), UnitLevel("player") }
      if pfJournal then pfJournal.dirty = true end
    end
  elseif event == "QUEST_REMOVED" then
    local questid = tonumber(arg1)
    pfQuest:TraceAbandon("EVENT REMOVED id=" .. tostring(questid)
      .. " turned=" .. tostring(questid and pfQuest.turnedInQuestIDs[questid] and true or false))
    if questid then
      -- ClassicAPI emits QUEST_TURNED_IN before QUEST_REMOVED for a hand-in.
      -- An ID removed without that server-authoritative completion event is
      -- an abandon. This is more reliable on Turtle than the legacy global
      -- AbandonQuest hook and arrives before our deferred quest-log scan.
      if not pfQuest.turnedInQuestIDs[questid] then
        pfQuest.abandonID = questid
        local active = pfQuest.questlog and pfQuest.questlog[questid]
        pfQuest.abandon = active and active.title or GetCanonicalQuestTitle(questid) or ""
      end
      pfQuest.turnedInQuestIDs[questid] = nil
    end
    pfQuest.updateQuestLog = true
  elseif event == "SKILL_LINES_CHANGED" then
    -- Use table.concat to avoid string concatenation garbage
    local skillParts = {}
    for i = 0, GetNumSkillLines() do
      skillParts[i + 1] = GetSkillLineInfo(i) or ""
    end
    local skills = concat(skillParts)

    -- update quest givers when new skills or
    -- professions became available
    if skills ~= skillstate then
      pfQuest.updateQuestGivers = true
      skillstate = skills
    end
  elseif event == "PLAYER_LEVEL_UP" then
    pfQuest.updateQuestGivers = true
  elseif event == "PLAYER_ENTERING_WORLD" then
    -- The initial QUEST_LOG_UPDATE can arrive while login is locked. Queue a
    -- complete post-login scan so active hand-in nodes are rebuilt reliably.
    pfQuest.updateQuestLog = true
    pfQuest.updateQuestGivers = true
  else
    pfQuest.updateQuestLog = true
  end

  if event == "QUEST_LOG_UPDATE" then
    -- lock initial scan during incoming events
    if this.lock and this.lock > GetTime() then
      this.lock = GetTime() + 1.5
    end
  end
end)

pfQuest:SetScript("OnUpdate", function()
  if this.lock and this.lock > GetTime() then
    return
  end
  if not pfDatabase.localized then
    return
  end

  if (this.tick or 0.05) > GetTime() then
    return
  else
    this.tick = GetTime() + 0.05
  end

  -- pfUI applies the initial Quest Log selection just after OnShow. Refresh
  -- pfQuest once on the following tick so its controls do not require a
  -- manual quest-selection change before appearing.
  if this.questLogOpenRefreshAt and this.questLogOpenRefreshAt <= GetTime() then
    this.questLogOpenRefreshAt = nil
    if QuestLogFrame and QuestLogFrame:IsShown() then
      pfQuest:UpdateQuestlog()
      QuestLog_Update()
    end
  end

  -- Game events refresh the quest log immediately. Keep a slow fallback for
  -- clients that miss an event, but do not rebuild every active quest once
  -- per second while the player is idle.
  if (this.qlogtick or 60) < GetTime() then
    local t0 = GetTime()
    if pfQuest:UpdateQuestlog() then
      -- The map renderer is not always active while playing. Refresh the
      -- standalone tracker here too, so newly accepted unwatched quests do
      -- not have to wait for a map update before appearing.
      if pfQuest.tracker then
        pfQuest.tracker.Reset()
        pfQuest.tracker.DoLayout()
      end
      this.currentZoneRefreshAt = GetTime() + 0.75
      pfQuest:Debug(format("Update Quest|cff33ffccLog|r [|cffff3333Tick|r] %.4fs", GetTime() - t0))
    end
    this.qlogtick = GetTime() + 60
  end

  if this.updateQuestLog == true and pfQuest.queueCount == 0 then
    local t0 = GetTime()
    if pfQuest:UpdateQuestlog() then
      if pfQuest.tracker then
        pfQuest.tracker.Reset()
        pfQuest.tracker.DoLayout()
      end
      this.currentZoneRefreshAt = GetTime() + 0.75
    end
    pfQuest:Debug(format("Update Quest|cff33ffccLog %.4fs", GetTime() - t0))
    this.updateQuestLog = false
  end

  if this.updateQuestGivers == true then
    pfQuest:Debug("Update Quest|cff33ffcc Givers")
    -- A fresh profile shows the mode selector during login. Do not generate
    -- the complete available-questgiver map behind that selector; it can add
    -- thousands of nodes while the client is still loading.
    if pfQuest_config["welcome"] == "1" and pfQuest_config["trackingmethod"] ~= 4 and pfQuest_config["allquestgivers"] == "1" then
      local meta = { ["addon"] = "PFQUEST" }
      local t0 = GetTime()
      if not pfDatabase:SearchQuestGiversHDB(meta) then
        pfDatabase:SearchQuests(meta)
      end
      pfQuest:Debug(format("|cffff3333TIMER SearchQuests: %.4fs", GetTime() - t0))
    end
    this.updateQuestGivers = false
  end

  -- Turtle can send QUEST_LOG_UPDATE before a newly accepted quest has fully
  -- populated its objective data. Retry that one new entry shortly afterward
  -- so its map nodes and standalone tracker do not depend on opening the map.
  if this.questRetry and this.questRetry.at <= GetTime() then
    local retry = this.questRetry
    this.questRetry = nil
    local active = pfQuest.questlog[retry.questid]
    if active and active.qlogid == retry.qlogid and pfQuest_config["trackingmethod"] ~= 4 then
      -- This pass exists only because Turtle can publish a NEW quest before
      -- its objectives are ready.  Keep the first successful render intact:
      -- AddNode merges matching coordinates, while deleting here could erase
      -- a valid objective set when the delayed payload is still incomplete.
      -- Regular RELOAD events retain the full delete-and-rebuild behavior.
      local retryMeta = { ["addon"] = "PFQUEST", ["qlogid"] = retry.qlogid }
      local usedHDB = pfDatabase:SearchQuestIDHDB(retry.questid, retryMeta)
      local retryMaps = usedHDB and nil or pfDatabase:SearchQuestID(retry.questid, retryMeta)
      -- Current Zone Only normally receives entries while UpdateNodes walks
      -- rendered pins. Confirm the quest is truly in the log before adding a
      -- same-zone fallback for item/object objectives.
      if tonumber(pfQuest_config["trackingmethod"]) == 5 then
        local currentMap = pfMap:GetMapID(GetCurrentMapContinent(), GetCurrentMapZone())
        local hasCurrentMap = usedHDB and pfDatabase:QuestHDBHasMapPin(retry.questid, retry.qlogid, currentMap)
          or (retryMaps and retryMaps[currentMap])
        if currentMap and hasCurrentMap then
          -- UpdateNodes rebuilds Current Zone Only from its visible pins. Keep
          -- confirmed item/object quests that belong to this map in a small
          -- map-scoped cache so that rebuild cannot immediately clear them.
          pfMap.currentZoneTracker = pfMap.currentZoneTracker or {}
          pfMap.currentZoneTracker[currentMap] = pfMap.currentZoneTracker[currentMap] or {}
          pfMap.currentZoneTracker[currentMap][retry.questid] = retry.title
        end
      end
      pfMap.queue_update = GetTime()
    end
  end

  -- The server can issue its final QUEST_LOG_UPDATE after the initial node
  -- scan. In Current Zone Only mode, rebuild the active quest nodes once the
  -- queue has been quiet for a moment. This is event-driven (not per frame)
  -- and leaves the tracker untouched.
  if this.currentZoneRefreshAt and this.currentZoneRefreshAt <= GetTime() and pfQuest.queueCount == 0 then
    this.currentZoneRefreshAt = nil
    if tonumber(pfQuest_config["trackingmethod"]) == 5 then
      for questid, data in pairs(pfQuest.questlog) do
        if type(questid) == "number" and data.qlogid then
          local refreshMeta = { ["addon"] = "PFQUEST", ["qlogid"] = data.qlogid }
          if not pfDatabase:SearchQuestIDHDB(questid, refreshMeta) then
            pfDatabase:SearchQuestID(questid, refreshMeta)
          end
        end
      end
      pfMap.queue_update = GetTime()
    end
  end

  if pfQuest.queueCount == 0 then
    return
  end

  -- process queue
  for id, entry in pairs(this.queue) do
    -- HDB can update one accepted quest from its cached starter set. The Lua
    -- fallback still needs the established complete refresh.
    if entry[4] == "NEW" then
      if not (type(pfDatabase.MarkQuestAcceptedHDB) == "function"
        and pfDatabase:MarkQuestAcceptedHDB(entry[2])) then
        this.needsQuestGiverUpdate = true
      end
    end

    -- Async same-title resolution first indexes a log entry by its visible
    -- title, then replaces that temporary key with the numeric quest ID. The
    -- old key appears in the queue as REMOVE even though the quest is still
    -- active. Do not let that bookkeeping transition erase nodes just rendered
    -- for the resolved ID (both entries deliberately share the same title).
    local identityRekey = false
    if entry[4] == "REMOVE" and type(entry[2]) == "string" then
      for activeID, active in pairs(pfQuest.questlog or {}) do
        if type(activeID) == "number" and active and active.title == entry[1] then
          identityRekey = true
          break
        end
      end
    end

    -- remove quest
    if identityRekey then
      pfQuest:Debug("HearthDB resolved quest identity: " .. entry[1])
    elseif entry[4] == "REMOVE" then
      local canonicalTitle = GetCanonicalQuestTitle(entry[2])
      local abandoned = entry[1] == pfQuest.abandon
        or (pfQuest.abandonID and tonumber(entry[2]) == pfQuest.abandonID)
      if abandoned then pfQuest.abandonTraceQuestID = tonumber(entry[2]) end
      pfQuest:TraceAbandon("QUEUE REMOVE id=" .. tostring(entry[2])
        .. " abandoned=" .. tostring(abandoned and true or false)
        .. " hookID=" .. tostring(pfQuest.abandonID)
        .. " hookTitle=" .. tostring(pfQuest.abandon))
      pfDatabase:ClearQuestHDBCache(entry[2])
      pfQuest:Debug("|cffff5555Remove Quest: " .. entry[1] .. " (" .. entry[2] .. ")")

      -- write pfQuest.questlog history
      if abandoned then
        pfQuest_history[entry[2]] = nil
      elseif not (pfQuestCompat.optional and pfQuestCompat.optional.questEvents) then
        -- Legacy clients expose only a generic log removal, so completion must
        -- still be inferred there. Enhanced clients report QUEST_TURNED_IN with
        -- the exact numeric ID above; do not let an unrelated removal or a
        -- missed abandon marker create a false completion on those clients.
        pfQuest_history[entry[2]] = { time(), UnitLevel("player") }
      end
      -- Mark journal dirty when history changes
      if pfJournal then
        pfJournal.dirty = true
      end

      if pfQuest_config["trackingmethod"] ~= 4 then
        -- delete nodes by title
        local t0 = GetTime()
        pfMap:DeleteNode("PFQUEST", entry[1])

        -- also delete nodes by quest ids for servers with different names
        if canonicalTitle then pfMap:DeleteNode("PFQUEST", canonicalTitle) end
        pfQuest:Debug(format("|cffffff00TIMER DeleteNode(REMOVE): %.4fs", GetTime() - t0))
      end

      if abandoned and type(pfDatabase.RestoreAbandonedQuestGiverHDB) == "function"
        and pfDatabase:RestoreAbandonedQuestGiverHDB(entry[2], { addon = "PFQUEST" }) then
        -- The single cached quest was restored without scanning every giver.
      elseif not abandoned and type(pfDatabase.RefreshCompletedQuestGiversHDB) == "function"
        and pfDatabase:RefreshCompletedQuestGiversHDB(entry[2], { addon = "PFQUEST" }) then
        -- Only direct follow-ups can become newly eligible after this turn-in.
      else
        -- Keep the complete eligibility refresh as the compatibility fallback.
        this.needsQuestGiverUpdate = true
      end
      -- A quest-log update can remove multiple entries in one unordered batch.
      -- Preserve the abandon identity across unrelated removals and consume it
      -- only after the matching quest has taken the abandon restoration path.
      if abandoned then
        pfQuest.abandon = ""
        pfQuest.abandonID = nil
      end
    elseif entry[4] == "REINDEX" then
      pfQuest:Debug("Reindex Quest: " .. entry[1] .. " (" .. entry[2] .. ")")
      if pfMap and pfMap.nodes and pfMap.nodes.PFQUEST then
        for _, coordinates in pairs(pfMap.nodes.PFQUEST) do
          for _, titles in pairs(coordinates) do
            for _, node in pairs(titles) do
              if node and tonumber(node.questid) == tonumber(entry[2]) then
                node.qlogid = entry[3]
              end
            end
          end
        end
      end
      if pfDatabase and pfDatabase.ReindexQuestHDBCache then
        pfDatabase:ReindexQuestHDBCache(entry[2], entry[3])
      end
      pfMap.queue_update = GetTime()
    else
      if entry[4] == "NEW" then
        pfQuest:Debug("|cff55ff55New Quest: " .. entry[1] .. " (" .. entry[2] .. ")")
      else
        pfQuest:Debug("|cffffff55Update Quest: " .. entry[1] .. " (" .. entry[2] .. ")")
      end

      -- update quest nodes
      if pfQuest_config["trackingmethod"] ~= 4 then
        -- delete node by title
        local t0 = GetTime()
        pfMap:DeleteNode("PFQUEST", entry[1])

        -- delete nodes by quest ids for servers with different names
        local canonicalTitle = GetCanonicalQuestTitle(entry[2])
        if canonicalTitle then pfMap:DeleteNode("PFQUEST", canonicalTitle) end
        pfQuest:Debug(format("|cffffff00TIMER DeleteNode(NEW/RELOAD): %.4fs", GetTime() - t0))

        -- skip quest objective detection on manual and tracked mode
        if
          pfQuest_config["trackingmethod"] ~= 3
          and (pfQuest_config["trackingmethod"] ~= 2 or IsQuestWatched(entry[3]))
        then
          local meta = { ["addon"] = "PFQUEST", ["qlogid"] = entry[3] }
          local t1 = GetTime()
          -- HearthDB owns active-quest map nodes when enabled. A failed or
          -- unavailable native query immediately falls back to normal pfQuest.
          if not pfDatabase:SearchQuestIDHDB(entry[2], meta) then
            pfDatabase:SearchQuestID(entry[2], meta)
          end
          -- SearchQuestID marks map nodes dirty, but does not itself request a
          -- render. Queue one after the quest batch settles so the tracker
          -- receives newly found same-zone objectives immediately.
          pfMap.queue_update = GetTime()
          if entry[4] == "NEW" then
            this.questRetry = {
              questid = entry[2],
              qlogid = entry[3],
              title = entry[1],
              at = GetTime() + 0.5,
            }
          end
          pfQuest:Debug(format("|cffff8800TIMER SearchQuestID: %.4fs", GetTime() - t1))
        end
      end
    end

    -- remove entry from queue and decrement counter
    pfQuest.queue[id] = nil
    pfQuest.queueCount = pfQuest.queueCount - 1

    -- only return when other entries exist
    -- otherwise, continue and update questgivers
    if pfQuest.queueCount > 0 then
      return
    end
  end

  -- trigger questgiver update only when needed
  if pfQuest.queueCount == 0 then
    this.updateQuestLog = true
    if this.needsQuestGiverUpdate then
      this.updateQuestGivers = true
      this.needsQuestGiverUpdate = false
    end

    -- An abandoned quest can shift several Quest Log rows, producing REMOVE
    -- plus multiple REINDEX entries. Wait until that complete batch has been
    -- applied, then perform one synchronous tracker/route/minimap rebuild from
    -- the restored cached starter instead of showing several staggered states.
    if this.immediateAbandonRefresh then
      this:TraceAbandon("QUEUE settled: immediate redraw")
      this.immediateAbandonRefresh = nil
      pfMap.queue_update = nil
      pfMap.xPlayer = nil
      pfMap.minimapTick = nil
      pfMap:UpdateNodes()
      pfMap:UpdateMinimap()
      local traceID = this.abandonTraceQuestID
      local stored, shown = 0, 0
      for _, maps in pairs((pfMap.nodes and pfMap.nodes.PFQUEST) or {}) do
        for _, titles in pairs(maps) do
          for _, node in pairs(titles) do
            if tonumber(node.questid) == traceID then stored = stored + 1 end
          end
        end
      end
      for _, pin in pairs(pfMap.mpins or {}) do
        if pin:IsShown() and tonumber(pin.questid) == traceID then shown = shown + 1 end
      end
      this:TraceAbandon("REDRAW id=" .. tostring(traceID)
        .. " stored=" .. stored .. " minimapShown=" .. shown)
    end
  end
end)

local questlog_flip, questlog_flop = {}, {}
function pfQuest:UpdateQuestlog()
  -- initialize flip flop if not yet defined
  pfQuest.questlog_tmp = pfQuest.questlog_tmp or questlog_flip

  local _, numQuests = GetNumQuestLogEntries()
  local found = 0
  local change = nil

  -- iterate over all quests
  for qlogid = 1, 40 do
    local title, _, _, header, _, complete = compat.GetQuestLogTitle(qlogid)
    local objectives = GetNumQuestLeaderBoards(qlogid)
    local watched, questid, state

    if title and not header then
      -- A legacy same-title lookup can select hidden quest rows. While the
      -- Quest Log is open, keep background refreshes read-only so collapsed
      -- categories remain collapsed through progress and completion updates.
      local preserveSelection = QuestLogFrame and QuestLogFrame:IsShown()
      local resolved = pfDatabase:GetQuestIDs(qlogid, preserveSelection)
      questid = resolved and tonumber(resolved[1])
      if not questid then
        -- Removing a quest shifts every row below it. HDB title resolution can
        -- be pending for one scan during that transition; replacing an
        -- existing numeric key with the title would emit a false REMOVE and
        -- delete that quest's completed minimap marker. Reuse the prior ID
        -- only when the active title identifies exactly one numeric quest.
        local priorID
        for activeID, active in pairs(pfQuest.questlog) do
          if type(activeID) == "number" and active and active.title == title then
            if priorID then
              priorID = nil
              break
            end
            priorID = activeID
          end
        end
        questid = priorID or title
      end
      watched = IsQuestWatched(qlogid)

      -- build state string using table.concat (avoid string concat garbage)
      -- Completion can change without adding or removing objective rows (for
      -- example, a simple talk/report quest). Keep it in the change token so
      -- its ender pin is rebuilt from the client state.
      local stateParts = { watched and "track" or "", complete and "complete" or "incomplete" }
      if objectives then
        for i = 1, objectives, 1 do
          local text, _, done = compat.GetQuestLogLeaderBoard(i, qlogid)
          stateParts[getn(stateParts) + 1] = i
          stateParts[getn(stateParts) + 1] = text or ""
          stateParts[getn(stateParts) + 1] = done and "done" or "todo"
        end
      end
      state = concat(stateParts)

      -- add new quest to the questlog
      if not pfQuest.questlog[questid] then
        queueAdd({ title, questid, qlogid, "NEW" })
        pfQuest.questlog_tmp[questid] = {
          title = title,
          qlogid = qlogid,
          state = state,
        }
        change = true
      elseif pfQuest.questlog[questid].qlogid ~= qlogid then
        -- Accepting one quest can shift the Quest Log index of every quest
        -- below it. The quest data itself has not changed, so keep its map
        -- nodes and update only the index used for live objective reads.
        queueAdd({ title, questid, qlogid, "REINDEX" })
        pfQuest.questlog_tmp[questid] = pfQuest.questlog[questid]
        pfQuest.questlog_tmp[questid].qlogid = qlogid
        pfQuest.questlog_tmp[questid].state = state
        change = true
      elseif pfQuest.questlog[questid].state ~= state then
        queueAdd({ title, questid, qlogid, "RELOAD" })
        pfQuest.questlog_tmp[questid] = pfQuest.questlog[questid]
        pfQuest.questlog_tmp[questid].qlogid = qlogid
        pfQuest.questlog_tmp[questid].state = state
        change = true
      else
        pfQuest.questlog_tmp[questid] = pfQuest.questlog[questid]
      end

      found = found + 1
      if found >= numQuests then
        break
      end
    end
  end

  -- quest removal events
  for questid, data in pairs(pfQuest.questlog) do
    if not pfQuest.questlog_tmp[questid] then
      queueAdd({ data.title, questid, nil, "REMOVE" })
      change = true
    end
  end

  -- set questlog to current flip flop
  pfQuest.questlog = pfQuest.questlog_tmp

  -- switch tmp to the other flip flop
  if pfQuest.questlog_tmp == questlog_flip then
    pfQuest.questlog_tmp = questlog_flop
  else
    pfQuest.questlog_tmp = questlog_flip
  end

  -- clear next temporary questlog entries
  for k, v in pairs(pfQuest.questlog_tmp) do
    pfQuest.questlog_tmp[k] = nil
  end

  return change
end

function pfQuest:ResetAll()
  -- force reload all quests
  pfMap:DeleteNode("PFQUEST")
  if pfDatabase and pfDatabase.ClearHDBQuestGiverCache then pfDatabase:ClearHDBQuestGiverCache() end
  pfQuest.questlog = {}
  pfQuest.updateQuestLog = true
  pfQuest.updateQuestGivers = true
  -- pfMap.nodes["PFQUEST"] is now empty; tell SearchQuests to start fresh
  if pfDatabase then
    for id in pairs(pfDatabase.lastQuestGiversSet) do
      pfDatabase.lastQuestGiversSet[id] = nil
    end
  end
end

-- register popup dialog to copy urls
StaticPopupDialogs["PFQUEST_URLCOPY"] = {
  text = "|cff33ffccpf|cffffffffQuest " .. pfQuest_Loc["Online Search"],
  button1 = "Close",
  hasEditBox = 1,
  hasWideEditBox = 1,
  timeout = 0,
  exclusive = 1,
  whileDead = 1,
  hideOnEscape = 1,
  OnShow = function()
    local editBox = _G[this:GetName() .. "WideEditBox"]
    editBox:SetText(StaticPopupDialogs["PFQUEST_URLCOPY"].data)
    editBox:HighlightText()
  end,
  OnHide = function()
    _G[this:GetName() .. "WideEditBox"]:SetText("")
  end,
  EditBoxOnEnterPressed = function()
    this:GetParent():Hide()
  end,
  EditBoxOnEscapePressed = function()
    this:GetParent():Hide()
  end,
  EditBoxOnTextChanged = function()
    this:SetText(StaticPopupDialogs["PFQUEST_URLCOPY"].data)
    this:HighlightText()
  end,
}

function pfQuest:AddQuestLogIntegration()
  if pfQuest_config["questlogbuttons"] == "0" then
    return
  end

  local dockFrame = EQL3_QuestLogDetailScrollChildFrame
    or ShaguQuest_QuestLogDetailScrollChildFrame
    or QuestLogDetailScrollChildFrame
  local dockTitle = EQL3_QuestLogDescriptionTitle
    or ShaguQuest_QuestLogDescriptionTitle
    or pfQuestCompat.QuestLogDescriptionTitle

  dockTitle:SetHeight(dockTitle:GetHeight() + 30)
  dockTitle:SetJustifyV("BOTTOM")

  pfQuest.buttonOnline = pfQuest.buttonOnline or CreateFrame("Button", "pfQuestOnline", dockFrame)
  pfQuest.buttonOnline:SetParent(UIParent)
  pfQuest.buttonOnline:SetFrameStrata("DIALOG")
  pfQuest.buttonOnline:SetFrameLevel(100)
  pfQuest.buttonOnline:SetWidth(18)
  pfQuest.buttonOnline:SetHeight(15)
  pfQuest.buttonOnline:ClearAllPoints()
  pfQuest.buttonOnline:SetPoint("RIGHT", QuestLogQuestCount, "LEFT", -30, 0)
  pfQuest.buttonOnline:SetScript("OnClick", function()
    if pfUI and pfUI.chat then
      pfUI.chat.urlcopy.text:SetText(pfQuest:GetDatabaseURL() .. (this:GetID() or 0))
      pfUI.chat.urlcopy:Show()
    else
      StaticPopupDialogs["PFQUEST_URLCOPY"].data = pfQuest:GetDatabaseURL() .. (this:GetID() or 0)
      local dialog = StaticPopup_Show("PFQUEST_URLCOPY")
      _G[dialog:GetName() .. "Button1"]:ClearAllPoints()
      _G[dialog:GetName() .. "Button1"]:SetPoint("BOTTOM", dialog, "BOTTOM", 0, 16)
      _G[dialog:GetName() .. "WideEditBox"]:SetScript("OnTextChanged", StaticPopup_EditBoxOnTextChanged)
      dialog:SetWidth(420)
    end
  end)

  pfQuest.buttonOnline.txt = pfQuest.buttonOnline:CreateFontString("pfQuestIDButton", "HIGH", "GameFontWhite")
  pfQuest.buttonOnline.txt:SetAllPoints(pfQuest.buttonOnline)
  pfQuest.buttonOnline.txt:SetJustifyH("RIGHT")
  pfQuest.buttonOnline.txt:SetText("|cff000000[|cffaa2222?|cff000000]")

  pfQuest.buttonLanguage = pfQuest.buttonLanguage or CreateFrame("Button", "pfQuestLanguage", dockFrame)
  pfQuest.buttonLanguage:SetParent(UIParent)
  pfQuest.buttonLanguage:SetFrameStrata("DIALOG")
  pfQuest.buttonLanguage:SetFrameLevel(100)
  pfQuest.buttonLanguage:SetWidth(75)
  pfQuest.buttonLanguage:SetHeight(15)
  pfQuest.buttonLanguage:ClearAllPoints()
  pfQuest.buttonLanguage:SetPoint("RIGHT", pfQuest.buttonOnline, "LEFT", 0, 0)

  pfQuest.buttonLanguage.txt = pfQuest.buttonLanguage:CreateFontString("pfQuestIDButton", "HIGH", "GameFontWhite")
  pfQuest.buttonLanguage.txt:SetAllPoints(pfQuest.buttonLanguage)
  pfQuest.buttonLanguage.txt:SetJustifyH("RIGHT")
  pfQuest.buttonLanguage.txt:SetText("|cff000000[|cff3333ff" .. pfQuest_Loc["Translate"] .. "|cff000000]")

  -- ARIALN.TTF is bundled with the 1.12 client and includes Cyrillic glyphs.
  -- Keep the replacement scoped to the quest-log text that pfQuest translates.
  local translationFontStrings = {
    EQL3_QuestLogQuestTitle or pfQuestCompat.QuestLogQuestTitle,
    EQL3_QuestLogObjectivesText or pfQuestCompat.QuestLogObjectivesText,
    EQL3_QuestLogQuestDescription or pfQuestCompat.QuestLogQuestDescription,
  }
  local translationFonts = {}
  for index, fontString in ipairs(translationFontStrings) do
    local font, size, flags = fontString:GetFont()
    translationFonts[index] = { font = font, size = size, flags = flags }
  end

  local function SetQuestTranslationFont(language)
    if pfQuest.translationFontLanguage == language then return end

    for index, fontString in ipairs(translationFontStrings) do
      local original = translationFonts[index]
      if language == "ruRU" then
        fontString:SetFont("Fonts\\ARIALN.TTF", original.size, original.flags)
      else
        fontString:SetFont(original.font, original.size, original.flags)
      end
    end

    pfQuest.translationFontLanguage = language
  end

  pfQuest.buttonLanguage:SetScript("OnClick", function()
    UIDropDownMenu_Initialize(self, function()
      local func = function()
        pfQuest_config.translate = this.value
      end
      local info = {}
      info.text = "|cffaaaaaa" .. pfQuest_Loc["Reset Language"]
      info.value = nil
      info.func = func
      UIDropDownMenu_AddButton(info)

      for loc, caption in pairs(pfDB.locales) do
        local info = {}
        info.text = caption
        info.value = loc
        info.func = func
        UIDropDownMenu_AddButton(info)
      end
    end)
    ToggleDropDownMenu(1, nil, self, "cursor", 3, -3)
  end)

  local hdbQuestLogText = {}
  local hdbQuestLogPending = {}
  local hdbQuestLogFailed = {}
  local function ApplyQuestLogText(record)
    if not record then return end
    local QuestLogQuestTitle = EQL3_QuestLogQuestTitle or pfQuestCompat.QuestLogQuestTitle
    local QuestLogObjectivesText = EQL3_QuestLogObjectivesText or pfQuestCompat.QuestLogObjectivesText
    local QuestLogQuestDescription = EQL3_QuestLogQuestDescription or pfQuestCompat.QuestLogQuestDescription
    local QuestLogDetailScrollFrame = EQL3_QuestLogDetailScrollFrame or QuestLogDetailScrollFrame

    QuestLogQuestTitle:SetText(pfDatabase:FormatQuestText(record.title or ""))
    QuestLogObjectivesText:SetText(pfDatabase:FormatQuestText(record.objective or ""))
    QuestLogQuestDescription:SetText(pfDatabase:FormatQuestText(record.description or ""))
    QuestLogDetailScrollFrame:UpdateScrollChildRect()
  end

  local function ApplyLuaQuestLogText(id, lang)
    local texts = id and pfDB["quests"][lang] and pfDB["quests"][lang][id]
    if not texts then return end
    ApplyQuestLogText({
      title = texts["T"],
      objective = texts["O"],
      description = texts["D"],
    })
  end

  pfQuest.buttonLanguage:SetScript("OnUpdate", function()
    -- The controls live on UIParent so they can sit in pfUI's header. Never
    -- leave them behind if another addon closes the Quest Log without hiding
    -- its frame through the normal path.
    if not QuestLogFrame:IsShown() then
      pfQuest.buttonOnline:Hide()
      pfQuest.buttonLanguage:Hide()
      return
    end

    local id = pfQuest.buttonOnline:GetID()
    local lang = pfQuest_config.translate

    if this.translate ~= pfQuest_config.translate then
      pfQuest.buttonLanguage.txt:SetText(
        "|cff000000[|cff3333ff"
          .. (pfDB.locales[pfQuest_config.translate] or "|cff3333ff" .. pfQuest_Loc["Translate"])
          .. "|cff000000]"
      )
      this.translate = pfQuest_config.translate
      SetQuestTranslationFont(pfQuest_config.translate)
      QuestLog_UpdateQuestDetails(true)
      return
    end

    if id and lang == "enUS" and type(pfDatabase.GetQuestTextHDB) == "function" then
      if hdbQuestLogText[id] then
        ApplyQuestLogText(hdbQuestLogText[id])
        return
      elseif not hdbQuestLogPending[id] and not hdbQuestLogFailed[id] then
        hdbQuestLogPending[id] = true
        local selectedID, selectedLang = id, lang
        local accepted = pfDatabase:GetQuestTextHDB(id, function(record, err)
          hdbQuestLogPending[selectedID] = nil
          if record then
            hdbQuestLogText[selectedID] = record
            if QuestLogFrame:IsShown() and pfQuest.buttonOnline:GetID() == selectedID
              and pfQuest_config.translate == selectedLang then
              ApplyQuestLogText(record)
            end
          else
            hdbQuestLogFailed[selectedID] = true
          end
        end)
        if accepted then return end
        hdbQuestLogPending[id] = nil
        hdbQuestLogFailed[id] = true
      end
    end

    -- Non-English translations and unavailable native records retain the
    -- established Lua localization path.
    ApplyLuaQuestLogText(id, lang)
  end)

  -- pfUI finishes its Quest Log layout during OnShow. Refresh afterwards so
  -- the language and database-link controls are visible on the first open.
  if not pfQuest.questLogOnShowHook then
    local function HookFrameScript(frame, script, handler)
      -- Some Turtle clients expose HookScript as a non-callable frame field.
      -- Preserve the existing script and append ours directly instead.
      local previous = frame:GetScript(script)
      frame:SetScript(script, function()
        if previous then previous() end
        handler()
      end)
    end

    HookFrameScript(QuestLogFrame, "OnShow", function()
      pfQuest.questLogOpenRefreshAt = GetTime() + 0.15
    end)
    HookFrameScript(QuestLogFrame, "OnHide", function()
      pfQuest.buttonOnline:Hide()
      pfQuest.buttonLanguage:Hide()
    end)
    HookFrameScript(QuestLogFrameCloseButton, "OnClick", function()
      pfQuest.buttonOnline:Hide()
      pfQuest.buttonLanguage:Hide()
    end)
    pfQuest.questLogOnShowHook = true
  end

  pfQuest.buttonShow = pfQuest.buttonShow or CreateFrame("Button", "pfQuestShow", dockFrame, "UIPanelButtonTemplate")
  pfQuest.buttonShow:SetWidth(70)
  pfQuest.buttonShow:SetHeight(20)
  pfQuest.buttonShow:SetText(pfQuest_Loc["Show"])
  pfQuest.buttonShow:SetPoint("TOP", dockTitle, "TOP", -110, 0)
  pfQuest.buttonShow:SetScript("OnClick", function()
    local questIndex = compat.GetQuestLogSelection()
    local questids = pfDatabase:GetQuestIDs(questIndex)
    local title, _, _, header, _, complete = compat.GetQuestLogTitle(questIndex)
    local id = questids and tonumber(questids[1])
    if header or not id then
      return
    end

    local maps, meta = {}, { ["addon"] = "PFQUEST", ["qlogid"] = questIndex }
    if type(pfDatabase.SearchQuestIDHDB) == "function" and pfDatabase:SearchQuestIDHDB(id, meta) then
      -- Native quest rows can exist without a matching entry in the legacy
      -- Lua table. Wait for the HDB start/end hub lookup before opening the
      -- map; static data remains the fallback for non-HDB or incomplete rows.
      local fallbackMap = pfQuest:GetQuestHubMap(id)
      if type(pfDatabase.GetQuestHubMapHDB) == "function"
        and pfDatabase:GetQuestHubMapHDB(id, function(hubMap)
          pfMap:ShowMapID(hubMap or fallbackMap)
        end) then
        return
      end
      pfMap:ShowMapID(fallbackMap)
      return
    end
    maps = pfDatabase:SearchQuestID(id, meta, maps)
    pfMap:ShowMapID(pfQuest:GetQuestHubMap(id) or pfDatabase:GetBestMap(maps))
  end)

  pfQuest.buttonHide = pfQuest.buttonHide or CreateFrame("Button", "pfQuestHide", dockFrame, "UIPanelButtonTemplate")
  pfQuest.buttonHide:SetWidth(70)
  pfQuest.buttonHide:SetHeight(20)
  pfQuest.buttonHide:SetText(pfQuest_Loc["Hide"])
  pfQuest.buttonHide:SetPoint("TOP", dockTitle, "TOP", -37, 0)
  pfQuest.buttonHide:SetScript("OnClick", function()
    local questIndex = compat.GetQuestLogSelection()
    local title, _, _, header, _, complete = compat.GetQuestLogTitle(questIndex)
    if header then
      return
    end

    pfMap:DeleteNode("PFQUEST", title)
  end)

  pfQuest.buttonClean = pfQuest.buttonClean or CreateFrame("Button", "pfQuestClean", dockFrame, "UIPanelButtonTemplate")
  pfQuest.buttonClean:SetWidth(70)
  pfQuest.buttonClean:SetHeight(20)
  pfQuest.buttonClean:SetText(pfQuest_Loc["Clean"])
  pfQuest.buttonClean:SetPoint("TOP", dockTitle, "TOP", 37, 0)
  pfQuest.buttonClean:SetScript("OnClick", function()
    pfMap:DeleteNode("PFQUEST")
    -- A manually selected map pin owns the route arrow until its explicit
    -- target is cleared. Cleaning the pins must also release that target and
    -- discard the cached route to the now-hidden quest marker.
    if pfQuest.route then
      pfQuest.route.SetTarget(nil)
      pfQuest.route:Clear()
    end
  end)

  pfQuest.buttonReset = pfQuest.buttonReset or CreateFrame("Button", "pfQuestReset", dockFrame, "UIPanelButtonTemplate")
  pfQuest.buttonReset:SetWidth(70)
  pfQuest.buttonReset:SetHeight(20)
  pfQuest.buttonReset:SetText(pfQuest_Loc["Reset"])
  pfQuest.buttonReset:SetPoint("TOP", dockTitle, "TOP", 110, 0)
  pfQuest.buttonReset:SetScript("OnClick", function()
    pfQuest:ResetAll()
  end)

  -- use pfUI buttons in native mode
  if not pfUI.api.emulated then
    pfUI.api.SkinButton(pfQuest.buttonShow)
    pfUI.api.SkinButton(pfQuest.buttonHide)
    pfUI.api.SkinButton(pfQuest.buttonClean)
    pfUI.api.SkinButton(pfQuest.buttonReset)
  end
end

function pfQuest:AddWorldMapIntegration()
  if pfQuest_config["worldmapmenu"] == "0" then
    return
  end

  -- Quest Display Selection
  pfQuest.mapButton = CreateFrame("Frame", "pfQuestMapDropdown", WorldMapButton, "UIDropDownMenuTemplate")
  pfQuest.mapButton:ClearAllPoints()
  pfQuest.mapButton:SetPoint("TOPRIGHT", 0, -10)
  pfQuest.mapButton:SetScript("OnShow", function()
    pfQuest.mapButton.current = tonumber(pfQuest_config["trackingmethod"])
    -- Version 8.0.23 briefly exposed a sixth filter while it was being
    -- evaluated.  It was removed before release, but that value can remain
    -- in a test character's saved settings.  A dropdown with no matching
    -- entry keeps whatever text it last drew (often a zone name), so repair
    -- the setting before building the menu.
    if not pfQuest.mapButton.current or pfQuest.mapButton.current < 1 or pfQuest.mapButton.current > 5 then
      pfQuest.mapButton.current = 1
      pfQuest_config["trackingmethod"] = "1"
    end
    pfQuest.mapButton:UpdateMenu()
    -- This is a custom dropdown, so pfUI's map module never sees it during
    -- its normal Blizzard-control skin pass. Skin it after initialization to
    -- match the Continent and Zone selectors without requiring pfUI on clean
    -- clients.
    if not pfQuest.mapButton.pfUISkinned and pfUI and pfUI.api and pfUI.api.SkinDropDown then
      pfUI.api.SkinDropDown(pfQuest.mapButton, nil, nil, nil, true)
      pfQuest.mapButton.pfUISkinned = true
    end
  end)

  pfQuest.mapButton.point = "TOPLEFT"
  pfQuest.mapButton.relativePoint = "BOTTOMLEFT"

  -- Keep the available-quest difficulty filter with the other World Map
  -- controls. It belongs to the map frame rather than the zoomed map canvas,
  -- so Magnify cannot clip it when the map is scaled.
  pfQuest.mapLevelButton = CreateFrame("Frame", "pfQuestMapLevelDropdown", WorldMapFrame, "UIDropDownMenuTemplate")
  pfQuest.mapLevelButton.point = "TOPLEFT"
  pfQuest.mapLevelButton.relativePoint = "BOTTOMLEFT"
  pfQuest.mapLevelButton:SetFrameStrata(pfQuest.mapButton:GetFrameStrata())
  pfQuest.mapLevelButton:SetFrameLevel(pfQuest.mapButton:GetFrameLevel() + 10)
  local mapLevelTemplateButton = pfQuest.mapLevelButton.Button or _G["pfQuestMapLevelDropdownButton"]
  if mapLevelTemplateButton then
    mapLevelTemplateButton:SetFrameLevel(pfQuest.mapLevelButton:GetFrameLevel() + 2)
  end

  local function PositionMapLevelButton()
    if pfQuest.mapLevelButton.layoutAnchor ~= pfQuest.mapButton then
      pfQuest.mapLevelButton.layoutAnchor = pfQuest.mapButton
      pfQuest.mapLevelButton:ClearAllPoints()
      pfQuest.mapLevelButton:SetPoint("TOPRIGHT", pfQuest.mapButton, "BOTTOMRIGHT", 0, 0)
    end

    local filterMarkers = _G["ModernMapMarkersFilter_Blizz"]
    if filterMarkers and filterMarkers.pfQuestLayoutAnchor ~= pfQuest.mapLevelButton then
      filterMarkers.pfQuestLayoutAnchor = pfQuest.mapLevelButton
      filterMarkers:ClearAllPoints()
      filterMarkers:SetPoint("TOPRIGHT", pfQuest.mapLevelButton, "BOTTOMRIGHT", 0, 0)
    end
  end
  PositionMapLevelButton()

  local levelModes = {
    { value = "red", name = "Red", color = "|cffff2020" },
    { value = "orange", name = "Orange", color = "|cffff8040" },
    { value = "yellow", name = "Yellow", color = "|cffffff00" },
    { value = "green", name = "Green", color = "|cff40c040" },
    { value = "gray", name = "Grey", color = "|cff999999" },
  }

  local function GetSelectedLevelRange()
    local selected = pfQuest_config["questpinlevelrange"] or "off"
    if selected == "all" then
      selected = "off"
      pfQuest_config["questpinlevelrange"] = "off"
    end
    return selected
  end

  local function CreateLevelRangeEntries()
    local selected = GetSelectedLevelRange()
    local direction = pfQuest_config["questpinleveldirection"] == "higher" and "Higher" or "Lower"
    for index, mode in ipairs(levelModes) do
      -- Use a fresh table because the legacy dropdown reuses its row frames.
      local info = {}
      info.text = mode.color .. mode.name .. " & " .. direction .. "|r"
      info.value = mode.value
      info.checked = selected == mode.value
      info.func = function()
        local selectedValue = this and this.value
        if not selectedValue then return end
        local current = GetSelectedLevelRange()
        -- Clicking the active range again disables the feature and restores
        -- normal pfQuest high/low-level filtering.
        pfQuest_config["questpinlevelrange"] = current == selectedValue and "off" or selectedValue
        CloseDropDownMenus()
        pfQuest.mapLevelButton:UpdateMenu()
        pfQuest:ResetAll()
      end
      UIDropDownMenu_AddButton(info)
    end
  end

  -- Register the initializer once. Reinitializing a legacy dropdown while
  -- another window owns the shared dropdown rows can replace that window's
  -- labels with Level Range entries (for example, profession filters).
  UIDropDownMenu_Initialize(pfQuest.mapLevelButton, CreateLevelRangeEntries)

  function pfQuest.mapLevelButton:UpdateMenu()
    local selected = GetSelectedLevelRange()
    local selectedID
    for index, mode in ipairs(levelModes) do
      if selected == mode.value then selectedID = index end
    end

    pfQuest.mapLevelButton.current = selectedID
    if client >= 30300 then
      UIDropDownMenu_SetWidth(pfQuest.mapLevelButton, 120)
      UIDropDownMenu_SetButtonWidth(pfQuest.mapLevelButton, 125)
      UIDropDownMenu_JustifyText(pfQuest.mapLevelButton, "RIGHT")
    else
      UIDropDownMenu_SetWidth(120, pfQuest.mapLevelButton)
      UIDropDownMenu_SetButtonWidth(125, pfQuest.mapLevelButton)
      UIDropDownMenu_JustifyText("RIGHT", pfQuest.mapLevelButton)
    end
    pfQuest.mapLevelButton.currentLabel = "Level Range"
    local direction = pfQuest_config["questpinleveldirection"] == "higher" and "higher" or "lower"
    if pfQuest.mapLevelButton.directionArrow then
      pfQuest.mapLevelButton.directionArrow:SetText(direction == "higher" and "|cffffcc00^|r" or "|cffffcc00v|r")
    end
    -- Moving this control out of the map canvas prevents the legacy template
    -- from repainting its selected caption automatically.
    if client >= 30300 then
      UIDropDownMenu_SetText(pfQuest.mapLevelButton, "Level Range")
    else
      UIDropDownMenu_SetText("Level Range", pfQuest.mapLevelButton)
    end
    -- The stock template anchors its text to the map canvas. This dropdown is
    -- intentionally in WorldMapFrame, so anchor the existing text child to
    -- its own control instead of creating a separate display frame.
    local text = pfQuest.mapLevelButton.Text or _G["pfQuestMapLevelDropdownText"]
    local mapText = pfQuest.mapButton.Text or _G["pfQuestMapDropdownText"]
    if text then
      text:ClearAllPoints()
      text:SetPoint("RIGHT", pfQuest.mapLevelButton, "RIGHT", -42, 0)
      text:SetWidth(110)
      text:SetJustifyH("RIGHT")
      text:SetDrawLayer("OVERLAY")
      text:SetAlpha(1)
      text:SetText("Level Range")
      text:Show()
      if mapText and mapText.GetFont then
        local font, size, flags = mapText:GetFont()
        if font then text:SetFont(font, size, flags) end
        local r, g, b, a = mapText:GetTextColor()
        text:SetTextColor(r, g, b, a)
      end
      text:Show()
    end

  end

  local function ToggleLevelRangeDirection()
    local direction = pfQuest_config["questpinleveldirection"] == "higher" and "higher" or "lower"
    pfQuest_config["questpinleveldirection"] = direction == "higher" and "lower" or "higher"
    CloseDropDownMenus()
    pfQuest.mapLevelButton:UpdateMenu()
    if GetSelectedLevelRange() ~= "off" then pfQuest:ResetAll() end
  end

  local function ShowLevelRangeHelp(owner)
    GameTooltip:SetOwner(owner, "ANCHOR_LEFT")
    GameTooltip:SetText("Level Range")
    GameTooltip:AddLine("Right-click: Reverse direction", 1, 1, 1)
    GameTooltip:Show()
  end

  -- Keep the indicator above pfUI's dropdown backdrop and make the left-side
  -- marker itself usable for reversing the filter.
  pfQuest.mapLevelButton.directionIndicator = CreateFrame("Button", nil, pfQuest.mapLevelButton)
  pfQuest.mapLevelButton.directionIndicator:SetWidth(18)
  pfQuest.mapLevelButton.directionIndicator:SetHeight(18)
  pfQuest.mapLevelButton.directionIndicator:SetPoint("LEFT", pfQuest.mapLevelButton, "LEFT", 18, 1)
  pfQuest.mapLevelButton.directionIndicator:SetFrameStrata(pfQuest.mapLevelButton:GetFrameStrata())
  pfQuest.mapLevelButton.directionIndicator:SetFrameLevel(pfQuest.mapLevelButton:GetFrameLevel() + 20)
  pfQuest.mapLevelButton.directionIndicator:RegisterForClicks("RightButtonUp")
  pfQuest.mapLevelButton.directionIndicator:SetScript("OnClick", ToggleLevelRangeDirection)
  pfQuest.mapLevelButton.directionIndicator:SetScript("OnEnter", function() ShowLevelRangeHelp(this) end)
  pfQuest.mapLevelButton.directionIndicator:SetScript("OnLeave", function() GameTooltip:Hide() end)
  pfQuest.mapLevelButton.directionArrow = pfQuest.mapLevelButton.directionIndicator:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  pfQuest.mapLevelButton.directionArrow:SetAllPoints(pfQuest.mapLevelButton.directionIndicator)
  pfQuest.mapLevelButton.directionArrow:SetJustifyH("CENTER")

  local function ApplyMapLevelButtonSkin()
    if not (pfUI and pfUI.api and pfUI.api.SkinDropDown) then return end
    if not pfQuest.mapLevelButton.pfUISkinned then
      pfUI.api.SkinDropDown(pfQuest.mapLevelButton, nil, nil, nil, true)
      pfQuest.mapLevelButton.pfUISkinned = true
    end
  end

  local function SyncMapLevelScale()
    local parentScale = WorldMapFrame:GetEffectiveScale()
    local sourceScale = pfQuest.mapButton:GetEffectiveScale()
    if parentScale > 0 and sourceScale > 0 then
      pfQuest.mapLevelButton:SetScale(sourceScale / parentScale)
    end
  end

  pfQuest.mapLevelButton:SetScript("OnShow", function()
    PositionMapLevelButton()
    ApplyMapLevelButtonSkin()
    pfQuest.mapLevelButton:UpdateMenu()
    SyncMapLevelScale()
  end)

  -- The legacy dropdown reuses its list rows. Refresh their boolean checked
  -- state immediately before each open, rather than during a selection.
  local levelToggle = pfQuest.mapLevelButton.Button or _G["pfQuestMapLevelDropdownButton"]
  if levelToggle and not levelToggle.pfQuestLevelMenuHook then
    local previous = levelToggle:GetScript("OnClick")
    local previousEnter = levelToggle:GetScript("OnEnter")
    local previousLeave = levelToggle:GetScript("OnLeave")
    levelToggle:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    levelToggle:SetScript("OnClick", function()
      if arg1 == "RightButton" then
        ToggleLevelRangeDirection()
        return
      end
      pfQuest.mapLevelButton:UpdateMenu()
      if previous then previous() end
    end)
    levelToggle:SetScript("OnEnter", function()
      if previousEnter then previousEnter() end
      ShowLevelRangeHelp(this)
    end)
    levelToggle:SetScript("OnLeave", function()
      if previousLeave then previousLeave() end
      GameTooltip:Hide()
    end)
    levelToggle.pfQuestLevelMenuHook = true
  end

  pfQuest.mapLevelButton.lastMapScale = nil
  pfQuest.mapLevelButton:SetScript("OnUpdate", function()
    PositionMapLevelButton()
    local scale = pfQuest.mapButton:GetEffectiveScale()
    if scale ~= pfQuest.mapLevelButton.lastMapScale then
      pfQuest.mapLevelButton.lastMapScale = scale
      SyncMapLevelScale()
    end
  end)

  function pfQuest.mapButton:UpdateMenu()
    local function CreateEntries()
      local info = {}
      info.text = pfQuest_Loc["All Quests"]
      info.checked = false
      info.func = function()
        UIDropDownMenu_SetSelectedID(pfQuest.mapButton, this:GetID(), 0)
        pfQuest_config["trackingmethod"] = this:GetID()
        pfQuest:ResetAll()
      end
      UIDropDownMenu_AddButton(info)

      local info = {}
      info.text = pfQuest_Loc["Tracked Quests"]
      info.checked = false
      info.func = function()
        UIDropDownMenu_SetSelectedID(pfQuest.mapButton, this:GetID(), 0)
        pfQuest_config["trackingmethod"] = this:GetID()
        pfQuest:ResetAll()
      end
      UIDropDownMenu_AddButton(info)

      local info = {}
      info.text = pfQuest_Loc["Manual Selection"]
      info.checked = false
      info.func = function()
        UIDropDownMenu_SetSelectedID(pfQuest.mapButton, this:GetID(), 0)
        pfQuest_config["trackingmethod"] = this:GetID()
        pfQuest:ResetAll()
      end
      UIDropDownMenu_AddButton(info)

      local info = {}
      info.text = pfQuest_Loc["Hide Quests"]
      info.checked = false
      info.func = function()
        UIDropDownMenu_SetSelectedID(pfQuest.mapButton, this:GetID(), 0)
        pfQuest_config["trackingmethod"] = this:GetID()
        pfQuest:ResetAll()
      end
      UIDropDownMenu_AddButton(info)

      local info = {}
      info.text = pfQuest_Loc["Current Zone Only"] or "Current Zone Only"
      info.checked = false
      info.func = function()
        UIDropDownMenu_SetSelectedID(pfQuest.mapButton, this:GetID(), 0)
        pfQuest_config["trackingmethod"] = this:GetID()
        pfQuest:ResetAll()
      end
      UIDropDownMenu_AddButton(info)
    end

    UIDropDownMenu_Initialize(pfQuest.mapButton, CreateEntries)
    if client >= 30300 then
      UIDropDownMenu_SetWidth(pfQuest.mapButton, 120)
      UIDropDownMenu_SetButtonWidth(pfQuest.mapButton, 125)
      UIDropDownMenu_JustifyText(pfQuest.mapButton, "RIGHT")
    else
      UIDropDownMenu_SetWidth(120, pfQuest.mapButton)
      UIDropDownMenu_SetButtonWidth(125, pfQuest.mapButton)
      UIDropDownMenu_JustifyText("RIGHT", pfQuest.mapButton)
    end
    UIDropDownMenu_SetSelectedID(pfQuest.mapButton, pfQuest.mapButton.current)
  end
end

-- [[ Hook UI Functions ]] --
-- Set certain events on quest watch
local pfHookRemoveQuestWatch = RemoveQuestWatch
RemoveQuestWatch = function(questIndex)
  local ret = pfHookRemoveQuestWatch(questIndex)

  if questIndex then
    local title, _, _, header, _, complete = compat.GetQuestLogTitle(questIndex)
    pfMap:DeleteNode("PFQUEST", title)
  end

  pfQuest.updateQuestLog = true
  pfQuest.updateQuestGivers = true

  return ret
end

-- Set certain events on quest unwatch
local pfHookAddQuestWatch = AddQuestWatch
AddQuestWatch = function(questIndex)
  local ret = pfHookAddQuestWatch(questIndex)
  pfQuest.updateQuestLog = true
  pfQuest.updateQuestGivers = true
  return ret
end

-- Save the abandoned questname to remove from history
local HookAbandonQuest = AbandonQuest
AbandonQuest = function()
  pfQuest.abandon = GetAbandonQuestName()
  pfQuest.abandonID = nil
  local selected = compat.GetQuestLogSelection()
  for questID, state in pairs(pfQuest.questlog or {}) do
    if type(questID) == "number" and state and state.qlogid == selected then
      pfQuest.abandonID = questID
      break
    end
  end
  pfQuest:TraceAbandon("HOOK AbandonQuest id=" .. tostring(pfQuest.abandonID)
    .. " title=" .. tostring(pfQuest.abandon))
  HookAbandonQuest()
end

local function UpdateQuestLevel(button, id)
  local title, level, tag, header = compat.GetQuestLogTitle(id)
  if header or not title then
    return
  end
  button:SetText(" [" .. (level or "??") .. (tag and "+" or "") .. "] " .. title)
  if not QuestLogTitleButton_Resize then
    return
  end
  QuestLogTitleButton_Resize(button)
end

-- Update quest id button
local pfHookQuestLog_Update = QuestLog_Update
QuestLog_Update = function()
  pfHookQuestLog_Update()

  if pfQuest_config["questloglevel"] == "1" then
    if client >= 30300 then
      for i, button in pairs(QuestLogScrollFrame.buttons) do
        UpdateQuestLevel(button, button:GetID())
      end
    else
      for i = 1, QUESTS_DISPLAYED, 1 do
        UpdateQuestLevel(_G["QuestLogTitle" .. i], i + FauxScrollFrame_GetOffset(QuestLogListScrollFrame))
      end
    end
  end

  if pfQuest_config["questlogbuttons"] == "1" then
    -- Completion forces a QuestLog_Update while the log is visible. Keep this
    -- button refresh read-only so resolving an ambiguous quest cannot select a
    -- hidden row and expand its collapsed category.
    local preserveSelection = QuestLogFrame and QuestLogFrame:IsShown()
    local selectedQlogID = compat.GetQuestLogSelection()
    local questids = pfDatabase:GetQuestIDs(selectedQlogID, preserveSelection)
    local resolvedQuestID = questids and tonumber(questids[1])
    local selectedQuestIsActive
    if resolvedQuestID then
      local resolvedState = pfQuest.questlog and pfQuest.questlog[resolvedQuestID]
      selectedQuestIsActive = resolvedState and resolvedState.qlogid == selectedQlogID
      if not selectedQuestIsActive then
        -- Duplicate-title HDB resolution is asynchronous. The selected row can
        -- resolve one refresh before UpdateQuestlog rekeys its title entry to
        -- the numeric ID. The qlog index still proves this is the active row.
        for _, state in pairs(pfQuest.questlog or {}) do
          if state and state.qlogid == selectedQlogID then
            selectedQuestIsActive = true
            break
          end
        end
      end
    end
    if resolvedQuestID and selectedQuestIsActive then
      pfQuest.buttonOnline:SetID(resolvedQuestID)
      pfQuest.buttonOnline:Show()
      pfQuest.buttonLanguage:Show()
      -- enable buttons
      if pfQuest.buttonShow then pfQuest.buttonShow:Enable() end
      if pfQuest.buttonHide then pfQuest.buttonHide:Enable() end

      if pfQuest_config.showids == "1" then
        pfQuest.buttonOnline.txt:SetText("|cff000000[|cffaa2222id: " .. resolvedQuestID .. "|cff000000]")
        pfQuest.buttonOnline:SetWidth(pfQuest.buttonOnline.txt:GetStringWidth())
      end
    else
      pfQuest.buttonOnline:Hide()
      pfQuest.buttonLanguage:Hide()
      -- disable buttons
      if pfQuest.buttonShow then pfQuest.buttonShow:Disable() end
      if pfQuest.buttonHide then pfQuest.buttonHide:Disable() end
    end
  end
end

-- attach the new function to the scroll frame
if QuestLogScrollFrame then
  QuestLogScrollFrame.update = QuestLog_Update
end

-- refresh language and url on quest selection
local pfHookQuestLogTitleButton_OnClick = QuestLogTitleButton_OnClick
QuestLogTitleButton_OnClick = function(self, button)
  pfHookQuestLogTitleButton_OnClick(self, button)
  QuestLog_Update()
end

if not GetQuestLink then -- Allow to send questlinks from questlog
  local pfHookQuestLogTitleButton_OnClick = QuestLogTitleButton_OnClick
  QuestLogTitleButton_OnClick = function(button)
    local scrollFrame = EQL3_QuestLogListScrollFrame or ShaguQuest_QuestLogListScrollFrame or QuestLogListScrollFrame
    local questIndex = this:GetID() + FauxScrollFrame_GetOffset(scrollFrame)
    local questName, questLevel = compat.GetQuestLogTitle(questIndex)
    local questids = pfDatabase:GetQuestIDs(questIndex)
    local questid = questids and tonumber(questids[1]) or 0

    if IsShiftKeyDown() and not this.isHeader and ChatFrameEditBox:IsVisible() then
      pfQuestCompat.InsertQuestLink(questid, questName, questLevel)
      QuestLog_SetSelection(questIndex)
      QuestLog_Update()
      return
    end

    pfHookQuestLogTitleButton_OnClick(button)
  end

  -- Patch ItemRef to display Questlinks
  local pfQuestHookSetItemRef = SetItemRef
  local function DrawQuestLinkTooltip(id, questTitle, hasTitle, record)
    ItemRefTooltip:ClearLines()

    local title = record and record.title or questTitle
    local questlevel = record and tonumber(record.level)
    if title then
      local color = questlevel and pfQuestCompat.GetDifficultyColor(questlevel) or { r = 1, g = 1, b = 0 }
      ItemRefTooltip:AddLine(title, color.r, color.g, color.b)
    elseif hasTitle then
      ItemRefTooltip:AddLine(questTitle, 1, 1, 0)
    end

    local queststate = pfQuest_history[id] and 2 or 0
    queststate = pfQuest.questlog[id] and 1 or queststate
    if queststate == 0 then
      ItemRefTooltip:AddLine(pfQuest_Loc["You don't have this quest."] .. "\n\n", 1, 0.5, 0.5)
    elseif queststate == 1 then
      ItemRefTooltip:AddLine(pfQuest_Loc["You are on this quest."] .. "\n\n", 1, 1, 0.5)
    elseif queststate == 2 then
      ItemRefTooltip:AddLine(pfQuest_Loc["You already did this quest."] .. "\n\n", 0.5, 1, 0.5)
    end

    local objective = record and record.objective
    local description = record and record.description
    if objective and objective ~= "" then
      ItemRefTooltip:AddLine(pfDatabase:FormatQuestText(objective), 1, 1, 1, true)
    end
    if objective and objective ~= "" and description and description ~= "" then
      ItemRefTooltip:AddLine(" ", 0, 0, 0)
    end
    if description and description ~= "" then
      ItemRefTooltip:AddLine(pfDatabase:FormatQuestText(description), 0.8, 0.8, 0.8, true)
    end

    local minlevel = record and tonumber(record.minLevel)
    if questlevel or minlevel then ItemRefTooltip:AddLine(" ", 0, 0, 0) end
    if minlevel then
      local color = pfQuestCompat.GetDifficultyColor(minlevel)
      ItemRefTooltip:AddLine(
        "|cffffffff" .. pfQuest_Loc["Required Level"] .. ": |r" .. minlevel,
        color.r,
        color.g,
        color.b
      )
    end
    if questlevel then
      local color = pfQuestCompat.GetDifficultyColor(questlevel)
      ItemRefTooltip:AddLine(
        "|cffffffff" .. pfQuest_Loc["Quest Level"] .. ": |r" .. questlevel,
        color.r,
        color.g,
        color.b
      )
    end

    ItemRefTooltip:Show()
  end

  local function GetLuaQuestLinkRecord(id)
    local texts = id and pfDB["quests"]["loc"][id]
    local data = id and pfDB["quests"]["data"][id]
    if not texts then return nil end
    return {
      title = texts["T"], objective = texts["O"], description = texts["D"],
      level = data and data["lvl"], minLevel = data and data["min"],
    }
  end

  SetItemRef = function(link, text, button)
    local isQuest, _, id = string.find(link, "quest:(%d+):.*")
    local isQuest2, _, _ = string.find(link, "quest2:.*")

    if isQuest or isQuest2 then
      if IsShiftKeyDown() and ChatFrameEditBox:IsVisible() then
        ChatFrameEditBox:Insert(text)
        return
      end

      if ItemRefTooltip:IsShown() and ItemRefTooltip.pfQtext == text then
        HideUIPanel(ItemRefTooltip)
        return
      end

      ShowUIPanel(ItemRefTooltip)
      ItemRefTooltip:SetOwner(UIParent, "ANCHOR_PRESERVE")

      local _, _, questTitle = string.find(text or "", "%[([^%]]+)%]")
      if (not questTitle or questTitle == "") and isQuest2 then
        local _, _, linkedTitle = string.find(link or "", "^quest2:(.+)$")
        questTitle = linkedTitle
      end
      local hasTitle = questTitle and questTitle ~= ""

      id = tonumber(id)
      ItemRefTooltip.pfQtext = text

      local function LoadHDBQuestLink(resolvedID)
        if not resolvedID or resolvedID <= 0 or type(pfDatabase.GetQuestTextHDB) ~= "function" then return false end
        ItemRefTooltip:ClearLines()
        if hasTitle then ItemRefTooltip:AddLine(questTitle, 1, 1, 0) end
        ItemRefTooltip:Show()
        local requestedText = text
        local accepted = pfDatabase:GetQuestTextHDB(resolvedID, function(record, err)
          if not ItemRefTooltip:IsShown() or ItemRefTooltip.pfQtext ~= requestedText then return end
          DrawQuestLinkTooltip(resolvedID, questTitle, hasTitle, record or GetLuaQuestLinkRecord(resolvedID))
        end)
        return accepted and true or false
      end

      if not id or id == 0 then
        if questTitle and type(pfDatabase.GetQuestTextByTitleHDB) == "function" then
          local requestedText = text
          local accepted = pfDatabase:GetQuestTextByTitleHDB(questTitle, function(record, err)
            if not ItemRefTooltip:IsShown() or ItemRefTooltip.pfQtext ~= requestedText then return end
            local resolvedID = record and tonumber(record.id)
            DrawQuestLinkTooltip(resolvedID, questTitle, hasTitle, record or GetLuaQuestLinkRecord(resolvedID))
          end)
          if accepted then
            ItemRefTooltip:ClearLines()
            if hasTitle then ItemRefTooltip:AddLine(questTitle, 1, 1, 0) end
            ItemRefTooltip:Show()
            return
          end
        end
        for scanID, data in pairs(pfDB["quests"]["loc"]) do
          if data.T == questTitle then
            id = scanID
            break
          end
        end
      end

      if LoadHDBQuestLink(id) then return end

      DrawQuestLinkTooltip(id, questTitle, hasTitle, GetLuaQuestLinkRecord(id))
    else
      pfQuestHookSetItemRef(link, text, button)
    end
    ItemRefTooltip.pfQtext = text
  end
else
  -- patch itemref to show known quest levels on tbc
  local pfQuestHookSetItemRef = SetItemRef
  SetItemRef = function(link, text, button)
    pfQuestHookSetItemRef(link, text, button)

    -- skip modifier clicks
    if IsAltKeyDown() or IsControlKeyDown() or IsShiftKeyDown() then
      return
    end

    local quest, _, id = string.find(link, "quest:(%d+):.*")
    if not quest then
      return
    end
    id = tonumber(id)

    -- adjust text color to level color
    if id and id > 0 and pfDB["quests"]["loc"][id] then
      local questlevel = tonumber(pfDB["quests"]["data"][id]["lvl"])
      local color = pfQuestCompat.GetDifficultyColor(questlevel)
      ItemRefTooltipTextLeft1:SetTextColor(color.r, color.g, color.b)
    end

    -- add quest levels to tooltip
    if pfDB["quests"]["loc"][id] then
      ItemRefTooltip:AddLine(" ")

      if pfDB["quests"]["data"][id]["min"] then
        local questlevel = tonumber(pfDB["quests"]["data"][id]["min"])
        local color = pfQuestCompat.GetDifficultyColor(questlevel)
        ItemRefTooltip:AddLine(
          "|cffffffff" .. pfQuest_Loc["Required Level"] .. ": |r" .. questlevel,
          color.r,
          color.g,
          color.b
        )
      end

      if pfDB["quests"]["data"][id]["lvl"] then
        local questlevel = tonumber(pfDB["quests"]["data"][id]["lvl"])
        local color = pfQuestCompat.GetDifficultyColor(questlevel)
        ItemRefTooltip:AddLine(
          "|cffffffff" .. pfQuest_Loc["Quest Level"] .. ": |r" .. questlevel,
          color.r,
          color.g,
          color.b
        )
      end
    end

    ItemRefTooltip:Show()
  end
end
