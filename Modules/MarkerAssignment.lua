local _, ns = ...

local IsSecretValue = ns.IsSecretValue
local IsSecretTable = ns.IsSecretTable
local ClearTable = ns.ClearTable
local SafeUnitBoolean = ns.SafeUnitBoolean

local MARKER_ASSIGNMENT_PREFIX = "RRC_TM3"
local MARKER_ASSIGNMENT_PROTOCOL_VERSION = "2"
local MARKER_ASSIGNMENT_MACRO_NAME = "RRC-TM"
local MARKER_ASSIGNMENT_MACRO_ICON = 134400
local MARKER_ASSIGNMENT_CHAT_PARTY_RAID = "PARTY_RAID"
local MARKER_ASSIGNMENT_CHAT_INSTANCE = "INSTANCE"
local MARKER_ASSIGNMENT_COUNT = 8
local MARKER_ASSIGNMENT_DISCOVERY_DELAY = 0.6
local MARKER_ASSIGNMENT_RETRY_DELAY = 1.2
local MARKER_ASSIGNMENT_RECOVERY_DELAY = 5
local MARKER_ASSIGNMENT_MAX_RETRIES = 2
local MARKER_ASSIGNMENT_ROSTER_DELAY = 0.2
local MARKER_ASSIGNMENT_MESSAGE_LIMIT = 220

local function NormalizeMarkerAssignmentID(value)
    if IsSecretValue and IsSecretValue(value) then
        return nil
    end

    value = tonumber(value)
    if not value or value ~= math.floor(value)
        or value < 1 or value > MARKER_ASSIGNMENT_COUNT then
        return nil
    end
    return value
end

local function NormalizeDisabledMarkers(value)
    local normalized = {}
    if type(value) == "table" and not (IsSecretTable and IsSecretTable(value)) then
        for marker = 1, MARKER_ASSIGNMENT_COUNT do
            if value[marker] == true then
                normalized[marker] = true
            end
        end
    end
    return normalized
end

local function NormalizeMarkerAssignmentChatChannelMode(value)
    if IsSecretValue and IsSecretValue(value) then
        return MARKER_ASSIGNMENT_CHAT_PARTY_RAID
    end
    if value == MARKER_ASSIGNMENT_CHAT_INSTANCE then
        return MARKER_ASSIGNMENT_CHAT_INSTANCE
    end
    return MARKER_ASSIGNMENT_CHAT_PARTY_RAID
end

local markerAssignmentSettings
local markerAssignmentControls
local markerAssignmentCurrentText
local markerAssignmentStatusText
local markerAssignmentEventFrame = CreateFrame("Frame")
local markerAssignmentSessionID
local markerAssignmentStatusSequence = 0
local markerAssignmentPlanSequence = 0
local markerAssignmentRoster = {}
local markerAssignmentRosterByKey = {}
local markerAssignmentSenderAliases = {}
local markerAssignmentPeers = {}
local markerAssignmentMessageRates = {}
local markerAssignmentLatestSessions = {}
local markerAssignmentRetiredSessions = {}
local markerAssignmentRosterSignature
local markerAssignmentDiscoveryGeneration = 0
local markerAssignmentRosterGeneration = 0
local markerAssignmentRetryCount = 0
local markerAssignmentIncumbent = false
local markerAssignmentDiscoveryPending = false
local markerAssignmentDiscoveryCollecting = false
local markerAssignmentPendingReconcile = false
local markerAssignmentPrefixRegistered = false
local markerAssignmentMacroError
local markerAssignmentCommunicationError
local markerAssignmentCommunicationBlocked = false
local markerAssignmentPendingStateBroadcast = false
local markerAssignmentStateRetryScheduled = false
local markerAssignmentLatestStatusSequences = {}
local markerAssignmentLastPlanSequence = {}
local markerAssignmentMacroRefreshGeneration = 0
local markerAssignmentMacroRetryScheduled = false
local markerAssignmentPendingMacroUpdate = false
local RefreshMarkerAssignmentUI
local RequestMarkerAssignmentReconcile
local ScheduleMarkerAssignmentMacroRetry

local function IsRegularMarkerAssignmentParty()
    if type(IsInGroup) ~= "function" or not IsInGroup() then
        return false
    end
    if type(IsInRaid) == "function" and IsInRaid() then
        return false
    end
    if LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
        return false
    end
    return true
end

local function IsSoloMarkerAssignmentContext()
    if type(IsInGroup) ~= "function" or IsInGroup() then
        return false
    end
    if LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
        return false
    end
    if type(IsInRaid) == "function" and IsInRaid() then
        return false
    end
    return true
end

local function GetMarkerAssignmentFullName(unit)
    if type(UnitFullName) ~= "function" then
        return nil
    end

    local succeeded, name, realm = pcall(UnitFullName, unit)
    if not succeeded or (IsSecretValue and (IsSecretValue(name) or IsSecretValue(realm)))
        or type(name) ~= "string" or name == "" then
        return nil
    end

    if type(realm) ~= "string" or realm == "" then
        if type(GetNormalizedRealmName) == "function" then
            local realmSucceeded, normalizedRealm = pcall(GetNormalizedRealmName)
            if realmSucceeded and not (IsSecretValue and IsSecretValue(normalizedRealm))
                and type(normalizedRealm) == "string" then
                realm = normalizedRealm
            end
        end
    end
    if type(realm) ~= "string" or realm == "" then
        return name, name
    end

    realm = realm:gsub("%s+", "")
    return name .. "-" .. realm, name
end

