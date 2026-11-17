local _, ns = ...

-- forever 不加载本模块，避免创建监测框架及注册事件。
if ns.IsForever then return end

local IsSecretValue = ns.IsSecretValue
local IsSecretTable = ns.IsSecretTable
local ClearTable = ns.ClearTable
local Clamp = ns.Clamp
local NormalizeColor = ns.NormalizeColor
local NormalizeCoordinate = ns.NormalizeCoordinate
local NormalizeInteger = ns.NormalizeInteger
local CreateSolidTexture = ns.CreateSolidTexture
local AddBorder = ns.AddBorder
local GetSharedMedia = ns.GetSharedMedia
local IsValidSharedMedia = ns.IsValidSharedMedia
local FetchSharedMedia = ns.FetchSharedMedia

local AUTOBURN_FRAME_NAME = "ReRansCustomlizationsAutoburnBar"
local BLOOD_BOIL_SPELL_ID = 50842
local AUTOBURN_DEFAULT_DURATION = 3
local AUTOBURN_MIN_DURATION = 0.1
local AUTOBURN_MAX_DURATION = 60
local AUTOBURN_SIZE = {
    DEFAULT_WIDTH = 240,
    MIN_WIDTH = 100,
    MAX_WIDTH = 600,
    DEFAULT_HEIGHT = 22,
    MIN_HEIGHT = 12,
    MAX_HEIGHT = 80,
    DEFAULT_FONT_SIZE = 12,
    MIN_FONT_SIZE = 8,
    MAX_FONT_SIZE = 32,
    MIN_TEXT_OFFSET = -300,
    MAX_TEXT_OFFSET = 300,
    DEFAULT_DECIMAL_PLACES = 1,
}
local AUTOBURN_DEFAULT_X = 0
local AUTOBURN_DEFAULT_Y = -180
local AUTOBURN_DEFAULT_LABEL = "autoburn"
local AUTOBURN_DEFAULT_MEDIA_KEY = "__default"
local AUTOBURN_DEFAULT_TEXTURE = "Interface\\Buttons\\WHITE8X8"
local AUTOBURN_DEFAULT_READY_COLOR = { r = 0.10, g = 0.45, b = 1.00, a = 1 }
local AUTOBURN_DEFAULT_BLOCKED_COLOR = { r = 0.90, g = 0.10, b = 0.10, a = 1 }

local NamespacedIsSpellOverlayed = C_SpellActivationOverlay
    and C_SpellActivationOverlay.IsSpellOverlayed
local LegacyIsSpellOverlayed = _G.IsSpellOverlayed

local autoburnBar
local settings
local positionControls
local monitoringEnabled = false
local highlightKnown = false
local isHighlighted = false
local timerEndTime
local timerDurationAtStart
local autoburnColorState = "ready"
local configPreviewActive = false
local positionUnlocked = false
local isSyncingPositionControls = false
local RefreshAutoburnDisplay
local ApplyAutoburnAppearance
local ApplyAutoburnPosition
local SyncPositionControls
local syncGeneration = 0
local syncPending = false
local pendingTransitionEvaluation = false
local targetSpellName
local targetSpellIDsDirty = true
local targetSpellIDs = {}
local observedTargetSpellIDs = {}
local activeTargetOverlayIDs = {}
local monitorFrame = CreateFrame("Frame")
local positionDragFrame = CreateFrame("Frame")

local function NormalizeLabel(value)
    if type(value) ~= "string" then
        return AUTOBURN_DEFAULT_LABEL
    end

    return value
end

local function GetDisplayLabel()
    local label = settings.label:gsub("|", "||")
    return label
end

local function IsSafePositiveSpellID(value)
    if IsSecretValue and IsSecretValue(value) then
        return false
    end

    return type(value) == "number" and value > 0
end

local function ParseDuration(value)
    local duration = tonumber(value)

    if not duration or duration ~= duration
        or duration < AUTOBURN_MIN_DURATION
        or duration > AUTOBURN_MAX_DURATION then
        return nil
    end

    return math.floor(duration * 100 + 0.5) / 100
end

local function FormatDuration(duration)
    local text = string.format("%.2f", duration)
    text = text:gsub("0+$", "")
    text = text:gsub("%.$", "")
    return text
