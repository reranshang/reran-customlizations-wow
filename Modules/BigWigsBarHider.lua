local _, ns = ...

local IsSecretTable = ns.IsSecretTable

-- BigWigs 条：通过 BigWigs 官方 bar style API（BigWigsAPI:RegisterBarStyle）注册一个
-- "隐藏式"计时条样式，需要隐藏时把 Bars 插件的 profile.barStyle 切换到该样式并备份
-- 原样式。这是 BigWigs 提供的带版本校验（apiVersion）和文档的公开扩展点，不依赖已
-- 废弃的 BigWigs_BarCreated / BigWigs_BarEmphasized 回调。文字提示、声音、倒数、
-- 闪屏均为独立插件/独立消息通道，不受影响。
--
-- AbilityTimeline 图标：仅在安装 AT 时处理其三个容器、AtAbilitySpellIconN 和
-- BIGICONN。大图标经 AceGUI 回收后父级变成 UIParent，复用不恢复父级，必须直接
-- SetAlpha(0/1)；AT 和对象池均不回改这些图标的 alpha，计时、回收及语音照常运行。
-- 新图标在各自构造器出口压 alpha（见 TryWrapAbilityTimelineConstructors）。禁忌：绝不能 Disable 任何
-- BigWigs 插件（会触发 AT 的 StopAllTimers 清空全部计时），也不能用 AceAddon
-- :Disable()（AT 的事件只在 OnInitialize 注册，Disable 后直到 /reload 都无法恢复）。
--
-- EXBoss 条：优先通过 DisplayPolicy.GetTimelineBars() 取得活动开关，团本中把
-- bun/timer 都设为 false 并备份原值，通过 Scheduler:RefreshTimelineBars() 清屏并
-- 重置挂载标记。旧版才使用 barDisplayMode="none"；新版仅在首次迁移时读取旧字段。
-- 按接口能力适配，不检查插件发布版本。中心圆环、中心文字、倒数数字、语音均保留。
-- 前提是 EXBoss 的"团本中禁用 EXBoss"关闭，本模块在功能开启时自动关闭它。
-- 禁忌：不碰 EXBoss 守护的三个暴雪 CVar（encounterTimelineEnabled 等，会被打回）。
local STYLE_KEY = "ReRansCustomlizationsHidden"
local STYLE_VERSION = 1
local AT_CONTAINER_FRAMES = {
    "AbilityTimelineFrame",
    "AbilityTimelineBigIconFrame",
    "AbilityTimelineTextHighlightFrame",
}
local AT_ICON_TYPES = {
    { widgetType = "AtAbilitySpellIcon", framePrefix = "AtAbilitySpellIcon" },
    { widgetType = "AtBigIcon", framePrefix = "BIGICON" },
}
local EXBOSS_BAR_MODES = { bun = true, timer = true, both = true }

local settings
local enabledCheckButton
local onlyInDungeonCheckButton
local exbossCheckButton
local initialized = false
local styleRegistered = false
local messagesRegistered = false
local callbackObject = {}
local hiddenBars = setmetatable({}, { __mode = "k" })
local hookedBars = setmetatable({}, { __mode = "k" })
local abilityTimelineHidden = false
local abilityTimelineSweepScheduled = false
local abilityTimelineEventRegistered = false
local abilityTimelineConstructorsWrapped = {}
local abilityTimelineApplyScheduled = false
local exbossApplyScheduled = false
local eventFrame = CreateFrame("Frame")

local function GetInstanceType()
    local _, instanceType = IsInInstance()
    return instanceType
end

local function ShouldHideBossBars()
    if not settings or settings.enabled ~= true then
        return false
    end
    if settings.onlyInDungeon == true then
        return GetInstanceType() == "party"
    end
    return true
end

-- ---------------------------------------------------------------------------
-- BigWigs 计时条
-- ---------------------------------------------------------------------------

