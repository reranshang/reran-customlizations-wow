local _, ns = ...

local interfaceVersion = select(4, GetBuildInfo())
ns.IsForever = (WOW_PROJECT_CAMELOT ~= nil and WOW_PROJECT_ID == WOW_PROJECT_CAMELOT)
    or (interfaceVersion >= 16000 and interfaceVersion < 20000)

ns.IsSecretValue = _G.issecretvalue
ns.IsSecretTable = _G.issecrettable

function ns.CreateSolidTexture(parent, layer, red, green, blue, alpha)
    local texture = parent:CreateTexture(nil, layer)
    texture:SetColorTexture(red, green, blue, alpha)
    return texture
end

function ns.AddBorder(frame, size, red, green, blue, alpha)
    local top = ns.CreateSolidTexture(frame, "BORDER", red, green, blue, alpha)
    top:SetPoint("TOPLEFT")
    top:SetPoint("TOPRIGHT")
    top:SetHeight(size)

    local bottom = ns.CreateSolidTexture(frame, "BORDER", red, green, blue, alpha)
    bottom:SetPoint("BOTTOMLEFT")
    bottom:SetPoint("BOTTOMRIGHT")
    bottom:SetHeight(size)

    local left = ns.CreateSolidTexture(frame, "BORDER", red, green, blue, alpha)
    left:SetPoint("TOPLEFT")
    left:SetPoint("BOTTOMLEFT")
    left:SetWidth(size)

    local right = ns.CreateSolidTexture(frame, "BORDER", red, green, blue, alpha)
    right:SetPoint("TOPRIGHT")
    right:SetPoint("BOTTOMRIGHT")
    right:SetWidth(size)
end

function ns.ClearTable(tableToClear)
    for key in pairs(tableToClear) do
        tableToClear[key] = nil
    end
end

function ns.Clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

function ns.NormalizeColor(color, defaultColor)
    if type(color) ~= "table" then
        color = {}
    end

    local red = tonumber(color.r)
    local green = tonumber(color.g)
    local blue = tonumber(color.b)

    if not red or red ~= red then red = defaultColor.r end
    if not green or green ~= green then green = defaultColor.g end
    if not blue or blue ~= blue then blue = defaultColor.b end

    return {
        r = ns.Clamp(red, 0, 1),
        g = ns.Clamp(green, 0, 1),
        b = ns.Clamp(blue, 0, 1),
    }
end

function ns.NormalizeCoordinate(value, defaultValue)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge then
        return defaultValue
    end

    if value >= 0 then
        return math.floor(value + 0.5)
    end
    return math.ceil(value - 0.5)
end

function ns.NormalizeInteger(value, defaultValue, minimum, maximum)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge then
        return defaultValue
    end

    value = value >= 0 and math.floor(value + 0.5) or math.ceil(value - 0.5)
    return ns.Clamp(value, minimum, maximum)
end

local sharedMedia

function ns.GetSharedMedia()
    if sharedMedia then
        return sharedMedia
    end
    if not _G.LibStub then
        return nil
    end

    local succeeded, media = pcall(function()
        return _G.LibStub("LibSharedMedia-3.0", true)
    end)
    if succeeded then
        sharedMedia = media
    end

    return sharedMedia
end

function ns.IsValidSharedMedia(media, mediaType, mediaKey)
    if not media or type(mediaKey) ~= "string" then
        return false
    end

    local succeeded, isValid = pcall(media.IsValid, media, mediaType, mediaKey)
    return succeeded and isValid == true
end

function ns.FetchSharedMedia(media, mediaType, mediaKey)
    if not ns.IsValidSharedMedia(media, mediaType, mediaKey) then
        return nil
    end

    local succeeded, mediaTable = pcall(media.HashTable, media, mediaType)
    if succeeded and type(mediaTable) == "table" then
        local value = mediaTable[mediaKey]
        if type(value) == "string" or type(value) == "number" then
            return value
        end
    end

    return nil
end

function ns.SafeUnitBoolean(api, ...)
    if type(api) ~= "function" then
        return nil
    end

    local succeeded, result = pcall(api, ...)
    if not succeeded or (ns.IsSecretValue and ns.IsSecretValue(result)) then
        return nil
    end
    if result == nil or result == false or result == 0 then
        return false
    end
    return true
end

function ns.SafeUnitNumber(api, ...)
    if type(api) ~= "function" then
        return nil
    end

    local succeeded, result = pcall(api, ...)
    if not succeeded or (ns.IsSecretValue and ns.IsSecretValue(result))
        or type(result) ~= "number" or result ~= result
        or result == math.huge or result == -math.huge then
        return nil
    end
    return result
end
