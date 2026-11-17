local _, ns = ...

local settings
local initialized = false
local eventFrame = CreateFrame("Frame")
local trackedFrames = setmetatable({}, { __mode = "k" })
local hookedMixins = {}
local hookedVFlowStyle
local elapsedUpdate, elapsedScan = 0, 0
local GLOW_KEY = "RRC_CDM_BUFF"
local glowTypes = {
    { key = "proc", label = "触发发光" },
    { key = "pixel", label = "像素发光" },
    { key = "autocast", label = "自动施法发光" },
    { key = "button", label = "按钮发光" },
}

local function IsSecret(value)
    return ns.IsSecretValue and ns.IsSecretValue(value)
end

local function GetGlowLibrary()
    return _G.LibStub and _G.LibStub("LibCustomGlow-1.0", true)
end

local function StopGlow(state)
    if state.glowType then
        local lib = GetGlowLibrary()
        if lib then
            if state.glowType == "proc" then
                lib.ProcGlow_Stop(state.host, GLOW_KEY)
            elseif state.glowType == "pixel" then
                lib.PixelGlow_Stop(state.host, GLOW_KEY)
            elseif state.glowType == "autocast" then
                lib.AutoCastGlow_Stop(state.host, GLOW_KEY)
            else
                lib.ButtonGlow_Stop(state.host)
            end
        end
        state.glowType = nil
    end
    if state.host and state.host:IsShown() then state.host:Hide() end
    state.alphaMode = nil
end

local function StartGlow(frame, state)
    local lib = GetGlowLibrary()
    if not lib then return end
    if state.glowType == settings.glowType then
        local level = frame:GetFrameLevel() + 5
        if state.host:GetFrameLevel() ~= level then state.host:SetFrameLevel(level) end
        return
    end
    StopGlow(state)
    if not state.host then
        local host = CreateFrame("Frame", nil, frame)
        host:SetAllPoints(frame)
        host:EnableMouse(false)
        state.host = host
    end
    local host = state.host
    host:SetFrameLevel(frame:GetFrameLevel() + 5)
    host:Show()
    if settings.glowType == "proc" then
        lib.ProcGlow_Start(host, { key = GLOW_KEY, frameLevel = 1, startAnim = false })
    elseif settings.glowType == "pixel" then
        lib.PixelGlow_Start(host, nil, 8, 0.25, nil, 2, 0, 0, false, GLOW_KEY, 1)
    elseif settings.glowType == "autocast" then
        lib.AutoCastGlow_Start(host, nil, 4, 0.25, 1, 0, 0, GLOW_KEY, 1)
    else
        lib.ButtonGlow_Start(host, nil, nil, 1)
    end
    state.glowType = settings.glowType
end

-- 判断的是 CDM 当前的增益显示模式，不读取/计算秘密的 Buff 剩余时间。
local function GetBuffDisplayState(frame)
    local hideBuff = frame._vf_hideBuffCooldownOverlay
    if not IsSecret(hideBuff) and hideBuff then return false end

    local mode = frame.cooldownUseAuraDisplayTime
    if IsSecret(mode) then
        return mode
    end
    if mode then return true end

    -- 与 vFlow 一致：模式字段同步前，用 CDM 保存的原始 swipe 色作兜底。
    -- 不读 Cooldown:GetSwipeColor，避免把 vFlow 的自定义色当成状态。
    local color = frame.cooldownSwipeColor
    if not IsSecret(color) and color and type(color) ~= "number" and color.GetRGBA then
        local succeeded, red = pcall(color.GetRGBA, color)
        if succeeded and not IsSecret(red) and type(red) == "number" then
            return red ~= 0
        end
    end
    return false
end

local function RestoreReverse(frame, state)
    if not state.reverseOwned then return end
    state.reapplyingReverse = true
    local succeeded = pcall(frame.Cooldown.SetReverse, frame.Cooldown, state.originalReverse)
    state.reapplyingReverse = nil
    if succeeded then state.reverseOwned = nil end
