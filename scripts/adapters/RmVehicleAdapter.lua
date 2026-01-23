-- RmVehicleAdapter.lua
-- Purpose: Thin vehicle adapter - bridges FS25 vehicle events to centralized FreshManager
-- Author: Ritter
-- CRITICAL: Must stay under 150 lines to validate thin adapter architecture

RmVehicleAdapter = {}
RmVehicleAdapter.SPEC_TABLE_NAME = ("spec_%s.rmVehicleAdapter"):format(g_currentModName)
RmVehicleAdapter.ENTITY_TYPE = "vehicle"

local Log = RmLogging.getLogger("Fresh")

-- =============================================================================
-- IDENTITY
-- =============================================================================

function RmVehicleAdapter:getEntityId(vehicle)
    return vehicle.uniqueId  -- FS25's stable uniqueId
end

--- Build identity structure for a vehicle fill unit
--- Called during registration to create identityMatch for Manager
---@param vehicle table Vehicle entity
---@param fillUnitIndex number Fill unit index (1-based)
---@return table identityMatch structure for registerContainer
function RmVehicleAdapter:buildIdentityMatch(vehicle, fillUnitIndex)
    local fillUnit = vehicle.spec_fillUnit.fillUnits[fillUnitIndex]
    local fillTypeName = g_fillTypeManager:getFillTypeNameByIndex(fillUnit.fillType)

    Log:trace("BUILD_IDENTITY: vehicle=%s fu=%d fillType=%s amount=%.1f",
        vehicle.uniqueId or "?", fillUnitIndex, fillTypeName or "?", fillUnit.fillLevel or 0)

    return {
        worldObject = {
            uniqueId = vehicle.uniqueId,
        },
        storage = {
            fillTypeName = fillTypeName,
            amount = fillUnit.fillLevel,
            fillUnitHint = fillUnitIndex,  -- Hint only, not for identity matching
        },
    }
end

-- =============================================================================
-- FILL LEVEL MANIPULATION (for console commands)
-- Uses containerId as identifier - adapter resolves fillUnitIndex internally
-- =============================================================================

--- Get fill level for a container by containerId
--- Adapter resolves fillUnitIndex from its internal spec.containerIds mapping
---@param containerId string Container ID
---@return number fillLevel Current fill level
---@return number fillType Fill type index
function RmVehicleAdapter:getFillLevel(containerId)
    local container = RmFreshManager:getContainer(containerId)
    if not container then return 0, 0 end

    local vehicle = container.runtimeEntity
    if not vehicle then return 0, 0 end

    -- Reverse lookup: find fillUnitIndex for this containerId
    local spec = vehicle[RmVehicleAdapter.SPEC_TABLE_NAME]
    if not spec or not spec.containerIds then return 0, 0 end

    for fillUnitIndex, cId in pairs(spec.containerIds) do
        if cId == containerId then
            local fillLevel = vehicle:getFillUnitFillLevel(fillUnitIndex)
            local fillType = vehicle:getFillUnitFillType(fillUnitIndex)
            return fillLevel, fillType
        end
    end

    return 0, 0
end

--- Add fill level for a container by containerId
--- Adapter resolves fillUnitIndex from its internal spec.containerIds mapping
---@param containerId string Container ID
---@param delta number Amount to add (negative to remove)
---@return boolean success True if fill was modified
function RmVehicleAdapter:addFillLevel(containerId, delta)
    local container = RmFreshManager:getContainer(containerId)
    if not container then return false end

    local vehicle = container.runtimeEntity
    if not vehicle then return false end

    local fillType = container.fillTypeIndex
    if not fillType then return false end

    -- Reverse lookup: find fillUnitIndex for this containerId
    local spec = vehicle[RmVehicleAdapter.SPEC_TABLE_NAME]
    if not spec or not spec.containerIds then return false end

    for fillUnitIndex, cId in pairs(spec.containerIds) do
        if cId == containerId then
            vehicle:addFillUnitFillLevel(
                vehicle:getOwnerFarmId(),
                fillUnitIndex,
                delta,
                fillType,
                ToolType.UNDEFINED
            )
            return true
        end
    end

    return false
