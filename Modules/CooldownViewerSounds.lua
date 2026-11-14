local _, ns = ...

local FIRST_PAYLOAD = -2000000000
local LAST_PAYLOAD = -2147483648
local settings
local payloadByName = {}
local nextPayload = FIRST_PAYLOAD
local initialized = false
local hooksInstalled = false
local conflictingAddon = false
local conflictWarningShown = false
local eventFrame = CreateFrame("Frame")

local function IsEnabled()
    return settings and settings.enabled and not conflictingAddon
end

local function IsPublic(value)
    return not (ns.IsSecretValue and ns.IsSecretValue(value))
end

local function IsSoundAlert(alert)
    if not IsPublic(alert) or type(alert) ~= "table"
        or (ns.IsSecretTable and ns.IsSecretTable(alert)) then
        return false
    end
    local alertType = CooldownViewerAlert_GetType(alert)
    return IsPublic(alertType) and alertType == Enum.CooldownViewerAlertType.Sound
end

local function GetMediaName(alert)
    if not settings or not IsSoundAlert(alert) then
        return nil
    end
    local payload = CooldownViewerAlert_GetPayload(alert)
    if IsPublic(payload) and type(payload) == "number" then
        return settings.payloadNames[payload]
    end
end

local function IsPlayableMedia(value)
    if type(value) == "string" then
        return value ~= ""
    end
    return type(value) == "number" and value > 0 and value < math.huge
        and value == math.floor(value)
end

local function FetchSound(name)
    local value = ns.FetchSharedMedia(ns.GetSharedMedia(), "sound", name)
    if IsPlayableMedia(value) then
        return value
    end
end

local function PlayMedia(name)
    if not IsEnabled() then
        return
    end
    local sound = FetchSound(name)
    if sound then
        -- LSM 的 number 是 FileDataID，不是 SoundKitID；两种媒体都用 PlaySoundFile。
        pcall(PlaySoundFile, sound, "Master")
    end
end

local function OnPlayAlert(_, _, alert)
    if not IsEnabled() then
        return
    end
    local name = GetMediaName(alert)
    if name then
        PlayMedia(name)
    end
end

local function GetOrCreatePayload(name)
    local payload = payloadByName[name]
    if payload then
        return payload
    end
    if nextPayload < LAST_PAYLOAD then
        return nil
    end
    payload = nextPayload
    nextPayload = nextPayload - 1
    settings.payloadNames[payload] = name
    payloadByName[name] = payload
    return payload
end

local function GetSelectionText(editor)
    local alert = editor.workingCopyOfAlert
    local name = GetMediaName(alert)
    if name then
        local displayName = name:gsub("|", "||")
        if not IsEnabled() then
            return "SharedMedia（已关闭）：" .. displayName
        elseif not FetchSound(name) then
            return "SharedMedia（缺失）：" .. displayName
        end
        return "SharedMedia：" .. displayName
    end
    return CooldownViewerAlert_GetPayloadText(alert)
end

local function UpdateSelectionText(editor)
    if editor.workingCopyOfAlert then
        editor.PayloadDropdown:SetSelectionText(function()
            return GetSelectionText(editor)
        end)
        editor.PayloadDropdown:SignalUpdate()
    end
end

local function AddMediaButton(editor, description, name)
    local buttonDescription = description:CreateRadio(name:gsub("|", "||"), function(mediaName)
        return GetMediaName(editor.workingCopyOfAlert) == mediaName
    end, function(mediaName)
        -- 已打开的菜单也必须遵守开关，且媒体消失时不能选入一个失效的新提醒。
        if not IsEnabled() or not IsSoundAlert(editor.workingCopyOfAlert)
            or not FetchSound(mediaName) then
            return
        end
        local payload = GetOrCreatePayload(mediaName)
        if payload then
            CooldownViewerAlert_SetPayload(editor.workingCopyOfAlert, payload)
        end
    end, name)

    buttonDescription:AddInitializer(function(button)
        local sampleButton = MenuTemplates.AttachUtilityButton(button)
        sampleButton.Texture:Hide()
        CooldownViewerAlert_SetupTypeButton(sampleButton, Enum.CooldownViewerAlertType.Sound)
        MenuTemplates.SetUtilityButtonTooltipText(sampleButton, COOLDOWN_VIEWER_SETTINGS_ALERT_MENU_PLAY_SAMPLE)
        MenuTemplates.SetUtilityButtonAnchor(sampleButton, MenuVariants.GearButtonAnchor, button)
        MenuTemplates.SetUtilityButtonClickHandler(sampleButton, function()
            PlayMedia(name)
        end)
    end)
end