end

local function UpdateReverse(frame, state, active)
    local cooldown = frame.Cooldown
    if not settings or not settings.enabled or not settings.reverseBuffSwipe or not state.active
        or not frame:IsShown() or IsSecret(active) or not active then
        RestoreReverse(frame, state)
        return
    end
    if state.reverseOwned or type(cooldown.SetReverse) ~= "function" then return end
    if state.originalReverse == nil and type(cooldown.GetReverse) == "function" then
        local succeeded, reverse = pcall(cooldown.GetReverse, cooldown)
        if succeeded and not IsSecret(reverse) and type(reverse) == "boolean" then
            state.originalReverse = reverse
        end
    end
    -- 无法安全保存原方向时不接管，避免退出 Buff 后破坏普通冷却。
    if state.originalReverse == nil or state.originalReverse == true then return end
    state.reapplyingReverse = true
    local succeeded = pcall(cooldown.SetReverse, cooldown, true)
    state.reapplyingReverse = nil
    if succeeded then state.reverseOwned = true end
end

local function WriteSwipeColor(frame, state, color)
    if not color or type(frame.Cooldown.SetSwipeColor) ~= "function" then return false end
    state.reapplyingColor = true
    local succeeded = pcall(frame.Cooldown.SetSwipeColor, frame.Cooldown,
        color.r, color.g, color.b, color.a)
    state.reapplyingColor = nil
    return succeeded
end

local function RestoreColor(frame, state)
    if state.vflowColorOwned then
        if frame._vf_buffMaskColor == state.appliedBuffColor then
            frame._vf_buffMaskColor = state.originalBuffColor
        end
        state.vflowColorOwned = nil
        state.appliedBuffColor = nil
        local active = GetBuffDisplayState(frame)
        if not IsSecret(active) then
            local color = active and frame._vf_buffMaskColor or frame._vf_cooldownMaskColor
            local hideBuff, charge = frame._vf_hideBuffCooldownOverlay, frame._vf_spellOnlyChargeRechargeActive
            if not IsSecret(hideBuff) and hideBuff and not IsSecret(charge) and charge then
                color = frame._vf_chargeRechargeMaskColor or color
            end
            WriteSwipeColor(frame, state, color)
        end
        state.originalBuffColor = nil
        state.colorOwned = nil
    elseif state.colorOwned then
        if WriteSwipeColor(frame, state, state.originalSwipeColor) then state.colorOwned = nil end
    end
    state.appliedColor = nil
    if not state.colorOwned then
        state.originalSwipeColor = nil
        state.colorDirty = nil
    end
end

local function UpdateVFlowColor(frame, state)
    if not settings or not settings.enabled or not settings.overrideBuffColor or not state.active then
        return false
    end
    if not frame.Cooldown._vf_swipeColorHooked or not frame._vf_buffMaskColor then return false end
    if not state.vflowColorOwned or frame._vf_buffMaskColor ~= state.appliedBuffColor then
        state.originalBuffColor = frame._vf_buffMaskColor
    end
    state.vflowColorOwned = true
    state.appliedBuffColor = settings.buffSwipeColor
    -- 替换图标的配色输入，不修改 vFlow 分组配置或其原颜色表。
    if frame._vf_buffMaskColor ~= state.appliedBuffColor then
        frame._vf_buffMaskColor = state.appliedBuffColor
    end
    return true
end