end

--- Set fill level for a container by containerId
--- Adapter resolves fillUnitIndex from its internal spec.containerIds mapping
---@param containerId string Container ID
---@param level number Target fill level
---@return boolean success True if fill was modified
function RmVehicleAdapter:setFillLevel(containerId, level)
    local currentFill, _ = self:getFillLevel(containerId)
    local delta = level - currentFill
    return self:addFillLevel(containerId, delta)
end

-- =============================================================================
-- LOOKUP API
-- =============================================================================

--- Get containerId for a vehicle fillUnit
--- Used by TransferCoordinator to resolve source/destination containers
--- NETWORK SAFE: Works on both server and client (uses synced spec.containerIds)
---@param vehicle table Vehicle entity
---@param fillUnitIndex number Fill unit index (1-based)
---@return string|nil containerId or nil if not registered
function RmVehicleAdapter:getContainerIdForFillUnit(vehicle, fillUnitIndex)
    if not vehicle then return nil end

    local spec = vehicle[RmVehicleAdapter.SPEC_TABLE_NAME]
    if not spec or not spec.containerIds then return nil end

    local containerId = spec.containerIds[fillUnitIndex]

    Log:trace("VEHICLE_LOOKUP: fu=%d -> containerId=%s",
        fillUnitIndex or 0, containerId or "nil")

    return containerId
end

-- =============================================================================
-- SPECIALIZATION SETUP
-- =============================================================================

function RmVehicleAdapter.prerequisitesPresent(specializations)
    return SpecializationUtil.hasSpecialization(FillUnit, specializations)
end

function RmVehicleAdapter.registerEventListeners(vehicleType)
    SpecializationUtil.registerEventListener(vehicleType, "onLoad", RmVehicleAdapter)
    SpecializationUtil.registerEventListener(vehicleType, "onLoadFinished", RmVehicleAdapter)
    SpecializationUtil.registerEventListener(vehicleType, "onDelete", RmVehicleAdapter)
    SpecializationUtil.registerEventListener(vehicleType, "onFillUnitFillLevelChanged", RmVehicleAdapter)
    -- MP sync for client display
    SpecializationUtil.registerEventListener(vehicleType, "onWriteStream", RmVehicleAdapter)
    SpecializationUtil.registerEventListener(vehicleType, "onReadStream", RmVehicleAdapter)
end

function RmVehicleAdapter.registerOverwrittenFunctions(vehicleType)
    SpecializationUtil.registerOverwrittenFunction(vehicleType, "showInfo", RmVehicleAdapter.showInfo)
end

-- =============================================================================
-- LIFECYCLE HOOKS
-- =============================================================================

function RmVehicleAdapter:onLoad(savegame)
    -- Server only - clients receive container state via sync events
    if not self.isServer then return end

    -- Create spec table with containerIds map (fillUnitIndex → containerId)
    -- Registration deferred to onLoadFinished to ensure all fill events during load are ignored
    self[RmVehicleAdapter.SPEC_TABLE_NAME] = { containerIds = {} }
end

function RmVehicleAdapter:onLoadFinished(savegame)
    -- Server only - clients receive container state via sync events
    if not self.isServer then return end

    if RmFreshManager == nil then
        Log:error("VEHICLE_LOAD_FINISHED: RmFreshManager not available")
        return
    end

    local spec = self[RmVehicleAdapter.SPEC_TABLE_NAME]
    if spec == nil then return end  -- Safety check

    -- Skip non-player vehicles (shop previews, map defaults, shop config)
    -- VehiclePropertyState: NONE=1, OWNED=2, LEASED=3, MISSION=4, SHOP_CONFIG=5
    local propertyState = self:getPropertyState()
    if propertyState == VehiclePropertyState.SHOP_CONFIG or
       propertyState == VehiclePropertyState.NONE then
        Log:trace("VEHICLE_SKIP_NON_PLAYER: propertyState=%d name=%s",
            propertyState or 0, self:getName() or "unknown")
        return
    end

    -- Use uniqueId for identity
    local entityId = self.uniqueId
    if entityId == nil or entityId == "" then
        -- Defer registration - uniqueId assigned after onLoadFinished for purchased vehicles
        RmVehicleAdapter.deferRegistration(self)
        return
    end

    -- Register immediately (savegame vehicles have uniqueId at onLoadFinished)
    RmVehicleAdapter.doRegistration(self, entityId)