local function AppendSoundMenu(owner, rootDescription)
    local editor = _G.CooldownViewerSettingsEditAlert
    if not IsEnabled() or not editor or owner ~= editor.PayloadDropdown
        or not IsSoundAlert(editor.workingCopyOfAlert) then
        return
    end

    -- 只追加，不重建暴雪的分类、文字转语音或视觉提醒菜单。
    local description = rootDescription:CreateButton("SharedMedia")
    description:SetScrollMode(400)
    local media = ns.GetSharedMedia()
    local succeeded, sounds
    if media then
        succeeded, sounds = pcall(media.HashTable, media, "sound")
    end
    local names = {}
    if succeeded and type(sounds) == "table" then
        for name, value in pairs(sounds) do
            if type(name) == "string" and name ~= "" and name ~= "None"
                and IsPlayableMedia(value) then
                names[#names + 1] = name
            end
        end
    end
    table.sort(names)
    if #names == 0 then
        local text = media and "没有已注册的音效" or "未加载 LibSharedMedia-3.0"
        description:CreateButton(text):SetEnabled(false)
        return
    end
    for _, name in ipairs(names) do
        AddMediaButton(editor, description, name)
    end
end

local function CheckConflict()
    conflictingAddon = C_AddOns and C_AddOns.IsAddOnLoaded
        and C_AddOns.IsAddOnLoaded("CooldownManagerCustomSounds") or false
    if settings and settings.enabled and conflictingAddon and not conflictWarningShown then
        conflictWarningShown = true
        print("RRC：请先停用 CooldownManagerCustomSounds 并 /reload，再使用第6项自定义冷却管理器音效。")
    end
end

local function TryInstallHooks()
    -- 关闭后重载也保留已有提醒的名称；菜单追加和播放仍分别受开关控制。
    if hooksInstalled or not settings or conflictingAddon
        or (not settings.enabled and next(settings.payloadNames) == nil) then
        return
    end
    local editor = _G.CooldownViewerSettingsEditAlert
    if not Menu or type(Menu.ModifyMenu) ~= "function"
        or type(CooldownViewerAlert_PlayAlert) ~= "function"
        or not editor or type(editor.SetupDropdowns) ~= "function" then
        return
    end
    hooksInstalled = true
    hooksecurefunc("CooldownViewerAlert_PlayAlert", OnPlayAlert)
    hooksecurefunc(editor, "SetupDropdowns", UpdateSelectionText)
    Menu.ModifyMenu("COOLDOWN_VIEWER_ALERT_PAYLOAD", AppendSoundMenu)
    UpdateSelectionText(editor)
end

local function RefreshEditor()
    local editor = _G.CooldownViewerSettingsEditAlert
    if hooksInstalled and editor and editor:IsShown() and editor.workingCopyOfAlert then
        editor.PayloadDropdown:CloseMenu()
        editor:SetupDropdowns()
    end
end

local function InitializeSettings(db)
    if type(db.cooldownViewerSounds) ~= "table" then
        db.cooldownViewerSounds = {}
    end
    settings = db.cooldownViewerSounds
    if type(settings.enabled) ~= "boolean" then
        settings.enabled = false
    end
    if type(settings.payloadNames) ~= "table" then
        settings.payloadNames = {}
    end

    payloadByName = {}
    nextPayload = FIRST_PAYLOAD
    for payload, name in pairs(settings.payloadNames) do
        if type(payload) == "number" and payload >= LAST_PAYLOAD and payload <= FIRST_PAYLOAD
            and payload == math.floor(payload) and type(name) == "string" and name ~= "" then
            payloadByName[name] = math.max(payloadByName[name] or payload, payload)
            nextPayload = math.min(nextPayload, payload - 1)
        else
            settings.payloadNames[payload] = nil
        end
    end
    -- 不因媒体缺失而清理/重排编号；暴雪布局保存的是编号，RRC 保存其名称映射。
end

local function SetEnabled(enabled)
    if not settings then
        return
    end
    settings.enabled = enabled == true
    CheckConflict()
    TryInstallHooks()
    RefreshEditor()
end

local function Initialize()
    if initialized then
        return
    end
    initialized = true
    eventFrame:RegisterEvent("ADDON_LOADED")
    eventFrame:RegisterEvent("PLAYER_LOGIN")
    CheckConflict()
    TryInstallHooks()
end

eventFrame:SetScript("OnEvent", function()
    CheckConflict()
    TryInstallHooks()
end)

ns.CooldownViewerSounds = {
    InitializeSettings = InitializeSettings,
    GetSettings = function() return settings end,
    SetEnabled = SetEnabled,
    Initialize = Initialize,
}
