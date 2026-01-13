--[[
    RmStatsFrame.lua
    Fresh mod Statistics tab frame - Loss statistics display
]]

RmStatsFrame = {}
local RmStatsFrame_mt = Class(RmStatsFrame, TabbedMenuFrameElement)

local Log = RmLogging.getLogger("Fresh")

-- Store mod directory at source time
local modDirectory = g_currentModDirectory

RmStatsFrame.MAX_LOG_ENTRIES = 50

-- Visible row threshold for scrollbar visibility
RmStatsFrame.VISIBLE_ROWS = 12  -- 620px height / 48px per row

function RmStatsFrame.new()
    Log:trace("RmStatsFrame.new()")
    local self = RmStatsFrame:superClass().new(nil, RmStatsFrame_mt)
    self.name = "RmStatsFrame"
    self.statsSummary = {}
    self.breakdownData = {}
    self.recentData = {}
    return self
end

function RmStatsFrame.setupGui()
    local frame = RmStatsFrame.new()
    g_gui:loadGui(
        Utils.getFilename("gui/statsFrame.xml", modDirectory),
        "RmStatsFrame",
        frame,
        true
    )
    Log:debug("RmStatsFrame.setupGui() complete")
end

function RmStatsFrame:onGuiSetupFinished()
    Log:trace("RmStatsFrame:onGuiSetupFinished()")
    RmStatsFrame:superClass().onGuiSetupFinished(self)

    -- Setup breakdown list data source and delegate
    if self.breakdownList then
        self.breakdownList:setDataSource(self)
        self.breakdownList:setDelegate(self)
    end

    -- Setup recent list data source and delegate
    if self.recentList then
        self.recentList:setDataSource(self)
        self.recentList:setDelegate(self)
    end
end

function RmStatsFrame:onFrameOpen()
    RmStatsFrame:superClass().onFrameOpen(self)
    Log:trace("RmStatsFrame:onFrameOpen()")
    self:refreshData()
end

function RmStatsFrame:onFrameClose()
    RmStatsFrame:superClass().onFrameClose(self)
    Log:trace("RmStatsFrame:onFrameClose()")
end

-- =============================================================================
-- DATA REFRESH
-- =============================================================================

