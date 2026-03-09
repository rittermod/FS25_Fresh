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
RmSettingsFrame.SUB_CATEGORY = { SETTINGS = 1, EXPIRATION = 2, MAXBENEFIT = 3, STORAGE = 4 }

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

--- Data array for fillType rows (class-level, rebuilt each onFrameOpen)
RmSettingsFrame.allPerishableFillTypes = nil

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

--- Storage class dropdown option names (state 1=Auto, 2-7=EXPOSED..DISABLED)
RmSettingsFrame.STORAGE_CLASS_OPTIONS = { "auto", "exposed", "sheltered", "indoor", "cooled", "frozen", "disabled" }

--- Max benefit class dropdown options (state 1=Default, 2-6=EXPOSED..FROZEN)
--- No "Disabled" - that's a per-building opt-out from F-125-1, not a fillType ceiling
RmSettingsFrame.MAXBENEFIT_OPTIONS = {
    { value = nil,  label = "fresh_maxbenefit_default" },
    { value = 0,    label = "fresh_class_exposed" },
    { value = 1,    label = "fresh_class_sheltered" },
    { value = 2,    label = "fresh_class_indoor" },
    { value = 3,    label = "fresh_class_cooled" },
    { value = 4,    label = "fresh_class_frozen" },
}

--- Sentinel value for "clear override" in pendingMaxBenefitChanges
RmSettingsFrame.MAXBENEFIT_CLEAR = "CLEAR"

--- Pending max benefit class changes accumulated during user interaction
--- Flushed on frame close. Key: fillTypeName, Value: classValue (number) or MAXBENEFIT_CLEAR
RmSettingsFrame.pendingMaxBenefitChanges = {}

--- Sentinel value for "clear override" in pendingStorageChanges
RmSettingsFrame.STORAGE_CLEAR = "CLEAR"

--- Pending storage class changes accumulated during user interaction
--- Flushed on frame close. Key: storage key, Value: classValue (number) or STORAGE_CLEAR
RmSettingsFrame.pendingStorageChanges = {}

