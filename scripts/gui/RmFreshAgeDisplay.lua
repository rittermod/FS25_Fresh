-- RmFreshAgeDisplay.lua
-- Purpose: Manages freshness age distribution HUD display
-- Author: Ritter
-- Architecture: Uses RmFreshInfoBox integrated with game's InfoDisplay for proper stacking

local Log = RmLogging.getLogger("Fresh")

-- =============================================================================
-- RmFreshAgeDisplay MODULE
-- =============================================================================

RmFreshAgeDisplay = {}

--- The info box instance (created via InfoDisplay system)
RmFreshAgeDisplay.box = nil

--- Pending vehicle for drawable (set in showInfo, drawn in draw())
--- showInfo is data-population phase, not render phase - can't call showNextFrame there
RmFreshAgeDisplay.pendingVehicle = nil

--- Pending bale for drawable (set in showInfoHook, drawn in draw())
--- Same two-phase pattern as vehicles: showInfo is update phase, draw() is render phase
RmFreshAgeDisplay.pendingBale = nil

--- Install hooks for HUD display
--- Called from main.lua onLoadMapFinished()
function RmFreshAgeDisplay.install()
    -- Create our box via the InfoDisplay system (handles stacking automatically)
    if g_currentMission.hud and g_currentMission.hud.infoDisplay then
        RmFreshAgeDisplay.box = g_currentMission.hud.infoDisplay:createBox(RmFreshInfoBox)
        Log:debug("FRESH_AGE_DISPLAY: Box created via InfoDisplay")
    end

    -- Install placeable hook (if supported)
    if PlaceableInfoTrigger ~= nil and Platform.playerInfo.showPlaceableInfo then
        PlaceableInfoTrigger.onDraw = Utils.appendedFunction(
            PlaceableInfoTrigger.onDraw,
            RmFreshAgeDisplay.onPlaceableDrawHook
        )
        Log:debug("FRESH_AGE_DISPLAY: Placeable hook installed")
    end

    -- Vehicle display: Register as drawable for render phase
    -- showInfo stores the vehicle, draw() triggers box display
    g_currentMission:addDrawable(RmFreshAgeDisplay)
    Log:debug("FRESH_AGE_DISPLAY: Vehicle drawable registered")

    Log:info("FRESH_AGE_DISPLAY: Installed")
end

--- Uninstall hooks (called on map unload)
function RmFreshAgeDisplay.uninstall()
    if g_currentMission then
        g_currentMission:removeDrawable(RmFreshAgeDisplay)
    end

    -- Destroy our box
    if RmFreshAgeDisplay.box and g_currentMission.hud and g_currentMission.hud.infoDisplay then
        g_currentMission.hud.infoDisplay:destroyBox(RmFreshAgeDisplay.box)
        RmFreshAgeDisplay.box = nil
    end

    RmFreshAgeDisplay.pendingVehicle = nil
    RmFreshAgeDisplay.pendingBale = nil
    Log:debug("FRESH_AGE_DISPLAY: Uninstalled")
end

-- =============================================================================
-- PLACEABLE DISPLAY
-- =============================================================================

--- Hook: Populate box for placeable display
---@param placeable table The placeable (self in onDraw)
function RmFreshAgeDisplay.onPlaceableDrawHook(placeable)
    -- Check if feature is enabled
    if not RmFreshSettings:getGlobal("showAgeDisplay") then
        return
    end

    -- Check box exists
    local box = RmFreshAgeDisplay.box
    if box == nil then
        return
    end

    -- Get placeable's info trigger spec
    local spec = placeable.spec_infoTrigger
    if spec == nil or not spec.showInfo then
        return
    end

    -- Get containers for this placeable
    local containers = RmFreshManager:getContainersByRuntimeEntity(placeable)
    if containers == nil or #containers == 0 then
        return
    end

    -- Build row data and populate box
    local rows = RmFreshAgeDisplay.buildRows(containers)
    if #rows == 0 then
        return
    end

    -- Populate box
    box:clear()
    box:setTitle(g_i18n:getText("fresh_age_display_title"))
    for _, row in ipairs(rows) do
        box:addRow(row.fillTypeName, row.buckets, row.total)
    end
    box:showNextFrame()
end

-- =============================================================================
-- BALE DISPLAY
-- Two-phase: showInfoHook stores bale, draw() populates box
-- =============================================================================

--- Store bale for drawing (called from RmBaleAdapter.showInfoHook)
--- showInfo is data-population phase - can't call showNextFrame there
---@param bale table The bale entity
function RmFreshAgeDisplay.drawForBale(bale)
    -- Check if feature is enabled
    if not RmFreshSettings:getGlobal("showAgeDisplay") then
        return
    end

    -- Store for draw() phase
    RmFreshAgeDisplay.pendingBale = bale
end

-- =============================================================================
-- VEHICLE DISPLAY
-- Two-phase: showInfo stores vehicle, draw() populates box
-- =============================================================================

--- Store vehicle for drawing (called from RmVehicleAdapter.showInfo)
--- showInfo is data-population phase - can't call showNextFrame there
---@param vehicle table The vehicle
---@param box table The info box (unused, kept for API compatibility)
function RmFreshAgeDisplay.drawForVehicle(vehicle, box)
    -- Check if feature is enabled
    if not RmFreshSettings:getGlobal("showAgeDisplay") then
        return
    end

    -- Vehicle must have fill capacity to be relevant
    if vehicle.spec_fillUnit == nil then
        return
    end

    -- Store for draw() phase
    RmFreshAgeDisplay.pendingVehicle = vehicle
end

