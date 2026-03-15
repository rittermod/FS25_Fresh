--[[
    RmFillTypeDetailFrame.lua
    FillType Detail tab - two-panel layout (left: fillType list, right: per-storage breakdown)
]]

RmFillTypeDetailFrame = {}
local RmFillTypeDetailFrame_mt = Class(RmFillTypeDetailFrame, TabbedMenuFrameElement)

local Log = RmLogging.getLogger("Fresh")

local modDirectory = g_currentModDirectory

-- Visible row thresholds for scrollbar visibility
RmFillTypeDetailFrame.LEFT_VISIBLE_ROWS = 9   -- 740px / ~80px effective (100px - 20px overlap)
RmFillTypeDetailFrame.RIGHT_VISIBLE_ROWS = 12  -- 600px / 48px per row

-- =============================================================================
-- CONSTRUCTOR
-- =============================================================================

function RmFillTypeDetailFrame.new()
    local self = RmFillTypeDetailFrame:superClass().new(nil, RmFillTypeDetailFrame_mt)
    self.name = "RmFillTypeDetailFrame"

    -- Left panel state
    self.fillTypeData = {}

    -- Right panel state
    self.detailData = {}
    self.selectedFillType = nil
    self.currentDetail = nil  -- Full detail result from Manager

    return self
end

function RmFillTypeDetailFrame.setupGui()
    local frame = RmFillTypeDetailFrame.new()
    g_gui:loadGui(
        Utils.getFilename("gui/fillTypeDetailFrame.xml", modDirectory),
        "RmFillTypeDetailFrame",
        frame,
        true
    )
    Log:debug("RmFillTypeDetailFrame.setupGui() complete")
end

-- =============================================================================
-- LIFECYCLE
-- =============================================================================

function RmFillTypeDetailFrame:onGuiSetupFinished()
    RmFillTypeDetailFrame:superClass().onGuiSetupFinished(self)

    -- Setup category selector (single option for visual consistency)
    if self.categorySelector then
        self.categorySelector:setTexts({g_i18n:getText("fresh_column_type")})
        self.categorySelector:setState(1, true)
    end

    -- Setup left list data source and delegate
    if self.fillTypeList then
        self.fillTypeList:setDataSource(self)
        self.fillTypeList:setDelegate(self)
    end

    -- Setup right list data source and delegate
    if self.detailList then
        self.detailList:setDataSource(self)
        self.detailList:setDelegate(self)
    end

    -- Cache class column header reference for show/hide
    if self.detailTableHeader then
        for _, child in ipairs(self.detailTableHeader.elements) do
            if child.name == "classColumnHeader" then
                self.classColumnHeader = child
                break
            end
        end
    end

    Log:debug("RmFillTypeDetailFrame:onGuiSetupFinished() complete")
end

function RmFillTypeDetailFrame:onFrameOpen()
    RmFillTypeDetailFrame:superClass().onFrameOpen(self)
    self:refreshData()

    -- Set initial focus to left list
    if self.fillTypeList then
        FocusManager:setFocus(self.fillTypeList)
    end
end

function RmFillTypeDetailFrame:onFrameClose()
    RmFillTypeDetailFrame:superClass().onFrameClose(self)
end

-- =============================================================================
-- DATA REFRESH
-- =============================================================================

