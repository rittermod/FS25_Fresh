-- RmTransferCoordinator.lua
-- Purpose: Hook FS25 transfer functions to preserve batch ages during fill transfers
-- Author: Ritter
--
-- =============================================================================
-- ARCHITECTURE: Age-Preserving Transfers
-- =============================================================================
--
-- FLOW:
--   BEFORE superFunc: Stage batches from source
--     1. Resolve source container via adapter lookup
--     2. Resolve destination container via adapter lookup
--     3. peekBatches(source, amount) → preview oldest batches
--     4. setTransferPending(destination, batches) → stage for destination
--
--   superFunc: Game performs actual fill movement
--
--   AFTER (in adapter's onFillChanged):
--     5. Destination adapter checks getTransferPending()
--     6. If pending → add batches with transferred ages (preserves freshness)
--     7. If no pending → create fresh batch age=0 (normal flow)
--
-- HOOK TARGETS:
--   LoadingStation:addFillLevelToFillableObject → Storage → Vehicle
--   Dischargeable:dischargeToObject → Vehicle → Target (vehicle/storage/trigger)
--
-- =============================================================================

RmTransferCoordinator = {}

local Log = RmLogging.getLogger("Fresh")

-- =============================================================================
-- INSTALLATION
-- =============================================================================

--- Install transfer hooks
--- Called from main.lua onLoadMapFinished_v2 after Manager.initialize()
--- SERVER ONLY - clients don't track batches
function RmTransferCoordinator.install()
    if g_server == nil then
        Log:debug("TransferCoordinator: skipped on client")
        return
    end

    -- Install hooks
    RmTransferCoordinator.installLoadingStationHook()
    RmTransferCoordinator.installDischargeableHook()

    Log:info("TransferCoordinator hooks installed")
end

-- =============================================================================
-- LOADINGSTATION HOOK (Storage → Vehicle)
-- =============================================================================

--- Install LoadingStation hook for Storage → Vehicle transfers
function RmTransferCoordinator.installLoadingStationHook()
    if LoadingStation == nil then
        Log:warning("LoadingStation not found - loading hook skipped")
        return
    end

    LoadingStation.addFillLevelToFillableObject = Utils.overwrittenFunction(
        LoadingStation.addFillLevelToFillableObject,
        RmTransferCoordinator.loadingStationAddFillLevel
    )

    Log:debug("LoadingStation hook installed")
end

--- Wrapped LoadingStation transfer function
--- SIGNATURE from v1: (station, superFunc, fillableObject, fillUnitIndex, fillType, delta, fillInfo, toolType)
---@param station table LoadingStation instance (has sourceStorages table)
---@param superFunc function Original function
---@param fillableObject table Destination vehicle
---@param fillUnitIndex number Target fill unit on vehicle
---@param fillType number Fill type index
---@param delta number Amount to transfer (~50L per call)
---@param fillInfo table Fill position/rotation info
---@param toolType any Tool type (ToolType.TRIGGER)
---@return number actualDelta Amount transferred
function RmTransferCoordinator.loadingStationAddFillLevel(station, superFunc, fillableObject, fillUnitIndex, fillType, delta, fillInfo, toolType)
    -- Server only - clients don't track batches
    if g_server == nil then
        return superFunc(station, fillableObject, fillUnitIndex, fillType, delta, fillInfo, toolType)
    end

    -- Skip non-perishable fill types
    if not RmFreshSettings:isPerishableByIndex(fillType) then
        return superFunc(station, fillableObject, fillUnitIndex, fillType, delta, fillInfo, toolType)
    end

    -- Resolve destination first (vehicle fillUnit)
    local destContainerId = RmVehicleAdapter:getContainerIdForFillUnit(fillableObject, fillUnitIndex)

    -- Resolve source: iterate station.sourceStorages (v1 pattern)
    -- LoadingStation can have multiple source storages - find first with fill
    local sourceContainerId = nil
    if station.sourceStorages ~= nil then
        local farmId = fillableObject:getOwnerFarmId()
        for _, storage in pairs(station.sourceStorages) do
            if station:hasFarmAccessToStorage(farmId, storage) then
                local fillLevel = storage:getFillLevel(fillType)
                if fillLevel ~= nil and fillLevel > 0 then
                    sourceContainerId = RmPlaceableAdapter:getContainerIdForStorage(storage, fillType)
                    if sourceContainerId then break end
                end
            end
        end
    end

    -- Stage transfer if both containers tracked
    if sourceContainerId and destContainerId then
        -- Peek source batches for delta amount
        local peeked = RmFreshManager:peekBatches(sourceContainerId, delta)

        if peeked.totalAmount > 0 then
            RmFreshManager:setTransferPending(destContainerId, peeked.batches)
            Log:debug("LOADING_STAGE: %s -> %s amount=%.1f batches=%d",
                sourceContainerId, destContainerId, peeked.totalAmount, #peeked.batches)
        end
    end

    -- Call original (game performs transfer)
    local actualDelta = superFunc(station, fillableObject, fillUnitIndex, fillType, delta, fillInfo, toolType)

    -- NOTE: Destination adapter's onFillChanged will consume pending batches

    return actualDelta
end

-- =============================================================================
-- DISCHARGEABLE HOOK (Vehicle → Target)
-- =============================================================================

--- Dischargeable hook registration
--- NOTE: dischargeToObject is registered via RmVehicleAdapter.registerOverwrittenFunctions()
--- using SpecializationUtil.registerOverwrittenFunction(). This is REQUIRED because late
--- Utils.overwrittenFunction hooks don't reach already-loaded vehicle instances.
--- The LoadingStation hook does NOT have this issue because LoadingStation is not a
--- vehicle specialization.
function RmTransferCoordinator.installDischargeableHook()
    -- No-op: hook is now registered via VehicleAdapter specialization system
    Log:debug("Dischargeable hook: registered via VehicleAdapter specialization (type-level)")
end

--- Wrapped Dischargeable transfer function
--- SIGNATURE from v1: (vehicle, superFunc, dischargeNode, emptyLiters, object, targetFillUnitIndex)
---@param vehicle table The discharging vehicle (self in Dischargeable)
---@param superFunc function Original function
---@param dischargeNode table Discharge node configuration
---@param emptyLiters number Amount to discharge
---@param object table Target object (storage, vehicle, UnloadTrigger, etc.)
---@param targetFillUnitIndex number Target fill unit index
---@return number dischargedLiters Amount actually discharged
function RmTransferCoordinator.dischargeToObject(vehicle, superFunc, dischargeNode, emptyLiters, object, targetFillUnitIndex)
    -- EARLY DEBUG: Log EVERY call to this hook (before any filtering)
    Log:trace("DISCHARGE_HOOK_ENTRY: vehicle=%s emptyLiters=%.1f object=%s targetFillUnitIndex=%s",
        tostring(vehicle and vehicle.getName and vehicle:getName() or "nil"),
        emptyLiters or 0,
        tostring(object ~= nil),
        tostring(targetFillUnitIndex))

    -- Server only
    if g_server == nil then
        return superFunc(vehicle, dischargeNode, emptyLiters, object, targetFillUnitIndex)
    end

    -- Get fill type from discharge node
    local fillType, _ = vehicle:getDischargeFillType(dischargeNode)

    -- Skip if no fill type (edge case: empty discharge node)
    if not fillType then
        return superFunc(vehicle, dischargeNode, emptyLiters, object, targetFillUnitIndex)
    end

    -- Skip non-perishable
    if not RmFreshSettings:isPerishableByIndex(fillType) then
        return superFunc(vehicle, dischargeNode, emptyLiters, object, targetFillUnitIndex)
    end

    -- Resolve source (vehicle's discharge fillUnit)
    local sourceFillUnitIndex = dischargeNode.fillUnitIndex
    local sourceContainerId = RmVehicleAdapter:getContainerIdForFillUnit(vehicle, sourceFillUnitIndex)

    -- Resolve destination (complex - v1 has extensive resolution logic)
    -- Target can be: Vehicle, Storage, UnloadTrigger→Storage, UnloadTrigger→UnloadingStation→Storage
    local destContainerId = RmTransferCoordinator.resolveDischargeTarget(object, targetFillUnitIndex, fillType)

    -- Stage transfer if both containers tracked
    if sourceContainerId and destContainerId then
        local peeked = RmFreshManager:peekBatches(sourceContainerId, emptyLiters)

        if peeked.totalAmount > 0 then
            RmFreshManager:setTransferPending(destContainerId, peeked.batches)
            Log:debug("DISCHARGE_STAGE: %s -> %s amount=%.1f batches=%d",
                sourceContainerId, destContainerId, peeked.totalAmount, #peeked.batches)
        end
    end

    -- Mixture-aware staging for unresolved destinations (e.g., husbandry food troughs)
    -- When dest can't be resolved but source is a mixture, pre-expand to ingredient
    -- fillType pending entries so HusbandryFoodAdapter can match by fillType
    if sourceContainerId and not destContainerId then
        Log:trace("    mixture check: source=%s has no dest, checking fillType=%d", sourceContainerId, fillType)
        local mixture = g_currentMission.animalFoodSystem:getMixtureByFillType(fillType)
        if mixture then
            local peeked = RmFreshManager:peekBatches(sourceContainerId, emptyLiters)
            if peeked.totalAmount > 0 then
                local stagedCount = 0
                for _, ingredient in ipairs(mixture.ingredients) do
                    local ingredientFillType = ingredient.fillTypes[1]
                    if RmFreshSettings:isPerishableByIndex(ingredientFillType) then
                        local scaledBatches = {}
                        for _, batch in ipairs(peeked.batches) do
                            table.insert(scaledBatches, {
                                amount = batch.amount * ingredient.weight,
                                age = batch.age
                            })
                        end
                        RmFreshManager:setTransferPendingByFillType(ingredientFillType, scaledBatches)
                        stagedCount = stagedCount + 1
                        Log:trace("    mixture ingredient: fillType=%d weight=%.2f batches=%d",
                            ingredientFillType, ingredient.weight, #scaledBatches)
                    else
                        Log:trace("    mixture ingredient skipped: fillType=%d (non-perishable)", ingredientFillType)
                    end
                end
                Log:debug("DISCHARGE_MIXTURE_EXPAND: %s fillType=%d -> %d ingredients (%d perishable) amount=%.1f",
                    sourceContainerId, fillType, #mixture.ingredients, stagedCount, peeked.totalAmount)
            end
        end
    end

    -- Call original
    return superFunc(vehicle, dischargeNode, emptyLiters, object, targetFillUnitIndex)
end

-- =============================================================================
-- TARGET RESOLUTION HELPER
-- =============================================================================

--- Resolve discharge target to containerId
--- CRITICAL: v1 has extensive resolution logic for different target types
--- Patterns from v1 (scripts-v1/RmFresh.lua:935-1058):
---   1. Direct RmPerishableVehicle (vehicle-to-vehicle)
---   2. Direct RmPerishablePlaceable
---   3. UnloadTrigger → .target → RmPerishablePlaceable
---   4. UnloadTrigger → UnloadingStation → owningPlaceable
---   5. Storage → owningPlaceable
---@param object table Target object
---@param targetFillUnitIndex number Target fill unit (for vehicles)
---@param fillType number Fill type index
---@return string|nil containerId or nil
function RmTransferCoordinator.resolveDischargeTarget(object, targetFillUnitIndex, fillType)
    if object == nil then return nil end

    -- DEBUG: Log object properties to diagnose resolution failures
    Log:trace("DISCHARGE_RESOLVE: type=%s spec_fillUnit=%s getFillLevel=%s target=%s owningPlaceable=%s",
        tostring(object.typeName or type(object)),
        tostring(object.spec_fillUnit ~= nil),
        tostring(object.getFillLevel ~= nil),
        tostring(object.target ~= nil),
        tostring(object.owningPlaceable ~= nil))

    -- Pattern 1: Target is a vehicle with FillUnit spec
    if object.spec_fillUnit ~= nil and targetFillUnitIndex then
        return RmVehicleAdapter:getContainerIdForFillUnit(object, targetFillUnitIndex)
    end

    -- Pattern 2: Target is a Storage object (has getFillLevel)
    if object.getFillLevel ~= nil then
        return RmPlaceableAdapter:getContainerIdForStorage(object, fillType)
    end

    -- Pattern 3: UnloadTrigger pattern - has .target property
    if object.target ~= nil then
        local innerTarget = object.target

        -- 3a: Direct storage from UnloadTrigger.target
        if innerTarget.getFillLevel ~= nil then
            return RmPlaceableAdapter:getContainerIdForStorage(innerTarget, fillType)
        end

        -- 3b: UnloadingStation pattern (has owningPlaceable + targetStorages)
        if innerTarget.owningPlaceable ~= nil and innerTarget.targetStorages ~= nil then
            -- Get first available storage from UnloadingStation
            for _, storage in pairs(innerTarget.targetStorages) do
                local containerId = RmPlaceableAdapter:getContainerIdForStorage(storage, fillType)
                if containerId then return containerId end
            end
        end

        -- 3c: Simple owningPlaceable (UnloadingStation without targetStorages)
        if innerTarget.owningPlaceable ~= nil then
            -- Try to find storage in the placeable
            local storages = RmPlaceableAdapter.discoverStorages(innerTarget.owningPlaceable)
            for _, storageInfo in ipairs(storages) do
                local containerId = RmPlaceableAdapter:getContainerIdForStorage(storageInfo.storage, fillType)
                if containerId then return containerId end
            end
        end
    end

    -- Pattern 4: Direct owningPlaceable (Storage object with owner reference)
    if object.owningPlaceable ~= nil then
        local storages = RmPlaceableAdapter.discoverStorages(object.owningPlaceable)
        for _, storageInfo in ipairs(storages) do
            local containerId = RmPlaceableAdapter:getContainerIdForStorage(storageInfo.storage, fillType)
            if containerId then return containerId end
        end
    end

    -- Pattern 5: Husbandry feedingTroughs (not yet implemented)
    -- Full implementation requires HusbandryFoodAdapter reverse lookup
    -- For now, husbandry discharges will create fresh batches (age=0)

    Log:trace("DISCHARGE_TARGET_UNRESOLVED: objectType=%s", tostring(object.typeName or type(object)))
    return nil
end

-- =============================================================================
-- DIRECT BATCH TRANSFER (EXPERIMENTAL)
-- =============================================================================
-- Used by ObjectStorageAdapter for entry/exit transfers where entire batch
-- lists need to move between containers (not incremental fill changes).
--
-- EXPERIMENTAL: May be refactored or removed if approach doesn't work.
-- =============================================================================

--- Transfer all batches from source container to destination container
--- Moves entire batch list, preserving ages. Clears source batches after transfer.
--- SERVER ONLY - batch data only exists on server
---@param sourceContainerId string Source container ID
---@param destContainerId string Destination container ID
---@return boolean success True if transfer completed
---@return number batchCount Number of batches transferred
---@return number totalAmount Total amount transferred
function RmTransferCoordinator.transferAllBatches(sourceContainerId, destContainerId)
    Log:trace(">>> transferAllBatches(source=%s, dest=%s)",
        sourceContainerId or "nil", destContainerId or "nil")

    -- Server only
    if g_server == nil then
        Log:trace("<<< transferAllBatches: client (no-op)")
        return false, 0, 0
    end

    -- Validate containers
    if not sourceContainerId or not destContainerId then
        Log:trace("<<< transferAllBatches: missing containerId")
        return false, 0, 0
    end

    local sourceContainer = RmFreshManager:getContainer(sourceContainerId)
    if not sourceContainer then
        Log:trace("<<< transferAllBatches: source not found")
        return false, 0, 0
    end

    local destContainer = RmFreshManager:getContainer(destContainerId)
    if not destContainer then
        Log:trace("<<< transferAllBatches: dest not found")
        return false, 0, 0
    end

    -- Get all batches from source
    local sourceBatches = RmFreshManager:getBatches(sourceContainerId)
    if not sourceBatches or #sourceBatches == 0 then
        Log:trace("<<< transferAllBatches: no batches in source")
        return true, 0, 0  -- Success but nothing to transfer
    end

    -- Transfer each batch to destination (preserving ages)
    local batchCount = 0
    local totalAmount = 0

    for _, batch in ipairs(sourceBatches) do
        RmFreshManager:addBatch(destContainerId, batch.amount, batch.ageInPeriods)
        batchCount = batchCount + 1
        totalAmount = totalAmount + batch.amount
    end

    -- Clear source batches
    RmFreshManager:clearBatches(sourceContainerId)

    Log:debug("TRANSFER_ALL_BATCHES: %s -> %s batches=%d amount=%.1f",
        sourceContainerId, destContainerId, batchCount, totalAmount)
    Log:trace("<<< transferAllBatches: success")

    return true, batchCount, totalAmount
end
