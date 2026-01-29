-- RmFreshInfoBox.lua
-- Purpose: Custom InfoDisplayBox for freshness age distribution display
-- Author: Ritter
-- Architecture: Extends InfoDisplayBox for proper stacking with other info boxes

local Log = RmLogging.getLogger("Fresh")

RmFreshInfoBox = {}
local RmFreshInfoBox_mt = Class(RmFreshInfoBox, InfoDisplayBox)

--- Age distribution colors - FS25 predefined color values
--- Also used by RmOverviewFrame for consistent visual language
RmFreshInfoBox.COLORS = {
    FRESH    = {0.0742, 0.4341, 0.6939, 1},     -- colorBlue (75-100% remaining)
    GOOD     = {0.33716, 0.55834, 0.0003, 1},   -- fs25_colorGreen (50-75% remaining)
    WARNING  = {0.8, 0.4, 0, 1},                -- colorOrange (25-50% remaining)
    CRITICAL = {0.8069, 0.0097, 0.0097, 1},     -- colorRed (0-25% remaining)
    BAR_BG   = {0.0, 0.0, 0.0, 0.3},            -- Subtle bar background
}

---Create new RmFreshInfoBox
---@param infoDisplay table The InfoDisplay instance
---@param uiScale number UI scale factor
---@return table RmFreshInfoBox instance
function RmFreshInfoBox.new(infoDisplay, uiScale)
    local self = InfoDisplayBox.new(infoDisplay, uiScale, RmFreshInfoBox_mt)

    self.rows = {}  -- Array of {fillTypeName, buckets, total}
    self.title = ""
    self.doShowNextFrame = false

    -- Background overlays
    local r, g, b, a = unpack(HUD.COLOR.BACKGROUND)
    self.bgTop = g_overlayManager:createOverlay("gui.fieldInfo_top", 0, 0, 0, 0)
    self.bgTop:setColor(r, g, b, a)
    self.bgMiddle = g_overlayManager:createOverlay("gui.fieldInfo_middle", 0, 0, 0, 0)
    self.bgMiddle:setColor(r, g, b, a)
    self.bgBottom = g_overlayManager:createOverlay("gui.fieldInfo_bottom", 0, 0, 0, 0)
    self.bgBottom:setColor(r, g, b, a)

    -- Progress bar for rounded freshness bars
    self.progressBar = ThreePartOverlay.new()
    self.progressBar:setLeftPart("gui.progressbar_left", 0, 0)
    self.progressBar:setMiddlePart("gui.progressbar_middle", 0, 0)
    self.progressBar:setRightPart("gui.progressbar_right", 0, 0)

    self:storeScaledValues()

    Log:trace("FRESH_INFO_BOX: Created")
    return self
end

---Delete overlays
function RmFreshInfoBox:delete()
    if self.bgTop then self.bgTop:delete() end
    if self.bgMiddle then self.bgMiddle:delete() end
    if self.bgBottom then self.bgBottom:delete() end
    if self.progressBar then self.progressBar:delete() end
    Log:trace("FRESH_INFO_BOX: Deleted")
end

---Store scaled dimension values
function RmFreshInfoBox:storeScaledValues()
    local infoDisplay = self.infoDisplay

    -- Box dimensions
    self.boxWidth = infoDisplay:scalePixelToScreenWidth(340)
    self.capHeight = infoDisplay:scalePixelToScreenHeight(6)

    -- Title dimensions
    self.titleTextSize = infoDisplay:scalePixelToScreenHeight(15)
    self.titleOffsetX = infoDisplay:scalePixelToScreenWidth(14)
    self.titleOffsetY = infoDisplay:scalePixelToScreenHeight(-27)
    self.titleHeight = infoDisplay:scalePixelToScreenHeight(30)
    self.titleMaxWidth = infoDisplay:scalePixelToScreenWidth(312)

    -- Row dimensions
    self.rowHeight = infoDisplay:scalePixelToScreenHeight(21)
    self.rowTextSize = infoDisplay:scalePixelToScreenHeight(14)
    self.keyOffsetX = infoDisplay:scalePixelToScreenWidth(30)

    -- Bar dimensions
    self.barWidth = infoDisplay:scalePixelToScreenWidth(140)
    self.barHeight = infoDisplay:scalePixelToScreenHeight(6)
    self.barCapWidth = infoDisplay:scalePixelToScreenWidth(3)

    -- Padding
    self.paddingX = infoDisplay:scalePixelToScreenWidth(10)
    self.paddingY = infoDisplay:scalePixelToScreenHeight(6)
    self.textBarGap = infoDisplay:scalePixelToScreenWidth(6)

    -- Update overlay dimensions
    self.bgTop:setDimension(self.boxWidth, self.capHeight)
    self.bgMiddle:setDimension(self.boxWidth, 0)
    self.bgBottom:setDimension(self.boxWidth, self.capHeight)

    -- Update progress bar cap dimensions
    self.progressBar:setLeftPart(nil, self.barCapWidth, self.barHeight)
    self.progressBar:setRightPart(nil, self.barCapWidth, self.barHeight)
