--[[
    RmStorageDetailFrame.lua
    Storage Detail tab - two-panel layout (left: storage list with category selector, right: per-fillType breakdown)
]]

RmStorageDetailFrame = {}
local RmStorageDetailFrame_mt = Class(RmStorageDetailFrame, TabbedMenuFrameElement)

local Log = RmLogging.getLogger("Fresh")

local modDirectory = g_currentModDirectory

-- Visible row thresholds for scrollbar visibility
RmStorageDetailFrame.LEFT_VISIBLE_ROWS = 9   -- 740px / ~80px effective (100px - 20px overlap)
RmStorageDetailFrame.RIGHT_VISIBLE_ROWS = 12  -- 600px / 48px per row

-- Category filter functions (entry → boolean)
-- Husbandry buildings register via both PlaceableAdapter ("placeable") and
-- HusbandryFoodAdapter ("husbandryfood"), sharing the same uniqueId.
-- getStorageList groups by uniqueId so the entityType is non-deterministic.
-- We detect husbandries via isHusbandry flag (set in enrichStorageData) to
-- ensure they always appear in Husbandries, never in Placeables.
RmStorageDetailFrame.CATEGORY_FILTERS = {
    [1] = function(entry) -- Placeables (excludes husbandries)
        return (entry.entityType == "placeable" or entry.entityType == "stored") and not entry.isHusbandry
    end,
    [2] = function(entry) -- Husbandries
        return entry.entityType == "husbandryfood" or entry.isHusbandry
    end,
    [3] = function(entry) -- Vehicles
        return entry.entityType == "vehicle"
    end,
    [4] = function(entry) -- Bales & Pallets
        return entry.entityType == "itemsInWorld"
    end,
}

-- =============================================================================
-- CONSTRUCTOR
-- =============================================================================

function RmStorageDetailFrame.new()
    local self = RmStorageDetailFrame:superClass().new(nil, RmStorageDetailFrame_mt)
    self.name = "RmStorageDetailFrame"

    -- Left panel state
    self.allStorageData = {}   -- Full unfiltered list from Manager
    self.storageData = {}      -- Filtered by current category

    -- Right panel state
    self.detailData = {}
    self.selectedStorage = nil
    self.currentDetail = nil   -- Full detail result from Manager

    -- Category selector state
    self.currentCategory = 1

    return self
end

function RmStorageDetailFrame.setupGui()
    local frame = RmStorageDetailFrame.new()
    g_gui:loadGui(
        Utils.getFilename("gui/storageDetailFrame.xml", modDirectory),
        "RmStorageDetailFrame",
        frame,
        true
    )
    Log:debug("RmStorageDetailFrame.setupGui() complete")
end

-- =============================================================================
-- LIFECYCLE
-- =============================================================================

function RmStorageDetailFrame:onGuiSetupFinished()
    RmStorageDetailFrame:superClass().onGuiSetupFinished(self)

    -- Setup category selector with 4 entity type categories
    if self.categorySelector then
        self.categorySelector:setTexts({
            g_i18n:getText("fresh_category_placeables"),
            g_i18n:getText("fresh_category_husbandries"),
            g_i18n:getText("fresh_category_vehicles"),
            g_i18n:getText("fresh_category_bales_pallets"),
        })
        self.categorySelector:setState(1, true)
    end

    -- Setup left list data source and delegate
    if self.storageList then
        self.storageList:setDataSource(self)
        self.storageList:setDelegate(self)
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

    Log:debug("RmStorageDetailFrame:onGuiSetupFinished() complete")
end

function RmStorageDetailFrame:onFrameOpen()
    RmStorageDetailFrame:superClass().onFrameOpen(self)
    self:updateCategoryDots()
    self:refreshData()

    -- Set initial focus to left list
    if self.storageList then
        FocusManager:setFocus(self.storageList)
    end
end

function RmStorageDetailFrame:onFrameClose()
    RmStorageDetailFrame:superClass().onFrameClose(self)
end

-- =============================================================================
-- CATEGORY DOTS
-- =============================================================================

