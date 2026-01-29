--[[
    RmSettingsFrame.lua
    Fresh mod Settings tab frame with fillType expiration selectors
]]

RmSettingsFrame = {}
local RmSettingsFrame_mt = Class(RmSettingsFrame, TabbedMenuFrameElement)

local Log = RmLogging.getLogger("Fresh")

-- Store mod directory at source time
local modDirectory = g_currentModDirectory

-- =============================================================================
-- CONSTANTS
-- =============================================================================

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

--- Warning hours options for MultiTextOption selector
RmSettingsFrame.WARNING_HOURS_OPTIONS = {
    { hours = 6,  label = "fresh_warning_6h" },
    { hours = 12, label = "fresh_warning_12h" },
    { hours = 24, label = "fresh_warning_24h" },
    { hours = 48, label = "fresh_warning_48h" },
    { hours = 72, label = "fresh_warning_72h" },
}

--- Map period values to option indices for quick lookup
RmSettingsFrame.PERIOD_TO_INDEX = {} -- Built in buildPeriodToIndexMap()

--- MODULE-LEVEL storage for fillType selectors (shared across instances)
--- FS25 creates multiple frame instances but only the first one has the template.
--- Selectors are stored here so all instances can access them.
RmSettingsFrame.fillTypeSelectorsShared = nil -- fillTypeName → MultiTextOptionElement

--- Fallback categories to check when boolean type flags are all false
--- (workaround for mods like LazyDistribution that overwrite fillTypes without preserving flags)
RmSettingsFrame.TYPE_FALLBACK_CATEGORIES = {
    -- Bulk product categories
    "COMBINE",      -- harvestable crops (WHEAT, BARLEY, OAT, etc.)
    "FARMSILO",     -- storable crops
    "TRAINWAGON",   -- trainable bulk goods
    -- Pallet/processed product categories
    "PRODUCT",                   -- processed goods
    "SELLINGSTATION_PRODUCTSFOOD", -- food products
    -- Bale/windrow categories
    "WINDROW",              -- grass/straw materials
    "SELLINGSTATION_BALES", -- bale-able materials
}

--- Reference to the frame instance that built the rows (owns the GUI elements)
RmSettingsFrame.builderInstance = nil

--- Reference to the currently DISPLAYED frame instance
--- Updated in onFrameOpen, cleared in onFrameClose
--- Used by sync events to refresh the visible UI
RmSettingsFrame.displayedInstance = nil

--- Fix B: Suppression flag to prevent callbacks during programmatic refresh
--- Set true during refreshData/refreshFillTypeSelectors to avoid cascade updates
RmSettingsFrame.isRefreshing = false

--- Pending fillType changes accumulated during user interaction (RIT-177)
--- Flushed on frame close. Key: fillTypeName, Value: { action, value }
RmSettingsFrame.pendingFillTypeChanges = {}

-- =============================================================================
-- CONSTRUCTOR
-- =============================================================================

function RmSettingsFrame.new()
    Log:trace("RmSettingsFrame.new()")
    local self = RmSettingsFrame:superClass().new(nil, RmSettingsFrame_mt)
    self.name = "RmSettingsFrame"
    -- Initialize alternating row color state (used by onCreate callback)
    self.isEvenRow = true
    return self
end

--- Build period-to-index lookup map for quick state lookup
function RmSettingsFrame:buildPeriodToIndexMap()
    RmSettingsFrame.PERIOD_TO_INDEX = {}
    for i, opt in ipairs(RmSettingsFrame.EXPIRATION_OPTIONS) do
        if opt.period then
            RmSettingsFrame.PERIOD_TO_INDEX[opt.period] = i
            Log:trace("PERIOD_TO_INDEX[%.1f] = %d", opt.period, i)
        end
    end
    Log:debug("SETTINGS_UI: Built PERIOD_TO_INDEX with %d entries", self:tableCount(RmSettingsFrame.PERIOD_TO_INDEX))
end

--- Count entries in a table (utility for debug)
---@param t table
---@return number
function RmSettingsFrame:tableCount(t)
    local count = 0
    for _ in pairs(t or {}) do count = count + 1 end
    return count
end

function RmSettingsFrame.setupGui()
    local frame = RmSettingsFrame.new()
    g_gui:loadGui(
        Utils.getFilename("gui/settingsFrame.xml", modDirectory),
        "RmSettingsFrame",
        frame,
        true -- true = this is a frame, not standalone
    )
    Log:debug("RmSettingsFrame.setupGui() complete")