function RmFillTypeDetailFrame:refreshData()
    local farmId = g_currentMission:getFarmId()
    Log:debug("FILLTYPE_DETAIL_REFRESH: farmId=%d", farmId or 0)

    -- Refresh left panel data
    self.fillTypeData = RmFreshManager:getInventoryList(farmId, "fillType")

    if self.fillTypeList then
        self.fillTypeList:reloadData()
    end

    -- Auto-select first item if available
    -- Note: setSelectedIndex triggers onListSelectionChanged (via delegate),
    -- which calls refreshDetailPanel. No need to call it again here.
    if #self.fillTypeData > 0 then
        self.selectedFillType = self.fillTypeData[1]
        if self.fillTypeList then
            self.fillTypeList:setSelectedIndex(1)
        end
    else
        self.selectedFillType = nil
        self.currentDetail = nil
        self.detailData = {}
        if self.detailList then
            self.detailList:reloadData()
        end
    end

    self:updateEmptyState()
    self:updateDetailEmptyState()
    self:updateScrollbarVisibility()

    Log:debug("FILLTYPE_DETAIL_REFRESH: %d fillTypes loaded", #self.fillTypeData)
end

-- =============================================================================
-- LEFT LIST SELECTION
-- =============================================================================

function RmFillTypeDetailFrame:onListSelectionChanged(list, _section, index)
    -- CRITICAL: prevent recursive calls during reloadData()
    if g_gui.currentlyReloading then return end

    if list == self.fillTypeList then
        local entry = self.fillTypeData[index]
        if entry then
            self.selectedFillType = entry
            self:refreshDetailPanel()
            self:updateDetailEmptyState()
            self:updateScrollbarVisibility()
        end
    end
end

-- =============================================================================
-- RIGHT PANEL REFRESH
-- =============================================================================

function RmFillTypeDetailFrame:refreshDetailPanel()
    if self.selectedFillType == nil then return end

    local farmId = g_currentMission:getFarmId()
    local detail = RmFreshManager:getFillTypeDetail(self.selectedFillType.fillTypeName, farmId)
    if detail == nil then
        self.currentDetail = nil
        self.detailData = {}
        if self.detailList then
            self.detailList:reloadData()
        end
        return
    end

    self.currentDetail = detail

    -- Aggregate containers that share the same uniqueId (e.g., multiple pallets in one building)
    local aggregated = {}
    local byUniqueId = {}
    for _, entry in ipairs(detail.containers or {}) do
        local key = entry.uniqueId
        if key and byUniqueId[key] then
            -- Merge into existing entry
            local existing = byUniqueId[key]
            existing.amount = existing.amount + entry.amount
            for _, batch in ipairs(entry.batches or {}) do
                table.insert(existing.mergedBatches, batch)
            end
        else
            -- New entry (copy fields, create merged batches array)
            local merged = {
                containerId = entry.containerId,
                entityType = entry.entityType,
                storageName = entry.storageName,
                uniqueId = entry.uniqueId,
                amount = entry.amount,
                mergedBatches = {},
                effectiveClass = entry.effectiveClass,
                className = entry.className,
                multiplier = entry.multiplier,
                expiresInDisplay = entry.expiresInDisplay,
            }
            for _, batch in ipairs(entry.batches or {}) do
                table.insert(merged.mergedBatches, batch)
            end
            table.insert(aggregated, merged)
            if key then
                byUniqueId[key] = merged
            end
        end
    end

    -- Use mergedBatches for age distribution, recalculate expiresInDisplay for merged entries
    local daysPerPeriod = (g_currentMission and g_currentMission.environment
        and g_currentMission.environment.daysPerPeriod) or 1
    for _, entry in ipairs(aggregated) do
        entry.batches = entry.mergedBatches
        entry.mergedBatches = nil
        -- Recalculate expiry from oldest batch across all merged containers
        local oldestAge = 0
        for _, batch in ipairs(entry.batches) do
            if batch.ageInPeriods > oldestAge then
                oldestAge = batch.ageInPeriods
            end
        end
        if detail.threshold then
            entry.expiresInDisplay = RmBatch.formatExpiresIn(
                { ageInPeriods = oldestAge }, detail.threshold, daysPerPeriod, entry.multiplier)
        end
    end

    self.detailData = aggregated

    -- Sort by amount descending, tie-break by storageName ascending
    table.sort(self.detailData, function(a, b)
        if a.amount ~= b.amount then
            return a.amount > b.amount
        end
        return (a.storageName or "") < (b.storageName or "")
    end)

    -- Update detail header
    self:updateDetailHeader(detail)

    -- Reload detail list
    if self.detailList then
        self.detailList:reloadData()
    end

    Log:debug("FILLTYPE_DETAIL_PANEL: %s - %d containers, %.0f total",
        detail.fillTypeName, #self.detailData, detail.totalAmount or 0)
end

-- =============================================================================
-- DETAIL HEADER
-- =============================================================================

function RmFillTypeDetailFrame:updateDetailHeader(detail)
    -- Title
    if self.detailTitle then
        self.detailTitle:setText(detail.fillTypeTitle or detail.fillTypeName)
    end

    -- Total amount
    if self.detailTotal then
        local totalDisplay = g_i18n:formatNumber(detail.totalAmount or 0, 0) .. " L"
        self.detailTotal:setText(string.format(
            g_i18n:getText("fresh_filltype_detail_total"), totalDisplay
        ))
    end

end

-- =============================================================================
-- DATA SOURCE METHODS (SmoothList) - Handles BOTH lists
-- =============================================================================

function RmFillTypeDetailFrame:getNumberOfItemsInSection(list, _section)
    if list == self.fillTypeList then
        return #self.fillTypeData
    elseif list == self.detailList then
        return #self.detailData
    end
    return 0
end

function RmFillTypeDetailFrame:populateCellForItemInSection(list, _section, index, cell)
    if list == self.fillTypeList then
        self:populateFillTypeCell(index, cell)
    elseif list == self.detailList then
        self:populateDetailCell(index, cell)
    end
end

-- =============================================================================
-- LEFT LIST: Populate FillType Cell
-- =============================================================================

function RmFillTypeDetailFrame:populateFillTypeCell(index, cell)
    local entry = self.fillTypeData[index]
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

    -- Total amount
    local amountElement = cell:getAttribute("fillTypeAmount")
    if amountElement then
        amountElement:setText(entry.amountDisplay)
    end
end

-- =============================================================================
-- RIGHT LIST: Populate Detail Cell
-- =============================================================================

function RmFillTypeDetailFrame:populateDetailCell(index, cell)
    local entry = self.detailData[index]
    if entry == nil then return end

    local detail = self.currentDetail

    -- Storage name
    local nameElement = cell:getAttribute("storageName")
    if nameElement then
        nameElement:setText(entry.storageName or "Unknown")
    end

    -- Class label (conditional on storageAgingEnabled)
    local classElement = cell:getAttribute("classLabel")
    if classElement then
        if RmFreshSettings.storageAgingEnabled and entry.className then
            classElement:setText(entry.className)
            classElement:setVisible(true)
        else
            classElement:setText("")
            classElement:setVisible(false)
        end
    end

    -- Age bucket amounts (4 columns)
    if detail then
        local buckets = RmFreshAgeDisplay.getAgeDistribution(
            entry.batches or {}, detail.threshold, RmFreshInfoBox.COLORS
        )
        local bucketNames = {"freshAmount", "goodAmount", "warningAmount", "criticalAmount"}
        for i = 1, 4 do
            local el = cell:getAttribute(bucketNames[i])
            if el then
                if buckets[i].amount > 0 then
                    el:setText(g_i18n:formatNumber(buckets[i].amount, 0) .. " L")
                else
                    el:setText("-")
                end
            end
        end
    end

    -- Expiry time
    local expiresElement = cell:getAttribute("expiresIn")
    if expiresElement then
        expiresElement:setText(entry.expiresInDisplay or "")
    end
end

-- =============================================================================
-- EMPTY STATES
-- =============================================================================

function RmFillTypeDetailFrame:updateEmptyState()
    local hasData = #self.fillTypeData > 0
    local farmId = g_currentMission:getFarmId()

    if self.emptyState then
        if farmId == nil or farmId == 0 then
            self.emptyState:setText(g_i18n:getText("fresh_no_farm"))
        else
            self.emptyState:setText(g_i18n:getText("fresh_filltype_detail_empty"))
        end
        self.emptyState:setVisible(not hasData)
    end

    if self.fillTypeList then
        self.fillTypeList:setVisible(hasData)
    end
end

function RmFillTypeDetailFrame:updateDetailEmptyState()
    local hasSelection = self.selectedFillType ~= nil and self.currentDetail ~= nil
    local hasData = #self.fillTypeData > 0

    -- Detail title/total visibility
    if self.detailTitle then
        self.detailTitle:setVisible(hasSelection)
    end
    if self.detailTotal then
        self.detailTotal:setVisible(hasSelection)
    end

    -- Detail table header visibility
    if self.detailTableHeader then
        self.detailTableHeader:setVisible(hasSelection)
    end
    if self.detailSubHeader then
        self.detailSubHeader:setVisible(hasSelection)
    end

    -- Class column header visibility (based on storageAgingEnabled)
    if self.classColumnHeader then
        self.classColumnHeader:setVisible(hasSelection and RmFreshSettings.storageAgingEnabled)
    end

    -- Detail list visibility
    if self.detailList then
        self.detailList:setVisible(hasSelection)
    end

    -- Detail empty state
    if self.detailEmptyState then
        if not hasData then
            self.detailEmptyState:setVisible(false)  -- Left empty state handles this
        elseif not hasSelection then
            self.detailEmptyState:setText(g_i18n:getText("fresh_filltype_detail_no_selection"))
            self.detailEmptyState:setVisible(true)
        else
            self.detailEmptyState:setVisible(false)
        end
    end
end

-- =============================================================================
-- SCROLLBAR VISIBILITY
-- =============================================================================

function RmFillTypeDetailFrame:updateScrollbarVisibility()
    if self.fillTypeSliderBox then
        self.fillTypeSliderBox:setVisible(#self.fillTypeData > RmFillTypeDetailFrame.LEFT_VISIBLE_ROWS)
    end
    if self.detailSliderBox then
        self.detailSliderBox:setVisible(#self.detailData > RmFillTypeDetailFrame.RIGHT_VISIBLE_ROWS)
    end
end