--- Create dot indicators for the category selector (base game pattern)
--- Clones the RoundCorner dot template once per category into the dot box.
--- Each dot's getIsSelected() highlights when it matches the current selector state.
function RmStorageDetailFrame:updateCategoryDots()
    -- Unlink template on first use (keep Lua reference for cloning)
    if self.categoryDotTemplate and self.categoryDotTemplate.parent then
        self.categoryDotTemplate:unlinkElement()
        FocusManager:removeElement(self.categoryDotTemplate)
    end

    if not self.categoryDotBox or not self.categoryDotTemplate then return end

    -- Clear existing dots
    for i, dot in pairs(self.categoryDotBox.elements) do
        dot:delete()
        self.categoryDotBox.elements[i] = nil
    end

    -- Create one dot per category (4 fixed categories)
    local numCategories = 4
    for i = 1, numCategories do
        self.categoryDotTemplate:clone(self.categoryDotBox).getIsSelected = function()
            return self.categorySelector:getState() == i
        end
    end

    self.categoryDotBox:invalidateLayout()
    self.categoryDotBox:setVisible(numCategories > 1)
end

-- =============================================================================
-- DATA REFRESH
-- =============================================================================

function RmStorageDetailFrame:refreshData()
    local farmId = g_currentMission:getFarmId()
    Log:debug("STORAGE_DETAIL_REFRESH: farmId=%d", farmId or 0)

    -- Fetch all storages from Manager
    self.allStorageData = RmFreshManager:getStorageList(farmId)

    -- Enrich entries with husbandry detection (before filtering)
    self:enrichStorageData()

    -- Resolve shop images for each entry (cached as entry.imageFilename)
    self:resolveShopImages()

    -- Sort alphabetically by entityName (once; filtering preserves order)
    table.sort(self.allStorageData, function(a, b)
        return (a.entityName or "") < (b.entityName or "")
    end)

    -- Filter by current category
    self:filterByCategory()

    -- Auto-select first item if available
    -- Note: setSelectedIndex triggers onListSelectionChanged (via delegate),
    -- which calls refreshDetailPanel. No need to call it again here.
    if #self.storageData > 0 then
        self.selectedStorage = self.storageData[1]
        if self.storageList then
            self.storageList:setSelectedIndex(1)
        end
    else
        self.selectedStorage = nil
        self.currentDetail = nil
        self.detailData = {}
        if self.detailList then
            self.detailList:reloadData()
        end
    end

    self:updateEmptyState()
    self:updateDetailEmptyState()
    self:updateScrollbarVisibility()

    Log:debug("STORAGE_DETAIL_REFRESH: %d storages loaded (%d in category %d)",
        #self.allStorageData, #self.storageData, self.currentCategory)
end

--- Detect husbandry buildings and flag entries
--- Husbandry buildings may appear with entityType "placeable" due to
--- non-deterministic grouping in getStorageList (pairs() iteration order)
function RmStorageDetailFrame:enrichStorageData()
    -- Build set of husbandry uniqueIds from live placeables
    local husbandryIds = {}
    if g_currentMission.placeableSystem then
        for _, placeable in ipairs(g_currentMission.placeableSystem.placeables) do
            if placeable.uniqueId and placeable.spec_husbandry then
                husbandryIds[placeable.uniqueId] = true
            end
        end
    end

    for _, entry in ipairs(self.allStorageData) do
        entry.isHusbandry = husbandryIds[entry.uniqueId] or false
    end
end

--- Resolve shop images for all storage entries using O(N+M) lookup map
function RmStorageDetailFrame:resolveShopImages()
    -- Build uniqueId → entity lookup map once
    local entityMap = {}
    if g_currentMission.placeableSystem then
        for _, placeable in ipairs(g_currentMission.placeableSystem.placeables) do
            if placeable.uniqueId and placeable.getImageFilename then
                entityMap[placeable.uniqueId] = placeable
            end
        end
    end
    if g_currentMission.vehicleSystem then
        for _, vehicle in ipairs(g_currentMission.vehicleSystem.vehicles) do
            if vehicle.uniqueId and vehicle.getImageFilename then
                entityMap[vehicle.uniqueId] = vehicle
            end
        end
    end

    -- Resolve image for each entry
    local squareBaleImage = nil
    local squareBaleFillType = g_fillTypeManager:getFillTypeByName("SQUAREBALE_GRASS")
    if squareBaleFillType and squareBaleFillType.hudOverlayFilename then
        squareBaleImage = squareBaleFillType.hudOverlayFilename
    end

    for _, entry in ipairs(self.allStorageData) do
        if entry.entityType == "itemsInWorld" then
            entry.imageFilename = squareBaleImage
            entry.isHudOverlay = true  -- Flag for icon sizing
        else
            local entity = entityMap[entry.uniqueId]
            if entity then
                entry.imageFilename = entity:getImageFilename()
            else
                entry.imageFilename = nil
            end
            entry.isHudOverlay = false
        end
    end
end

-- =============================================================================
-- CATEGORY SELECTOR
-- =============================================================================

function RmStorageDetailFrame:onCategoryChanged(state)
    self.currentCategory = state
    self:filterByCategory()

    -- Auto-select first item in filtered list
    if #self.storageData > 0 then
        self.selectedStorage = self.storageData[1]
        self:refreshDetailPanel()
        if self.storageList then
            self.storageList:setSelectedIndex(1)
        end
    else
        self.selectedStorage = nil
        self.currentDetail = nil
        self.detailData = {}
        if self.detailList then
            self.detailList:reloadData()
        end
    end

    self:updateEmptyState()
    self:updateDetailEmptyState()
    self:updateScrollbarVisibility()
end

function RmStorageDetailFrame:filterByCategory()
    local filterFn = RmStorageDetailFrame.CATEGORY_FILTERS[self.currentCategory]
    self.storageData = {}

    for _, entry in ipairs(self.allStorageData) do
        if filterFn(entry) then
            table.insert(self.storageData, entry)
        end
    end

    -- No sort needed: allStorageData is pre-sorted alphabetically in refreshData()
    if self.storageList then
        self.storageList:reloadData()
    end
end

-- =============================================================================
-- LEFT LIST SELECTION
-- =============================================================================

function RmStorageDetailFrame:onListSelectionChanged(list, _section, index)
    -- CRITICAL: prevent recursive calls during reloadData()
    if g_gui.currentlyReloading then return end

    if list == self.storageList then
        local entry = self.storageData[index]
        if entry then
            self.selectedStorage = entry
            self:refreshDetailPanel()
            self:updateDetailEmptyState()
            self:updateScrollbarVisibility()
        end
    end
end

-- =============================================================================
-- RIGHT PANEL REFRESH
-- =============================================================================

function RmStorageDetailFrame:refreshDetailPanel()
    if self.selectedStorage == nil then return end

    local farmId = g_currentMission:getFarmId()
    local detail = RmFreshManager:getStorageDetail(self.selectedStorage.uniqueId, farmId)
    local fillTypes = detail and detail.fillTypes or {}

    if #fillTypes == 0 then
        self.currentDetail = nil
        self.detailData = {}
        if self.detailList then
            self.detailList:reloadData()
        end
        return
    end

    self.currentDetail = detail
    self.detailData = fillTypes

    -- Sort by amount descending, tie-break by fillTypeTitle ascending
    table.sort(self.detailData, function(a, b)
        if a.amount ~= b.amount then
            return a.amount > b.amount
        end
        return (a.fillTypeTitle or "") < (b.fillTypeTitle or "")
    end)

    -- Update detail header
    self:updateDetailHeader(detail)

    -- Reload detail list
    if self.detailList then
        self.detailList:reloadData()
    end

    Log:debug("STORAGE_DETAIL_PANEL: %s - %d fillTypes, %.0f total",
        detail.entityName, #self.detailData, detail.totalAmount or 0)
end

-- =============================================================================
-- DETAIL HEADER
-- =============================================================================

function RmStorageDetailFrame:updateDetailHeader(detail)
    -- Title (storage name, uppercase via profile)
    if self.detailTitle then
        self.detailTitle:setText(detail.entityName or "Unknown")
    end

    -- Total amount
    if self.detailTotal then
        local totalDisplay = g_i18n:formatNumber(detail.totalAmount or 0, 0) .. " L"
        self.detailTotal:setText(string.format(
            g_i18n:getText("fresh_storage_detail_total"), totalDisplay
        ))
    end
end

-- =============================================================================
-- DATA SOURCE METHODS (SmoothList) - Handles BOTH lists
-- =============================================================================

function RmStorageDetailFrame:getNumberOfItemsInSection(list, _section)
    if list == self.storageList then
        return #self.storageData
    elseif list == self.detailList then
        return #self.detailData
    end
    return 0
end

function RmStorageDetailFrame:populateCellForItemInSection(list, _section, index, cell)
    if list == self.storageList then
        self:populateStorageCell(index, cell)
    elseif list == self.detailList then
        self:populateDetailCell(index, cell)
    end
end

-- =============================================================================
-- LEFT LIST: Populate Storage Cell
-- =============================================================================

function RmStorageDetailFrame:populateStorageCell(index, cell)
    local entry = self.storageData[index]
    if entry == nil then return end

    -- Storage icon (shop image or HUD overlay)
    local iconElement = cell:getAttribute("storageIcon")
    if iconElement then
        if entry.imageFilename and entry.imageFilename ~= "" then
            iconElement:setImageFilename(entry.imageFilename)
            iconElement:setVisible(true)
        else
            iconElement:setVisible(false)
        end
    end

    -- Storage name
    local nameElement = cell:getAttribute("storageName")
    if nameElement then
        nameElement:setText(entry.entityName or "Unknown")
    end
end

-- =============================================================================
-- RIGHT LIST: Populate Detail Cell
-- =============================================================================

function RmStorageDetailFrame:populateDetailCell(index, cell)
    local entry = self.detailData[index]
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
        nameElement:setText(entry.fillTypeTitle or "")
    end

    -- Class label (conditional on storageAgingEnabled)
    local classElement = cell:getAttribute("classLabel")
    if classElement then
        if RmFreshSettings.storageAgingEnabled and entry.effectiveClassName then
            classElement:setText(entry.effectiveClassName)
            classElement:setVisible(true)
        else
            classElement:setText("")
            classElement:setVisible(false)
        end
    end

    -- Age bucket amounts (4 columns)
    local threshold = RmFreshSettings:getExpiration(entry.fillTypeName)
    if threshold then
        local buckets = RmFreshAgeDisplay.getAgeDistribution(
            entry.batches or {}, threshold, RmFreshInfoBox.COLORS
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
    else
        -- No threshold: clear all buckets
        local bucketNames = {"freshAmount", "goodAmount", "warningAmount", "criticalAmount"}
        for i = 1, 4 do
            local el = cell:getAttribute(bucketNames[i])
            if el then
                el:setText("-")
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

function RmStorageDetailFrame:updateEmptyState()
    local hasData = #self.storageData > 0
    local farmId = g_currentMission:getFarmId()

    if self.emptyState then
        if farmId == nil or farmId == 0 then
            self.emptyState:setText(g_i18n:getText("fresh_no_farm"))
        else
            self.emptyState:setText(g_i18n:getText("fresh_storage_detail_empty"))
        end
        self.emptyState:setVisible(not hasData)
    end

    if self.storageList then
        self.storageList:setVisible(hasData)
    end
end

function RmStorageDetailFrame:updateDetailEmptyState()
    local hasSelection = self.selectedStorage ~= nil and self.currentDetail ~= nil
    local hasData = #self.storageData > 0

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
            self.detailEmptyState:setText(g_i18n:getText("fresh_storage_detail_no_selection"))
            self.detailEmptyState:setVisible(true)
        else
            self.detailEmptyState:setVisible(false)
        end
    end
end

-- =============================================================================
-- SCROLLBAR VISIBILITY
-- =============================================================================

function RmStorageDetailFrame:updateScrollbarVisibility()
    if self.storageSliderBox then
        self.storageSliderBox:setVisible(#self.storageData > RmStorageDetailFrame.LEFT_VISIBLE_ROWS)
    end
    if self.detailSliderBox then
        self.detailSliderBox:setVisible(#self.detailData > RmStorageDetailFrame.RIGHT_VISIBLE_ROWS)
    end
end
