-- RmVehicleAdapter.lua
-- Purpose: Thin vehicle adapter - bridges FS25 vehicle events to centralized FreshManager
-- Author: Ritter
-- CRITICAL: Must stay under 150 lines to validate thin adapter architecture

RmVehicleAdapter = {}
RmVehicleAdapter.SPEC_TABLE_NAME = ("spec_%s.rmVehicleAdapter"):format(g_currentModName)
RmVehicleAdapter.ENTITY_TYPE = "vehicle"

local Log = RmLogging.getLogger("Fresh")

--- Safe getName wrapper - some vehicle types (e.g. Rideable/horse) override getName()
--- with code that throws when internal state isn't ready (cluster=nil during async load).
--- Base game bug: Rideable:getName() has no nil guard on spec.cluster.
local function safeGetName(vehicle)
    local ok, name = pcall(function() return vehicle:getName() end)
    if ok and name then return name end
    return vehicle.typeName or vehicle.configFileName or "unknown"
end

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
---@param fillTypeName string Explicit fill type name (e.g., "WHEAT") - required for pre-registration of empty fill units
---@return table identityMatch structure for registerContainer
function RmVehicleAdapter:buildIdentityMatch(vehicle, fillUnitIndex, fillTypeName)
    local fillUnit = vehicle.spec_fillUnit.fillUnits[fillUnitIndex]
    -- Only report fill level if the fill unit currently holds this type
    local fillLevel = 0
    local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(fillTypeName)
    if fillUnit.fillType == fillTypeIndex then
        fillLevel = fillUnit.fillLevel or 0
    end

    Log:trace("BUILD_IDENTITY: vehicle=%s fu=%d fillType=%s amount=%.1f",
        vehicle.uniqueId or "?", fillUnitIndex, fillTypeName or "?", fillLevel)

    return {
        worldObject = {
            uniqueId = vehicle.uniqueId,
        },
        storage = {
            fillTypeName = fillTypeName,
            amount = fillLevel,
            fillUnitHint = fillUnitIndex,  -- Hint only, not for identity matching
        },
    }
end

-- =============================================================================
-- STORAGE CLASS DETECTION (F-124-1)
-- =============================================================================

--- Detect storage class for a vehicle based on its type
--- Pallet/bigBag → EXPOSED, open-top (FillVolume) → EXPOSED, enclosed → SHELTERED
---@param vehicle table Vehicle entity
---@return number storageClass Storage class enum value
function RmVehicleAdapter.detectStorageClass(vehicle)
    local SC = RmFreshManager.STORAGE_CLASS

    Log:trace(">>> detectStorageClass: isPallet=%s fillVolume=%s fillUnit=%s",
        tostring(vehicle.isPallet),
        tostring(vehicle.spec_fillVolume ~= nil),
        tostring(vehicle.spec_fillUnit ~= nil))

    -- Pallet/bigBag: always exposed (isPallet covers both)
    if vehicle.isPallet then
        return SC.EXPOSED
    end
    -- Open-top heap (trailer with FillVolume): exposed
    if vehicle.spec_fillVolume ~= nil then
        return SC.EXPOSED
    end
    -- Enclosed container (spec_fillUnit only): sheltered
    return SC.SHELTERED
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

    for fillUnitIndex, fuMap in pairs(spec.containerIds) do
        if type(fuMap) == "table" then
            for _, cId in pairs(fuMap) do
                if cId == containerId then
                    -- Only return fill level if fill unit currently holds this container's fill type
                    local currentFillType = vehicle:getFillUnitFillType(fillUnitIndex)
                    if currentFillType == container.fillTypeIndex then
                        return vehicle:getFillUnitFillLevel(fillUnitIndex), currentFillType
                    end
                    return 0, container.fillTypeIndex
                end
            end
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

    for fillUnitIndex, fuMap in pairs(spec.containerIds) do
        if type(fuMap) == "table" then
            for _, cId in pairs(fuMap) do
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

