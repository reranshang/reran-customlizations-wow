local _, ns = ...

local AutoInvite = {}
ns.AutoInvite = AutoInvite

local settings
local eventFrame = CreateFrame("Frame")
local monitoredEvents = { "CHAT_MSG_WHISPER", "CHAT_MSG_BN_WHISPER", "CHAT_MSG_GUILD" }

function AutoInvite.InitializeSettings(database)
    if type(database.autoInvite) ~= "table" then
        database.autoInvite = {}
    end
    settings = database.autoInvite
    settings.enabled = settings.enabled == true
    if type(settings.channels) ~= "table" then
        settings.channels = {}
    end
    for _, event in ipairs(monitoredEvents) do
        if type(settings.channels[event]) ~= "boolean" then
            settings.channels[event] = true
        end
    end

    if type(settings.strings) ~= "table" then
        settings.strings = { "RRC-Inviteme" }
    end
    local strings = {}
    for _, text in ipairs(settings.strings) do
        if type(text) == "string" then
            strings[#strings + 1] = text
        end
    end
    settings.strings = strings
end

function AutoInvite.GetSettings()
    return settings
end

function AutoInvite.SetEnabled(enabled)
    settings.enabled = not not enabled
    for _, event in ipairs(monitoredEvents) do
        if settings.enabled and settings.channels[event] then
            eventFrame:RegisterEvent(event)
        else
            eventFrame:UnregisterEvent(event)
        end
    end
end

function AutoInvite.SetChannelEnabled(event, enabled)
    for _, monitoredEvent in ipairs(monitoredEvents) do
        if event == monitoredEvent then
            settings.channels[event] = not not enabled
            AutoInvite.SetEnabled(settings.enabled)
            return
        end
    end
end

function AutoInvite.Initialize()
    AutoInvite.SetEnabled(settings.enabled)
end

local function IsReadableString(value)
    return not (ns.IsSecretValue and ns.IsSecretValue(value))
        and type(value) == "string" and value ~= ""
end

function AutoInvite.MatchesMessage(message)
    if not settings or not IsReadableString(message) then
        return false
    end
    for _, text in ipairs(settings.strings) do
        -- 完整、区分大小写的字节比较；不裁剪空格，不使用模式匹配。
        if text ~= "" and message == text then
            return true
        end
    end
    return false
end

local function CanInviteNow()
    -- 交由游戏判断邀请权限（包括团队助理），不额外屏蔽战斗或大秘境。
    if not C_PartyInfo.CanInvite() then
        return false
    end
    local maximum = IsInRaid(LE_PARTY_CATEGORY_HOME) and 40 or 5
    return GetNumGroupMembers(LE_PARTY_CATEGORY_HOME) < maximum
end

local function IsAlreadyGrouped(sender)
    return ns.SafeUnitBoolean(UnitIsUnit, sender, "player") == true
        or ns.SafeUnitBoolean(UnitInParty, sender) == true
        or ns.SafeUnitBoolean(UnitInRaid, sender) == true
end

local function ShouldInvite(message)
    return settings and settings.enabled and AutoInvite.MatchesMessage(message) and CanInviteNow()
end

function AutoInvite.HandleWhisper(message, sender)
    if not IsReadableString(sender) or not ShouldInvite(message) or IsAlreadyGrouped(sender) then
        return
    end
    -- 角色密语和公会聊天使用事件给出的角色全名，保留跨服后缀。
    -- 游戏可能拒绝当前环境下的邀请；不绕过限制，也不排队补邀。
    pcall(C_PartyInfo.InviteUnit, sender)
end

local function IsReadableValue(value)
    return not (ns.IsSecretValue and ns.IsSecretValue(value))
end

local function IsReadableTable(value)
    return IsReadableValue(value) and type(value) == "table"
        and not (ns.IsSecretTable and ns.IsSecretTable(value))
end

function AutoInvite.HandleBattleNetWhisper(message, accountID)
    if not ShouldInvite(message) or not IsReadableValue(accountID)
        or type(accountID) ~= "number" or accountID <= 0 then
        return
    end
    -- 新版 retail 使用 C_BattleNet；保留旧命名以兼容沿用旧接口的客户端。
    local battleNet = C_BattleNet or C_BNet
    local getAccountInfo = battleNet and battleNet.GetAccountInfoByID
    local inviteFriend = (battleNet and battleNet.InviteFriend) or BNInviteFriend
    if type(getAccountInfo) ~= "function" or type(inviteFriend) ~= "function" then
        return
    end
    local succeeded, accountInfo = pcall(getAccountInfo, accountID)
    if not succeeded or not IsReadableTable(accountInfo)
        or not IsReadableValue(accountInfo.isFriend) or accountInfo.isFriend ~= true then
        return
    end
    local game = accountInfo.gameAccountInfo
    if not IsReadableTable(game) or not IsReadableString(game.clientProgram)
        or game.clientProgram ~= "WoW" or not IsReadableValue(game.isOnline) or game.isOnline ~= true
        or not IsReadableValue(game.wowProjectID) or game.wowProjectID ~= WOW_PROJECT_ID
        or not IsReadableValue(game.isInCurrentRegion) or game.isInCurrentRegion == false
        or not IsReadableValue(game.gameAccountID) or type(game.gameAccountID) ~= "number"
        or game.gameAccountID <= 0 then
        return
    end
    if IsReadableString(game.characterName) and IsReadableString(game.realmName) then
        local sender = game.characterName .. "-" .. game.realmName:gsub("%s+", "")
        if IsAlreadyGrouped(sender) then return end
    end
    -- 战网显示名不是角色名；使用解析出的游戏账号 ID 邀请，不把 BattleTag 当角色名。
    pcall(inviteFriend, game.gameAccountID)
end

function AutoInvite.GetExportText()
    local first = settings and settings.strings[1]
    if not IsReadableString(first) then
        return nil, "请先填写第一条匹配字符串。"
    end
    local name, realm = UnitFullName("player")
    if not IsReadableString(realm) then
        realm = GetNormalizedRealmName()
    end
    if not IsReadableString(name) or not IsReadableString(realm) then
        return nil, "暂时无法获取当前角色的完整名称。"
    end
    return "/w " .. name .. "-" .. realm .. " " .. first
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
    if not settings or not settings.enabled or not settings.channels[event] then
        return
    end
    local message, sender = ...
    if event == "CHAT_MSG_WHISPER" or event == "CHAT_MSG_GUILD" then
        AutoInvite.HandleWhisper(message, sender)
    elseif event == "CHAT_MSG_BN_WHISPER" then
        -- 第 13 个聊天事件参数是战网发送者账号 ID，不是显示名或游戏账号 ID。
        AutoInvite.HandleBattleNetWhisper(message, select(13, ...))
    end
end)
