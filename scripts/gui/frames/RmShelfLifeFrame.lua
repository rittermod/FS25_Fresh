--[[
    RmShelfLifeFrame.lua
    Read-only reference frame showing active shelf life per perishable fill type.
    Uses ScrollingLayout + template clone pattern (same as settings page).
]]

RmShelfLifeFrame = {}
local RmShelfLifeFrame_mt = Class(RmShelfLifeFrame, TabbedMenuFrameElement)

local Log = RmLogging.getLogger("Fresh")

local modDirectory = g_currentModDirectory

-- =============================================================================
-- CONSTRUCTOR
-- =============================================================================

function RmShelfLifeFrame.new()
    local self = RmShelfLifeFrame:superClass().new(nil, RmShelfLifeFrame_mt)
    self.name = "RmShelfLifeFrame"
    self.rows = {}
    self.populated = false
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
---@return table Array of { name = string, title = string, period = number }
function RmShelfLifeFrame:getPerishableFillTypes()
    local fillTypes = {}

    for fillTypeName, fillTypeData in pairs(RmFreshSettings.allFillTypes or {}) do
        if fillTypeName ~= "UNKNOWN" then
            local period = RmFreshSettings:getExpiration(fillTypeName)
            if period ~= nil then
                table.insert(fillTypes, {
                    name = fillTypeName,
                    title = fillTypeData.title or fillTypeName,
                    period = period,
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

--- Format a period in months for display
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

    self.rows = {}

    for index, ft in ipairs(fillTypes) do
        local row = template:clone(layout)

        -- Alternating row color (clone doesn't fire onCreate)
        local isEven = (index % 2 == 0)
        row:setImageColor(nil, table.unpack(
            InGameMenuSettingsFrame.COLOR_ALTERNATING[isEven]))

        -- Element 1: shelf life value text (rmFreshSettingsReadonlyValue)
        local valueText = row.elements[1]
        if valueText then
            valueText:setText(self:formatPeriod(ft.period))
        end

        -- Element 2: fill type icon
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

        -- Element 3: fill type title
        local titleText = row.elements[3]
        if titleText then
            titleText:setText(ft.title)
        end

        self.rows[index] = { row = row, valueText = valueText, fillTypeName = ft.name }
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

    Log:trace("SHELF LIFE: %d rows cloned, template unlinked", #fillTypes)
end

-- =============================================================================
-- REFRESH (update values without re-cloning)
-- =============================================================================

--- Refresh shelf life values from current settings (handles preset changes)
function RmShelfLifeFrame:refreshValues()
    for _, rowData in ipairs(self.rows) do
        local period = RmFreshSettings:getExpiration(rowData.fillTypeName)
        if period ~= nil and rowData.valueText then
            rowData.valueText:setText(self:formatPeriod(period))
        end
    end
end