local function UpdateColor(frame, state, active)
    if not settings or not settings.enabled or not settings.overrideBuffColor or not state.active then
        RestoreColor(frame, state)
        return
    end
    local vflow = UpdateVFlowColor(frame, state)
    if IsSecret(active) or not active then
        if not vflow then RestoreColor(frame, state) end
        state.appliedColor = nil
        return
    end
    if not vflow and not state.originalSwipeColor then
        local color = frame.cooldownSwipeColor
        if not IsSecret(color) and color and type(color) ~= "number" and color.GetRGBA then
            local succeeded, r, g, b, a = pcall(color.GetRGBA, color)
            if succeeded then state.originalSwipeColor = { r = r, g = g, b = b, a = a } end
        end
        if not state.originalSwipeColor then return end
    end
    if state.appliedColor == settings.buffSwipeColor and (vflow or not state.colorDirty) then return end
    if WriteSwipeColor(frame, state, settings.buffSwipeColor) then
        state.colorOwned = true
        state.appliedColor = settings.buffSwipeColor
        state.colorDirty = nil
    end
end

local function UpdateFrame(frame, state)
    local active = false
    if settings and settings.enabled and state.active and frame:IsShown() then
        active = GetBuffDisplayState(frame)
    end
    UpdateReverse(frame, state, active)
    UpdateColor(frame, state, active)
    if not settings or not settings.enabled or not settings.buffHighlight or not state.active then
        StopGlow(state)
        return
    end
    if IsSecret(active) then
        StartGlow(frame, state)
        if state.host and state.host.SetAlphaFromBoolean then
            -- 秘密布尔值直传原生显示接口，不进入 Lua 条件判断。
            state.host:SetAlphaFromBoolean(active, 1, 0)
            state.alphaMode = "secret"
        else
            StopGlow(state)
        end
    elseif active then
        StartGlow(frame, state)
        if state.host and state.alphaMode ~= "visible" then
            state.host:SetAlpha(1)
            state.alphaMode = "visible"
        end
    else
        StopGlow(state)
    end
end

local function TrackFrame(frame)
    if not frame or not frame.Cooldown or not frame.Icon or frame._vf_itemAppendFrame then return end
    local state = trackedFrames[frame]
    if not state then
        state = {}
        trackedFrames[frame] = state
        frame:HookScript("OnHide", function()
            StopGlow(state)
            RestoreReverse(frame, state)
            RestoreColor(frame, state)
        end)
        local cooldown = frame.Cooldown
        if type(cooldown.SetSwipeColor) == "function" then
            hooksecurefunc(cooldown, "SetSwipeColor", function(_, r, g, b, a)
                if state.reapplyingColor or frame.Cooldown._vf_swipeColorHooked then return end
                if not settings or not settings.enabled or not settings.overrideBuffColor then return end
                -- 原生刷新只保存颜色并标记，不在钩子内写回；秘密分量不参与比较。
                state.originalSwipeColor = { r = r, g = g, b = b, a = a }
                state.colorOwned = nil
                state.colorDirty = true
            end)
        end
        if type(cooldown.SetReverse) == "function" then
            hooksecurefunc(cooldown, "SetReverse", function(_, reverse)
                if state.reapplyingReverse then return end
                state.reverseOwned = nil
                state.originalReverse = nil
                if not IsSecret(reverse) and type(reverse) == "boolean" then
                    state.originalReverse = reverse
                end
                -- 只记录外部方向写入，统一在轮询中处理，不在冷却刷新栈内写回。
            end)
        end
    end
    state.active = true
end

local function ScanViewer(viewer)
    if not viewer then return end
    if viewer.itemFramePool and viewer.itemFramePool.EnumerateActive then
        for frame in viewer.itemFramePool:EnumerateActive() do TrackFrame(frame) end
    else
        for _, frame in ipairs({ viewer:GetChildren() }) do TrackFrame(frame) end
    end
end

local function ScanFrames()
    for _, state in pairs(trackedFrames) do state.active = false end
    -- 原生池仍拥有被 vFlow 移入自定义分组的 CDM 条目。
    ScanViewer(_G.EssentialCooldownViewer)
    ScanViewer(_G.UtilityCooldownViewer)
    for frame, state in pairs(trackedFrames) do UpdateFrame(frame, state) end
end

