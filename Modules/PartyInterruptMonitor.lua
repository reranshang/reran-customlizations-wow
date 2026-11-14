local _, ns = ...

local IsSecretValue, IsSecretTable = ns.IsSecretValue, ns.IsSecretTable
local settings, statusChanged, lastStatus
local initialized, listening = false, false
local eventFrame = CreateFrame("Frame")
local displayFrame, rows, castFrames = nil, {}, {}
local roster, byGUID, byUnit, petOwners = {}, {}, {}, {}
local cooldowns, revision = {}, 0
local specCache, invalidSpecs, inspectAttempts = {}, {}, {}
local pendingInspect, inspectTimer, nextInspectAt = nil, nil, 0
local shownCount, unknownCount = 0, 0
local pendings, meterHits, directCasts, guesses, enemySeen = {}, {}, {}, {}, {}
local meterSnap, specIcons = {}, {}
local lastMeterHit
local expiryTimer, selfTimer, generation = nil, nil, 0
local selfQueued, tickElapsed, layoutDirty = false, 0, false
local RefreshRoster, PumpInspect, RenderRoster, UpdateRows, SyncListening
local Pair, ArmExpiry, RefreshSelf, QueueSelf, StartTicker

local SIZE = {
    DEFAULT_WIDTH = 230, MIN_WIDTH = 100, MAX_WIDTH = 600,
    DEFAULT_HEIGHT = 24, MIN_HEIGHT = 12, MAX_HEIGHT = 80,
    DEFAULT_FONT_SIZE = 12, MIN_FONT_SIZE = 8, MAX_FONT_SIZE = 32,
    MIN_TEXT_OFFSET = -300, MAX_TEXT_OFFSET = 300,
    DEFAULT_DECIMAL_PLACES = 1,
}
local DEFAULT_MEDIA_KEY = "__default"
local DEFAULT_TEXTURE = "Interface\\Buttons\\WHITE8X8"
local DEFAULT_X, DEFAULT_Y, ICON_GAP, ROW_SPACING = 260, 120, 2, 4
local appearance = { texture = DEFAULT_TEXTURE, timerFormat = "%.1f" }

local INSPECT_INTERVAL, INSPECT_TIMEOUT, MAX_INSPECT_ATTEMPTS = 2, 5, 2
local MATCH_WINDOW, QUEUE_AGE, RECORD_AGE, LIMIT = 1, 1.5, 3, 256
local ROSTER_EVENTS = {
    "PLAYER_ENTERING_WORLD", "GROUP_ROSTER_UPDATE", "PLAYER_SPECIALIZATION_CHANGED",
    "PLAYER_REGEN_ENABLED", "UNIT_CONNECTION", "INSPECT_READY", "SPELLS_CHANGED",
    "UNIT_NAME_UPDATE", "UNIT_PET",
}
local LIVE_EVENTS = {
    "UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_CHANNEL_STOP",
    "DAMAGE_METER_COMBAT_SESSION_UPDATED", "DAMAGE_METER_RESET", "SPELL_UPDATE_COOLDOWN",
}

-- Local estimates, not a complete talent/pet availability detector. Event, icon and
-- player cooldown-query IDs deliberately differ for warlock command aliases.
local KICKS = {
    [47528] = { cd = 12, class = "DEATHKNIGHT" },
    [183752] = { cd = 15, class = "DEMONHUNTER" },
    [106839] = { cd = 15, class = "DRUID" },
    [78675] = { cd = 60, class = "DRUID" },
    [351338] = { cd = 40, class = "EVOKER" },
    [147362] = { cd = 24, class = "HUNTER" },
    [187707] = { cd = 15, class = "HUNTER" },
    [2139] = { cd = 21, class = "MAGE" },
    [116705] = { cd = 15, class = "MONK" },
    [96231] = { cd = 15, class = "PALADIN" },
    [15487] = { cd = 45, class = "PRIEST" },
    [1766] = { cd = 15, class = "ROGUE" },
    [57994] = { cd = 12, healerCd = 30, class = "SHAMAN" },
    [6552] = { cd = 13.5, class = "WARRIOR" },
    [386071] = { cd = 90, class = "WARRIOR" },
    [19647] = { cd = 24, class = "WARLOCK", poll = 119910 },
    [89766] = { cd = 30, class = "WARLOCK", poll = 119914 },
    [119910] = { cd = 24, class = "WARLOCK", icon = 19647 },
    [132409] = { cd = 24, class = "WARLOCK", icon = 19647 },
    [1276467] = { cd = 24, class = "WARLOCK", icon = 19647 },
    [119914] = { cd = 30, class = "WARLOCK", icon = 89766 },
}
local CLASS_INTERRUPTS = {
    WARRIOR = 6552, MAGE = 2139, ROGUE = 1766, PALADIN = 96231,
    MONK = 116705, SHAMAN = 57994, DEATHKNIGHT = 47528,
    DEMONHUNTER = 183752, EVOKER = 351338,
}
local SPEC_INTERRUPTS = {
    PRIEST = { [256] = false, [257] = false, [258] = 15487 },
    DRUID = { [102] = 78675, [103] = 106839, [104] = 106839, [105] = false },
    HUNTER = { [253] = 147362, [254] = 147362, [255] = 187707 },
    WARLOCK = { [265] = 19647, [266] = 89766, [267] = 19647 },
    PALADIN = { [65] = false, [66] = 96231, [70] = 96231 },
    MONK = { [268] = 116705, [269] = 116705, [270] = false },
    EVOKER = { [1467] = 351338, [1468] = false, [1473] = 351338 },
}
local HEALER_SPEC = { [65] = true, [105] = true, [256] = true, [257] = true, [264] = true, [270] = true, [1468] = true }
local HEALER_NO_KICK = { DRUID = true, EVOKER = true, PALADIN = true, PRIEST = true, MONK = true }

-- Never test truthiness, index, compare, concatenate or do arithmetic on a value
-- before the secret check. pcall alone is not a secret-value sanitiser.
local function IsPublic(value)
    return type(IsSecretValue) == "function" and not IsSecretValue(value)
end

local function PublicTable(value)
    if not IsPublic(value) or type(value) ~= "table" then return false end
    return type(IsSecretTable) ~= "function" or not IsSecretTable(value)
end

local function ReadPublic(api, ...)
    if type(api) ~= "function" then return nil end
    local ok, value = pcall(api, ...)
    if ok and IsPublic(value) then return value end
end

local function Field(container, key)
    if not PublicTable(container) then return nil end
    local ok, value = pcall(function() return container[key] end)
    if ok and IsPublic(value) then return value end
end

local function Finite(value)
    return IsPublic(value) and type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function Text(value)
    return IsPublic(value) and type(value) == "string" and value ~= ""
end

local function Now()
    local value = ReadPublic(GetTime)
    return Finite(value) and value or 0
end

local function IsParty()
    return ReadPublic(IsInGroup) == true and ReadPublic(IsInRaid) == false
end

local function IsActive()
    return settings ~= nil and settings.enabled == true and IsParty()
end