end

local function SafeCallSpellIDFunction(api, spellID)
    if type(api) ~= "function" or not IsSafePositiveSpellID(spellID) then
        return nil
    end

    local succeeded, result = pcall(api, spellID)
    if not succeeded or not IsSafePositiveSpellID(result) then
        return nil
    end

    return result
end

local function NormalizeSpellName(name)
    if IsSecretValue and IsSecretValue(name) then
        return nil
    end
    if type(name) ~= "string" then
        return nil
    end

    return string.lower(name)
end

local function GetNormalizedSpellName(spellID)
    if not IsSafePositiveSpellID(spellID) then
        return nil
    end

    if C_Spell and C_Spell.GetSpellName then
        local succeeded, name = pcall(C_Spell.GetSpellName, spellID)
        if succeeded then
            name = NormalizeSpellName(name)
            if name then
                return name
            end
        end
    end

    if C_Spell and C_Spell.GetSpellInfo then
        local succeeded, spellInfo = pcall(C_Spell.GetSpellInfo, spellID)
        if succeeded and type(spellInfo) == "table"
            and not (IsSecretTable and IsSecretTable(spellInfo)) then
            local name = NormalizeSpellName(spellInfo.name)
            if name then
                return name
            end
        end
    end

    if _G.GetSpellInfo then
        local succeeded, name = pcall(_G.GetSpellInfo, spellID)
        if succeeded then
            return NormalizeSpellName(name)
        end
    end

    return nil
end