local function InstallHooks()
    local style = _G.VFlow and _G.VFlow.StyleApply
    if style and style ~= hookedVFlowStyle and type(style.ApplyAuraSwipeColor) == "function" then
        hookedVFlowStyle = style
        hooksecurefunc(style, "ApplyAuraSwipeColor", function(frame)
            local state = trackedFrames[frame]
            if state then UpdateVFlowColor(frame, state) end
        end)
    end
    for _, name in ipairs({ "CooldownViewerEssentialItemMixin", "CooldownViewerUtilityItemMixin" }) do
        local mixin = _G[name]
        if mixin and not hookedMixins[mixin] and type(mixin.OnCooldownIDSet) == "function" then
            hookedMixins[mixin] = true
            hooksecurefunc(mixin, "OnCooldownIDSet", TrackFrame)
        end
    end
end

local function Refresh()
    if settings and settings.enabled
        and (settings.buffHighlight or settings.reverseBuffSwipe or settings.overrideBuffColor) then
        InstallHooks()
        elapsedUpdate, elapsedScan = 0, 0
        ScanFrames()
        eventFrame:SetScript("OnUpdate", function(_, elapsed)
            elapsedUpdate = elapsedUpdate + elapsed
            elapsedScan = elapsedScan + elapsed
            if elapsedScan >= 1 then
                elapsedScan = 0
                ScanFrames()
            elseif elapsedUpdate >= 0.1 then
                for frame, state in pairs(trackedFrames) do UpdateFrame(frame, state) end
            end
            if elapsedUpdate >= 0.1 then elapsedUpdate = 0 end
        end)
    else
        eventFrame:SetScript("OnUpdate", nil)
        for frame, state in pairs(trackedFrames) do
            StopGlow(state)
            RestoreReverse(frame, state)
            RestoreColor(frame, state)
        end
    end
end

local function InitializeSettings(db)
    if type(db.cdmColors) ~= "table" then db.cdmColors = {} end
    settings = db.cdmColors
    if type(settings.enabled) ~= "boolean" then settings.enabled = false end
    if type(settings.buffHighlight) ~= "boolean" then settings.buffHighlight = false end
    if type(settings.reverseBuffSwipe) ~= "boolean" then settings.reverseBuffSwipe = false end
    if type(settings.overrideBuffColor) ~= "boolean" then settings.overrideBuffColor = false end
    if type(settings.buffSwipeColor) ~= "table" then settings.buffSwipeColor = {} end
    local defaults = { r = 0, g = 0, b = 0, a = 0.7 }
    for key, value in pairs(defaults) do
        local component = settings.buffSwipeColor[key]
        if type(component) ~= "number" or component ~= component then component = value end
        settings.buffSwipeColor[key] = math.max(0, math.min(1, component))
    end
    local validType = false
    for _, option in ipairs(glowTypes) do
        if settings.glowType == option.key then validType = true end
    end
    if not validType then settings.glowType = "proc" end
end

local function Initialize()
    if initialized then return end
    initialized = true
    eventFrame:RegisterEvent("ADDON_LOADED")
    eventFrame:RegisterEvent("PLAYER_LOGIN")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventFrame:SetScript("OnEvent", Refresh)
    Refresh()
end

ns.CDMColors = {
    InitializeSettings = InitializeSettings,
    GetSettings = function() return settings end,
    GetGlowTypes = function() return glowTypes end,
    SetEnabled = function(enabled)
        settings.enabled = enabled == true
        Refresh()
    end,
    SetBuffHighlight = function(enabled)
        settings.buffHighlight = enabled == true
        Refresh()
    end,
    SetReverseBuffSwipe = function(enabled)
        settings.reverseBuffSwipe = enabled == true
        Refresh()
    end,
    SetOverrideBuffColor = function(enabled)
        settings.overrideBuffColor = enabled == true
        Refresh()
    end,
    Refresh = Refresh,
    SetGlowType = function(glowType)
        for _, option in ipairs(glowTypes) do
            if option.key == glowType then
                settings.glowType = glowType
                Refresh()
                return
            end
        end
    end,
    Initialize = Initialize,
}