local function GetStatus()
    if not settings or not settings.enabled then return "已关闭。" end
    if not IsParty() then return "等待进入小队（不在单人或团队中显示）。" end
    local text = string.format("显示 %d 条打断技能条；专精/成员信息待获取：%d。", shownCount, unknownCount)
    if type(IsSecretValue) ~= "function" then return text .. "\nsecret 检查 API 不可用，监视已安全暂停。" end
    return text .. "\n可读施放直接计时；隐藏施放由敌方中断与暴雪统计配对补偿。\n队友 CD 为本地估算；推断以“~”标记，隐藏空踢可能漏记。\n“就绪”仅表示无观察中的 CD 或估计到期，不证明入队时技能真实可用。"
end

local function NotifyStatus()
    local text = GetStatus()
    if text ~= lastStatus then
        lastStatus = text
        if statusChanged then statusChanged(text) end
    end
end

local function BoundedPush(list, value)
    if #list >= LIMIT then table.remove(list, 1) end
    list[#list + 1] = value
end

local function CancelTimer(timer)
    if timer then timer:Cancel() end
end

local function ClearMeter()
    generation = generation + 1
    CancelTimer(expiryTimer)
    CancelTimer(selfTimer)
    expiryTimer, selfTimer, selfQueued, lastMeterHit = nil, nil, false, nil
    pendings, meterHits, directCasts, guesses, enemySeen, meterSnap = {}, {}, {}, {}, {}, {}
    -- DAMAGE_METER_RESET invalidates evidence, never an already running cooldown.
end

local function Duration(member, spellID)
    local kick = KICKS[spellID]
    return kick and ((member.heals and kick.healerCd) or kick.cd)
end

local function IconSpell(spellID)
    local kick = KICKS[spellID]
    return kick and (kick.icon or spellID)
end

local function PollSpell(spellID)
    local kick = KICKS[spellID]
    return kick and (kick.poll or spellID)
end

local function CopyState(state)
    if not state then return nil end
    local copy = {}
    for key, value in pairs(state) do copy[key] = value end
    return copy
end

local function SetReady(guid)
    if cooldowns[guid] then
        revision = revision + 1
        cooldowns[guid] = nil
        local member = byGUID[guid]
        if member and not member.spellID then layoutDirty = true end
    end
end

local function ApplyCooldown(member, at, spellID, inferred)
    local duration = Duration(member, spellID)
    if not duration then return nil end
    revision = revision + 1
    local state = {
        start = at, duration = duration, finish = at + duration, revision = revision,
        eventSpell = spellID, displaySpell = IconSpell(spellID),
        pollSpell = (member.unit == "player" and spellID == member.spellID and member.pollSpell) or PollSpell(spellID),
        inferred = inferred == true, correctionAfter = at + 0.001,
    }
    cooldowns[member.guid] = state
    StartTicker()
    UpdateRows()
    if member.unit == "player" then QueueSelf() end
    return state
end

local function HideTooltip(icon)
    if GameTooltip and GameTooltip:IsOwned(icon) then GameTooltip:Hide() end
end

local function ShortName(name)
    return name:match("^[^-]+")
end

local function DisplayName(member)
    return settings.showRealmName and (member.fullName or member.name) or ShortName(member.name)
end

local function NormalizeAppearance()
    settings.textureKey = type(settings.textureKey) == "string" and settings.textureKey ~= ""
        and settings.textureKey or DEFAULT_MEDIA_KEY
    settings.fontKey = type(settings.fontKey) == "string" and settings.fontKey ~= ""
        and settings.fontKey or DEFAULT_MEDIA_KEY
    settings.width = ns.NormalizeInteger(settings.width, SIZE.DEFAULT_WIDTH, SIZE.MIN_WIDTH, SIZE.MAX_WIDTH)
    settings.height = ns.NormalizeInteger(settings.height, SIZE.DEFAULT_HEIGHT, SIZE.MIN_HEIGHT, SIZE.MAX_HEIGHT)
    settings.fontSize = ns.NormalizeInteger(settings.fontSize, SIZE.DEFAULT_FONT_SIZE, SIZE.MIN_FONT_SIZE, SIZE.MAX_FONT_SIZE)
    settings.labelOffsetX = ns.NormalizeInteger(settings.labelOffsetX, 0, SIZE.MIN_TEXT_OFFSET, SIZE.MAX_TEXT_OFFSET)
    settings.timerOffsetX = ns.NormalizeInteger(settings.timerOffsetX, 0, SIZE.MIN_TEXT_OFFSET, SIZE.MAX_TEXT_OFFSET)
    settings.decimalPlaces = ns.NormalizeInteger(settings.decimalPlaces, SIZE.DEFAULT_DECIMAL_PLACES, 0, 2)
    if type(settings.showRealmName) ~= "boolean" then settings.showRealmName = false end
    settings.x = ns.NormalizeCoordinate(settings.x, DEFAULT_X)
    settings.y = ns.NormalizeCoordinate(settings.y, DEFAULT_Y)
end

local function ValidateMediaKey(key, mediaType)
    if not settings or settings[key] == DEFAULT_MEDIA_KEY then return end
    local media = ns.GetSharedMedia()
    if media and not ns.IsValidSharedMedia(media, mediaType, settings[key]) then
        settings[key] = DEFAULT_MEDIA_KEY
    end
end

local function ResolveAppearance()
    local media = ns.GetSharedMedia()
    appearance.texture = settings.textureKey ~= DEFAULT_MEDIA_KEY
        and ns.FetchSharedMedia(media, "statusbar", settings.textureKey) or DEFAULT_TEXTURE
    local font, flags
    if GameFontHighlightSmall and type(GameFontHighlightSmall.GetFont) == "function" then
        local ok, path, _, fontFlags = pcall(GameFontHighlightSmall.GetFont, GameFontHighlightSmall)
        if ok then font, flags = path, fontFlags end
    end
    if type(font) ~= "string" or font == "" then font = STANDARD_TEXT_FONT end
    appearance.fallbackFont = font
    appearance.flags = type(flags) == "string" and flags or ""
    if settings.fontKey ~= DEFAULT_MEDIA_KEY then
        local custom = ns.FetchSharedMedia(media, "font", settings.fontKey)
        if type(custom) == "string" and custom ~= "" then font = custom end
    end
    appearance.font = font
    appearance.timerFormat = "%." .. settings.decimalPlaces .. "f"
end

local function ApplyFont(fontString)
    local ok, applied = pcall(fontString.SetFont, fontString,
        appearance.font, settings.fontSize, appearance.flags)
    if (not ok or applied == false) and appearance.fallbackFont then
        pcall(fontString.SetFont, fontString, appearance.fallbackFont, settings.fontSize, appearance.flags)
    end
end

local function StackSize()
    local width = settings and settings.width or SIZE.DEFAULT_WIDTH
    local height = settings and settings.height or SIZE.DEFAULT_HEIGHT
    -- A one-row footprint also makes position controls usable before any rows exist.
    return width + height + ICON_GAP, math.max(1, shownCount) * (height + ROW_SPACING) - ROW_SPACING
end

local function GetPositionBounds()
    local width, height = StackSize()
    local halfWidth, halfHeight = UIParent:GetWidth() / 2, UIParent:GetHeight() / 2
    local minX, maxY = math.ceil(-halfWidth), math.floor(halfHeight)
    -- If the stack cannot fit, pin its top-left rather than inverting the bounds.
    local maxX = math.max(minX, math.floor(halfWidth - width))
    local minY = math.min(maxY, math.ceil(height - halfHeight))
    return minX, maxX, minY, maxY
end

local function ClampPosition()
    if not settings then return end
    local minX, maxX, minY, maxY = GetPositionBounds()
    settings.x = ns.Clamp(ns.NormalizeCoordinate(settings.x, DEFAULT_X), minX, maxX)
    settings.y = ns.Clamp(ns.NormalizeCoordinate(settings.y, DEFAULT_Y), minY, maxY)
    if displayFrame then
        displayFrame:ClearAllPoints()
        displayFrame:SetPoint("TOPLEFT", UIParent, "CENTER", settings.x, settings.y)
    end
end

local function SetCoordinate(axis, value)
    if not settings or (axis ~= "x" and axis ~= "y") then return end
    settings[axis] = ns.NormalizeCoordinate(value, settings[axis])
    ClampPosition()
end

local function LayoutDisplay()
    if displayFrame then displayFrame:SetSize(StackSize()) end
    ClampPosition()
end

local function ApplyRowAppearance(row, index)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", displayFrame, "TOPLEFT", settings.height + ICON_GAP,
        -(index - 1) * (settings.height + ROW_SPACING))
    row:SetSize(settings.width, settings.height)
    row:SetStatusBarTexture(appearance.texture)
    row.icon:SetSize(settings.height, settings.height)
    ApplyFont(row.label)
    ApplyFont(row.state)
    row.state:ClearAllPoints()
    row.state:SetPoint("RIGHT", row, "RIGHT", -5 + settings.timerOffsetX, 0)
    row.label:ClearAllPoints()
    row.label:SetPoint("LEFT", row, "LEFT", 5 + settings.labelOffsetX, 0)
    row.label:SetPoint("RIGHT", row.state, "LEFT", -4, 0)