end

-- =============================================================================
-- LIFECYCLE METHODS
-- =============================================================================

function RmSettingsFrame:onGuiSetupFinished()
    Log:trace("RmSettingsFrame:onGuiSetupFinished()")
    RmSettingsFrame:superClass().onGuiSetupFinished(self)

    -- Build period lookup map
    self:buildPeriodToIndexMap()

    -- Elements with 'id' attribute are automatically exposed as self.elementId
    Log:debug("SETTINGS_UI: boxLayout=%s", tostring(self.boxLayout))
    Log:debug("SETTINGS_UI: checkEnableExpiration=%s", tostring(self.checkEnableExpiration))
    Log:debug("SETTINGS_UI: checkShowWarnings=%s", tostring(self.checkShowWarnings))

    -- Setup warning hours selector
    if self.warningHoursSelector then
        local texts = {}
        for _, opt in ipairs(RmSettingsFrame.WARNING_HOURS_OPTIONS) do
            table.insert(texts, g_i18n:getText(opt.label))
        end
        self.warningHoursSelector:setTexts(texts)
    end

    -- Initialize menu button info (Back + Reset)
    self:initializeMenuButtons()

    -- Build fillType selector rows dynamically
    self:buildFillTypeRows()
end

--- Initialize menu button info for bottom bar
--- Pattern from EasyDevControls: define buttons, set self.menuButtonInfo
function RmSettingsFrame:initializeMenuButtons()
    -- Back button (MENU_BACK) - no callback needed, TabbedMenu handles it
    self.backButtonInfo = {
        inputAction = InputAction.MENU_BACK
    }

    -- Reset to Defaults button
    self.resetButtonInfo = {
        inputAction = InputAction.MENU_EXTRA_1,
        text = g_i18n:getText("fresh_settings_resetDefaults"),
        callback = function()
            self:onResetDefaults()
        end
    }

    -- Set initial menu button info
    self:updateMenuButtons()
end

--- Update menu buttons array based on current state
--- Called on frame open and when permissions change
function RmSettingsFrame:updateMenuButtons()
    self.menuButtonInfo = {
        self.backButtonInfo
    }

    -- Reset button disabled: fillType selectors don't visually update
    -- after reset because FS25 creates multiple frame instances with separate GUI trees.
    -- The selectors belong to the first instance but setState doesn't update the visible UI.
    -- Uncomment when bug is fixed:
    -- if self:isAdmin() then
    --     table.insert(self.menuButtonInfo, self.resetButtonInfo)
    -- end
end

function RmSettingsFrame:onFrameOpen()
    RmSettingsFrame:superClass().onFrameOpen(self)

    -- Track this as the currently displayed instance (for sync events)
    RmSettingsFrame.displayedInstance = self

    -- DIAGNOSTIC: Log instance info
    local sharedCount = self:tableCount(RmSettingsFrame.fillTypeSelectorsShared)
    Log:info("DIAG_OPEN: self=%s, builder=%s, boxLayout=%s, sharedSelectors=%d",
        tostring(self),
        tostring(RmSettingsFrame.builderInstance),
        tostring(self.boxLayout),
        sharedCount)

    -- Populate UI with current settings
    self:refreshData()

    -- Disable controls for non-admin clients
    self:updateReadonlyState()

    -- Update menu buttons (show/hide Reset based on admin status)
    self:updateMenuButtons()
    self:setMenuButtonInfoDirty()
end

function RmSettingsFrame:onFrameClose()
    -- RIT-177: Flush pending fillType changes before closing
    if next(RmSettingsFrame.pendingFillTypeChanges) then
        local count = 0
        for _ in pairs(RmSettingsFrame.pendingFillTypeChanges) do count = count + 1 end
        Log:debug("SETTINGS_FLUSH: applying %d pending fillType changes on frame close", count)

        if g_server then
            RmFreshSettings:applyBatchChanges(RmSettingsFrame.pendingFillTypeChanges)
        else
            -- Client: send individual events to server
            for fillTypeName, change in pairs(RmSettingsFrame.pendingFillTypeChanges) do
                if RmSettingsChangeRequestEvent then
                    g_client:getServerConnection():sendEvent(
                        RmSettingsChangeRequestEvent.new(change.action, fillTypeName, change.value)
                    )
                end
            end
        end

        RmSettingsFrame.pendingFillTypeChanges = {}
        Log:trace("    flush complete (server=%s)", tostring(g_server ~= nil))
    end

    RmSettingsFrame:superClass().onFrameClose(self)
    Log:trace("RmSettingsFrame:onFrameClose() (self=%s)", tostring(self))

    -- Clear displayed instance when frame closes
    if RmSettingsFrame.displayedInstance == self then
        RmSettingsFrame.displayedInstance = nil
    end
