--[[
    RmShelfLifeFrame.lua
    Read-only reference frame showing active shelf life per perishable fill type.
    Dual-mode display:
      - Table mode (storageAgingEnabled=true): columns for each storage class
      - Simple mode (storageAgingEnabled=false): single shelf life value
    Uses ScrollingLayout + template clone pattern (same as settings page).
]]

RmShelfLifeFrame = {}
local RmShelfLifeFrame_mt = Class(RmShelfLifeFrame, TabbedMenuFrameElement)

local Log = RmLogging.getLogger("Fresh")

local modDirectory = g_currentModDirectory

--- Storage classes to display as columns (EXPOSED through FROZEN, excludes DISABLED)
RmShelfLifeFrame.DISPLAY_CLASSES = { 0, 1, 2, 3, 4 }

-- =============================================================================
-- CONSTRUCTOR
-- =============================================================================

function RmShelfLifeFrame.new()
    local self = RmShelfLifeFrame:superClass().new(nil, RmShelfLifeFrame_mt)
    self.name = "RmShelfLifeFrame"
    self.rows = {}
    self.populated = false
    self.tableMode = nil  -- nil = not yet determined
    return self
end

function RmShelfLifeFrame.setupGui()
    local frame = RmShelfLifeFrame.new()
    g_gui:loadGui(
        Utils.getFilename("gui/shelfLifeFrame.xml", modDirectory),
        "RmShelfLifeFrame",
        frame,
        true
    )
    Log:debug("RmShelfLifeFrame.setupGui() complete")
end

-- =============================================================================
-- LIFECYCLE
-- =============================================================================

function RmShelfLifeFrame:onGuiSetupFinished()
    RmShelfLifeFrame:superClass().onGuiSetupFinished(self)
    -- Do NOT unlink template here (dual-instance gotcha)
end

function RmShelfLifeFrame:onFrameOpen()
    RmShelfLifeFrame:superClass().onFrameOpen(self)

    -- Determine display mode based on storage aging setting
    local newTableMode = RmFreshSettings.storageAgingEnabled
    if self.tableMode ~= newTableMode then
        self.populated = false  -- Force re-populate on mode change
    end
    self.tableMode = newTableMode

    -- Toggle visibility of table header elements
    if self.tableHeaderRow then
        self.tableHeaderRow:setVisible(newTableMode)
    end
    if self.subheaderRow then
        self.subheaderRow:setVisible(newTableMode)
    end

    if not self.populated then
        self:populate()
    else
        self:refreshValues()
    end
end

-- =============================================================================
-- DATA
-- =============================================================================

--- Get sorted list of perishable fill types with their active shelf life
---@return table Array of { name = string, title = string, period = number, maxBenefitClass = number }
function RmShelfLifeFrame:getPerishableFillTypes()
    local fillTypes = {}

    for fillTypeName, fillTypeData in pairs(RmFreshSettings.allFillTypes or {}) do
        if fillTypeName ~= "UNKNOWN" then
            local period = RmFreshSettings:getExpiration(fillTypeName)
            if period ~= nil then
                local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(fillTypeName)
                if fillTypeIndex == nil then
                    fillTypeIndex = 0
                end
                local maxBenefitClass = RmFreshSettings:getMaxBenefitClass(fillTypeIndex)
                table.insert(fillTypes, {
                    name = fillTypeName,
                    title = fillTypeData.title or fillTypeName,
                    period = period,
                    maxBenefitClass = maxBenefitClass,
                })
            end
        end
    end

    -- Sort alphabetically by localized title (case-insensitive)
    table.sort(fillTypes, function(a, b)
        return a.title:lower() < b.title:lower()
    end)

    return fillTypes
end

--- Calculate effective shelf life for a given base period and storage class
---@param basePeriod number Base shelf life in months (already preset-adjusted)
---@param classValue number Storage class value (0-4)
---@param maxBenefitClass number Maximum beneficial class for this fill type
---@return number|nil Effective shelf life in months, or nil if beyond ceiling
function RmShelfLifeFrame:getEffectiveShelfLife(basePeriod, classValue, maxBenefitClass)
    if classValue > maxBenefitClass then
        return nil
    end
    local multiplier = RmFreshSettings:getClassMultiplier(classValue)
    if multiplier <= 0 then
        return nil
    end
    return basePeriod / multiplier
end

--- Format a shelf life value with fixed 1-decimal formatting
---@param months number Shelf life in months
---@return string Formatted value (e.g., "12.0" or "1.5")
function RmShelfLifeFrame:formatCompactValue(months)
    return string.format("%.1f", months)
end

