local _, ns = ...

local IsSecretValue = ns.IsSecretValue
local IsSecretTable = ns.IsSecretTable
local Clamp = ns.Clamp
local NormalizeColor = ns.NormalizeColor
local NormalizeCoordinate = ns.NormalizeCoordinate
local NormalizeInteger = ns.NormalizeInteger
local CreateSolidTexture = ns.CreateSolidTexture
local AddBorder = ns.AddBorder
local SafeUnitBoolean = ns.SafeUnitBoolean
local SafeUnitNumber = ns.SafeUnitNumber

local NAMEPLATE_DEBUFF_FRAME_NAME = "ReRansCustomlizationsNameplateDebuffGrid"
local NAMEPLATE_DEBUFF_DEFAULT_X = 0
local NAMEPLATE_DEBUFF_DEFAULT_Y = -220
local NAMEPLATE_DEBUFF_DEFAULT_DIRECTION = "RIGHT"
local NAMEPLATE_DEBUFF_DEFAULT_PER_ROW = 8
local NAMEPLATE_DEBUFF_DEFAULT_SIZE = 12
local NAMEPLATE_DEBUFF_MIN_SIZE = 4
local NAMEPLATE_DEBUFF_MAX_SIZE = 40
local NAMEPLATE_DEBUFF_MAX_UNITS = 40
local NAMEPLATE_DEBUFF_MAX_SPELLS = 16
local NAMEPLATE_DEBUFF_GAP = 1
local NAMEPLATE_DEBUFF_FILTER = "HARMFUL|PLAYER|INCLUDE_NAME_PLATE_ONLY"
local NAMEPLATE_DEBUFF_DEFAULT_COLORS = {
    noBuffColor = { r = 1, g = 1, b = 1 },
    hasBuffColor = { r = 0.10, g = 0.45, b = 1.00 },
}

local nameplateDebuffSettings
local nameplateDebuffRoot
local nameplateDebuffPositionControls
local nameplateDebuffConfigPreviewActive = false
local nameplateDebuffPositionUnlocked = false
local nameplateDebuffMonitoringEnabled = false
local nameplateDebuffSyncingControls = false
local nameplateDebuffTicker
local nameplateDebuffPendingSecureRebuild = false
local nameplateDebuffConfigRevision = 1
local nameplateDebuffRetryScheduled = false
local nameplateDebuffPendingText
local nameplateDebuffHosts = {}
local nameplateDebuffFreeHosts = {}
local nameplateDebuffStates = {}
local nameplateDebuffPreviewSquares = {}
local nameplateDebuffEventFrame = CreateFrame("Frame")
local nameplateDebuffDragFrame = CreateFrame("Frame")
local RefreshNameplateDebuffDisplay
local ApplyNameplateDebuffPosition
local SyncNameplateDebuffPositionControls
local ReconcileAllNameplates
local TryApplyNameplateDebuffSecureConfiguration
local UpdateNameplateDebuffPendingText
local ScheduleNameplateDebuffSecureRetry
local ApplyNameplateDebuffColors

local function ParseNameplateDebuffSpellID(value)
    if IsSecretValue and IsSecretValue(value) then
        return nil
    end

    if type(value) == "string" and not value:match("^%d+$") then
        return nil
    end

    local spellID = tonumber(value)
    if not spellID or spellID ~= spellID or spellID == math.huge or spellID == -math.huge then
        return nil
    end

    if spellID ~= math.floor(spellID) then
        return nil
    end
    spellID = math.floor(spellID)
    if spellID < 1 or spellID > 2147483647 then
        return nil
    end

    return spellID
end