local function AddTargetSpellID(spellID, pendingSpellIDs)
    if not IsSafePositiveSpellID(spellID) or targetSpellIDs[spellID] then
        return
    end

    targetSpellIDs[spellID] = true
    pendingSpellIDs[#pendingSpellIDs + 1] = spellID
end

local function RebuildTargetSpellIDs()
    ClearTable(targetSpellIDs)
    targetSpellName = GetNormalizedSpellName(BLOOD_BOIL_SPELL_ID)

    local pendingSpellIDs = {}
    AddTargetSpellID(BLOOD_BOIL_SPELL_ID, pendingSpellIDs)

    for spellID in pairs(observedTargetSpellIDs) do
        AddTargetSpellID(spellID, pendingSpellIDs)
    end

    local index = 1
    while index <= #pendingSpellIDs and index <= 32 do
        local spellID = pendingSpellIDs[index]
        index = index + 1

        if C_Spell then
            local overrideSpellID = SafeCallSpellIDFunction(C_Spell.GetOverrideSpell, spellID)
            AddTargetSpellID(overrideSpellID, pendingSpellIDs)

            local baseSpellID = SafeCallSpellIDFunction(C_Spell.GetBaseSpell, spellID)
            AddTargetSpellID(baseSpellID, pendingSpellIDs)
        end
    end

    targetSpellIDsDirty = false
end

local function IsTargetSpell(spellID, normalizedName)
    if not IsSafePositiveSpellID(spellID) then
        return false
    end

    if targetSpellIDs[spellID] then
        return true
    end

    if C_Spell and C_Spell.GetBaseSpell then
        local baseSpellID = SafeCallSpellIDFunction(C_Spell.GetBaseSpell, spellID)
        if baseSpellID and targetSpellIDs[baseSpellID] then
            observedTargetSpellIDs[spellID] = true
            targetSpellIDs[spellID] = true
            targetSpellIDsDirty = true
            return true
        end
    end

    normalizedName = normalizedName or GetNormalizedSpellName(spellID)
    if targetSpellName and normalizedName == targetSpellName then
        observedTargetSpellIDs[spellID] = true
        targetSpellIDs[spellID] = true
        targetSpellIDsDirty = true
        return true
    end

    return false
end

local function CallIsSpellOverlayed(api, spellID)
    if type(api) ~= "function" then
        return nil
    end

    local succeeded, result = pcall(api, spellID)
    if not succeeded or (IsSecretValue and IsSecretValue(result)) or result == nil then
        return nil
    end

    return not not result
end

local function SafeIsSpellOverlayed(spellID)
    if not IsSafePositiveSpellID(spellID) then
        return nil
    end

    local result = CallIsSpellOverlayed(NamespacedIsSpellOverlayed, spellID)
    if result ~= nil then
        return result
    end
    if LegacyIsSpellOverlayed ~= NamespacedIsSpellOverlayed then
        return CallIsSpellOverlayed(LegacyIsSpellOverlayed, spellID)
    end

    return nil
end

local function ResolveAutoburnTexture()
    if settings.textureKey ~= AUTOBURN_DEFAULT_MEDIA_KEY then
        local texture = FetchSharedMedia(GetSharedMedia(), "statusbar", settings.textureKey)
        if texture then
            return texture
        end
    end

    return AUTOBURN_DEFAULT_TEXTURE
end

local function GetDefaultAutoburnFont()
    if GameFontHighlightSmall and GameFontHighlightSmall.GetFont then
        local font = GameFontHighlightSmall:GetFont()
        if type(font) == "string" and font ~= "" then
            return font
        end
    end
    return STANDARD_TEXT_FONT
end

local function ResolveAutoburnFont()
    if settings.fontKey ~= AUTOBURN_DEFAULT_MEDIA_KEY then
        local font = FetchSharedMedia(GetSharedMedia(), "font", settings.fontKey)
        if type(font) == "string" and font ~= "" then
            return font
        end
    end
    return GetDefaultAutoburnFont()
end

local function ValidateAutoburnMediaKey(settingKey, mediaType)
    if settings[settingKey] == AUTOBURN_DEFAULT_MEDIA_KEY then
        return
    end

    local media = GetSharedMedia()
    if media and not IsValidSharedMedia(media, mediaType, settings[settingKey]) then
        settings[settingKey] = AUTOBURN_DEFAULT_MEDIA_KEY
    end
end

local function ValidateAutoburnTextureKey()
    ValidateAutoburnMediaKey("textureKey", "statusbar")
end

local function ValidateAutoburnFontKey()
    ValidateAutoburnMediaKey("fontKey", "font")
end

local function GetAutoburnPositionBounds()
    local maximumX = math.max(0, math.floor((UIParent:GetWidth() - settings.width) / 2))
    local maximumY = math.max(0, math.floor((UIParent:GetHeight() - settings.height) / 2))
    return -maximumX, maximumX, -maximumY, maximumY
end

local function ClampAutoburnPosition()
    local minimumX, maximumX, minimumY, maximumY = GetAutoburnPositionBounds()
    settings.x = NormalizeCoordinate(Clamp(settings.x, minimumX, maximumX), AUTOBURN_DEFAULT_X)
    settings.y = NormalizeCoordinate(Clamp(settings.y, minimumY, maximumY), AUTOBURN_DEFAULT_Y)
end

SyncPositionControls = function()
    if not positionControls then
        return
    end

    local minimumX, maximumX, minimumY, maximumY = GetAutoburnPositionBounds()
    isSyncingPositionControls = true
    positionControls.x.slider:SetMinMaxValues(minimumX, maximumX)
    positionControls.y.slider:SetMinMaxValues(minimumY, maximumY)
    positionControls.x.slider:SetValue(settings.x)
    positionControls.y.slider:SetValue(settings.y)
    positionControls.x.valueText:SetText(tostring(settings.x))
    positionControls.y.valueText:SetText(tostring(settings.y))
    isSyncingPositionControls = false
end

ApplyAutoburnPosition = function()
    if not autoburnBar or not settings then
        return
    end

    ClampAutoburnPosition()
    autoburnBar:ClearAllPoints()
    autoburnBar:SetPoint("CENTER", UIParent, "CENTER", settings.x, settings.y)
    SyncPositionControls()
end

local function SaveDraggedAutoburnPosition(reanchor)
    if not autoburnBar then
        return
    end

    local barX, barY = autoburnBar:GetCenter()
    local parentX, parentY = UIParent:GetCenter()
    if not barX or not barY or not parentX or not parentY then
        if reanchor then
            ApplyAutoburnPosition()
        end
        return
    end

    local barScale = autoburnBar:GetEffectiveScale()
    local parentScale = UIParent:GetEffectiveScale()
    settings.x = NormalizeCoordinate((barX * barScale - parentX * parentScale) / parentScale, settings.x)
    settings.y = NormalizeCoordinate((barY * barScale - parentY * parentScale) / parentScale, settings.y)
    ClampAutoburnPosition()
    SyncPositionControls()

    if reanchor then
        ApplyAutoburnPosition()
    end
end

local function EnsureAutoburnBar()
    if autoburnBar then
        return autoburnBar
    end

    local bar = CreateFrame("StatusBar", AUTOBURN_FRAME_NAME, UIParent)
    bar:SetSize(settings.width, settings.height)
    bar:SetFrameStrata("MEDIUM")
    bar:SetClampedToScreen(true)
    bar:SetMovable(false)
    bar:EnableMouse(false)
    bar:RegisterForDrag("LeftButton")
    bar:SetMinMaxValues(0, AUTOBURN_DEFAULT_DURATION)
    bar:SetValue(0)
    bar:SetAlpha(1)

    local background = CreateSolidTexture(bar, "BACKGROUND", 0, 0, 0, 0.68)
    background:SetAllPoints()
    AddBorder(bar, 1, 0.08, 0.08, 0.10, 1)

    local remainingText = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    remainingText:SetJustifyH("RIGHT")
    bar.remainingText = remainingText

    local label = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetJustifyH("LEFT")
    label:SetWordWrap(false)
    bar.label = label

    bar:SetScript("OnDragStart", function(self)
        if positionUnlocked then
            self:StartMoving()
            positionDragFrame:SetScript("OnUpdate", function()
                SaveDraggedAutoburnPosition(false)
            end)
        end
    end)
    bar:SetScript("OnDragStop", function(self)
        positionDragFrame:SetScript("OnUpdate", nil)
        self:StopMovingOrSizing()
        if positionUnlocked then
            SaveDraggedAutoburnPosition(true)
        end
    end)

    bar:Hide()
    autoburnBar = bar
    ApplyAutoburnAppearance()
    ApplyAutoburnPosition()
    return bar
end

local function ApplyAutoburnFont(fontString)
    local font = ResolveAutoburnFont()
    local _, _, flags = GameFontHighlightSmall:GetFont()
    local succeeded, applied = pcall(fontString.SetFont, fontString,
        font, settings.fontSize, flags or "")
    if succeeded and applied ~= false then
        return
    end

    local fallback = GetDefaultAutoburnFont()
    if fallback then
        pcall(fontString.SetFont, fontString, fallback, settings.fontSize, flags or "")
    end
end

local function LayoutAutoburnTexts(showTimer)
    if not autoburnBar then
        return
    end

    autoburnBar.remainingText:ClearAllPoints()
    autoburnBar.remainingText:SetPoint("RIGHT", autoburnBar, "RIGHT",
        -7 + settings.timerOffsetX, 0)
    autoburnBar.label:ClearAllPoints()
    autoburnBar.label:SetPoint("LEFT", autoburnBar, "LEFT",
        7 + settings.labelOffsetX, 0)
    if showTimer then
        autoburnBar.label:SetPoint("RIGHT", autoburnBar.remainingText, "LEFT", -4, 0)
    else
        autoburnBar.label:SetPoint("RIGHT", autoburnBar, "RIGHT", -7, 0)
    end
end

local function FormatAutoburnRemaining(remaining)
    remaining = math.max(0, remaining or 0)
    local text = string.format("%." .. settings.decimalPlaces .. "f", remaining)
    return settings.showTimeUnit and (text .. "s") or text
end

local function GetAutoburnDisplayBucket(remaining)
    local factor = 10 ^ settings.decimalPlaces
    return math.floor(math.max(0, remaining or 0) * factor + 0.5)
end

local function SetAutoburnColor(colorState)
    if colorState ~= "blocked" and colorState ~= "full" then
        colorState = "ready"
    end
    autoburnColorState = colorState

    if not autoburnBar then
        return
    end

    local color = settings.readyColor
    if colorState == "blocked" then
        color = settings.blockedColor
    elseif colorState == "full" then
        color = settings.fullBarColor
    end
    autoburnBar:SetStatusBarColor(color.r, color.g, color.b, color.a)
end

ApplyAutoburnAppearance = function()
    if not autoburnBar or not settings then
        return
    end

    autoburnBar:SetSize(settings.width, settings.height)
    autoburnBar:SetStatusBarTexture(ResolveAutoburnTexture())
    ApplyAutoburnFont(autoburnBar.label)
    ApplyAutoburnFont(autoburnBar.remainingText)
    autoburnBar.label:SetText(GetDisplayLabel())
    SetAutoburnColor(autoburnColorState)
end

local function IsAutoburnPreviewActive()
    return configPreviewActive or positionUnlocked
end

RefreshAutoburnDisplay = function()
    local timerIsRunning = timerEndTime and timerEndTime > GetTime()
    local previewIsActive = IsAutoburnPreviewActive()

    if not timerIsRunning and timerEndTime then
        timerEndTime = nil
        timerDurationAtStart = nil
        autoburnColorState = "ready"
        if autoburnBar then
            autoburnBar.displayedTimeBucket = nil
            autoburnBar:SetScript("OnUpdate", nil)
        end
    end

    local fullBarIsActive = settings.showFullBar and monitoringEnabled
        and highlightKnown and isHighlighted and not timerIsRunning

    if not previewIsActive and not timerIsRunning and not fullBarIsActive then
        autoburnColorState = "ready"
        if autoburnBar then
            autoburnBar:SetMovable(false)
            autoburnBar:EnableMouse(false)
            autoburnBar:Hide()
        end
        return
    end

    local bar = EnsureAutoburnBar()
    ApplyAutoburnAppearance()
    ApplyAutoburnPosition()
    bar:SetAlpha(1)
    bar:SetMovable(positionUnlocked)
    bar:EnableMouse(positionUnlocked)

    if previewIsActive then
        bar:SetFrameStrata("DIALOG")
        bar:SetFrameLevel(100)
        bar:SetMinMaxValues(0, settings.duration)
        bar:SetValue(0)
        bar.remainingText:Hide()
        LayoutAutoburnTexts(false)
    elseif timerIsRunning then
        local remaining = timerEndTime - GetTime()
        SetAutoburnColor(isHighlighted and "blocked" or "ready")
        bar:SetFrameStrata("MEDIUM")
        bar:SetFrameLevel(0)
        bar:SetMinMaxValues(0, timerDurationAtStart)
        bar:SetValue(remaining)
        bar.remainingText:SetText(FormatAutoburnRemaining(remaining))
        bar.displayedTimeBucket = GetAutoburnDisplayBucket(remaining)
        bar.remainingText:Show()
        LayoutAutoburnTexts(true)
    else
        SetAutoburnColor("full")
        bar:SetFrameStrata("MEDIUM")
        bar:SetFrameLevel(0)
        bar:SetMinMaxValues(0, 1)
        bar:SetValue(1)
        bar.remainingText:Hide()
        LayoutAutoburnTexts(false)
    end

    bar:Show()
end

local function StopAutoburn()
    timerEndTime = nil
    timerDurationAtStart = nil
    autoburnColorState = "ready"

    if autoburnBar then
        autoburnBar.displayedTimeBucket = nil
        autoburnBar:SetScript("OnUpdate", nil)
    end
    RefreshAutoburnDisplay()
end

local function UpdateAutoburn(self)
    if not timerEndTime then
        StopAutoburn()
        return
    end

    local remaining = timerEndTime - GetTime()
    if remaining <= 0 then
        self:SetValue(0)
        StopAutoburn()
        return
    end

    if IsAutoburnPreviewActive() then
        return
    end

    self:SetValue(remaining)

    local displayedTimeBucket = GetAutoburnDisplayBucket(remaining)
    if displayedTimeBucket ~= self.displayedTimeBucket then
        self.displayedTimeBucket = displayedTimeBucket
        self.remainingText:SetText(FormatAutoburnRemaining(remaining))
    end
end

local function StartOrResetAutoburn()
    if not settings then
        return
    end

    local bar = EnsureAutoburnBar()
    timerDurationAtStart = settings.duration
    timerEndTime = GetTime() + timerDurationAtStart

    bar.displayedTimeBucket = GetAutoburnDisplayBucket(timerDurationAtStart)
    SetAutoburnColor("ready")
    bar:SetScript("OnUpdate", UpdateAutoburn)
    RefreshAutoburnDisplay()
end

local function ApplyHighlightState(newState, isBaselineSync)
    newState = not not newState

    if isBaselineSync or not highlightKnown then
        highlightKnown = true
        isHighlighted = newState
        RefreshAutoburnDisplay()
        return
    end

    if newState == isHighlighted then
        return
    end

    local wasHighlighted = isHighlighted
    isHighlighted = newState

    if newState then
        RefreshAutoburnDisplay()
    elseif wasHighlighted then
        StartOrResetAutoburn()
    end
end

local function QueryCurrentHighlight()
    local querySucceeded = false
    local hasUnresolvedActiveSpell = false
    local hasUnresolvedTargetSpell = false
    local queriedSpellIDs = {}

    for spellID in pairs(activeTargetOverlayIDs) do
        local overlayed = SafeIsSpellOverlayed(spellID)
        queriedSpellIDs[spellID] = true

        if overlayed == true then
            return true
        elseif overlayed == false then
            querySucceeded = true
            activeTargetOverlayIDs[spellID] = nil
        else
            hasUnresolvedActiveSpell = true
        end
    end

    for spellID in pairs(targetSpellIDs) do
        if not queriedSpellIDs[spellID] then
            local overlayed = SafeIsSpellOverlayed(spellID)
            if overlayed ~= nil then
                querySucceeded = true
                if overlayed then
                    return true
                end
            else
                hasUnresolvedTargetSpell = true
            end
        end
    end

    if hasUnresolvedActiveSpell then
        return true
    end
    if hasUnresolvedTargetSpell then
        return nil
    end
    if querySucceeded then
        return false
    end

    return nil
end

local function SynchronizeOverlayState(isBaselineSync)
    if not monitoringEnabled then
        return
    end

    if targetSpellIDsDirty then
        RebuildTargetSpellIDs()
    end

    local queriedState = QueryCurrentHighlight()
    if queriedState ~= nil then
        ApplyHighlightState(queriedState, isBaselineSync)
        return queriedState
    elseif not highlightKnown then
        ApplyHighlightState(false, true)
    end

    return nil
end

local function ScheduleOverlaySync(isBaselineSync)
    if not isBaselineSync or not syncPending then
        pendingTransitionEvaluation = not isBaselineSync
    end

    if syncPending then
        return
    end

    syncPending = true
    local generation = syncGeneration

    local function RunScheduledSync()
        if generation ~= syncGeneration then
            return
        end

        syncPending = false
        if not monitoringEnabled then
            pendingTransitionEvaluation = false
            return
        end

        local useBaseline = not pendingTransitionEvaluation
        pendingTransitionEvaluation = false
        local synchronizedState = SynchronizeOverlayState(useBaseline)
        local shouldRetry = synchronizedState == nil
            or (not useBaseline and synchronizedState == true)

        if shouldRetry and C_Timer and C_Timer.After then
            local function RetryOverlayState(attemptsRemaining)
                if not monitoringEnabled or generation ~= syncGeneration then
                    return
                end

                local retryState = SynchronizeOverlayState(useBaseline)
                local retryAgain = retryState == nil
                    or (not useBaseline and retryState == true)
                if retryAgain and attemptsRemaining > 1 then
                    C_Timer.After(0.05, function()
                        RetryOverlayState(attemptsRemaining - 1)
                    end)
                elseif retryAgain and not useBaseline and not next(activeTargetOverlayIDs) then
                    ApplyHighlightState(false, false)
                end
            end

            C_Timer.After(0.05, function()
                RetryOverlayState(3)
            end)
        end
    end

    if C_Timer and C_Timer.After then
        C_Timer.After(0, RunScheduledSync)
    else
        RunScheduledSync()
    end
end

local function ResetMonitoringBaseline(stopTimer)
    if not monitoringEnabled then
        return
    end

    syncGeneration = syncGeneration + 1
    syncPending = false
    pendingTransitionEvaluation = false
    targetSpellIDsDirty = true
    ClearTable(activeTargetOverlayIDs)
    highlightKnown = false
    isHighlighted = false
    if stopTimer then
        StopAutoburn()
    else
        RefreshAutoburnDisplay()
    end
    ScheduleOverlaySync(true)
end

local function HandleOverlayEvent(event, spellID)
    if not IsSafePositiveSpellID(spellID) then
        return
    end

    local wasActive = activeTargetOverlayIDs[spellID]
    if not wasActive and not IsTargetSpell(spellID) then
        return
    end

    if event == "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW" then
        syncGeneration = syncGeneration + 1
        syncPending = false
        pendingTransitionEvaluation = false
        activeTargetOverlayIDs[spellID] = true
        ApplyHighlightState(true, false)
    else
        activeTargetOverlayIDs[spellID] = nil
        ScheduleOverlaySync(false)
    end
end

local function SetMonitoringEnabled(enabled)
    enabled = not not enabled

    if settings then
        settings.enabled = enabled
    end

    if monitoringEnabled == enabled then
        if enabled then
            ScheduleOverlaySync(true)
        end
        return
    end

    monitoringEnabled = enabled
    syncGeneration = syncGeneration + 1
    syncPending = false
    pendingTransitionEvaluation = false
    targetSpellIDsDirty = true
    ClearTable(activeTargetOverlayIDs)
    highlightKnown = false
    isHighlighted = false

    if enabled then
        monitorFrame:RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_SHOW")
        monitorFrame:RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_HIDE")
        monitorFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
        monitorFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
        monitorFrame:RegisterEvent("SPELLS_CHANGED")
        ScheduleOverlaySync(true)
    else
        monitorFrame:UnregisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_SHOW")
        monitorFrame:UnregisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_HIDE")
        monitorFrame:UnregisterEvent("PLAYER_ENTERING_WORLD")
        monitorFrame:UnregisterEvent("PLAYER_SPECIALIZATION_CHANGED")
        monitorFrame:UnregisterEvent("SPELLS_CHANGED")
        StopAutoburn()
    end
end

local function CommitDurationInput(editBox)
    local duration = ParseDuration(editBox:GetText())
    if duration then
        settings.duration = duration
    end

    editBox:SetText(FormatDuration(settings.duration))
end

local function CommitLabelInput(editBox)
    settings.label = NormalizeLabel(editBox:GetText())
    editBox:SetText(settings.label)
    RefreshAutoburnDisplay()
end

local function SetConfigPreviewActive(active)
    configPreviewActive = not not active
    RefreshAutoburnDisplay()
end

local function UpdateUnlockButton()
    if positionControls and positionControls.unlockButton then
        positionControls.unlockButton:SetText(positionUnlocked and "锁定" or "解除锁定")
    end
end

local function SetPositionUnlocked(unlocked)
    positionUnlocked = not not unlocked
    if not positionUnlocked then
        positionDragFrame:SetScript("OnUpdate", nil)
        if autoburnBar then
            autoburnBar:StopMovingOrSizing()
        end
    end
    UpdateUnlockButton()
    RefreshAutoburnDisplay()
end

local function SetAutoburnCoordinate(axis, value)
    local minimumX, maximumX, minimumY, maximumY = GetAutoburnPositionBounds()
    value = NormalizeCoordinate(value, settings[axis])

    if axis == "x" then
        settings.x = Clamp(value, minimumX, maximumX)
    else
        settings.y = Clamp(value, minimumY, maximumY)
    end

    ApplyAutoburnPosition()
end

local function InitializeAutoburnSettings(db)
    if type(db.autoburn) ~= "table" then
        db.autoburn = {}
    end

    settings = db.autoburn

    if type(settings.enabled) ~= "boolean" then
        local _, classFilename = UnitClass("player")
        settings.enabled = classFilename == "DEATHKNIGHT"
    end

    settings.duration = ParseDuration(settings.duration) or AUTOBURN_DEFAULT_DURATION
    settings.readyColor = NormalizeColor(settings.readyColor, AUTOBURN_DEFAULT_READY_COLOR)
    settings.blockedColor = NormalizeColor(settings.blockedColor, AUTOBURN_DEFAULT_BLOCKED_COLOR)
    settings.fullBarColor = NormalizeColor(settings.fullBarColor, AUTOBURN_DEFAULT_READY_COLOR)
    if type(settings.showFullBar) ~= "boolean" then
        settings.showFullBar = false
    end
    settings.label = NormalizeLabel(settings.label)
    settings.textureKey = type(settings.textureKey) == "string" and settings.textureKey ~= ""
        and settings.textureKey or AUTOBURN_DEFAULT_MEDIA_KEY
    settings.fontKey = type(settings.fontKey) == "string" and settings.fontKey ~= ""
        and settings.fontKey or AUTOBURN_DEFAULT_MEDIA_KEY
    settings.width = NormalizeInteger(settings.width, AUTOBURN_SIZE.DEFAULT_WIDTH,
        AUTOBURN_SIZE.MIN_WIDTH, AUTOBURN_SIZE.MAX_WIDTH)
    settings.height = NormalizeInteger(settings.height, AUTOBURN_SIZE.DEFAULT_HEIGHT,
        AUTOBURN_SIZE.MIN_HEIGHT, AUTOBURN_SIZE.MAX_HEIGHT)
    settings.fontSize = NormalizeInteger(settings.fontSize, AUTOBURN_SIZE.DEFAULT_FONT_SIZE,
        AUTOBURN_SIZE.MIN_FONT_SIZE, AUTOBURN_SIZE.MAX_FONT_SIZE)
    settings.labelOffsetX = NormalizeInteger(settings.labelOffsetX, 0,
        AUTOBURN_SIZE.MIN_TEXT_OFFSET, AUTOBURN_SIZE.MAX_TEXT_OFFSET)
    settings.timerOffsetX = NormalizeInteger(settings.timerOffsetX, 0,
        AUTOBURN_SIZE.MIN_TEXT_OFFSET, AUTOBURN_SIZE.MAX_TEXT_OFFSET)
    if type(settings.showTimeUnit) ~= "boolean" then
        settings.showTimeUnit = true
    end
    settings.decimalPlaces = NormalizeInteger(settings.decimalPlaces,
        AUTOBURN_SIZE.DEFAULT_DECIMAL_PLACES, 0, 2)
    settings.x = NormalizeCoordinate(settings.x, AUTOBURN_DEFAULT_X)
    settings.y = NormalizeCoordinate(settings.y, AUTOBURN_DEFAULT_Y)
end

monitorFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW"
        or event == "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE" then
        HandleOverlayEvent(event, ...)
    elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
        local unit = ...
        if not unit or unit == "player" then
            ResetMonitoringBaseline(true)
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        ResetMonitoringBaseline(false)
    elseif event == "SPELLS_CHANGED" then
        targetSpellIDsDirty = true
        RebuildTargetSpellIDs()
        ScheduleOverlaySync(true)
    end
end)