local function HideBar(bar)
    if not bar or type(bar.SetAlpha) ~= "function" then
        return
    end

    hiddenBars[bar] = true
    if not hookedBars[bar] then
        hookedBars[bar] = true
        -- Bars 的 rearrangeBars 会把曾超出可见上限、回到限额内的条重新 SetAlpha(1)，
        -- 该路径不经过 ApplyStyle，只能在这里压回去。alpha == 0 时不再回写，天然终止递归。
        pcall(hooksecurefunc, bar, "SetAlpha", function(hookedBar, alpha)
            if hiddenBars[hookedBar] and alpha ~= 0 then
                hookedBar:SetAlpha(0)
            end
        end)
    end
    bar:SetAlpha(0)

    local iconFrame = bar.candyBarIconFrame
    if iconFrame and type(iconFrame.EnableMouse) == "function" then
        pcall(iconFrame.EnableMouse, iconFrame, false)
    end
end

local function RestoreBar(bar)
    if not bar then
        return
    end

    hiddenBars[bar] = nil
    if type(bar.SetAlpha) == "function" then
        bar:SetAlpha(1)
    end

    local iconFrame = bar.candyBarIconFrame
    if iconFrame and type(iconFrame.EnableMouse) == "function"
        and type(bar.Get) == "function" then
        local succeeded, hasTooltip = pcall(bar.Get, bar, "bigwigs:tooltip")
        if succeeded and hasTooltip then
            pcall(iconFrame.EnableMouse, iconFrame, true)
        end
    end
end

local barStyle = {
    apiVersion = 1,
    version = STYLE_VERSION,
    GetStyleName = function()
        return "RRC 隐藏计时条"
    end,
    ApplyStyle = HideBar,
    BarStopped = RestoreBar,
}

local function GetBarsProfile()
    local bigwigs = _G.BigWigs
    if not bigwigs or type(bigwigs.GetPlugin) ~= "function" then
        return nil
    end

    local succeeded, bars = pcall(bigwigs.GetPlugin, bigwigs, "Bars", true)
    if not succeeded or type(bars) ~= "table" then
        return nil
    end

    local db = bars.db
    if type(db) ~= "table" or type(db.profile) ~= "table" then
        return nil
    end
    return db.profile
end

local function BroadcastProfileUpdate()
    local loader = _G.BigWigsLoader
    if loader and type(loader.SendMessage) == "function" then
        pcall(loader.SendMessage, loader, "BigWigs_ProfileUpdate")
    end
end

local function ApplyBigWigsState()
    local barsProfile = GetBarsProfile()
    if not barsProfile then
        return
    end

    if ShouldHideBossBars() then
        if barsProfile.barStyle ~= STYLE_KEY then
            if type(barsProfile.barStyle) == "string" then
                settings.previousBarStyle = barsProfile.barStyle
            end
            barsProfile.barStyle = STYLE_KEY
            BroadcastProfileUpdate()
        end
    elseif barsProfile.barStyle == STYLE_KEY then
        local previousBarStyle = settings and settings.previousBarStyle
        barsProfile.barStyle = type(previousBarStyle) == "string"
            and previousBarStyle or "Default"
        if settings then
            settings.previousBarStyle = nil
        end
        BroadcastProfileUpdate()
    end
end

-- ---------------------------------------------------------------------------
-- AbilityTimeline 计时条图标
-- ---------------------------------------------------------------------------

local function IsAbilityTimelineLoaded()
    return C_AddOns and C_AddOns.IsAddOnLoaded
        and C_AddOns.IsAddOnLoaded("AbilityTimeline") == true
end

local function SetAbilityTimelineAlpha(alpha)
    for _, frameName in ipairs(AT_CONTAINER_FRAMES) do
        local frame = _G[frameName]
        if frame and type(frame.SetAlpha) == "function" then
            pcall(frame.SetAlpha, frame, alpha)
        end
    end

    -- 普通图标及复用后的大图标都可能以 UIParent 为父级；池内对象也需同步恢复。
    -- 两类帧各自连续编号，不能因其中一类尚未创建就跳过另一类。
    for _, iconType in ipairs(AT_ICON_TYPES) do
        local index = 1
        local icon = _G[iconType.framePrefix .. index]
        while icon do
            if type(icon.SetAlpha) == "function" then
                pcall(icon.SetAlpha, icon, alpha)
            end
            index = index + 1
            icon = _G[iconType.framePrefix .. index]
        end
    end
