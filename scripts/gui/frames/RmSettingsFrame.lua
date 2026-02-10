--[[
    RmSettingsFrame.lua
    Settings frame with clone-based ScrollingLayout for fillType rows.
]]

RmSettingsFrame = {}
local RmSettingsFrame_mt = Class(RmSettingsFrame, TabbedMenuFrameElement)

local Log = RmLogging.getLogger("Fresh")

local modDirectory = g_currentModDirectory

-- =============================================================================
-- CONSTANTS
-- =============================================================================

--- Sub-category page indices
RmSettingsFrame.SUB_CATEGORY = { SETTINGS = 1, EXPIRATION = 2, DLCMOD = 3 }

--- Preset option names (matches RmFreshSettings.PRESET_NAMES order)
RmSettingsFrame.PRESET_OPTIONS = { "veryEasy", "easy", "normal", "hard", "custom" }

--- Warning hours options for MultiTextOption selector
RmSettingsFrame.WARNING_HOURS_OPTIONS = {
    { hours = 6,  label = "fresh_warning_6h" },
    { hours = 12, label = "fresh_warning_12h" },
    { hours = 24, label = "fresh_warning_24h" },
    { hours = 48, label = "fresh_warning_48h" },
    { hours = 72, label = "fresh_warning_72h" },
}

--- Expiration period options for MultiTextOption selectors
--- Index 1 = "Do not expire", subsequent indices = periods in months
RmSettingsFrame.EXPIRATION_OPTIONS = {
    { expires = false, label = "fresh_expire_never" },
    { period = 1.0,    label = "fresh_expire_1_month" },
    { period = 2.0,    label = "fresh_expire_2_months" },
    { period = 3.0,    label = "fresh_expire_3_months" },
    { period = 4.0,    label = "fresh_expire_4_months" },
    { period = 5.0,    label = "fresh_expire_5_months" },
    { period = 6.0,    label = "fresh_expire_6_months" },
    { period = 9.0,    label = "fresh_expire_9_months" },
    { period = 12.0,   label = "fresh_expire_1_year" },
    { period = 18.0,   label = "fresh_expire_1_5_years" },
    { period = 24.0,   label = "fresh_expire_2_years" },
    { period = 36.0,   label = "fresh_expire_3_years" },
    { period = 60.0,   label = "fresh_expire_5_years" },
}

--- Map period values to EXPIRATION_OPTIONS indices for quick lookup
RmSettingsFrame.PERIOD_TO_INDEX = {}

--- Data arrays for fillType rows (class-level, rebuilt each onFrameOpen)
RmSettingsFrame.basegameFillTypes = nil
RmSettingsFrame.dlcmodFillTypes = nil

--- Suppression flag to prevent callbacks during programmatic refresh
RmSettingsFrame.isRefreshing = false

--- Reference to the currently DISPLAYED frame instance
--- Updated in onFrameOpen, cleared in onFrameClose
--- Used by sync events to refresh the visible UI
RmSettingsFrame.displayedInstance = nil

--- Pending fillType changes accumulated during user interaction
--- Flushed on frame close. Key: fillTypeName, Value: { action, value }
RmSettingsFrame.pendingFillTypeChanges = {}

--- Currently active sub-category tab index
RmSettingsFrame.currentSubCategory = 1

-- =============================================================================
-- CONSTRUCTOR
-- =============================================================================

function RmSettingsFrame.new()
    local self = RmSettingsFrame:superClass().new(nil, RmSettingsFrame_mt)
    self.name = "RmSettingsFrame"
    self.isEvenRow = true
    self.sc2Populated = false
    self.sc3Populated = false
    return self
end

function RmSettingsFrame.setupGui()
    local frame = RmSettingsFrame.new()
    g_gui:loadGui(
        Utils.getFilename("gui/settingsFrame.xml", modDirectory),
        "RmSettingsFrame",
        frame,
        true
    )
    Log:debug("RmSettingsFrame.setupGui() complete")
end

-- =============================================================================
-- LIFECYCLE
-- =============================================================================

