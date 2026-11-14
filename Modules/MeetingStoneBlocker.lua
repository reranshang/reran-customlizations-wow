local _, ns = ...

-- forever 不加载集合石屏蔽功能。
if ns.IsForever then return end

local CreateSolidTexture = ns.CreateSolidTexture
local AddBorder = ns.AddBorder
local IsSecretValue = ns.IsSecretValue

local MAX_IMPORT_ID = 100
local MAX_PAGES = 4
local FONT_SIZES = { 16, 14 } -- Physical pixels, independent of UI scale.
local OUTPUT_FRAME_NAME = "ReRansCustomlizationsMeetingStoneOutputFrame"
local IMPORT_FRAME_NAME = "ReRansCustomlizationsMeetingStoneImportFrame"
local IMPORT_PREFIX = "RRC1"

local settings
local outputFrame
local importFrame
local statusText = "尚未读取集合石列表"
local statusChanged
local lastBatchSecond
local batchSequence = 0

local function SetStatus(text)
    statusText = text
    if statusChanged then
        statusChanged(text)
    end
end

local function IsReadableString(value)
    return type(value) == "string"
        and not (IsSecretValue and IsSecretValue(value))
end

local function GetMeetingStoneModules()
    if not _G.LibStub then
        return nil, nil, "未检测到 MeetingStone"
    end

    local aceAddon = _G.LibStub("AceAddon-3.0", true)
    if not aceAddon then
        return nil, nil, "未检测到 MeetingStone"
    end

    local addon = aceAddon:GetAddon("MeetingStone", true)
    if not addon then
        return nil, nil, "请先加载 MeetingStone"
    end

    local browsePanel = addon:GetModule("BrowsePanel", true)
    local lfgService = addon:GetModule("LfgService", true)
    if not browsePanel or not lfgService then
        return nil, nil, "MeetingStone 尚未完成初始化"
    end

    return browsePanel, lfgService
end

local function GetDisplayText(value)
    -- Kstrings such as |Kt66|k are ordinary Lua strings (not secret values).
    -- Preserve the token so FontString can render it; only flatten real line breaks.
    if type(value) == "nil" then return "-" end
    if not IsReadableString(value) then
        error("标题或说明受保护，无法保证完整输出")
    end
    if value == "" then return "-" end

    local succeeded, text = pcall(function()
        return value:gsub("[\r\n]+", "·")
    end)
    if not succeeded then error("标题或说明无法完整读取") end
    return text
end

local function CreateBatchID()
    local now = time()
    if now == lastBatchSecond then
        batchSequence = (batchSequence + 1) % 100
    else
        lastBatchSecond = now
        batchSequence = 0
    end
    return string.format("%010d%02d", now, batchSequence)
end

-- Never compare or do arithmetic with a secret/failed measurement. In particular,
-- kstrings stay opaque: only the game's FontString renderer measures their text.
local function IsLayoutNumber(value, allowZero)
    local ok, valid = pcall(function()
        local isSecret = _G.issecretvalue or IsSecretValue
        if isSecret and isSecret(value) then
            return false
        end
        return type(value) == "number" and value == value and value < math.huge
            and (value > 0 or (allowZero and value == 0))
    end)
    return ok and valid
end

local function GetOutputGeometry()
    local ok, width, height, scale = pcall(function()
        return UIParent:GetWidth(), UIParent:GetHeight(), UIParent:GetEffectiveScale()
    end)
    if not ok or not IsLayoutNumber(width) or not IsLayoutNumber(height)
        or not IsLayoutNumber(scale) then
        return nil, "无法安全读取屏幕尺寸或 UI 缩放"
    end
    local geometry = {
        scale = scale,
        width = width - 16 / scale,
        height = height - 16 / scale,
        padding = 12 / scale,
        gutter = 24 / scale,
        borderWidth = 2 / scale,
        textInset = 6 / scale,
        fieldPadding = 4 / scale, -- Includes the 2px boundary; glyphs never touch it.
        labelGap = 4 / scale,
        rowGap = 4 / scale,
        headerBottom = math.ceil(math.max(40, 40 * scale)) / scale,
        footerHeight = math.ceil(math.max(42, 42 * scale)) / scale,
    }
    if not IsLayoutNumber(geometry.width) or not IsLayoutNumber(geometry.height) then
        return nil, "屏幕可用区域不足"
    end
    return geometry