end

---Check if box should be drawn this frame
---@return boolean
function RmFreshInfoBox:canDraw()
    return self.doShowNextFrame and #self.rows > 0
end

---Mark box to show next frame
function RmFreshInfoBox:showNextFrame()
    self.doShowNextFrame = true
end

---Clear rows
function RmFreshInfoBox:clear()
    self.rows = {}
end

---Set title
---@param title string The title text
function RmFreshInfoBox:setTitle(title)
    local newTitle = utf8ToUpper(title)
    if newTitle ~= self.title then
        self.title = Utils.limitTextToWidth(newTitle, self.titleTextSize, self.titleMaxWidth, false, "...")
    end
end

---Add a row with freshness data
---@param fillTypeName string Display name of the fill type
---@param buckets table Array of {color, amount}
---@param total number Total amount
function RmFreshInfoBox:addRow(fillTypeName, buckets, total)
    table.insert(self.rows, {
        fillTypeName = fillTypeName,
        buckets = buckets,
        total = total
    })
end

---Draw the box at given position
---@param posX number Right edge X position
---@param posY number Bottom Y position (where to start drawing)
---@return number posX Unchanged X position
---@return number newPosY New Y position (top of our box) for next box
function RmFreshInfoBox:draw(posX, posY)
    local numRows = #self.rows
    if numRows == 0 then
        self.doShowNextFrame = false
        return posX, posY
    end

    -- Calculate content height
    local contentHeight = self.titleHeight + (numRows * self.rowHeight) + self.paddingY
    local totalHeight = contentHeight + self.capHeight * 2
    local leftX = posX - self.boxWidth

    -- Draw background (bottom cap, middle, top cap)
    self.bgBottom:setPosition(leftX, posY)
    self.bgBottom:render()

    self.bgMiddle:setDimension(self.boxWidth, contentHeight)
    self.bgMiddle:setPosition(leftX, posY + self.capHeight)
    self.bgMiddle:render()

    self.bgTop:setPosition(leftX, posY + self.capHeight + contentHeight)
    self.bgTop:render()

    -- Draw title
    local titleX = leftX + self.titleOffsetX
    local titleY = posY + totalHeight + self.titleOffsetY

    setTextBold(true)
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(1, 1, 1, 1)
    renderText(titleX, titleY, self.titleTextSize, self.title)
    setTextBold(false)

    -- Draw rows (below title, top to bottom)
    local rowY = posY + totalHeight - self.capHeight - self.titleHeight - self.rowHeight
    for _, row in ipairs(self.rows) do
        self:drawRow(leftX, rowY, row)
        rowY = rowY - self.rowHeight
    end

    -- Reset state
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(1, 1, 1, 1)
    self.doShowNextFrame = false

    -- Return new Y position (top of our box) for next box to stack above
    local newPosY = posY + totalHeight
    return posX, newPosY
end

---Draw a single row with fillType name and freshness bar
---@param leftX number Left edge of box
---@param rowY number Y position of row (bottom)
---@param row table Row data {fillTypeName, buckets, total}
function RmFreshInfoBox:drawRow(leftX, rowY, row)
    local C = RmFreshInfoBox.COLORS

    -- Text position
    local textX = leftX + self.keyOffsetX

    -- Bar position (right-aligned with padding)
    local barX = leftX + self.boxWidth - self.paddingX - self.barWidth
    local barY = rowY + (self.rowHeight - self.barHeight) / 2

    -- Max text width (truncate to fit bar)
    local maxTextWidth = barX - textX - self.textBarGap

    -- Draw fillType name
    setTextBold(false)
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(1, 1, 1, 1)
    local textY = rowY + (self.rowHeight - self.rowTextSize) / 2 + self.rowTextSize * 0.15
    local displayName = Utils.limitTextToWidth(row.fillTypeName or "Unknown", self.rowTextSize, maxTextWidth, false, "...")
    renderText(textX, textY, self.rowTextSize, displayName)

    -- Draw bar using ThreePartOverlay
    local bar = self.progressBar
    local middleWidth = self.barWidth - 2 * self.barCapWidth

    -- Draw background bar (dark, full width)
    bar:setColor(C.BAR_BG[1], C.BAR_BG[2], C.BAR_BG[3], C.BAR_BG[4])
    bar:setMiddlePart(nil, middleWidth, self.barHeight)
    bar:setPosition(barX, barY)
    bar:render()

    -- Draw colored segments (reverse order so smaller segments overlay larger)
    local buckets = row.buckets or {}
    local cumAmount = row.total
    for i = #buckets, 1, -1 do
        local bucket = buckets[i]
        if bucket.amount > 0 and row.total > 0 then
            local segMiddleWidth = middleWidth * (cumAmount / row.total)
            local c = bucket.color
            bar:setColor(c[1], c[2], c[3], c[4])
            bar:setMiddlePart(nil, segMiddleWidth, self.barHeight)
            bar:setPosition(barX, barY)
            bar:render()
            cumAmount = cumAmount - bucket.amount
        end
    end
end

Log:debug("FRESH_INFO_BOX: Module loaded")