end

local function RefreshDisplay()
    if not settings then return end
    NormalizeAppearance()
    ResolveAppearance()
    for index, row in ipairs(rows) do
        ApplyRowAppearance(row, index)
        local member = byGUID[row.guid]
        if member then row.label:SetText(DisplayName(member)) end
    end
    LayoutDisplay()
    UpdateRows()
end

local function EnsureRow(index)
    if rows[index] then return rows[index] end
    if not displayFrame then
        displayFrame = CreateFrame("Frame", "ReRansPartyInterruptMonitor", UIParent)
        displayFrame:SetClampedToScreen(true)
        displayFrame:SetFrameStrata("MEDIUM")
    end
    local row = CreateFrame("StatusBar", nil, displayFrame)
    row:SetMinMaxValues(0, 1)
    row:SetValue(1)
    ns.CreateSolidTexture(row, "BACKGROUND", 0, 0, 0, 0.68):SetAllPoints()
    ns.AddBorder(row, 1, 0.08, 0.08, 0.10, 1)
    row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.label:SetJustifyH("LEFT")
    row.label:SetWordWrap(false)
    row.label:SetTextColor(1, 1, 1)
    row.state = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.state:SetJustifyH("RIGHT")
    row.state:SetWordWrap(false)
    row.state:SetTextColor(1, 1, 1)
    row.icon = CreateFrame("Button", nil, row)
    row.icon:SetPoint("RIGHT", row, "LEFT", -ICON_GAP, 0)
    row.icon:EnableMouse(true)
    row.icon.texture = row.icon:CreateTexture(nil, "ARTWORK")
    row.icon.texture:SetAllPoints()
    row.icon.texture:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    row.icon:SetScript("OnEnter", function(self)
        if not self.spellID or not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetSpellByID(self.spellID)
        GameTooltip:AddLine(self.fullName, 1, 1, 1)
        GameTooltip:AddLine("队友时长来自本地技能表估算，不保证覆盖全部天赋、宠物与重置。", 1, 0.82, 0.2, true)
        local state = cooldowns[row.guid]
        if state and state.inferred then
            GameTooltip:AddLine("~ 推断归属：统计辅助或候选估计，非直接施放证据。", 1, 0.82, 0.2, true)
        end
        GameTooltip:Show()
    end)
    row.icon:SetScript("OnLeave", HideTooltip)
    row.icon:SetScript("OnHide", HideTooltip)
    rows[index] = row
    ApplyRowAppearance(row, index)
    return row
end

UpdateRows = function()
    if layoutDirty then RenderRoster(); return end
    local now = Now()
    for index = 1, shownCount do
        local row = rows[index]
        local member = byGUID[row.guid]
        if member then
            local state = cooldowns[member.guid]
            local spell = state and state.displaySpell or member.spellID
            if row.icon.spellID ~= spell then
                row.icon.spellID = spell
                local texture = C_Spell and ReadPublic(C_Spell.GetSpellTexture, spell)
                row.icon.texture:SetTexture(texture or 134400)
            end
            if state then
                local remaining = math.max(0, state.finish - now)
                row:SetMinMaxValues(0, state.duration)
                row:SetValue(math.min(state.duration, remaining))
                row.state:SetText((state.inferred and "~" or "") .. string.format(appearance.timerFormat, remaining))
            else
                row:SetMinMaxValues(0, 1)
                row:SetValue(1)
                row.state:SetText("就绪")
            end
        end
    end
end

RenderRoster = function()
    layoutDirty = false
    shownCount = 0
    for _, member in ipairs(roster) do
        if member.spellID or cooldowns[member.guid] then
            shownCount = shownCount + 1
            local row = EnsureRow(shownCount)
            HideTooltip(row.icon)
            row.guid = member.guid
            row.label:SetText(DisplayName(member))
            row.icon.fullName = member.fullName or member.name
            local color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[member.class]
            row:SetStatusBarColor(color and color.r or 1, color and color.g or 1, color and color.b or 1, 0.72)
            row:Show()
        end
    end
    for index = shownCount + 1, #rows do
        local row = rows[index]
        HideTooltip(row.icon)
        row.guid, row.icon.spellID, row.icon.fullName = nil, nil, nil
        row.label:SetText("")
        row.icon.texture:SetTexture(nil)
        row:Hide()
    end
    if displayFrame then
        LayoutDisplay()
        displayFrame:SetShown(shownCount > 0)
    end
    UpdateRows()
end