end

-- 时间轴事件可能同步 Show 图标，下一帧补扫会闪现。分别包装普通/大图标构造器，
-- 让新帧在构造出口就带 alpha 0；池复用不走构造器，但保留帧自身已设置的 alpha。
-- WidgetRegistry 是公开表，按类型记录包装状态，允许尚未注册的类型稍后重试。
local function TryWrapAbilityTimelineConstructors()
    local libStub = _G.LibStub
    if not libStub then
        return false
    end

    local succeeded, aceGUI = pcall(function()
        return libStub("AceGUI-3.0", true)
    end)
    if not succeeded or type(aceGUI) ~= "table" then
        return false
    end

    local registry = aceGUI.WidgetRegistry
    if type(registry) ~= "table" then
        return false
    end

    local allWrapped = true
    for _, iconType in ipairs(AT_ICON_TYPES) do
        local widgetType = iconType.widgetType
        if not abilityTimelineConstructorsWrapped[widgetType] then
            local constructor = registry[widgetType]
            if type(constructor) == "function" then
                registry[widgetType] = function(...)
                    local widget = constructor(...)
                    if abilityTimelineHidden and type(widget) == "table" then
                        local frame = widget.frame
                        if frame and type(frame.SetAlpha) == "function" then
                            pcall(frame.SetAlpha, frame, 0)
                        end
                    end
                    return widget
                end
                abilityTimelineConstructorsWrapped[widgetType] = true
            else
                allWrapped = false
            end
        end
    end
    return allWrapped
end

-- 战斗中新建的图标帧在 ENCOUNTER_TIMELINE_EVENT_ADDED 之后出现，下一帧补扫。
-- 构造器尚未注册时保留此兜底；补扫时也重试安装，后续新图标就不必等下一帧。
local function ScheduleAbilityTimelineSweep()
    if abilityTimelineSweepScheduled or not C_Timer or not C_Timer.After then
        return
    end

    abilityTimelineSweepScheduled = true
    C_Timer.After(0, function()
        abilityTimelineSweepScheduled = false
        if abilityTimelineHidden then
            TryWrapAbilityTimelineConstructors()
            SetAbilityTimelineAlpha(0)
        end
    end)
end

local function ApplyAbilityTimelineState()
    local shouldHide = ShouldHideBossBars() and IsAbilityTimelineLoaded()

    if shouldHide then
        TryWrapAbilityTimelineConstructors()
        if not abilityTimelineEventRegistered then
            -- AT 也会在 TRACK_CHANGED（事件从隐藏轨道移到可见轨道）时补建图标。
            abilityTimelineEventRegistered = pcall(eventFrame.RegisterEvent,
                eventFrame, "ENCOUNTER_TIMELINE_EVENT_ADDED")
            pcall(eventFrame.RegisterEvent, eventFrame,
                "ENCOUNTER_TIMELINE_EVENT_TRACK_CHANGED")
        end
        abilityTimelineHidden = true
        SetAbilityTimelineAlpha(0)
    else
        if abilityTimelineEventRegistered then
            pcall(eventFrame.UnregisterEvent, eventFrame,
                "ENCOUNTER_TIMELINE_EVENT_ADDED")
            pcall(eventFrame.UnregisterEvent, eventFrame,
                "ENCOUNTER_TIMELINE_EVENT_TRACK_CHANGED")
            abilityTimelineEventRegistered = false
        end
        if abilityTimelineHidden then
            abilityTimelineHidden = false
            SetAbilityTimelineAlpha(1)
        end
    end
end