end

--- Defer registration to next frame for purchased vehicles
--- uniqueId is assigned after onLoadFinished for shop purchases
function RmVehicleAdapter.deferRegistration(vehicle)
    local spec = vehicle[RmVehicleAdapter.SPEC_TABLE_NAME]
    if spec.deferredRegistration then return end  -- Already scheduled

    spec.deferredRegistration = true
    Log:trace("VEHICLE_DEFER: name=%s (uniqueId not yet assigned)", vehicle:getName() or "unknown")

    -- Schedule registration check for next frame
    g_currentMission:addUpdateable({
        vehicle = vehicle,
        update = function(self, dt)
            local v = self.vehicle
            if v.uniqueId and v.uniqueId ~= "" then
                RmVehicleAdapter.doRegistration(v, v.uniqueId)
                g_currentMission:removeUpdateable(self)
            elseif v.isDeleted then
                -- Vehicle was deleted before uniqueId assigned (cancelled purchase)
                g_currentMission:removeUpdateable(self)
            end
        end
    })
end

--- Perform actual container registration
--- Creates one container per perishable fillUnit
function RmVehicleAdapter.doRegistration(vehicle, entityId)
    local spec = vehicle[RmVehicleAdapter.SPEC_TABLE_NAME]
    if spec == nil then return end

    -- Check if already registered (any containers present)
    if next(spec.containerIds) ~= nil then return end

    local fillUnits = vehicle.spec_fillUnit and vehicle.spec_fillUnit.fillUnits
    if fillUnits == nil then return end

    for fillUnitIndex, fillUnit in ipairs(fillUnits) do
        local fillType = fillUnit.fillType

        -- Only track perishable fill types
        if fillType ~= nil and RmFreshSettings:isPerishableByIndex(fillType) then
            local identityMatch = RmVehicleAdapter:buildIdentityMatch(vehicle, fillUnitIndex)

            local containerId, wasReconciled = RmFreshManager:registerContainer(
                "vehicle",
                identityMatch,
                vehicle,
                { location = vehicle:getName() or "Vehicle" }
            )

            spec.containerIds[fillUnitIndex] = containerId

            -- Add initial batch only for NEW containers (not reconciled from save)
            if not wasReconciled then
                local currentFill = fillUnit.fillLevel or 0
                if currentFill > 0 and containerId then
                    RmFreshManager:addBatch(containerId, currentFill, 0)
                end
            end

            Log:debug("VEHICLE_REGISTERED: fillType=%s containerId=%s reconciled=%s name=%s",
                identityMatch.storage.fillTypeName, containerId or "nil", tostring(wasReconciled), vehicle:getName() or "unknown")
        end
    end
end

function RmVehicleAdapter:onDelete()
    -- Server only - clients don't register containers
    if not self.isServer then return end

    local spec = self[RmVehicleAdapter.SPEC_TABLE_NAME]
    if spec and spec.containerIds then
        for fillUnitIndex, containerId in pairs(spec.containerIds) do
            if containerId and RmFreshManager then
                RmFreshManager:unregisterContainer(containerId)
                Log:debug("VEHICLE_DELETE: fu=%d containerId=%s", fillUnitIndex, containerId)
            end
        end
    end
end

-- =============================================================================
-- FILL CHANGE HOOK
-- =============================================================================