function RmSettingsFrame:onGuiSetupFinished()
    RmSettingsFrame:superClass().onGuiSetupFinished(self)

    -- Setup presetSelector texts
    if self.presetSelector then
        local presetTexts = {}
        for _, presetName in ipairs(RmSettingsFrame.PRESET_OPTIONS) do
            table.insert(presetTexts, g_i18n:getText("fresh_preset_" .. presetName))
        end
        self.presetSelector:setTexts(presetTexts)
    end

    -- Setup warningHoursSelector texts
    if self.warningHoursSelector then
        local texts = {}
        for _, opt in ipairs(RmSettingsFrame.WARNING_HOURS_OPTIONS) do
            table.insert(texts, g_i18n:getText(opt.label))
        end
        self.warningHoursSelector:setTexts(texts)
    end

    -- Build period-to-index lookup map
    self:buildPeriodToIndexMap()

    -- Initialize menu buttons (back + reset to defaults)
    self:initializeMenuButtons()
end

--- Initialize menu button info for bottom bar
function RmSettingsFrame:initializeMenuButtons()
    self.backButtonInfo = {
        inputAction = InputAction.MENU_BACK
    }

    self.resetButtonInfo = {
        inputAction = InputAction.MENU_EXTRA_1,
        text = g_i18n:getText("fresh_settings_resetDefaults"),
        callback = function()
            self:onResetDefaults()
        end
    }

    self:updateMenuButtons()
end

--- Update menu buttons array based on current state
--- Reset button shown only for admins
function RmSettingsFrame:updateMenuButtons()
    self.menuButtonInfo = {
        self.backButtonInfo
    }

    if self:isAdmin() then
        table.insert(self.menuButtonInfo, self.resetButtonInfo)
    end
end

function RmSettingsFrame:onFrameOpen()
    RmSettingsFrame:superClass().onFrameOpen(self)

    RmSettingsFrame.displayedInstance = self
    RmSettingsFrame.pendingFillTypeChanges = {}

    -- Build fillType data arrays (rebuilt each open to catch late DLC/mod fillTypes)
    self:buildFillTypeData()
    self.optionTexts = self:buildOptionTexts()

    -- Initialize sub-category pages
    self:initializeSubCategoryPages()

    -- Populate cloned pages (first open only)
    if not self.sc2Populated then
        self:populateSc2()
    end
    if not self.sc3Populated then
        self:populateSc3()
    end

    -- Load current settings values into all controls
    self:refreshData()

    -- Disable controls for non-admin clients
    self:updateReadonlyState()

    -- Update menu buttons (show Reset for admins)
    self:updateMenuButtons()
    self:setMenuButtonInfoDirty()

    -- Show first tab
    self.subCategoryPaging:setState(RmSettingsFrame.SUB_CATEGORY.SETTINGS, true)
end

function RmSettingsFrame:onFrameClose()
    -- Flush pending fillType changes before closing
    if next(RmSettingsFrame.pendingFillTypeChanges) then
        local count = 0
        for _ in pairs(RmSettingsFrame.pendingFillTypeChanges) do count = count + 1 end
        Log:debug("SETT FLUSH: applying %d pending fillType changes", count)

        if g_server then
            RmFreshSettings:applyBatchChanges(RmSettingsFrame.pendingFillTypeChanges)
        else
            for fillTypeName, change in pairs(RmSettingsFrame.pendingFillTypeChanges) do
                if RmSettingsChangeRequestEvent then
                    g_client:getServerConnection():sendEvent(
                        RmSettingsChangeRequestEvent.new(change.action, fillTypeName, change.value)
                    )
                end
            end
        end
        RmSettingsFrame.pendingFillTypeChanges = {}
    end

    RmSettingsFrame:superClass().onFrameClose(self)

    if RmSettingsFrame.displayedInstance == self then
        RmSettingsFrame.displayedInstance = nil
    end
end

-- =============================================================================
-- SUB-CATEGORY TABS
-- =============================================================================