-- Returns true/false/unknown. In particular hidden isActive/isOnGCD are not
-- coerced to booleans, and a GCD can neither create nor lengthen an interrupt CD.
local function SelfCooldownInfo(state)
    local api = C_Spell and C_Spell.GetSpellCooldown
    if type(api) ~= "function" then return nil, nil, nil, false end
    local info = ReadPublic(api, state.pollSpell)
    if not PublicTable(info) then return nil, nil, nil, true end
    local active, gcd = Field(info, "isActive"), Field(info, "isOnGCD")
    local start, duration, rate = Field(info, "startTime"), Field(info, "duration"), Field(info, "modRate")
    if type(gcd) ~= "boolean" or type(active) ~= "boolean" then return nil, nil, nil, true end
    if gcd == true then return nil, nil, nil, true end
    if active == false then return false, nil, nil, true end
    if active ~= true or gcd ~= false then return nil, nil, nil, true end
    if Finite(start) and start >= 0 and Finite(duration) and duration > 2 then
        if Finite(rate) and rate > 0 then duration = duration / rate end
        return true, start, duration, true
    end
    return true, nil, nil, true
end

RefreshSelf = function()
    local member = byUnit.player
    if not member or ReadPublic(UnitGUID, "player") ~= member.guid then return end
    local state = cooldowns[member.guid]
    if not state then return end -- unrelated SPELL_UPDATE_COOLDOWN cannot invent a cast
    local now = Now()
    if now < state.correctionAfter then return end -- same-frame cooldown can still be old ready
    state.polledAt = now
    local running, start, duration, available = SelfCooldownInfo(state)
    state.running, state.apiAvailable = running, available
    if running == false then
        SetReady(member.guid)
    elseif start and duration then
        local finish = start + duration
        if finish <= now then
            -- An active API with stale numeric data is not evidence of readiness.
            return
        end
        if state.start ~= start or state.duration ~= duration then
            revision = revision + 1
            state.start, state.duration, state.finish, state.revision = start, duration, finish, revision
        end
    end
end

QueueSelf = function()
    local own = byUnit.player
    if selfQueued or not listening or not own or not cooldowns[own.guid] then return end
    selfQueued = true
    StartTicker()
    if C_Timer and type(C_Timer.NewTimer) == "function" then
        local epoch = generation
        selfTimer = C_Timer.NewTimer(0.001, function()
            if epoch ~= generation or not listening then return end
            selfTimer, selfQueued = nil, false
            RefreshSelf()
            UpdateRows()
        end)
    end
end

StartTicker = function()
    eventFrame:SetScript("OnUpdate", function(_, elapsed)
        if not listening or not IsActive() then RefreshRoster(); return end
        tickElapsed = tickElapsed + elapsed
        if tickElapsed < 0.05 then return end
        tickElapsed = 0
        local now, busy = Now(), false
        local own = byUnit.player
        local ownState = own and cooldowns[own.guid]
        if ownState and (selfQueued or now - (ownState.polledAt or -1) >= 0.15 or now >= ownState.finish) then
            selfQueued = false
            RefreshSelf()
        end
        for guid, state in pairs(cooldowns) do
            if state.finish <= now then
                if own and guid == own.guid and state.running == true then
                    -- Only publicly active state can extend a finite estimate.
                    -- Unknown state preserves it until natural estimated expiry.
                    revision = revision + 1
                    state.revision = revision
                    state.finish = now + 0.5
                    state.duration = math.max(state.duration, state.finish - state.start)
                else
                    SetReady(guid)
                end
            end
            if cooldowns[guid] then busy = true end
        end
        UpdateRows()
        if not busy and not selfQueued then eventFrame:SetScript("OnUpdate", nil) end
    end)
end

local function SpecIcon(spec)
    if not spec then return nil end
    if specIcons[spec] ~= nil then return specIcons[spec] or nil end
    local api = C_SpecializationInfo and C_SpecializationInfo.GetSpecializationInfoByID or GetSpecializationInfoByID
    local icon
    if type(api) == "function" then
        local ok, _, _, _, value = pcall(api, spec)
        if ok and Finite(value) then icon = value end
    end
    specIcons[spec] = icon or false
    return icon
end

local function MatchEntry(entry)
    local matches, count = {}, 0
    local full = entry.name and entry.name:find("-", 1, true) ~= nil
    for _, member in ipairs(roster) do
        local own = member.unit == "player"
        local ok = true
        if entry.me ~= nil and entry.me ~= own then ok = false end
        if entry.class and entry.class ~= member.class then ok = false end
        if entry.name then
            if full then
                if entry.name ~= member.name then ok = false end
            elseif ShortName(entry.name) ~= ShortName(member.name) then
                ok = false
            end
        end
        if entry.icon and member.spec then
            local icon = SpecIcon(member.spec)
            if icon and icon ~= entry.icon then ok = false end
        end
        if ok then matches[member.guid], count = true, count + 1 end
    end
    -- A class alone, even if unique in this party, is not a unique identity.
    local identified = entry.me == true or entry.name ~= nil or (entry.class ~= nil and entry.icon ~= nil)
    return count == 1 and identified and next(matches) or nil, matches
end

local function MeterEnums()
    local types, sessions = Field(Enum, "DamageMeterType"), Field(Enum, "DamageMeterSessionType")
    local interrupts = Field(types, "Interrupts")
    if not Finite(interrupts) or not PublicTable(sessions) then return nil end
    return interrupts, sessions
end