end

-- =============================================================================
-- DATA REFRESH
-- =============================================================================

function RmSettingsFrame:refreshData()
    Log:trace(">>> RmSettingsFrame:refreshData()")

    -- Update global checkboxes (BinaryOption uses setState: 1=off, 2=on)
    -- Note: Set isRefreshing to block callbacks during global checkbox updates too
    RmSettingsFrame.isRefreshing = true
    if self.checkEnableExpiration then
        local enableExpiration = RmFreshSettings:getGlobal("enableExpiration")
        local state = (enableExpiration ~= false) and 2 or 1
        self.checkEnableExpiration:setState(state) -- No 'true' - need visual update
        Log:trace("    checkEnableExpiration state=%d", state)
    else
        Log:warning("SETTINGS_UI: checkEnableExpiration not found")
    end

    if self.checkShowWarnings then
        local showWarnings = RmFreshSettings:getGlobal("showWarnings")
        local state = (showWarnings ~= false) and 2 or 1
        self.checkShowWarnings:setState(state) -- No 'true' - need visual update
        Log:trace("    checkShowWarnings state=%d", state)
    else
        Log:warning("SETTINGS_UI: checkShowWarnings not found")
    end

    if self.checkShowAgeDisplay then
        local showAgeDisplay = RmFreshSettings:getGlobal("showAgeDisplay")
        local state = (showAgeDisplay ~= false) and 2 or 1
        self.checkShowAgeDisplay:setState(state)
        Log:trace("    checkShowAgeDisplay state=%d", state)
    else
        Log:warning("SETTINGS_UI: checkShowAgeDisplay not found")
    end

    if self.warningHoursSelector then
        local currentHours = RmFreshSettings:getWarningHours()
        local state = self:findWarningHoursState(currentHours)
        self.warningHoursSelector:setState(state)
        Log:trace("    warningHoursSelector state=%d", state)
    end
    RmSettingsFrame.isRefreshing = false

    -- Update fillType selectors
    self:refreshFillTypeSelectors()

    Log:trace("<<< RmSettingsFrame:refreshData()")
end

-- =============================================================================
-- FILLTYPE ROW BUILDING
-- =============================================================================

--- Check if fillType belongs to any fallback category indicating it's a real product
--- Used when boolean type flags (isBulkType, isPalletType, isBaleType) are all false
--- due to mod conflicts (e.g., LazyDistribution overwrites fillTypes without preserving flags)
---@param fillTypeIndex number The fillType index
---@return boolean True if fillType is in any fallback category
function RmSettingsFrame:checkCategoryFallback(fillTypeIndex)
    for _, categoryName in ipairs(RmSettingsFrame.TYPE_FALLBACK_CATEGORIES) do
        if g_fillTypeManager:getIsFillTypeInCategory(fillTypeIndex, categoryName) then
            return true
        end
    end
    return false
end