local function NormalizeNameplateDebuffSpellIDs(value)
    local normalized = {}
    local seen = {}

    if type(value) == "table" and not (IsSecretTable and IsSecretTable(value)) then
        local indexes = {}
        for index in pairs(value) do
            if type(index) == "number" and index >= 1 and index == math.floor(index) then
                indexes[#indexes + 1] = index
            end
        end
        table.sort(indexes)

        for _, index in ipairs(indexes) do
            local spellID = ParseNameplateDebuffSpellID(value[index])
            if spellID and not seen[spellID] then
                normalized[#normalized + 1] = spellID
                seen[spellID] = true
                if #normalized >= NAMEPLATE_DEBUFF_MAX_SPELLS then
                    break
                end
            end
        end
    end

    return normalized
end

local function IsNameplateDebuffUnitToken(unit)
    if IsSecretValue and IsSecretValue(unit) then
        return false
    end
    if type(unit) ~= "string" then
        return false
    end

    local index = tonumber(unit:match("^nameplate(%d+)$"))
    return index and index >= 1 and index <= NAMEPLATE_DEBUFF_MAX_UNITS, index
end


local function GetNameplateDebuffFootprint(count)
    count = math.max(1, math.min(NAMEPLATE_DEBUFF_MAX_UNITS, count or NAMEPLATE_DEBUFF_MAX_UNITS))
    local columns = math.min(nameplateDebuffSettings.squaresPerRow, count)
    local rows = math.ceil(count / nameplateDebuffSettings.squaresPerRow)
    local step = nameplateDebuffSettings.squareSize + NAMEPLATE_DEBUFF_GAP
    return columns * step - NAMEPLATE_DEBUFF_GAP, rows * step - NAMEPLATE_DEBUFF_GAP
end

local function GetNameplateDebuffPositionBounds()
    local width, height = GetNameplateDebuffFootprint(NAMEPLATE_DEBUFF_MAX_UNITS)
    local halfScreenWidth = UIParent:GetWidth() / 2
    local halfScreenHeight = UIParent:GetHeight() / 2
    local minimumX, maximumX

    if width >= UIParent:GetWidth() then
        minimumX = nameplateDebuffSettings.growthDirection == "LEFT"
            and halfScreenWidth or -halfScreenWidth
        maximumX = minimumX
    elseif nameplateDebuffSettings.growthDirection == "LEFT" then
        minimumX = -halfScreenWidth + width
        maximumX = halfScreenWidth
    else
        minimumX = -halfScreenWidth
        maximumX = halfScreenWidth - width
    end

    local minimumY, maximumY
    if height >= UIParent:GetHeight() then
        minimumY = halfScreenHeight
        maximumY = halfScreenHeight
    else
        minimumY = -halfScreenHeight + height
        maximumY = halfScreenHeight
    end
    minimumX, maximumX = math.ceil(minimumX), math.floor(maximumX)
    minimumY, maximumY = math.ceil(minimumY), math.floor(maximumY)
    if minimumX > maximumX then
        local fixedX = NormalizeCoordinate((minimumX + maximumX) / 2, 0)
        minimumX, maximumX = fixedX, fixedX
    end
    if minimumY > maximumY then
        local fixedY = NormalizeCoordinate((minimumY + maximumY) / 2, 0)
        minimumY, maximumY = fixedY, fixedY
    end
    return minimumX, maximumX, minimumY, maximumY
end

local function ClampNameplateDebuffPosition()
    local minimumX, maximumX, minimumY, maximumY = GetNameplateDebuffPositionBounds()
    nameplateDebuffSettings.x = NormalizeCoordinate(
        Clamp(nameplateDebuffSettings.x, minimumX, maximumX), NAMEPLATE_DEBUFF_DEFAULT_X)
    nameplateDebuffSettings.y = NormalizeCoordinate(
        Clamp(nameplateDebuffSettings.y, minimumY, maximumY), NAMEPLATE_DEBUFF_DEFAULT_Y)
end

SyncNameplateDebuffPositionControls = function()
    if not nameplateDebuffPositionControls then
        return
    end

    local minimumX, maximumX, minimumY, maximumY = GetNameplateDebuffPositionBounds()
    nameplateDebuffSyncingControls = true
    nameplateDebuffPositionControls.x.slider:SetMinMaxValues(minimumX, maximumX)
    nameplateDebuffPositionControls.y.slider:SetMinMaxValues(minimumY, maximumY)
    nameplateDebuffPositionControls.x.slider:SetValue(nameplateDebuffSettings.x)
    nameplateDebuffPositionControls.y.slider:SetValue(nameplateDebuffSettings.y)
    nameplateDebuffPositionControls.x.valueText:SetText(tostring(nameplateDebuffSettings.x))
    nameplateDebuffPositionControls.y.valueText:SetText(tostring(nameplateDebuffSettings.y))
    nameplateDebuffSyncingControls = false
end

ApplyNameplateDebuffPosition = function()
    if not nameplateDebuffRoot or not nameplateDebuffSettings then
        return
    end

    ClampNameplateDebuffPosition()
    nameplateDebuffRoot:ClearAllPoints()
    local point = nameplateDebuffSettings.growthDirection == "LEFT" and "TOPRIGHT" or "TOPLEFT"
    nameplateDebuffRoot:SetPoint(point, UIParent, "CENTER",
        nameplateDebuffSettings.x, nameplateDebuffSettings.y)
    SyncNameplateDebuffPositionControls()
end

local function SaveDraggedNameplateDebuffPosition(reanchor)
    if not nameplateDebuffRoot then
        return
    end

    local edgeX = nameplateDebuffSettings.growthDirection == "LEFT"
        and nameplateDebuffRoot:GetRight() or nameplateDebuffRoot:GetLeft()
    local top = nameplateDebuffRoot:GetTop()
    local parentX, parentY = UIParent:GetCenter()
    if not edgeX or not top or not parentX or not parentY then
        if reanchor then
            ApplyNameplateDebuffPosition()
        end
        return
    end

    local rootScale = nameplateDebuffRoot:GetEffectiveScale()
    local parentScale = UIParent:GetEffectiveScale()
    nameplateDebuffSettings.x = NormalizeCoordinate(
        (edgeX * rootScale - parentX * parentScale) / parentScale, nameplateDebuffSettings.x)
    nameplateDebuffSettings.y = NormalizeCoordinate(
        (top * rootScale - parentY * parentScale) / parentScale, nameplateDebuffSettings.y)
    ClampNameplateDebuffPosition()
    SyncNameplateDebuffPositionControls()

    if reanchor then
        ApplyNameplateDebuffPosition()
    end
end

local function EnsureNameplateDebuffRoot()
    if nameplateDebuffRoot then
        return nameplateDebuffRoot
    end

    local root = CreateFrame("Frame", NAMEPLATE_DEBUFF_FRAME_NAME, UIParent)
    root:SetSize(1, 1)
    root:SetFrameStrata("MEDIUM")
    root:SetClampedToScreen(true)
    root:SetMovable(false)
    root:EnableMouse(false)
    root:RegisterForDrag("LeftButton")
    root:SetScript("OnDragStart", function(self)
        if nameplateDebuffPositionUnlocked then
            self:StartMoving()
            nameplateDebuffDragFrame:SetScript("OnUpdate", function()
                SaveDraggedNameplateDebuffPosition(false)
            end)
        end
    end)
    root:SetScript("OnDragStop", function(self)
        nameplateDebuffDragFrame:SetScript("OnUpdate", nil)
        self:StopMovingOrSizing()
        if nameplateDebuffPositionUnlocked then
            SaveDraggedNameplateDebuffPosition(true)
        end
    end)
    root:Hide()
    nameplateDebuffRoot = root
    ApplyNameplateDebuffPosition()
    return root
end

local function IsNameplateDebuffPreviewActive()
    return nameplateDebuffConfigPreviewActive or nameplateDebuffPositionUnlocked
end

local function EnsureNameplateDebuffPreviewSquare(index)
    local square = nameplateDebuffPreviewSquares[index]
    if square then
        return square
    end

    square = CreateFrame("Frame", nil, EnsureNameplateDebuffRoot())
    local noBuffColor = nameplateDebuffSettings.noBuffColor
    local hasBuffColor = nameplateDebuffSettings.hasBuffColor
    square.white = CreateSolidTexture(square, "BACKGROUND",
        noBuffColor.r, noBuffColor.g, noBuffColor.b, 1)
    square.white:SetAllPoints()
    square.blue = CreateSolidTexture(square, "ARTWORK",
        hasBuffColor.r, hasBuffColor.g, hasBuffColor.b, 1)
    square.blue:SetPoint("TOPLEFT", 1, -1)
    square.blue:SetPoint("BOTTOMRIGHT", -1, 1)
    AddBorder(square, 1, 0.05, 0.05, 0.07, 1)
    nameplateDebuffPreviewSquares[index] = square
    return square
end

local function LayoutNameplateDebuffFrames(frames, count)
    local root = EnsureNameplateDebuffRoot()
    local size = nameplateDebuffSettings.squareSize
    local step = size + NAMEPLATE_DEBUFF_GAP
    local width, height = GetNameplateDebuffFootprint(count)
    root:SetSize(width, height)

    for index = 1, count do
        local frame = frames[index]
        local column = (index - 1) % nameplateDebuffSettings.squaresPerRow
        local row = math.floor((index - 1) / nameplateDebuffSettings.squaresPerRow)
        frame:ClearAllPoints()
        frame:SetSize(size, size)
        frame:SetFrameLevel(root:GetFrameLevel() + 1)
        if frame.container then
            frame.container:SetFrameLevel(frame:GetFrameLevel() + 1)
            frame.blueGate:SetFrameLevel(frame.container:GetFrameLevel() + 1)
        end
        if nameplateDebuffSettings.growthDirection == "LEFT" then
            frame:SetPoint("TOPRIGHT", root, "TOPRIGHT", -column * step, -row * step)
        else
            frame:SetPoint("TOPLEFT", root, "TOPLEFT", column * step, -row * step)
        end
        frame:Show()
    end
end

-- Each spell gets a one-frame group. The secure layout is S + K*S pixels wide
-- (one S padding plus K matched groups). The blue inset begins just after N*S,
-- so child clipping reveals it only when K == N, without reading aura data.
local function ConfigureNameplateDebuffHost(host)
    local container = host.container
    local size = nameplateDebuffSettings.squareSize
    local spellCount = #nameplateDebuffSettings.spellIDs

    container:SetFlowLayoutPadding(size, 0, 0, 0)
    container:SetFlowLayoutAxis(AnchorUtil.FlowLayoutAxis.Horizontal)
    container:SetFlowLayoutAnchorPoint("TOPLEFT")
    container:SetFlowLayoutGrowthDirection(AnchorUtil.FlowDirection.Right, AnchorUtil.FlowDirection.Down)
    container:SetFlowLayoutMaximumLineSize((spellCount + 1) * size + 0.1)

    for index = 1, spellCount do
        local group = host.groups[index]
        if not group then
            local key = "rrcDebuff" .. index
            local function InitializeAuraButton(button)
                button:SetSize(nameplateDebuffSettings.squareSize, nameplateDebuffSettings.squareSize)
                button:SetAlpha(0)
                button:EnableMouse(false)
                if button.SetMouseMotionEnabled then
                    button:SetMouseMotionEnabled(false)
                end
                if button.ClearIcon then
                    button:ClearIcon()
                end
            end
            container:AddAuraGroup(key, NAMEPLATE_DEBUFF_FILTER, {
                maxFrameCount = 1,
                initializeFrame = InitializeAuraButton,
            })
            group = { key = key }
            host.groups[index] = group
        else
            container:SetAuraGroupFilterString(group.key, NAMEPLATE_DEBUFF_FILTER)
        end

        container:SetAuraGroupMaxFrameCount(group.key, 1)
        container:SetAuraGroupCandidateFilters(group.key, {
            includeSpellIDs = { [nameplateDebuffSettings.spellIDs[index]] = true },
        })
        container:SetAuraGroupLayout(group.key, {
            elementWidth = size,
            elementHeight = size,
            elementSpacing = 0,
            groupSpacing = 0,
            lineSpacing = 0,
            layoutIndex = index,
        })
        if AuraContainerSortMethod and AuraContainerSortDirection then
            container:SetAuraGroupSortMethod(group.key,
                AuraContainerSortMethod.Default, AuraContainerSortDirection.Normal)
        end
    end

    for index = spellCount + 1, #host.groups do
        container:SetAuraGroupMaxFrameCount(host.groups[index].key, 0)
    end

    container:ClearAllPoints()
    container:SetPoint("TOPLEFT", host, "TOPLEFT", -spellCount * size, 0)
    host.blueGate:ClearAllPoints()
    host.blueGate:SetPoint("TOPLEFT", container, "TOPLEFT", spellCount * size + 1, -1)
    host.blueGate:SetSize(math.max(1, size - 2), math.max(1, size - 2))
    host.blueGate:SetShown(spellCount > 0)
    host:SetSize(size, size)
    host.appliedRevision = nameplateDebuffConfigRevision
end

local function CreateNameplateDebuffHost()
    local root = EnsureNameplateDebuffRoot()
    local index = #nameplateDebuffHosts + 1
    local host = CreateFrame("Frame", nil, root)
    host:SetSize(nameplateDebuffSettings.squareSize, nameplateDebuffSettings.squareSize)
    local noBuffColor = nameplateDebuffSettings.noBuffColor
    local hasBuffColor = nameplateDebuffSettings.hasBuffColor
    host.white = CreateSolidTexture(host, "BACKGROUND",
        noBuffColor.r, noBuffColor.g, noBuffColor.b, 1)
    host.white:SetAllPoints()
    AddBorder(host, 1, 0.05, 0.05, 0.07, 1)

    local container = CreateFrame("AuraContainer", nil, host, "CustomAuraContainerTemplate")
    container:SetSize(1, 1)
    container:SetFrameLevel(host:GetFrameLevel() + 1)
    container:SetClipsChildren(true)
    container:SetFlattensRenderLayers(true)
    container:SetPoint("TOPLEFT", host, "TOPLEFT")
    host.container = container
    host.blueGate = CreateFrame("Frame", nil, container)
    host.blueGate:SetFrameLevel(container:GetFrameLevel() + 1)
    host.blueTexture = CreateSolidTexture(host.blueGate, "ARTWORK",
        hasBuffColor.r, hasBuffColor.g, hasBuffColor.b, 1)
    host.blueTexture:SetAllPoints()
    host.groups = {}
    host:Hide()
    container:Hide()

    nameplateDebuffHosts[index] = host
    return host
end

ApplyNameplateDebuffColors = function()
    if not nameplateDebuffSettings then
        return
    end

    local noBuffColor = nameplateDebuffSettings.noBuffColor
    local hasBuffColor = nameplateDebuffSettings.hasBuffColor
    for _, square in ipairs(nameplateDebuffPreviewSquares) do
        square.white:SetColorTexture(noBuffColor.r, noBuffColor.g, noBuffColor.b, 1)
        square.blue:SetColorTexture(hasBuffColor.r, hasBuffColor.g, hasBuffColor.b, 1)
    end
    for _, host in ipairs(nameplateDebuffHosts) do
        host.white:SetColorTexture(noBuffColor.r, noBuffColor.g, noBuffColor.b, 1)
        host.blueTexture:SetColorTexture(hasBuffColor.r, hasBuffColor.g, hasBuffColor.b, 1)
    end
end

local function BindNameplateDebuffHost(host, unit)
    host.unit = unit
    host:SetSize(nameplateDebuffSettings.squareSize, nameplateDebuffSettings.squareSize)
    host.container:Show()
    host.container:SetUnit(unit)
    host.container:SetEnabled(#nameplateDebuffSettings.spellIDs > 0)
    host.container:UpdateAllAuras()
end

local function ReleaseNameplateDebuffHost(host)
    if not host then
        return
    end

    pcall(host.container.SetEnabled, host.container, false)
    pcall(host.container.SetUnit, host.container, nil)
    host.container:Hide()
    host:Hide()
    host.unit = nil
    nameplateDebuffFreeHosts[#nameplateDebuffFreeHosts + 1] = host
end

local function AcquireNameplateDebuffHost(unit)
    local host = table.remove(nameplateDebuffFreeHosts)
    if not host then
        local created
        created, host = pcall(CreateNameplateDebuffHost)
        if not created or not host then
            nameplateDebuffPendingSecureRebuild = true
            UpdateNameplateDebuffPendingText()
            ScheduleNameplateDebuffSecureRetry()
            return nil
        end
    end

    if host.appliedRevision ~= nameplateDebuffConfigRevision then
        local configured = pcall(ConfigureNameplateDebuffHost, host)
        if not configured then
            host:Hide()
            nameplateDebuffFreeHosts[#nameplateDebuffFreeHosts + 1] = host
            nameplateDebuffPendingSecureRebuild = true
            UpdateNameplateDebuffPendingText()
            ScheduleNameplateDebuffSecureRetry()
            return nil
        end
    end

    local bound = pcall(BindNameplateDebuffHost, host, unit)
    if not bound then
        pcall(host.container.SetEnabled, host.container, false)
        host.container:Hide()
        host:Hide()
        host.unit = nil
        nameplateDebuffFreeHosts[#nameplateDebuffFreeHosts + 1] = host
        nameplateDebuffPendingSecureRebuild = true
        UpdateNameplateDebuffPendingText()
        ScheduleNameplateDebuffSecureRetry()
        return nil
    end
    return host
end

UpdateNameplateDebuffPendingText = function()
    if nameplateDebuffPendingText then
        nameplateDebuffPendingText:SetShown(nameplateDebuffPendingSecureRebuild)
    end
end

ScheduleNameplateDebuffSecureRetry = function()
    if nameplateDebuffRetryScheduled or nameplateDebuffTicker
        or not nameplateDebuffPendingSecureRebuild
        or not C_Timer or not C_Timer.After then
        return
    end

    nameplateDebuffRetryScheduled = true
    C_Timer.After(0.5, function()
        nameplateDebuffRetryScheduled = false
        if nameplateDebuffPendingSecureRebuild
            and not TryApplyNameplateDebuffSecureConfiguration() then
            ScheduleNameplateDebuffSecureRetry()
        end
    end)
end

local function RequestNameplateDebuffSecureRebuild()
    nameplateDebuffConfigRevision = nameplateDebuffConfigRevision + 1
    nameplateDebuffPendingSecureRebuild = true
    UpdateNameplateDebuffPendingText()

    -- Coalesce repeated slider changes while the static preview is visible.
    if IsNameplateDebuffPreviewActive() then
        ScheduleNameplateDebuffSecureRetry()
    elseif not TryApplyNameplateDebuffSecureConfiguration() then
        ScheduleNameplateDebuffSecureRetry()
    end
    RefreshNameplateDebuffDisplay()
end

TryApplyNameplateDebuffSecureConfiguration = function()
    if not nameplateDebuffPendingSecureRebuild then
        return true
    end

    for _, host in ipairs(nameplateDebuffHosts) do
        local configured = pcall(ConfigureNameplateDebuffHost, host)
        if not configured then
            UpdateNameplateDebuffPendingText()
            return false
        end
        if host.unit then
            local bound = pcall(BindNameplateDebuffHost, host, host.unit)
            if not bound then
                UpdateNameplateDebuffPendingText()
                return false
            end
        end
    end

    nameplateDebuffPendingSecureRebuild = false
    UpdateNameplateDebuffPendingText()
    if ReconcileAllNameplates then
        ReconcileAllNameplates(true)
    end
    RefreshNameplateDebuffDisplay()
    if nameplateDebuffPendingSecureRebuild then
        UpdateNameplateDebuffPendingText()
        return false
    end
    return true
end

local function IsNameplateDebuffUnitEligible(unit, state)
    if not state or not state.present then
        return false
    end
    if SafeUnitBoolean(UnitExists, unit) ~= true then
        return false
    end
    if SafeUnitBoolean(UnitCanAttack, "player", unit) ~= true then
        return false
    end
    if SafeUnitBoolean(UnitIsDead, unit) == true then
        return false
    end

    if SafeUnitBoolean(UnitAffectingCombat, unit) == true then
        return true
    end
    if SafeUnitNumber(UnitThreatSituation, "player", unit) ~= nil then
        return true
    end
    if state.healthActivityUntil and state.healthActivityUntil > GetTime() then
        return true
    end

    local playerInCombat = SafeUnitBoolean(UnitAffectingCombat, "player") == true
    if not playerInCombat then
        return false
    end
    if SafeUnitBoolean(UnitIsUnit, unit, "target") == true
        or SafeUnitBoolean(UnitIsUnit, unit, "softenemy") == true then
        return true
    end

    local health = SafeUnitNumber(UnitHealth, unit)
    local maximumHealth = SafeUnitNumber(UnitHealthMax, unit)
    return health ~= nil and maximumHealth ~= nil
        and maximumHealth > 0 and health < maximumHealth
end

local function UpdateNameplateDebuffUnit(unit)
    local valid = IsNameplateDebuffUnitToken(unit)
    if not valid then
        return false
    end

    local state = nameplateDebuffStates[unit]
    if not state then
        state = { present = false, eligible = false }
        nameplateDebuffStates[unit] = state
    end

    local eligible = IsNameplateDebuffUnitEligible(unit, state)
    local changed = eligible ~= state.eligible
    state.eligible = eligible

    if eligible and not nameplateDebuffPendingSecureRebuild then
        if not state.host then
            state.host = AcquireNameplateDebuffHost(unit)
            changed = true
        end
    elseif state.host then
        ReleaseNameplateDebuffHost(state.host)
        state.host = nil
        changed = true
    end

    return changed
end

ReconcileAllNameplates = function(suppressRefresh)
    local changed = false
    for unit, state in pairs(nameplateDebuffStates) do
        if state.present and UpdateNameplateDebuffUnit(unit) then
            changed = true
        end
    end
    if changed and not suppressRefresh then
        RefreshNameplateDebuffDisplay()
    end
    return changed
end

local function RemoveNameplateDebuffUnit(unit, suppressRefresh)
    local state = nameplateDebuffStates[unit]
    if not state then
        return false
    end

    local changed = state.present or state.eligible or state.host ~= nil
    state.present = false
    state.eligible = false
    state.healthActivityUntil = nil
    state.lastHealth = nil
    if state.host then
        ReleaseNameplateDebuffHost(state.host)
        state.host = nil
    end
    if changed and not suppressRefresh then
        RefreshNameplateDebuffDisplay()
    end
    return changed
end

local function AddNameplateDebuffUnit(unit, suppressRefresh)
    local valid = IsNameplateDebuffUnitToken(unit)
    if not valid then
        return false
    end

    local state = nameplateDebuffStates[unit]
    if not state then
        state = { present = true, eligible = false }
        nameplateDebuffStates[unit] = state
    else
        state.present = true
    end
    state.healthActivityUntil = nil
    state.lastHealth = SafeUnitNumber(UnitHealth, unit)
    local previousHost = state.host
    local changed = UpdateNameplateDebuffUnit(unit)
    if previousHost and state.host == previousHost then
        local rebound = pcall(BindNameplateDebuffHost, state.host, unit)
        if not rebound then
            nameplateDebuffPendingSecureRebuild = true
            UpdateNameplateDebuffPendingText()
            ScheduleNameplateDebuffSecureRetry()
            changed = true
        end
    end
    if changed and not suppressRefresh then
        RefreshNameplateDebuffDisplay()
    end
    return changed
end

local function ScanExistingNameplates()
    for unit, state in pairs(nameplateDebuffStates) do
        state.present = false
        state.eligible = false
        state.healthActivityUntil = nil
        state.lastHealth = nil
        if state.host then
            ReleaseNameplateDebuffHost(state.host)
            state.host = nil
        end
    end

    if C_NamePlate and C_NamePlate.GetNamePlateForUnit then
        for index = 1, NAMEPLATE_DEBUFF_MAX_UNITS do
            local unit = "nameplate" .. index
            local succeeded, plate = pcall(C_NamePlate.GetNamePlateForUnit, unit)
            if succeeded and plate then
                AddNameplateDebuffUnit(unit, true)
            end
        end
    end
    RefreshNameplateDebuffDisplay()
end

local function GetSortedActiveNameplateDebuffHosts()
    local entries = {}
    for unit, state in pairs(nameplateDebuffStates) do
        if state.eligible and state.host then
            local _, index = IsNameplateDebuffUnitToken(unit)
            entries[#entries + 1] = { index = index, host = state.host }
        end
    end
    table.sort(entries, function(left, right)
        return left.index < right.index
    end)

    local hosts = {}
    for index, entry in ipairs(entries) do
        hosts[index] = entry.host
    end
    return hosts
end

RefreshNameplateDebuffDisplay = function()
    if not nameplateDebuffSettings then
        return
    end

    local previewActive = IsNameplateDebuffPreviewActive()
    if not nameplateDebuffRoot and not previewActive and not nameplateDebuffMonitoringEnabled then
        return
    end

    local root = EnsureNameplateDebuffRoot()
    for _, square in ipairs(nameplateDebuffPreviewSquares) do
        square:Hide()
    end
    for _, host in ipairs(nameplateDebuffHosts) do
        host:Hide()
    end

    root:SetMovable(nameplateDebuffPositionUnlocked)
    root:EnableMouse(nameplateDebuffPositionUnlocked)

    if previewActive then
        local count = math.min(NAMEPLATE_DEBUFF_MAX_UNITS,
            nameplateDebuffSettings.squaresPerRow + 2)
        local previewFrames = {}
        for index = 1, count do
            local square = EnsureNameplateDebuffPreviewSquare(index)
            square.blue:SetShown(index % 3 == 0)
            previewFrames[index] = square
        end
        root:SetFrameStrata("DIALOG")
        root:SetFrameLevel(100)
        LayoutNameplateDebuffFrames(previewFrames, count)
        ApplyNameplateDebuffPosition()
        root:Show()
        return
    end

    if not nameplateDebuffMonitoringEnabled or nameplateDebuffPendingSecureRebuild then
        root:Hide()
        return
    end

    local hosts = GetSortedActiveNameplateDebuffHosts()
    if #hosts == 0 then
        root:Hide()
        return
    end

    root:SetFrameStrata("MEDIUM")
    root:SetFrameLevel(0)
    LayoutNameplateDebuffFrames(hosts, #hosts)
    ApplyNameplateDebuffPosition()
    root:Show()
    for _, host in ipairs(hosts) do
        host:Show()
    end
end

local function RefreshActiveNameplateDebuffAuras()
    for _, state in pairs(nameplateDebuffStates) do
        if state.host then
            local refreshed = pcall(state.host.container.UpdateAllAuras, state.host.container)
            if not refreshed then
                nameplateDebuffPendingSecureRebuild = true
                UpdateNameplateDebuffPendingText()
                ScheduleNameplateDebuffSecureRetry()
                RefreshNameplateDebuffDisplay()
                return
            end
        end
    end
end

local function SetNameplateDebuffConfigPreviewActive(active)
    local wasActive = IsNameplateDebuffPreviewActive()
    nameplateDebuffConfigPreviewActive = not not active
    local isActive = IsNameplateDebuffPreviewActive()
    RefreshNameplateDebuffDisplay()
    if wasActive and not isActive then
        RefreshActiveNameplateDebuffAuras()
    end
end

local function UpdateNameplateDebuffUnlockButton()
    if nameplateDebuffPositionControls and nameplateDebuffPositionControls.unlockButton then
        nameplateDebuffPositionControls.unlockButton:SetText(
            nameplateDebuffPositionUnlocked and "锁定" or "解除锁定")
    end
end

local function SetNameplateDebuffPositionUnlocked(unlocked)
    local wasPreviewActive = IsNameplateDebuffPreviewActive()
    nameplateDebuffPositionUnlocked = not not unlocked
    if not nameplateDebuffPositionUnlocked then
        nameplateDebuffDragFrame:SetScript("OnUpdate", nil)
        if nameplateDebuffRoot then
            nameplateDebuffRoot:StopMovingOrSizing()
        end
    end
    UpdateNameplateDebuffUnlockButton()
    RefreshNameplateDebuffDisplay()
    if wasPreviewActive and not IsNameplateDebuffPreviewActive() then
        RefreshActiveNameplateDebuffAuras()
    end
end

local function SetNameplateDebuffCoordinate(axis, value)
    local minimumX, maximumX, minimumY, maximumY = GetNameplateDebuffPositionBounds()
    value = NormalizeCoordinate(value, nameplateDebuffSettings[axis])
    if axis == "x" then
        nameplateDebuffSettings.x = Clamp(value, minimumX, maximumX)
    else
        nameplateDebuffSettings.y = Clamp(value, minimumY, maximumY)
    end
    ApplyNameplateDebuffPosition()
end

local function SetNameplateDebuffMonitoringEnabled(enabled)
    enabled = not not enabled
    nameplateDebuffSettings.enabled = enabled

    if nameplateDebuffMonitoringEnabled == enabled then
        if enabled then
            ScanExistingNameplates()
        end
        RefreshNameplateDebuffDisplay()
        return
    end

    nameplateDebuffMonitoringEnabled = enabled
    if enabled then
        TryApplyNameplateDebuffSecureConfiguration()
        nameplateDebuffEventFrame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
        nameplateDebuffEventFrame:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
        nameplateDebuffEventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
        nameplateDebuffEventFrame:RegisterEvent("UNIT_FACTION")
        nameplateDebuffEventFrame:RegisterEvent("UNIT_FLAGS")
        nameplateDebuffEventFrame:RegisterEvent("UNIT_HEALTH")
        nameplateDebuffEventFrame:RegisterEvent("UNIT_THREAT_LIST_UPDATE")
        nameplateDebuffEventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
        nameplateDebuffEventFrame:RegisterEvent("PLAYER_SOFT_ENEMY_CHANGED")
        nameplateDebuffEventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
        nameplateDebuffEventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
        if C_Timer and C_Timer.NewTicker then
            nameplateDebuffTicker = C_Timer.NewTicker(0.5, function()
                if nameplateDebuffPendingSecureRebuild then
                    TryApplyNameplateDebuffSecureConfiguration()
                end
                ReconcileAllNameplates()
            end)
        end
        ScanExistingNameplates()
    else
        nameplateDebuffEventFrame:UnregisterAllEvents()
        if nameplateDebuffTicker then
            nameplateDebuffTicker:Cancel()
            nameplateDebuffTicker = nil
        end
        for unit in pairs(nameplateDebuffStates) do
            RemoveNameplateDebuffUnit(unit, true)
        end
        nameplateDebuffPendingSecureRebuild = false
        UpdateNameplateDebuffPendingText()
    end
    RefreshNameplateDebuffDisplay()
end

nameplateDebuffEventFrame:SetScript("OnEvent", function(_, event, unit)
    if event == "NAME_PLATE_UNIT_ADDED" then
        AddNameplateDebuffUnit(unit)
    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        if IsNameplateDebuffUnitToken(unit) then
            RemoveNameplateDebuffUnit(unit)
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        if C_Timer and C_Timer.After then
            C_Timer.After(0, function()
                if nameplateDebuffMonitoringEnabled then
                    ScanExistingNameplates()
                end
            end)
        elseif nameplateDebuffMonitoringEnabled then
            ScanExistingNameplates()
        end
    elseif event == "UNIT_HEALTH" then
        if IsNameplateDebuffUnitToken(unit) then
            local state = nameplateDebuffStates[unit]
            if state and state.present then
                local health = SafeUnitNumber(UnitHealth, unit)
                local maximumHealth = SafeUnitNumber(UnitHealthMax, unit)
                local healthDecreased = health and state.lastHealth and health < state.lastHealth
                if not state.lastHealth and health and maximumHealth and maximumHealth > 0 then
                    healthDecreased = health < maximumHealth
                end
                if health then
                    state.lastHealth = health
                end
                if healthDecreased then
                    state.healthActivityUntil = GetTime() + 5
                    if UpdateNameplateDebuffUnit(unit) then
                        RefreshNameplateDebuffDisplay()
                    end
                end
            end
        end
    elseif event == "UNIT_FACTION" or event == "UNIT_FLAGS"
        or event == "UNIT_THREAT_LIST_UPDATE" then
        if IsNameplateDebuffUnitToken(unit) and UpdateNameplateDebuffUnit(unit) then
            RefreshNameplateDebuffDisplay()
        end
    elseif event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_TARGET_CHANGED"
        or event == "PLAYER_SOFT_ENEMY_CHANGED" then
        ReconcileAllNameplates()
    elseif event == "PLAYER_REGEN_ENABLED" then
        for _, state in pairs(nameplateDebuffStates) do
            state.healthActivityUntil = nil
        end
        ReconcileAllNameplates()
    end
end)

local function InitializeNameplateDebuffSettings(db)
    if type(db.nameplateDebuffs) ~= "table" then
        db.nameplateDebuffs = {}
    end

    nameplateDebuffSettings = db.nameplateDebuffs
    if type(nameplateDebuffSettings.enabled) ~= "boolean" then
        nameplateDebuffSettings.enabled = false
    end
    nameplateDebuffSettings.spellIDs = NormalizeNameplateDebuffSpellIDs(nameplateDebuffSettings.spellIDs)
    nameplateDebuffSettings.growthDirection = nameplateDebuffSettings.growthDirection == "LEFT"
        and "LEFT" or NAMEPLATE_DEBUFF_DEFAULT_DIRECTION
    nameplateDebuffSettings.squaresPerRow = NormalizeInteger(nameplateDebuffSettings.squaresPerRow,
        NAMEPLATE_DEBUFF_DEFAULT_PER_ROW, 1, NAMEPLATE_DEBUFF_MAX_UNITS)
    nameplateDebuffSettings.squareSize = NormalizeInteger(nameplateDebuffSettings.squareSize,
        NAMEPLATE_DEBUFF_DEFAULT_SIZE, NAMEPLATE_DEBUFF_MIN_SIZE, NAMEPLATE_DEBUFF_MAX_SIZE)
    nameplateDebuffSettings.noBuffColor = NormalizeColor(nameplateDebuffSettings.noBuffColor,
        NAMEPLATE_DEBUFF_DEFAULT_COLORS.noBuffColor)
    nameplateDebuffSettings.hasBuffColor = NormalizeColor(nameplateDebuffSettings.hasBuffColor,
        NAMEPLATE_DEBUFF_DEFAULT_COLORS.hasBuffColor)
    nameplateDebuffSettings.x = NormalizeCoordinate(nameplateDebuffSettings.x, NAMEPLATE_DEBUFF_DEFAULT_X)
    nameplateDebuffSettings.y = NormalizeCoordinate(nameplateDebuffSettings.y, NAMEPLATE_DEBUFF_DEFAULT_Y)
end

ns.NameplateDebuffs = {
    MAX_SPELLS = NAMEPLATE_DEBUFF_MAX_SPELLS,
    MAX_UNITS = NAMEPLATE_DEBUFF_MAX_UNITS,
    MIN_SIZE = NAMEPLATE_DEBUFF_MIN_SIZE,
    MAX_SIZE = NAMEPLATE_DEBUFF_MAX_SIZE,
    InitializeSettings = InitializeNameplateDebuffSettings,
    GetSettings = function()
        return nameplateDebuffSettings
    end,
    SetMonitoringEnabled = SetNameplateDebuffMonitoringEnabled,
    RefreshDisplay = RefreshNameplateDebuffDisplay,
    ApplyPosition = ApplyNameplateDebuffPosition,
    ApplyColors = ApplyNameplateDebuffColors,
    RequestSecureRebuild = RequestNameplateDebuffSecureRebuild,
    ParseSpellID = ParseNameplateDebuffSpellID,
    SetConfigPreviewActive = SetNameplateDebuffConfigPreviewActive,
    TogglePositionLock = function()
        SetNameplateDebuffPositionUnlocked(not nameplateDebuffPositionUnlocked)
    end,
    UpdateUnlockButton = UpdateNameplateDebuffUnlockButton,
    SetCoordinate = SetNameplateDebuffCoordinate,
    SyncPositionControls = SyncNameplateDebuffPositionControls,
    ClampPosition = ClampNameplateDebuffPosition,
    SetPositionControls = function(controls)
        nameplateDebuffPositionControls = controls
    end,
    IsSyncingControls = function()
        return nameplateDebuffSyncingControls
    end,
    SetPendingText = function(fontString)
        nameplateDebuffPendingText = fontString
    end,
    UpdatePendingText = UpdateNameplateDebuffPendingText,
    OnDisplayChanged = function()
        if nameplateDebuffSettings then
            ApplyNameplateDebuffPosition()
            RefreshNameplateDebuffDisplay()
        end
    end,
}