function RmSettingsFrame.new()
    local self = RmSettingsFrame:superClass().new(nil, RmSettingsFrame_mt)
    self.name = "RmSettingsFrame"
    self.isEvenRow = true
    self.expirationPopulated = false
    self.sc3Populated = false
    self.sc4Populated = false
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
    RmSettingsFrame.pendingStorageChanges = {}

    -- Filter storages list to current player's farm (matches Overview/Stats pattern)
    self.farmId = g_currentMission:getFarmId()

    -- Build fillType data arrays (rebuilt each open to catch late DLC/mod fillTypes)
    self:buildFillTypeData()
    self.optionTexts = self:buildOptionTexts()

    -- Initialize sub-category pages
    self:initializeSubCategoryPages()

    -- Populate cloned expiration page (first open only)
    if not self.expirationPopulated then
        self:populateExpirationTab()
    end

    -- Populate cloned max benefit page (first open only)
    if not self.sc3Populated then
        self:populateMaxBenefitTab()
    end

    -- Populate cloned storage page (first open, or after dirty reset from menu open)
    if RmSettingsFrame.sc4Dirty then
        self.sc4Populated = false
        RmSettingsFrame.sc4Dirty = false
    end
    if not self.sc4Populated then
        self:populateStorageTab()
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

    -- Flush pending max benefit class changes before closing
    if next(RmSettingsFrame.pendingMaxBenefitChanges) then
        local count = 0
        for _ in pairs(RmSettingsFrame.pendingMaxBenefitChanges) do count = count + 1 end
        Log:debug("SETT FLUSH: applying %d pending maxBenefit changes", count)

        local isClear = RmSettingsFrame.MAXBENEFIT_CLEAR
        for fillTypeName, classValue in pairs(RmSettingsFrame.pendingMaxBenefitChanges) do
            if g_server then
                if classValue == isClear then
                    RmFreshSettings:clearMaxBenefitClassOverride(fillTypeName)
                else
                    RmFreshSettings:setMaxBenefitClassOverride(fillTypeName, classValue)
                end
            else
                if RmSettingsChangeRequestEvent then
                    if classValue == isClear then
                        g_client:getServerConnection():sendEvent(
                            RmSettingsChangeRequestEvent.new("clearMaxBenefitClass", fillTypeName, nil)
                        )
                    else
                        g_client:getServerConnection():sendEvent(
                            RmSettingsChangeRequestEvent.new("setMaxBenefitClass", fillTypeName, classValue)
                        )
                    end
                end
            end
        end
        RmSettingsFrame.pendingMaxBenefitChanges = {}
    end

    -- Flush pending storage class changes before closing
    if next(RmSettingsFrame.pendingStorageChanges) then
        local count = 0
        for _ in pairs(RmSettingsFrame.pendingStorageChanges) do count = count + 1 end
        Log:debug("SETT FLUSH: applying %d pending storage changes", count)

        local isClear = RmSettingsFrame.STORAGE_CLEAR
        for key, classValue in pairs(RmSettingsFrame.pendingStorageChanges) do
            if g_server then
                if classValue == isClear then
                    RmFreshSettings:clearStorageClassOverride(key)
                else
                    RmFreshSettings:setStorageClassOverride(key, classValue)
                end
            else
                if RmSettingsChangeRequestEvent then
                    if classValue == isClear then
                        g_client:getServerConnection():sendEvent(
                            RmSettingsChangeRequestEvent.new("clearStorageClassOverride", key, nil)
                        )
                    else
                        g_client:getServerConnection():sendEvent(
                            RmSettingsChangeRequestEvent.new("setStorageClassOverride", key, classValue)
                        )
                    end
                end
            end
        end
        RmSettingsFrame.pendingStorageChanges = {}
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

    for index, button in ipairs(self.subCategoryTabs) do
        -- Make tab background respond to selection state
        button:getDescendantByName("background").getIsSelected = function()
            return index == tonumber(self.subCategoryPaging.texts[self.subCategoryPaging:getState()])
        end

        -- Make tab button respond to selection state
        function button.getIsSelected()
            return index == tonumber(self.subCategoryPaging.texts[self.subCategoryPaging:getState()])
        end

        button:setVisible(true)
        table.insert(subCategories, tostring(index))
    end

    -- Configure paging selector
    self.subCategoryBox:invalidateLayout()
    self.subCategoryPaging:setTexts(subCategories)
    self.subCategoryPaging:setSize(self.subCategoryBox.maxFlowSize + 140 * g_pixelSizeScaledX)
end

-- =============================================================================
-- FILLTYPE DATA BUILDING
-- =============================================================================

