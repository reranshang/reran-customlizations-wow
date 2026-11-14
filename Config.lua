local ADDON_NAME, ns = ...

local CreateSolidTexture = ns.CreateSolidTexture
local AddBorder = ns.AddBorder
local NormalizeColor = ns.NormalizeColor
local NormalizeInteger = ns.NormalizeInteger
local GetSharedMedia = ns.GetSharedMedia
local FetchSharedMedia = ns.FetchSharedMedia

local FRAME_NAME = "ReRansCustomlizationsConfigFrame"
local FRAME_ASPECT_RATIO = 1.5
local FRAME_SCREEN_AREA = 1 / 6
local FRAME_MIN_WIDTH = 640
local FRAME_MIN_HEIGHT = 520
local FRAME_SCREEN_MARGIN = 48

local configFrame
local colorPickerOwned = false
local colorPickerHooked = false
local integerValueControls = {}
local syncingIntegerValueControls = false
local bootFrame = CreateFrame("Frame")

local function CalculateFrameSize()
    local screenWidth = UIParent:GetWidth()
    local screenHeight = UIParent:GetHeight()
    local targetArea = screenWidth * screenHeight * FRAME_SCREEN_AREA
    local width = math.sqrt(targetArea * FRAME_ASPECT_RATIO)
    local height = width / FRAME_ASPECT_RATIO

    width = math.max(width, FRAME_MIN_WIDTH)
    height = math.max(height, FRAME_MIN_HEIGHT)

    local maximumWidth = math.max(1, screenWidth - FRAME_SCREEN_MARGIN)
    local maximumHeight = math.max(1, screenHeight - FRAME_SCREEN_MARGIN)
    local scale = math.min(1, maximumWidth / width, maximumHeight / height)

    return math.floor(width * scale + 0.5), math.floor(height * scale + 0.5)
end

local function InitializeDatabase()
    if type(ReRansCustomlizationsDB) ~= "table" then
        ReRansCustomlizationsDB = {}
    end

    if ns.IsForever then
        if type(ReRansCustomlizationsDB.autoburn) ~= "table" then
            ReRansCustomlizationsDB.autoburn = {}
        end
        ReRansCustomlizationsDB.autoburn.enabled = false
    else
        ns.Autoburn.InitializeSettings(ReRansCustomlizationsDB)
    end
    ns.NameplateDebuffs.InitializeSettings(ReRansCustomlizationsDB)
    ns.MarkerAssignment.InitializeSettings(ReRansCustomlizationsDB)
    ns.BigWigsBarHider.InitializeSettings(ReRansCustomlizationsDB)
    if not ns.IsForever then
        ns.MeetingStoneBlocker.InitializeSettings(ReRansCustomlizationsDB)
    end
    ns.CooldownViewerSounds.InitializeSettings(ReRansCustomlizationsDB)
    ns.PartyInterruptMonitor.InitializeSettings(ReRansCustomlizationsDB)
    ns.AutoInvite.InitializeSettings(ReRansCustomlizationsDB)
    -- 清理已移除的旧版集合石过滤数据
    ReRansCustomlizationsDB.meetingStoneFilter = nil
    ReRansCustomlizationsDB.msFilterDebugLog = nil
end

local function CloseCoordinateEditors(controls)
    if not controls then
        return
    end
    for _, control in pairs({ controls.x, controls.y }) do
        if control.editBox:IsShown() then
            control.editBox.cancelEdit = true
            control.editBox:ClearFocus()
            control.editBox:Hide()
            control.valueButton:Show()
        end
    end
end

local function CreateColorOption(parent, labelText, offsetY,
    targetSettings, settingKey, onChanged)
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("TOPLEFT", 4, offsetY)
    label:SetText(labelText)

    local button = CreateFrame("Button", nil, parent)
    button:SetSize(42, 20)
    button:SetPoint("LEFT", label, "RIGHT", 12, 0)
    local swatch = CreateSolidTexture(button, "ARTWORK", 1, 1, 1, 1)
    swatch:SetPoint("TOPLEFT", 2, -2)
    swatch:SetPoint("BOTTOMRIGHT", -2, 2)
    AddBorder(button, 1, 0.55, 0.57, 0.62, 1)
    button.swatch = swatch

    function button:Refresh()
        local color = targetSettings[settingKey]
        self.swatch:SetColorTexture(color.r, color.g, color.b, 1)
    end

    button:SetScript("OnClick", function(self)
        local color = targetSettings[settingKey]
        local original = { r = color.r, g = color.g, b = color.b }

        local function ApplyPickerColor(red, green, blue)
            targetSettings[settingKey] = NormalizeColor({
                r = red, g = green, b = blue,
            }, original)
            self:Refresh()
            onChanged()
        end

        colorPickerOwned = true
        ColorPickerFrame:SetupColorPickerAndShow({
            r = color.r,
            g = color.g,
            b = color.b,
            hasOpacity = false,
            swatchFunc = function()
                ApplyPickerColor(ColorPickerFrame:GetColorRGB())
            end,
            cancelFunc = function()
                targetSettings[settingKey] = original
                self:Refresh()
                onChanged()
            end,
        })
    end)
    button:Refresh()
    return button
end