local function ScheduleAbilityTimelineApply()
    if abilityTimelineApplyScheduled then
        return
    end
    if not C_Timer or type(C_Timer.After) ~= "function" then
        ApplyAbilityTimelineState()
        return
    end
    -- AT 的容器与组件可能在自身 ADDON_LOADED 回调中才准备好。
    abilityTimelineApplyScheduled = true
    C_Timer.After(0, function()
        abilityTimelineApplyScheduled = false
        ApplyAbilityTimelineState()
    end)
end

-- ---------------------------------------------------------------------------
-- EXBoss 计时条 / 束状条
-- ---------------------------------------------------------------------------

local function GetExbossGeneral()
    local root = _G.EXBOSS12S2
    if type(root) ~= "table" or (IsSecretTable and IsSecretTable(root)) then
        return nil
    end

    local uiSettings = root.ui
    if type(uiSettings) ~= "table" or (IsSecretTable and IsSecretTable(uiSettings)) then
        return nil
    end

    local general = uiSettings.general
    if type(general) ~= "table" or (IsSecretTable and IsSecretTable(general)) then
        return nil
    end
    return general
end

local function IsExbossTimelineBars(value)
    return type(value) == "table" and not (IsSecretTable and IsSecretTable(value))
        and type(value.bun) == "boolean" and type(value.timer) == "boolean"
end

local function GetExbossTimelineBars(general)
    local exboss = _G.ExBoss
    local policy = type(exboss) == "table" and exboss.DisplayPolicy
    if type(policy) == "table" and type(policy.GetTimelineBars) == "function" then
        local succeeded, bars = pcall(policy.GetTimelineBars)
        -- 当前接口未准备好时不能退回旧字段：它在新版仅用于首次迁移。
        return succeeded and IsExbossTimelineBars(bars) and bars or nil, true
    end
    if general and general.timelineBars ~= nil then
        local bars = general.timelineBars
        return IsExbossTimelineBars(bars) and bars or nil, true
    end
    return nil, false
end

local function ReleaseExbossBars()
    local exboss = _G.ExBoss
    local uiModules = type(exboss) == "table" and exboss.UI
    if type(uiModules) ~= "table" then
        return
    end

    local timerBar = uiModules.TimerBar
    if type(timerBar) == "table" and type(timerBar.ReleaseAll) == "function" then
        pcall(timerBar.ReleaseAll, timerBar)
    end
    local bunBar = uiModules.BunBar
    if type(bunBar) == "table" and type(bunBar.ReleaseAll) == "function" then
        pcall(bunBar.ReleaseAll, bunBar)
    end
end

local function RefreshExbossBars()
    local exboss = _G.ExBoss
    local timeline = type(exboss) == "table" and exboss.Timeline
    local scheduler = type(timeline) == "table" and timeline.Scheduler
    if type(scheduler) == "table" and type(scheduler.RefreshTimelineBars) == "function"
        and pcall(scheduler.RefreshTimelineBars, scheduler) then
        return
    end
    ReleaseExbossBars()
end