function RmStatsFrame:refreshData()
    Log:trace(">>> RmStatsFrame:refreshData()")

    -- Get current player's farm (CRITICAL for MP isolation)
    local farmId = g_currentMission:getFarmId()
    Log:debug("STATS_REFRESH: farmId=%d", farmId or 0)

    -- Get statistics from Manager (farm-filtered)
    self.statsSummary = RmFreshManager:getLossStatsSummary(farmId)
    self.breakdownData = self.statsSummary.breakdown or {}
    self.recentData = RmFreshManager:getLossLogRecent(farmId, self.MAX_LOG_ENTRIES)

    Log:trace("    breakdown items: %d, recent items: %d", #self.breakdownData, #self.recentData)

    -- Update summary cards
    self:updateSummaryCards()

    -- Update lists
    if self.breakdownList then
        self.breakdownList:reloadData()
    end
    if self.recentList then
        self.recentList:reloadData()
    end

    -- Update empty states and scrollbar visibility
    self:updateEmptyStates()
    self:updateScrollbarVisibility()

    Log:trace("<<< RmStatsFrame:refreshData()")
end

function RmStatsFrame:updateSummaryCards()
    -- Combine amount and value for display: "850 L / $4,500"
    local todayAmount = self.statsSummary.todayExpiredDisplay or "0 L"
    local todayValue = self.statsSummary.todayValueDisplay or "-"
    local monthAmount = self.statsSummary.thisMonthExpiredDisplay or "0 L"
    local monthValue = self.statsSummary.thisMonthValueDisplay or "-"
    local yearAmount = self.statsSummary.last12MonthsExpiredDisplay or "0 L"
    local yearValue = self.statsSummary.last12MonthsValueDisplay or "-"
    local totalAmount = self.statsSummary.totalExpiredDisplay or "0 L"
    local totalValue = self.statsSummary.totalValueDisplay or "-"

    -- Format: "Amount / Value" (skip value if "-")
    local function formatCard(amount, value)
        if value == "-" then
            return amount
        end
        return string.format("%s / %s", amount, value)
    end

    local today = formatCard(todayAmount, todayValue)
    local month = formatCard(monthAmount, monthValue)
    local year = formatCard(yearAmount, yearValue)
    local total = formatCard(totalAmount, totalValue)

    Log:debug("STATS_CARDS: today=%s, month=%s, 12mo=%s, total=%s", today, month, year, total)

    if self.todayExpiredValue then
        self.todayExpiredValue:setText(today)
    end
    if self.monthExpiredValue then
        self.monthExpiredValue:setText(month)
    end
    if self.last12MonthsExpiredValue then
        self.last12MonthsExpiredValue:setText(year)
    end
    if self.totalExpiredValue then
        self.totalExpiredValue:setText(total)
    end
end

function RmStatsFrame:updateEmptyStates()
    local hasBreakdown = #self.breakdownData > 0
    local hasRecent = #self.recentData > 0
    local farmId = g_currentMission:getFarmId()

    Log:debug("STATS_EMPTY: hasBreakdown=%s, hasRecent=%s, farmId=%s",
        tostring(hasBreakdown), tostring(hasRecent), tostring(farmId))

    -- Breakdown empty state
    if self.breakdownEmpty then
        if farmId == nil or farmId == 0 then
            self.breakdownEmpty:setText(g_i18n:getText("fresh_no_farm"))
        else
            self.breakdownEmpty:setText(g_i18n:getText("fresh_stats_breakdown_empty"))
        end
        self.breakdownEmpty:setVisible(not hasBreakdown)
    end
    if self.breakdownList then
        self.breakdownList:setVisible(hasBreakdown)
    end
    if self.breakdownHeader then
        self.breakdownHeader:setVisible(hasBreakdown)
    end

    -- Recent empty state
    if self.recentEmpty then
        if farmId == nil or farmId == 0 then
            self.recentEmpty:setText(g_i18n:getText("fresh_no_farm"))
        else
            self.recentEmpty:setText(g_i18n:getText("fresh_stats_log_empty"))
        end
        self.recentEmpty:setVisible(not hasRecent)
    end
    if self.recentList then
        self.recentList:setVisible(hasRecent)
    end
    if self.recentHeader then
        self.recentHeader:setVisible(hasRecent)
    end
end

function RmStatsFrame:updateScrollbarVisibility()
    if self.breakdownSliderBox then
        self.breakdownSliderBox:setVisible(#self.breakdownData > RmStatsFrame.VISIBLE_ROWS)
    end
    if self.recentSliderBox then
        self.recentSliderBox:setVisible(#self.recentData > RmStatsFrame.VISIBLE_ROWS)
    end
end

-- =============================================================================
-- DATA SOURCE METHODS (SmoothList)
-- =============================================================================

function RmStatsFrame:getNumberOfItemsInSection(list, _section)
    if list == self.breakdownList then
        return #self.breakdownData
    elseif list == self.recentList then
        return #self.recentData
    end
    return 0
end

function RmStatsFrame:populateCellForItemInSection(list, _section, index, cell)
    if list == self.breakdownList then
        self:populateBreakdownCell(index, cell)
    elseif list == self.recentList then
        self:populateRecentCell(index, cell)
    end
end

-- =============================================================================
-- LEFT TABLE: Populate Breakdown Cell
-- =============================================================================

function RmStatsFrame:populateBreakdownCell(index, cell)
    local entry = self.breakdownData[index]
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

    -- Value (placeholder)
    local valueElement = cell:getAttribute("value")
    if valueElement then
        valueElement:setText(entry.valueDisplay or "")
    end
end

-- =============================================================================
-- RIGHT TABLE: Populate Recent Cell
-- =============================================================================

function RmStatsFrame:populateRecentCell(index, cell)
    local entry = self.recentData[index]
    if entry == nil then return end

    -- DateTime
    local dateTimeElement = cell:getAttribute("dateTime")
    if dateTimeElement then
        dateTimeElement:setText(entry.dateTimeDisplay or "")
    end

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

    -- Value
    local valueElement = cell:getAttribute("value")
    if valueElement then
        valueElement:setText(entry.valueDisplay or "-")
    end

    -- Storage location
    local storageElement = cell:getAttribute("storage")
    if storageElement then
        storageElement:setText(entry.location or "")
    end
end