--- Format a period in months for display (simple mode)
---@param months number Period in months
---@return string Formatted string (e.g., "12 months" or "1.5 months")
function RmShelfLifeFrame:formatPeriod(months)
    if months == math.floor(months) then
        return string.format(g_i18n:getText("fresh_period_months"), months)
    else
        return string.format(g_i18n:getText("fresh_period_months_decimal"), months)
    end
end

-- =============================================================================
-- POPULATE (clone template per fill type)
-- =============================================================================

function RmShelfLifeFrame:populate()
    local layout = self.shelfLifeLayout
    local template = self.rowTemplate

    if not template or not layout then return end

    -- Clear existing rows (required for re-populate on mode change)
    for _, rowData in ipairs(self.rows) do
        if rowData.row then
            rowData.row:delete()
        end
    end
    self.rows = {}

    local fillTypes = self:getPerishableFillTypes()

    -- Show empty state if no perishable fill types
    if self.emptyState then
        self.emptyState:setVisible(#fillTypes == 0)
    end

    if #fillTypes == 0 then
        self.populated = true
        return
    end

    -- Save focus context as safety guard
    local savedFocusData = FocusManager.currentFocusData

    local isTableMode = self.tableMode

    for index, ft in ipairs(fillTypes) do
        local row = template:clone(layout)

        -- Alternating row color (clone doesn't fire onCreate)
        local isEven = (index % 2 == 0)
        row:setImageColor(nil, table.unpack(
            InGameMenuSettingsFrame.COLOR_ALTERNATING[isEven]))

        -- Children by index (matches XML order):
        -- 1=singleValue, 2=fillTypeIcon, 3=titleText, 4-8=classValue0..4
        local singleValue = row.elements[1]
        local iconElement = row.elements[2]
        local titleText = row.elements[3]

        -- Set icon
        local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(ft.name)
        local fillType = fillTypeIndex and g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
        if iconElement then
            if fillType and fillType.hudOverlayFilename then
                iconElement:setImageFilename(fillType.hudOverlayFilename)
                iconElement:setVisible(true)
            else
                iconElement:setVisible(false)
            end
        end

        -- Set title
        if titleText then
            titleText:setText(ft.title)
        end

        -- Collect class value refs
        local classValues = {}
        for i = 0, 4 do
            classValues[i] = row.elements[4 + i]
        end

        if isTableMode then
            -- Table mode: hide single value, show class columns
            if singleValue then
                singleValue:setVisible(false)
            end
            for _, classIdx in ipairs(RmShelfLifeFrame.DISPLAY_CLASSES) do
                local cell = classValues[classIdx]
                if cell then
                    cell:setVisible(true)
                    local effective = self:getEffectiveShelfLife(ft.period, classIdx, ft.maxBenefitClass)
                    if effective then
                        cell:setText(self:formatCompactValue(effective))
                    else
                        cell:setText("")
                    end
                end
            end
        else
            -- Simple mode: show single value, hide class columns
            if singleValue then
                singleValue:setVisible(true)
                singleValue:setText(self:formatPeriod(ft.period))
            end
            for i = 0, 4 do
                local cell = classValues[i]
                if cell then
                    cell:setVisible(false)
                end
            end
        end

        self.rows[index] = {
            row = row,
            fillTypeName = ft.name,
            singleValue = singleValue,
            classValues = classValues,
        }
    end

    -- Restore focus context
    FocusManager.currentFocusData = savedFocusData

    -- Unlink template from layout and focus system
    if template.parent then
        template:unlinkElement()
        FocusManager:removeElement(template)
    end

    layout:invalidateLayout()
    self.populated = true

    Log:trace("SHELF LIFE: %d rows cloned, tableMode=%s", #fillTypes, tostring(isTableMode))
end

-- =============================================================================
-- REFRESH (update values without re-cloning)
-- =============================================================================

--- Refresh shelf life values from current settings (handles preset changes)
function RmShelfLifeFrame:refreshValues()
    for _, rowData in ipairs(self.rows) do
        local period = RmFreshSettings:getExpiration(rowData.fillTypeName)
        if period ~= nil then
            if self.tableMode then
                local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(rowData.fillTypeName)
                if fillTypeIndex == nil then
                    fillTypeIndex = 0
                end
                local maxBenefitClass = RmFreshSettings:getMaxBenefitClass(fillTypeIndex)
                for _, classIdx in ipairs(RmShelfLifeFrame.DISPLAY_CLASSES) do
                    local cell = rowData.classValues[classIdx]
                    if cell then
                        local effective = self:getEffectiveShelfLife(period, classIdx, maxBenefitClass)
                        if effective then
                            cell:setText(self:formatCompactValue(effective))
                        else
                            cell:setText("")
                        end
                    end
                end
            else
                if rowData.singleValue then
                    rowData.singleValue:setText(self:formatPeriod(period))
                end
            end
        end
    end
end