local function ApplyExbossState()
    if not settings then
        return
    end

    local general = GetExbossGeneral()
    local bars, modern = GetExbossTimelineBars(general)
    if modern then
        if not bars then
            return
        end
    elseif not general or (general.barDisplayMode ~= "none"
        and not EXBOSS_BAR_MODES[general.barDisplayMode]) then
        return
    end

    -- 功能前提：EXBoss 的"团本中禁用 EXBoss"必须关闭，否则团本里 EXBoss 会
    -- 整体自清（圆环/中心文字也没了）。功能开启时自动关闭它。
    if settings.hideExbossBarsInRaid == true and general and general.disableEXBossInRaid == true then
        general.disableEXBossInRaid = false
    end

    local shouldHide = settings.hideExbossBarsInRaid == true and GetInstanceType() == "raid"
    if modern then
        local previousMode = settings.exbossSavedBarMode
        if previousMode then
            -- 旧 RRC 写入的 none 可能已被 EXBoss 迁移成双 false；只凭有效备份
            -- 和旧 none 确认归属。已有新备份或当前可见配置优先，不猜用户原选择。
            if not settings.exbossSavedTimelineBars and not bars.bun and not bars.timer
                and general and general.barDisplayMode == "none" then
                settings.exbossSavedTimelineBars = {
                    bun = previousMode == "bun" or previousMode == "both",
                    timer = previousMode == "timer" or previousMode == "both",
                }
            end
            if general and general.barDisplayMode == "none" then
                general.barDisplayMode = previousMode
            end
            settings.exbossSavedBarMode = nil
        end

        local saved = settings.exbossSavedTimelineBars
        if shouldHide then
            if (bars.bun or bars.timer) and not saved then
                settings.exbossSavedTimelineBars = { bun = bars.bun, timer = bars.timer }
            end
            bars.bun, bars.timer = false, false
            -- 重载或旧配置迁移后也清理当前显示和挂载标记，不只在字段变化时清屏。
            RefreshExbossBars()
        elseif saved then
            if not bars.bun and not bars.timer then
                bars.bun, bars.timer = saved.bun, saved.timer
                RefreshExbossBars()
            end
            -- 已有可见项说明外部已修改配置，尊重当前选择，丢弃失去归属的备份。
            settings.exbossSavedTimelineBars = nil
        end
        return
    end

    if shouldHide then
        if general.barDisplayMode ~= "none" then
            if EXBOSS_BAR_MODES[general.barDisplayMode] then
                settings.exbossSavedBarMode = general.barDisplayMode
            end
            general.barDisplayMode = "none"
            ReleaseExbossBars()
        end
    elseif general.barDisplayMode == "none"
        and type(settings.exbossSavedBarMode) == "string" then
        -- 只恢复由本模块写入的 "none"；用户自己选的"两者都隐藏"不动。
        general.barDisplayMode = settings.exbossSavedBarMode
        settings.exbossSavedBarMode = nil
    end
end

local function ScheduleExbossApply()
    if exbossApplyScheduled then
        return
    end
    if not C_Timer or type(C_Timer.After) ~= "function" then
        ApplyExbossState()
        return
    end
    -- EXBoss 在同一 ADDON_LOADED 事件内初始化 DB，不依赖双方回调的执行顺序。
    exbossApplyScheduled = true
    C_Timer.After(0, function()
        exbossApplyScheduled = false
        ApplyExbossState()
    end)
end

-- ---------------------------------------------------------------------------
-- 状态驱动
-- ---------------------------------------------------------------------------

local function ApplyAllStates()
    ApplyBigWigsState()
    ApplyAbilityTimelineState()
    ApplyExbossState()
end

local function OnBigWigsMessage(event, moduleName)
    if event == "BigWigs_PluginOptionsReady" and moduleName ~= "Bars" then
        return
    end
    ApplyBigWigsState()
end

local function TryRegisterStyle()
    if styleRegistered then
        return true
    end

    local api = _G.BigWigsAPI
    if not api or type(api.RegisterBarStyle) ~= "function" then
        return false
    end

    styleRegistered = pcall(api.RegisterBarStyle, api, STYLE_KEY, barStyle)
    return styleRegistered
end

local function TryRegisterMessages()
    if messagesRegistered then
        return true
    end

    local loader = _G.BigWigsLoader
    if not loader or type(loader.RegisterMessage) ~= "function" then
        return false
    end

    local profileRegistered = pcall(loader.RegisterMessage, callbackObject,
        "BigWigs_ProfileUpdate", OnBigWigsMessage)
    local optionsRegistered = pcall(loader.RegisterMessage, callbackObject,
        "BigWigs_PluginOptionsReady", OnBigWigsMessage)
    local coreRegistered = pcall(loader.RegisterMessage, callbackObject,
        "BigWigs_CoreEnabled", OnBigWigsMessage)
    messagesRegistered = profileRegistered and optionsRegistered and coreRegistered
    return messagesRegistered
end

-- ---------------------------------------------------------------------------
-- 设置 / 界面 / 初始化
-- ---------------------------------------------------------------------------

