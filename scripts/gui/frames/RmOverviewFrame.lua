--[[
    RmOverviewFrame.lua
    Fresh mod Overview tab frame - Inventory display
]]

RmOverviewFrame = {}
local RmOverviewFrame_mt = Class(RmOverviewFrame, TabbedMenuFrameElement)

local Log = RmLogging.getLogger("Fresh")

-- Store mod directory at source time
local modDirectory = g_currentModDirectory

-- Sort options for left table (Inventory by Type)
RmOverviewFrame.SORT_OPTIONS = {
    { id = "fillType", label = "fresh_sort_by_type" },
    { id = "expiring", label = "fresh_sort_by_expiring" },
    { id = "age",      label = "fresh_sort_by_age" },
}

-- Expiry filter options for right table (Expiring Soon)
RmOverviewFrame.EXPIRY_OPTIONS = {
    { hours = 24, label = "fresh_expires_24h" },
    { hours = 48, label = "fresh_expires_48h" },
    { hours = 72, label = "fresh_expires_72h" },
}

-- Status colors
RmOverviewFrame.COLOR_WARNING = { 1, 0.6, 0, 1 }    -- Orange for expiring soon
RmOverviewFrame.COLOR_OK = { 0.3, 0.8, 0.3, 1 }     -- Green for healthy
RmOverviewFrame.COLOR_CRITICAL = { 1, 0.3, 0.3, 1 } -- Red for very soon

-- Visible row threshold for scrollbar visibility
RmOverviewFrame.VISIBLE_ROWS = 14  -- 700px height / 48px per row

function RmOverviewFrame.new()
    Log:trace("RmOverviewFrame.new()")
    local self = RmOverviewFrame:superClass().new(nil, RmOverviewFrame_mt)
    self.name = "RmOverviewFrame"
    -- Left table state
    self.sortBy = "fillType"
    self.inventoryData = {}
    -- Right table state
    self.expiryHours = 24
    self.expiringData = {}
    return self
end

function RmOverviewFrame.setupGui()
    local frame = RmOverviewFrame.new()
    g_gui:loadGui(
        Utils.getFilename("gui/overviewFrame.xml", modDirectory),
        "RmOverviewFrame",
        frame,
        true
    )
    Log:debug("RmOverviewFrame.setupGui() complete")
end

function RmOverviewFrame:onGuiSetupFinished()
    Log:trace("RmOverviewFrame:onGuiSetupFinished()")
    RmOverviewFrame:superClass().onGuiSetupFinished(self)

    -- Setup LEFT list data source and delegate
    if self.inventoryList then
        self.inventoryList:setDataSource(self)
        self.inventoryList:setDelegate(self)
    end

    -- Load saved sort preference (default: fillType)
    local savedSortBy = RmFreshSettings:getGlobal("overviewSortBy") or "fillType"
    self.sortBy = savedSortBy
    local sortState = self:findSortStateByValue(savedSortBy)

    -- Setup LEFT sort selector
    if self.sortSelector then
        local texts = {}
        for _, opt in ipairs(RmOverviewFrame.SORT_OPTIONS) do
            table.insert(texts, g_i18n:getText(opt.label))
        end
        self.sortSelector:setTexts(texts)
        self.sortSelector:setState(sortState, true)
    end

    -- Setup RIGHT list data source and delegate
    if self.expiringList then
        self.expiringList:setDataSource(self)
        self.expiringList:setDelegate(self)
    end

    -- Load saved expiry preference (default: 24 hours)
    local savedExpiryHours = RmFreshSettings:getGlobal("overviewExpiryHours") or 24
    self.expiryHours = savedExpiryHours
    local expiryState = self:findExpiryStateByValue(savedExpiryHours)

    -- Setup RIGHT expiry selector
    if self.expirySelector then
        local texts = {}
        for _, opt in ipairs(RmOverviewFrame.EXPIRY_OPTIONS) do
            table.insert(texts, g_i18n:getText(opt.label))
        end
        self.expirySelector:setTexts(texts)
        self.expirySelector:setState(expiryState, true)
    end

    Log:debug("OVERVIEW_PREFS: loaded sortBy=%s expiryHours=%d", self.sortBy, self.expiryHours)