--- Initialize sub-category tab pages (FS25 InGameMenuSettingsFrame pattern)
function RmSettingsFrame:initializeSubCategoryPages()
    local subCategories = {}

    -- Hide DLC & Mods tab when no DLC/mod fillTypes exist
    local hideDlcTab = #(RmSettingsFrame.dlcmodFillTypes or {}) == 0

    for index, button in ipairs(self.subCategoryTabs) do
        local visible = not (index == RmSettingsFrame.SUB_CATEGORY.DLCMOD and hideDlcTab)

        -- Make tab background respond to selection state
        button:getDescendantByName("background").getIsSelected = function()
            return index == tonumber(self.subCategoryPaging.texts[self.subCategoryPaging:getState()])
        end

        -- Make tab button respond to selection state
        function button.getIsSelected()
            return index == tonumber(self.subCategoryPaging.texts[self.subCategoryPaging:getState()])
        end

        button:setVisible(visible)
        if visible then
            table.insert(subCategories, tostring(index))
        end
    end

    -- Configure paging selector
    self.subCategoryBox:invalidateLayout()
    self.subCategoryPaging:setTexts(subCategories)
    self.subCategoryPaging:setSize(self.subCategoryBox.maxFlowSize + 140 * g_pixelSizeScaledX)
end

-- =============================================================================
-- FILLTYPE DATA BUILDING
-- =============================================================================