function RmVehicleAdapter:onFillUnitFillLevelChanged(fillUnitIndex, fillLevelDelta, fillTypeIndex, ...)
    if not self.isServer then return end  -- Server only
    if fillUnitIndex <= 0 then return end  -- Invalid index guard
    if fillLevelDelta == 0 then return end

    -- Guard against infinity (some mods report inf for initial fill)
    if fillLevelDelta == math.huge or fillLevelDelta == -math.huge then
        -- Try to get actual fill level instead
        local actualFill = self:getFillUnitFillLevel(fillUnitIndex) or 0
        if actualFill > 0 and actualFill < 1000000 then
            fillLevelDelta = actualFill
            Log:debug("FILL_DELTA_INF_FIX: fu=%d replaced inf with actual=%.1f", fillUnitIndex, actualFill)
        else
            Log:warning("FILL_DELTA_INF_SKIP: fu=%d delta=inf actualFill=%.1f (skipping)", fillUnitIndex, actualFill)
            return
        end
    end

    local spec = self[RmVehicleAdapter.SPEC_TABLE_NAME]
    if spec == nil then return end

    local containerId = spec.containerIds and spec.containerIds[fillUnitIndex]

    -- Dynamic registration: if no container but fill is perishable and being added
    if containerId == nil and fillLevelDelta > 0 and RmFreshSettings:isPerishableByIndex(fillTypeIndex) then
        local identityMatch = RmVehicleAdapter:buildIdentityMatch(self, fillUnitIndex)
        local wasReconciled
        containerId, wasReconciled = RmFreshManager:registerContainer(
            "vehicle", identityMatch, self,
            { location = self:getName() or "Vehicle" }
        )
        spec.containerIds[fillUnitIndex] = containerId

        if wasReconciled then
            -- Reconciled from save - batches already loaded, skip fill change processing
            Log:debug("VEHICLE_RECONCILED: fillType=%s containerId=%s name=%s (skipping fill delta)",
                identityMatch.storage.fillTypeName, containerId or "nil", self:getName() or "unknown")
            return
        end

        Log:debug("VEHICLE_DYNAMIC_REG: fillType=%s containerId=%s name=%s",
            identityMatch.storage.fillTypeName, containerId or "nil", self:getName() or "unknown")
    end

    if containerId then
        RmFreshManager:onFillChanged(containerId, fillUnitIndex, fillLevelDelta, fillTypeIndex)
    end
end

-- =============================================================================
-- MP STREAM SYNC (sync containerIds to joining clients)
-- =============================================================================

--- Sync containerIds to joining client
function RmVehicleAdapter:onWriteStream(streamId, connection)
    local spec = self[RmVehicleAdapter.SPEC_TABLE_NAME]
    local containerIds = spec and spec.containerIds or {}

    -- Count containers
    local count = 0
    for _ in pairs(containerIds) do count = count + 1 end

    streamWriteUInt8(streamId, count)
    Log:trace("VEHICLE_WRITE_STREAM: sending %d containerIds", count)

    for fillUnitIndex, containerId in pairs(containerIds) do
        streamWriteUInt8(streamId, fillUnitIndex)
        streamWriteString(streamId, containerId)
    end
end

--- Receive containerIds on client join
function RmVehicleAdapter:onReadStream(streamId, connection)
    local spec = self[RmVehicleAdapter.SPEC_TABLE_NAME]
    if spec == nil then
        spec = { containerIds = {} }
        self[RmVehicleAdapter.SPEC_TABLE_NAME] = spec
    end
    spec.containerIds = spec.containerIds or {}

    local count = streamReadUInt8(streamId)
    Log:trace("VEHICLE_READ_STREAM: receiving %d containerIds", count)

    for i = 1, count do
        local fillUnitIndex = streamReadUInt8(streamId)
        local containerId = streamReadString(streamId)
        spec.containerIds[fillUnitIndex] = containerId

        -- Register entity→containerId mapping for display hooks
        if RmFreshManager and RmFreshManager.registerClientEntity then
            RmFreshManager:registerClientEntity(self, containerId)
        end
    end
end

-- =============================================================================
-- DISPLAY HOOK
-- =============================================================================