--- Get containerId for a vehicle fillUnit and fillType
--- Used by TransferCoordinator to resolve source/destination containers
--- NETWORK SAFE: Works on both server and client (uses synced spec.containerIds)
---@param vehicle table Vehicle entity
---@param fillUnitIndex number Fill unit index (1-based)
---@param fillTypeIndex number Fill type index (required - resolves to fillTypeName for nested lookup)
---@return string|nil containerId or nil if not registered
function RmVehicleAdapter:getContainerIdForFillUnit(vehicle, fillUnitIndex, fillTypeIndex)
    if not vehicle or not fillTypeIndex then return nil end

    local spec = vehicle[RmVehicleAdapter.SPEC_TABLE_NAME]
    if not spec or not spec.containerIds then return nil end

    local fuMap = spec.containerIds[fillUnitIndex]
    if not fuMap then return nil end

    local fillTypeName = g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex)
    local containerId = fuMap[fillTypeName]

    Log:trace("VEHICLE_LOOKUP: fu=%d fillType=%s -> containerId=%s",
        fillUnitIndex or 0, fillTypeName or "?", containerId or "nil")

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
    -- Transfer age preservation: must use registerOverwrittenFunction (not late-bound
    -- Utils.overwrittenFunction) because late hooks don't reach already-loaded vehicles.
    -- Safe no-op for vehicle types without Dischargeable (skips if function absent).
    SpecializationUtil.registerOverwrittenFunction(vehicleType, "dischargeToObject", RmTransferCoordinator.dischargeToObject)
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
            propertyState or 0, safeGetName(self))
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

--- Polling timeout for deferred registration: 10 seconds (600 frames at 60fps)
local DEFER_TIMEOUT_MS = 10000

--- Defer registration until uniqueId is available (for purchased vehicles)
--- uniqueId is assigned after onLoadFinished for shop purchases
---@param vehicle table Vehicle entity
function RmVehicleAdapter.deferRegistration(vehicle)
    Log:trace(">>> deferRegistration(vehicle=%s)", safeGetName(vehicle))

    local spec = vehicle[RmVehicleAdapter.SPEC_TABLE_NAME]
    if spec.deferredRegistration then
        Log:trace("<<< deferRegistration (already scheduled)")
        return
    end

    spec.deferredRegistration = true
    Log:debug("VEHICLE_DEFER: %s (uniqueId not yet assigned)", safeGetName(vehicle))

    local startTime = g_currentMission.time

    g_currentMission:addUpdateable({
        vehicle = vehicle,
        update = function(self, _dt)
            -- Guard: mission teardown (avoid accessing nil g_currentMission)
            if g_currentMission == nil then
                return
            end

            local v = self.vehicle

            -- Success: uniqueId now available
            if v.uniqueId and v.uniqueId ~= "" then
                Log:trace("    deferred: uniqueId now available after %dms", g_currentMission.time - startTime)
                RmVehicleAdapter.doRegistration(v, v.uniqueId)
                g_currentMission:removeUpdateable(self)
                return
            end

            -- Cancelled: vehicle deleted before uniqueId assigned
            if v.isDeleted then
                Log:trace("    deferred: vehicle deleted, cancelling")
                g_currentMission:removeUpdateable(self)
                return
            end

            -- Timeout: polling exhausted
            if (g_currentMission.time - startTime) > DEFER_TIMEOUT_MS then
                Log:warning("VEHICLE_NO_UNIQUEID: %s failed to get uniqueId after %dms",
                    safeGetName(v), DEFER_TIMEOUT_MS)
                g_currentMission:removeUpdateable(self)
                return
            end
        end
    })

    Log:trace("<<< deferRegistration (scheduled, timeout=%dms)", DEFER_TIMEOUT_MS)
end