local function CreateIntegerValueSlider(parent, labelText, offsetY,
    minimum, maximum, getValue, setValue)
    local row = CreateFrame("Frame", nil, parent)
    row:SetPoint("TOPLEFT", 0, offsetY)
    row:SetPoint("TOPRIGHT", -4, offsetY)
    row:SetHeight(42)

    local label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("TOPLEFT", 0, 0)
    label:SetText(labelText)

    local valueButton = CreateFrame("Button", nil, row)
    valueButton:SetSize(50, 18)
    valueButton:SetPoint("TOPRIGHT", 0, 2)
    valueButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    local valueBackground = CreateSolidTexture(valueButton, "BACKGROUND", 0.075, 0.08, 0.10, 1)
    valueBackground:SetAllPoints()
    AddBorder(valueButton, 1, 0.34, 0.36, 0.42, 1)
    local valueText = valueButton:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    valueText:SetAllPoints()
    valueText:SetJustifyH("CENTER")

    local editBox = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
    editBox:SetSize(50, 20)
    editBox:SetPoint("TOPRIGHT", 0, 2)
    editBox:SetAutoFocus(false)
    editBox:SetMaxLetters(12)
    editBox:Hide()

    local slider = CreateFrame("Slider", nil, row)
    slider:SetPoint("TOPLEFT", 0, -22)
    slider:SetPoint("TOPRIGHT", 0, -22)
    slider:SetHeight(16)
    slider:SetOrientation("HORIZONTAL")
    slider:SetMinMaxValues(minimum, maximum)
    slider:SetValueStep(1)
    slider:SetObeyStepOnDrag(true)
    local track = CreateSolidTexture(slider, "BACKGROUND", 0.19, 0.21, 0.25, 1)
    track:SetPoint("LEFT")
    track:SetPoint("RIGHT")
    track:SetHeight(4)
    slider:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    slider:GetThumbTexture():SetSize(16, 16)

    local control = {
        slider = slider,
        valueButton = valueButton,
        valueText = valueText,
        editBox = editBox,
    }

    function control:Refresh()
        local value = NormalizeInteger(getValue(), minimum, minimum, maximum)
        local wasSyncing = syncingIntegerValueControls
        syncingIntegerValueControls = true
        self.slider:SetValue(value)
        self.valueText:SetText(tostring(value))
        syncingIntegerValueControls = wasSyncing
    end

    function control:SetRange(newMinimum, newMaximum)
        minimum, maximum = newMinimum, newMaximum
        local wasSyncing = syncingIntegerValueControls
        syncingIntegerValueControls = true
        self.slider:SetMinMaxValues(minimum, maximum)
        self:Refresh()
        syncingIntegerValueControls = wasSyncing
    end

    function control:CloseEditor(cancel)
        if self.editBox:IsShown() then
            self.editBox.cancelEdit = cancel and true or nil
            self.editBox:ClearFocus()
            self.editBox:Hide()
            self.valueButton:Show()
            self:Refresh()
        end
    end

    local function FinishEditing(commit)
        if commit then
            local value = tonumber(editBox:GetText())
            if value then
                setValue(NormalizeInteger(value, getValue(), minimum, maximum))
            end
        end
        editBox.cancelEdit = nil
        editBox:Hide()
        valueButton:Show()
        control:Refresh()
    end

    valueButton:SetScript("OnClick", function(_, mouseButton)
        if mouseButton ~= "RightButton" then
            return
        end
        valueButton:Hide()
        editBox:SetText(tostring(getValue()))
        editBox:Show()
        editBox:SetFocus()
        editBox:HighlightText()
    end)
    editBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    editBox:SetScript("OnEscapePressed", function(self)
        self.cancelEdit = true
        self:ClearFocus()
    end)
    editBox:SetScript("OnEditFocusLost", function(self)
        FinishEditing(not self.cancelEdit)
    end)
    slider:SetScript("OnValueChanged", function(_, value)
        value = NormalizeInteger(value, getValue(), minimum, maximum)
        valueText:SetText(tostring(value))
        if not syncingIntegerValueControls then
            setValue(value)
        end
    end)

    control:Refresh()
    integerValueControls[#integerValueControls + 1] = control
    return control
end

local function CreateMediaDropdown(parent, labelText, offsetY, mediaType,
    settings, settingKey, defaultKey, validateKey, onChanged)
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("TOPLEFT", 0, offsetY)
    label:SetText(labelText)

    local dropdown = CreateFrame("DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
    dropdown:SetPoint("TOPLEFT", 0, offsetY - 20)
    dropdown:SetPoint("TOPRIGHT", -4, offsetY - 20)

    local function Refresh()
        validateKey()
        local key = settings[settingKey]
        local text = key == defaultKey and "默认" or key:gsub("|", "||")
        if dropdown.OverrideText then
            dropdown:OverrideText(text)
        else
            dropdown:SetDefaultText(text)
        end
    end

    local function AddChoice(rootDescription, key, text)
        rootDescription:CreateRadio(text, function()
            return settings[settingKey] == key
        end, function()
            settings[settingKey] = key
            onChanged()
            Refresh()
        end)
    end

    dropdown:SetupMenu(function(_, rootDescription)
        AddChoice(rootDescription, defaultKey, "默认")
        local media = GetSharedMedia()
        if not media then return end
        local succeeded, mediaKeys = pcall(media.List, media, mediaType)
        if not succeeded or type(mediaKeys) ~= "table" then return end
        local sortedKeys = {}
        for _, key in ipairs(mediaKeys) do
            if type(key) == "string" then sortedKeys[#sortedKeys + 1] = key end
        end
        table.sort(sortedKeys)
        for _, key in ipairs(sortedKeys) do
            local value = FetchSharedMedia(media, mediaType, key)
            if value and (mediaType ~= "font" or (type(value) == "string" and value ~= "")) then
                local text = key:gsub("|", "||")
                if mediaType == "statusbar" then
                    text = "|T" .. tostring(value) .. ":14:80|t " .. text
                end
                AddChoice(rootDescription, key, text)
            end
        end
        rootDescription:SetScrollMode(300)
    end)
    Refresh()
    return Refresh
end

local function CreateAutoburnPage(content)
    local Autoburn = ns.Autoburn
    local settings = Autoburn.GetSettings()
    local SetMonitoringEnabled = Autoburn.SetMonitoringEnabled
    local FormatDuration = Autoburn.FormatDuration
    local CommitDurationInput = Autoburn.CommitDurationInput
    local CommitLabelInput = Autoburn.CommitLabelInput
    local RefreshAutoburnDisplay = Autoburn.RefreshDisplay
    local ValidateAutoburnTextureKey = Autoburn.ValidateTextureKey
    local ValidateAutoburnFontKey = Autoburn.ValidateFontKey
    local AUTOBURN_SIZE = Autoburn.SIZE
    local AUTOBURN_DEFAULT_MEDIA_KEY = Autoburn.DEFAULT_MEDIA_KEY
    local SetAutoburnCoordinate = Autoburn.SetCoordinate
    local SyncPositionControls = Autoburn.SyncPositionControls
    local UpdateUnlockButton = Autoburn.UpdateUnlockButton
    local ClampAutoburnPosition = Autoburn.ClampPosition

    local firstPage = CreateFrame("Frame", nil, content)
    firstPage:SetAllPoints()

    local firstPageTitle = firstPage:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    firstPageTitle:SetPoint("TOPLEFT", 4, -4)
    firstPageTitle:SetText("DK沸点监测")

    local autoburnLeftPanel = CreateFrame("Frame", nil, firstPage)
    autoburnLeftPanel:SetPoint("TOPLEFT", 0, -30)
    autoburnLeftPanel:SetPoint("BOTTOMLEFT")
    autoburnLeftPanel:SetWidth(210)

    local autoburnRightPanel = CreateFrame("Frame", nil, firstPage)
    autoburnRightPanel:SetPoint("TOPLEFT", autoburnLeftPanel, "TOPRIGHT", 12, 0)
    autoburnRightPanel:SetPoint("BOTTOMRIGHT")

    local enabledCheckButton = CreateFrame("CheckButton", nil,
        autoburnLeftPanel, "UICheckButtonTemplate")
    enabledCheckButton:SetPoint("TOPLEFT", 0, 0)
    enabledCheckButton:SetChecked(settings.enabled)
    enabledCheckButton:SetScript("OnClick", function(self)
        SetMonitoringEnabled(self:GetChecked())
    end)

    local enabledLabel = autoburnLeftPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    enabledLabel:SetPoint("LEFT", enabledCheckButton, "RIGHT", 4, 1)
    enabledLabel:SetText("开启")

    local timeLabel = autoburnLeftPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    timeLabel:SetPoint("TOPLEFT", 4, -42)
    timeLabel:SetText("倒计时（秒）")

    local timeInput = CreateFrame("EditBox", nil, autoburnLeftPanel, "InputBoxTemplate")
    timeInput:SetSize(82, 26)
    timeInput:SetPoint("LEFT", timeLabel, "RIGHT", 16, 0)
    timeInput:SetAutoFocus(false)
    timeInput:SetMaxLetters(6)
    timeInput:SetText(FormatDuration(settings.duration))
    timeInput:SetScript("OnEnterPressed", function(self)
        CommitDurationInput(self)
        self:ClearFocus()
    end)
    timeInput:SetScript("OnEscapePressed", function(self)
        self:SetText(FormatDuration(settings.duration))
        self:ClearFocus()
    end)
    timeInput:SetScript("OnEditFocusLost", CommitDurationInput)

    local blockedColorButton = CreateColorOption(autoburnLeftPanel,
        "不该施放血沸的颜色", -82, settings, "blockedColor", RefreshAutoburnDisplay)
    local readyColorButton = CreateColorOption(autoburnLeftPanel,
        "能施放血沸的颜色", -114, settings, "readyColor", RefreshAutoburnDisplay)

    local textLabel = autoburnLeftPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    textLabel:SetPoint("TOPLEFT", 4, -154)
    textLabel:SetText("显示文字")

    local textInput = CreateFrame("EditBox", nil, autoburnLeftPanel, "InputBoxTemplate")
    textInput:SetSize(124, 26)
    textInput:SetPoint("LEFT", textLabel, "RIGHT", 16, 0)
    textInput:SetAutoFocus(false)
    textInput:SetMaxLetters(48)
    textInput:SetText(settings.label)
    textInput:SetScript("OnEnterPressed", function(self)
        CommitLabelInput(self)
        self:ClearFocus()
    end)
    textInput:SetScript("OnEscapePressed", function(self)
        self:SetText(settings.label)
        self:ClearFocus()
    end)
    textInput:SetScript("OnEditFocusLost", CommitLabelInput)

    local showTimeUnitCheckButton = CreateFrame("CheckButton", nil,
        autoburnLeftPanel, "UICheckButtonTemplate")
    showTimeUnitCheckButton:SetPoint("TOPLEFT", 0, -194)
    showTimeUnitCheckButton:SetChecked(settings.showTimeUnit)
    showTimeUnitCheckButton:SetScript("OnClick", function(self)
        settings.showTimeUnit = not not self:GetChecked()
        Autoburn.InvalidateTimerText()
        RefreshAutoburnDisplay()
    end)

    local showTimeUnitLabel = autoburnLeftPanel:CreateFontString(nil,
        "OVERLAY", "GameFontHighlight")
    showTimeUnitLabel:SetPoint("LEFT", showTimeUnitCheckButton, "RIGHT", 4, 1)
    showTimeUnitLabel:SetText("显示时间单位")

    local decimalPlacesLabel = autoburnLeftPanel:CreateFontString(nil,
        "OVERLAY", "GameFontHighlight")
    decimalPlacesLabel:SetPoint("TOPLEFT", 4, -242)
    decimalPlacesLabel:SetText("时间小数位数")

    local decimalPlacesDropdown = CreateFrame("DropdownButton", nil,
        autoburnLeftPanel, "WowStyle1DropdownTemplate")
    decimalPlacesDropdown:SetPoint("TOPLEFT", 106, -232)
    decimalPlacesDropdown:SetPoint("TOPRIGHT", -4, -232)

    local function RefreshDecimalPlacesText()
        local text = settings.decimalPlaces .. " 位"
        if decimalPlacesDropdown.OverrideText then
            decimalPlacesDropdown:OverrideText(text)
        else
            decimalPlacesDropdown:SetDefaultText(text)
        end
    end

    decimalPlacesDropdown:SetupMenu(function(_, rootDescription)
        for decimalPlaces = 0, 2 do
            local value = decimalPlaces
            rootDescription:CreateRadio(value .. " 位", function()
                return settings.decimalPlaces == value
            end, function()
                settings.decimalPlaces = value
                Autoburn.InvalidateTimerText()
                RefreshDecimalPlacesText()
                RefreshAutoburnDisplay()
            end)
        end
    end)
    RefreshDecimalPlacesText()

    local RefreshTextureDropdownText = CreateMediaDropdown(autoburnRightPanel,
        "条材质", -4, "statusbar", settings, "textureKey", AUTOBURN_DEFAULT_MEDIA_KEY,
        ValidateAutoburnTextureKey, RefreshAutoburnDisplay)
    local RefreshFontDropdownText = CreateMediaDropdown(autoburnRightPanel,
        "文字字体", -62, "font", settings, "fontKey", AUTOBURN_DEFAULT_MEDIA_KEY,
        ValidateAutoburnFontKey, RefreshAutoburnDisplay)

    local autoburnWidthControl = CreateIntegerValueSlider(autoburnRightPanel,
        "计时条长度", -118, AUTOBURN_SIZE.MIN_WIDTH, AUTOBURN_SIZE.MAX_WIDTH,
        function() return settings.width end, function(value)
            settings.width = value
            RefreshAutoburnDisplay()
        end)
    local autoburnHeightControl = CreateIntegerValueSlider(autoburnRightPanel,
        "计时条高度", -166, AUTOBURN_SIZE.MIN_HEIGHT, AUTOBURN_SIZE.MAX_HEIGHT,
        function() return settings.height end, function(value)
            settings.height = value
            RefreshAutoburnDisplay()
        end)
    local autoburnFontSizeControl = CreateIntegerValueSlider(autoburnRightPanel,
        "字体大小", -214, AUTOBURN_SIZE.MIN_FONT_SIZE, AUTOBURN_SIZE.MAX_FONT_SIZE,
        function() return settings.fontSize end, function(value)
            settings.fontSize = value
            RefreshAutoburnDisplay()
        end)
    local autoburnLabelOffsetControl = CreateIntegerValueSlider(autoburnRightPanel,
        "文字横坐标偏移", -262, AUTOBURN_SIZE.MIN_TEXT_OFFSET, AUTOBURN_SIZE.MAX_TEXT_OFFSET,
        function() return settings.labelOffsetX end, function(value)
            settings.labelOffsetX = value
            RefreshAutoburnDisplay()
        end)
    local autoburnTimerOffsetControl = CreateIntegerValueSlider(autoburnRightPanel,
        "计时横坐标偏移", -310, AUTOBURN_SIZE.MIN_TEXT_OFFSET, AUTOBURN_SIZE.MAX_TEXT_OFFSET,
        function() return settings.timerOffsetX end, function(value)
            settings.timerOffsetX = value
            RefreshAutoburnDisplay()
        end)

    local showFullBarCheckButton = CreateFrame("CheckButton", nil,
        autoburnRightPanel, "UICheckButtonTemplate")
    showFullBarCheckButton:SetPoint("TOPLEFT", 0, -356)
    showFullBarCheckButton:SetChecked(settings.showFullBar)
    showFullBarCheckButton:SetScript("OnClick", function(self)
        settings.showFullBar = not not self:GetChecked()
        RefreshAutoburnDisplay()
    end)

    local showFullBarLabel = autoburnRightPanel:CreateFontString(nil,
        "OVERLAY", "GameFontHighlight")
    showFullBarLabel:SetPoint("LEFT", showFullBarCheckButton, "RIGHT", 4, 1)
    showFullBarLabel:SetText("开启满条显示")
    showFullBarCheckButton:SetHitRectInsets(0, -showFullBarLabel:GetStringWidth() - 4, 0, 0)
    showFullBarCheckButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("开启满条显示")
        GameTooltip:AddLine("未自动触发但血沸高亮时显示满条", 0.75, 0.75, 0.75, true)
        GameTooltip:Show()
    end)
    showFullBarCheckButton:SetScript("OnLeave", GameTooltip_Hide)

    local fullBarColorButton = CreateColorOption(autoburnRightPanel,
        "满条颜色", -400, settings, "fullBarColor", RefreshAutoburnDisplay)

    local unlockButton = CreateFrame("Button", nil, autoburnLeftPanel, "UIPanelButtonTemplate")
    unlockButton:SetSize(120, 24)
    unlockButton:SetPoint("TOPLEFT", 4, -262)
    unlockButton:SetScript("OnClick", function()
        Autoburn.TogglePositionLock()
    end)

    local coordinateHint = autoburnLeftPanel:CreateFontString(nil,
        "OVERLAY", "GameFontDisableSmall")
    coordinateHint:SetPoint("TOPLEFT", unlockButton, "BOTTOMLEFT", 0, -4)
    coordinateHint:SetText("右键数值可精确输入")

    local function CreatePositionControl(axis, labelText, offsetY)
        local row = CreateFrame("Frame", nil, autoburnLeftPanel)
        row:SetPoint("TOPLEFT", 4, offsetY)
        row:SetPoint("RIGHT", -4, 0)
        row:SetHeight(24)

        local label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        label:SetPoint("LEFT", 0, 0)
        label:SetWidth(22)
        label:SetJustifyH("LEFT")
        label:SetText(labelText)

        local slider = CreateFrame("Slider", nil, row)
        slider:SetPoint("LEFT", label, "RIGHT", 8, 0)
        slider:SetPoint("RIGHT", -62, 0)
        slider:SetHeight(18)
        slider:SetOrientation("HORIZONTAL")
        slider:SetValueStep(1)
        slider:SetObeyStepOnDrag(true)

        local track = CreateSolidTexture(slider, "BACKGROUND", 0.19, 0.21, 0.25, 1)
        track:SetPoint("LEFT", 0, 0)
        track:SetPoint("RIGHT", 0, 0)
        track:SetHeight(4)
        slider:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
        local thumb = slider:GetThumbTexture()
        thumb:SetSize(16, 16)

        local valueButton = CreateFrame("Button", nil, row)
        valueButton:SetSize(54, 22)
        valueButton:SetPoint("RIGHT", 0, 0)
        valueButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        local valueBackground = CreateSolidTexture(valueButton, "BACKGROUND", 0.075, 0.08, 0.10, 1)
        valueBackground:SetAllPoints()
        AddBorder(valueButton, 1, 0.34, 0.36, 0.42, 1)
        local valueText = valueButton:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        valueText:SetAllPoints()
        valueText:SetJustifyH("CENTER")

        local editBox = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
        editBox:SetSize(54, 22)
        editBox:SetPoint("RIGHT", 0, 0)
        editBox:SetAutoFocus(false)
        editBox:SetMaxLetters(12)
        editBox:Hide()

        local function FinishEditing(commit)
            if commit then
                local value = tonumber(editBox:GetText())
                if value then
                    SetAutoburnCoordinate(axis, value)
                end
            end
            editBox.cancelEdit = nil
            editBox:Hide()
            valueButton:Show()
            SyncPositionControls()
        end

        valueButton:SetScript("OnClick", function(_, mouseButton)
            if mouseButton ~= "RightButton" then
                return
            end
            valueButton:Hide()
            editBox:SetText(tostring(settings[axis]))
            editBox:Show()
            editBox:SetFocus()
            editBox:HighlightText()
        end)
        editBox:SetScript("OnEnterPressed", function(self)
            self:ClearFocus()
        end)
        editBox:SetScript("OnEscapePressed", function(self)
            self.cancelEdit = true
            self:ClearFocus()
        end)
        editBox:SetScript("OnEditFocusLost", function(self)
            FinishEditing(not self.cancelEdit)
        end)
        slider:SetScript("OnValueChanged", function(_, value)
            if not Autoburn.IsSyncingPositionControls() then
                SetAutoburnCoordinate(axis, value)
            end
        end)

        return {
            slider = slider,
            valueButton = valueButton,
            valueText = valueText,
            editBox = editBox,
        }
    end

    local positionControls = {
        unlockButton = unlockButton,
        x = CreatePositionControl("x", "X", -302),
        y = CreatePositionControl("y", "Y", -334),
    }
    Autoburn.SetPositionControls(positionControls)
    UpdateUnlockButton()
    SyncPositionControls()

    local function CloseEditors()
        CloseCoordinateEditors(positionControls)
        autoburnWidthControl:CloseEditor(true)
        autoburnHeightControl:CloseEditor(true)
        autoburnFontSizeControl:CloseEditor(true)
        autoburnLabelOffsetControl:CloseEditor(true)
        autoburnTimerOffsetControl:CloseEditor(true)
    end

    return {
        page = firstPage,
        Refresh = function()
            enabledCheckButton:SetChecked(settings.enabled)
            timeInput:SetText(FormatDuration(settings.duration))
            textInput:SetText(settings.label)
            blockedColorButton:Refresh()
            readyColorButton:Refresh()
            fullBarColorButton:Refresh()
            RefreshTextureDropdownText()
            RefreshFontDropdownText()
            showTimeUnitCheckButton:SetChecked(settings.showTimeUnit)
            showFullBarCheckButton:SetChecked(settings.showFullBar)
            RefreshDecimalPlacesText()
            autoburnWidthControl:Refresh()
            autoburnHeightControl:Refresh()
            autoburnFontSizeControl:Refresh()
            autoburnLabelOffsetControl:Refresh()
            autoburnTimerOffsetControl:Refresh()
            UpdateUnlockButton()
            ClampAutoburnPosition()
            SyncPositionControls()
        end,
        CloseEditors = CloseEditors,
        OnConfigHide = function()
            timeInput:ClearFocus()
            textInput:ClearFocus()
            CloseEditors()
        end,
        SetPreviewShown = function(shown)
            Autoburn.SetConfigPreviewActive(shown)
        end,
    }
end

local function CreateNameplateDebuffPage(content)
    local NameplateDebuffs = ns.NameplateDebuffs
    local nameplateDebuffSettings = NameplateDebuffs.GetSettings()
    local NAMEPLATE_DEBUFF_MAX_SPELLS = NameplateDebuffs.MAX_SPELLS
    local NAMEPLATE_DEBUFF_MAX_UNITS = NameplateDebuffs.MAX_UNITS
    local NAMEPLATE_DEBUFF_MIN_SIZE = NameplateDebuffs.MIN_SIZE
    local NAMEPLATE_DEBUFF_MAX_SIZE = NameplateDebuffs.MAX_SIZE
    local ParseNameplateDebuffSpellID = NameplateDebuffs.ParseSpellID
    local SetNameplateDebuffMonitoringEnabled = NameplateDebuffs.SetMonitoringEnabled
    local RefreshNameplateDebuffDisplay = NameplateDebuffs.RefreshDisplay
    local ApplyNameplateDebuffPosition = NameplateDebuffs.ApplyPosition
    local ApplyNameplateDebuffColors = NameplateDebuffs.ApplyColors
    local RequestNameplateDebuffSecureRebuild = NameplateDebuffs.RequestSecureRebuild
    local SetNameplateDebuffCoordinate = NameplateDebuffs.SetCoordinate
    local SyncNameplateDebuffPositionControls = NameplateDebuffs.SyncPositionControls
    local UpdateNameplateDebuffUnlockButton = NameplateDebuffs.UpdateUnlockButton
    local UpdateNameplateDebuffPendingText = NameplateDebuffs.UpdatePendingText
    local ClampNameplateDebuffPosition = NameplateDebuffs.ClampPosition

    local secondPage = CreateFrame("Frame", nil, content)
    secondPage:SetAllPoints()

    local secondPageTitle = secondPage:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    secondPageTitle:SetPoint("TOPLEFT", 4, -4)
    secondPageTitle:SetText("姓名版 Debuff 监测")

    local nameplateLeftPanel = CreateFrame("Frame", nil, secondPage)
    nameplateLeftPanel:SetPoint("TOPLEFT", 0, -30)
    nameplateLeftPanel:SetPoint("BOTTOMLEFT")
    nameplateLeftPanel:SetWidth(210)

    local nameplateRightPanel = CreateFrame("Frame", nil, secondPage)
    nameplateRightPanel:SetPoint("TOPLEFT", nameplateLeftPanel, "TOPRIGHT", 12, 0)
    nameplateRightPanel:SetPoint("BOTTOMRIGHT")

    local nameplateEnabledCheckButton = CreateFrame("CheckButton", nil,
        nameplateLeftPanel, "UICheckButtonTemplate")
    nameplateEnabledCheckButton:SetPoint("TOPLEFT", 0, 0)
    nameplateEnabledCheckButton:SetChecked(nameplateDebuffSettings.enabled)
    nameplateEnabledCheckButton:SetScript("OnClick", function(self)
        SetNameplateDebuffMonitoringEnabled(self:GetChecked())
    end)

    local nameplateEnabledLabel = nameplateLeftPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    nameplateEnabledLabel:SetPoint("LEFT", nameplateEnabledCheckButton, "RIGHT", 4, 1)
    nameplateEnabledLabel:SetText("开启")

    local spellListLabel = nameplateLeftPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    spellListLabel:SetPoint("TOPLEFT", 4, -42)
    spellListLabel:SetPoint("TOPRIGHT", -4, -42)
    spellListLabel:SetJustifyH("LEFT")
    spellListLabel:SetWordWrap(true)
    spellListLabel:SetText(string.format("玩家施加的 Debuff 技能 ID（最多 %d 个）",
        NAMEPLATE_DEBUFF_MAX_SPELLS))

    local spellScrollFrame = CreateFrame("ScrollFrame", nil,
        nameplateLeftPanel, "UIPanelScrollFrameTemplate")
    spellScrollFrame:SetPoint("TOPLEFT", 4, -82)
    spellScrollFrame:SetSize(174, 162)

    local spellScrollChild = CreateFrame("Frame", nil, spellScrollFrame)
    spellScrollChild:SetSize(150, 1)
    spellScrollFrame:SetScrollChild(spellScrollChild)

    local spellRows = {}
    local newSpellDraftActive = false
    local RefreshNameplateSpellRows

    local function CommitFocusedNameplateSpellEdit(excludedRow)
        for _, row in ipairs(spellRows) do
            if row ~= excludedRow and row.editBox:HasFocus() then
                row.editBox:ClearFocus()
                return
            end
        end
    end

    local function SpellIDAlreadyConfigured(spellID, excludedIndex)
        for index, configuredSpellID in ipairs(nameplateDebuffSettings.spellIDs) do
            if index ~= excludedIndex and configuredSpellID == spellID then
                return true
            end
        end
        return false
    end

    local function CommitNameplateSpellRow(index, editBox, errorText)
        local spellID = ParseNameplateDebuffSpellID(editBox:GetText())
        if not spellID then
            errorText:SetText("请输入正整数")
            return false
        end
        if SpellIDAlreadyConfigured(spellID, index <= #nameplateDebuffSettings.spellIDs and index or nil) then
            errorText:SetText("ID 重复")
            return false
        end

        if index <= #nameplateDebuffSettings.spellIDs then
            if nameplateDebuffSettings.spellIDs[index] == spellID then
                errorText:SetText("")
                editBox:SetText(tostring(spellID))
                return true
            end
            nameplateDebuffSettings.spellIDs[index] = spellID
        elseif #nameplateDebuffSettings.spellIDs < NAMEPLATE_DEBUFF_MAX_SPELLS then
            nameplateDebuffSettings.spellIDs[#nameplateDebuffSettings.spellIDs + 1] = spellID
            newSpellDraftActive = false
        else
            errorText:SetText("已达上限")
            return false
        end

        RequestNameplateDebuffSecureRebuild()
        RefreshNameplateSpellRows()
        return true
    end

    local function EnsureNameplateSpellRow(index)
        local row = spellRows[index]
        if row then
            return row
        end

        row = CreateFrame("Frame", nil, spellScrollChild)
        row:SetHeight(30)
        row:SetPoint("LEFT")
        row:SetPoint("RIGHT")

        local editBox = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
        editBox:SetSize(82, 24)
        editBox:SetPoint("LEFT", 0, 0)
        editBox:SetAutoFocus(false)
        editBox:SetNumeric(true)
        editBox:SetMaxLetters(10)
        row.editBox = editBox

        local deleteButton = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        deleteButton:SetSize(48, 22)
        deleteButton:SetPoint("LEFT", editBox, "RIGHT", 5, 0)
        deleteButton:SetText("删除")
        row.deleteButton = deleteButton

        local errorText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        errorText:SetTextColor(1, 0.2, 0.2)
        errorText:SetPoint("LEFT", deleteButton, "RIGHT", 4, 0)
        errorText:SetPoint("RIGHT", 0, 0)
        errorText:SetJustifyH("LEFT")
        row.errorText = errorText

        spellRows[index] = row
        return row
    end

    local addSpellButton = CreateFrame("Button", nil, nameplateLeftPanel, "UIPanelButtonTemplate")
    addSpellButton:SetSize(116, 24)
    addSpellButton:SetPoint("TOPLEFT", spellScrollFrame, "BOTTOMLEFT", 0, -8)
    addSpellButton:SetText("添加技能 ID")

    RefreshNameplateSpellRows = function()
        local rowCount = #nameplateDebuffSettings.spellIDs + (newSpellDraftActive and 1 or 0)
        for index = 1, math.max(rowCount, #spellRows) do
            local row = EnsureNameplateSpellRow(index)
            if index <= rowCount then
                local rowIndex = index
                local rowIsDraft = rowIndex > #nameplateDebuffSettings.spellIDs
                row:ClearAllPoints()
                local rowOffset = -(rowIndex - 1) * 30
                row:SetPoint("TOPLEFT", 0, rowOffset)
                row:SetPoint("TOPRIGHT", 0, rowOffset)
                row.errorText:SetText("")
                if not row.editBox:HasFocus() then
                    row.editBox:SetText(rowIsDraft and ""
                        or tostring(nameplateDebuffSettings.spellIDs[rowIndex]))
                end
                row.editBox:SetScript("OnEnterPressed", function(self)
                    if CommitNameplateSpellRow(rowIndex, self, row.errorText) then
                        self.ignoreNextFocusLost = true
                        self:ClearFocus()
                    end
                end)
                row.editBox:SetScript("OnEscapePressed", function(self)
                    self.ignoreNextFocusLost = true
                    self:ClearFocus()
                    if rowIsDraft then
                        newSpellDraftActive = false
                        RefreshNameplateSpellRows()
                    else
                        self:SetText(tostring(nameplateDebuffSettings.spellIDs[rowIndex]))
                        row.errorText:SetText("")
                    end
                end)
                row.editBox:SetScript("OnEditFocusLost", function(self)
                    if self.ignoreNextFocusLost then
                        self.ignoreNextFocusLost = nil
                        return
                    end
                    CommitNameplateSpellRow(rowIndex, self, row.errorText)
                end)
                row.deleteButton:SetScript("OnMouseDown", function()
                    CommitFocusedNameplateSpellEdit(row)
                    if row.editBox:HasFocus() then
                        row.editBox.ignoreNextFocusLost = true
                    end
                end)
                row.deleteButton:SetScript("OnClick", function()
                    if row.editBox:HasFocus() then
                        row.editBox:ClearFocus()
                    end
                    row.editBox.ignoreNextFocusLost = nil
                    if rowIsDraft then
                        newSpellDraftActive = false
                    else
                        table.remove(nameplateDebuffSettings.spellIDs, rowIndex)
                        RequestNameplateDebuffSecureRebuild()
                    end
                    RefreshNameplateSpellRows()
                end)
                row:Show()
            else
                if row.editBox:HasFocus() then
                    row.editBox.ignoreNextFocusLost = true
                    row.editBox:ClearFocus()
                end
                row:Hide()
            end
        end

        spellScrollChild:SetHeight(math.max(1, rowCount * 30))
        if rowCount == 0 then
            spellScrollFrame:SetVerticalScroll(0)
        end
        addSpellButton:SetEnabled(not newSpellDraftActive
            and #nameplateDebuffSettings.spellIDs < NAMEPLATE_DEBUFF_MAX_SPELLS)
    end

    addSpellButton:SetScript("OnClick", function()
        CommitFocusedNameplateSpellEdit()
        if newSpellDraftActive or #nameplateDebuffSettings.spellIDs >= NAMEPLATE_DEBUFF_MAX_SPELLS then
            return
        end
        newSpellDraftActive = true
        RefreshNameplateSpellRows()
        local rowCount = #nameplateDebuffSettings.spellIDs + 1
        spellScrollFrame:SetVerticalScroll(math.max(0, rowCount * 30 - 162))
        local row = spellRows[rowCount]
        row.editBox:SetFocus()
    end)
    RefreshNameplateSpellRows()

    local directionLabel = nameplateRightPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    directionLabel:SetPoint("TOPLEFT", 0, -4)
    directionLabel:SetText("方块生长方向")

    local directionDropdown = CreateFrame("DropdownButton", nil,
        nameplateRightPanel, "WowStyle1DropdownTemplate")
    directionDropdown:SetPoint("TOPLEFT", 0, -26)
    directionDropdown:SetPoint("TOPRIGHT", -4, -26)

    local function RefreshNameplateDirectionText()
        local text = nameplateDebuffSettings.growthDirection == "LEFT" and "向左" or "向右"
        if directionDropdown.OverrideText then
            directionDropdown:OverrideText(text)
        else
            directionDropdown:SetDefaultText(text)
        end
    end

    directionDropdown:SetupMenu(function(_, rootDescription)
        rootDescription:CreateRadio("向右", function()
            return nameplateDebuffSettings.growthDirection == "RIGHT"
        end, function()
            nameplateDebuffSettings.growthDirection = "RIGHT"
            RefreshNameplateDirectionText()
            RefreshNameplateDebuffDisplay()
            ApplyNameplateDebuffPosition()
        end)
        rootDescription:CreateRadio("向左", function()
            return nameplateDebuffSettings.growthDirection == "LEFT"
        end, function()
            nameplateDebuffSettings.growthDirection = "LEFT"
            RefreshNameplateDirectionText()
            RefreshNameplateDebuffDisplay()
            ApplyNameplateDebuffPosition()
        end)
    end)
    RefreshNameplateDirectionText()

    local noBuffColorButton = CreateColorOption(nameplateRightPanel,
        "无BUFF颜色", -70, nameplateDebuffSettings, "noBuffColor", ApplyNameplateDebuffColors)
    local hasBuffColorButton = CreateColorOption(nameplateRightPanel,
        "有BUFF颜色", -102, nameplateDebuffSettings, "hasBuffColor", ApplyNameplateDebuffColors)

    local perRowControl = CreateIntegerValueSlider(nameplateRightPanel,
        "每行方块数量", -138, 1, NAMEPLATE_DEBUFF_MAX_UNITS, function()
            return nameplateDebuffSettings.squaresPerRow
        end, function(value)
            if nameplateDebuffSettings.squaresPerRow ~= value then
                nameplateDebuffSettings.squaresPerRow = value
                RefreshNameplateDebuffDisplay()
            end
        end)

    local squareSizeControl = CreateIntegerValueSlider(nameplateRightPanel,
        "方块大小", -184, NAMEPLATE_DEBUFF_MIN_SIZE, NAMEPLATE_DEBUFF_MAX_SIZE, function()
            return nameplateDebuffSettings.squareSize
        end, function(value)
            if nameplateDebuffSettings.squareSize ~= value then
                nameplateDebuffSettings.squareSize = value
                RequestNameplateDebuffSecureRebuild()
            end
        end)

    local nameplateUnlockButton = CreateFrame("Button", nil,
        nameplateRightPanel, "UIPanelButtonTemplate")
    nameplateUnlockButton:SetSize(112, 24)
    nameplateUnlockButton:SetPoint("TOPLEFT", 0, -232)
    nameplateUnlockButton:SetScript("OnClick", function()
        NameplateDebuffs.TogglePositionLock()
    end)

    local nameplateCoordinateHint = nameplateRightPanel:CreateFontString(nil,
        "OVERLAY", "GameFontDisableSmall")
    nameplateCoordinateHint:SetPoint("TOPLEFT", nameplateUnlockButton, "BOTTOMLEFT", 0, -4)
    nameplateCoordinateHint:SetPoint("TOPRIGHT", nameplateRightPanel, "TOPRIGHT", -4, -260)
    nameplateCoordinateHint:SetJustifyH("LEFT")
    nameplateCoordinateHint:SetWordWrap(true)
    nameplateCoordinateHint:SetText("右键数量、大小或坐标数值可精确输入")

    local function CreateNameplatePositionControl(axis, labelText, offsetY)
        local row = CreateFrame("Frame", nil, nameplateRightPanel)
        row:SetPoint("TOPLEFT", 0, offsetY)
        row:SetPoint("TOPRIGHT", -4, offsetY)
        row:SetHeight(24)

        local label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        label:SetPoint("LEFT")
        label:SetWidth(18)
        label:SetText(labelText)

        local slider = CreateFrame("Slider", nil, row)
        slider:SetPoint("LEFT", label, "RIGHT", 4, 0)
        slider:SetPoint("RIGHT", -54, 0)
        slider:SetHeight(18)
        slider:SetOrientation("HORIZONTAL")
        slider:SetValueStep(1)
        slider:SetObeyStepOnDrag(true)
        local track = CreateSolidTexture(slider, "BACKGROUND", 0.19, 0.21, 0.25, 1)
        track:SetPoint("LEFT")
        track:SetPoint("RIGHT")
        track:SetHeight(4)
        slider:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
        slider:GetThumbTexture():SetSize(16, 16)

        local valueButton = CreateFrame("Button", nil, row)
        valueButton:SetSize(50, 22)
        valueButton:SetPoint("RIGHT")
        valueButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        local valueBackground = CreateSolidTexture(valueButton, "BACKGROUND", 0.075, 0.08, 0.10, 1)
        valueBackground:SetAllPoints()
        AddBorder(valueButton, 1, 0.34, 0.36, 0.42, 1)
        local valueText = valueButton:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        valueText:SetAllPoints()

        local editBox = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
        editBox:SetSize(50, 22)
        editBox:SetPoint("RIGHT")
        editBox:SetAutoFocus(false)
        editBox:SetMaxLetters(12)
        editBox:Hide()

        local function FinishEditing(commit)
            if commit then
                local value = tonumber(editBox:GetText())
                if value then
                    SetNameplateDebuffCoordinate(axis, value)
                end
            end
            editBox.cancelEdit = nil
            editBox:Hide()
            valueButton:Show()
            SyncNameplateDebuffPositionControls()
        end

        valueButton:SetScript("OnClick", function(_, mouseButton)
            if mouseButton == "RightButton" then
                valueButton:Hide()
                editBox:SetText(tostring(nameplateDebuffSettings[axis]))
                editBox:Show()
                editBox:SetFocus()
                editBox:HighlightText()
            end
        end)
        editBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
        editBox:SetScript("OnEscapePressed", function(self)
            self.cancelEdit = true
            self:ClearFocus()
        end)
        editBox:SetScript("OnEditFocusLost", function(self)
            FinishEditing(not self.cancelEdit)
        end)
        slider:SetScript("OnValueChanged", function(_, value)
            if not NameplateDebuffs.IsSyncingControls() then
                SetNameplateDebuffCoordinate(axis, value)
            end
        end)

        return {
            slider = slider,
            valueButton = valueButton,
            valueText = valueText,
            editBox = editBox,
        }
    end

    local nameplateDebuffPositionControls = {
        unlockButton = nameplateUnlockButton,
        x = CreateNameplatePositionControl("x", "X", -280),
        y = CreateNameplatePositionControl("y", "Y", -314),
    }
    NameplateDebuffs.SetPositionControls(nameplateDebuffPositionControls)
    UpdateNameplateDebuffUnlockButton()
    SyncNameplateDebuffPositionControls()

    local nameplateDebuffPendingText = nameplateRightPanel:CreateFontString(nil,
        "OVERLAY", "GameFontNormalSmall")
    nameplateDebuffPendingText:SetPoint("TOPLEFT", 0, -340)
    nameplateDebuffPendingText:SetPoint("TOPRIGHT", -4, -340)
    nameplateDebuffPendingText:SetJustifyH("LEFT")
    nameplateDebuffPendingText:SetTextColor(1, 0.78, 0.2)
    nameplateDebuffPendingText:SetText("正在应用新的技能 ID/尺寸设置…")
    NameplateDebuffs.SetPendingText(nameplateDebuffPendingText)
    UpdateNameplateDebuffPendingText()

    local function CloseNameplateSpellEditors()
        for _, row in ipairs(spellRows) do
            if row.editBox:HasFocus() then
                row.editBox:ClearFocus()
            end
        end
        newSpellDraftActive = false
        RefreshNameplateSpellRows()
    end

    local function CloseEditors()
        CloseCoordinateEditors(nameplateDebuffPositionControls)
        CloseNameplateSpellEditors()
        perRowControl:CloseEditor(true)
        squareSizeControl:CloseEditor(true)
    end

    return {
        page = secondPage,
        Refresh = function()
            nameplateEnabledCheckButton:SetChecked(nameplateDebuffSettings.enabled)
            RefreshNameplateSpellRows()
            RefreshNameplateDirectionText()
            noBuffColorButton:Refresh()
            hasBuffColorButton:Refresh()
            perRowControl:Refresh()
            squareSizeControl:Refresh()
            UpdateNameplateDebuffUnlockButton()
            UpdateNameplateDebuffPendingText()
            ClampNameplateDebuffPosition()
            SyncNameplateDebuffPositionControls()
        end,
        CloseEditors = CloseEditors,
        OnConfigHide = CloseEditors,
        SetPreviewShown = function(shown)
            NameplateDebuffs.SetConfigPreviewActive(shown)
        end,
    }
end

local function CreateMarkerAssignmentPage(content)
    local MarkerAssignment = ns.MarkerAssignment
    local MARKER_ASSIGNMENT_COUNT = MarkerAssignment.COUNT
    local MARKER_ASSIGNMENT_CHAT_PARTY_RAID = MarkerAssignment.CHAT_PARTY_RAID
    local MARKER_ASSIGNMENT_CHAT_INSTANCE = MarkerAssignment.CHAT_INSTANCE

    local thirdPage = CreateFrame("Frame", nil, content)
    thirdPage:SetAllPoints()

    local thirdPageTitle = thirdPage:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    thirdPageTitle:SetPoint("TOPLEFT", 4, -4)
    thirdPageTitle:SetText("标记分配")

    local markerSettings = MarkerAssignment.GetSettings()
    local markerEnabledCheckButton = CreateFrame("CheckButton", nil, thirdPage,
        "UICheckButtonTemplate")
    markerEnabledCheckButton:SetPoint("TOPLEFT", 0, -36)
    markerEnabledCheckButton:SetChecked(markerSettings.enabled)
    markerEnabledCheckButton:SetScript("OnClick", function(self)
        MarkerAssignment.SetEnabled(self:GetChecked())
    end)

    local markerEnabledLabel = thirdPage:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    markerEnabledLabel:SetPoint("LEFT", markerEnabledCheckButton, "RIGHT", 2, 0)
    markerEnabledLabel:SetText("开启")

    local markerOverwriteCheckButton = CreateFrame("CheckButton", nil, thirdPage,
        "UICheckButtonTemplate")
    markerOverwriteCheckButton:SetPoint("TOPLEFT", 120, -36)
    markerOverwriteCheckButton:SetChecked(markerSettings.overwriteExistingMarkers)
    markerOverwriteCheckButton:SetScript("OnClick", function(self)
        MarkerAssignment.SetOverwriteExistingMarkers(self:GetChecked())
    end)
    local markerOverwriteLabel = thirdPage:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    markerOverwriteLabel:SetPoint("LEFT", markerOverwriteCheckButton, "RIGHT", 2, 0)
    markerOverwriteLabel:SetText("覆盖已有标记")

    local markerHelpText = thirdPage:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    markerHelpText:SetPoint("TOPLEFT", 4, -76)
    markerHelpText:SetPoint("RIGHT", -4, 0)
    markerHelpText:SetJustifyH("LEFT")
    markerHelpText:SetText("点击图标可禁用或重新启用该标记。红色表示禁用，绿色表示当前分配。")

    local markerButtons = {}
    for marker = 1, MARKER_ASSIGNMENT_COUNT do
        local markerIndex = marker
        local button = CreateFrame("Button", nil, thirdPage)
        button:SetSize(44, 44)
        button:SetPoint("TOPLEFT", 4 + (marker - 1) * 50, -106)

        local background = CreateSolidTexture(button, "BACKGROUND", 0.075, 0.08, 0.10, 1)
        background:SetAllPoints()
        AddBorder(button, 1, 0.34, 0.36, 0.42, 1)

        local icon = button:CreateTexture(nil, "ARTWORK")
        icon:SetPoint("TOPLEFT", 4, -4)
        icon:SetPoint("BOTTOMRIGHT", -4, 4)
        icon:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_" .. marker)

        local assignedOverlay = CreateSolidTexture(button, "OVERLAY", 0.05, 0.85, 0.18, 0.42)
        assignedOverlay:SetAllPoints()
        assignedOverlay:Hide()
        button.assignedOverlay = assignedOverlay

        local disabledOverlay = CreateSolidTexture(button, "OVERLAY", 0.9, 0.05, 0.05, 0.52)
        disabledOverlay:SetAllPoints()
        disabledOverlay:Hide()
        button.disabledOverlay = disabledOverlay

        local assignedBorder = CreateFrame("Frame", nil, button)
        assignedBorder:SetAllPoints()
        assignedBorder:SetFrameLevel(button:GetFrameLevel() + 3)
        AddBorder(assignedBorder, 2, 0.15, 1, 0.25, 1)
        assignedBorder:Hide()
        button.assignedBorder = assignedBorder

        button:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
        button:SetScript("OnClick", function()
            MarkerAssignment.ToggleDisabled(markerIndex)
        end)
        button:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            local markerName = _G["RAID_TARGET_" .. markerIndex] or ("标记 " .. markerIndex)
            GameTooltip:SetText(markerName)
            if markerSettings.disabledMarkers[markerIndex] then
                GameTooltip:AddLine("已禁用；点击重新启用。", 1, 0.35, 0.35)
            else
                GameTooltip:AddLine("可用；点击禁用。", 0.75, 0.75, 0.75)
            end
            GameTooltip:Show()
        end)
        button:SetScript("OnLeave", GameTooltip_Hide)
        markerButtons[marker] = button
    end

    local markerCurrentText = thirdPage:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    markerCurrentText:SetPoint("TOPLEFT", 4, -170)
    markerCurrentText:SetText("当前分配：无")

    local markerChannelLabel = thirdPage:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    markerChannelLabel:SetPoint("TOPLEFT", 4, -204)
    markerChannelLabel:SetText("喊话频道")

    local markerChannelDropdown = CreateFrame("DropdownButton", nil, thirdPage,
        "WowStyle1DropdownTemplate")
    markerChannelDropdown:SetPoint("TOPLEFT", 106, -194)
    markerChannelDropdown:SetPoint("TOPRIGHT", -4, -194)
    markerChannelDropdown:SetupMenu(function(_, rootDescription)
        rootDescription:CreateRadio("小队 / 团队（自动）", function()
            return markerSettings.chatChannelMode == MARKER_ASSIGNMENT_CHAT_PARTY_RAID
        end, function()
            MarkerAssignment.SetChatChannelMode(MARKER_ASSIGNMENT_CHAT_PARTY_RAID)
        end)
        rootDescription:CreateRadio("副本", function()
            return markerSettings.chatChannelMode == MARKER_ASSIGNMENT_CHAT_INSTANCE
        end, function()
            MarkerAssignment.SetChatChannelMode(MARKER_ASSIGNMENT_CHAT_INSTANCE)
        end)
    end)

    local markerAllowInRaidCheckButton = CreateFrame("CheckButton", nil, thirdPage,
        "UICheckButtonTemplate")
    markerAllowInRaidCheckButton:SetPoint("TOPLEFT", 0, -236)
    markerAllowInRaidCheckButton:SetChecked(markerSettings.allowInRaid)
    markerAllowInRaidCheckButton:SetScript("OnClick", function(self)
        MarkerAssignment.SetAllowInRaid(self:GetChecked())
    end)

    local markerAllowInRaidLabel = thirdPage:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    markerAllowInRaidLabel:SetPoint("LEFT", markerAllowInRaidCheckButton, "RIGHT", 2, 0)
    markerAllowInRaidLabel:SetText("在团队中也执行标记和喊话")

    local markerChatTextLabel = thirdPage:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    markerChatTextLabel:SetPoint("TOPLEFT", 4, -280)
    markerChatTextLabel:SetText("喊话内容")
    local markerChatTextInput = CreateFrame("EditBox", nil, thirdPage, "InputBoxTemplate")
    markerChatTextInput:SetPoint("TOPLEFT", 112, -274)
    markerChatTextInput:SetPoint("TOPRIGHT", -4, -274)
    markerChatTextInput:SetHeight(26)
    markerChatTextInput:SetAutoFocus(false)
    markerChatTextInput:SetMaxBytes(MarkerAssignment.CHAT_TEXT_MAX_BYTES)
    markerChatTextInput:SetText(markerSettings.chatText)
    markerChatTextInput:SetScript("OnTextChanged", function(self, userInput)
        if userInput then MarkerAssignment.SetChatText(self:GetText()) end
    end)
    markerChatTextInput:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    markerChatTextInput:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    local markerStatusText = thirdPage:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    markerStatusText:SetPoint("TOPLEFT", 4, -314)
    markerStatusText:SetPoint("TOPRIGHT", -4, -314)
    markerStatusText:SetJustifyH("LEFT")
    markerStatusText:SetJustifyV("TOP")

    local markerMacroHelp = thirdPage:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    markerMacroHelp:SetPoint("TOPLEFT", 4, -352)
    markerMacroHelp:SetPoint("TOPRIGHT", -4, -352)
    markerMacroHelp:SetJustifyH("LEFT")
    markerMacroHelp:SetText("RRC 会在战斗外创建或更新账号通用宏 RRC-TM；关闭功能后保留宏的最后内容。")

    MarkerAssignment.SetControls({
        enabledCheckButton = markerEnabledCheckButton,
        markerButtons = markerButtons,
        chatChannelDropdown = markerChannelDropdown,
        allowInRaidCheckButton = markerAllowInRaidCheckButton,
        overwriteExistingMarkersCheckButton = markerOverwriteCheckButton,
        chatTextInput = markerChatTextInput,
    }, markerCurrentText, markerStatusText)

    return {
        page = thirdPage,
        Refresh = function()
            MarkerAssignment.RefreshUI()
        end,
        CloseEditors = function() markerChatTextInput:ClearFocus() end,
        OnConfigHide = function() markerChatTextInput:ClearFocus() end,
    }
end

local function CreateBigWigsBarHiderPage(content)
    local BigWigsBarHider = ns.BigWigsBarHider

    local fourthPage = CreateFrame("Frame", nil, content)
    fourthPage:SetAllPoints()

    local fourthPageTitle = fourthPage:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    fourthPageTitle:SetPoint("TOPLEFT", 4, -4)
    fourthPageTitle:SetText("隐藏bigwigs计时条")

    local bigwigsBarHiderEnabledCheckButton = CreateFrame("CheckButton", nil, fourthPage,
        "UICheckButtonTemplate")
    bigwigsBarHiderEnabledCheckButton:SetPoint("TOPLEFT", 0, -36)
    bigwigsBarHiderEnabledCheckButton:SetScript("OnClick", function(self)
        BigWigsBarHider.SetEnabled(self:GetChecked())
    end)
    local bigwigsBarHiderEnabledLabel = fourthPage:CreateFontString(nil,
        "OVERLAY", "GameFontHighlight")
    bigwigsBarHiderEnabledLabel:SetPoint("LEFT", bigwigsBarHiderEnabledCheckButton,
        "RIGHT", 2, 0)
    bigwigsBarHiderEnabledLabel:SetText("启用")

    local onlyInDungeonCheckButton = CreateFrame("CheckButton", nil, fourthPage,
        "UICheckButtonTemplate")
    onlyInDungeonCheckButton:SetPoint("TOPLEFT", bigwigsBarHiderEnabledCheckButton,
        "BOTTOMLEFT", 0, -8)
    onlyInDungeonCheckButton:SetScript("OnClick", function(self)
        BigWigsBarHider.SetOnlyInDungeon(self:GetChecked())
    end)
    local onlyInDungeonLabel = fourthPage:CreateFontString(nil,
        "OVERLAY", "GameFontHighlight")
    onlyInDungeonLabel:SetPoint("LEFT", onlyInDungeonCheckButton, "RIGHT", 2, 0)
    onlyInDungeonLabel:SetText("仅在地下城中关闭计时条")

    local exbossCheckButton = CreateFrame("CheckButton", nil, fourthPage,
        "UICheckButtonTemplate")
    exbossCheckButton:SetPoint("TOPLEFT", onlyInDungeonCheckButton,
        "BOTTOMLEFT", 0, -8)
    exbossCheckButton:SetScript("OnClick", function(self)
        BigWigsBarHider.SetHideExbossBarsInRaid(self:GetChecked())
    end)
    local exbossLabel = fourthPage:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    exbossLabel:SetPoint("LEFT", exbossCheckButton, "RIGHT", 2, 0)
    exbossLabel:SetText("团队副本中关闭EXBoss计时条")

    BigWigsBarHider.SetControls(bigwigsBarHiderEnabledCheckButton,
        onlyInDungeonCheckButton, exbossCheckButton)

    return {
        page = fourthPage,
        Refresh = function()
            BigWigsBarHider.RefreshUI()
        end,
    }
end

local function CreateMeetingStoneBlockerPage(content)
    local MeetingStoneBlocker = ns.MeetingStoneBlocker

    local fifthPage = CreateFrame("Frame", nil, content)
    fifthPage:SetAllPoints()

    local fifthPageTitle = fifthPage:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    fifthPageTitle:SetPoint("TOPLEFT", 4, -4)
    fifthPageTitle:SetText("集合石屏蔽")

    local outputButton = CreateFrame("Button", nil, fifthPage, "UIPanelButtonTemplate")
    outputButton:SetSize(180, 28)
    outputButton:SetPoint("TOPLEFT", 4, -38)
    outputButton:SetText("读取当前列表并输出")
    outputButton:SetScript("OnClick", function()
        MeetingStoneBlocker.OpenOutputWindow()
    end)

    local importButton = CreateFrame("Button", nil, fifthPage, "UIPanelButtonTemplate")
    importButton:SetSize(180, 28)
    importButton:SetPoint("TOPLEFT", outputButton, "BOTTOMLEFT", 0, -14)
    importButton:SetText("导入字符串")
    importButton:SetScript("OnClick", function()
        MeetingStoneBlocker.OpenImportWindow()
    end)

    local scriptHint = fifthPage:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    scriptHint:SetPoint("TOPLEFT", importButton, "BOTTOMLEFT", 0, -22)
    scriptHint:SetJustifyH("LEFT")
    scriptHint:SetText("打开魔兽目录外的 RRC 集合石助手（RRC_MS.exe），选择本批截图，识别后复制并导入字符串。")

    local statusLabel = fifthPage:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    statusLabel:SetPoint("TOPLEFT", scriptHint, "BOTTOMLEFT", 0, -24)
    statusLabel:SetJustifyH("LEFT")
    statusLabel:SetTextColor(1, 0.82, 0.20)

    local function UpdateTextWidths()
        local width = math.max(100, fifthPage:GetWidth() - 8)
        scriptHint:SetWidth(width)
        statusLabel:SetWidth(width)
    end
    fifthPage:SetScript("OnSizeChanged", UpdateTextWidths)
    UpdateTextWidths()

    MeetingStoneBlocker.SetStatusChanged(function(text)
        statusLabel:SetText(text)
    end)

    return {
        page = fifthPage,
        Refresh = function()
            statusLabel:SetText(MeetingStoneBlocker.GetStatus())
        end,
    }
end

local function CreateCooldownViewerSoundsPage(content)
    local CooldownViewerSounds = ns.CooldownViewerSounds
    local sixthPage = CreateFrame("Frame", nil, content)
    sixthPage:SetAllPoints()

    local enabledCheckButton = CreateFrame("CheckButton", nil, sixthPage, "UICheckButtonTemplate")
    enabledCheckButton:SetPoint("TOPLEFT", 0, -4)
    enabledCheckButton:SetScript("OnClick", function(self)
        CooldownViewerSounds.SetEnabled(self:GetChecked())
    end)

    local enabledLabel = sixthPage:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    enabledLabel:SetPoint("LEFT", enabledCheckButton, "RIGHT", 2, 0)
    enabledLabel:SetText("开启")

    return {
        page = sixthPage,
        Refresh = function()
            enabledCheckButton:SetChecked(CooldownViewerSounds.GetSettings().enabled)
        end,
    }
end

local function CreatePartyInterruptMonitorPage(content)
    local PartyInterruptMonitor = ns.PartyInterruptMonitor
    local settings = PartyInterruptMonitor.GetSettings()
    local size = PartyInterruptMonitor.SIZE
    local seventhPage = CreateFrame("Frame", nil, content)
    seventhPage:SetAllPoints()

    local leftPanel = CreateFrame("Frame", nil, seventhPage)
    leftPanel:SetPoint("TOPLEFT")
    leftPanel:SetPoint("BOTTOMLEFT")
    leftPanel:SetWidth(210)
    local rightPanel = CreateFrame("Frame", nil, seventhPage)
    rightPanel:SetPoint("TOPLEFT", leftPanel, "TOPRIGHT", 12, 0)
    rightPanel:SetPoint("BOTTOMRIGHT")

    local controls, positionControls = {}, {}
    local function RefreshPositionControls()
        PartyInterruptMonitor.ClampPosition()
        local minX, maxX, minY, maxY = PartyInterruptMonitor.GetPositionBounds()
        if positionControls.x then positionControls.x:SetRange(minX, maxX) end
        if positionControls.y then positionControls.y:SetRange(minY, maxY) end
    end
    local function RefreshDisplay()
        PartyInterruptMonitor.RefreshDisplay()
        RefreshPositionControls()
    end

    local enabledCheckButton = CreateFrame("CheckButton", nil, leftPanel, "UICheckButtonTemplate")
    enabledCheckButton:SetPoint("TOPLEFT", 0, -4)
    enabledCheckButton:SetScript("OnClick", function(self)
        PartyInterruptMonitor.SetEnabled(not not self:GetChecked())
        RefreshPositionControls()
    end)
    local enabledLabel = leftPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    enabledLabel:SetPoint("LEFT", enabledCheckButton, "RIGHT", 2, 0)
    enabledLabel:SetText("开启")

    local showRealmCheckButton = CreateFrame("CheckButton", nil, leftPanel, "UICheckButtonTemplate")
    showRealmCheckButton:SetPoint("TOPLEFT", 0, -44)
    showRealmCheckButton:SetScript("OnClick", function(self)
        settings.showRealmName = not not self:GetChecked()
        RefreshDisplay()
    end)
    local showRealmLabel = leftPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    showRealmLabel:SetPoint("LEFT", showRealmCheckButton, "RIGHT", 2, 0)
    showRealmLabel:SetText("显示角色服务器名")
    showRealmCheckButton:SetHitRectInsets(0, -showRealmLabel:GetStringWidth() - 2, 0, 0)

    local decimalPlacesLabel = leftPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    decimalPlacesLabel:SetPoint("TOPLEFT", 4, -96)
    decimalPlacesLabel:SetText("时间小数位数")
    local decimalPlacesDropdown = CreateFrame("DropdownButton", nil,
        leftPanel, "WowStyle1DropdownTemplate")
    decimalPlacesDropdown:SetPoint("TOPLEFT", 106, -86)
    decimalPlacesDropdown:SetPoint("TOPRIGHT", -4, -86)
    local function RefreshDecimalPlacesText()
        local text = settings.decimalPlaces .. " 位"
        if decimalPlacesDropdown.OverrideText then
            decimalPlacesDropdown:OverrideText(text)
        else
            decimalPlacesDropdown:SetDefaultText(text)
        end
    end
    decimalPlacesDropdown:SetupMenu(function(_, rootDescription)
        for decimalPlaces = 0, 2 do
            local value = decimalPlaces
            rootDescription:CreateRadio(value .. " 位", function()
                return settings.decimalPlaces == value
            end, function()
                settings.decimalPlaces = value
                RefreshDecimalPlacesText()
                RefreshDisplay()
            end)
        end
    end)

    local RefreshTextureDropdownText = CreateMediaDropdown(rightPanel,
        "条材质", -4, "statusbar", settings, "textureKey", PartyInterruptMonitor.DEFAULT_MEDIA_KEY,
        PartyInterruptMonitor.ValidateTextureKey, RefreshDisplay)
    local RefreshFontDropdownText = CreateMediaDropdown(rightPanel,
        "文字字体", -62, "font", settings, "fontKey", PartyInterruptMonitor.DEFAULT_MEDIA_KEY,
        PartyInterruptMonitor.ValidateFontKey, RefreshDisplay)

    local function AddSizeControl(labelText, offsetY, key, minimum, maximum)
        controls[#controls + 1] = CreateIntegerValueSlider(rightPanel,
            labelText, offsetY, minimum, maximum,
            function() return settings[key] end, function(value)
                settings[key] = value
                RefreshDisplay()
            end)
    end
    AddSizeControl("计时条长度", -118, "width", size.MIN_WIDTH, size.MAX_WIDTH)
    AddSizeControl("计时条高度", -166, "height", size.MIN_HEIGHT, size.MAX_HEIGHT)
    AddSizeControl("字体大小", -214, "fontSize", size.MIN_FONT_SIZE, size.MAX_FONT_SIZE)
    AddSizeControl("文字横坐标偏移", -262, "labelOffsetX", size.MIN_TEXT_OFFSET, size.MAX_TEXT_OFFSET)
    AddSizeControl("计时横坐标偏移", -310, "timerOffsetX", size.MIN_TEXT_OFFSET, size.MAX_TEXT_OFFSET)

    local positionLabel = leftPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    positionLabel:SetPoint("TOPLEFT", 4, -150)
    positionLabel:SetText("屏幕位置精确调整")
    local minX, maxX, minY, maxY = PartyInterruptMonitor.GetPositionBounds()
    local function AddPositionControl(axis, labelText, offsetY, minimum, maximum)
        local control = CreateIntegerValueSlider(leftPanel, labelText, offsetY, minimum, maximum,
            function() return settings[axis] end, function(value)
                PartyInterruptMonitor.SetCoordinate(axis, value)
                RefreshPositionControls()
            end)
        positionControls[axis] = control
        controls[#controls + 1] = control
    end
    AddPositionControl("x", "X", -182, minX, maxX)
    AddPositionControl("y", "Y", -238, minY, maxY)

    local function CloseEditors()
        for _, control in ipairs(controls) do control:CloseEditor(true) end
    end
    local function Refresh()
        enabledCheckButton:SetChecked(settings.enabled)
        showRealmCheckButton:SetChecked(settings.showRealmName)
        RefreshDecimalPlacesText()
        RefreshTextureDropdownText()
        RefreshFontDropdownText()
        RefreshPositionControls()
        for _, control in ipairs(controls) do control:Refresh() end
    end
    seventhPage:SetScript("OnShow", Refresh)
    seventhPage:SetScript("OnSizeChanged", RefreshPositionControls)
    Refresh()

    return {
        page = seventhPage,
        Refresh = Refresh,
        CloseEditors = CloseEditors,
        OnConfigHide = CloseEditors,
    }
end

local function CreateAutoInvitePage(content)
    local AutoInvite = ns.AutoInvite
    local settings = AutoInvite.GetSettings()
    local page = CreateFrame("Frame", nil, content)
    page:SetAllPoints()

    local title = page:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    title:SetPoint("TOPLEFT", 4, -4)
    title:SetText("自动邀请")

    local enabledCheckButton = CreateFrame("CheckButton", nil, page, "UICheckButtonTemplate")
    enabledCheckButton:SetPoint("TOPLEFT", 0, -34)
    enabledCheckButton:SetScript("OnClick", function(self)
        AutoInvite.SetEnabled(self:GetChecked())
    end)
    local enabledLabel = page:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    enabledLabel:SetPoint("LEFT", enabledCheckButton, "RIGHT", 2, 0)
    enabledLabel:SetText("启用")

    local channelButtons = {}
    local channels = {
        { event = "CHAT_MSG_WHISPER", label = "角色密语", x = 0 },
        { event = "CHAT_MSG_BN_WHISPER", label = "战网好友密语", x = 110 },
        { event = "CHAT_MSG_GUILD", label = "公会", x = 260 },
    }
    for _, channel in ipairs(channels) do
        local event = channel.event
        local button = CreateFrame("CheckButton", nil, page, "UICheckButtonTemplate")
        button:SetPoint("TOPLEFT", channel.x, -72)
        button:SetChecked(settings.channels[event])
        button:SetScript("OnClick", function(self)
            AutoInvite.SetChannelEnabled(event, self:GetChecked())
        end)
        local label = page:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        label:SetPoint("LEFT", button, "RIGHT", 2, 0)
        label:SetText(channel.label)
        channelButtons[event] = button
    end

    local hint = page:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", 4, -114)
    hint:SetPoint("TOPRIGHT", -4, -114)
    hint:SetJustifyH("LEFT")
    hint:SetWordWrap(true)
    hint:SetText("监视角色密语、战网好友密语和公会聊天。内容须完整匹配任意一条字符串，区分大小写及空格；空输入框不匹配。修改即时保存。")

    local scrollFrame = CreateFrame("ScrollFrame", nil, page, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 4, -12)
    scrollFrame:SetPoint("TOPRIGHT", hint, "BOTTOMRIGHT", -26, -12)
    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetSize(1, 1)
    scrollFrame:SetScrollChild(scrollChild)
    local rows = {}
    local RefreshRows
    local exportOutput

    local function CloseEditors()
        for _, row in ipairs(rows) do
            row.editBox:ClearFocus()
        end
        if exportOutput then exportOutput:ClearFocus() end
    end

    local addButton = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
    addButton:SetSize(120, 24)
    addButton:SetPoint("TOPLEFT", scrollFrame, "BOTTOMLEFT", -4, -8)
    addButton:SetText("添加字符串")

    local exportButton = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
    exportButton:SetSize(120, 24)
    exportButton:SetPoint("TOPLEFT", addButton, "BOTTOMLEFT", 0, -8)
    exportButton:SetText("导出密语")
    local exportHint = page:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    exportHint:SetPoint("TOPLEFT", exportButton, "BOTTOMLEFT", 0, -8)
    exportHint:SetPoint("RIGHT", page, "RIGHT", -4, 0)
    exportHint:SetJustifyH("LEFT")
    exportHint:SetWordWrap(true)
    exportHint:SetText("点击导出密语以快捷复制匹配首个字符串的密语")

    exportOutput = CreateFrame("EditBox", nil, page, "InputBoxTemplate")
    exportOutput:SetPoint("TOPLEFT", exportHint, "BOTTOMLEFT", 6, -10)
    exportOutput:SetPoint("TOPRIGHT", exportHint, "BOTTOMRIGHT", -4, -10)
    exportOutput:SetHeight(26)
    exportOutput:SetAutoFocus(false)
    exportOutput:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    exportOutput:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    exportOutput:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    exportButton:SetScript("OnClick", function()
        CloseEditors()
        local text, errorMessage = AutoInvite.GetExportText()
        exportOutput:SetText(text or "")
        if not text then
            print("|cff33ff99RRC 自动邀请：|r" .. errorMessage)
            return
        end
        exportOutput:SetFocus()
        exportOutput:HighlightText()
    end)

    local function RefreshExportState()
        exportButton:SetEnabled(settings.strings[1] ~= nil and settings.strings[1] ~= "")
        -- 列表变化后清空旧结果，避免复制已经失效的触发字符串。
        exportOutput:SetText("")
    end

    local function UpdateLayout()
        local width = math.max(1, scrollFrame:GetWidth())
        scrollChild:SetWidth(width)
        local height = math.min(math.max(36, #settings.strings * 36),
            math.max(36, page:GetHeight() - hint:GetStringHeight() - exportHint:GetStringHeight() - 252))
        scrollFrame:SetHeight(height)
        scrollChild:SetHeight(math.max(1, #settings.strings * 36))
        scrollFrame:SetVerticalScroll(math.min(scrollFrame:GetVerticalScroll(),
            math.max(0, #settings.strings * 36 - height)))
    end
    page:SetScript("OnSizeChanged", UpdateLayout)

    local function EnsureRow(index)
        if rows[index] then return rows[index] end
        local row = CreateFrame("Frame", nil, scrollChild)
        row:SetHeight(36)
        row:SetPoint("TOPLEFT", 0, -(index - 1) * 36)
        row:SetPoint("TOPRIGHT", 0, -(index - 1) * 36)
        local label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetPoint("LEFT", 0, 0)
        label:SetWidth(28)
        label:SetText(tostring(index))

        local deleteButton = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        deleteButton:SetSize(48, 24)
        deleteButton:SetPoint("RIGHT")
        deleteButton:SetText("删除")

        local editBox = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
        editBox:SetPoint("LEFT", label, "RIGHT", 4, 0)
        editBox:SetPoint("RIGHT", deleteButton, "LEFT", -8, 0)
        editBox:SetHeight(26)
        editBox:SetAutoFocus(false)
        editBox:SetMaxBytes(255)
        editBox:SetScript("OnTextChanged", function(self, userInput)
            if userInput then
                settings.strings[index] = self:GetText()
                RefreshExportState()
            end
        end)
        editBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
        editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        row.editBox = editBox
        deleteButton:SetScript("OnClick", function()
            CloseEditors()
            table.remove(settings.strings, index)
            RefreshRows()
        end)
        rows[index] = row
        return row
    end

    RefreshRows = function()
        for index = 1, #settings.strings do
            local row = EnsureRow(index)
            if not row.editBox:HasFocus() then
                row.editBox:SetText(settings.strings[index])
            end
            row:Show()
        end
        for index = #settings.strings + 1, #rows do
            rows[index]:Hide()
        end
        RefreshExportState()
        UpdateLayout()
    end
    addButton:SetScript("OnClick", function()
        CloseEditors()
        settings.strings[#settings.strings + 1] = ""
        RefreshRows()
        scrollFrame:SetVerticalScroll(math.max(0, scrollChild:GetHeight() - scrollFrame:GetHeight()))
        rows[#settings.strings].editBox:SetFocus()
    end)

    return {
        page = page,
        Refresh = function()
            enabledCheckButton:SetChecked(settings.enabled)
            for event, button in pairs(channelButtons) do
                button:SetChecked(settings.channels[event])
            end
            RefreshRows()
        end,
        CloseEditors = CloseEditors,
        OnConfigHide = CloseEditors,
    }
end

local function CreateConfigFrame()
    local frame = CreateFrame("Frame", FRAME_NAME, UIParent)
    configFrame = frame

    frame:SetFrameStrata("DIALOG")
    frame:SetToplevel(true)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:SetPoint("CENTER")
    frame:Hide()

    local background = CreateSolidTexture(frame, "BACKGROUND", 0.045, 0.05, 0.065, 0.98)
    background:SetAllPoints()
    AddBorder(frame, 1, 0.34, 0.36, 0.42, 1)

    local header = CreateFrame("Frame", nil, frame)
    header:SetPoint("TOPLEFT", 1, -1)
    header:SetPoint("TOPRIGHT", -1, -1)
    header:SetHeight(42)
    header:EnableMouse(true)
    header:RegisterForDrag("LeftButton")
    header:SetScript("OnDragStart", function()
        frame:StartMoving()
    end)
    header:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
    end)

    local headerBackground = CreateSolidTexture(header, "BACKGROUND", 0.09, 0.10, 0.13, 1)
    headerBackground:SetAllPoints()

    local title = header:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("LEFT", 16, 0)
    title:SetText("ReRan's Customlizations")

    local closeButton = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    closeButton:SetPoint("TOPRIGHT", -5, -5)
    closeButton:SetScript("OnClick", function()
        frame:Hide()
    end)

    local sidebar = CreateFrame("Frame", nil, frame)
    sidebar:SetPoint("TOPLEFT", 12, -54)
    sidebar:SetPoint("BOTTOMLEFT", 12, 12)

    local sidebarBackground = CreateSolidTexture(sidebar, "BACKGROUND", 0.075, 0.08, 0.10, 0.92)
    sidebarBackground:SetAllPoints()

    local divider = CreateSolidTexture(frame, "BORDER", 0.25, 0.27, 0.32, 1)
    divider:SetPoint("TOPLEFT", sidebar, "TOPRIGHT", 8, 0)
    divider:SetPoint("BOTTOMLEFT", sidebar, "BOTTOMRIGHT", 8, 0)
    divider:SetWidth(1)

    local content = CreateFrame("Frame", nil, frame)
    content:SetPoint("TOPLEFT", divider, "TOPRIGHT", 18, 0)
    content:SetPoint("BOTTOMRIGHT", -18, 16)

    if ColorPickerFrame and not colorPickerHooked then
        ColorPickerFrame:HookScript("OnHide", function()
            colorPickerOwned = false
        end)
        colorPickerHooked = true
    end

    -- 保留禁用分类的位置，但不创建依赖未加载模块的配置页面。
    local function CreateDisabledPage()
        local page = CreateFrame("Frame", nil, content)
        page:SetAllPoints()
        page:Hide()
        return { page = page, disabled = true }
    end

    local pages = {
        ns.IsForever and CreateDisabledPage() or CreateAutoburnPage(content),
        CreateNameplateDebuffPage(content),
        CreateMarkerAssignmentPage(content),
        CreateBigWigsBarHiderPage(content),
        ns.IsForever and CreateDisabledPage() or CreateMeetingStoneBlockerPage(content),
        CreateCooldownViewerSoundsPage(content),
        CreatePartyInterruptMonitorPage(content),
        CreateAutoInvitePage(content),
    }
    local categoryButtons = {}
    local selectedCategoryIndex = ns.IsForever and 2 or 1

    local function SelectCategory(selectedIndex)
        if pages[selectedIndex].disabled then return end
        selectedCategoryIndex = selectedIndex
        for index, pageHandler in ipairs(pages) do
            if index ~= selectedIndex and pageHandler.CloseEditors then
                pageHandler.CloseEditors()
            end
        end

        for index = 1, #categoryButtons do
            local isSelected = index == selectedIndex
            categoryButtons[index].selectedBackground:SetShown(isSelected)

            if isSelected then
                categoryButtons[index].label:SetTextColor(1, 1, 1)
                pages[index].page:Show()
            else
                if pages[index].disabled then
                    categoryButtons[index].label:SetTextColor(0.35, 0.35, 0.35)
                else
                    categoryButtons[index].label:SetTextColor(0.72, 0.74, 0.78)
                end
                pages[index].page:Hide()
            end
        end

        for index, pageHandler in ipairs(pages) do
            if pageHandler.SetPreviewShown then
                pageHandler.SetPreviewShown(frame:IsShown() and selectedIndex == index)
            end
        end
    end

    local categoryNames = {
        "1. DK沸点监测",
        "2. 姓名版 Debuff 监测",
        "3.标记分配",
        "4.隐藏bigwigs计时条",
        "5.集合石屏蔽",
        "6.自定义冷却管理器音效",
        "7.队友打断监视",
        "8.自动邀请",
    }

    for index, categoryName in ipairs(categoryNames) do
        local categoryIndex = index
        local button = CreateFrame("Button", nil, sidebar)
        button:SetHeight(38)
        button:SetPoint("LEFT", 8, 0)
        button:SetPoint("RIGHT", -8, 0)

        if index == 1 then
            button:SetPoint("TOP", 0, -8)
        else
            button:SetPoint("TOP", categoryButtons[index - 1], "BOTTOM", 0, -4)
        end

        local selectedBackground = CreateSolidTexture(button, "BACKGROUND", 0.34, 0.35, 0.38, 0.82)
        selectedBackground:SetAllPoints()
        selectedBackground:Hide()
        button.selectedBackground = selectedBackground

        local highlight = CreateSolidTexture(button, "HIGHLIGHT", 0.24, 0.25, 0.28, 0.55)
        highlight:SetAllPoints()

        local label = button:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        label:SetPoint("LEFT", 10, 0)
        label:SetPoint("RIGHT", -8, 0)
        label:SetJustifyH("LEFT")
        label:SetText(categoryName)
        button.label = label

        button:SetEnabled(not pages[index].disabled)
        button:SetScript("OnClick", function()
            SelectCategory(categoryIndex)
        end)

        categoryButtons[index] = button
    end

    local function UpdateFrameSize()
        local width, height = CalculateFrameSize()
        frame:SetSize(width, height)
        sidebar:SetWidth(math.max(160, math.min(220, width * 0.28)))
    end

    frame:SetScript("OnShow", function(self)
        for _, pageHandler in ipairs(pages) do
            if pageHandler.Refresh then
                pageHandler.Refresh()
            end
        end
        UpdateFrameSize()
        SelectCategory(selectedCategoryIndex)
        self:Raise()
    end)
    frame:SetScript("OnHide", function()
        for _, pageHandler in ipairs(pages) do
            if pageHandler.OnConfigHide then
                pageHandler.OnConfigHide()
            end
        end
        if colorPickerOwned and ColorPickerFrame and ColorPickerFrame:IsShown() then
            ColorPickerFrame:Hide()
        end
        colorPickerOwned = false
        for _, pageHandler in ipairs(pages) do
            if pageHandler.SetPreviewShown then
                pageHandler.SetPreviewShown(false)
            end
        end
    end)
    frame:RegisterEvent("DISPLAY_SIZE_CHANGED")
    frame:RegisterEvent("UI_SCALE_CHANGED")
    frame:SetScript("OnEvent", UpdateFrameSize)

    UpdateFrameSize()
    SelectCategory(selectedCategoryIndex)
    table.insert(UISpecialFrames, FRAME_NAME)

    return frame
end
bootFrame:RegisterEvent("ADDON_LOADED")
bootFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local loadedAddonName = ...
        if loadedAddonName ~= ADDON_NAME then
            return
        end

        self:UnregisterEvent("ADDON_LOADED")
        self:RegisterEvent("DISPLAY_SIZE_CHANGED")
        self:RegisterEvent("UI_SCALE_CHANGED")
        InitializeDatabase()
        if not ns.IsForever then
            ns.Autoburn.SetMonitoringEnabled(ns.Autoburn.GetSettings().enabled)
        end
        ns.NameplateDebuffs.SetMonitoringEnabled(ns.NameplateDebuffs.GetSettings().enabled)
        ns.MarkerAssignment.Initialize()
        ns.BigWigsBarHider.Initialize()
        ns.CooldownViewerSounds.Initialize()
        ns.PartyInterruptMonitor.Initialize()
        ns.AutoInvite.Initialize()
    elseif event == "DISPLAY_SIZE_CHANGED" or event == "UI_SCALE_CHANGED" then
        if not ns.IsForever then
            ns.Autoburn.OnDisplayChanged()
        end
        ns.NameplateDebuffs.OnDisplayChanged()
        ns.PartyInterruptMonitor.OnDisplayChanged()
    end
end)

SLASH_RERANSCUSTOMLIZATIONS1 = "/rrc"
SlashCmdList.RERANSCUSTOMLIZATIONS = function()
    local frame = configFrame or CreateConfigFrame()

    if frame:IsShown() then
        frame:Hide()
    else
        frame:Show()
    end
end