--- Show freshness status in vehicle HUD info
--- NETWORK SAFE: Uses spec.containerIds (populated on both server and client)
--- RIT-120: Display one line per fillType, showing shortest expiration time
function RmVehicleAdapter:showInfo(superFunc, box)
    superFunc(self, box)

    local spec = self[RmVehicleAdapter.SPEC_TABLE_NAME]
    if not spec or not spec.containerIds then return end

    -- Group by fillTypeIndex, keeping container with oldest batch (expires soonest)
    local byFillType = {} -- fillTypeIndex → { containerId, oldestAge }

    for _, containerId in pairs(spec.containerIds) do
        local container = RmFreshManager:getContainer(containerId)
        if container and container.batches and #container.batches > 0 then
            local ftIndex = container.fillTypeIndex
            local oldestAge = container.batches[1].ageInPeriods

            if not byFillType[ftIndex] or oldestAge > byFillType[ftIndex].oldestAge then
                byFillType[ftIndex] = {
                    containerId = containerId,
                    oldestAge = oldestAge,
                }
            end
        end
    end

    -- Count unique fillTypes for label formatting
    local fillTypeCount = 0
    for _ in pairs(byFillType) do
        fillTypeCount = fillTypeCount + 1
    end

    local hasWarning = false

    for ftIndex, data in pairs(byFillType) do
        local info = RmFreshManager:getDisplayInfo(data.containerId)
        if info then
            local label = g_i18n:getText("fresh_expires_in")
            -- Append localized fillType name when multiple fillTypes
            if fillTypeCount > 1 then
                local fillType = g_fillTypeManager:getFillTypeByIndex(ftIndex)
                local displayName = fillType and fillType.title or "?"
                label = label .. " (" .. displayName .. ")"
            end
            box:addLine(label, info.text)
            if info.isWarning then
                hasWarning = true
            end
        end
    end

    -- Show single warning if any container is near expiration
    if hasWarning then
        box:addLine(g_i18n:getText("fresh_near_expiration"), nil, true)
    end

    -- Draw age distribution display (if enabled)
    if RmFreshAgeDisplay and RmFreshAgeDisplay.drawForVehicle then
        RmFreshAgeDisplay.drawForVehicle(self, box)
    end
end

-- =============================================================================
-- EMPTY CONTAINER CALLBACK (from Manager after expiration)
-- =============================================================================

--- Handle empty container after expiration
--- Called by Manager when container batches are empty
--- Only deletes pallets, not equipment like trailers (v1 pattern)
---@param containerId string Container ID
function RmVehicleAdapter:onContainerEmpty(containerId)
    local container = RmFreshManager:getContainer(containerId)
    if not container then return end

    local vehicle = container.runtimeEntity
    if not vehicle then return end

    -- Only delete disposable containers (pallets), not equipment like trailers
    if not vehicle.isPallet then
        Log:debug("VEHICLE_EMPTY_KEPT: %s (not a pallet)", containerId)
        return
    end

    -- Check if already deleted (some pallets self-delete when emptied)
    if vehicle.isDeleted then
        Log:debug("VEHICLE_ALREADY_DELETED: %s", containerId)
        RmFreshManager:unregisterContainer(containerId)
        return
    end

    -- Check if ALL fill units are empty (vehicle might have multiple containers)
    local totalFillLevel = 0
    local fillUnitSpec = vehicle.spec_fillUnit
    if fillUnitSpec and fillUnitSpec.fillUnits then
        for _, fillUnit in ipairs(fillUnitSpec.fillUnits) do
            totalFillLevel = totalFillLevel + (vehicle:getFillUnitFillLevel(fillUnit.fillUnitIndex) or 0)
        end
    end

    if totalFillLevel > 0 then
        Log:debug("VEHICLE_NOT_FULLY_EMPTY: %s totalFill=%.1f", containerId, totalFillLevel)
        return
    end

    Log:info("PALLET_EXPIRED_DELETE: %s removed (empty after expiration)", containerId)

    -- Unregister from Manager first
    RmFreshManager:unregisterContainer(containerId)

    -- Then delete the game entity
    vehicle:delete()
end

-- ADAPTER REGISTRATION
RmFreshManager:registerAdapter(RmVehicleAdapter.ENTITY_TYPE, RmVehicleAdapter)
