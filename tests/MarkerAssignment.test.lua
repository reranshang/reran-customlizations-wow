-- Run from the addon directory: lua tests/MarkerAssignment.test.lua
local ns = {
    ClearTable = function(t) for key in pairs(t) do t[key] = nil end end,
}
local eventFrame = { scripts = {} }
function eventFrame:SetScript(event, callback) self.scripts[event] = callback end
function eventFrame:RegisterEvent() end
function CreateFrame() return eventFrame end
local combat = false
InCombatLockdown = function() return combat end
IsInGroup = function() return false end
IsInRaid = function() return false end
GetServerTime = function() return 100 end
GetTime = function() return 1 end
C_ChatInfo = { RegisterAddonMessagePrefix = function() return true end }
C_Timer = { After = function() end }
local macroBody
GetNumMacros = function() return macroBody and 1 or 0, 0 end
GetMacroInfo = function() return "RRC-TM", 134400, macroBody end
CreateMacro = function(_, _, body) macroBody = body; return 1 end
EditMacro = function(_, _, _, body) macroBody = body end

assert(loadfile("Modules/MarkerAssignment.lua"))("RRC", ns)
local MarkerAssignment = ns.MarkerAssignment
local database = {}
MarkerAssignment.InitializeSettings(database)
local settings = MarkerAssignment.GetSettings()
assert(not settings.overwriteExistingMarkers)
assert(settings.chatText == "我焦点打断-%f")
MarkerAssignment.Initialize()
MarkerAssignment.SetEnabled(true)
assert(macroBody:find("/tm [@focus] ~1", 1, true))
assert(macroBody:find("/p 我焦点打断-%f", 1, true))
MarkerAssignment.SetOverwriteExistingMarkers(true)
assert(macroBody:find("/tm [@focus] 1", 1, true))
assert(not macroBody:find("~1", 1, true))
MarkerAssignment.SetChatText("自定义焦点-%f")
assert(settings.chatText == "自定义焦点-%f")
assert(macroBody:find("/p 自定义焦点-%f", 1, true))
MarkerAssignment.SetChatChannelMode(MarkerAssignment.CHAT_INSTANCE)
assert(macroBody:find("/i 自定义焦点-%f", 1, true))
MarkerAssignment.SetOverwriteExistingMarkers(false)
assert(macroBody:find("/tm [@focus] ~1", 1, true))

-- No embedded macro commands; the text field only supplies a single chat line.
MarkerAssignment.SetChatText("焦点-%f\n/clearfocus")
assert(settings.chatText == "焦点-%f /clearfocus")
assert(not macroBody:find("\n/clearfocus", 1, true))
MarkerAssignment.SetChatText("")
assert(not macroBody:find("/i ", 1, true))
MarkerAssignment.SetChatChannelMode(MarkerAssignment.CHAT_PARTY_RAID)
IsInRaid = function() return true end
MarkerAssignment.SetChatText(string.rep("x", MarkerAssignment.CHAT_TEXT_MAX_BYTES))
assert(#macroBody == 255, "longest supported macro must fit exactly")
MarkerAssignment.SetChatText(string.rep("x", MarkerAssignment.CHAT_TEXT_MAX_BYTES + 1))
assert(settings.chatText == "我焦点打断-%f")
assert(#macroBody <= 255)
IsInRaid = function() return false end

-- Edits made during combat update settings immediately and the macro after combat.
local before = macroBody
combat = true
MarkerAssignment.SetOverwriteExistingMarkers(true)
MarkerAssignment.SetChatText("战斗修改-%f")
assert(settings.overwriteExistingMarkers and settings.chatText == "战斗修改-%f")
assert(macroBody == before)
combat = false
eventFrame.scripts.OnEvent(eventFrame, "PLAYER_REGEN_ENABLED")
assert(macroBody:find("/tm [@focus] 1", 1, true))
assert(macroBody:find("/p 战斗修改-%f", 1, true))

-- Disabled feature keeps the last macro; saved preferences survive initialization.
MarkerAssignment.SetEnabled(false)
before = macroBody
MarkerAssignment.SetChatText("下次启用-%f")
MarkerAssignment.SetOverwriteExistingMarkers(false)
assert(macroBody == before)
MarkerAssignment.InitializeSettings(database)
assert(MarkerAssignment.GetSettings().chatText == "下次启用-%f")
assert(not MarkerAssignment.GetSettings().overwriteExistingMarkers)
MarkerAssignment.SetEnabled(true)
assert(macroBody:find("/tm [@focus] ~1", 1, true))
assert(macroBody:find("/p 下次启用-%f", 1, true))
print("PASS: marker macro defaults, overwrite, custom chat, length, combat deferral and persistence")