--- Perform actual container registration
--- Pre-registers one container per perishable supported fillType per fillUnit
--- Aligns with PlaceableAdapter pattern: iterate supportedFillTypes, register even when empty
function RmVehicleAdapter.doRegistration(vehicle, entityId)
    local spec = vehicle[RmVehicleAdapter.SPEC_TABLE_NAME]
    if spec == nil then return end

    -- Check if already registered (any containers present)
    if next(spec.containerIds) ~= nil then return end

    local fillUnits = vehicle.spec_fillUnit and vehicle.spec_fillUnit.fillUnits
    if fillUnits == nil then return end

    local storageClass = RmVehicleAdapter.detectStorageClass(vehicle)

    for fillUnitIndex, fillUnit in ipairs(fillUnits) do
        -- Iterate all supported fill types (not just current fillType)
        local supportedFillTypes = vehicle:getFillUnitSupportedFillTypes(fillUnitIndex) or {}

        for fillTypeIndex, _ in pairs(supportedFillTypes) do
            if RmFreshSettings:isPerishableByIndex(fillTypeIndex) then
                local fillTypeName = g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex)
                local identityMatch = RmVehicleAdapter:buildIdentityMatch(vehicle, fillUnitIndex, fillTypeName)

                local containerId, wasReconciled = RmFreshManager:registerContainer(
                    "vehicle",
                    identityMatch,
                    vehicle,
                    { location = safeGetName(vehicle), storageClass = storageClass, isPallet = vehicle.isPallet or false }
                )

                -- Create sub-table lazily (only when we have a perishable type)
                if not spec.containerIds[fillUnitIndex] then
                    spec.containerIds[fillUnitIndex] = {}
                end
                spec.containerIds[fillUnitIndex][fillTypeName] = containerId

                -- Add initial batch only for NEW containers with actual fill of this type
                if not wasReconciled and containerId then
                    local currentFill = 0
                    if fillUnit.fillType == fillTypeIndex then
                        currentFill = fillUnit.fillLevel or 0
                    end
                    if currentFill > 0 then
                        RmFreshManager:addBatch(containerId, currentFill, 0)
                    end
                end

                if identityMatch.storage.amount > 0 then
                    Log:debug("VEHICLE_REGISTERED: fillType=%s containerId=%s reconciled=%s name=%s",
                        fillTypeName, containerId or "nil", tostring(wasReconciled), safeGetName(vehicle))
                else
                    Log:debug("VEHICLE_REGISTERED_EMPTY: fillType=%s containerId=%s name=%s (pre-registered)",
                        fillTypeName, containerId or "nil", safeGetName(vehicle))
                end
                Log:debug("STORAGE_DETECT: container=%s type=vehicle class=%s(%d)",
                    containerId or "nil", RmFreshManager.STORAGE_CLASS_NAMES[storageClass], storageClass)
            end
        end
    end
end

--- Rescan all vehicles for newly-perishable fillUnits
--- Called when settings change makes a fillType perishable
--- Iterates supportedFillTypes per fill unit (not just current fillType)
---@return number count Number of new containers registered
function RmVehicleAdapter.rescanForPerishables()
    if not g_currentMission or not g_currentMission.vehicleSystem then return 0 end

    Log:trace(">>> RmVehicleAdapter.rescanForPerishables()")
    local count = 0
    for _, vehicle in ipairs(g_currentMission.vehicleSystem.vehicles) do
        local spec = vehicle[RmVehicleAdapter.SPEC_TABLE_NAME]
        if spec and spec.containerIds and vehicle.uniqueId then
            local fillUnits = vehicle.spec_fillUnit and vehicle.spec_fillUnit.fillUnits
            if fillUnits then
                for fillUnitIndex, fillUnit in ipairs(fillUnits) do
                    spec.containerIds[fillUnitIndex] = spec.containerIds[fillUnitIndex] or {}
                    local fuMap = spec.containerIds[fillUnitIndex]

                    -- Clear stale adapter refs in nested structure
                    -- Collect stale keys first to avoid modifying table during pairs() iteration
                    local staleKeys = {}
                    for fillTypeName, existingId in pairs(fuMap) do
                        if RmFreshManager.containers[existingId] == nil then
                            Log:debug("RESCAN_STALE_REF: fu=%d fillType=%s containerId=%s (clearing)",
                                fillUnitIndex, fillTypeName, existingId)
                            staleKeys[#staleKeys + 1] = fillTypeName
                        end
                    end
                    for _, key in ipairs(staleKeys) do
                        fuMap[key] = nil
                    end

                    -- Iterate all supported fill types for this fill unit
                    local supportedFillTypes = vehicle:getFillUnitSupportedFillTypes(fillUnitIndex) or {}
                    for fillTypeIndex, _ in pairs(supportedFillTypes) do
                        if RmFreshSettings:isPerishableByIndex(fillTypeIndex) then
                            local fillTypeName = g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex)
                            if fuMap[fillTypeName] == nil then
                                local identityMatch = RmVehicleAdapter:buildIdentityMatch(vehicle, fillUnitIndex, fillTypeName)
                                local rescanStorageClass = RmVehicleAdapter.detectStorageClass(vehicle)
                                local containerId, wasReconciled = RmFreshManager:registerContainer(
                                    "vehicle", identityMatch, vehicle,
                                    { location = safeGetName(vehicle), storageClass = rescanStorageClass, isPallet = vehicle.isPallet or false }
                                )
                                fuMap[fillTypeName] = containerId

                                -- Add initial batch only if fill unit currently holds this type
                                if not wasReconciled and containerId then
                                    local currentFill = 0
                                    if fillUnit.fillType == fillTypeIndex then
                                        currentFill = fillUnit.fillLevel or 0
                                    end
                                    if currentFill > 0 then
                                        RmFreshManager:addBatch(containerId, currentFill, 0)
                                    end
                                end
                                count = count + 1

                                Log:debug("RESCAN_VEHICLE: fillType=%s containerId=%s name=%s",
                                    fillTypeName, containerId or "nil",
                                    safeGetName(vehicle))
                            end
                        end
                    end
                end
            end
        end
    end
    Log:trace("<<< RmVehicleAdapter.rescanForPerishables = %d", count)
    return count