local function HashMarkerAssignmentText(text)
    local hash = 7
    for index = 1, #text do
        hash = (hash * 131 + string.byte(text, index)) % 2147483647
    end
    return tostring((hash + #text) % 2147483647)
end

local function RebuildMarkerAssignmentRoster()
    if not IsRegularMarkerAssignmentParty() then
        ClearTable(markerAssignmentRoster)
        ClearTable(markerAssignmentRosterByKey)
        ClearTable(markerAssignmentSenderAliases)
        ClearTable(markerAssignmentPeers)
        ClearTable(markerAssignmentMessageRates)
        ClearTable(markerAssignmentLatestSessions)
        ClearTable(markerAssignmentRetiredSessions)
        ClearTable(markerAssignmentLatestStatusSequences)
        ClearTable(markerAssignmentLastPlanSequence)
        markerAssignmentRosterSignature = nil
        return false
    end

    local previousRemoteKeys = {}
    for _, entry in ipairs(markerAssignmentRoster) do
        if entry.unit ~= "player" then
            previousRemoteKeys[entry.key] = true
        end
    end

    local memberCount = 0
    if type(GetNumSubgroupMembers) == "function" then
        local succeeded, count = pcall(GetNumSubgroupMembers)
        if not succeeded or (IsSecretValue and IsSecretValue(count))
            or type(count) ~= "number" then
            return false
        end
        memberCount = math.min(4, math.max(0, math.floor(count)))
    end

    local units = { "player" }
    for index = 1, memberCount do
        units[#units + 1] = "party" .. index
    end

    local nextRoster = {}
    local nextRosterByKey = {}
    local nextSenderAliases = {}
    for _, unit in ipairs(units) do
        local fullName, shortName = GetMarkerAssignmentFullName(unit)
        if not fullName or nextRosterByKey[fullName] then
            return false
        end
        local connected = SafeUnitBoolean(UnitIsConnected, unit)
        local entry = {
            key = fullName,
            shortName = shortName,
            unit = unit,
            connected = connected ~= false,
        }
        nextRoster[#nextRoster + 1] = entry
        nextRosterByKey[fullName] = entry
    end

    table.sort(nextRoster, function(left, right)
        return left.key < right.key
    end)

    local hasRosterContinuity = false
    for _, entry in ipairs(nextRoster) do
        if entry.unit ~= "player" and previousRemoteKeys[entry.key] then
            hasRosterContinuity = true
            break
        end
    end
    if not hasRosterContinuity then
        markerAssignmentIncumbent = false
    end

    for index, entry in ipairs(nextRoster) do
        entry.index = index
        nextSenderAliases[entry.key] = entry.key
        local existing = nextSenderAliases[entry.shortName]
        if existing and existing ~= entry.key then
            nextSenderAliases[entry.shortName] = false
        elseif existing == nil then
            nextSenderAliases[entry.shortName] = entry.key
        end
    end

    markerAssignmentRoster = nextRoster
    markerAssignmentRosterByKey = nextRosterByKey
    markerAssignmentSenderAliases = nextSenderAliases

    for key in pairs(markerAssignmentPeers) do
        if not markerAssignmentRosterByKey[key] then
            markerAssignmentPeers[key] = nil
            markerAssignmentMessageRates[key] = nil
        end
    end
    for key in pairs(markerAssignmentMessageRates) do
        if not markerAssignmentRosterByKey[key] then
            markerAssignmentMessageRates[key] = nil
        end
    end
    for key in pairs(markerAssignmentLatestSessions) do
        if not markerAssignmentRosterByKey[key] then
            markerAssignmentLatestSessions[key] = nil
            markerAssignmentRetiredSessions[key] = nil
        end
    end
    for statusKey in pairs(markerAssignmentLatestStatusSequences) do
        local senderKey = statusKey:match("^([^|]+)|")
        if not senderKey or not markerAssignmentRosterByKey[senderKey] then
            markerAssignmentLatestStatusSequences[statusKey] = nil
        end
    end
    for planKey in pairs(markerAssignmentLastPlanSequence) do
        local senderKey = planKey:match("^([^|]+)|")
        if not senderKey or not markerAssignmentRosterByKey[senderKey] then
            markerAssignmentLastPlanSequence[planKey] = nil
        end
    end

    local rosterKeys = {}
    for index, entry in ipairs(markerAssignmentRoster) do
        rosterKeys[index] = entry.key
    end
    markerAssignmentRosterSignature = HashMarkerAssignmentText(table.concat(rosterKeys, ";"))
    return true
end

local function ResolveMarkerAssignmentSender(sender)
    if type(sender) ~= "string" or sender == "" then
        return nil
    end

    local key = markerAssignmentSenderAliases[sender]
    if key then
        return key
    end

    if type(Ambiguate) == "function" then
        local succeeded, shortName = pcall(Ambiguate, sender, "short")
        if succeeded and type(shortName) == "string" then
            key = markerAssignmentSenderAliases[shortName]
            if key then
                return key
            end
        end
    end
    return nil
end

local function IsMarkerAssignmentDisabled(mask, marker)
    return math.floor(mask / (2 ^ (marker - 1))) % 2 == 1
end

local function GetLocalMarkerAssignmentDisabledMask()
    local mask = 0
    for marker = 1, MARKER_ASSIGNMENT_COUNT do
        if markerAssignmentSettings.disabledMarkers[marker] then
            mask = mask + 2 ^ (marker - 1)
        end
    end
    return mask
end

local function GetLocalMarkerAssignmentKey()
    for _, entry in ipairs(markerAssignmentRoster) do
        if entry.unit == "player" then
            return entry.key
        end
    end
    return nil
end

local function UpdateLocalMarkerAssignmentPeer()
    local playerKey = GetLocalMarkerAssignmentKey()
    if not playerKey then
        return nil
    end

    local peer = markerAssignmentPeers[playerKey] or {}
    peer.sessionID = markerAssignmentSessionID
    peer.sequence = markerAssignmentStatusSequence
    peer.enabled = markerAssignmentSettings.enabled
    peer.disabledMask = GetLocalMarkerAssignmentDisabledMask()
    peer.incumbent = markerAssignmentIncumbent
    peer.currentMarker = markerAssignmentSettings.assignedMarker or 0
    peer.lastSeen = GetTime and GetTime() or 0
    markerAssignmentPeers[playerKey] = peer
    return playerKey
end

local function ClearRemoteMarkerAssignmentPeers()
    local playerKey = GetLocalMarkerAssignmentKey()
    for key in pairs(markerAssignmentPeers) do
        if key ~= playerKey then
            markerAssignmentPeers[key] = nil
        end
    end
end

local function SendMarkerAssignmentAddonMessage(message)
    if InCombatLockdown and InCombatLockdown() then
        return false, "combat"
    end
    if not markerAssignmentPrefixRegistered or not IsRegularMarkerAssignmentParty()
        or type(message) ~= "string" or #message > MARKER_ASSIGNMENT_MESSAGE_LIMIT then
        return false
    end

    local succeeded, result = pcall(C_ChatInfo.SendAddonMessage,
        MARKER_ASSIGNMENT_PREFIX, message, "PARTY")
    local successCode = Enum and Enum.SendAddonMessageResult
        and Enum.SendAddonMessageResult.Success or 0
    local sent = succeeded and (result == nil or result == true or result == successCode)
    return sent, result
end

local SendMarkerAssignmentState

local function ScheduleMarkerAssignmentStateRetry()
    if markerAssignmentStateRetryScheduled then
        return
    end
    markerAssignmentStateRetryScheduled = true
    C_Timer.After(MARKER_ASSIGNMENT_RECOVERY_DELAY, function()
        markerAssignmentStateRetryScheduled = false
        if markerAssignmentPendingStateBroadcast and IsRegularMarkerAssignmentParty() then
            SendMarkerAssignmentState()
        end
    end)
end

SendMarkerAssignmentState = function()
    if InCombatLockdown and InCombatLockdown() then
        markerAssignmentPendingStateBroadcast = true
        return false, "combat"
    end
    if not RebuildMarkerAssignmentRoster() then
        markerAssignmentPendingStateBroadcast = true
        ScheduleMarkerAssignmentStateRetry()
        return false
    end

    markerAssignmentStatusSequence = markerAssignmentStatusSequence + 1
    local playerKey = UpdateLocalMarkerAssignmentPeer()
    if not playerKey then
        return false
    end

    local message = table.concat({
        MARKER_ASSIGNMENT_PROTOCOL_VERSION,
        "S",
        markerAssignmentSessionID,
        tostring(markerAssignmentStatusSequence),
        markerAssignmentSettings.enabled and "1" or "0",
        tostring(GetLocalMarkerAssignmentDisabledMask()),
        markerAssignmentIncumbent and "1" or "0",
        tostring(markerAssignmentSettings.assignedMarker or 0),
    }, "|")
    local sent, result = SendMarkerAssignmentAddonMessage(message)
    markerAssignmentPendingStateBroadcast = not sent
    if not sent then
        ScheduleMarkerAssignmentStateRetry()
    end
    return sent, result
end

local function SendMarkerAssignmentQuery()
    markerAssignmentStatusSequence = markerAssignmentStatusSequence + 1
    return SendMarkerAssignmentAddonMessage(table.concat({
        MARKER_ASSIGNMENT_PROTOCOL_VERSION,
        "Q",
        markerAssignmentSessionID,
        tostring(markerAssignmentStatusSequence),
    }, "|"))
end

local function BuildMarkerAssignmentParticipants()
    local participants = {}
    for _, entry in ipairs(markerAssignmentRoster) do
        local peer = markerAssignmentPeers[entry.key]
        if entry.connected and peer and peer.enabled then
            participants[#participants + 1] = {
                key = entry.key,
                rosterIndex = entry.index,
                disabledMask = peer.disabledMask,
                incumbent = peer.incumbent,
                currentMarker = peer.currentMarker,
            }
        end
    end
    return participants
end

local function GetMarkerAssignmentConfigSignature()
    local parts = {}
    for index, entry in ipairs(markerAssignmentRoster) do
        local peer = markerAssignmentPeers[entry.key]
        if peer then
            parts[index] = table.concat({
                entry.key,
                entry.connected and "1" or "0",
                peer.sessionID,
                peer.enabled and "1" or "0",
                tostring(peer.disabledMask),
                peer.incumbent and "1" or "0",
                tostring(peer.currentMarker),
            }, ",")
        else
            parts[index] = entry.key .. "," .. (entry.connected and "1" or "0") .. ",-"
        end
    end
    return HashMarkerAssignmentText(table.concat(parts, ";"))
end

local function IsMarkerAssignmentVectorEarlier(left, right)
    if not right then
        return true
    end
    for index = 1, #left do
        if left[index] ~= right[index] then
            return left[index] < right[index]
        end
    end
    return false
end

local function SolveMarkerAssignments(participants)
    local candidateLists = {}
    for index, participant in ipairs(participants) do
        local candidates = {}
        for marker = 1, MARKER_ASSIGNMENT_COUNT do
            if not IsMarkerAssignmentDisabled(participant.disabledMask, marker) then
                candidates[#candidates + 1] = marker
            end
        end
        if #candidates == 0 then
            candidates[1] = 0
        end
        candidateLists[index] = candidates
    end

    local working = {}
    local loads = {}
    local bestVector
    local bestDistinct = -1
    local bestIncumbentRetained = -1
    local bestRetained = -1
    local bestCollisions = math.huge

    local function Evaluate()
        local distinct = 0
        local incumbentRetained = 0
        local retained = 0
        local collisions = 0
        for marker = 1, MARKER_ASSIGNMENT_COUNT do
            local load = loads[marker] or 0
            if load > 0 then
                distinct = distinct + 1
                collisions = collisions + load * (load - 1) / 2
            end
        end
        for index, participant in ipairs(participants) do
            local current = participant.currentMarker
            if current and current > 0 and working[index] == current
                and not IsMarkerAssignmentDisabled(participant.disabledMask, current) then
                retained = retained + 1
                if participant.incumbent then
                    incumbentRetained = incumbentRetained + 1
                end
            end
        end

        local better = distinct > bestDistinct
            or (distinct == bestDistinct and incumbentRetained > bestIncumbentRetained)
            or (distinct == bestDistinct and incumbentRetained == bestIncumbentRetained
                and retained > bestRetained)
            or (distinct == bestDistinct and incumbentRetained == bestIncumbentRetained
                and retained == bestRetained and collisions < bestCollisions)
            or (distinct == bestDistinct and incumbentRetained == bestIncumbentRetained
                and retained == bestRetained and collisions == bestCollisions
                and IsMarkerAssignmentVectorEarlier(working, bestVector))
        if better then
            bestDistinct = distinct
            bestIncumbentRetained = incumbentRetained
            bestRetained = retained
            bestCollisions = collisions
            bestVector = {}
            for index = 1, #working do
                bestVector[index] = working[index]
            end
        end
    end

    local function Search(index)
        if index > #participants then
            Evaluate()
            return
        end

        for _, marker in ipairs(candidateLists[index]) do
            working[index] = marker
            if marker > 0 then
                loads[marker] = (loads[marker] or 0) + 1
            end
            Search(index + 1)
            if marker > 0 then
                loads[marker] = loads[marker] - 1
            end
        end
    end

    Search(1)

    local rosterVector = {}
    for index = 1, #markerAssignmentRoster do
        rosterVector[index] = 0
    end
    for index, participant in ipairs(participants) do
        rosterVector[participant.rosterIndex] = bestVector and bestVector[index] or 0
    end
    return rosterVector
end

local function MarkerAssignmentVectorsEqual(left, right)
    if #left ~= #right then
        return false
    end
    for index = 1, #left do
        if left[index] ~= right[index] then
            return false
        end
    end
    return true
end

local function GetMarkerAssignmentChatCommand()
    if markerAssignmentSettings.chatChannelMode == MARKER_ASSIGNMENT_CHAT_INSTANCE then
        return "/i"
    end
    if type(IsInRaid) == "function" and IsInRaid() then
        return "/raid"
    end
    return "/p"
end

local function BuildMarkerAssignmentMacroBody(marker)
    marker = NormalizeMarkerAssignmentID(marker)
    if marker and markerAssignmentSettings.disabledMarkers[marker] then
        marker = nil
    end

    local lines = {
        "/clearfocus",
        "/focus [@mouseover,harm,nodead][@target,harm,nodead]",
        "/stopmacro [@focus,noexists][@focus,dead][@focus,help]",
    }
    if not markerAssignmentSettings.allowInRaid then
        lines[#lines + 1] = "/stopmacro [group:raid]"
    end
    if marker then
        lines[#lines + 1] = "/tm [@focus] ~" .. marker
    end
    lines[#lines + 1] = "/stopmacro [nogroup]"

    local chatCommand = GetMarkerAssignmentChatCommand()
    lines[#lines + 1] = chatCommand .. " 我焦点打断-%f"
    return table.concat(lines, "\n")
end

local function NormalizeMarkerAssignmentMacroBody(body)
    if type(body) ~= "string" then
        return body
    end
    return (body:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\n+$", ""))
end

local function FindMarkerAssignmentMacros()
    local accountMacroCount, characterMacroCount = GetNumMacros()
    accountMacroCount = tonumber(accountMacroCount) or 0
    characterMacroCount = tonumber(characterMacroCount) or 0
    local maximumAccountMacros = Constants and Constants.MacroConsts
        and Constants.MacroConsts.MAX_ACCOUNT_MACROS or 120
    local macroIndexes = {}

    for index = 1, accountMacroCount do
        local macroName = GetMacroInfo(index)
        if macroName == MARKER_ASSIGNMENT_MACRO_NAME then
            macroIndexes[#macroIndexes + 1] = index
        end
    end

    local firstCharacterMacro = maximumAccountMacros + 1
    for index = firstCharacterMacro, firstCharacterMacro + characterMacroCount - 1 do
        local macroName = GetMacroInfo(index)
        if macroName == MARKER_ASSIGNMENT_MACRO_NAME then
            macroIndexes[#macroIndexes + 1] = index
        end
    end

    return macroIndexes, accountMacroCount, maximumAccountMacros
end

local function ApplyMarkerAssignmentMacro(marker)
    if InCombatLockdown and InCombatLockdown() then
        markerAssignmentPendingMacroUpdate = true
        return false
    end

    local body = BuildMarkerAssignmentMacroBody(marker)
    if #body > 255 then
        markerAssignmentPendingMacroUpdate = true
        markerAssignmentMacroError = "RRC-TM 宏正文超过客户端长度限制。"
        return false
    end

    local succeeded, result = pcall(function()
        local macroIndexes, accountMacroCount, maximumAccountMacros = FindMarkerAssignmentMacros()
        if #macroIndexes > 0 then
            for _, macroIndex in ipairs(macroIndexes) do
                local _, _, existingBody = GetMacroInfo(macroIndex)
                if NormalizeMarkerAssignmentMacroBody(existingBody)
                    ~= NormalizeMarkerAssignmentMacroBody(body) then
                    EditMacro(macroIndex, MARKER_ASSIGNMENT_MACRO_NAME,
                        MARKER_ASSIGNMENT_MACRO_ICON, body)
                    local _, _, updatedBody = GetMacroInfo(macroIndex)
                    if NormalizeMarkerAssignmentMacroBody(updatedBody)
                        ~= NormalizeMarkerAssignmentMacroBody(body) then
                        return "macro_update_failed"
                    end
                end
            end
            return true
        end

        if accountMacroCount >= maximumAccountMacros then
            return "macro_slots_full"
        end

        local createdIndex = CreateMacro(MARKER_ASSIGNMENT_MACRO_NAME,
            MARKER_ASSIGNMENT_MACRO_ICON, body, nil)
        if not createdIndex or createdIndex == 0 then
            return "macro_create_failed"
        end
        local _, _, createdBody = GetMacroInfo(createdIndex)
        if NormalizeMarkerAssignmentMacroBody(createdBody)
            ~= NormalizeMarkerAssignmentMacroBody(body) then
            return "macro_create_failed"
        end
        return true
    end)

    if not succeeded then
        markerAssignmentPendingMacroUpdate = true
        markerAssignmentMacroError = "更新 RRC-TM 失败：" .. tostring(result)
        ScheduleMarkerAssignmentMacroRetry()
        return false
    end
    if result == "macro_slots_full" then
        markerAssignmentPendingMacroUpdate = true
        markerAssignmentMacroError = "账号通用宏栏已满，无法创建 RRC-TM。"
        return false
    end
    if result ~= true then
        markerAssignmentPendingMacroUpdate = true
        markerAssignmentMacroError = "无法创建或更新 RRC-TM。"
        ScheduleMarkerAssignmentMacroRetry()
        return false
    end

    markerAssignmentPendingMacroUpdate = false
    markerAssignmentMacroError = nil
    return true
end

ScheduleMarkerAssignmentMacroRetry = function()
    if markerAssignmentMacroRetryScheduled then
        return
    end
    markerAssignmentMacroRetryScheduled = true
    C_Timer.After(MARKER_ASSIGNMENT_RECOVERY_DELAY, function()
        markerAssignmentMacroRetryScheduled = false
        if not markerAssignmentMacroError or not markerAssignmentSettings.enabled then
            return
        end
        if InCombatLockdown and InCombatLockdown() then
            markerAssignmentPendingReconcile = true
            RefreshMarkerAssignmentUI()
            return
        end
        ApplyMarkerAssignmentMacro(markerAssignmentSettings.assignedMarker)
        RefreshMarkerAssignmentUI()
    end)
end

local function ScheduleMarkerAssignmentMacroRefresh()
    markerAssignmentMacroRefreshGeneration = markerAssignmentMacroRefreshGeneration + 1
    local generation = markerAssignmentMacroRefreshGeneration
    C_Timer.After(0.1, function()
        if generation ~= markerAssignmentMacroRefreshGeneration
            or not markerAssignmentSettings.enabled then
            return
        end
        ApplyMarkerAssignmentMacro(markerAssignmentSettings.assignedMarker)
        RefreshMarkerAssignmentUI()
    end)
end

local function SelectSoloMarkerAssignment()
    local currentMarker = NormalizeMarkerAssignmentID(markerAssignmentSettings.assignedMarker)
    if currentMarker and not markerAssignmentSettings.disabledMarkers[currentMarker] then
        return currentMarker
    end
    for marker = 1, MARKER_ASSIGNMENT_COUNT do
        if not markerAssignmentSettings.disabledMarkers[marker] then
            return marker
        end
    end
    return nil
end

local function ApplySoloMarkerAssignment()
    if InCombatLockdown and InCombatLockdown() then
        markerAssignmentPendingReconcile = true
        RefreshMarkerAssignmentUI()
        return false
    end

    markerAssignmentDiscoveryGeneration = markerAssignmentDiscoveryGeneration + 1
    markerAssignmentRetryCount = 0
    markerAssignmentIncumbent = false
    markerAssignmentDiscoveryPending = false
    markerAssignmentDiscoveryCollecting = false
    markerAssignmentPendingReconcile = false
    markerAssignmentPendingStateBroadcast = false
    markerAssignmentCommunicationBlocked = false
    markerAssignmentSettings.assignedMarker = SelectSoloMarkerAssignment()
    ApplyMarkerAssignmentMacro(markerAssignmentSettings.assignedMarker)
    RefreshMarkerAssignmentUI()
    return true
end

local function ApplyMarkerAssignmentPlan(vector)
    if InCombatLockdown and InCombatLockdown() then
        markerAssignmentPendingReconcile = true
        RefreshMarkerAssignmentUI()
        return false
    end

    local playerKey = GetLocalMarkerAssignmentKey()
    local localMarker
    for index, entry in ipairs(markerAssignmentRoster) do
        local peer = markerAssignmentPeers[entry.key]
        if peer and peer.enabled then
            peer.currentMarker = vector[index] or 0
            peer.incumbent = true
        end
        if entry.key == playerKey then
            localMarker = vector[index]
        end
    end

    markerAssignmentSettings.assignedMarker = NormalizeMarkerAssignmentID(localMarker)
    markerAssignmentIncumbent = true
    markerAssignmentPendingReconcile = false
    markerAssignmentDiscoveryPending = false
    markerAssignmentDiscoveryCollecting = false
    -- Keep the shared assignment stable if the local macro API fails; the UI reports
    -- the error and the macro-only retry path repairs it without perturbing the party.
    ApplyMarkerAssignmentMacro(markerAssignmentSettings.assignedMarker)
    RefreshMarkerAssignmentUI()
    return true
end

local function GetMarkerAssignmentLeaderKey(participants)
    for _, participant in ipairs(participants) do
        if participant.incumbent then
            return participant.key
        end
    end
    return participants[1] and participants[1].key or nil
end

local function SendMarkerAssignmentPlan(vector, configSignature)
    markerAssignmentPlanSequence = markerAssignmentPlanSequence + 1
    local vectorParts = {}
    for index = 1, #markerAssignmentRoster do
        vectorParts[index] = tostring(vector[index] or 0)
    end

    return SendMarkerAssignmentAddonMessage(table.concat({
        MARKER_ASSIGNMENT_PROTOCOL_VERSION,
        "P",
        markerAssignmentSessionID,
        tostring(markerAssignmentPlanSequence),
        markerAssignmentRosterSignature,
        configSignature,
        table.concat(vectorParts),
    }, "|"))
end

local BeginMarkerAssignmentDiscovery
local ScheduleMarkerAssignmentEvaluation

local function ScheduleMarkerAssignmentRetry()
    local retryGeneration = markerAssignmentDiscoveryGeneration
    local delay = markerAssignmentRetryCount < MARKER_ASSIGNMENT_MAX_RETRIES
        and MARKER_ASSIGNMENT_RETRY_DELAY or MARKER_ASSIGNMENT_RECOVERY_DELAY
    C_Timer.After(delay, function()
        if retryGeneration == markerAssignmentDiscoveryGeneration
            and markerAssignmentDiscoveryPending then
            markerAssignmentRetryCount = markerAssignmentRetryCount + 1
            BeginMarkerAssignmentDiscovery(true)
        end
    end)
end

local function FinishMarkerAssignmentDiscovery(generation)
    if generation ~= markerAssignmentDiscoveryGeneration
        or not markerAssignmentSettings.enabled
        or not IsRegularMarkerAssignmentParty() then
        return
    end
    if InCombatLockdown and InCombatLockdown() then
        markerAssignmentPendingReconcile = true
        markerAssignmentDiscoveryPending = false
        markerAssignmentDiscoveryCollecting = false
        RefreshMarkerAssignmentUI()
        return
    end

    markerAssignmentDiscoveryCollecting = false
    if not RebuildMarkerAssignmentRoster() then
        markerAssignmentDiscoveryPending = true
        RefreshMarkerAssignmentUI()
        ScheduleMarkerAssignmentRetry()
        return
    end
    UpdateLocalMarkerAssignmentPeer()
    local participants = BuildMarkerAssignmentParticipants()
    local leaderKey = GetMarkerAssignmentLeaderKey(participants)
    local playerKey = GetLocalMarkerAssignmentKey()
    markerAssignmentDiscoveryPending = leaderKey ~= nil and leaderKey ~= playerKey

    if leaderKey == playerKey then
        local configSignature = GetMarkerAssignmentConfigSignature()
        local vector = SolveMarkerAssignments(participants)
        local planSent = SendMarkerAssignmentPlan(vector, configSignature)
        if planSent then
            markerAssignmentCommunicationBlocked = false
            ApplyMarkerAssignmentPlan(vector)
        else
            markerAssignmentCommunicationBlocked = true
            markerAssignmentDiscoveryPending = true
            RefreshMarkerAssignmentUI()
            ScheduleMarkerAssignmentRetry()
        end
        return
    end

    RefreshMarkerAssignmentUI()
    if leaderKey then
        ScheduleMarkerAssignmentRetry()
    end
end

ScheduleMarkerAssignmentEvaluation = function(delay)
    if not markerAssignmentSettings.enabled or not IsRegularMarkerAssignmentParty() then
        return
    end
    if InCombatLockdown and InCombatLockdown() then
        markerAssignmentPendingReconcile = true
        RefreshMarkerAssignmentUI()
        return
    end

    markerAssignmentDiscoveryGeneration = markerAssignmentDiscoveryGeneration + 1
    local generation = markerAssignmentDiscoveryGeneration
    markerAssignmentDiscoveryPending = true
    RefreshMarkerAssignmentUI()
    C_Timer.After(delay or MARKER_ASSIGNMENT_DISCOVERY_DELAY, function()
        FinishMarkerAssignmentDiscovery(generation)
    end)
end

BeginMarkerAssignmentDiscovery = function(isRetry)
    if not markerAssignmentSettings.enabled or not IsRegularMarkerAssignmentParty() then
        return
    end
    if not markerAssignmentPrefixRegistered then
        markerAssignmentDiscoveryCollecting = false
        markerAssignmentDiscoveryPending = false
        RefreshMarkerAssignmentUI()
        return
    end
    if InCombatLockdown and InCombatLockdown() then
        markerAssignmentPendingReconcile = true
        RefreshMarkerAssignmentUI()
        return
    end

    if not isRetry then
        markerAssignmentRetryCount = 0
    end
    if not RebuildMarkerAssignmentRoster() then
        markerAssignmentDiscoveryCollecting = false
        markerAssignmentDiscoveryPending = true
        RefreshMarkerAssignmentUI()
        ScheduleMarkerAssignmentRetry()
        return
    end
    ClearRemoteMarkerAssignmentPeers()
    markerAssignmentDiscoveryCollecting = true
    local stateSent = SendMarkerAssignmentState()
    local querySent = SendMarkerAssignmentQuery()
    if not stateSent or not querySent then
        markerAssignmentCommunicationBlocked = true
        markerAssignmentDiscoveryCollecting = false
        markerAssignmentDiscoveryPending = true
        RefreshMarkerAssignmentUI()
        ScheduleMarkerAssignmentRetry()
        return
    end

    markerAssignmentCommunicationBlocked = false
    ScheduleMarkerAssignmentEvaluation(MARKER_ASSIGNMENT_DISCOVERY_DELAY)
end

RequestMarkerAssignmentReconcile = function()
    markerAssignmentDiscoveryGeneration = markerAssignmentDiscoveryGeneration + 1
    markerAssignmentDiscoveryPending = false
    markerAssignmentDiscoveryCollecting = false

    if not markerAssignmentSettings or not markerAssignmentSettings.enabled then
        markerAssignmentPendingReconcile = false
        RebuildMarkerAssignmentRoster()
        RefreshMarkerAssignmentUI()
        return
    end

    if IsSoloMarkerAssignmentContext() then
        markerAssignmentCommunicationBlocked = false
        RebuildMarkerAssignmentRoster()
        ApplySoloMarkerAssignment()
        return
    end

    if not IsRegularMarkerAssignmentParty() then
        markerAssignmentCommunicationBlocked = false
        markerAssignmentPendingReconcile = false
        RebuildMarkerAssignmentRoster()
        RefreshMarkerAssignmentUI()
        return
    end

    if InCombatLockdown and InCombatLockdown() then
        markerAssignmentPendingReconcile = true
        RefreshMarkerAssignmentUI()
        return
    end

    markerAssignmentPendingReconcile = false
    BeginMarkerAssignmentDiscovery(false)
end

local function ParseMarkerAssignmentInteger(value, minimum, maximum)
    if type(value) ~= "string" or not value:match("^%d+$") then
        return nil
    end
    local number = tonumber(value)
    if not number or number < minimum or number > maximum then
        return nil
    end
    return number
end

local function SplitMarkerAssignmentMessage(message)
    if type(message) ~= "string" or #message > MARKER_ASSIGNMENT_MESSAGE_LIMIT then
        return nil
    end

    local fields = {}
    for field in (message .. "|"):gmatch("([^|]*)|") do
        fields[#fields + 1] = field
    end
    return fields
end

local function IsMarkerAssignmentSenderRateLimited(senderKey)
    local now = GetTime and GetTime() or 0
    local rate = markerAssignmentMessageRates[senderKey]
    if not rate or now - rate.windowStart >= 5 then
        markerAssignmentMessageRates[senderKey] = { windowStart = now, count = 1 }
        return false
    end

    rate.count = rate.count + 1
    return rate.count > 20
end

local function IsValidMarkerAssignmentSessionID(value)
    if type(value) ~= "string" or #value > 40 then
        return false
    end
    local serverTime, preciseTime = value:match("^(%d+)%-(%d+)$")
    return serverTime ~= nil and #serverTime <= 15 and #preciseTime <= 15
end

local function IsNewerMarkerAssignmentSession(candidate, current)
    local candidateServer, candidateTime = candidate:match("^(%d+)%-(%d+)$")
    local currentServer, currentTime = current:match("^(%d+)%-(%d+)$")
    candidateServer = tonumber(candidateServer)
    candidateTime = tonumber(candidateTime)
    currentServer = tonumber(currentServer)
    currentTime = tonumber(currentTime)
    if not candidateServer or not candidateTime or not currentServer or not currentTime then
        return false
    end
    return candidateServer > currentServer
        or (candidateServer == currentServer and candidateTime > currentTime)
end

local function HandleMarkerAssignmentStatus(fields, senderKey)
    if #fields ~= 8 or not IsValidMarkerAssignmentSessionID(fields[3]) then
        return
    end

    local sequence = ParseMarkerAssignmentInteger(fields[4], 1, 1000000000)
    local enabled = ParseMarkerAssignmentInteger(fields[5], 0, 1)
    local disabledMask = ParseMarkerAssignmentInteger(fields[6], 0, 255)
    local incumbent = ParseMarkerAssignmentInteger(fields[7], 0, 1)
    local currentMarker = ParseMarkerAssignmentInteger(fields[8], 0, MARKER_ASSIGNMENT_COUNT)
    if not sequence or enabled == nil or not disabledMask
        or incumbent == nil or currentMarker == nil then
        return
    end

    local sessionID = fields[3]
    if markerAssignmentRetiredSessions[senderKey] == sessionID then
        return
    end

    local latestSession = markerAssignmentLatestSessions[senderKey]
    if latestSession and latestSession ~= sessionID then
        if not IsNewerMarkerAssignmentSession(sessionID, latestSession) then
            return
        end
        markerAssignmentRetiredSessions[senderKey] = latestSession
        markerAssignmentLatestStatusSequences[senderKey .. "|" .. latestSession] = nil
        markerAssignmentLastPlanSequence[senderKey .. "|" .. latestSession] = nil
    end
    markerAssignmentLatestSessions[senderKey] = sessionID

    local statusKey = senderKey .. "|" .. sessionID
    local latestSequence = markerAssignmentLatestStatusSequences[statusKey] or 0
    if sequence <= latestSequence then
        return
    end
    markerAssignmentLatestStatusSequences[statusKey] = sequence

    markerAssignmentPeers[senderKey] = {
        sessionID = sessionID,
        sequence = sequence,
        enabled = enabled == 1,
        disabledMask = disabledMask,
        incumbent = incumbent == 1,
        currentMarker = currentMarker,
        lastSeen = GetTime and GetTime() or 0,
    }

    if markerAssignmentSettings.enabled then
        if InCombatLockdown and InCombatLockdown() then
            markerAssignmentPendingReconcile = true
            RefreshMarkerAssignmentUI()
        elseif not markerAssignmentDiscoveryCollecting then
            ScheduleMarkerAssignmentEvaluation(0.15)
        end
    end
end

local function ParseMarkerAssignmentVector(text)
    if type(text) ~= "string" or #text ~= #markerAssignmentRoster then
        return nil
    end

    local vector = {}
    for index = 1, #text do
        local marker = tonumber(text:sub(index, index))
        if not marker or marker < 0 or marker > MARKER_ASSIGNMENT_COUNT then
            return nil
        end
        vector[index] = marker
    end
    return vector
end

local function HandleMarkerAssignmentPlan(fields, senderKey)
    if #fields ~= 7 or not markerAssignmentSettings.enabled
        or senderKey == GetLocalMarkerAssignmentKey() then
        return
    end
    if InCombatLockdown and InCombatLockdown() then
        markerAssignmentPendingReconcile = true
        RefreshMarkerAssignmentUI()
        return
    end

    local planSequence = ParseMarkerAssignmentInteger(fields[4], 1, 1000000000)
    if not planSequence or fields[5] ~= markerAssignmentRosterSignature then
        return
    end

    local participants = BuildMarkerAssignmentParticipants()
    if senderKey ~= GetMarkerAssignmentLeaderKey(participants)
        or fields[6] ~= GetMarkerAssignmentConfigSignature() then
        RequestMarkerAssignmentReconcile()
        return
    end

    local leaderPeer = markerAssignmentPeers[senderKey]
    if not leaderPeer or leaderPeer.sessionID ~= fields[3] then
        return
    end
    local planKey = senderKey .. "|" .. fields[3]
    local lastSequence = markerAssignmentLastPlanSequence[planKey] or 0
    if planSequence <= lastSequence then
        return
    end

    local vector = ParseMarkerAssignmentVector(fields[7])
    local expectedVector = SolveMarkerAssignments(participants)
    if not vector or not MarkerAssignmentVectorsEqual(vector, expectedVector) then
        RequestMarkerAssignmentReconcile()
        return
    end

    markerAssignmentLastPlanSequence[planKey] = planSequence
    markerAssignmentCommunicationBlocked = false
    markerAssignmentDiscoveryGeneration = markerAssignmentDiscoveryGeneration + 1
    markerAssignmentDiscoveryPending = false
    ApplyMarkerAssignmentPlan(vector)
end

local function HandleMarkerAssignmentAddonMessage(prefix, message, channel, sender)
    if IsSecretValue and IsSecretValue(prefix) then
        return
    end
    if prefix ~= MARKER_ASSIGNMENT_PREFIX or not IsRegularMarkerAssignmentParty() then
        return
    end
    if IsSecretValue and (IsSecretValue(message)
        or IsSecretValue(channel) or IsSecretValue(sender)) then
        if markerAssignmentSettings.enabled then
            markerAssignmentPendingReconcile = true
            markerAssignmentCommunicationBlocked = true
            markerAssignmentDiscoveryPending = true
            ScheduleMarkerAssignmentRetry()
        end
        RefreshMarkerAssignmentUI()
        return
    end
    if channel ~= "PARTY" then
        return
    end
    if InCombatLockdown and InCombatLockdown() then
        markerAssignmentPendingReconcile = markerAssignmentSettings.enabled
        RefreshMarkerAssignmentUI()
        return
    end

    if not RebuildMarkerAssignmentRoster() then
        return
    end
    local senderKey = ResolveMarkerAssignmentSender(sender)
    if not senderKey or IsMarkerAssignmentSenderRateLimited(senderKey) then
        return
    end

    local fields = SplitMarkerAssignmentMessage(message)
    if not fields or fields[1] ~= MARKER_ASSIGNMENT_PROTOCOL_VERSION then
        return
    end

    if fields[2] == "Q" then
        if #fields == 4 and IsValidMarkerAssignmentSessionID(fields[3])
            and ParseMarkerAssignmentInteger(fields[4], 1, 1000000000) then
            SendMarkerAssignmentState()
        end
    elseif fields[2] == "S" then
        HandleMarkerAssignmentStatus(fields, senderKey)
    elseif fields[2] == "P" then
        HandleMarkerAssignmentPlan(fields, senderKey)
    end
end

local function SetMarkerAssignmentEnabled(enabled)
    enabled = not not enabled
    if markerAssignmentSettings.enabled == enabled then
        RefreshMarkerAssignmentUI()
        return
    end

    markerAssignmentSettings.enabled = enabled
    markerAssignmentIncumbent = false

    if enabled then
        if not IsSoloMarkerAssignmentContext() then
            ApplyMarkerAssignmentMacro(markerAssignmentSettings.assignedMarker)
        end
        RequestMarkerAssignmentReconcile()
    else
        markerAssignmentMacroRefreshGeneration = markerAssignmentMacroRefreshGeneration + 1
        markerAssignmentPendingMacroUpdate = false
        markerAssignmentMacroError = nil
        if IsRegularMarkerAssignmentParty() then
            SendMarkerAssignmentState()
        end
        markerAssignmentDiscoveryGeneration = markerAssignmentDiscoveryGeneration + 1
        markerAssignmentDiscoveryPending = false
        markerAssignmentDiscoveryCollecting = false
        markerAssignmentPendingReconcile = false
        RefreshMarkerAssignmentUI()
    end
end

local function SetMarkerAssignmentChatChannelMode(mode)
    mode = NormalizeMarkerAssignmentChatChannelMode(mode)
    if markerAssignmentSettings.chatChannelMode == mode then
        RefreshMarkerAssignmentUI()
        return
    end

    markerAssignmentSettings.chatChannelMode = mode
    if markerAssignmentSettings.enabled then
        ApplyMarkerAssignmentMacro(markerAssignmentSettings.assignedMarker)
    end
    RefreshMarkerAssignmentUI()
end

local function SetMarkerAssignmentAllowInRaid(enabled)
    enabled = not not enabled
    if markerAssignmentSettings.allowInRaid == enabled then
        RefreshMarkerAssignmentUI()
        return
    end

    markerAssignmentSettings.allowInRaid = enabled
    if markerAssignmentSettings.enabled then
        ApplyMarkerAssignmentMacro(markerAssignmentSettings.assignedMarker)
    end
    RefreshMarkerAssignmentUI()
end

local function ToggleMarkerAssignmentDisabled(marker)
    if not NormalizeMarkerAssignmentID(marker) then
        return
    end

    if markerAssignmentSettings.disabledMarkers[marker] then
        markerAssignmentSettings.disabledMarkers[marker] = nil
    else
        markerAssignmentSettings.disabledMarkers[marker] = true
    end
    if markerAssignmentSettings.enabled and not IsSoloMarkerAssignmentContext() then
        ApplyMarkerAssignmentMacro(markerAssignmentSettings.assignedMarker)
    end
    RefreshMarkerAssignmentUI()
    RequestMarkerAssignmentReconcile()
end

local function GetMarkerAssignmentChatChannelLabel()
    if markerAssignmentSettings.chatChannelMode == MARKER_ASSIGNMENT_CHAT_INSTANCE then
        return "副本"
    end
    return "小队 / 团队（自动）"
end

local function GetMarkerAssignmentIconMarkup(marker, size)
    if not marker then
        return "无"
    end
    size = size or 18
    return string.format("|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_%d:%d:%d:0:0|t",
        marker, size, size)
end

RefreshMarkerAssignmentUI = function()
    if not markerAssignmentSettings then
        return
    end

    if markerAssignmentControls then
        markerAssignmentControls.enabledCheckButton:SetChecked(markerAssignmentSettings.enabled)
        markerAssignmentControls.allowInRaidCheckButton:SetChecked(
            markerAssignmentSettings.allowInRaid)
        local channelText = GetMarkerAssignmentChatChannelLabel()
        if markerAssignmentControls.chatChannelDropdown.OverrideText then
            markerAssignmentControls.chatChannelDropdown:OverrideText(channelText)
        else
            markerAssignmentControls.chatChannelDropdown:SetDefaultText(channelText)
        end

        for marker, button in ipairs(markerAssignmentControls.markerButtons) do
            local disabled = markerAssignmentSettings.disabledMarkers[marker] == true
            local assigned = markerAssignmentSettings.assignedMarker == marker
            button.disabledOverlay:SetShown(disabled)
            button.assignedOverlay:SetShown(assigned and not disabled)
            button.assignedBorder:SetShown(assigned)
        end
    end

    if markerAssignmentCurrentText then
        markerAssignmentCurrentText:SetText("当前分配："
            .. GetMarkerAssignmentIconMarkup(markerAssignmentSettings.assignedMarker, 20))
    end

    if not markerAssignmentStatusText then
        return
    end

    local isRegularParty = IsRegularMarkerAssignmentParty()
    local isSolo = IsSoloMarkerAssignmentContext()
    local inCombat = InCombatLockdown and InCombatLockdown()
    if markerAssignmentMacroError then
        markerAssignmentStatusText:SetTextColor(1, 0.25, 0.25)
        markerAssignmentStatusText:SetText(markerAssignmentMacroError)
    elseif markerAssignmentCommunicationError and markerAssignmentSettings.enabled
        and isRegularParty then
        markerAssignmentStatusText:SetTextColor(1, 0.25, 0.25)
        markerAssignmentStatusText:SetText(markerAssignmentCommunicationError)
    elseif markerAssignmentCommunicationBlocked and markerAssignmentSettings.enabled
        and isRegularParty then
        markerAssignmentStatusText:SetTextColor(1, 0.78, 0.2)
        markerAssignmentStatusText:SetText("插件通信暂时受限；解除限制后将重新同步。")
    elseif not markerAssignmentSettings.enabled then
        markerAssignmentStatusText:SetTextColor(0.65, 0.67, 0.72)
        markerAssignmentStatusText:SetText("功能已关闭；保留 RRC-TM 的最后内容。")
    elseif inCombat and (markerAssignmentPendingReconcile
        or markerAssignmentPendingMacroUpdate) then
        markerAssignmentStatusText:SetTextColor(1, 0.78, 0.2)
        markerAssignmentStatusText:SetText("战斗中，脱战后重新分配并更新宏。")
    elseif isSolo then
        if GetLocalMarkerAssignmentDisabledMask() == 255 then
            markerAssignmentStatusText:SetTextColor(0.75, 0.75, 0.75)
            markerAssignmentStatusText:SetText("单人模式：全部标记均已禁用，RRC-TM 不会添加标记。")
        else
            markerAssignmentStatusText:SetTextColor(0.35, 0.9, 0.45)
            markerAssignmentStatusText:SetText("单人标记已就绪；无需进行小队协调。")
        end
    elseif not isRegularParty then
        markerAssignmentStatusText:SetTextColor(0.65, 0.67, 0.72)
        markerAssignmentStatusText:SetText("当前队伍类型不进行标记协调。")
    elseif markerAssignmentPendingReconcile then
        markerAssignmentStatusText:SetTextColor(1, 0.78, 0.2)
        markerAssignmentStatusText:SetText("等待重新分配并更新宏。")
    elseif markerAssignmentDiscoveryPending then
        markerAssignmentStatusText:SetTextColor(1, 0.78, 0.2)
        markerAssignmentStatusText:SetText("正在同步小队标记分配…")
    elseif GetLocalMarkerAssignmentDisabledMask() == 255 then
        markerAssignmentStatusText:SetTextColor(0.75, 0.75, 0.75)
        markerAssignmentStatusText:SetText("全部标记均已禁用；RRC-TM 不会添加标记。")
    else
        markerAssignmentStatusText:SetTextColor(0.35, 0.9, 0.45)
        markerAssignmentStatusText:SetText("分配已同步；RRC-TM 已使用当前标记。")
    end
end

local function ScheduleMarkerAssignmentRosterRefresh()
    markerAssignmentDiscoveryGeneration = markerAssignmentDiscoveryGeneration + 1
    markerAssignmentDiscoveryCollecting = false
    markerAssignmentRosterGeneration = markerAssignmentRosterGeneration + 1
    local generation = markerAssignmentRosterGeneration
    C_Timer.After(MARKER_ASSIGNMENT_ROSTER_DELAY, function()
        if generation ~= markerAssignmentRosterGeneration then
            return
        end

        local isRegularParty = IsRegularMarkerAssignmentParty()
        local isSolo = IsSoloMarkerAssignmentContext()
        RebuildMarkerAssignmentRoster()

        if markerAssignmentSettings.enabled and not isSolo
            and markerAssignmentSettings.chatChannelMode
                == MARKER_ASSIGNMENT_CHAT_PARTY_RAID then
            ApplyMarkerAssignmentMacro(markerAssignmentSettings.assignedMarker)
        end

        if isRegularParty then
            if markerAssignmentSettings.enabled then
                RequestMarkerAssignmentReconcile()
            else
                SendMarkerAssignmentState()
                RefreshMarkerAssignmentUI()
            end
        else
            markerAssignmentDiscoveryGeneration = markerAssignmentDiscoveryGeneration + 1
            markerAssignmentCommunicationBlocked = false
            markerAssignmentDiscoveryPending = false
            markerAssignmentDiscoveryCollecting = false
            if markerAssignmentSettings.enabled and isSolo then
                ApplySoloMarkerAssignment()
            else
                markerAssignmentPendingReconcile = false
                RefreshMarkerAssignmentUI()
            end
        end
    end)
end

local function InitializeMarkerAssignment()
    local serverTime = type(GetServerTime) == "function" and GetServerTime() or time()
    local preciseTime = type(GetTime) == "function" and math.floor(GetTime() * 1000) or 0
    markerAssignmentSessionID = tostring(serverTime) .. "-" .. tostring(preciseTime)

    if C_ChatInfo and type(C_ChatInfo.RegisterAddonMessagePrefix) == "function" then
        local succeeded, registered = pcall(C_ChatInfo.RegisterAddonMessagePrefix,
            MARKER_ASSIGNMENT_PREFIX)
        markerAssignmentPrefixRegistered = succeeded and (registered == true
            or registered == 0 or registered == 1)
    end
    if not markerAssignmentPrefixRegistered then
        markerAssignmentCommunicationError = "无法注册 RRC 标记通信；本次登录无法协调分配。"
    end

    markerAssignmentEventFrame:RegisterEvent("CHAT_MSG_ADDON")
    markerAssignmentEventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
    markerAssignmentEventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    markerAssignmentEventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
    markerAssignmentEventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    markerAssignmentEventFrame:RegisterEvent("UPDATE_MACROS")

    markerAssignmentIncumbent = false
    RebuildMarkerAssignmentRoster()
    UpdateLocalMarkerAssignmentPeer()
    if markerAssignmentSettings.enabled then
        if not IsSoloMarkerAssignmentContext() then
            ApplyMarkerAssignmentMacro(markerAssignmentSettings.assignedMarker)
        end
        RequestMarkerAssignmentReconcile()
    else
        RefreshMarkerAssignmentUI()
    end
end

markerAssignmentEventFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "CHAT_MSG_ADDON" then
        HandleMarkerAssignmentAddonMessage(...)
    elseif event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_ENTERING_WORLD" then
        ScheduleMarkerAssignmentRosterRefresh()
    elseif event == "PLAYER_REGEN_DISABLED" then
        RefreshMarkerAssignmentUI()
    elseif event == "UPDATE_MACROS" then
        if markerAssignmentSettings.enabled then
            ScheduleMarkerAssignmentMacroRefresh()
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        local isRegularParty = IsRegularMarkerAssignmentParty()
        local isSolo = IsSoloMarkerAssignmentContext()
        if markerAssignmentSettings.enabled and markerAssignmentPendingReconcile
            and (isRegularParty or isSolo) then
            RequestMarkerAssignmentReconcile()
        elseif markerAssignmentSettings.enabled and isRegularParty
            and markerAssignmentPendingStateBroadcast then
            RequestMarkerAssignmentReconcile()
        else
            if markerAssignmentPendingMacroUpdate and markerAssignmentSettings.enabled then
                ApplyMarkerAssignmentMacro(markerAssignmentSettings.assignedMarker)
            end
            if markerAssignmentPendingStateBroadcast and isRegularParty then
                SendMarkerAssignmentState()
            end
            markerAssignmentPendingReconcile = false
            RefreshMarkerAssignmentUI()
        end
    end
end)

local function InitializeMarkerAssignmentSettings(db)
    if type(db.markerAssignment) ~= "table"
        or (IsSecretTable and IsSecretTable(db.markerAssignment)) then
        db.markerAssignment = {}
    end

    local markerSettings = db.markerAssignment
    if type(markerSettings.enabled) ~= "boolean" then
        markerSettings.enabled = false
    end
    markerSettings.disabledMarkers = NormalizeDisabledMarkers(markerSettings.disabledMarkers)
    markerSettings.assignedMarker = NormalizeMarkerAssignmentID(markerSettings.assignedMarker)
    markerSettings.chatChannelMode = NormalizeMarkerAssignmentChatChannelMode(
        markerSettings.chatChannelMode)
    if type(markerSettings.allowInRaid) ~= "boolean" then
        markerSettings.allowInRaid = false
    end
    markerAssignmentSettings = markerSettings
end

ns.MarkerAssignment = {
    COUNT = MARKER_ASSIGNMENT_COUNT,
    CHAT_PARTY_RAID = MARKER_ASSIGNMENT_CHAT_PARTY_RAID,
    CHAT_INSTANCE = MARKER_ASSIGNMENT_CHAT_INSTANCE,
    InitializeSettings = InitializeMarkerAssignmentSettings,
    GetSettings = function()
        return markerAssignmentSettings
    end,
    SetControls = function(controls, currentText, statusText)
        markerAssignmentControls = controls
        markerAssignmentCurrentText = currentText
        markerAssignmentStatusText = statusText
        RefreshMarkerAssignmentUI()
    end,
    SetEnabled = SetMarkerAssignmentEnabled,
    SetChatChannelMode = SetMarkerAssignmentChatChannelMode,
    SetAllowInRaid = SetMarkerAssignmentAllowInRaid,
    ToggleDisabled = ToggleMarkerAssignmentDisabled,
    RefreshUI = RefreshMarkerAssignmentUI,
    Initialize = InitializeMarkerAssignment,
}