--- Get list of ALL fillTypes sorted by type relevance, then expiration, then alphabetically
--- Sort order: 1) Has type + expires, 2) Has type + doesn't expire, 3) No type (bottom)
---@return table Array of { name = string, title = string, expires = boolean, hasType = boolean }
function RmSettingsFrame:getPerishableFillTypes()
    local fillTypes = {}

    -- Get ALL fillTypes from game (not just mod defaults)
    for fillTypeName, fillTypeData in pairs(RmFreshSettings.allFillTypes or {}) do
        -- Skip UNKNOWN fillType
        if fillTypeName ~= "UNKNOWN" then
            local expiration = RmFreshSettings:getExpiration(fillTypeName)

            -- Check if fillType has a type classification (Bulk/Pallet/Bale)
            local hasType = false
            local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(fillTypeName)
            if fillTypeIndex then
                local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
                if fillType then
                    hasType = fillType.isBulkType or fillType.isPalletType or fillType.isBaleType or false

                    -- If no type flags set, check category fallback
                    -- (workaround for mods that overwrite fillTypes without preserving flags)
                    if not hasType then
                        hasType = self:checkCategoryFallback(fillTypeIndex)
                    end
                end
            end

            table.insert(fillTypes, {
                name = fillTypeName,
                title = fillTypeData.title or fillTypeName,
                expires = expiration ~= nil,
                hasType = hasType
            })
        end
    end

    -- Sort: hasType first, then expires, then alphabetically
    -- Priority: 1) hasType+expires, 2) hasType+!expires, 3) !hasType (bottom)
    table.sort(fillTypes, function(a, b)
        -- First priority: hasType (true comes before false)
        if a.hasType ~= b.hasType then
            return a.hasType
        end
        -- Second priority: expires (true comes before false)
        if a.expires ~= b.expires then
            return a.expires
        end
        -- Third priority: alphabetically by title
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

--- Build tooltip text for a fillType with distinguishing information
---@param fillTypeName string The internal fillType name (e.g., "WHEAT")
---@param fillType table|nil The fillType object from g_fillTypeManager (may be nil)
---@return string Tooltip text
function RmSettingsFrame:buildFillTypeTooltip(fillTypeName, fillType)
    local parts = {}

    -- Always show the internal name
    table.insert(parts, string.format("Fill type: %s", fillTypeName))

    if fillType then
        -- Show type classification
        local typeInfo = {}
        if fillType.isBulkType then table.insert(typeInfo, "Bulk") end
        if fillType.isPalletType then table.insert(typeInfo, "Pallet") end
        if fillType.isBaleType then table.insert(typeInfo, "Bale") end
        if #typeInfo > 0 then
            table.insert(parts, "Type: " .. table.concat(typeInfo, ", "))
        end
    end

    return table.concat(parts, " | ")
end

--- Get the option index for a fillType's current expiration setting
---@param fillTypeName string The fillType name
---@return number Option index (1 = never, 2+ = periods)
function RmSettingsFrame:getOptionIndexForFillType(fillTypeName)
    local expiration = RmFreshSettings:getExpiration(fillTypeName)
    if expiration == nil then
        Log:trace("    getOptionIndexForFillType(%s): expiration=nil -> index=1", fillTypeName)
        return 1 -- "Do not expire"
    end
    -- Round to 1 decimal place to avoid floating point precision issues
    -- (XML parsing may return 12.000000001 instead of 12.0)
    local roundedExpiration = math.floor(expiration * 10 + 0.5) / 10
    local index = RmSettingsFrame.PERIOD_TO_INDEX[roundedExpiration]
    if index == nil then
        Log:debug("SETTINGS_UI: %s expiration=%.2f (rounded=%.1f) not in PERIOD_TO_INDEX -> index=1",
            fillTypeName, expiration, roundedExpiration)
        return 1
    end
    Log:trace("    getOptionIndexForFillType(%s): expiration=%.2f -> index=%d", fillTypeName, expiration, index)
    return index
end

--- Build fillType selector rows dynamically by cloning template
--- Called once during onGuiSetupFinished
--- NOTE: FS25 creates multiple frame instances but only the first one has the template.
--- Selectors are stored at module level (fillTypeSelectorsShared) so all instances can access them.
function RmSettingsFrame:buildFillTypeRows()
    Log:debug(">>> buildFillTypeRows() (self=%s, boxLayout=%s)", tostring(self), tostring(self.boxLayout))

    -- Skip if already built (module-level check)
    if RmSettingsFrame.fillTypeSelectorsShared ~= nil then
        Log:debug("SETTINGS_UI: fillType rows already built, skipping (shared has %d selectors)",
            self:tableCount(RmSettingsFrame.fillTypeSelectorsShared))
        return
    end

    if self.boxLayout == nil then
        Log:warning("SETTINGS_UI: boxLayout not found, cannot build fillType rows")
        return
    end

    if self.fillTypeRowTemplate == nil then
        Log:warning("SETTINGS_UI: fillTypeRowTemplate not found, cannot build fillType rows")
        return
    end

    -- Initialize module-level storage
    RmSettingsFrame.fillTypeSelectorsShared = {}
    -- Store reference to this instance as the builder (owns the GUI elements)
    RmSettingsFrame.builderInstance = self

    local fillTypes = self:getPerishableFillTypes()
    local optionTexts = self:buildOptionTexts()

    Log:debug("SETTINGS_UI: Building %d fillType selector rows (builder=%s, boxLayout=%s)",
        #fillTypes, tostring(self), tostring(self.boxLayout))

    for _, ft in ipairs(fillTypes) do
        self:createFillTypeRow(ft.name, ft.title, optionTexts)
    end

    -- Remove the template from the layout now that all rows are created
    -- This prevents the hidden template from appearing as a ghost row
    self.fillTypeRowTemplate:delete()
    self.fillTypeRowTemplate = nil
    Log:trace("    Template deleted after cloning")

    Log:debug("<<< buildFillTypeRows() - created %d rows", #fillTypes)
end

--- Create a single fillType selector row by cloning template
---@param fillTypeName string The fillType name (e.g., "WHEAT")
---@param fillTypeTitle string The display title (e.g., "Wheat")
---@param optionTexts table Array of option text labels
function RmSettingsFrame:createFillTypeRow(fillTypeName, fillTypeTitle, optionTexts)
    -- Clone the template row
    local rowContainer = self.fillTypeRowTemplate:clone(self.boxLayout)
    if rowContainer == nil then
        Log:warning("SETTINGS_UI: Failed to clone fillTypeRowTemplate for %s", fillTypeName)
        return
    end

    -- Make it visible (template is hidden)
    rowContainer:setVisible(true)

    -- Apply alternating row color
    self:onCreateSettingRow(rowContainer)

    -- Find the selector element within the cloned row
    local selector = rowContainer:getDescendantByName("fillTypeSelector")
    if selector == nil then
        Log:warning("SETTINGS_UI: Could not find fillTypeSelector in cloned row for %s", fillTypeName)
        return
    end

    -- Configure selector
    selector:setTexts(optionTexts)

    -- Wire callback - capture fillTypeName in closure (FS25 pattern from MoveHusbandryAnimals)
    -- Note: The 'element' param in callback is the clicked button, not the selector
    local frame = self
    local ftName = fillTypeName
    selector.onClickCallback = function(_element, state)
        frame:onFillTypeOptionChangedByName(ftName, state)
    end

    -- Set initial state based on configured expiration
    local optionIndex = self:getOptionIndexForFillType(fillTypeName)
    selector:setState(optionIndex, true) -- true = skip callback
    Log:trace("    %s initial state=%d", fillTypeName, optionIndex)

    -- Find and set the title text
    local titleText = rowContainer:getDescendantByName("fillTypeTitle")
    if titleText then
        titleText:setText(fillTypeTitle)
    end

    -- Find and set the fillType icon and build tooltip
    local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(fillTypeName)
    local fillType = fillTypeIndex and g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)

    local iconElement = rowContainer:getDescendantByName("fillTypeIcon")
    if iconElement ~= nil then
        if fillType ~= nil and fillType.hudOverlayFilename ~= nil then
            iconElement:setImageFilename(fillType.hudOverlayFilename)
            iconElement:setVisible(true)
        else
            iconElement:setVisible(false)
        end
    end

    -- Set tooltip with distinguishing information
    local tooltipElement = rowContainer:getDescendantByName("fillTypeTooltip")
    if tooltipElement ~= nil then
        local tooltipText = self:buildFillTypeTooltip(fillTypeName, fillType)
        tooltipElement:setText(tooltipText)
    end

    -- Note: clone(boxLayout) already adds the element to boxLayout - no addElement() needed

    -- Store reference at MODULE level for refreshData (shared across all instances)
    RmSettingsFrame.fillTypeSelectorsShared[fillTypeName] = selector

    Log:trace("    Created row: %s (%s)", fillTypeName, fillTypeTitle)
end

--- Refresh all fillType selector states from current settings
--- Uses module-level fillTypeSelectorsShared (works across all frame instances)
--- Fix B: Sets isRefreshing flag to suppress callbacks during programmatic update
function RmSettingsFrame:refreshFillTypeSelectors()
    local selectors = RmSettingsFrame.fillTypeSelectorsShared or {}

    -- Diagnostic: Log userOverrides state at refresh time
    local overrideCount = RmFreshSettings:tableCount(RmFreshSettings.userOverrides.fillTypes or {})
    Log:debug("SETTINGS_UI: refreshFillTypeSelectors() - %d selectors, %d userOverrides (self=%s)",
        self:tableCount(selectors), overrideCount, tostring(self))

    RmSettingsFrame.isRefreshing = true -- Suppress callbacks during refresh

    -- Get option texts once for all selectors (used to force visual update)
    local optionTexts = self:buildOptionTexts()

    for fillTypeName, selector in pairs(selectors) do
        local optionIndex = self:getOptionIndexForFillType(fillTypeName)
        local currentState = selector:getState()

        -- DIAGNOSTIC: Log selector parent for WHEAT/BARLEY to understand GUI tree ownership
        local hasOverride = RmFreshSettings.userOverrides.fillTypes[fillTypeName] ~= nil
        if hasOverride or fillTypeName == "WHEAT" or fillTypeName == "BARLEY" then
            Log:info("DIAG_REFRESH: %s selector=%s parent=%s state=%d->%d",
                fillTypeName, tostring(selector), tostring(selector.parent), currentState, optionIndex)
        end

        -- Force visual update by resetting texts and state
        -- This ensures the C++ visual tree is refreshed, not just the Lua state
        selector:setTexts(optionTexts)
        selector:setState(optionIndex)
    end
    RmSettingsFrame.isRefreshing = false
end

--- Callback when a fillType expiration option is changed (by name, from closure)
---@param fillTypeName string The fillType name (captured in closure)
---@param state number The new option index
function RmSettingsFrame:onFillTypeOptionChangedByName(fillTypeName, state)
    -- DIAGNOSTIC: Log which frame instance the callback belongs to (captured in closure)
    Log:info("DIAG_CALLBACK: frame=%s (closure), fillType=%s, state=%d, displayed=%s",
        tostring(self), fillTypeName, state, tostring(RmSettingsFrame.displayedInstance))

    -- Fix B: Skip if this is a programmatic refresh (not user interaction)
    if RmSettingsFrame.isRefreshing then
        Log:trace("    skipped (isRefreshing)")
        return
    end

    if not self:isAdmin() then
        Log:trace("    skipped (not admin)")
        return
    end

    local option = RmSettingsFrame.EXPIRATION_OPTIONS[state]
    if option == nil then
        Log:warning("SETTINGS_UI: Invalid option state %d", state)
        return
    end

    -- RIT-177: Defer change to frame close instead of applying immediately
    local action = option.expires == false and "setDoNotExpire" or "setExpiration"
    RmSettingsFrame.pendingFillTypeChanges[fillTypeName] = {
        action = action,
        value = option.period,  -- nil for setDoNotExpire
    }

    Log:trace("    SETTINGS_PENDING: %s -> %s (deferred to frame close)", fillTypeName, action)
    Log:trace("<<< onFillTypeOptionChangedByName")
end

-- =============================================================================
-- LEGACY: buildFillTypeList (kept for tests T14)
-- =============================================================================

function RmSettingsFrame:buildFillTypeList()
    local fillTypes = {}

    if g_fillTypeManager == nil then
        return fillTypes
    end

    for _, fillType in pairs(g_fillTypeManager:getFillTypes()) do
        if fillType.name ~= nil and fillType.name ~= "UNKNOWN" then
            table.insert(fillTypes, {
                name = fillType.name,
                title = fillType.title or fillType.name
            })
        end
    end

    table.sort(fillTypes, function(a, b)
        return a.title:lower() < b.title:lower()
    end)

    return fillTypes
end

-- =============================================================================
-- CALLBACK HANDLERS
-- =============================================================================

function RmSettingsFrame:onClickEnableExpiration(state, _element)
    Log:trace(">>> onClickEnableExpiration(state=%s)", tostring(state))

    -- Skip if this is a programmatic refresh (not user interaction)
    if RmSettingsFrame.isRefreshing then
        Log:trace("    skipped (isRefreshing)")
        return
    end

    if not self:isAdmin() then
        return
    end

    local enabled = (state == 2) -- BinaryOption: 1=off, 2=on

    if g_server then
        RmFreshSettings:setGlobal("enableExpiration", enabled)
    else
        if RmSettingsChangeRequestEvent then
            g_client:getServerConnection():sendEvent(
                RmSettingsChangeRequestEvent.new("setGlobal", "enableExpiration", enabled)
            )
        end
    end

    Log:trace("<<< onClickEnableExpiration")
end

function RmSettingsFrame:onClickShowWarnings(state, _element)
    Log:trace(">>> onClickShowWarnings(state=%s)", tostring(state))

    -- Skip if this is a programmatic refresh (not user interaction)
    if RmSettingsFrame.isRefreshing then
        Log:trace("    skipped (isRefreshing)")
        return
    end

    if not self:isAdmin() then
        return
    end

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

    -- Update warningHoursSelector disabled state
    self:updateReadonlyState()

    Log:trace("<<< onClickShowWarnings")
end

function RmSettingsFrame:onClickShowAgeDisplay(state, _element)
    Log:trace(">>> onClickShowAgeDisplay(state=%s)", tostring(state))

    -- Skip if this is a programmatic refresh (not user interaction)
    if RmSettingsFrame.isRefreshing then
        Log:trace("    skipped (isRefreshing)")
        return
    end

    if not self:isAdmin() then
        return
    end

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

    Log:trace("<<< onClickShowAgeDisplay")
end

function RmSettingsFrame:findWarningHoursState(hours)
    for i, opt in ipairs(RmSettingsFrame.WARNING_HOURS_OPTIONS) do
        if opt.hours == hours then
            return i
        end
    end
    return 3  -- Default to 24h (index 3)
end

function RmSettingsFrame:onClickWarningHours(state, _element)
    Log:trace(">>> onClickWarningHours(state=%s)", tostring(state))

    if RmSettingsFrame.isRefreshing then
        Log:trace("    skipped (isRefreshing)")
        return
    end

    if not self:isAdmin() then
        return
    end

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

    Log:trace("<<< onClickWarningHours")
end

function RmSettingsFrame:onResetDefaults()
    Log:trace(">>> onResetDefaults()")

    if not self:isAdmin() then
        return
    end

    -- YesNoDialog.show(callback, target, text, title, yesText, noText)
    YesNoDialog.show(
        self.onResetConfirmed,
        self,
        g_i18n:getText("fresh_settings_resetConfirm"),
        g_i18n:getText("ui_attention")
    )
end

function RmSettingsFrame:onResetConfirmed(yes)
    local selectors = RmSettingsFrame.fillTypeSelectorsShared or {}
    Log:debug(">>> onResetConfirmed(yes=%s, self=%s, sharedSelectors=%d)",
        tostring(yes), tostring(self), self:tableCount(selectors))

    if not yes then
        return
    end

    if g_server then
        RmFreshSettings:resetAllOverrides()
        -- Refresh using SELF (per-instance selectors now work correctly)
        self:refreshData()
        Log:info("SETTINGS_UI: Reset to defaults complete")
    else
        if RmSettingsChangeRequestEvent then
            g_client:getServerConnection():sendEvent(
                RmSettingsChangeRequestEvent.new("resetAll", nil, nil)
            )
        end
    end
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

--- Update disabled state of all controls based on admin status
--- Non-admin clients get disabled controls (grayed out)
--- Uses module-level fillTypeSelectorsShared (works across all frame instances)
function RmSettingsFrame:updateReadonlyState()
    local isAdmin = self:isAdmin()
    local disabled = not isAdmin

    -- Disable global checkboxes
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

    -- Disable all fillType selectors (using shared table)
    -- Fix C: Disable selector and ALL its children (buttons have dynamic names in profiles)
    local selectors = RmSettingsFrame.fillTypeSelectorsShared or {}
    local selectorCount = 0
    for fillTypeName, selector in pairs(selectors) do
        selector:setDisabled(disabled)
        selectorCount = selectorCount + 1
        -- Disable all child elements (arrow buttons, etc.)
        local children = selector.elements or {}
        local childCount = 0
        for _, child in ipairs(children) do
            if child.setDisabled then
                child:setDisabled(disabled)
                childCount = childCount + 1
            end
        end
        -- DIAGNOSTIC: Log first few selectors to verify disable
        if fillTypeName == "WHEAT" or fillTypeName == "BARLEY" then
            Log:info("DIAG_DISABLE: %s selector=%s disabled=%s children=%d",
                fillTypeName, tostring(selector), tostring(disabled), childCount)
        end
    end

    Log:debug("SETTINGS_UI: readonly=%s (isAdmin=%s, selectors=%d, self=%s)",
        tostring(disabled), tostring(isAdmin), selectorCount, tostring(self))
end

-- =============================================================================
-- XML onCreate CALLBACKS
-- =============================================================================

--- Called by XML onCreate attribute to apply alternating row colors
-- Uses InGameMenuSettingsFrame.COLOR_ALTERNATING from base game
function RmSettingsFrame:onCreateSettingRow(element)
    element:setImageColor(nil, table.unpack(InGameMenuSettingsFrame.COLOR_ALTERNATING[self.isEvenRow]))
    self.isEvenRow = not self.isEvenRow
end
