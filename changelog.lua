-- Shared presentation; each edition supplies only its own small release list.
pfQuestChangelog = { sources = {} }
local changelog = pfQuestChangelog

function changelog:Register(addon, entries, edition)
  self.sources[addon] = entries
  if edition then self.edition = edition end
end

function changelog:BuildText()
  local entries, installed = {}, {}
  for _, addon in ipairs({ "pfQuest", "pfQuest-turtle" }) do
    if self.sources[addon] then
      local version = GetAddOnMetadata(addon, "Version") or "unknown"
      table.insert(installed, addon .. " " .. version)
      for index, entry in ipairs(self.sources[addon]) do
        table.insert(entries, { addon = addon, entry = entry, index = index })
      end
    end
  end
  table.sort(entries, function(a, b)
    if a.entry.date ~= b.entry.date then return a.entry.date > b.entry.date end
    if a.addon ~= b.addon then return a.addon < b.addon end
    return a.index < b.index
  end)
  local lines = { "|cffaaaaaaInstalled: " .. table.concat(installed, " / ") .. "|r", "" }
  for _, row in ipairs(entries) do
    local entry = row.entry
    table.insert(lines, "|cff33ffcc" .. row.addon .. " - " .. entry.version .. "|r")
    table.insert(lines, "|cffaaaaaa" .. entry.date .. "|r")
    for _, note in ipairs(entry.notes) do table.insert(lines, "- " .. note) end
    table.insert(lines, "")
  end
  return table.concat(lines, "\n")
end

function changelog:HasUnread()
  local read = pfQuest_global and pfQuest_global.changelogRead or {}
  for addon in pairs(self.sources) do
    local version = GetAddOnMetadata(addon, "Version")
    if version and version ~= "" then
      local key = (self.edition or "lua") .. ":" .. addon .. ":" .. version
      if not read[key] then return true end
    end
  end
  return false
end

function changelog:UpdateButton()
  local button = pfQuestConfig and pfQuestConfig.changelog
  if not button or not button.unreadBorder then return end
  if self:HasUnread() then button.unreadBorder:Show() else button.unreadBorder:Hide() end
end

function changelog:MarkRead()
  pfQuest_global = pfQuest_global or {}
  pfQuest_global.changelogRead = pfQuest_global.changelogRead or {}
  for addon in pairs(self.sources) do
    local version = GetAddOnMetadata(addon, "Version")
    if version and version ~= "" then
      local key = (self.edition or "lua") .. ":" .. addon .. ":" .. version
      pfQuest_global.changelogRead[key] = true
    end
  end
  self:UpdateButton()
end

function changelog:Announce()
  pfQuest_global = pfQuest_global or {}
  pfQuest_global.changelogSeen = pfQuest_global.changelogSeen or {}
  local seen, updated = pfQuest_global.changelogSeen, false
  for addon in pairs(self.sources) do
    local version = GetAddOnMetadata(addon, "Version")
    if version and version ~= "" then
      local key = (self.edition or "lua") .. ":" .. addon .. ":" .. version
      if not seen[key] then seen[key], updated = true, true end
    end
  end
  if updated then
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ffccpfQuest|r updated. Open Settings > Changelog to see what's new.")
  end
  self:UpdateButton()
end

function changelog:Show()
  if not self.window then
    local f = CreateFrame("Frame", "pfQuestChangelogWindow", UIParent)
    self.window = f
    f:Hide()
    f:SetWidth(580)
    f:SetHeight(430)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function() this:StartMoving() end)
    f:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
    pfUI.api.CreateBackdrop(f, nil, true, 0.9)
    table.insert(UISpecialFrames, "pfQuestChangelogWindow")

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -12)
    title:SetText("|cff33ffccpfQuest|r Changelog")
    local close = CreateFrame("Button", nil, f)
    close:SetWidth(24)
    close:SetHeight(24)
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -6)
    local label = close:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetAllPoints(close)
    label:SetText("|cffff4444X|r")
    close:SetScript("OnClick", function() f:Hide() end)
    pfUI.api.SkinButton(close)

    local scroll = CreateFrame("ScrollFrame", "pfQuestChangelogScroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -42)
    scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -36, 16)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetWidth(528)
    content:SetHeight(1)
    scroll:SetScrollChild(content)
    local text = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    text:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
    text:SetWidth(524)
    text:SetJustifyH("LEFT")
    text:SetJustifyV("TOP")
    text:SetTextColor(1, 1, 1)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function()
      local bar = getglobal("pfQuestChangelogScrollScrollBar")
      local low, high = bar:GetMinMaxValues()
      bar:SetValue(math.max(low, math.min(high, bar:GetValue() - arg1 * 36)))
    end)
    f:SetScript("OnShow", function()
      text:SetText(changelog:BuildText())
      local height = text.GetStringHeight and text:GetStringHeight() or text:GetHeight()
      content:SetHeight(math.max(1, height + 8))
      scroll:UpdateScrollChildRect()
      scroll:SetVerticalScroll(0)
      getglobal("pfQuestChangelogScrollScrollBar"):SetValue(0)
      changelog:MarkRead()
    end)
  end
  self.window:Show()
end

local notice = CreateFrame("Frame")
notice:RegisterEvent("PLAYER_LOGIN")
notice:SetScript("OnEvent", function()
  changelog:Announce()
  notice:UnregisterAllEvents()
end)