end

function RmVehicleAdapter:onDelete()
    -- Server only - clients don't register containers
    if not self.isServer then return end

    local spec = self[RmVehicleAdapter.SPEC_TABLE_NAME]
    if spec and spec.containerIds then
        for fillUnitIndex, fuMap in pairs(spec.containerIds) do
            if type(fuMap) == "table" then
                for fillTypeName, containerId in pairs(fuMap) do
                    if containerId and RmFreshManager then
                        RmFreshManager:unregisterContainer(containerId)
                        Log:debug("VEHICLE_DELETE: fu=%d fillType=%s containerId=%s", fillUnitIndex, fillTypeName, containerId)
                    end
                end
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

    -- Guard against infinity
    -- Negative infinity: FS25 fill type switch drain event (-math.huge drains old type)
    -- Must be processed to consume old container's batches via pre-registered containers
    if fillLevelDelta == -math.huge then
        fillLevelDelta = -1000000000  -- Manager's consumeBatches caps at actual batch total
        Log:debug("FILL_DELTA_NEG_INF: fu=%d replaced -inf with -1B (fill type switch drain)", fillUnitIndex)
    end

    -- Positive infinity: some mods report inf for initial fill
    if fillLevelDelta == math.huge then
        local actualFill = self:getFillUnitFillLevel(fillUnitIndex) or 0
        if actualFill > 0 and actualFill < 1000000 then
            fillLevelDelta = actualFill
            Log:debug("FILL_DELTA_POS_INF_FIX: fu=%d replaced +inf with actual=%.1f", fillUnitIndex, actualFill)
        else
            Log:warning("FILL_DELTA_POS_INF_SKIP: fu=%d delta=+inf actualFill=%.1f (skipping)", fillUnitIndex, actualFill)
            return
        end
    end

    local spec = self[RmVehicleAdapter.SPEC_TABLE_NAME]
    if spec == nil then return end

    local fillTypeName = g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex)
    local fuMap = spec.containerIds and spec.containerIds[fillUnitIndex]
    local containerId = fuMap and fuMap[fillTypeName]

    -- Clear stale adapter ref if Manager no longer has this container
    if containerId ~= nil and RmFreshManager.containers[containerId] == nil then
        Log:debug("VEHICLE_STALE_REF: fu=%d fillType=%s containerId=%s (clearing)", fillUnitIndex, fillTypeName or "?", containerId)
        fuMap[fillTypeName] = nil
        containerId = nil
    end

    -- Dynamic registration: if no container but fill is perishable and being added
    if containerId == nil and fillLevelDelta > 0 and RmFreshSettings:isPerishableByIndex(fillTypeIndex) then
        local identityMatch = RmVehicleAdapter:buildIdentityMatch(self, fillUnitIndex, fillTypeName)
        local dynStorageClass = RmVehicleAdapter.detectStorageClass(self)
        local wasReconciled
        containerId, wasReconciled = RmFreshManager:registerContainer(
            "vehicle", identityMatch, self,
            { location = safeGetName(self), storageClass = dynStorageClass, isPallet = self.isPallet or false }
        )
        spec.containerIds[fillUnitIndex] = spec.containerIds[fillUnitIndex] or {}
        spec.containerIds[fillUnitIndex][fillTypeName] = containerId

        if wasReconciled then
            -- Reconciled from save - batches already loaded, skip fill change processing
            Log:debug("VEHICLE_RECONCILED: fillType=%s containerId=%s name=%s (skipping fill delta)",
                fillTypeName, containerId or "nil", safeGetName(self))
            return
        end

        Log:debug("VEHICLE_DYNAMIC_REG: fillType=%s containerId=%s name=%s",
            fillTypeName, containerId or "nil", safeGetName(self))
    end

    if containerId then
        RmFreshManager:onFillChanged(containerId, fillUnitIndex, fillLevelDelta, fillTypeIndex)
    end