local function ReadMeterList(sessionType, interrupts)
    local api = C_DamageMeter and C_DamageMeter.GetCombatSessionFromType
    local session = ReadPublic(api, sessionType, interrupts)
    local sources = Field(session, "combatSources")
    if not PublicTable(sources) then return nil end
    local list, occurrences = {}, {}
    for index = 1, 256 do
        local src = Field(sources, index)
        if src == nil then break end
        if PublicTable(src) then
            local class, name = Field(src, "classFilename"), Field(src, "name")
            local icon, me = Field(src, "specIconID"), Field(src, "isLocalPlayer")
            if not Text(class) then class = nil end
            if not Text(name) then name = nil end
            if not Finite(icon) then icon = nil end
            if type(me) ~= "boolean" then me = nil end
            if class or name or me == true then
                local entry = { class = class, name = name, icon = icon, me = me }
                -- Full names retain realm identity. Duplicate identity signatures
                -- never gain artificial uniqueness through row index suffixes.
                entry.key = (name or "") .. "\031" .. (class or "") .. "\031"
                    .. (icon and tostring(icon) or "") .. "\031" .. (me == nil and "?" or tostring(me))
                occurrences[entry.key] = (occurrences[entry.key] or 0) + 1
                list[#list + 1] = entry
            end
        end
    end
    for _, entry in ipairs(list) do entry.duplicate = occurrences[entry.key] > 1 end
    return list
end

local function DiffMeter(sessionType, interrupts)
    local list = ReadMeterList(sessionType, interrupts)
    local old = meterSnap[sessionType]
    meterSnap[sessionType] = list -- update both sessions, even when one already identifies someone
    if not list then return nil, nil end
    if #list == 1 then return list[1], list end
    if not old then return nil, list end
    local indices = {}
    for index, entry in ipairs(old) do
        if not entry.duplicate then indices[entry.key] = index end
    end
    local newcomer, climber, nNew, nClimb = nil, nil, 0, 0
    for index, entry in ipairs(list) do
        if not entry.duplicate then
            local before = indices[entry.key]
            if not before then newcomer, nNew = entry, nNew + 1
            elseif index < before then climber, nClimb = entry, nClimb + 1 end
        end
    end
    if nNew == 1 then return newcomer, list end
    if nNew == 0 and nClimb == 1 then return climber, list end
    return nil, list
end

local function Union(out, values)
    for guid in pairs(values) do out[guid] = true end
end

local function MeterKicker(interrupts, sessions)
    local results, readable = {}, false
    for _, name in ipairs({ "Current", "Overall" }) do
        local sessionType = Field(sessions, name)
        if Finite(sessionType) then
            local entry, list = DiffMeter(sessionType, interrupts)
            results[#results + 1] = { entry = entry, list = list }
            if list then readable = true end
        end
    end
    if not readable then return nil end
    local owners, candidates, fallback, narrowed = {}, {}, {}, false
    for _, result in ipairs(results) do
        if result.entry and not result.entry.duplicate then
            local owner, matches = MatchEntry(result.entry)
            if owner then owners[owner] = true end
            if next(matches) then Union(candidates, matches); narrowed = true end
        end
        for _, entry in ipairs(result.list or {}) do
            local _, matches = MatchEntry(entry)
            Union(fallback, matches)
        end
    end
    if not narrowed then candidates = fallback end
    if not next(candidates) then return nil end -- empty/unreadable stats are not a confirmation
    local owner, n = nil, 0
    for guid in pairs(owners) do owner, n = guid, n + 1 end
    return { owner = n == 1 and owner or nil, candidates = candidates }
end

local function PrimeMeter()
    local interrupts, sessions = MeterEnums()
    if not interrupts then return end
    for _, name in ipairs({ "Current", "Overall" }) do
        local sessionType = Field(sessions, name)
        if Finite(sessionType) then meterSnap[sessionType] = ReadMeterList(sessionType, interrupts) end
    end
end

local function Prune(now)
    for _, list in ipairs({ pendings, meterHits, directCasts, guesses, enemySeen }) do
        local age = (list == pendings or list == meterHits) and QUEUE_AGE or RECORD_AGE
        while list[1] and now - list[1].time >= age do table.remove(list, 1) end
    end
end

ArmExpiry = function()
    CancelTimer(expiryTimer)
    expiryTimer = nil
    if not listening or not C_Timer or type(C_Timer.NewTimer) ~= "function" then return end
    local deadline
    for _, list in ipairs({ pendings, meterHits, directCasts, guesses, enemySeen }) do
        local age = (list == pendings or list == meterHits) and QUEUE_AGE or RECORD_AGE
        if list[1] then deadline = math.min(deadline or math.huge, list[1].time + age) end
    end
    if not deadline then return end
    local epoch = generation
    expiryTimer = C_Timer.NewTimer(math.max(0.001, deadline - Now()), function()
        if epoch ~= generation or not listening then return end
        expiryTimer = nil
        Prune(Now())
        ArmExpiry()
    end)
end

local function Compatible(record, pending, candidates)
    if record.consumed or math.abs(record.time - pending.time) > MATCH_WINDOW then return false end
    if pending.owner then return record.guid == pending.owner end
    return not candidates or candidates[record.guid] == true
end

local function ClaimDirect(pending, candidates, owner)
    local match, count = nil, 0
    for _, record in ipairs(directCasts) do
        if Compatible(record, pending, candidates) and (not owner or record.guid == owner) then
            match, count = record, count + 1
        end
    end
    if count == 1 then match.consumed = true; return match end
end

local function GuessMember(candidates, allowBusy)
    local best, bestCD
    for _, member in ipairs(roster) do
        if member.unit ~= "player" and member.spellID and (not candidates or candidates[member.guid]) then
            local state = cooldowns[member.guid]
            if allowBusy or not state or state.finish <= Now() then
                local cd = Duration(member, member.spellID)
                if cd and (not bestCD or cd < bestCD) then best, bestCD = member, cd end
            end
        end
    end
    return best
end

local function Charge(pending, hit)
    -- A readable source is stronger than meter identity; never steal another
    -- member's direct cast just because statistics arrived late.
    local owner = pending.owner or hit.owner
    local record
    if not pending.owner then
        -- Meter rank/name heuristics can lag a recent local cast. Claim it first
        -- only if it is the sole time-compatible evidence, and another queued
        -- enemy event is not closer. Never steal a readable external source.
        local own, count = nil, 0
        for _, cast in ipairs(directCasts) do
            if Compatible(cast, pending, nil) then own, count = cast, count + 1 end
        end
        if count == 1 and byUnit.player and own.guid == byUnit.player.guid
            and math.abs(own.time - pending.time) <= 0.8 then
            local closer = false
            for _, other in ipairs(pendings) do
                if math.abs(own.time - other.time) < math.abs(own.time - pending.time) then closer = true end
            end
            if not closer then own.consumed = true; return end
        end
    end
    local candidates = hit.candidates
    if pending.owner then candidates = nil end
    record = ClaimDirect(pending, candidates, owner)
    if record then return end
    local member = owner and byGUID[owner]
    local inferred = pending.owner == nil -- meter-based identity is still inference
    if not member then
        member = GuessMember(hit.candidates, false) or GuessMember(hit.candidates, true) or GuessMember(nil, false)
        inferred = true
    end
    if not member or not member.spellID then return end
    local previous = CopyState(cooldowns[member.guid])
    local state = ApplyCooldown(member, pending.time, member.spellID, inferred)
    if state then
        -- Also retain clearly attributed observed uses: a later SUCCEEDED for
        -- this interruption must upgrade evidence, not restart a full cooldown.
        BoundedPush(guesses, {
            time = pending.time, guid = member.guid, revision = state.revision,
            previous = previous, owner = pending.owner, candidates = hit.candidates,
        })
    end
end

Pair = function(now)
    Prune(now)
    while pendings[1] and meterHits[1] do
        local pending, hit = pendings[1], meterHits[1]
        local gap = pending.time - hit.time
        if gap > MATCH_WINDOW then table.remove(meterHits, 1)
        elseif gap < -MATCH_WINDOW then table.remove(pendings, 1)
        else
            table.remove(pendings, 1)
            table.remove(meterHits, 1)
            Charge(pending, hit)
        end
    end
    ArmExpiry()
end

local function CorrectGuess(member, at)
    local match, count = nil, 0
    for _, guess in ipairs(guesses) do
        if not guess.corrected and math.abs(at - guess.time) <= MATCH_WINDOW
            and (not guess.owner or guess.owner == member.guid) then
            match, count = guess, count + 1
        end
    end
    if count ~= 1 then return nil end
    match.corrected = true
    local state = cooldowns[match.guid]
    -- No blanket SetReady: later casts/API corrections own a newer revision.
    if state and state.revision == match.revision then
        revision = revision + 1
        local previous = CopyState(match.previous)
        if previous and previous.finish > Now() then
            previous.revision = revision
            cooldowns[match.guid] = previous
        else
            cooldowns[match.guid] = nil
            local member = byGUID[match.guid]
            if member and not member.spellID then layoutDirty = true end
        end
    end
    return match
end

local function OnSucceeded(frame, castGUID, spellID)
    if not IsPublic(spellID) or not Finite(spellID) then return end
    local kick = KICKS[spellID]
    if not kick then return end
    local member = byUnit[frame.ownerUnit]
    if not member or frame.ownerGUID ~= member.guid or ReadPublic(UnitGUID, frame.ownerUnit) ~= frame.ownerGUID then return end
    if kick.class ~= member.class then return end
    -- Also validate a pet frame against the live pet, rather than a stale owner
    -- binding after UNIT_PET; command and pet actual casts remain one use.
    if frame.petUnit and (ReadPublic(UnitExists, frame.unit) ~= true or not frame.petGUID
        or ReadPublic(UnitGUID, frame.unit) ~= frame.petGUID) then return end
    local now = Now()
    Prune(now)
    local cast = Text(castGUID) and castGUID or nil
    local icon = IconSpell(spellID)
    for _, record in ipairs(directCasts) do
        if record.guid == member.guid then
            local sameCast = cast and record.cast == cast
            local petAlias = member.class == "WARLOCK" and record.icon == icon
                and record.unit ~= frame.unit and math.abs(now - record.time) <= 0.35
            if sameCast or petAlias then
                -- Prefer the readable command's query ID over the pet's ability.
                local state = cooldowns[member.guid]
                if state and state.revision == record.revision and kick.icon then state.pollSpell = PollSpell(spellID) end
                return
            end
        end
    end
    local corrected = CorrectGuess(member, now)
    local state = ApplyCooldown(member, corrected and corrected.time or now, spellID, false)
    if not state then return end
    BoundedPush(directCasts, {
        time = now, guid = member.guid, unit = frame.unit, cast = cast, icon = icon,
        revision = state.revision, consumed = corrected ~= nil,
    })
    -- Actual readable casts can reveal an alternative ability not inferred from
    -- spec/role. Display it while it is cooling without changing the default.
    RenderRoster()
    Pair(now)
end

local function EnemyKey(unit, castGUID, spellID, now)
    local enemy = ReadPublic(UnitGUID, unit)
    if not Text(enemy) then enemy = nil end
    local cast = Text(castGUID) and castGUID or nil
    local spell = Finite(spellID) and spellID or nil
    for _, record in ipairs(enemySeen) do
        if cast and record.cast == cast and (not enemy or not record.enemy or record.enemy == enemy) then return false end
        if enemy and record.enemy == enemy and now - record.time <= 0.08
            and (not spell or not record.spell or record.spell == spell) then return false end
        if not enemy and not cast and record.unit == unit and now - record.time <= 0.02 then return false end
    end
    BoundedPush(enemySeen, { time = now, unit = unit, enemy = enemy, cast = cast, spell = spell })
    return true
end

local function OnEnemyInterrupted(event, unit, castGUID, spellID, interruptedBy)
    if not C_Timer or type(C_Timer.NewTimer) ~= "function" then return end
    if not Text(unit) or byUnit[unit] then return end
    for _, frame in ipairs(castFrames) do if frame.unit == unit then return end end
    if event == "UNIT_SPELLCAST_CHANNEL_STOP" and IsPublic(interruptedBy) and interruptedBy == nil then return end
    if ReadPublic(UnitCanAttack, "player", unit) ~= true then return end
    local owner
    if IsPublic(interruptedBy) and interruptedBy ~= nil then
        if not Text(interruptedBy) then return end
        owner = byGUID[interruptedBy] and interruptedBy or petOwners[interruptedBy]
        if not owner then return end -- publicly outside this party
        local member = byGUID[owner]
        if not member or ReadPublic(UnitGUID, member.unit) ~= owner then return end
        if interruptedBy ~= owner then
            local pet = member.unit == "player" and "pet" or "partypet" .. member.unit:sub(-1)
            if ReadPublic(UnitGUID, pet) ~= interruptedBy then return end
        end
    end
    local now = Now()
    Prune(now)
    if not EnemyKey(unit, castGUID, spellID, now) then return end
    BoundedPush(pendings, { time = now, owner = owner })
    Pair(now)
end

local function OnMeterUpdate(dmType)
    if not IsPublic(dmType) then return end
    local interrupts, sessions = MeterEnums()
    if not interrupts or dmType ~= interrupts then return end
    local hit = MeterKicker(interrupts, sessions)
    if not hit or not C_Timer or type(C_Timer.NewTimer) ~= "function" then return end
    hit.time = Now()
    local keys = {}
    for guid in pairs(hit.candidates) do keys[#keys + 1] = guid end
    table.sort(keys)
    hit.signature = (hit.owner or "?") .. ":" .. table.concat(keys, ",")
    -- Duplicate Current/Overall notifications can arrive in the same burst.
    -- Identity-scoped, never global: different owners or a distinct waiting
    -- enemy interruption are not throttled. Counts themselves remain unread.
    if lastMeterHit and lastMeterHit.signature == hit.signature
        and hit.time - lastMeterHit.time <= 0.02 and #pendings == 0 then return end
    lastMeterHit = hit
    BoundedPush(meterHits, hit) -- one hit per event, never one per session
    Pair(hit.time)
end

local function CancelInspectTimer()
    CancelTimer(inspectTimer)
    inspectTimer = nil
end

local function ResetRoster()
    CancelInspectTimer()
    pendingInspect, nextInspectAt = nil, 0
    roster, byGUID, byUnit, petOwners = {}, {}, {}, {}
    specCache, invalidSpecs, inspectAttempts, cooldowns = {}, {}, {}, {}
    unknownCount = 0
    ClearMeter()
    eventFrame:SetScript("OnUpdate", nil)
    RenderRoster()
end

local function ReadSpec(unit, class)
    local api, spec = C_SpecializationInfo
    if unit == "player" then
        local index = ReadPublic(api and api.GetSpecialization or GetSpecialization)
        if Finite(index) then spec = ReadPublic(api and api.GetSpecializationInfo or GetSpecializationInfo, index) end
    else
        spec = ReadPublic(api and api.GetInspectSpecialization or GetInspectSpecialization, unit)
    end
    if not Finite(spec) or spec <= 0 or spec ~= math.floor(spec) then return nil end
    local map = SPEC_INTERRUPTS[class]
    if not map or map[spec] ~= nil then return spec end
end

local function ReadName(unit)
    if type(UnitFullName) ~= "function" then return nil end
    local ok, name, realm = pcall(UnitFullName, unit)
    if not ok or not Text(name) then return nil end
    if Text(realm) then
        local fullName = name .. "-" .. realm
        return fullName, fullName
    end
    -- Keep the original identity for meter matching. Only display metadata gets
    -- the local-realm suffix when UnitFullName returns a public empty realm.
    local displayRealm
    if IsPublic(realm) and (realm == nil or realm == "") then
        displayRealm = ReadPublic(GetNormalizedRealmName)
        if not Text(displayRealm) then
            displayRealm = ReadPublic(GetRealmName)
            if Text(displayRealm) then displayRealm = displayRealm:gsub("%s+", "") end
        end
    end
    return name, Text(displayRealm) and (name .. "-" .. displayRealm) or name
end

local function ReadClass(unit)
    if type(UnitClass) ~= "function" then return nil end
    local ok, _, token = pcall(UnitClass, unit)
    if ok and Text(token) then return token end
end

local function Known(spell, bank)
    if C_SpellBook and type(C_SpellBook.IsSpellKnownOrInSpellBook) == "function" then
        return ReadPublic(C_SpellBook.IsSpellKnownOrInSpellBook, spell, bank) == true
    end
    local petBank = Field(Field(Enum, "SpellBookSpellBank"), "Pet")
    local pet = bank == true or (Finite(petBank) and bank == petBank)
    return ReadPublic(IsSpellKnown, spell, pet == true) == true
end

local function PlayerSpell(member)
    if member.class ~= "WARLOCK" then return member.spellID, PollSpell(member.spellID) end
    local banks = Field(Enum, "SpellBookSpellBank")
    local petBank = Field(banks, "Pet")
    if Finite(petBank) then
        if Known(89766, petBank) then return 89766, 119914 end
        if Known(19647, petBank) then return 19647, 119910 end
    elseif Known(89766, true) then return 89766, 119914
    elseif Known(19647, true) then return 19647, 119910 end
    for _, spell in ipairs({ 132409, 1276467, 119910, 119914 }) do
        if Known(spell) then return IconSpell(spell), spell end
    end
    return member.spellID, PollSpell(member.spellID)
end

local function ScheduleInspect(delay)
    if inspectTimer or pendingInspect or not IsActive() or not C_Timer or type(C_Timer.NewTimer) ~= "function" then return end
    local epoch = generation
    inspectTimer = C_Timer.NewTimer(delay, function()
        if epoch ~= generation then return end
        inspectTimer = nil
        PumpInspect()
    end)
end

local function RefreshPetOwners()
    local owners = {}
    for _, member in ipairs(roster) do
        local unit = member.unit == "player" and "pet" or "partypet" .. member.unit:sub(-1)
        if ReadPublic(UnitGUID, member.unit) == member.guid then
            local guid = ReadPublic(UnitGUID, unit)
            if Text(guid) then owners[guid] = member.guid end
        end
    end
    petOwners = owners
end

local function BindCastFrames()
    for index = 0, 4 do
        local ownerUnit = index == 0 and "player" or "party" .. index
        for petIndex = 0, 1 do
            local slot = index * 2 + petIndex + 1
            local frame = castFrames[slot]
            if not frame then
                frame = CreateFrame("Frame")
                frame.ownerUnit = ownerUnit
                frame.unit = petIndex == 0 and ownerUnit or (index == 0 and "pet" or "partypet" .. index)
                frame.petUnit = petIndex == 1
                frame:SetScript("OnEvent", function(self, event, _, castGUID, spellID)
                    if event ~= "UNIT_SPELLCAST_SUCCEEDED" or not listening then return end
                    if not IsActive() then RefreshRoster(); return end
                    OnSucceeded(self, castGUID, spellID)
                end)
                castFrames[slot] = frame
            end
            local member = byUnit[ownerUnit]
            frame.ownerGUID = member and member.guid or nil
            local petGUID = frame.petUnit and ReadPublic(UnitGUID, frame.unit) or nil
            frame.petGUID = Text(petGUID) and petGUID or nil
            if listening and frame.ownerGUID then frame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", frame.unit)
            else frame:UnregisterEvent("UNIT_SPELLCAST_SUCCEEDED") end
        end
    end
end

SyncListening = function()
    local active = IsActive() and type(IsSecretValue) == "function"
    if listening ~= active then
        listening = active
        ClearMeter()
        for _, event in ipairs(LIVE_EVENTS) do
            if active then eventFrame:RegisterEvent(event) else eventFrame:UnregisterEvent(event) end
        end
        if active then PrimeMeter() else eventFrame:SetScript("OnUpdate", nil) end
    end
    BindCastFrames()
end

RefreshRoster = function()
    if not IsActive() then
        ResetRoster()
        SyncListening()
        NotifyStatus()
        return
    end
    local members, present, units = {}, {}, {}
    local changed, metadataChanged, selfChanged = false, false, false
    unknownCount = 0
    for index = 0, 4 do
        local unit = index == 0 and "player" or "party" .. index
        if ReadPublic(UnitExists, unit) == true then
            local guid = ReadPublic(UnitGUID, unit)
            if Text(guid) then
                local old = byGUID[guid]
                local name, fullName = ReadName(unit)
                local class = ReadClass(unit)
                name, class = name or (old and old.name), class or (old and old.class)
                fullName = fullName or (old and old.fullName) or name
                if name and class then
                    present[guid] = true
                    local spec
                    if not invalidSpecs[guid] then spec = ReadSpec(unit, class) end
                    if spec then specCache[guid] = spec else spec = specCache[guid] end
                    local role = ReadPublic(UnitGroupRolesAssigned, unit)
                    if not Text(role) then role = old and old.role end
                    local heals = spec and HEALER_SPEC[spec] == true or (not spec and role == "HEALER")
                    local map, spell, unknown = SPEC_INTERRUPTS[class], CLASS_INTERRUPTS[class], false
                    if map then
                        local mapped = spec and map[spec]
                        if mapped == nil then
                            unknown = true
                            spell = nil
                        elseif mapped == false then spell = nil
                        else spell = mapped end
                    elseif not spell then unknown = true end
                    if not spec and heals and HEALER_NO_KICK[class] then spell = nil end
                    local member = {
                        unit = unit, guid = guid, name = name, fullName = fullName, class = class, spec = spec,
                        role = role, heals = heals, spellID = spell,
                        needsSpec = spec == nil and unit ~= "player",
                    }
                    if unit == "player" then member.spellID, member.pollSpell = PlayerSpell(member) end
                    -- Unknown name/spec refreshes preserve GUID-owned cooldowns.
                    -- Only a definite ability change invalidates a running use.
                    local skillChanged = old and not unknown and (old.spellID ~= member.spellID or old.class ~= class)
                    if skillChanged then
                        local state = cooldowns[guid]
                        if old.class ~= class or not state or state.displaySpell ~= member.spellID then SetReady(guid) end
                    end
                    if not old or old.class ~= class or skillChanged then changed = true end
                    if not old or old.name ~= name or old.spec ~= spec then metadataChanged = true end
                    if unit == "player" and (not old or skillChanged or old.pollSpell ~= member.pollSpell) then selfChanged = true end
                    if unknown then unknownCount = unknownCount + 1 end
                    members[#members + 1], units[unit] = member, member
                else unknownCount = unknownCount + 1 end
            else unknownCount = unknownCount + 1 end
        end
    end
    for guid in pairs(byGUID) do if not present[guid] then changed = true end end
    roster, byUnit, byGUID = members, units, {}
    for _, member in ipairs(roster) do byGUID[member.guid] = member end
    for _, cache in ipairs({ specCache, invalidSpecs, inspectAttempts, cooldowns }) do
        for guid in pairs(cache) do if not present[guid] then cache[guid] = nil end end
    end
    if pendingInspect and (not present[pendingInspect.guid] or ReadPublic(UnitGUID, pendingInspect.unit) ~= pendingInspect.guid) then
        CancelInspectTimer()
        pendingInspect = nil
    end
    if changed then
        -- Cancel inspect before advancing the shared callback epoch.
        CancelInspectTimer()
        pendingInspect = nil
        ClearMeter()
    end
    RefreshPetOwners()
    SyncListening()
    if (changed or metadataChanged) and listening then PrimeMeter() end
    if selfChanged and listening then
        local own = byUnit.player
        if own and own.spellID and not cooldowns[own.guid] then
            local probe = { pollSpell = own.pollSpell or PollSpell(own.spellID) }
            local running, start, duration = SelfCooldownInfo(probe)
            if running == true and start and duration and start + duration > Now() then
                local state = ApplyCooldown(own, start, own.spellID, false)
                if state then state.duration, state.finish = duration, start + duration end
            end
        end
    end
    RenderRoster()
    if next(cooldowns) then StartTicker() end
    NotifyStatus()
    for _, member in ipairs(roster) do
        if member.needsSpec and (inspectAttempts[member.guid] or 0) < MAX_INSPECT_ATTEMPTS then
            ScheduleInspect(math.max(0, nextInspectAt - Now()))
            break
        end
    end
end

PumpInspect = function()
    if not IsActive() or pendingInspect or ReadPublic(InCombatLockdown) ~= false then return end
    if InspectFrame and ReadPublic(InspectFrame.IsShown, InspectFrame) == true then return end
    if type(NotifyInspect) ~= "function" or not C_Timer or type(C_Timer.NewTimer) ~= "function" then return end
    local retry = false
    for _, member in ipairs(roster) do
        local attempts = inspectAttempts[member.guid] or 0
        if member.needsSpec and attempts < MAX_INSPECT_ATTEMPTS then
            inspectAttempts[member.guid] = attempts + 1
            if ReadPublic(CanInspect, member.unit) == true and ReadPublic(UnitGUID, member.unit) == member.guid then
                pendingInspect = { unit = member.unit, guid = member.guid, class = member.class }
                local request, epoch = pendingInspect, generation
                nextInspectAt = Now() + INSPECT_INTERVAL
                local ok = pcall(NotifyInspect, member.unit)
                if pendingInspect ~= request then return end
                if not ok then pendingInspect = nil; ScheduleInspect(INSPECT_INTERVAL); return end
                inspectTimer = C_Timer.NewTimer(INSPECT_TIMEOUT, function()
                    if epoch ~= generation or pendingInspect ~= request then return end
                    inspectTimer, pendingInspect = nil, nil
                    RefreshRoster()
                end)
                return
            end
            retry = true
        end
    end
    if retry then ScheduleInspect(INSPECT_INTERVAL) end
end

local function OnInspectReady(guid)
    if not Text(guid) or not pendingInspect or guid ~= pendingInspect.guid then return end
    if ReadPublic(UnitGUID, pendingInspect.unit) == guid then
        local spec = ReadSpec(pendingInspect.unit, pendingInspect.class)
        if spec then specCache[guid], invalidSpecs[guid] = spec, nil end
    end
    CancelInspectTimer()
    pendingInspect = nil
    RefreshRoster()
end

local function UpdateActivation()
    if not initialized then return end
    for _, event in ipairs(ROSTER_EVENTS) do
        if settings.enabled then eventFrame:RegisterEvent(event) else eventFrame:UnregisterEvent(event) end
    end
    RefreshRoster()
end

local function InitializeSettings(db)
    if type(db.partyInterruptMonitor) ~= "table" then db.partyInterruptMonitor = {} end
    settings = db.partyInterruptMonitor
    if type(settings.enabled) ~= "boolean" then settings.enabled = false end
    settings.logs = nil
    NormalizeAppearance()
    ResolveAppearance()
    ClampPosition()
end

local function SetEnabled(enabled)
    if not settings then return end
    settings.enabled = IsPublic(enabled) and enabled == true
    inspectAttempts = {}
    UpdateActivation()
end

local function Initialize()
    if initialized then return end
    initialized = true
    UpdateActivation()
end

eventFrame:SetScript("OnEvent", function(_, event, arg1, arg2, arg3, arg4)
    if event == "UNIT_SPELLCAST_INTERRUPTED" or event == "UNIT_SPELLCAST_CHANNEL_STOP" then
        if listening and IsActive() then OnEnemyInterrupted(event, arg1, arg2, arg3, arg4) end
    elseif event == "DAMAGE_METER_COMBAT_SESSION_UPDATED" then
        if listening and IsActive() then OnMeterUpdate(arg1) end
    elseif event == "SPELL_UPDATE_COOLDOWN" then
        if listening and IsActive() then QueueSelf() end
    elseif event == "DAMAGE_METER_RESET" then
        CancelInspectTimer()
        pendingInspect = nil
        ClearMeter()
        if listening then PrimeMeter() end
        RefreshRoster()
    elseif event == "INSPECT_READY" then
        if IsActive() then OnInspectReady(arg1) end
    else
        if event == "PLAYER_SPECIALIZATION_CHANGED" and Text(arg1) then
            local guid = ReadPublic(UnitGUID, arg1)
            if Text(guid) then
                specCache[guid], inspectAttempts[guid] = nil, nil
                invalidSpecs[guid] = arg1 ~= "player" or nil
                if pendingInspect and pendingInspect.guid == guid then CancelInspectTimer(); pendingInspect = nil end
            end
        elseif event == "PLAYER_ENTERING_WORLD" then
            ResetRoster()
        elseif event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_REGEN_ENABLED" or event == "UNIT_CONNECTION" then
            inspectAttempts = {}
        elseif event == "UNIT_PET" then
            -- Rebuild live pet GUID ownership and baseline both meter sessions.
            RefreshPetOwners()
            CancelInspectTimer()
            pendingInspect = nil
            ClearMeter()
            if listening then PrimeMeter() end
        end
        RefreshRoster()
    end
end)

ns.PartyInterruptMonitor = {
    SIZE = SIZE,
    DEFAULT_MEDIA_KEY = DEFAULT_MEDIA_KEY,
    RefreshDisplay = RefreshDisplay,
    SetCoordinate = SetCoordinate,
    GetPositionBounds = GetPositionBounds,
    ClampPosition = ClampPosition,
    OnDisplayChanged = ClampPosition,
    ValidateTextureKey = function() ValidateMediaKey("textureKey", "statusbar") end,
    ValidateFontKey = function() ValidateMediaKey("fontKey", "font") end,
    InitializeSettings = InitializeSettings,
    GetSettings = function() return settings end,
    SetEnabled = SetEnabled,
    Initialize = Initialize,
    GetStatus = GetStatus,
    SetStatusChanged = function(callback) statusChanged = callback; lastStatus = nil end,
}