local function InitializeBigWigsBarHiderSettings(db)
    if type(db.bigwigsBarHider) ~= "table"
        or (IsSecretTable and IsSecretTable(db.bigwigsBarHider)) then
        db.bigwigsBarHider = {}
    end

    local barHiderSettings = db.bigwigsBarHider
    if type(barHiderSettings.enabled) ~= "boolean" then
        barHiderSettings.enabled = false
    end
    if type(barHiderSettings.onlyInDungeon) ~= "boolean" then
        barHiderSettings.onlyInDungeon = false
    end
    if type(barHiderSettings.hideExbossBarsInRaid) ~= "boolean" then
        barHiderSettings.hideExbossBarsInRaid = false
    end
    if type(barHiderSettings.previousBarStyle) ~= "string" then
        barHiderSettings.previousBarStyle = nil
    end
    if type(barHiderSettings.exbossSavedBarMode) ~= "string"
        or not EXBOSS_BAR_MODES[barHiderSettings.exbossSavedBarMode] then
        barHiderSettings.exbossSavedBarMode = nil
    end
    local savedBars = barHiderSettings.exbossSavedTimelineBars
    if not IsExbossTimelineBars(savedBars) or not (savedBars.bun or savedBars.timer) then
        barHiderSettings.exbossSavedTimelineBars = nil
    end
    settings = barHiderSettings
end

local function RefreshUI()
    if enabledCheckButton then
        enabledCheckButton:SetChecked(settings and settings.enabled == true)
    end
    if onlyInDungeonCheckButton then
        onlyInDungeonCheckButton:SetChecked(settings and settings.onlyInDungeon == true)
    end
    if exbossCheckButton then
        exbossCheckButton:SetChecked(settings and settings.hideExbossBarsInRaid == true)
    end
end

local function SetControls(newEnabledCheckButton, newOnlyInDungeonCheckButton,
    newExbossCheckButton)
    enabledCheckButton = newEnabledCheckButton
    onlyInDungeonCheckButton = newOnlyInDungeonCheckButton
    exbossCheckButton = newExbossCheckButton
    RefreshUI()
end

local function SetEnabled(enabled)
    if not settings then
        return
    end

    settings.enabled = enabled == true
    ApplyAllStates()
    RefreshUI()
end

local function SetOnlyInDungeon(onlyInDungeon)
    if not settings then
        return
    end

    settings.onlyInDungeon = onlyInDungeon == true
    ApplyAllStates()
    RefreshUI()
end

local function SetHideExbossBarsInRaid(hideExbossBarsInRaid)
    if not settings then
        return
    end

    settings.hideExbossBarsInRaid = hideExbossBarsInRaid == true
    ApplyExbossState()
    RefreshUI()
end

local function Initialize()
    if initialized then
        ApplyAllStates()
        return
    end
    initialized = true

    TryRegisterStyle()
    TryRegisterMessages()
    -- BW 就绪后也保留监听，AT / EXBoss 可能随后才加载；三者均为可选插件。
    eventFrame:RegisterEvent("ADDON_LOADED")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    ApplyAllStates()
end

eventFrame:SetScript("OnEvent", function(_, event, addonName)
    if event == "ADDON_LOADED" then
        if addonName == "BigWigs" then
            TryRegisterStyle()
            TryRegisterMessages()
            ApplyBigWigsState()
        elseif addonName == "AbilityTimeline" then
            ScheduleAbilityTimelineApply()
        elseif type(addonName) == "string" and addonName:lower() == "exboss" then
            ScheduleExbossApply()
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        ApplyAllStates()
    elseif event == "ENCOUNTER_TIMELINE_EVENT_ADDED"
        or event == "ENCOUNTER_TIMELINE_EVENT_TRACK_CHANGED" then
        ScheduleAbilityTimelineSweep()
    end
end)

ns.BigWigsBarHider = {
    InitializeSettings = InitializeBigWigsBarHiderSettings,
    SetControls = SetControls,
    SetEnabled = SetEnabled,
    SetOnlyInDungeon = SetOnlyInDungeon,
    SetHideExbossBarsInRaid = SetHideExbossBarsInRaid,
    RefreshUI = RefreshUI,
    Initialize = Initialize,
}