end

-- =============================================================================
-- MP STREAM SYNC (sync containerIds to joining clients)
-- =============================================================================

--- Sync containerIds to joining client (flat encoding: fillUnitIndex, fillTypeName, containerId)
function RmVehicleAdapter:onWriteStream(streamId, connection)
    local spec = self[RmVehicleAdapter.SPEC_TABLE_NAME]
    local containerIds = spec and spec.containerIds or {}

    -- Count total entries across all fill units
    local count = 0
    for _, fuMap in pairs(containerIds) do
        if type(fuMap) == "table" then
            for _ in pairs(fuMap) do count = count + 1 end
        end
    end

    streamWriteUInt8(streamId, count)
    Log:trace("VEHICLE_WRITE_STREAM: sending %d containerIds", count)

    for fillUnitIndex, fuMap in pairs(containerIds) do
        if type(fuMap) == "table" then
            for fillTypeName, containerId in pairs(fuMap) do
                streamWriteUInt8(streamId, fillUnitIndex)
                streamWriteString(streamId, fillTypeName)
                streamWriteString(streamId, containerId)
            end
        end
    end
end

--- Receive containerIds on client join (reconstructs nested map)
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
        local fillTypeName = streamReadString(streamId)
        local containerId = streamReadString(streamId)

        spec.containerIds[fillUnitIndex] = spec.containerIds[fillUnitIndex] or {}
        spec.containerIds[fillUnitIndex][fillTypeName] = containerId

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
--- Display one line per fillType, showing shortest expiration time
function RmVehicleAdapter:showInfo(superFunc, box)
    superFunc(self, box)

    local spec = self[RmVehicleAdapter.SPEC_TABLE_NAME]
    if not spec or not spec.containerIds then return end

    -- Group by fillTypeIndex: track oldest batch, total amount, and expiring amount
    local daysPerPeriod = (g_currentMission and g_currentMission.environment
        and g_currentMission.environment.daysPerPeriod) or 1
    local warningHours = RmFreshSettings:getWarningHours()
    local byFillType = {} -- fillTypeIndex → { containerId, oldestAge, totalAmount, expiringAmount }

    for _, fuMap in pairs(spec.containerIds) do
        if type(fuMap) == "table" then
            for _, containerId in pairs(fuMap) do
                local container = RmFreshManager:getContainer(containerId)
                if container and container.batches and #container.batches > 0 then
                    local ftIndex = container.fillTypeIndex
                    local oldestAge = container.batches[1].ageInPeriods

                    if not byFillType[ftIndex] then
                        byFillType[ftIndex] = {
                            containerId = containerId,
                            oldestAge = oldestAge,
                            totalAmount = 0,
                            expiringAmount = 0,
                        }
                    elseif oldestAge > byFillType[ftIndex].oldestAge then
                        byFillType[ftIndex].containerId = containerId
                        byFillType[ftIndex].oldestAge = oldestAge
                    end

                    local entry = byFillType[ftIndex]
                    if RmFreshSettings:isPerishableByIndex(ftIndex) then
                        local config = RmFreshSettings:getThresholdByIndex(ftIndex)
                        -- Resolve storage class multiplier for accurate time calculations
                        local classInfo = RmFreshManager:resolveStorageClassInfo(container)
                        local multiplier = classInfo and classInfo.multiplier or 1.0
                        for _, batch in ipairs(container.batches) do
                            entry.totalAmount = entry.totalAmount + batch.amount
                            if batch.amount >= RmBatch.MIN_AMOUNT
                                and RmBatch.isNearExpiration(batch, warningHours, config.expiration, daysPerPeriod, multiplier) then
                                entry.expiringAmount = entry.expiringAmount + batch.amount
                            end
                        end
                    end
                end
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
            -- Append expiring amount when partial (not all content expiring)
            local text = info.text
            if data.expiringAmount > 0 and data.expiringAmount < data.totalAmount * 0.99 then
                local formattedVolume = g_i18n:formatVolume(data.expiringAmount)
                text = text .. " " .. string.format(g_i18n:getText("fresh_vehicle_expiring_volume"), formattedVolume)
            end
            box:addLine(label, text)
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