end

--- Find selector state index for a sort value
---@param value string Sort option id (e.g., "fillType", "expiring", "age")
---@return number State index (1-based)
function RmOverviewFrame:findSortStateByValue(value)
    for i, opt in ipairs(RmOverviewFrame.SORT_OPTIONS) do
        if opt.id == value then
            return i
        end
    end
    return 1  -- Default to first option
end

--- Find selector state index for an expiry hours value
---@param value number Expiry hours (e.g., 24, 48, 72)
---@return number State index (1-based)
function RmOverviewFrame:findExpiryStateByValue(value)
    for i, opt in ipairs(RmOverviewFrame.EXPIRY_OPTIONS) do
        if opt.hours == value then
            return i
        end
    end
    return 1  -- Default to first option
end

function RmOverviewFrame:onFrameOpen()
    RmOverviewFrame:superClass().onFrameOpen(self)
    Log:trace("RmOverviewFrame:onFrameOpen()")
    self:refreshData()
end

function RmOverviewFrame:onFrameClose()
    RmOverviewFrame:superClass().onFrameClose(self)
    Log:trace("RmOverviewFrame:onFrameClose()")
end

-- =============================================================================
-- DATA REFRESH
-- =============================================================================

function RmOverviewFrame:refreshData()
    Log:trace(">>> RmOverviewFrame:refreshData()")

    -- Get current player's farm (CRITICAL for MP isolation)
    local farmId = g_currentMission:getFarmId()
    Log:debug("OVERVIEW_REFRESH: farmId=%d sortBy=%s expiryHours=%d",
        farmId or 0, self.sortBy or "fillType", self.expiryHours or 24)

    -- Refresh LEFT table (Inventory by Type)
    self.inventoryData = RmFreshManager:getInventoryList(farmId, self.sortBy)
    Log:trace("    inventory items loaded: %d", #self.inventoryData)

    if self.inventoryList then
        self.inventoryList:reloadData()
    end

    -- Refresh RIGHT table (Expiring Soon)
    local expiringResult = RmFreshManager:getExpiringWithin(self.expiryHours, farmId)
    self.expiringData = expiringResult.containers or {}
    self.expiringTotalAmount = expiringResult.totalAmount or 0
    Log:trace("    expiring items loaded: %d (total %.0f L)",
        #self.expiringData, self.expiringTotalAmount)

    if self.expiringList then
        self.expiringList:reloadData()
    end

    -- Update summaries and empty states
    self:updateSummaryText()
    self:updateEmptyState()
    self:updateExpiringSummaryText()
    self:updateExpiringEmptyState()
    self:updateScrollbarVisibility()

    Log:trace("<<< RmOverviewFrame:refreshData()")
end

-- =============================================================================
-- LEFT TABLE: Summary and Empty State
-- =============================================================================

function RmOverviewFrame:updateSummaryText()
    if self.summaryText == nil then return end

    local typeCount = #self.inventoryData
    local containerCount = 0
    for _, entry in ipairs(self.inventoryData) do
        containerCount = containerCount + entry.containerCount
    end

    local summaryText = string.format(
        g_i18n:getText("fresh_inventory_summary"),
        typeCount, containerCount
    )
    self.summaryText:setText(summaryText)
end

function RmOverviewFrame:updateEmptyState()
    local hasData = #self.inventoryData > 0
    local farmId = g_currentMission:getFarmId()
    local reason = farmId == 0 and "unowned farm" or (hasData and "has inventory" or "no containers")

    Log:debug("OVERVIEW_EMPTY: hasData=%s farmId=%s (reason: %s)",
        tostring(hasData), tostring(farmId), reason)

    if self.emptyState then
        if farmId == nil or farmId == 0 then
            self.emptyState:setText(g_i18n:getText("fresh_no_farm"))
        else
            self.emptyState:setText(g_i18n:getText("fresh_inventory_empty"))
        end
        self.emptyState:setVisible(not hasData)
    end

    if self.inventoryList then
        self.inventoryList:setVisible(hasData)
    end

    if self.tableHeader then
        self.tableHeader:setVisible(hasData)
    end

    if self.summaryRow then
        self.summaryRow:setVisible(hasData)
    end
end

-- =============================================================================
-- RIGHT TABLE: Summary and Empty State
-- =============================================================================

function RmOverviewFrame:updateExpiringSummaryText()
    if self.expiringSummaryText == nil then return end

    local count = #self.expiringData
    local total = self.expiringTotalAmount or 0

    local summaryText = string.format(
        g_i18n:getText("fresh_expiring_summary"),
        count, total
    )
    self.expiringSummaryText:setText(summaryText)
end

function RmOverviewFrame:updateExpiringEmptyState()
    local hasData = #self.expiringData > 0
    local farmId = g_currentMission:getFarmId()

    if self.expiringEmptyState then
        if farmId == nil or farmId == 0 then
            self.expiringEmptyState:setText(g_i18n:getText("fresh_no_farm"))
        else
            self.expiringEmptyState:setText(g_i18n:getText("fresh_expiring_empty"))
        end
        self.expiringEmptyState:setVisible(not hasData)
    end

    if self.expiringList then
        self.expiringList:setVisible(hasData)
    end

    if self.expiringHeader then
        self.expiringHeader:setVisible(hasData)
    end

    if self.expiringSummaryRow then
        self.expiringSummaryRow:setVisible(hasData)
    end
end

-- =============================================================================
-- SCROLLBAR VISIBILITY
-- =============================================================================

function RmOverviewFrame:updateScrollbarVisibility()
    -- Left table (Expiring Soon)
    if self.expiringSliderBox then
        self.expiringSliderBox:setVisible(#self.expiringData > RmOverviewFrame.VISIBLE_ROWS)
    end
    -- Right table (Inventory by Type)
    if self.inventorySliderBox then
        self.inventorySliderBox:setVisible(#self.inventoryData > RmOverviewFrame.VISIBLE_ROWS)
    end
end

-- =============================================================================
-- SELECTOR HANDLERS
-- =============================================================================

function RmOverviewFrame:onSortChanged(state, _element)
    Log:trace(">>> RmOverviewFrame:onSortChanged(state=%d)", state)
    local option = RmOverviewFrame.SORT_OPTIONS[state]
    if option then
        self.sortBy = option.id
        -- Save preference (persisted to rm_FreshSettings.xml on game save)
        RmFreshSettings.userOverrides.global["overviewSortBy"] = option.id
        Log:debug("OVERVIEW_SORT: changed to %s (saved)", self.sortBy)
        self:refreshData()
    end
    Log:trace("<<< RmOverviewFrame:onSortChanged()")
end

function RmOverviewFrame:onExpiryFilterChanged(state, _element)
    Log:trace(">>> RmOverviewFrame:onExpiryFilterChanged(state=%d)", state)
    local option = RmOverviewFrame.EXPIRY_OPTIONS[state]
    if option then
        self.expiryHours = option.hours
        -- Save preference (persisted to rm_FreshSettings.xml on game save)
        RmFreshSettings.userOverrides.global["overviewExpiryHours"] = option.hours
        Log:debug("OVERVIEW_EXPIRY: changed to %d hours (saved)", self.expiryHours)
        self:refreshData()
    end
    Log:trace("<<< RmOverviewFrame:onExpiryFilterChanged()")
end

-- =============================================================================
-- DATA SOURCE METHODS (SmoothList) - Handles BOTH lists
-- =============================================================================

function RmOverviewFrame:getNumberOfItemsInSection(list, _section)
    if list == self.inventoryList then
        return #self.inventoryData
    elseif list == self.expiringList then
        return #self.expiringData
    end
    return 0
end

function RmOverviewFrame:populateCellForItemInSection(list, _section, index, cell)
    if list == self.inventoryList then
        self:populateInventoryCell(index, cell)
    elseif list == self.expiringList then
        self:populateExpiringCell(index, cell)
    end
end

-- =============================================================================
-- LEFT TABLE: Populate Inventory Cell
-- =============================================================================

function RmOverviewFrame:populateInventoryCell(index, cell)
    local entry = self.inventoryData[index]
    if entry == nil then return end

    -- FillType icon
    local iconElement = cell:getAttribute("fillTypeIcon")
    if iconElement then
        local fillType = g_fillTypeManager:getFillTypeByIndex(entry.fillTypeIndex)
        if fillType and fillType.hudOverlayFilename then
            iconElement:setImageFilename(fillType.hudOverlayFilename)
            iconElement:setVisible(true)
        else
            iconElement:setVisible(false)
        end
    end

    -- FillType name
    local nameElement = cell:getAttribute("fillTypeName")
    if nameElement then
        nameElement:setText(entry.fillTypeTitle)
    end

    -- Amount
    local amountElement = cell:getAttribute("amount")
    if amountElement then
        amountElement:setText(entry.amountDisplay)
    end

    -- Expiring amount (shows how much is at/above 75% threshold)
    local expiringElement = cell:getAttribute("expiringAmount")
    if expiringElement then
        if entry.expiringAmountDisplay then
            expiringElement:setText(entry.expiringAmountDisplay)
            expiringElement:setTextColor(unpack(RmOverviewFrame.COLOR_WARNING))
        else
            expiringElement:setText("-")
            expiringElement:setTextColor(unpack(RmOverviewFrame.COLOR_OK))
        end
    end

    -- Oldest age
    local ageElement = cell:getAttribute("oldestAge")
    if ageElement then
        ageElement:setText(entry.ageDisplay)
    end

    -- Status indicator
    local statusElement = cell:getAttribute("status")
    if statusElement then
        if entry.isWarning then
            statusElement:setText(g_i18n:getText("fresh_status_expiring"))
            statusElement:setTextColor(unpack(RmOverviewFrame.COLOR_WARNING))
        else
            statusElement:setText(g_i18n:getText("fresh_status_ok"))
            statusElement:setTextColor(unpack(RmOverviewFrame.COLOR_OK))
        end
    end
end

-- =============================================================================
-- RIGHT TABLE: Populate Expiring Cell
-- =============================================================================

function RmOverviewFrame:populateExpiringCell(index, cell)
    local entry = self.expiringData[index]
    if entry == nil then return end

    -- FillType icon
    local iconElement = cell:getAttribute("expiringIcon")
    if iconElement then
        local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(entry.fillTypeName)
        local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
        if fillType and fillType.hudOverlayFilename then
            iconElement:setImageFilename(fillType.hudOverlayFilename)
            iconElement:setVisible(true)
        else
            iconElement:setVisible(false)
        end
    end

    -- Product name (fillType title)
    local productElement = cell:getAttribute("expiringProduct")
    if productElement then
        local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(entry.fillTypeName)
        local fillTypeTitle = g_fillTypeManager:getFillTypeTitleByIndex(fillTypeIndex) or entry.fillTypeName
        productElement:setText(fillTypeTitle)
    end

    -- Storage/location name
    local storageElement = cell:getAttribute("expiringStorage")
    if storageElement then
        storageElement:setText(entry.name or "Unknown")
    end

    -- Amount (no color - time column shows urgency)
    local amountElement = cell:getAttribute("expiringAmount")
    if amountElement then
        amountElement:setText(string.format("%.0f L", entry.expiringAmount))
    end

    -- Time left
    local timeLeftElement = cell:getAttribute("expiringTimeLeft")
    if timeLeftElement then
        local hours = entry.expiresInHours or 0
        local timeText
        if hours < 1 then
            timeText = g_i18n:getText("fresh_expires_soon")
        else
            timeText = string.format(g_i18n:getText("fresh_expires_hours"), math.floor(hours))
        end
        timeLeftElement:setText(timeText)

        -- Color based on urgency
        if hours < 12 then
            timeLeftElement:setTextColor(unpack(RmOverviewFrame.COLOR_CRITICAL))
        elseif hours < 24 then
            timeLeftElement:setTextColor(unpack(RmOverviewFrame.COLOR_WARNING))
        else
            timeLeftElement:setTextColor(unpack(RmOverviewFrame.COLOR_OK))
        end
    end
end