--- Drawable interface: Called each frame during render phase
--- Populates box for pending vehicle or bale (if any)
function RmFreshAgeDisplay:draw()
    -- Grab and clear all pending targets (always clear to prevent stale state)
    local vehicle = RmFreshAgeDisplay.pendingVehicle
    local bale = RmFreshAgeDisplay.pendingBale
    RmFreshAgeDisplay.pendingVehicle = nil
    RmFreshAgeDisplay.pendingBale = nil

    if vehicle == nil and bale == nil then
        return
    end

    -- Check if feature is enabled
    if not RmFreshSettings:getGlobal("showAgeDisplay") then
        return
    end

    -- Check box exists
    local box = RmFreshAgeDisplay.box
    if box == nil then
        return
    end

    -- Collect containers based on entity type
    local allContainers
    if vehicle ~= nil then
        allContainers = RmFreshAgeDisplay.collectVehicleContainers(vehicle)
    else
        allContainers = RmFreshManager:getContainersByRuntimeEntity(bale)
    end

    if allContainers == nil or #allContainers == 0 then
        return
    end

    -- Build row data
    local rows = RmFreshAgeDisplay.buildRows(allContainers)
    if #rows == 0 then
        return
    end

    -- Populate box
    box:clear()
    box:setTitle(g_i18n:getText("fresh_age_display_title"))
    for _, row in ipairs(rows) do
        box:addRow(row.fillTypeName, row.buckets, row.total)
    end
    box:showNextFrame()
end

--- Collect all Fresh containers from vehicle train (root + all attached implements)
---@param rootVehicle table The root vehicle
---@return table Array of Fresh containers
function RmFreshAgeDisplay.collectVehicleContainers(rootVehicle)
    local allContainers = {}

    -- Get containers from root vehicle
    local containers = RmFreshManager:getContainersByRuntimeEntity(rootVehicle)
    if containers then
        for _, container in ipairs(containers) do
            table.insert(allContainers, container)
        end
    end

    -- Get containers from all child vehicles (attached implements/trailers)
    if rootVehicle.childVehicles then
        for _, childVehicle in pairs(rootVehicle.childVehicles) do
            local childContainers = RmFreshManager:getContainersByRuntimeEntity(childVehicle)
            if childContainers then
                for _, container in ipairs(childContainers) do
                    table.insert(allContainers, container)
                end
            end
        end
    end

    return allContainers
end

-- =============================================================================
-- DATA PREPARATION (shared by placeable and vehicle)
-- =============================================================================

--- Build row data from containers
--- Groups containers by fillType to show one row per fillType
---@param containers table Array of Fresh containers
---@return table Array of row data for display
function RmFreshAgeDisplay.buildRows(containers)
    local rows = {}
    local C = RmFreshInfoBox.COLORS

    -- First pass: Group batches by fillTypeName
    local byFillType = {} -- fillTypeName -> { batches = {}, fillTypeIndex = nil }

    for _, container in ipairs(containers) do
        local batches = container.batches
        if batches and #batches > 0 then
            local fillTypeName = container.identityMatch and
                                 container.identityMatch.storage and
                                 container.identityMatch.storage.fillTypeName

            if fillTypeName then
                if not byFillType[fillTypeName] then
                    byFillType[fillTypeName] = {
                        batches = {},
                        fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(fillTypeName)
                    }
                end
                -- Merge batches from this container
                for _, batch in ipairs(batches) do
                    table.insert(byFillType[fillTypeName].batches, batch)
                end
            end
        end
    end

    -- Second pass: Create one row per fillType
    for fillTypeName, data in pairs(byFillType) do
        local fillTypeIndex = data.fillTypeIndex

        -- Skip non-perishable fill types (RIT-192)
        if fillTypeIndex and RmFreshSettings:isPerishableByIndex(fillTypeIndex) then
            -- Get expiration threshold
            local config = RmFreshSettings:getThresholdByIndex(fillTypeIndex)
            local expirationThreshold = config.expiration or 1.0

            -- Calculate age distribution from merged batches
            local buckets, total = RmFreshAgeDisplay.getAgeDistribution(data.batches, expirationThreshold, C)

            if total > 0 then
                -- Get display name
                local displayName = g_fillTypeManager:getFillTypeTitleByIndex(fillTypeIndex) or fillTypeName

                table.insert(rows, {
                    fillTypeIndex = fillTypeIndex,
                    fillTypeName = displayName,
                    buckets = buckets,
                    total = total,
                })
            end
        end
    end

    return rows
end

--- Calculate age distribution buckets from batches
---@param batches table Array of batches { amount, ageInPeriods }
---@param expirationThreshold number The expiration threshold for this fillType
---@param colors table Color constants
---@return table buckets Array of { color, amount }
---@return number total Total amount
function RmFreshAgeDisplay.getAgeDistribution(batches, expirationThreshold, colors)
    local buckets = {
        { color = colors.FRESH, amount = 0 },      -- 75-100% remaining
        { color = colors.GOOD, amount = 0 },       -- 50-75% remaining
        { color = colors.WARNING, amount = 0 },    -- 25-50% remaining
        { color = colors.CRITICAL, amount = 0 },   -- 0-25% remaining
    }
    local total = 0
    local threshold = expirationThreshold or 1.0

    for _, batch in ipairs(batches) do
        local ageRatio = (batch.ageInPeriods or 0) / threshold
        local remaining = math.max(0, 1.0 - ageRatio)

        local idx
        if remaining >= 0.75 then
            idx = 1  -- Fresh
        elseif remaining >= 0.50 then
            idx = 2  -- Good
        elseif remaining >= 0.25 then
            idx = 3  -- Warning
        else
            idx = 4  -- Critical
        end

        buckets[idx].amount = buckets[idx].amount + batch.amount
        total = total + batch.amount
    end

    return buckets, total
end

Log:debug("FRESH_AGE_DISPLAY: Module loaded")