--- Build categorized fillType data arrays for fillType rows
--- Called each onFrameOpen to catch late-registered DLC/mod fillTypes
function RmSettingsFrame:buildFillTypeData()
    local allFillTypes = self:getPerishableFillTypes()
    RmSettingsFrame.basegameFillTypes = {}
    RmSettingsFrame.dlcmodFillTypes = {}

    for _, ft in ipairs(allFillTypes) do
        if self:isBasegameFillType(ft.name) then
            table.insert(RmSettingsFrame.basegameFillTypes, ft)
        else
            table.insert(RmSettingsFrame.dlcmodFillTypes, ft)
        end
    end

    Log:debug("SETT DATA: Categorized %d fillTypes - %d basegame, %d DLC/mod",
        #allFillTypes, #RmSettingsFrame.basegameFillTypes, #RmSettingsFrame.dlcmodFillTypes)
end

--- Detect fillType origin using source tracking hooks
--- Falls back to hudOverlayFilename heuristic if hooks missed the fillType
---@param fillTypeName string
---@return boolean True if basegame fillType
function RmSettingsFrame:isBasegameFillType(fillTypeName)
    local source = RmFreshSettings:getFillTypeSource(fillTypeName)
    return source == "basegame"
end

--- Get list of ALL visible fillTypes sorted alphabetically
---@return table Array of { name = string, title = string, expires = boolean }
function RmSettingsFrame:getPerishableFillTypes()
    local fillTypes = {}
    local hiddenCount = 0

    for fillTypeName, fillTypeData in pairs(RmFreshSettings.allFillTypes or {}) do
        if fillTypeName ~= "UNKNOWN" and RmFreshSettings:isHidden(fillTypeName) then
            hiddenCount = hiddenCount + 1
        elseif fillTypeName ~= "UNKNOWN" then
            local expiration = RmFreshSettings:getExpiration(fillTypeName)

            local source, modName = RmFreshSettings:getFillTypeSource(fillTypeName)
            table.insert(fillTypes, {
                name = fillTypeName,
                title = fillTypeData.title or fillTypeName,
                expires = expiration ~= nil,
                source = source,
                sourceMod = modName,
            })
        end
    end

    Log:debug("SETTINGS_UI: %d fillTypes visible, %d hidden", #fillTypes, hiddenCount)

    -- Sort alphabetically by title
    table.sort(fillTypes, function(a, b)
        return a.title:lower() < b.title:lower()
    end)

    return fillTypes
end

--- Build the expiration option text labels
---@return table Array of localized strings
function RmSettingsFrame:buildOptionTexts()
    local texts = {}
    for _, opt in ipairs(RmSettingsFrame.EXPIRATION_OPTIONS) do
        table.insert(texts, g_i18n:getText(opt.label))
    end
    return texts
end

--- Build tooltip text for a fillType row
---@param fillTypeName string The internal fillType name (e.g., "WHEAT")
---@return string Tooltip text
function RmSettingsFrame:buildFillTypeTooltip(fillTypeName)
    local parts = {}
    table.insert(parts, string.format("Fill type: %s", fillTypeName))

    -- Show source origin
    local source, modName = RmFreshSettings:getFillTypeSource(fillTypeName)
    if source == "dlc" and modName then
        table.insert(parts, string.format("Source: DLC (%s)", modName))
    elseif source == "mod" and modName then
        table.insert(parts, string.format("Source: Mod (%s)", modName))
    elseif source == "map" then
        table.insert(parts, "Source: Map")
    elseif source == "basegame" then
        table.insert(parts, "Source: Base game")
    end

    return table.concat(parts, " | ")
end

--- Build period-to-index lookup map from EXPIRATION_OPTIONS
function RmSettingsFrame:buildPeriodToIndexMap()
    RmSettingsFrame.PERIOD_TO_INDEX = {}
    for i, opt in ipairs(RmSettingsFrame.EXPIRATION_OPTIONS) do
        if opt.period then
            RmSettingsFrame.PERIOD_TO_INDEX[opt.period] = i
        end
    end
end

--- Get the option index for a fillType's current expiration setting
---@param fillTypeName string The fillType name
---@return number Option index (1 = never, 2+ = periods)
function RmSettingsFrame:getOptionIndexForFillType(fillTypeName)
    local expiration = RmFreshSettings:getExpiration(fillTypeName)
    if expiration == nil then
        return 1 -- "Do not expire"
    end
    -- Round to 1 decimal place to avoid floating point precision issues
    local roundedExpiration = math.floor(expiration * 10 + 0.5) / 10
    local index = RmSettingsFrame.PERIOD_TO_INDEX[roundedExpiration]
    if index == nil then
        Log:debug("SETT: %s expiration=%.2f (rounded=%.1f) not in PERIOD_TO_INDEX -> index=1",
            fillTypeName, expiration, roundedExpiration)
        return 1
    end
    return index
end

--- Find the warning hours selector state for a given hours value
---@param hours number Warning hours value
---@return number Selector state index
function RmSettingsFrame:findWarningHoursState(hours)
    for i, opt in ipairs(RmSettingsFrame.WARNING_HOURS_OPTIONS) do
        if opt.hours == hours then
            return i
        end
    end
    return 3 -- Default to 24h (index 3)
end

-- =============================================================================
-- PRESET CONTROL
-- =============================================================================

--- Check if a fillType is fully controlled by the active preset
--- (preset active AND has mod default AND no user override)
---@param fillTypeName string
---@return boolean
function RmSettingsFrame:isPresetControlled(fillTypeName)
    local preset = RmFreshSettings:getGlobal("preset") or "custom"
    if preset == "custom" then return false end
    local hasModDefault = RmFreshSettings.modDefaults[fillTypeName] ~= nil
    local hasUserOverride = RmFreshSettings.userOverrides.fillTypes[fillTypeName] ~= nil
    return hasModDefault and not hasUserOverride
end

-- =============================================================================
-- DATA REFRESH
-- =============================================================================

--- Load current settings values into all UI controls
--- Called on frame open and after sync events
function RmSettingsFrame:refreshData()
    RmSettingsFrame.isRefreshing = true

    -- SC1: Global settings controls (BinaryOption: 1=off, 2=on)
    if self.checkEnableExpiration then
        local state = (RmFreshSettings:getGlobal("enableExpiration") ~= false) and 2 or 1
        self.checkEnableExpiration:setState(state)
    end
    if self.checkShowWarnings then
        local state = (RmFreshSettings:getGlobal("showWarnings") ~= false) and 2 or 1
        self.checkShowWarnings:setState(state)
    end
    if self.checkShowAgeDisplay then
        local state = (RmFreshSettings:getGlobal("showAgeDisplay") ~= false) and 2 or 1
        self.checkShowAgeDisplay:setState(state)
    end
    if self.warningHoursSelector then
        local currentHours = RmFreshSettings:getWarningHours()
        self.warningHoursSelector:setState(self:findWarningHoursState(currentHours))
    end
    if self.presetSelector then
        local currentPreset = RmFreshSettings:getGlobal("preset") or "custom"
        for i, name in ipairs(RmSettingsFrame.PRESET_OPTIONS) do
            if name == currentPreset then
                self.presetSelector:setState(i)
                break
            end
        end
    end

    -- SC2/SC3: FillType row visibility and selector states
    local sc2Visible = self:refreshFillTypeRows(self.sc2Rows)
    local sc3Visible = self:refreshFillTypeRows(self.sc3Rows)

    -- Toggle empty-state messages
    if self.sc2NoRowsMsg then self.sc2NoRowsMsg:setVisible(sc2Visible == 0) end
    if self.sc3NoRowsMsg then self.sc3NoRowsMsg:setVisible(sc3Visible == 0) end

    -- Invalidate layouts so ScrollingLayout recalculates after row visibility changes
    if self.sc2Layout then self.sc2Layout:invalidateLayout() end
    if self.sc3Layout then self.sc3Layout:invalidateLayout() end

    RmSettingsFrame.isRefreshing = false
end

--- Refresh fillType row visibility and selector states from current settings
--- Hides entire rows that are preset-controlled, re-applies alternating colors for visible rows
---@param rows table|nil Array of { row, multiOption, fillTypeName }
---@return number Number of visible rows
function RmSettingsFrame:refreshFillTypeRows(rows)
    if not rows then return 0 end

    local visibleIndex = 0
    for _, rowData in ipairs(rows) do
        if rowData and rowData.fillTypeName then
            local isPreset = self:isPresetControlled(rowData.fillTypeName)

            if isPreset then
                rowData.row:setVisible(false)
            else
                rowData.row:setVisible(true)
                visibleIndex = visibleIndex + 1

                -- Update selector state
                if rowData.multiOption then
                    local optionIndex = self:getOptionIndexForFillType(rowData.fillTypeName)
                    rowData.multiOption:setState(optionIndex)
                end

                -- Re-apply alternating row colors for visible rows only
                local isEven = (visibleIndex % 2 == 0)
                rowData.row:setImageColor(nil, table.unpack(
                    InGameMenuSettingsFrame.COLOR_ALTERNATING[isEven]))
            end
        end
    end

    return visibleIndex
end

-- =============================================================================
-- SC2 CLONE POPULATION
-- =============================================================================

--- Populate SC2 page by cloning one row per basegame fillType
function RmSettingsFrame:populateSc2()
    local layout = self.sc2Layout
    local template = self.sc2RowTemplate

    if not template or not layout then return end

    local fillTypes = RmSettingsFrame.basegameFillTypes or {}
    if #fillTypes == 0 then
        self.sc2Populated = true
        return
    end

    -- Save focus context as safety guard
    local savedFocusData = FocusManager.currentFocusData

    self.sc2Rows = {}

    for index, ft in ipairs(fillTypes) do
        local row = template:clone(layout)

        -- Alternating row color (clone doesn't fire onCreate)
        local isEven = (index % 2 == 0)
        row:setImageColor(nil, table.unpack(
            InGameMenuSettingsFrame.COLOR_ALTERNATING[isEven]))

        -- Set MultiTextOption texts to expiration options
        local multiOption = row.elements[1]
        if multiOption and self.optionTexts then
            multiOption:setTexts(self.optionTexts)

            -- Wire onClick closure with captured fillTypeName
            local fillTypeName = ft.name
            multiOption.onClickCallback = function(_target, state)
                self:onFillTypeOptionChangedByName(fillTypeName, state)
            end
        end

        -- Set fillType icon
        local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(ft.name)
        local fillType = fillTypeIndex and g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
        local iconElement = row.elements[2]
        if iconElement then
            if fillType and fillType.hudOverlayFilename then
                iconElement:setImageFilename(fillType.hudOverlayFilename)
                iconElement:setVisible(true)
            else
                iconElement:setVisible(false)
            end
        end

        -- Set title to fillType title
        local titleText = row.elements[3]
        if titleText then
            titleText:setText(ft.title)
        end

        -- Set tooltip
        local tooltipElement = row:getDescendantByName("fillTypeTooltip")
        if tooltipElement then
            tooltipElement:setText(self:buildFillTypeTooltip(ft.name))
        end

        self.sc2Rows[index] = { row = row, multiOption = multiOption, fillTypeName = ft.name }
    end

    -- Restore focus context
    FocusManager.currentFocusData = savedFocusData

    -- Unlink template from layout and focus system
    if template.parent then
        template:unlinkElement()
        FocusManager:removeElement(template)
    end

    layout:invalidateLayout()
    self.sc2Populated = true

    Log:trace("SETT CLONE SC2: %d rows cloned, template unlinked", #fillTypes)
end

--- Populate SC3 page by cloning one row per DLC/mod fillType
function RmSettingsFrame:populateSc3()
    local layout = self.sc3Layout
    local template = self.sc3RowTemplate

    if not template or not layout then return end

    local fillTypes = RmSettingsFrame.dlcmodFillTypes or {}
    if #fillTypes == 0 then
        self.sc3Populated = true
        return
    end

    -- Save focus context as safety guard
    local savedFocusData = FocusManager.currentFocusData

    self.sc3Rows = {}

    for index, ft in ipairs(fillTypes) do
        local row = template:clone(layout)

        -- Alternating row color (clone doesn't fire onCreate)
        local isEven = (index % 2 == 0)
        row:setImageColor(nil, table.unpack(
            InGameMenuSettingsFrame.COLOR_ALTERNATING[isEven]))

        -- Set MultiTextOption texts to expiration options
        local multiOption = row.elements[1]
        if multiOption and self.optionTexts then
            multiOption:setTexts(self.optionTexts)

            -- Wire onClick closure with captured fillTypeName
            local fillTypeName = ft.name
            multiOption.onClickCallback = function(_target, state)
                self:onFillTypeOptionChangedByName(fillTypeName, state)
            end
        end

        -- Set fillType icon
        local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(ft.name)
        local fillType = fillTypeIndex and g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
        local iconElement = row.elements[2]
        if iconElement then
            if fillType and fillType.hudOverlayFilename then
                iconElement:setImageFilename(fillType.hudOverlayFilename)
                iconElement:setVisible(true)
            else
                iconElement:setVisible(false)
            end
        end

        -- Set title to fillType title
        local titleText = row.elements[3]
        if titleText then
            titleText:setText(ft.title)
        end

        -- Set tooltip
        local tooltipElement = row:getDescendantByName("fillTypeTooltip")
        if tooltipElement then
            tooltipElement:setText(self:buildFillTypeTooltip(ft.name))
        end

        self.sc3Rows[index] = { row = row, multiOption = multiOption, fillTypeName = ft.name }
    end

    -- Restore focus context
    FocusManager.currentFocusData = savedFocusData

    -- Unlink template from layout and focus system
    if template.parent then
        template:unlinkElement()
        FocusManager:removeElement(template)
    end

    layout:invalidateLayout()
    self.sc3Populated = true

    Log:trace("SETT CLONE SC3: %d rows cloned, template unlinked", #fillTypes)
end

-- =============================================================================
-- TAB CLICK HANDLERS
-- =============================================================================

function RmSettingsFrame:onClickSettingsTab()
    self.subCategoryPaging:setState(RmSettingsFrame.SUB_CATEGORY.SETTINGS, true)
end

function RmSettingsFrame:onClickExpirationTab()
    self.subCategoryPaging:setState(RmSettingsFrame.SUB_CATEGORY.EXPIRATION, true)
end

function RmSettingsFrame:onClickDlcModTab()
    self.subCategoryPaging:setState(RmSettingsFrame.SUB_CATEGORY.DLCMOD, true)
end

-- =============================================================================
-- PAGE SWITCHING
-- =============================================================================

--- Page switching handler (called by MultiTextOption onClick)
--- Follows base game InGameMenuSettingsFrame pattern: show/hide pages, bind slider, link focus, set focus
---@param state number The paging state index
function RmSettingsFrame:updateSubCategoryPages(state)
    local idx = tonumber(self.subCategoryPaging.texts[state])
    if idx == nil then return end

    RmSettingsFrame.currentSubCategory = idx

    -- Show/hide page containers
    for index, page in ipairs(self.subCategoryPages) do
        page:setVisible(index == idx)
    end

    -- Bind slider and link focus for pages with ScrollingLayout
    local layout = nil
    if idx == RmSettingsFrame.SUB_CATEGORY.SETTINGS then
        layout = self.sc1Layout
    elseif idx == RmSettingsFrame.SUB_CATEGORY.EXPIRATION then
        layout = self.sc2Layout
    elseif idx == RmSettingsFrame.SUB_CATEGORY.DLCMOD then
        layout = self.sc3Layout
    end

    if layout then
        self.settingsSlider:setDataElement(layout)

        local firstFocusable = layout:findFirstFocusable(true)

        -- Find last focusable element (reverse search, skips hidden preset-controlled rows)
        local lastFocusable = nil
        for i = #layout.elements, 1, -1 do
            lastFocusable = layout.elements[i]:findFirstFocusable(true)
            if lastFocusable then break end
        end

        -- Bidirectional links (linkElements is unidirectional per FS25 FocusManager)
        if firstFocusable then
            FocusManager:linkElements(self.subCategoryPaging, FocusManager.BOTTOM, firstFocusable)
            FocusManager:linkElements(firstFocusable, FocusManager.TOP, self.subCategoryPaging)
        end
        if lastFocusable then
            FocusManager:linkElements(self.subCategoryPaging, FocusManager.TOP, lastFocusable)
            FocusManager:linkElements(lastFocusable, FocusManager.BOTTOM, self.subCategoryPaging)
        end
    end

    -- Set focus to paging element (tab bar)
    FocusManager:setFocus(self.subCategoryPaging)
end

-- =============================================================================
-- ADMIN HANDLING
-- =============================================================================

function RmSettingsFrame:isAdmin()
    if g_server ~= nil then
        return true
    end
    return g_currentMission.isMasterUser == true
end

-- =============================================================================
-- READONLY STATE
-- =============================================================================

--- Update disabled state of all controls based on admin status
--- Non-admin clients get disabled controls (grayed out)
function RmSettingsFrame:updateReadonlyState()
    local isAdmin = self:isAdmin()
    local disabled = not isAdmin

    -- Disable SC1 global controls
    if self.checkEnableExpiration then
        self.checkEnableExpiration:setDisabled(disabled)
    end
    if self.checkShowWarnings then
        self.checkShowWarnings:setDisabled(disabled)
    end
    if self.checkShowAgeDisplay then
        self.checkShowAgeDisplay:setDisabled(disabled)
    end
    if self.warningHoursSelector then
        local showWarnings = RmFreshSettings:getGlobal("showWarnings") ~= false
        self.warningHoursSelector:setDisabled(disabled or not showWarnings)
    end
    if self.presetSelector then
        self.presetSelector:setDisabled(disabled)
    end

    -- Disable fillType row selectors
    self:updateFillTypeRowsDisabled(self.sc2Rows)
    self:updateFillTypeRowsDisabled(self.sc3Rows)

    Log:debug("SETT: readonly=%s (isAdmin=%s)", tostring(disabled), tostring(isAdmin))
end

--- Update disabled state on all fillType row selectors
---@param rows table|nil Array of { row, multiOption, fillTypeName }
function RmSettingsFrame:updateFillTypeRowsDisabled(rows)
    if not rows then return end
    local disabled = not self:isAdmin()
    for _, rowData in ipairs(rows) do
        if rowData and rowData.multiOption then
            rowData.multiOption:setDisabled(disabled)
        end
    end
end

-- =============================================================================
-- RESET TO DEFAULTS
-- =============================================================================

function RmSettingsFrame:onResetDefaults()
    if not self:isAdmin() then
        return
    end

    YesNoDialog.show(
        self.onResetConfirmed,
        self,
        g_i18n:getText("fresh_settings_resetConfirm"),
        g_i18n:getText("ui_attention")
    )
end

function RmSettingsFrame:onResetConfirmed(yes)
    Log:debug("SETT: onResetConfirmed(yes=%s)", tostring(yes))

    if not yes then
        return
    end

    if g_server then
        RmFreshSettings:resetAllOverrides()
        RmSettingsFrame.pendingFillTypeChanges = {}
        self:refreshData()
        Log:info("SETT: Reset to defaults complete")
    else
        if RmSettingsChangeRequestEvent then
            g_client:getServerConnection():sendEvent(
                RmSettingsChangeRequestEvent.new("resetAll", nil, nil)
            )
        end
    end
end

-- =============================================================================
-- SETTINGS onClick HANDLERS
-- =============================================================================

function RmSettingsFrame:onClickPreset(state)
    if RmSettingsFrame.isRefreshing then return end
    if not self:isAdmin() then return end

    local presetName = RmSettingsFrame.PRESET_OPTIONS[state]
    if not presetName then
        Log:warning("SETT: Invalid preset state %d", state)
        return
    end

    Log:debug("SETT PRESET: -> %s", presetName)

    if g_server then
        if presetName ~= "custom" then
            RmFreshSettings:clearRedundantOverrides()
        end
        RmFreshSettings:setGlobal("preset", presetName)
        self:refreshData()
    else
        if RmSettingsChangeRequestEvent then
            g_client:getServerConnection():sendEvent(
                RmSettingsChangeRequestEvent.new("setGlobal", "preset", presetName)
            )
        end
    end
end

function RmSettingsFrame:onClickEnableExpiration(state)
    if RmSettingsFrame.isRefreshing then return end
    if not self:isAdmin() then return end

    local enabled = (state == 2)

    if g_server then
        RmFreshSettings:setGlobal("enableExpiration", enabled)
    else
        if RmSettingsChangeRequestEvent then
            g_client:getServerConnection():sendEvent(
                RmSettingsChangeRequestEvent.new("setGlobal", "enableExpiration", enabled)
            )
        end
    end
end

function RmSettingsFrame:onClickShowWarnings(state)
    if RmSettingsFrame.isRefreshing then return end
    if not self:isAdmin() then return end

    local enabled = (state == 2)

    if g_server then
        RmFreshSettings:setGlobal("showWarnings", enabled)
    else
        if RmSettingsChangeRequestEvent then
            g_client:getServerConnection():sendEvent(
                RmSettingsChangeRequestEvent.new("setGlobal", "showWarnings", enabled)
            )
        end
    end

    if self.warningHoursSelector then
        self.warningHoursSelector:setDisabled(not enabled)
    end
end

function RmSettingsFrame:onClickWarningHours(state)
    if RmSettingsFrame.isRefreshing then return end
    if not self:isAdmin() then return end

    local opt = RmSettingsFrame.WARNING_HOURS_OPTIONS[state]
    if not opt then return end

    if g_server then
        RmFreshSettings:setGlobal("warningHours", opt.hours)
    else
        if RmSettingsChangeRequestEvent then
            g_client:getServerConnection():sendEvent(
                RmSettingsChangeRequestEvent.new("setGlobal", "warningHours", opt.hours)
            )
        end
    end
end

function RmSettingsFrame:onClickShowAgeDisplay(state)
    if RmSettingsFrame.isRefreshing then return end
    if not self:isAdmin() then return end

    local enabled = (state == 2)

    if g_server then
        RmFreshSettings:setGlobal("showAgeDisplay", enabled)
    else
        if RmSettingsChangeRequestEvent then
            g_client:getServerConnection():sendEvent(
                RmSettingsChangeRequestEvent.new("setGlobal", "showAgeDisplay", enabled)
            )
        end
    end
end

-- =============================================================================
-- FILLTYPE CHANGE HANDLER
-- =============================================================================

--- Callback when a fillType expiration option is changed (from closure)
---@param fillTypeName string The fillType name (captured in closure)
---@param state number The new option index
function RmSettingsFrame:onFillTypeOptionChangedByName(fillTypeName, state)
    if RmSettingsFrame.isRefreshing then return end
    if not self:isAdmin() then return end

    local option = RmSettingsFrame.EXPIRATION_OPTIONS[state]
    if option == nil then
        Log:warning("SETT: Invalid option state %d", state)
        return
    end

    local action = option.expires == false and "setDoNotExpire" or "setExpiration"
    RmSettingsFrame.pendingFillTypeChanges[fillTypeName] = {
        action = action,
        value = option.period,
    }
end

-- =============================================================================
-- XML onCreate CALLBACKS
-- =============================================================================

--- Called by XML onCreate attribute to apply alternating row colors
function RmSettingsFrame:onCreateSettingRow(element)
    element:setImageColor(nil, table.unpack(InGameMenuSettingsFrame.COLOR_ALTERNATING[self.isEvenRow]))
    self.isEvenRow = not self.isEvenRow
end