ns.Autoburn = {
    SIZE = AUTOBURN_SIZE,
    DEFAULT_MEDIA_KEY = AUTOBURN_DEFAULT_MEDIA_KEY,
    InitializeSettings = InitializeAutoburnSettings,
    GetSettings = function()
        return settings
    end,
    SetMonitoringEnabled = SetMonitoringEnabled,
    RefreshDisplay = RefreshAutoburnDisplay,
    CommitDurationInput = CommitDurationInput,
    CommitLabelInput = CommitLabelInput,
    FormatDuration = FormatDuration,
    SetConfigPreviewActive = SetConfigPreviewActive,
    TogglePositionLock = function()
        SetPositionUnlocked(not positionUnlocked)
    end,
    UpdateUnlockButton = UpdateUnlockButton,
    SetCoordinate = SetAutoburnCoordinate,
    SyncPositionControls = SyncPositionControls,
    ClampPosition = ClampAutoburnPosition,
    SetPositionControls = function(controls)
        positionControls = controls
    end,
    IsSyncingPositionControls = function()
        return isSyncingPositionControls
    end,
    InvalidateTimerText = function()
        if autoburnBar then
            autoburnBar.displayedTimeBucket = nil
        end
    end,
    ValidateTextureKey = ValidateAutoburnTextureKey,
    ValidateFontKey = ValidateAutoburnFontKey,
    OnDisplayChanged = function()
        if settings then
            ApplyAutoburnPosition()
        end
    end,
}