end

-- Pure, ordered next-fit packing. A title and comment always move together.
-- Empty columns are retained, including on the last page (OCR partition anchors).
local function PackRows(rows, columnCount, columnHeight, rowGap, maxPages)
    if not IsLayoutNumber(columnCount) or columnCount % 1 ~= 0 or columnCount > 4
        or not IsLayoutNumber(columnHeight) or not IsLayoutNumber(rowGap, true)
        or not IsLayoutNumber(maxPages) or maxPages % 1 ~= 0 or maxPages > MAX_PAGES then
        return nil, "无效布局尺寸"
    end
    local pages = {}
    local function NewPage()
        local page = {}
        for column = 1, columnCount do
            page[column] = { rows = {}, usedHeight = 0 }
        end
        pages[#pages + 1] = page
        return page
    end
    local page = NewPage()
    local column = 1
    for index, row in ipairs(rows) do
        if not IsLayoutNumber(row.height) then
            return nil, string.format("编号 %03d 的文字高度无法安全测量", index)
        end
        if row.height > columnHeight then
            return nil, string.format("编号 %03d 的标题/说明过长，整支队伍无法放入一列", index)
        end
        local target = page[column]
        local gap = #target.rows > 0 and rowGap or 0
        if target.usedHeight + gap + row.height > columnHeight then
            column = column + 1
            if column > columnCount then
                if #pages >= maxPages then
                    return nil, "完整内容超过 4 页容量"
                end
                page = NewPage()
                column = 1
            end
            target = page[column]
            gap = 0
        end
        target.rows[#target.rows + 1] = { index = index, y = target.usedHeight + gap }
        target.usedHeight = target.usedHeight + gap + row.height
    end
    return pages
end

-- Pure selection over already measured candidates: one page first, then fewest
-- pages, then the more readable font, then fewer columns. Never shrink below 14px.
local function ChooseLayout(candidates)
    local best, failure
    for _, candidate in ipairs(candidates) do
        local pages, reason = PackRows(candidate.rows, candidate.columnCount,
            candidate.bodyHeight, candidate.rowGap, MAX_PAGES)
        if pages then
            if not best or #pages < #best.pages
                or (#pages == #best.pages and candidate.fontPixels > best.metrics.fontPixels)
                or (#pages == #best.pages and candidate.fontPixels == best.metrics.fontPixels
                    and candidate.columnCount < best.metrics.columnCount) then
                best = { metrics = candidate, pages = pages }
            end
        else
            failure = failure or reason
        end
    end
    return best, failure or "屏幕太窄，无法完整显示协议标记"
end

local function ConfigureOutputText(fontString, fontPath, fontSize, width, wrap)
    if not fontString:SetFont(fontPath, fontSize, "") then
        error("无法载入游戏字体")
    end
    fontString:SetWidth(width)
    fontString:SetHeight(0) -- Automatic height while measuring, never a fixed line cap.
    fontString:SetSpacing(0)
    fontString:SetWordWrap(wrap)
    fontString:SetNonSpaceWrap(wrap)
    fontString:SetJustifyH("LEFT")
    fontString:SetJustifyV("TOP")
end

local function ReadTextSize(fontString, width, scale)
    local height = fontString:GetStringHeight()
    local wrappedWidth = fontString:GetWrappedWidth()
    local truncated = fontString:IsTruncated()
    local isSecret = _G.issecretvalue or IsSecretValue
    if not IsLayoutNumber(height) or not IsLayoutNumber(wrappedWidth, true)
        or (isSecret and isSecret(truncated)) or type(truncated) ~= "boolean" then
        error("文字尺寸受保护或不可用，不能保证完整输出")
    end
    if truncated or wrappedWidth > width + 0.01 / scale then
        error("单字段无法完整显示（文字或协议标记超出列宽）")
    end
    -- Round up to physical pixels, with one extra pixel for glyph descenders.
    return (math.ceil(height * scale) + 1) / scale
end

local function MeasureText(fontString, fontPath, fontSize, width, scale, text, wrap)
    local ok, height = pcall(function()
        ConfigureOutputText(fontString, fontPath, fontSize, width, wrap)
        fontString:SetText(text)
        return ReadTextSize(fontString, width, scale)
    end)
    if not ok then
        return nil, IsReadableString(height) and height or "文字测量失败"
    end
    return height
end

local function BatchHeader(batch, page, pageCount, count, columns)
    return string.format("RRC3BATCH%sPAGE%dOF%dCOUNT%03dCOLS%d", batch, page, pageCount, count, columns)
end

local function ColumnLabel(side, column)
    return string.format("RRC3%s%d", side, column)
end

local function FieldMarker(side, index, kind)
    return string.format("%s%03d%s", side, index, kind == "title" and "T" or "C")
end

local function BuildOutputLayout(frame, entries, batch, geometry)
    local ok, fontPath = pcall(function() return GameFontNormal:GetFont() end)
    if not ok or not IsReadableString(fontPath) or fontPath == "" then
        return nil, "无法读取游戏中文字体路径"
    end
    local candidates, measurementError = {}, nil
    for _, fontPixels in ipairs(FONT_SIZES) do
        local fontSize = fontPixels / geometry.scale
        for columnCount = 1, 4 do
            -- Pixel-aligned outer edges, not FontString bounding boxes, define OCR geometry.
            local columnWidth = math.floor((geometry.width - 2 * geometry.padding
                - (columnCount - 1) * geometry.gutter) * geometry.scale / columnCount) / geometry.scale
            local markerWidth = columnWidth * 0.2 - 2 * geometry.textInset
            local bodyWidth = columnWidth * 0.6 - 2 * geometry.textInset
            local labelWidth = columnWidth / 2 - 2 * geometry.textInset
            local candidateOK, candidate = pcall(function()
                if not IsLayoutNumber(markerWidth) or not IsLayoutNumber(bodyWidth)
                    or not IsLayoutNumber(labelWidth) then error("屏幕太窄，无法完整显示协议标记") end
                local function Measure(text, width, wrap)
                    local height, reason = MeasureText(frame.measurer, fontPath, fontSize,
                        width, geometry.scale, text, wrap)
                    if not height then error(reason) end
                    return height
                end
                local batchHeight = Measure(BatchHeader(batch, MAX_PAGES, MAX_PAGES, #entries, columnCount),
                    geometry.width - 2 * geometry.padding, false)
                local labelHeight = 0
                for column = 1, columnCount do
                    for _, side in ipairs({ "L", "R", "Z" }) do
                        labelHeight = math.max(labelHeight, Measure(ColumnLabel(side, column), labelWidth, false))
                    end
                end
                local columnTop = geometry.headerBottom + batchHeight + 8 / geometry.scale
                local bodyTop = columnTop + labelHeight + geometry.labelGap
                local bodyHeight = math.floor((geometry.height - bodyTop - geometry.footerHeight
                    - geometry.labelGap - labelHeight) * geometry.scale) / geometry.scale
                local measured = {
                    fontPath = fontPath, fontPixels = fontPixels, fontSize = fontSize,
                    columnCount = columnCount, columnWidth = columnWidth,
                    markerWidth = markerWidth, bodyWidth = bodyWidth, labelWidth = labelWidth,
                    columnTop = columnTop, columnHeight = labelHeight,
                    batchHeight = batchHeight, bodyTop = bodyTop, bodyHeight = bodyHeight,
                    rowGap = geometry.rowGap, rows = {},
                }
                for index, entry in ipairs(entries) do
                    local row = {}
                    for _, kind in ipairs({ "title", "comment" }) do
                        -- Body and metadata are never concatenated. Opaque kstrings stay intact.
                        row[kind] = entry[kind]
                        local height = Measure(entry[kind], bodyWidth, true)
                        local markerHeight = math.max(Measure(FieldMarker("S", index, kind), markerWidth, false),
                            Measure(FieldMarker("E", index, kind), markerWidth, false))
                        row[kind .. "Height"] = height
                        row[kind .. "MarkerHeight"] = markerHeight
                        row[kind .. "FieldHeight"] = math.max(height, markerHeight) + 2 * geometry.fieldPadding
                    end
                    row.height = row.titleFieldHeight + row.commentFieldHeight
                    measured.rows[index] = row
                end
                return measured
            end)
            if candidateOK then
                candidates[#candidates + 1] = candidate
            else
                measurementError = measurementError or (IsReadableString(candidate) and candidate or "文字测量失败")
            end
        end
    end
    local layout, reason = ChooseLayout(candidates)
    if not layout then
        return nil, #candidates > 0 and reason or measurementError or reason
    end
    layout.geometry = geometry
    layout.batch = batch
    layout.count = #entries
    return layout
end

local function CreateWindow(name, width, height, titleText)
    local frame = CreateFrame("Frame", name, UIParent)
    frame:SetFrameStrata("FULLSCREEN_DIALOG")
    frame:SetToplevel(true)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:SetSize(width, height)
    frame:SetPoint("CENTER")
    frame:Hide()

    local background = CreateSolidTexture(frame, "BACKGROUND", 0.025, 0.025, 0.025, 1)
    background:SetAllPoints()
    AddBorder(frame, 1, 0.62, 0.64, 0.70, 1)

    local header = CreateFrame("Frame", nil, frame)
    header:SetPoint("TOPLEFT", 1, -1)
    header:SetPoint("TOPRIGHT", -1, -1)
    header:SetHeight(36)
    header:EnableMouse(true)
    header:RegisterForDrag("LeftButton")
    header:SetScript("OnDragStart", function()
        frame:StartMoving()
    end)
    header:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
    end)

    local headerBackground = CreateSolidTexture(header, "BACKGROUND", 0.08, 0.09, 0.11, 1)
    headerBackground:SetAllPoints()

    local title = header:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("LEFT", 12, 0)
    title:SetText(titleText)
    frame.title = title

    local closeButton = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    closeButton:SetPoint("TOPRIGHT", -3, -3)
    closeButton:SetScript("OnClick", function()
        frame:Hide()
    end)

    table.insert(UISpecialFrames, name)
    return frame
end

local function RenderText(fontString, metrics, geometry, text, height, width, wrap)
    ConfigureOutputText(fontString, metrics.fontPath, metrics.fontSize, width, wrap)
    fontString:SetText(text)
    fontString:SetHeight(height)
    if ReadTextSize(fontString, width, geometry.scale) > height + 0.01 / geometry.scale then
        error("文字实际高度改变，无法保证完整输出；请重新读取列表")
    end
end

-- Reuse textures across page turns and captures; no per-refresh texture leak.
local function DrawTableLine(frame, x, y, width, height)
    frame.lineCount = frame.lineCount + 1
    local line = frame.lines[frame.lineCount]
    if not line then
        line = CreateSolidTexture(frame, "ARTWORK", 0, 1, 1, 1)
        frame.lines[frame.lineCount] = line
    end
    line:ClearAllPoints()
    line:SetPoint("TOPLEFT", frame, "TOPLEFT", x, -y)
    line:SetSize(width, height)
    line:Show()
end

local function RenderField(row, kind, index, text, metrics, geometry, offset)
    local y = -(offset + geometry.fieldPadding)
    local body, left, right = row[kind], row[kind .. "Start"], row[kind .. "End"]
    body:ClearAllPoints()
    body:SetPoint("TOPLEFT", row, "TOPLEFT", metrics.columnWidth * 0.2 + geometry.textInset, y)
    RenderText(body, metrics, geometry, text[kind], text[kind .. "Height"], metrics.bodyWidth, true)
    left:ClearAllPoints()
    left:SetPoint("TOPLEFT", row, "TOPLEFT", geometry.textInset, y)
    right:ClearAllPoints()
    right:SetPoint("TOPLEFT", row, "TOPLEFT", metrics.columnWidth * 0.8 + geometry.textInset, y)
    RenderText(left, metrics, geometry, FieldMarker("S", index, kind),
        text[kind .. "MarkerHeight"], metrics.markerWidth, false)
    RenderText(right, metrics, geometry, FieldMarker("E", index, kind),
        text[kind .. "MarkerHeight"], metrics.markerWidth, false)
end

local function UpdateOutputPage(frame)
    local ok, reason = pcall(function()
        local layout = frame.layout
        local metrics, geometry = layout.metrics, layout.geometry
        RenderText(frame.batchLabel, metrics, geometry,
            BatchHeader(layout.batch, frame.pageNumber, frame.pageCount, layout.count, metrics.columnCount),
            metrics.batchHeight, geometry.width - 2 * geometry.padding, false)
        frame.batchLabel:ClearAllPoints()
        frame.batchLabel:SetPoint("TOP", 0, -geometry.headerBottom)
        frame.batchLabel:SetJustifyH("CENTER")

        for _, row in ipairs(frame.rows) do row:Hide() end
        for _, labels in ipairs(frame.columnLabels) do
            for _, label in pairs(labels) do label:Hide() end
        end
        for _, line in ipairs(frame.lines) do line:Hide() end
        frame.lineCount = 0
        local rowIndex = 0
        for column, placements in ipairs(layout.pages[frame.pageNumber]) do
            local x = geometry.padding + (column - 1) * (metrics.columnWidth + geometry.gutter)
            local bottom = metrics.bodyTop + metrics.bodyHeight
            for _, side in ipairs({ "L", "R", "Z" }) do
                local label = frame.columnLabels[column][side]
                RenderText(label, metrics, geometry, ColumnLabel(side, column),
                    metrics.columnHeight, metrics.labelWidth, false)
                label:ClearAllPoints()
                local right = side == "R"
                label:SetPoint(right and "TOPRIGHT" or "TOPLEFT", frame, "TOPLEFT",
                    right and (x + metrics.columnWidth - geometry.textInset) or (x + geometry.textInset),
                    -(side == "Z" and (bottom + geometry.labelGap) or metrics.columnTop))
                label:SetJustifyH(right and "RIGHT" or "LEFT")
                label:Show()
            end
            -- Closed outer rectangle, including empty columns. All strokes lie inside it.
            local stroke = geometry.borderWidth
            DrawTableLine(frame, x, metrics.bodyTop, metrics.columnWidth, stroke)
            DrawTableLine(frame, x, bottom - stroke, metrics.columnWidth, stroke)
            DrawTableLine(frame, x, metrics.bodyTop, stroke, metrics.bodyHeight)
            DrawTableLine(frame, x + metrics.columnWidth - stroke, metrics.bodyTop, stroke, metrics.bodyHeight)
            for _, placement in ipairs(placements.rows) do
                rowIndex = rowIndex + 1
                local row = frame.rows[rowIndex]
                if not row then
                    row = CreateFrame("Frame", nil, frame)
                    for _, kind in ipairs({ "title", "comment" }) do
                        for _, suffix in ipairs({ "", "Start", "End" }) do
                            local label = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                            label:SetTextColor(1, 1, 1)
                            row[kind .. suffix] = label
                        end
                    end
                    frame.rows[rowIndex] = row
                end
                local text = metrics.rows[placement.index]
                local top = metrics.bodyTop + placement.y
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", frame, "TOPLEFT", x, -top)
                row:SetSize(metrics.columnWidth, text.height)
                -- One line per field start (first title shares the rectangle top).
                -- Team gaps belong to the preceding C field; no blank cells are drawn.
                if placement.y > 0 then DrawTableLine(frame, x, top, metrics.columnWidth, stroke) end
                DrawTableLine(frame, x, top + text.titleFieldHeight, metrics.columnWidth, stroke)
                RenderField(row, "title", placement.index, text, metrics, geometry, 0)
                RenderField(row, "comment", placement.index, text, metrics, geometry, text.titleFieldHeight)
                row:Show()
            end
        end
        frame.previousButton:SetEnabled(frame.pageNumber > 1)
        frame.nextButton:SetEnabled(frame.pageNumber < frame.pageCount)
        frame.pageLabel:SetText(string.format("第 %d / %d 页 · %d列 · %dpx",
            frame.pageNumber, frame.pageCount, metrics.columnCount, metrics.fontPixels))
    end)
    if not ok then
        frame:Hide()
        local message = "输出失败：" .. (IsReadableString(reason) and reason or "无法安全测量文字")
        SetStatus(message)
        return false, message
    end
    return true
end

local function CreateOutputFrame(geometry)
    local frame = CreateWindow(OUTPUT_FRAME_NAME, geometry.width, geometry.height, "集合石 OCR 输出")
    frame.rows = {}
    frame.lines = {}
    frame.columnLabels = {}
    for column = 1, 4 do
        frame.columnLabels[column] = {}
        for _, side in ipairs({ "L", "R", "Z" }) do
            local label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            label:SetTextColor(1, 0.82, 0.20)
            label:Hide()
            frame.columnLabels[column][side] = label
        end
    end
    frame.measurer = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    frame.measurer:Hide()
    frame.batchLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    frame.batchLabel:SetTextColor(1, 0.82, 0.20)

    local previousButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    previousButton:SetSize(90, 24)
    previousButton:SetPoint("BOTTOM", -110, 10)
    previousButton:SetText("上一页")
    previousButton:SetScript("OnClick", function()
        if frame.pageNumber > 1 then
            frame.pageNumber = frame.pageNumber - 1
            UpdateOutputPage(frame)
        end
    end)
    frame.previousButton = previousButton

    local pageLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    pageLabel:SetPoint("BOTTOM", 0, 17)
    frame.pageLabel = pageLabel

    local nextButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    nextButton:SetSize(90, 24)
    nextButton:SetPoint("BOTTOM", 110, 10)
    nextButton:SetText("下一页")
    nextButton:SetScript("OnClick", function()
        if frame.pageNumber < frame.pageCount then
            frame.pageNumber = frame.pageNumber + 1
            UpdateOutputPage(frame)
        end
    end)
    frame.nextButton = nextButton

    return frame
end

local function CaptureCurrentList()
    local browsePanel, _, errorText = GetMeetingStoneModules()
    if not browsePanel then
        return false, errorText
    end
    if not browsePanel.ActivityList then
        return false, "MeetingStone 当前列表尚未建立"
    end

    local countOK, itemCount = pcall(browsePanel.ActivityList.GetItemCount, browsePanel.ActivityList)
    if not countOK or not IsLayoutNumber(itemCount, true) or itemCount % 1 ~= 0 then
        return false, "无法安全读取集合石列表数量"
    end
    if itemCount == 0 then
        return false, "当前集合石列表为空，请先搜索队伍"
    end

    local batch = CreateBatchID()
    local entries = {}
    local leaders = {}
    local skipped = 0
    local captureCount = math.min(itemCount, MAX_IMPORT_ID)

    for index = 1, captureCount do
        local activity = browsePanel.ActivityList:GetItem(index)
        local leader = activity and activity:GetLeader()
        if activity and IsReadableString(leader) and leader ~= "" then
            entries[#entries + 1] = {
                title = GetDisplayText(activity:GetSummary()),
                comment = GetDisplayText(activity:GetComment()),
            }
            leaders[#entries] = leader
        else
            skipped = skipped + 1
        end
    end

    if #entries == 0 then
        return false, "当前列表没有可导入的明文队长名"
    end

    local snapshot = {
        formatVersion = 3,
        batch = batch,
        leaders = leaders,
        createdAt = time(),
    }

    local omitted = math.max(0, itemCount - captureCount)
    local message = string.format("已读取 %d 支队伍，批次 %s", #entries, batch)
    if skipped > 0 then
        message = message .. string.format("；跳过 %d 条无队长记录", skipped)
    end
    if omitted > 0 then
        message = message .. string.format("；快照上限 100 条，未读取末尾 %d 条", omitted)
    end

    return { entries = entries, snapshot = snapshot }, message
end

local function OpenOutputWindow()
    -- Only this explicit user action captures the list. Refreshes never mutate it.
    -- Hide stale/partial output on failure and publish the new snapshot atomically.
    if outputFrame then outputFrame:Hide() end
    local geometry, geometryError = GetOutputGeometry()
    if not geometry then
        SetStatus("输出失败：" .. geometryError)
        return
    end
    local ok, capture, message = pcall(CaptureCurrentList)
    if not ok or not capture then
        SetStatus(ok and message or ("读取列表失败："
            .. (IsReadableString(capture) and capture or "无法安全读取标题/说明")))
        return
    end
    outputFrame = outputFrame or CreateOutputFrame(geometry)
    outputFrame:SetSize(geometry.width, geometry.height)
    outputFrame:ClearAllPoints()
    outputFrame:SetPoint("CENTER")
    local layout, layoutError = BuildOutputLayout(outputFrame, capture.entries, capture.snapshot.batch, geometry)
    if not layout then
        SetStatus("输出失败：" .. layoutError .. "；未截断内容，请减少列表或增加屏幕可用区域后重试")
        return
    end
    outputFrame.layout = layout
    outputFrame.pageNumber = 1
    outputFrame.pageCount = #layout.pages
    -- Validate every page with the real rendering FontStrings before publication.
    for page = 1, outputFrame.pageCount do
        outputFrame.pageNumber = page
        if not UpdateOutputPage(outputFrame) then return end
    end
    outputFrame.pageNumber = 1
    if not UpdateOutputPage(outputFrame) then return end
    settings.snapshot = capture.snapshot
    SetStatus(message .. string.format("；%d 页 / %d 列 / %dpx",
        #layout.pages, layout.metrics.columnCount, layout.metrics.fontPixels))
    outputFrame:Show()
    outputFrame:Raise()
end

local function FindExistingIgnore(ignoreList, leader)
    for _, record in ipairs(ignoreList) do
        if record.leader == leader then
            return record
        end
    end
    return nil
end

local function ParseImportString(text)
    if type(text) ~= "string" then
        return nil, "导入内容不是字符串"
    end

    text = text:gsub("%s+", "")
    local batch, payload = text:match("^" .. IMPORT_PREFIX
        .. "!(%d%d%d%d%d%d%d%d%d%d%d%d)!([%d%.]+)$")
    local snapshotCount
    if not batch then
        local countText
        countText, payload = text:match("^" .. IMPORT_PREFIX .. "!N(%d+)!([%d%.]+)$")
        snapshotCount = tonumber(countText)
        if not snapshotCount or snapshotCount < 1 or snapshotCount > MAX_IMPORT_ID then
            return nil, "格式错误，应为 RRC1!批次!编号.编号 或 RRC1!N数量!编号.编号"
        end
    end

    local ids = {}
    local seen = {}
    for value in payload:gmatch("%d+") do
        local id = tonumber(value)
        if not id or id < 1 or id > MAX_IMPORT_ID then
            return nil, "包含无效编号：" .. value
        end
        if not seen[id] then
            seen[id] = true
            ids[#ids + 1] = id
        end
    end

    if #ids == 0 then
        return nil, "导入字符串中没有队伍编号"
    end

    return {
        batch = batch,
        snapshotCount = snapshotCount,
        ids = ids,
    }
end

local function ImportBlockedLeaders(text)
    local parsed, parseError = ParseImportString(text)
    if not parsed then
        return false, parseError
    end

    local snapshot = settings and settings.snapshot
    if type(snapshot) ~= "table" or type(snapshot.leaders) ~= "table" then
        return false, "没有可供回查的列表快照，请先读取当前列表"
    end
    if parsed.batch then
        if parsed.batch ~= snapshot.batch then
            return false, "批次不匹配；请使用当前快照 " .. tostring(snapshot.batch)
        end
    else
        if snapshot.formatVersion ~= nil or not snapshot.allowLegacyCountImport then
            return false, "当前快照不接受旧版 N数量 格式，请重新读取列表并截图"
        end
        if parsed.snapshotCount ~= #snapshot.leaders then
            return false, string.format("快照队伍数量不匹配；截图为 %d，当前快照为 %d",
                parsed.snapshotCount, #snapshot.leaders)
        end
    end

    local browsePanel, _, moduleError = GetMeetingStoneModules()
    if not browsePanel then
        return false, moduleError
    end
    if type(browsePanel.IgnoreLeaderOnly) ~= "table"
        or type(_G.MEETINGSTONE_UI_DB) ~= "table"
        or type(_G.MEETINGSTONE_UI_DB.IGNORE_LIST) ~= "table" then
        return false, "MeetingStoneEX 尚未加载，无法写入其屏蔽列表"
    end

    local leaders = {}
    local missing = 0
    for _, id in ipairs(parsed.ids) do
        local leader = snapshot.leaders[id]
        if IsReadableString(leader) and leader ~= "" then
            leaders[#leaders + 1] = leader
        else
            missing = missing + 1
        end
    end

    if #leaders == 0 then
        return false, "导入编号在当前快照中均无对应队长"
    end

    local ignoreList = _G.MEETINGSTONE_UI_DB.IGNORE_LIST
    local added = 0
    local existing = 0
    for _, leader in ipairs(leaders) do
        browsePanel.IgnoreLeaderOnly[leader] = true
        local existingRecord = FindExistingIgnore(ignoreList, leader)
        if existingRecord then
            if existingRecord.t ~= 1 and existingRecord.t ~= 2 then
                existingRecord.t = 2
                existingRecord.dep = "RRC OCR导入"
            end
            existing = existing + 1
        else
            table.insert(ignoreList, 1, {
                leader = leader,
                time = date("%Y-%m-%d %H:%M", time()),
                dep = "RRC OCR导入",
                t = 2,
            })
            added = added + 1
        end
    end

    if browsePanel.ActivityList then
        browsePanel.ActivityList:Refresh()
    end

    local addon = _G.LibStub("AceAddon-3.0", true):GetAddon("MeetingStone", true)
    local ignoreListPanel = addon and addon:GetModule("IgnoreListPanel", true)
    if ignoreListPanel and ignoreListPanel.IgnoreList then
        ignoreListPanel.IgnoreList:Refresh()
    end

    local message = string.format("完成：新增屏蔽 %d 名队长，已有 %d 名", added, existing)
    if missing > 0 then
        message = message .. string.format("，忽略 %d 个失效编号", missing)
    end
    return true, message
end

local function CreateImportFrame()
    local frame = CreateWindow(IMPORT_FRAME_NAME, 620, 230, "导入集合石屏蔽字符串")

    local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    hint:SetPoint("TOPLEFT", 18, -54)
    hint:SetPoint("RIGHT", -18, 0)
    hint:SetJustifyH("LEFT")
    hint:SetText("粘贴 RRC 集合石助手生成的短串，例如：RRC1!179000000000!2.4.17")

    local inputBackground = CreateSolidTexture(frame, "BACKGROUND", 0.06, 0.065, 0.08, 1)
    inputBackground:SetPoint("TOPLEFT", 18, -82)
    inputBackground:SetPoint("BOTTOMRIGHT", -18, 91)

    local editBox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    editBox:SetPoint("TOPLEFT", 25, -89)
    editBox:SetPoint("TOPRIGHT", -25, -89)
    editBox:SetHeight(28)
    editBox:SetAutoFocus(false)
    editBox:SetMaxLetters(4096)
    editBox:SetFontObject(ChatFontNormal)
    editBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    frame.editBox = editBox

    local resultLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    resultLabel:SetPoint("TOPLEFT", 18, -136)
    resultLabel:SetPoint("RIGHT", -18, 0)
    resultLabel:SetJustifyH("LEFT")
    resultLabel:SetText("")
    frame.resultLabel = resultLabel

    local importButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    importButton:SetSize(120, 26)
    importButton:SetPoint("BOTTOM", 0, 18)
    importButton:SetText("开始屏蔽")
    importButton:SetScript("OnClick", function()
        local succeeded, message = ImportBlockedLeaders(editBox:GetText())
        resultLabel:SetText(message)
        if succeeded then
            resultLabel:SetTextColor(0.35, 1, 0.45)
            SetStatus(message)
        else
            resultLabel:SetTextColor(1, 0.35, 0.30)
        end
    end)

    return frame
end

local function OpenImportWindow()
    importFrame = importFrame or CreateImportFrame()
    importFrame.resultLabel:SetText("")
    importFrame:Show()
    importFrame:Raise()
    importFrame.editBox:SetFocus()
    importFrame.editBox:HighlightText()
end

local function InitializeSettings(database)
    if type(database.meetingStoneBlocker) ~= "table" then
        database.meetingStoneBlocker = {}
    end
    settings = database.meetingStoneBlocker
    if type(settings.snapshot) ~= "table"
        or type(settings.snapshot.batch) ~= "string"
        or type(settings.snapshot.leaders) ~= "table" then
        settings.snapshot = nil
    else
        if settings.snapshot.formatVersion == nil then
            settings.snapshot.allowLegacyCountImport = true
        else
            settings.snapshot.allowLegacyCountImport = nil
        end
        statusText = string.format("已载入列表快照：批次 %s，共 %d 支队伍",
            settings.snapshot.batch, #settings.snapshot.leaders)
    end
end

ns.MeetingStoneBlocker = {
    InitializeSettings = InitializeSettings,
    OpenOutputWindow = OpenOutputWindow,
    OpenImportWindow = OpenImportWindow,
    GetStatus = function()
        return statusText
    end,
    SetStatusChanged = function(callback)
        statusChanged = callback
    end,
}