--- Build fillType data array for expiration rows
--- Called each onFrameOpen to catch late-registered DLC/mod fillTypes
function RmSettingsFrame:buildFillTypeData()
    RmSettingsFrame.allPerishableFillTypes = self:getPerishableFillTypes()

    Log:debug("SETT DATA: %d perishable fillTypes", #RmSettingsFrame.allPerishableFillTypes)
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
    if self.checkStorageAging then
        local state = RmFreshSettings.storageAgingEnabled and 2 or 1
        self.checkStorageAging:setState(state)
    end

    -- Update tab visibility based on storageAgingEnabled
    self:updateStorageTabVisibility()

    -- Expiration tab: FillType row visibility and selector states
    local visibleCount = self:refreshFillTypeRows(self.expirationRows)

    -- Toggle empty-state message
    if self.sc2NoRowsMsg then self.sc2NoRowsMsg:setVisible(visibleCount == 0) end

    -- Invalidate layout so ScrollingLayout recalculates after row visibility changes
    if self.sc2Layout then self.sc2Layout:invalidateLayout() end

    -- SC3: Max Benefit tab - update dropdown states from current override values
    self:refreshMaxBenefitRows()
    -- Clear pending max benefit changes during refresh (prevents stale local changes)
    RmSettingsFrame.pendingMaxBenefitChanges = {}

    -- SC4: Storage tab - update dropdown states from current override values
    self:refreshStorageRows()
    -- Clear pending storage changes during refresh (prevents stale local changes)
    RmSettingsFrame.pendingStorageChanges = {}

    RmSettingsFrame.isRefreshing = false
end

--- Refresh storage tab dropdown states from current override values
--- Called during refreshData() - updates states only, no re-cloning
function RmSettingsFrame:refreshStorageRows()
    if not self.sc4Rows then return end

    for _, rowData in ipairs(self.sc4Rows) do
        if rowData and rowData.multiOption then
            local override = RmFreshSettings:getStorageClassOverride(rowData.key)
            if override ~= nil then
                rowData.multiOption:setState(override + 2) -- classValue + 2 = state
            else
                rowData.multiOption:setState(1) -- Auto
            end
        end
    end
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
-- EXPIRATION TAB CLONE POPULATION
-- =============================================================================

--- Populate Expiration tab by cloning one row per perishable fillType
function RmSettingsFrame:populateExpirationTab()
    local layout = self.sc2Layout
    local template = self.sc2RowTemplate

    if not template or not layout then return end

    local fillTypes = RmSettingsFrame.allPerishableFillTypes or {}
    if #fillTypes == 0 then
        self.expirationPopulated = true
        return
    end

    -- Save focus context as safety guard
    local savedFocusData = FocusManager.currentFocusData

    self.expirationRows = {}

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

        self.expirationRows[index] = { row = row, multiOption = multiOption, fillTypeName = ft.name }
    end

    -- Restore focus context
    FocusManager.currentFocusData = savedFocusData

    -- Unlink template from layout and focus system
    if template.parent then
        template:unlinkElement()
        FocusManager:removeElement(template)
    end

    layout:invalidateLayout()
    self.expirationPopulated = true

    Log:trace("SETT CLONE EXPIRATION: %d rows cloned, template unlinked", #fillTypes)
end

-- =============================================================================
-- STORAGE TAB CLONE POPULATION
-- =============================================================================

--- Build dropdown option texts for storage class selector
---@return table Array of localized strings
function RmSettingsFrame:buildStorageClassOptionTexts()
    local texts = {}
    table.insert(texts, g_i18n:getText("fresh_storage_auto"))
    for i = 0, 5 do
        local name = RmFreshManager.STORAGE_CLASS_NAMES[i]
        table.insert(texts, g_i18n:getText("fresh_class_" .. name))
    end
    return texts
end

--- Populate Storage tab by cloning one row per storage entity
function RmSettingsFrame:populateStorageTab()
    local layout = self.sc4Layout
    local template = self.sc4RowTemplate

    if not template or not layout then return end

    -- Save focus context as safety guard
    local savedFocusData = FocusManager.currentFocusData

    -- If repopulating after dirty flag, delete old clones first
    if self.sc4Rows then
        for _, rowData in ipairs(self.sc4Rows) do
            rowData.row:delete()
        end
    end

    local storageList = RmFreshManager:getStorageListForSettings(self.farmId)
    local optionTexts = self:buildStorageClassOptionTexts()
    self.sc4Rows = {}

    for index, entry in ipairs(storageList) do
        local row = template:clone(layout)

        -- Alternating row color
        local isEven = (index % 2 == 0)
        row:setImageColor(nil, table.unpack(InGameMenuSettingsFrame.COLOR_ALTERNATING[isEven]))

        -- Set MultiTextOption texts and callback
        local multiOption = row.elements[1]
        if multiOption then
            multiOption:setTexts(optionTexts)

            -- Set current state from override value
            local override = RmFreshSettings:getStorageClassOverride(entry.key)
            if override ~= nil then
                multiOption:setState(override + 2) -- classValue + 2 = state
            else
                multiOption:setState(1) -- Auto
            end

            -- Wire onClick closure (keep target intact per CLAUDE.md gotcha)
            local key = entry.key
            multiOption.onClickCallback = function(_target, state)
                self:onStorageClassChanged(key, state)
            end

            -- Set tooltip (dedicated tooltip for Items in World)
            local tooltipElement = multiOption:getDescendantByName("storageTooltip")
            if tooltipElement then
                local tooltipKey = entry.key == "itemsInWorld"
                    and "fresh_storage_items_in_world_tooltip"
                    or "fresh_storage_override_tooltip"
                tooltipElement:setText(g_i18n:getText(tooltipKey))
            end

            -- Disable for non-admin
            multiOption:setDisabled(not self:isAdmin())
        end

        -- Set entity icon
        local iconElement = row.elements[2]
        if iconElement then
            if entry.key == "itemsInWorld" then
                -- Use SQUAREBALE_GRASS icon for "Items in World"
                local fillType = g_fillTypeManager:getFillTypeByName("SQUAREBALE_GRASS")
                if fillType and fillType.hudOverlayFilename then
                    iconElement:setImageFilename(fillType.hudOverlayFilename)
                    -- HUD overlay icons fill the whole image (no sky to crop),
                    -- so use smaller size and center vertically in the row
                    local iconW, iconH = getNormalizedScreenValues(48, 48)
                    local posX, posY = getNormalizedScreenValues(19, -11)
                    iconElement:setSize(iconW, iconH)
                    iconElement:setPosition(posX, posY)
                    iconElement:setVisible(true)
                else
                    iconElement:setVisible(false)
                end
            else
                -- Resolve store image: try runtimeEntity first, fall back to placeable lookup
                local imageFilename = nil
                if entry.runtimeEntity and entry.runtimeEntity.getImageFilename then
                    imageFilename = entry.runtimeEntity:getImageFilename()
                end
                -- Fallback for Object Storage: runtimeEntity is abstractObject (no getImageFilename),
                -- find the parent placeable by uniqueId instead
                if (not imageFilename or imageFilename == "") and entry.uniqueId
                        and g_currentMission.placeableSystem then
                    for _, placeable in ipairs(g_currentMission.placeableSystem.placeables) do
                        if placeable.uniqueId == entry.uniqueId and placeable.getImageFilename then
                            imageFilename = placeable:getImageFilename()
                            break
                        end
                    end
                end
                if imageFilename and imageFilename ~= "" then
                    iconElement:setImageFilename(imageFilename)
                    iconElement:setVisible(true)
                else
                    iconElement:setVisible(false)
                end
            end
        end

        -- Set entity name
        local titleText = row.elements[3]
        if titleText then
            titleText:setText(entry.entityName)
        end

        -- Set detected class label
        local detectedLabel = row.elements[4]
        if detectedLabel then
            local className = RmFreshManager.STORAGE_CLASS_NAMES[entry.detectedClass]
            if className then
                local localizedName = g_i18n:getText("fresh_class_" .. className)
                detectedLabel:setText(string.format("%s: %s",
                    g_i18n:getText("fresh_storage_detected"), localizedName))
            else
                detectedLabel:setText("")
            end
        end

        self.sc4Rows[index] = { row = row, multiOption = multiOption, key = entry.key }
    end

    -- Restore focus context
    FocusManager.currentFocusData = savedFocusData

    -- Unlink template from layout (with parent guard for dual-instance safety)
    if template.parent then
        template:unlinkElement()
        FocusManager:removeElement(template)
    end

    layout:invalidateLayout()
    self.sc4Populated = true

    Log:trace("SETT CLONE STORAGE: %d rows cloned, template unlinked", #storageList)
end

--- Handle storage class override dropdown change
---@param key string uniqueId or "itemsInWorld"
---@param state number Dropdown state (1=Auto, 2-7=class values)
function RmSettingsFrame:onStorageClassChanged(key, state)
    if RmSettingsFrame.isRefreshing then return end
    if not self:isAdmin() then return end

    if state == 1 then
        -- Auto: mark for clearing override on flush
        RmSettingsFrame.pendingStorageChanges[key] = RmSettingsFrame.STORAGE_CLEAR
    else
        -- States 2-7 map to class values 0-5
        RmSettingsFrame.pendingStorageChanges[key] = state - 2
    end
end

-- =============================================================================
-- MAX BENEFIT TAB CLONE POPULATION
-- =============================================================================

--- Build dropdown option texts for max benefit class selector
---@return table Array of localized strings
function RmSettingsFrame:buildMaxBenefitOptionTexts()
    local texts = {}
    for _, opt in ipairs(RmSettingsFrame.MAXBENEFIT_OPTIONS) do
        table.insert(texts, g_i18n:getText(opt.label))
    end
    return texts
end

--- Get the default class label for a fillType (from config defaults)
---@param fillTypeName string
---@return string Localized class name (e.g., "Indoor")
function RmSettingsFrame:getDefaultClassLabel(fillTypeName)
    local classValue = RmFreshSettings.maxBenefitClassDefaults[fillTypeName]
    if classValue ~= nil then
        local className = RmFreshManager.STORAGE_CLASS_NAMES[classValue]
        if className then
            return g_i18n:getText("fresh_class_" .. className)
        end
    end
    -- Fallback: SHELTERED (the hardcoded default in getMaxBenefitClass)
    return g_i18n:getText("fresh_class_sheltered")
end

--- Populate Max Benefit tab by cloning one row per fillType
function RmSettingsFrame:populateMaxBenefitTab()
    local layout = self.sc3Layout
    local template = self.sc3RowTemplate

    if not template or not layout then return end

    local fillTypes = RmSettingsFrame.allPerishableFillTypes or {}
    if #fillTypes == 0 then
        self.sc3Populated = true
        return
    end

    -- Save focus context as safety guard
    local savedFocusData = FocusManager.currentFocusData

    local optionTexts = self:buildMaxBenefitOptionTexts()
    self.sc3Rows = {}

    for index, ft in ipairs(fillTypes) do
        local row = template:clone(layout)

        -- Alternating row color
        local isEven = (index % 2 == 0)
        row:setImageColor(nil, table.unpack(
            InGameMenuSettingsFrame.COLOR_ALTERNATING[isEven]))

        -- Set MultiTextOption texts to max benefit options
        local multiOption = row.elements[1]
        if multiOption then
            multiOption:setTexts(optionTexts)

            -- Wire onClick closure with captured fillTypeName
            local fillTypeName = ft.name
            multiOption.onClickCallback = function(_target, state)
                self:onMaxBenefitClassChanged(fillTypeName, state)
            end

            -- Set tooltip
            local tooltipElement = multiOption:getDescendantByName("maxBenefitTooltip")
            if tooltipElement then
                tooltipElement:setText(g_i18n:getText("fresh_maxbenefit_tooltip"))
            end

            -- Disable for non-admin
            multiOption:setDisabled(not self:isAdmin())
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

        -- Set default class label (read-only)
        local defaultLabel = row.elements[3]
        if defaultLabel then
            defaultLabel:setText(string.format("%s: %s",
                g_i18n:getText("fresh_maxbenefit_configDefault"), self:getDefaultClassLabel(ft.name)))
        end

        -- Set fillType title
        local titleText = row.elements[4]
        if titleText then
            titleText:setText(ft.title)
        end

        self.sc3Rows[index] = { row = row, multiOption = multiOption, fillTypeName = ft.name, defaultLabel = defaultLabel }
    end

    -- Restore focus context
    FocusManager.currentFocusData = savedFocusData

    -- Unlink template from layout (with parent guard for dual-instance safety)
    if template.parent then
        template:unlinkElement()
        FocusManager:removeElement(template)
    end

    layout:invalidateLayout()
    self.sc3Populated = true

    Log:trace("SETT CLONE MAXBENEFIT: %d rows cloned, template unlinked", #fillTypes)
end

--- Refresh max benefit tab dropdown states from current override values
--- Called during refreshData() - updates states only, no re-cloning
function RmSettingsFrame:refreshMaxBenefitRows()
    if not self.sc3Rows then return end

    for _, rowData in ipairs(self.sc3Rows) do
        if rowData and rowData.multiOption then
            local override = RmFreshSettings.maxBenefitClassOverrides[rowData.fillTypeName]
            if override ~= nil then
                -- States 2-6 map to class values 0-4
                rowData.multiOption:setState(override + 2)
            else
                rowData.multiOption:setState(1) -- Default
            end
        end
    end
end

--- Handle max benefit class dropdown change
---@param fillTypeName string FillType name (captured in closure)
---@param state number Dropdown state (1=Default, 2-6=class values 0-4)
function RmSettingsFrame:onMaxBenefitClassChanged(fillTypeName, state)
    if RmSettingsFrame.isRefreshing then return end
    if not self:isAdmin() then return end

    if state == 1 then
        -- Default: clear override
        RmSettingsFrame.pendingMaxBenefitChanges[fillTypeName] = RmSettingsFrame.MAXBENEFIT_CLEAR
    else
        -- States 2-6 map to class values 0-4
        RmSettingsFrame.pendingMaxBenefitChanges[fillTypeName] = state - 2
    end
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

function RmSettingsFrame:onClickMaxBenefitTab()
    self.subCategoryPaging:setState(RmSettingsFrame.SUB_CATEGORY.MAXBENEFIT, true)
end

function RmSettingsFrame:onClickStorageTab()
    self.subCategoryPaging:setState(RmSettingsFrame.SUB_CATEGORY.STORAGE, true)
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
    elseif idx == RmSettingsFrame.SUB_CATEGORY.MAXBENEFIT then
        layout = self.sc3Layout
    elseif idx == RmSettingsFrame.SUB_CATEGORY.STORAGE then
        layout = self.sc4Layout
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
    if self.checkStorageAging then
        self.checkStorageAging:setDisabled(disabled)
    end

    -- Disable fillType row selectors
    self:updateFillTypeRowsDisabled(self.expirationRows)

    -- Disable max benefit tab row selectors
    self:updateFillTypeRowsDisabled(self.sc3Rows)

    -- Disable storage tab row selectors
    self:updateFillTypeRowsDisabled(self.sc4Rows)

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
        RmSettingsFrame.pendingMaxBenefitChanges = {}
        RmSettingsFrame.pendingStorageChanges = {}
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

function RmSettingsFrame:onClickStorageAging(state)
    if RmSettingsFrame.isRefreshing then return end
    if not self:isAdmin() then return end

    local enabled = (state == 2)

    -- Set local property immediately for responsive UI
    RmFreshSettings.storageAgingEnabled = enabled

    if g_server then
        RmFreshSettings:setGlobal("storageAgingEnabled", enabled)
    else
        if RmSettingsChangeRequestEvent then
            g_client:getServerConnection():sendEvent(
                RmSettingsChangeRequestEvent.new("setGlobal", "storageAgingEnabled", enabled)
            )
        end
    end

    -- Immediately update tab visibility
    self:updateStorageTabVisibility()

    -- Repopulate storage tab when enabling (building list may have changed while tab was hidden)
    if enabled then
        self.sc4Populated = false
        self:populateStorageTab()
    end
end

--- Update visibility of storage-related tabs based on storageAgingEnabled
--- Hides/shows Max Benefit (SC3) and Storage (SC4) tab buttons, rebuilds paging selector
function RmSettingsFrame:updateStorageTabVisibility()
    local enabled = RmFreshSettings.storageAgingEnabled

    -- Hide/show Max Benefit tab button (index 3) and Storage tab button (index 4)
    local maxBenefitTabButton = self.subCategoryTabs[3]
    if maxBenefitTabButton then
        maxBenefitTabButton:setVisible(enabled)
    end
    local storageTabButton = self.subCategoryTabs[4]
    if storageTabButton then
        storageTabButton:setVisible(enabled)
    end

    -- Rebuild paging selector texts to match visible tabs
    local subCategories = {}
    for index, button in ipairs(self.subCategoryTabs) do
        if button:getIsVisible() then
            table.insert(subCategories, tostring(index))
        end
    end
    self.subCategoryBox:invalidateLayout()
    self.subCategoryPaging:setTexts(subCategories)
    self.subCategoryPaging:setSize(self.subCategoryBox.maxFlowSize + 140 * g_pixelSizeScaledX)

    -- If currently on a hidden tab, switch to General
    if not enabled and (RmSettingsFrame.currentSubCategory == RmSettingsFrame.SUB_CATEGORY.MAXBENEFIT
            or RmSettingsFrame.currentSubCategory == RmSettingsFrame.SUB_CATEGORY.STORAGE) then
        self.subCategoryPaging:setState(1, true)
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
