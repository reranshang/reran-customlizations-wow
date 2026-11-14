-- Run from the addon directory: lua tests/AutoInvite.test.lua
-- Standalone Lua 5.1+ tests; no game client or external libraries required.
local ns = {}
local frames = {}
local Frame = {}
Frame.__index = Frame
function Frame:SetScript(event, callback) self.scripts[event] = callback end
function Frame:RegisterEvent(event) self.events[event] = true end
function Frame:UnregisterEvent(event) self.events[event] = nil end
function CreateFrame()
    local frame = setmetatable({ scripts = {}, events = {} }, Frame)
    frames[#frames + 1] = frame
    return frame
end

local secret = setmetatable({}, { __eq = function() error("secret compared") end })
ns.IsSecretValue = function(value) return rawequal(value, secret) end
ns.SafeUnitBoolean = function(api, ...)
    local ok, result = pcall(api, ...)
    if not ok or ns.IsSecretValue(result) then return nil end
    return result ~= nil and result ~= false and result ~= 0
end

LE_PARTY_CATEGORY_HOME = 1
local allowed, raid, memberCount, inParty, inRaid, selfSender = true, false, 0, false, false, false
local invitations = {}
local chatText
local battleNetInvitations = {}
local gameAccount = {
    gameAccountID = 456, clientProgram = "WoW", isOnline = true,
    wowProjectID = 1, isInCurrentRegion = true,
    characterName = "战网角色", realmName = "跨服",
}
local accountInfo = { isFriend = true, gameAccountInfo = gameAccount }
WOW_PROJECT_ID = 1
C_BattleNet = {
    GetAccountInfoByID = function(id)
        assert(id == 123, "account ID must come from argument 13, not the display name")
        return accountInfo
    end,
    InviteFriend = function(id) battleNetInvitations[#battleNetInvitations + 1] = id end,
}
local rejectInvite = false
C_PartyInfo = {
    CanInvite = function() return allowed end,
    InviteUnit = function(sender)
        if rejectInvite then error("game restriction") end
        invitations[#invitations + 1] = sender
    end,
}
-- These must never be queried to exclude a combat/challenge whisper.
InCombatLockdown = function() error("unexpected combat gate") end
UnitAffectingCombat = InCombatLockdown
C_PartyInfo.IsChallengeModeActive = InCombatLockdown
C_PartyInfo.ChallengeModeRestrictionsActive = InCombatLockdown
IsInRaid = function(category) assert(category == LE_PARTY_CATEGORY_HOME); return raid end
GetNumGroupMembers = function(category) assert(category == LE_PARTY_CATEGORY_HOME); return memberCount end
UnitIsUnit = function() return selfSender end
UnitInParty = function() return inParty end
UnitInRaid = function() return inRaid end
local characterName, characterRealm = "A", "服务器1"
UnitFullName = function() return characterName, characterRealm end
GetNormalizedRealmName = function() return "服务器2" end
ChatFrame_OpenChat = function() error("export must not open a chat input") end

assert(loadfile("Modules/AutoInvite.lua"))("RRC", ns)
local AutoInvite = ns.AutoInvite
local database = {}
AutoInvite.InitializeSettings(database)
assert(database.autoInvite.enabled == false)
assert(database.autoInvite.strings[1] == "RRC-Inviteme")
AutoInvite.Initialize()
assert(not frames[1].events.CHAT_MSG_WHISPER)
AutoInvite.SetEnabled(true)
assert(frames[1].events.CHAT_MSG_WHISPER)
assert(frames[1].events.CHAT_MSG_BN_WHISPER)
assert(frames[1].events.CHAT_MSG_GUILD)
local settings = AutoInvite.GetSettings()
settings.strings = { "RRC-Inviteme", "rrc_inviteme", "a.b+[x]%", " padded " }

local checks = 0
local function expectInvite(message, sender, expected)
    local before = #invitations
    frames[1].scripts.OnEvent(frames[1], "CHAT_MSG_WHISPER", message, sender)
    assert(#invitations - before == (expected and 1 or 0), "unexpected invite for " .. tostring(message))
    if expected then assert(invitations[#invitations] == sender) end
    checks = checks + 1
end
expectInvite("RRC-Inviteme", "玩家-跨服", true)
expectInvite("rrc_inviteme", "玩家-跨服", true)
expectInvite("RRC_Inviteme", "玩家-跨服", false)
expectInvite("rrc-inviteme", "玩家-跨服", false)
expectInvite("RRC-Inviteme ", "玩家-跨服", false)
expectInvite(" RRC-Inviteme", "玩家-跨服", false)
expectInvite("xxRRC-Invitemexx", "玩家-跨服", false)
expectInvite("a.b+[x]%", "玩家-跨服", true)
expectInvite("axb+[x]%", "玩家-跨服", false)
expectInvite(" padded ", "玩家-跨服", true)
expectInvite("padded", "玩家-跨服", false)
expectInvite("", "玩家-跨服", false)
expectInvite(nil, "玩家-跨服", false)
expectInvite(secret, "玩家-跨服", false)
expectInvite("RRC-Inviteme", secret, false)
expectInvite("RRC-Inviteme", "", false)
expectInvite("RRC-Inviteme", nil, false)
allowed = false
expectInvite("RRC-Inviteme", "玩家-跨服", false)
allowed = true
-- Raid assistants are allowed by the API; no leader-only check exists.
raid, memberCount = true, 25
expectInvite("RRC-Inviteme", "助理邀请目标-跨服", true)
memberCount = 40
expectInvite("RRC-Inviteme", "玩家-跨服", false)
raid, memberCount = false, 5
expectInvite("RRC-Inviteme", "玩家-跨服", false)
memberCount = 0
inParty = true
expectInvite("RRC-Inviteme", "玩家-跨服", false)
inParty, inRaid = false, 2
expectInvite("RRC-Inviteme", "玩家-跨服", false)
inRaid, selfSender = false, true
expectInvite("RRC-Inviteme", "玩家-跨服", false)
selfSender, rejectInvite = false, true
expectInvite("RRC-Inviteme", "玩家-跨服", false)
rejectInvite = false
AutoInvite.SetEnabled(false)
assert(not frames[1].events.CHAT_MSG_WHISPER)
expectInvite("RRC-Inviteme", "玩家-跨服", false)
AutoInvite.SetEnabled(true)
local function expectEvent(event, message, sender, expected)
    local before = #invitations
    frames[1].scripts.OnEvent(frames[1], event, message, sender)
    assert(#invitations - before == (expected and 1 or 0))
    if expected then assert(invitations[#invitations] == sender) end
    checks = checks + 1
end
expectEvent("CHAT_MSG_GUILD", "RRC-Inviteme", "公会成员-跨服", true)
expectEvent("CHAT_MSG_GUILD", "rrc_inviteme", "公会成员-跨服", true)
expectEvent("CHAT_MSG_GUILD", "RRC_Inviteme", "公会成员-跨服", false)
expectEvent("CHAT_MSG_GUILD", "RRC-Inviteme ", "公会成员-跨服", false)
expectEvent("CHAT_MSG_GUILD", secret, "公会成员-跨服", false)
expectEvent("CHAT_MSG_GUILD", "RRC-Inviteme", secret, false)
selfSender = true
expectEvent("CHAT_MSG_GUILD", "RRC-Inviteme", "A-服务器1", false)
selfSender = false
expectEvent("CHAT_MSG_OFFICER", "RRC-Inviteme", "公会成员-跨服", false)
expectEvent("CHAT_MSG_WHISPER_INFORM", "RRC-Inviteme", "玩家-跨服", false)
expectEvent("CHAT_MSG_BN_WHISPER_INFORM", "RRC-Inviteme", "战网显示名", false)

local function expectBattleNet(message, id, expected)
    local before = #battleNetInvitations
    local characterBefore = #invitations
    frames[1].scripts.OnEvent(frames[1], "CHAT_MSG_BN_WHISPER", message, "战网显示名",
        "", "", "", "", 0, 0, "", 0, 0, "", id)
    assert(#battleNetInvitations - before == (expected and 1 or 0))
    assert(#invitations == characterBefore, "Battle.net display name used as character")
    if expected then assert(battleNetInvitations[#battleNetInvitations] == 456) end
    checks = checks + 1
end
expectBattleNet("RRC-Inviteme", 123, true)
expectBattleNet("rrc_inviteme", 123, true)
expectBattleNet("RRC_Inviteme", 123, false)
expectBattleNet("RRC-Inviteme ", 123, false)
expectBattleNet(secret, 123, false)
expectBattleNet("RRC-Inviteme", secret, false)
expectBattleNet("RRC-Inviteme", nil, false)
expectBattleNet("RRC-Inviteme", 0, false)
accountInfo.isFriend = false
expectBattleNet("RRC-Inviteme", 123, false)
accountInfo.isFriend = true
gameAccount.clientProgram = "D3"
expectBattleNet("RRC-Inviteme", 123, false)
gameAccount.clientProgram = "WoW"
gameAccount.wowProjectID = 2
expectBattleNet("RRC-Inviteme", 123, false)
gameAccount.wowProjectID = 1
gameAccount.isOnline = false
expectBattleNet("RRC-Inviteme", 123, false)
gameAccount.isOnline = true
gameAccount.isInCurrentRegion = false
expectBattleNet("RRC-Inviteme", 123, false)
gameAccount.isInCurrentRegion = true
gameAccount.gameAccountID = secret
expectBattleNet("RRC-Inviteme", 123, false)
gameAccount.gameAccountID = 456
accountInfo.gameAccountInfo = secret
expectBattleNet("RRC-Inviteme", 123, false)
accountInfo.gameAccountInfo = gameAccount
inParty = true
expectBattleNet("RRC-Inviteme", 123, false)
inParty = false
allowed = false
expectBattleNet("RRC-Inviteme", 123, false)
expectEvent("CHAT_MSG_GUILD", "RRC-Inviteme", "公会成员-跨服", false)
allowed = true
-- Compatibility with the older C_BNet namespace and BNInviteFriend API.
C_BNet = { GetAccountInfoByID = C_BattleNet.GetAccountInfoByID }
BNInviteFriend = C_BattleNet.InviteFriend
C_BattleNet = nil
expectBattleNet("RRC-Inviteme", 123, true)
AutoInvite.SetEnabled(false)
assert(not frames[1].events.CHAT_MSG_WHISPER)
assert(not frames[1].events.CHAT_MSG_BN_WHISPER)
assert(not frames[1].events.CHAT_MSG_GUILD)
expectBattleNet("RRC-Inviteme", 123, false)
expectEvent("CHAT_MSG_GUILD", "RRC-Inviteme", "公会成员-跨服", false)
AutoInvite.SetEnabled(true)

-- Each monitored channel can be switched independently, including queued events.
for _, event in ipairs({ "CHAT_MSG_WHISPER", "CHAT_MSG_BN_WHISPER", "CHAT_MSG_GUILD" }) do
    AutoInvite.SetChannelEnabled(event, false)
    assert(settings.channels[event] == false and not frames[1].events[event])
    expectEvent("CHAT_MSG_GUILD", "RRC-Inviteme", "公会成员-跨服", event ~= "CHAT_MSG_GUILD")
    expectInvite("RRC-Inviteme", "玩家-跨服", event ~= "CHAT_MSG_WHISPER")
    expectBattleNet("RRC-Inviteme", 123, event ~= "CHAT_MSG_BN_WHISPER")
    AutoInvite.SetEnabled(false)
    AutoInvite.SetEnabled(true)
    assert(not frames[1].events[event], "master toggle must retain channel preferences")
    AutoInvite.SetChannelEnabled(event, true)
    assert(frames[1].events[event])
end
AutoInvite.SetEnabled(false)
AutoInvite.SetChannelEnabled("CHAT_MSG_GUILD", false)
AutoInvite.SetChannelEnabled("CHAT_MSG_GUILD", true)
assert(not frames[1].events.CHAT_MSG_GUILD, "channel toggle must not enable the feature")
AutoInvite.SetEnabled(true)

assert(AutoInvite.GetExportText() == "/w A-服务器1 RRC-Inviteme")
characterRealm = nil
assert(AutoInvite.GetExportText() == "/w A-服务器2 RRC-Inviteme")
settings.strings = { "", "valid second row" }
assert(not AutoInvite.GetExportText())
expectInvite("", "玩家-跨服", false)
expectInvite("valid second row", "玩家-跨服", true)
settings.strings = {}
assert(not AutoInvite.GetExportText())
expectInvite("RRC-Inviteme", "玩家-跨服", false)
AutoInvite.InitializeSettings({ autoInvite = { enabled = "true", strings = { "keep", 123, "" } } })
assert(not AutoInvite.GetSettings().enabled)
assert(#AutoInvite.GetSettings().strings == 2)
assert(AutoInvite.GetSettings().strings[1] == "keep")
assert(AutoInvite.GetSettings().strings[2] == "")
for _, event in ipairs({ "CHAT_MSG_WHISPER", "CHAT_MSG_BN_WHISPER", "CHAT_MSG_GUILD" }) do
    assert(AutoInvite.GetSettings().channels[event] == true)
end
local persisted = { autoInvite = { channels = { CHAT_MSG_GUILD = false } } }
AutoInvite.InitializeSettings(persisted)
assert(not persisted.autoInvite.channels.CHAT_MSG_GUILD)
assert(persisted.autoInvite.channels.CHAT_MSG_WHISPER)
AutoInvite.InitializeSettings({ autoInvite = { strings = { "keep", "" } } })

-- Exercise the actual configuration-page factory with lightweight widget stubs.
function Frame:SetAllPoints() end
function Frame:SetPoint() end
function Frame:SetSize(width, height) self.width, self.height = width, height end
function Frame:SetWidth(width) self.width = width end
function Frame:SetHeight(height) self.height = height end
function Frame:GetWidth() return self.width or 400 end
function Frame:GetHeight() return self.height or 450 end
function Frame:SetJustifyH() end
function Frame:SetWordWrap() end
function Frame:SetText(text)
    self.text = text
    if self.scripts.OnTextChanged then self.scripts.OnTextChanged(self, false) end
end
function Frame:GetText() return self.text or "" end
function Frame:GetStringHeight() return 30 end
function Frame:SetChecked(value) self.checked = value end
function Frame:GetChecked() return self.checked end
function Frame:SetEnabled(value) self.enabled = value end
function Frame:SetAutoFocus() end
function Frame:SetMaxBytes() end
function Frame:SetScrollChild(child) self.scrollChild = child end
function Frame:SetVerticalScroll(value) self.scroll = value end
function Frame:GetVerticalScroll() return self.scroll or 0 end
function Frame:ClearFocus() self.focus = false end
function Frame:SetFocus() self.focus = true end
function Frame:HasFocus() return self.focus == true end
function Frame:HighlightText() self.highlighted = true end
function Frame:Show() self.shown = true end
function Frame:Hide() self.shown = false end
function Frame:CreateFontString() return CreateFrame() end
local configFile = assert(io.open("Config.lua", "r"))
local configSource = configFile:read("*a")
configFile:close()
local factorySource = assert(configSource:match("(local function CreateAutoInvitePage.-)\nlocal function CreateConfigFrame"))
local compile = loadstring or load
local factory = assert(compile("local ns = ...\n" .. factorySource .. "\nreturn CreateAutoInvitePage"))(ns)
local firstWidget = #frames + 1
local pageHandler = factory(CreateFrame())
pageHandler.Refresh()
local addButton, exportButton, exportOutput, deleteButtons, inputs = nil, nil, nil, {}, {}
for index = firstWidget, #frames do
    local widget = frames[index]
    if widget.text == "添加字符串" then addButton = widget end
    if widget.text == "导出密语" then exportButton = widget end
    if widget.scripts.OnEditFocusGained then exportOutput = widget end
    if widget.text == "删除" then deleteButtons[#deleteButtons + 1] = widget end
    if widget.scripts.OnTextChanged then inputs[#inputs + 1] = widget end
end
assert(addButton and exportButton and #inputs == 2 and #deleteButtons == 2)
local uiSettings = AutoInvite.GetSettings()
local channelControlCount = 0
for index = firstWidget, #frames do
    local widget = frames[index]
    if widget.scripts.OnClick and widget.checked == true then
        widget:SetChecked(false)
        widget.scripts.OnClick(widget)
        channelControlCount = channelControlCount + 1
    end
end
assert(channelControlCount == 3)
assert(not uiSettings.channels.CHAT_MSG_WHISPER)
assert(not uiSettings.channels.CHAT_MSG_BN_WHISPER)
assert(not uiSettings.channels.CHAT_MSG_GUILD)
pageHandler.Refresh()
inputs[1]:SetText("Guild_Exact")
inputs[1].scripts.OnTextChanged(inputs[1], true)
assert(uiSettings.strings[1] == "Guild_Exact")
assert(AutoInvite.MatchesMessage("Guild_Exact"))
assert(not AutoInvite.MatchesMessage("guild_exact"))
addButton.scripts.OnClick()
assert(#uiSettings.strings == 3 and uiSettings.strings[3] == "")
deleteButtons[1].scripts.OnClick()
assert(#uiSettings.strings == 2 and uiSettings.strings[1] == "" and not exportButton.enabled)
inputs[1]:SetText("New_First")
inputs[1].scripts.OnTextChanged(inputs[1], true)
exportButton.scripts.OnClick()
assert(exportOutput and exportOutput:GetText() == "/w A-服务器2 New_First")
assert(exportOutput:HasFocus() and exportOutput.highlighted)
assert(chatText == nil)
exportOutput.scripts.OnEscapePressed(exportOutput)
assert(not exportOutput:HasFocus())
exportButton.scripts.OnClick()
pageHandler.CloseEditors()
assert(not exportOutput:HasFocus())
inputs[1]:SetText("Updated_First")
inputs[1].scripts.OnTextChanged(inputs[1], true)
assert(exportOutput:GetText() == "")
exportButton.scripts.OnClick()
assert(exportOutput:GetText() == "/w A-服务器2 Updated_First")
deleteButtons[1].scripts.OnClick()
assert(exportOutput:GetText() == "")
deleteButtons[1].scripts.OnClick()
assert(#uiSettings.strings == 0 and not exportButton.enabled)
pageHandler.CloseEditors()
pageHandler.OnConfigHide()

-- Syntax-check every shipped Lua file without executing other feature modules.
for line in io.lines("ReRan's customlizations.toc") do
    if line:match("%.lua%s*$") then
        assert(loadfile((line:gsub("\r$", ""))))
    end
end
print("PASS: " .. checks .. " chat scenarios, settings, UI add/delete/edit/export and shipped Lua syntax")
