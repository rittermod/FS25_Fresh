-- RmObjectStorageAdapter.lua
-- Purpose: Thin object storage adapter - bridges FS25 PlaceableObjectStorage to centralized FreshManager
-- Author: Ritter
-- Pattern: Specialization-based adapter (like PlaceableAdapter, VehicleAdapter)

RmObjectStorageAdapter = {}
RmObjectStorageAdapter.SPEC_TABLE_NAME = ("spec_%s.rmObjectStorageAdapter"):format(g_currentModName)
RmObjectStorageAdapter.ENTITY_TYPE = "stored"

-- Client-side cache for expiring counts (synced from server)
-- Structure: [placeable] = { [objectInfoIndex] = count }
RmObjectStorageAdapter.clientExpiringCounts = {}

local Log = RmLogging.getLogger("Fresh")

-- =============================================================================
-- SPECIALIZATION SETUP
-- =============================================================================

--- Check if placeable has PlaceableObjectStorage specialization
---@param specializations table Specializations table
---@return boolean True if placeable has object storage capabilities
function RmObjectStorageAdapter.prerequisitesPresent(specializations)
    return SpecializationUtil.hasSpecialization(PlaceableObjectStorage, specializations)
end

--- Register event listeners for placeable lifecycle and MP sync
---@param placeableType table Placeable type table
function RmObjectStorageAdapter.registerEventListeners(placeableType)
    SpecializationUtil.registerEventListener(placeableType, "onLoad", RmObjectStorageAdapter)
    SpecializationUtil.registerEventListener(placeableType, "onLoadFinished", RmObjectStorageAdapter)
    SpecializationUtil.registerEventListener(placeableType, "onDelete", RmObjectStorageAdapter)
    -- MP sync for client display
    SpecializationUtil.registerEventListener(placeableType, "onWriteStream", RmObjectStorageAdapter)
    SpecializationUtil.registerEventListener(placeableType, "onReadStream", RmObjectStorageAdapter)
end

--- Register overwritten functions for HUD display and entry/exit hooks
---@param placeableType table Placeable type table
function RmObjectStorageAdapter.registerOverwrittenFunctions(placeableType)
    SpecializationUtil.registerOverwrittenFunction(placeableType, "updateInfo", RmObjectStorageAdapter.updateInfo)
    -- Entry hook: Object enters storage
    SpecializationUtil.registerOverwrittenFunction(placeableType, "addObjectToObjectStorage",
        RmObjectStorageAdapter.addObjectToObjectStorageHook)
    -- Exit hook: Object leaves storage (spawns back)
    SpecializationUtil.registerOverwrittenFunction(placeableType, "removeAbstractObjectFromStorage",
        RmObjectStorageAdapter.removeAbstractObjectFromStorageHook)
    -- Sort hook: Ensure oldest items exit first
    SpecializationUtil.registerOverwrittenFunction(placeableType, "updateObjectStorageObjectInfos",
        RmObjectStorageAdapter.updateObjectStorageObjectInfosHook)
end

-- =============================================================================
-- LIFECYCLE HOOKS
-- =============================================================================

--- Called when placeable loads
--- Creates spec table for container tracking
---@param _savegame table|nil Savegame data (unused)
function RmObjectStorageAdapter:onLoad(_savegame)
    Log:trace(">>> OBJECTSTORAGE_onLoad(isServer=%s, name=%s)",
        tostring(self.isServer), self:getName() or "unknown")

    -- Server only for batch tracking
    if not self.isServer then
        Log:trace("<<< OBJECTSTORAGE_onLoad: client (spec init only)")
        -- Still create spec table for client MP sync
        self[RmObjectStorageAdapter.SPEC_TABLE_NAME] = {
            containerIds = {},
            abstractObjectContainers = {},
            pendingSpawn = nil,
        }
        return
    end

    -- Skip construction preview placeables
    -- PlaceablePropertyState: NONE=1, OWNED=2, CONSTRUCTION_PREVIEW=3
    local propertyState = self:getPropertyState()
    if propertyState == PlaceablePropertyState.CONSTRUCTION_PREVIEW or
        propertyState == PlaceablePropertyState.NONE then
        Log:trace("<<< OBJECTSTORAGE_onLoad: skip (propertyState=%d)",
            propertyState or 0)
        return
    end

    -- Create spec table
    self[RmObjectStorageAdapter.SPEC_TABLE_NAME] = {
        containerIds = {},             -- index → containerId (for general tracking)
        abstractObjectContainers = {}, -- abstractObject → containerId (runtime mapping)
        pendingSpawn = nil,            -- abstractObject being spawned (for exit flow)
        deferredRegistration = false,  -- Prevent double scheduling
    }

    Log:trace("<<< OBJECTSTORAGE_onLoad: spec initialized (propertyState=%d)",
        propertyState or 0)
end

--- Called when placeable finishes loading
--- Registers containers for any stored objects loaded from savegame
---@param _savegame table|nil Savegame data (unused)
function RmObjectStorageAdapter:onLoadFinished(_savegame)
    Log:trace(">>> OBJECTSTORAGE_onLoadFinished(isServer=%s, name=%s)",
        tostring(self.isServer), self:getName() or "unknown")

    -- Server only
    if not self.isServer then
        Log:trace("<<< OBJECTSTORAGE_onLoadFinished: client (no-op)")
        return
    end

    -- Skip construction preview placeables
    local propertyState = self:getPropertyState()
    if propertyState == PlaceablePropertyState.CONSTRUCTION_PREVIEW or
        propertyState == PlaceablePropertyState.NONE then
        Log:trace("<<< OBJECTSTORAGE_onLoadFinished: skip (propertyState=%d)",
            propertyState or 0)
        return
    end

    local spec = self[RmObjectStorageAdapter.SPEC_TABLE_NAME]
    if spec == nil then
        Log:trace("<<< OBJECTSTORAGE_onLoadFinished: no spec table")
        return
    end

    -- Check if uniqueId is available
    local entityId = self.uniqueId
    if entityId == nil or entityId == "" then
        -- Defer registration - uniqueId assigned after onLoadFinished for purchased placeables
        RmObjectStorageAdapter.deferRegistration(self)
        Log:trace("<<< OBJECTSTORAGE_onLoadFinished: deferred (no uniqueId yet)")
        return
    end

    -- Register containers for stored objects (from savegame)
    RmObjectStorageAdapter.doLoadRegistration(self, entityId)

    Log:trace("<<< OBJECTSTORAGE_onLoadFinished: complete")
end

--- Register containers for stored objects loaded from savegame
--- Called after uniqueId is available
---@param placeable table The placeable entity
---@param entityId string The placeable's uniqueId
function RmObjectStorageAdapter.doLoadRegistration(placeable, entityId)
    Log:trace(">>> doLoadRegistration(entityId=%s)", entityId)

    local specOS = placeable.spec_objectStorage
    if not specOS or not specOS.storedObjects then
        Log:trace("<<< doLoadRegistration: no storedObjects")
        return
    end

    local spec = placeable[RmObjectStorageAdapter.SPEC_TABLE_NAME]
    local registeredCount = 0

    for i, abstractObject in ipairs(specOS.storedObjects) do
        -- Build identity from abstractObject
        local identityMatch = RmObjectStorageAdapter.buildIdentityFromAbstractObject(placeable, abstractObject)
        if not identityMatch then
            Log:trace("    [%d] identity build failed", i)
        else
            local fillTypeName = identityMatch.storage.fillTypeName
            local className = identityMatch.storage.className
            local amount = identityMatch.storage.amount

            -- Check if perishable
            local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(fillTypeName)
            if not fillTypeIndex or not RmFreshSettings:isPerishableByIndex(fillTypeIndex) then
                Log:trace("    [%d] %s %s not perishable", i, className or "?", fillTypeName or "?")
            else
                -- Get farmId from placeable owner
                local farmId = placeable.getOwnerFarmId and placeable:getOwnerFarmId() or 0

                -- Register with Manager (will reconcile with fresh.xml)
                -- AbstractObject IS a runtime entity - it exists in spec_objectStorage.storedObjects[]
                local containerId, wasReconciled = RmFreshManager:registerContainer(
                    RmObjectStorageAdapter.ENTITY_TYPE,
                    identityMatch,
                    abstractObject, -- AbstractObject is the runtime entity for stored items
                    { adapter = RmObjectStorageAdapter, farmId = farmId }
                )

                if containerId then
                    -- Map abstractObject → containerId for exit tracking
                    spec.abstractObjectContainers[abstractObject] = containerId
                    spec.containerIds[i] = containerId
                    registeredCount = registeredCount + 1

                    Log:debug("OBJECTSTORAGE_LOAD_REGISTER: [%d] %s %s %.0fL -> %s (reconciled=%s)",
                        i, className, fillTypeName, amount, containerId, tostring(wasReconciled))
                else
                    Log:trace("    [%d] registration failed", i)
                end
            end
        end
    end

    if registeredCount > 0 then
        Log:info("OBJECTSTORAGE_LOAD: %s registered %d containers from savegame",
            placeable:getName() or entityId, registeredCount)
    end

    Log:trace("<<< doLoadRegistration: %d registered", registeredCount)
end

--- Rescan all object storage placeables for newly-perishable objects
--- Called when settings change makes a fillType perishable
---@return number count Number of new containers registered
function RmObjectStorageAdapter.rescanForPerishables()
    if not g_currentMission or not g_currentMission.placeableSystem then return 0 end

    Log:trace(">>> RmObjectStorageAdapter.rescanForPerishables()")
    local count = 0

    for _, placeable in ipairs(g_currentMission.placeableSystem.placeables) do
        local spec = placeable[RmObjectStorageAdapter.SPEC_TABLE_NAME]
        if spec and spec.containerIds then
            local specOS = placeable.spec_objectStorage
            if specOS and specOS.storedObjects then
                for i, abstractObject in ipairs(specOS.storedObjects) do
                    -- Skip if this slot already registered
                    if spec.containerIds[i] == nil then
                        local identityMatch = RmObjectStorageAdapter.buildIdentityFromAbstractObject(
                            placeable, abstractObject
                        )
                        if identityMatch then
                            local fillTypeName = identityMatch.storage.fillTypeName
                            local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(fillTypeName)
                            if fillTypeIndex and RmFreshSettings:isPerishableByIndex(fillTypeIndex) then
                                local farmId = placeable.getOwnerFarmId and placeable:getOwnerFarmId() or 0
                                local containerId = RmFreshManager:registerContainer(
                                    RmObjectStorageAdapter.ENTITY_TYPE,
                                    identityMatch, abstractObject,
                                    { adapter = RmObjectStorageAdapter, farmId = farmId }
                                )
                                if containerId then
                                    spec.abstractObjectContainers[abstractObject] = containerId
                                    spec.containerIds[i] = containerId
                                    -- Initial batch at age=0 (no savegame data for newly-perishable)
                                    local amount = identityMatch.storage.amount or 0
                                    if amount > 0 then
                                        RmFreshManager:addBatch(containerId, amount, 0)
                                    end
                                    count = count + 1

                                    Log:debug("RESCAN_OBJECTSTORAGE: [%d] %s %.0fL -> %s name=%s",
                                        i, fillTypeName, amount, containerId,
                                        placeable:getName() or "unknown")
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    Log:trace("<<< RmObjectStorageAdapter.rescanForPerishables = %d", count)
    return count
end

-- =============================================================================
-- DEFERRED REGISTRATION (for purchased placeables)
-- =============================================================================

--- Polling timeout for deferred registration: 10 seconds
local DEFER_TIMEOUT_MS = 10000

--- Defer registration until uniqueId is available (for purchased placeables)
--- Pattern from PlaceableAdapter with timeout protection
---@param placeable table Placeable entity
function RmObjectStorageAdapter.deferRegistration(placeable)
    local spec = placeable[RmObjectStorageAdapter.SPEC_TABLE_NAME]
    if spec.deferredRegistration then return end -- Already scheduled

    spec.deferredRegistration = true
    Log:debug("OBJECTSTORAGE_DEFER: %s (uniqueId not yet assigned)", placeable:getName() or "unknown")

    local startTime = g_currentMission.time

    g_currentMission:addUpdateable({
        placeable = placeable,
        update = function(self, _dt)
            -- Guard: mission teardown
            if g_currentMission == nil then
                return
            end

            local p = self.placeable

            -- Success: uniqueId now available
            if p.uniqueId and p.uniqueId ~= "" then
                Log:trace("OBJECTSTORAGE_DEFER_COMPLETE: uniqueId=%s after %dms",
                    p.uniqueId, g_currentMission.time - startTime)
                RmObjectStorageAdapter.doLoadRegistration(p, p.uniqueId)
                g_currentMission:removeUpdateable(self)
                return
            end

            -- Cancelled: placeable deleted before uniqueId assigned
            if p.isDeleted then
                Log:trace("OBJECTSTORAGE_DEFER_CANCELLED: placeable deleted")
                g_currentMission:removeUpdateable(self)
                return
            end

            -- Timeout: polling exhausted
            if (g_currentMission.time - startTime) > DEFER_TIMEOUT_MS then
                Log:warning("OBJECTSTORAGE_NO_UNIQUEID: %s failed to get uniqueId after %dms",
                    p:getName() or "unknown", DEFER_TIMEOUT_MS)
                g_currentMission:removeUpdateable(self)
                return
            end
        end
    })
end

--- Called when placeable is deleted
--- Unregisters all containers
function RmObjectStorageAdapter:onDelete()
    Log:trace(">>> OBJECTSTORAGE_onDelete(isServer=%s, uniqueId=%s)",
        tostring(self.isServer), self.uniqueId or "?")

    -- Server only
    if not self.isServer then
        Log:trace("<<< OBJECTSTORAGE_onDelete: client (no-op)")
        return
    end

    local spec = self[RmObjectStorageAdapter.SPEC_TABLE_NAME]
    if spec == nil then
        Log:trace("<<< OBJECTSTORAGE_onDelete: no spec")
        return
    end

    -- Unregister all containers
    local count = 0
    if spec.abstractObjectContainers then
        for abstractObject, containerId in pairs(spec.abstractObjectContainers) do
            if containerId and RmFreshManager then
                RmFreshManager:unregisterContainer(containerId)
                count = count + 1
                Log:trace("    unregistered: %s", containerId)
            end
        end
    end

    if count > 0 then
        Log:debug("OBJECTSTORAGE_DELETE: %s unregistered %d containers",
            self.uniqueId or "?", count)
    end

    spec.containerIds = nil
    spec.abstractObjectContainers = nil
    spec.pendingSpawn = nil

    Log:trace("<<< OBJECTSTORAGE_onDelete: %d unregistered", count)
end

-- =============================================================================
-- ENTRY HOOK: Object enters storage
-- =============================================================================

--- Hook for addObjectToObjectStorage - captures batches when object enters storage
--- Called AFTER superFunc so abstractObject exists in storedObjects
---@param superFunc function Original function
---@param object table The real object (bale or pallet) entering storage
---@param loadedFromSavegame boolean True if loading from savegame (skip transfer)
function RmObjectStorageAdapter:addObjectToObjectStorageHook(superFunc, object, loadedFromSavegame)
    Log:trace(">>> addObjectToObjectStorageHook(object=%s, loadedFromSavegame=%s)",
        tostring(object and object.uniqueId or "nil"), tostring(loadedFromSavegame))

    -- Server only for batch tracking
    if not self.isServer then
        Log:trace("    client: calling superFunc only")
        superFunc(self, object, loadedFromSavegame)
        Log:trace("<<< addObjectToObjectStorageHook: client done")
        return
    end

    -- Get source containerId AND batches BEFORE calling super (object still exists)
    -- CRITICAL: superFunc virtualizes the object, which triggers adapter.onDelete()
    -- That unregisters the container. We must capture batches BEFORE that happens.
    local sourceContainerId = nil
    local sourceBatches = nil
    local objectClassName = nil

    if object then
        -- Detect object type - use isa() which is more reliable than ClassUtil
        if object.isa and object:isa(Bale) then
            objectClassName = "Bale"
        elseif object.spec_fillUnit then
            objectClassName = "Vehicle"
        end
        Log:trace("    objectClassName=%s", objectClassName or "nil")

        if objectClassName == "Bale" then
            sourceContainerId = RmBaleAdapter:getContainerIdForBale(object)
            Log:trace("    source (bale): containerId=%s", sourceContainerId or "nil")
        elseif object.spec_fillUnit then
            -- Vehicle (pallet) - fillUnit 1 for standard pallets
            sourceContainerId = RmVehicleAdapter:getContainerIdForFillUnit(object, 1)
            Log:trace("    source (vehicle): containerId=%s", sourceContainerId or "nil")
        end

        -- Capture batches NOW before superFunc deletes the container
        if sourceContainerId then
            sourceBatches = RmFreshManager:getBatches(sourceContainerId)
            if sourceBatches then
                Log:trace("    captured %d batches from source", #sourceBatches)
            end
        end
    end

    -- Call original function (creates abstractObject, virtualizes real object)
    -- WARNING: This triggers BaleAdapter/VehicleAdapter onDelete() which unregisters the source container!
    superFunc(self, object, loadedFromSavegame)

    -- Skip if loading from savegame (containers registered in onLoadFinished)
    if loadedFromSavegame then
        Log:trace("<<< addObjectToObjectStorageHook: loadedFromSavegame (skip transfer)")
        return
    end

    -- Skip if no source batches (not tracked by Fresh or no batches)
    if not sourceBatches or #sourceBatches == 0 then
        Log:trace("<<< addObjectToObjectStorageHook: no source batches")
        return
    end

    local spec = self[RmObjectStorageAdapter.SPEC_TABLE_NAME]
    if not spec then
        Log:trace("<<< addObjectToObjectStorageHook: no spec")
        return
    end

    -- Find the abstractObject that was just created (last in storedObjects)
    local specOS = self.spec_objectStorage
    if not specOS or not specOS.storedObjects or #specOS.storedObjects == 0 then
        Log:trace("<<< addObjectToObjectStorageHook: no storedObjects")
        return
    end

    local abstractObject = specOS.storedObjects[#specOS.storedObjects]
    Log:trace("    abstractObject: index=%d, className=%s",
        #specOS.storedObjects, abstractObject.REFERENCE_CLASS_NAME or "?")

    -- Build identity from abstractObject
    local identityMatch = RmObjectStorageAdapter.buildIdentityFromAbstractObject(self, abstractObject)
    if not identityMatch then
        Log:trace("<<< addObjectToObjectStorageHook: identity build failed")
        return
    end

    local fillTypeName = identityMatch.storage.fillTypeName
    local amount = identityMatch.storage.amount

    -- Check if perishable
    local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(fillTypeName)
    if not fillTypeIndex or not RmFreshSettings:isPerishableByIndex(fillTypeIndex) then
        Log:trace("<<< addObjectToObjectStorageHook: %s not perishable", fillTypeName or "?")
        return
    end

    -- Get farmId from placeable owner
    local farmId = self.getOwnerFarmId and self:getOwnerFarmId() or 0

    -- Register stored container with abstractObject as runtimeEntity
    -- AbstractObject IS a runtime entity - it exists in spec_objectStorage.storedObjects[]
    local storedContainerId, _ = RmFreshManager:registerContainer(
        RmObjectStorageAdapter.ENTITY_TYPE,
        identityMatch,
        abstractObject, -- AbstractObject is the runtime entity for stored items
        { adapter = RmObjectStorageAdapter, farmId = farmId }
    )

    if not storedContainerId then
        Log:warning("OBJECTSTORAGE_ENTRY: failed to register container for %s",
            fillTypeName or "?")
        Log:trace("<<< addObjectToObjectStorageHook: registration failed")
        return
    end

    -- Add captured batches to stored container (source container already deleted by superFunc)
    local batchCount = 0
    local totalAmount = 0

    for _, batch in ipairs(sourceBatches) do
        RmFreshManager:addBatch(storedContainerId, batch.amount, batch.ageInPeriods)
        batchCount = batchCount + 1
        totalAmount = totalAmount + batch.amount
    end

    if batchCount > 0 then
        Log:info("OBJECTSTORAGE_ENTRY: %s %s %.0fL -> stored (%d batches transferred)",
            objectClassName or "Object", fillTypeName, amount, batchCount)
        Log:debug("OBJECTSTORAGE_ENTRY_DETAIL: dest=%s batches=%d amount=%.1f",
            storedContainerId, batchCount, totalAmount)
    end

    -- Map abstractObject → containerId for exit tracking
    spec.abstractObjectContainers[abstractObject] = storedContainerId
    spec.containerIds[#specOS.storedObjects] = storedContainerId

    Log:trace("<<< addObjectToObjectStorageHook: success")
end

-- =============================================================================
-- EXIT HOOK: Object leaves storage (spawns back)
-- =============================================================================

--- Hook for removeAbstractObjectFromStorage - transfers batches when object spawns
--- Strategy: Snapshot existing containers → superFunc → find new container → transfer
---@param superFunc function Original function
---@param abstractObject table The abstract object being spawned
---@param x number Spawn X position
---@param y number Spawn Y position
---@param z number Spawn Z position
---@param rx number Spawn X rotation
---@param ry number Spawn Y rotation
---@param rz number Spawn Z rotation
function RmObjectStorageAdapter:removeAbstractObjectFromStorageHook(superFunc, abstractObject, x, y, z, rx, ry, rz)
    local className = abstractObject and abstractObject.REFERENCE_CLASS_NAME or "nil"
    Log:trace(">>> removeAbstractObjectFromStorageHook(className=%s, pos=%.1f,%.1f,%.1f)",
        className, x or 0, y or 0, z or 0)

    -- Client: just call super
    if not self.isServer then
        superFunc(self, abstractObject, x, y, z, rx, ry, rz)
        Log:trace("<<< removeAbstractObjectFromStorageHook: client done")
        return
    end

    local spec = self[RmObjectStorageAdapter.SPEC_TABLE_NAME]
    if not spec then
        superFunc(self, abstractObject, x, y, z, rx, ry, rz)
        Log:trace("<<< removeAbstractObjectFromStorageHook: no spec")
        return
    end

    -- Get stored containerId and batches BEFORE spawn
    local storedContainerId = spec.abstractObjectContainers[abstractObject]
    local sourceBatches = nil

    if storedContainerId then
        sourceBatches = RmFreshManager:getBatches(storedContainerId)
        Log:trace("    stored containerId=%s batches=%d",
            storedContainerId, sourceBatches and #sourceBatches or 0)
    end

    -- Snapshot existing bale/vehicle containerIds BEFORE spawn
    -- The spawned entity will register during superFunc
    local existingContainerIds = {}
    if className == "Bale" then
        existingContainerIds = RmObjectStorageAdapter.snapshotBaleContainerIds()
    elseif className == "Vehicle" then
        existingContainerIds = RmObjectStorageAdapter.snapshotVehicleContainerIds()
    end
    Log:trace("    snapshot: %d existing containers", RmObjectStorageAdapter.tableCount(existingContainerIds))

    -- Call original (spawns entity, which registers with its adapter)
    superFunc(self, abstractObject, x, y, z, rx, ry, rz)

    -- Find newly registered containerId (not in snapshot)
    local destContainerId = nil
    if className == "Bale" then
        destContainerId = RmObjectStorageAdapter.findNewBaleContainerId(existingContainerIds)
    elseif className == "Vehicle" then
        destContainerId = RmObjectStorageAdapter.findNewVehicleContainerId(existingContainerIds)
    end

    if destContainerId and sourceBatches and #sourceBatches > 0 then
        -- Clear BaleAdapter's initial batch before adding stored batches
        -- (BaleAdapter creates age=0 batch on spawn, we replace with aged batch)
        RmFreshManager:clearBatches(destContainerId)

        -- Transfer batches from stored → spawned
        local batchCount = 0
        local totalAmount = 0

        for _, batch in ipairs(sourceBatches) do
            RmFreshManager:addBatch(destContainerId, batch.amount, batch.ageInPeriods)
            batchCount = batchCount + 1
            totalAmount = totalAmount + batch.amount
        end

        Log:info("OBJECTSTORAGE_EXIT: stored -> %s (%d batches, %.0fL transferred)",
            className, batchCount, totalAmount)
        Log:debug("OBJECTSTORAGE_EXIT_DETAIL: source=%s -> dest=%s",
            storedContainerId, destContainerId)
    elseif destContainerId then
        Log:debug("OBJECTSTORAGE_EXIT: %s spawned (no batches to transfer)", className)
    else
        -- Spawn might be async - schedule deferred check
        if storedContainerId and sourceBatches and #sourceBatches > 0 then
            Log:trace("    spawn async, scheduling deferred transfer")
            RmObjectStorageAdapter.scheduleDeferredExitTransfer(
                self, abstractObject, storedContainerId, sourceBatches, className)
        end
    end

    -- Cleanup stored container
    if storedContainerId then
        spec.abstractObjectContainers[abstractObject] = nil
        RmFreshManager:unregisterContainer(storedContainerId)
        Log:trace("    unregistered stored container: %s", storedContainerId)
    else
        -- Log warning if we expected to find a containerId (perishable class)
        -- Non-perishable items won't have containers, so only warn for perishables
        if className == "Bale" or className == "Vehicle" then
            Log:debug("OBJECTSTORAGE_EXIT: no containerId for %s exit (may be non-perishable)",
                className)
        end
    end

    Log:trace("<<< removeAbstractObjectFromStorageHook: done")
end

--- Snapshot current bale containerIds from Manager
---@return table<string,boolean> Set of existing containerIds
function RmObjectStorageAdapter.snapshotBaleContainerIds()
    local snapshot = {}
    local containers = RmFreshManager.containers or {}
    for containerId, container in pairs(containers) do
        if container.entityType == "bale" then
            snapshot[containerId] = true
        end
    end
    return snapshot
end

--- Snapshot current vehicle containerIds from Manager
---@return table<string,boolean> Set of existing containerIds
function RmObjectStorageAdapter.snapshotVehicleContainerIds()
    local snapshot = {}
    local containers = RmFreshManager.containers or {}
    for containerId, container in pairs(containers) do
        if container.entityType == "vehicle" then
            snapshot[containerId] = true
        end
    end
    return snapshot
end

--- Find bale containerId that wasn't in snapshot (newly created)
---@param snapshot table<string,boolean> Previous containerIds
---@return string|nil containerId New containerId or nil
function RmObjectStorageAdapter.findNewBaleContainerId(snapshot)
    local containers = RmFreshManager.containers or {}
    for containerId, container in pairs(containers) do
        if container.entityType == "bale" and not snapshot[containerId] then
            return containerId
        end
    end
    return nil
end

--- Find vehicle containerId that wasn't in snapshot (newly created)
---@param snapshot table<string,boolean> Previous containerIds
---@return string|nil containerId New containerId or nil
function RmObjectStorageAdapter.findNewVehicleContainerId(snapshot)
    local containers = RmFreshManager.containers or {}
    for containerId, container in pairs(containers) do
        if container.entityType == "vehicle" and not snapshot[containerId] then
            return containerId
        end
    end
    return nil
end

--- Count table entries
---@param t table|nil
---@return number
function RmObjectStorageAdapter.tableCount(t)
    if t == nil then return 0 end
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count
end

--- Schedule deferred exit transfer (for async spawns)
--- Polls for newly registered containers matching className
---@param placeable table The placeable
---@param abstractObject table The abstract object that was spawned
---@param storedContainerId string The stored container ID (already unregistered)
---@param sourceBatches table Array of batches to transfer
---@param className string "Bale" or "Vehicle"
function RmObjectStorageAdapter.scheduleDeferredExitTransfer(placeable, abstractObject, storedContainerId, sourceBatches,
                                                             className)
    Log:trace(">>> scheduleDeferredExitTransfer(className=%s, batches=%d)",
        className, sourceBatches and #sourceBatches or 0)

    -- Snapshot current containers
    local existingContainerIds = {}
    if className == "Bale" then
        existingContainerIds = RmObjectStorageAdapter.snapshotBaleContainerIds()
    elseif className == "Vehicle" then
        existingContainerIds = RmObjectStorageAdapter.snapshotVehicleContainerIds()
    end

    local startTime = g_currentMission.time
    local maxWaitMs = 2000 -- 2 second timeout

    g_currentMission:addUpdateable({
        update = function(self, _dt)
            -- Guard: mission teardown
            if g_currentMission == nil then
                g_currentMission:removeUpdateable(self)
                return
            end

            -- Look for newly registered container
            local destContainerId = nil
            if className == "Bale" then
                destContainerId = RmObjectStorageAdapter.findNewBaleContainerId(existingContainerIds)
            elseif className == "Vehicle" then
                destContainerId = RmObjectStorageAdapter.findNewVehicleContainerId(existingContainerIds)
            end

            if destContainerId then
                -- Clear BaleAdapter's initial batch before adding stored batches
                RmFreshManager:clearBatches(destContainerId)

                -- Transfer batches to spawned entity
                local batchCount = 0
                local totalAmount = 0

                for _, batch in ipairs(sourceBatches) do
                    RmFreshManager:addBatch(destContainerId, batch.amount, batch.ageInPeriods)
                    batchCount = batchCount + 1
                    totalAmount = totalAmount + batch.amount
                end

                Log:info("OBJECTSTORAGE_EXIT_DEFERRED: -> %s (%d batches, %.0fL transferred)",
                    className, batchCount, totalAmount)
                Log:debug("OBJECTSTORAGE_EXIT_DEFERRED_DETAIL: dest=%s", destContainerId)

                g_currentMission:removeUpdateable(self)
                return
            end

            -- Timeout check
            if (g_currentMission.time - startTime) > maxWaitMs then
                Log:warning("OBJECTSTORAGE_EXIT_TIMEOUT: %s spawn not detected after %dms (batches lost)",
                    className, maxWaitMs)
                g_currentMission:removeUpdateable(self)
                return
            end
        end
    })
end

-- =============================================================================
-- IDENTITY BUILDER
-- =============================================================================

--- Build identity structure from abstractObject for Manager registration
--- Uses almost ALL attributes for matching (per design doc)
---@param placeable table The placeable (for uniqueId)
---@param abstractObject table The abstract stored object
---@return table|nil identityMatch or nil if invalid
function RmObjectStorageAdapter.buildIdentityFromAbstractObject(placeable, abstractObject)
    Log:trace(">>> buildIdentityFromAbstractObject(uniqueId=%s, className=%s)",
        placeable.uniqueId or "?", abstractObject and abstractObject.REFERENCE_CLASS_NAME or "nil")

    if not abstractObject then
        Log:trace("<<< buildIdentityFromAbstractObject: nil abstractObject")
        return nil
    end

    local className = abstractObject.REFERENCE_CLASS_NAME

    -- Extract fillType, fillLevel, and farmId - all live inside baleAttributes/palletAttributes
    -- Bale: baleAttributes.fillType, baleAttributes.fillLevel, baleAttributes.farmId
    -- Vehicle: palletAttributes.fillType, palletAttributes.fillLevel, palletAttributes.ownerFarmId
    local fillTypeValue, fillLevel, farmId

    if className == "Bale" and abstractObject.baleAttributes then
        local ba = abstractObject.baleAttributes
        fillTypeValue = ba.fillType
        fillLevel = ba.fillLevel or 0
        farmId = ba.farmId
        Log:trace("    bale: fillType=%s, fillLevel=%.0f, farmId=%s",
            tostring(fillTypeValue), fillLevel, tostring(farmId))
    elseif className == "Vehicle" and abstractObject.palletAttributes then
        local pa = abstractObject.palletAttributes
        fillTypeValue = pa.fillType
        fillLevel = pa.fillLevel or 0
        farmId = pa.ownerFarmId -- Note: pallets use "ownerFarmId" not "farmId"
        Log:trace("    vehicle: fillType=%s, fillLevel=%.0f, farmId=%s",
            tostring(fillTypeValue), fillLevel, tostring(farmId))
    else
        -- Fallback for unknown structures
        Log:trace("    unknown structure className=%s", className)
        fillTypeValue = abstractObject.fillType
        fillLevel = abstractObject.fillLevel or 0
        farmId = abstractObject.farmId
    end

    if not fillTypeValue then
        Log:trace("<<< buildIdentityFromAbstractObject: no fillType")
        return nil
    end

    -- Convert fillType to name (could be index or already a name string)
    local fillTypeName
    if type(fillTypeValue) == "number" then
        fillTypeName = g_fillTypeManager:getFillTypeNameByIndex(fillTypeValue)
        Log:trace("    fillType index %d -> name '%s'", fillTypeValue, fillTypeName or "nil")
    else
        fillTypeName = fillTypeValue
    end

    if not fillTypeName then
        Log:trace("<<< buildIdentityFromAbstractObject: fillType name lookup failed")
        return nil
    end

    local identity = {
        worldObject = {
            uniqueId = placeable.uniqueId,
        },
        storage = {
            className = className,
            fillTypeName = fillTypeName,
            amount = fillLevel,
            farmId = farmId,
        },
    }

    -- Bale-specific attributes (all in baleAttributes)
    if className == "Bale" then
        local ba = abstractObject.baleAttributes or {}
        identity.storage.variationIndex = ba.variationIndex
        identity.storage.isMissionBale = ba.isMissionBale
        identity.storage.wrappingState = ba.wrappingState
        -- NOT needed for matching: filename, wrappingColor (cosmetic), isFermenting, fermentationTime
        Log:trace("    bale identity: variation=%s, mission=%s, wrapping=%.2f",
            tostring(ba.variationIndex), tostring(ba.isMissionBale), ba.wrappingState or 0)
    end

    -- Vehicle-specific attributes (all in palletAttributes)
    if className == "Vehicle" then
        local pa = abstractObject.palletAttributes or {}
        identity.storage.isBigBag = pa.isBigBag
        -- NOT needed for matching: configFileName, configurations (cosmetic)
        Log:trace("    vehicle identity: isBigBag=%s", tostring(pa.isBigBag))
    end

    Log:trace("<<< buildIdentityFromAbstractObject: %s %s %.0fL",
        className or "?", fillTypeName, fillLevel)

    return identity
end

--- Build identity structure for container registration (legacy interface)
--- TODO: Remove or redirect to buildIdentityFromAbstractObject
---@return table identityMatch
function RmObjectStorageAdapter:buildIdentityMatch()
    return {
        worldObject = {
            uniqueId = nil,
        },
        storage = {
            fillTypeName = nil,
            amount = 0,
        },
    }
end

-- =============================================================================
-- MP STREAM SYNC
-- =============================================================================

--- Sync containerIds and expiring counts to joining client
---@param streamId number Network stream ID
---@param _connection table Network connection (unused)
function RmObjectStorageAdapter:onWriteStream(streamId, _connection)
    local spec = self[RmObjectStorageAdapter.SPEC_TABLE_NAME]
    local containerIds = spec and spec.containerIds or {}

    -- Count containers
    local count = 0
    for _ in pairs(containerIds) do count = count + 1 end

    streamWriteUInt8(streamId, count)

    for key, containerId in pairs(containerIds) do
        streamWriteString(streamId, tostring(key))
        streamWriteString(streamId, containerId)
    end

    -- Phase 2: Sync expiring counts for HUD display
    local specOS = self.spec_objectStorage
    local numObjectInfos = specOS and specOS.objectInfos and #specOS.objectInfos or 0
    streamWriteUInt8(streamId, numObjectInfos)

    for i = 1, numObjectInfos do
        local expiringCount, soonestHours = RmObjectStorageAdapter.countExpiringInObjectInfo(specOS.objectInfos[i], self)
        streamWriteUInt8(streamId, expiringCount)
        streamWriteUInt16(streamId, math.max(0, math.floor(soonestHours)))
    end

    Log:trace("OBJECTSTORAGE_WRITE_STREAM: sent %d containerIds, %d expiring counts", count, numObjectInfos)
end

--- Receive containerIds and expiring counts on client join
---@param streamId number Network stream ID
---@param _connection table Network connection (unused)
function RmObjectStorageAdapter:onReadStream(streamId, _connection)
    -- Create spec table if not exists
    local spec = self[RmObjectStorageAdapter.SPEC_TABLE_NAME]
    if spec == nil then
        spec = { containerIds = {}, abstractObjectContainers = {} }
        self[RmObjectStorageAdapter.SPEC_TABLE_NAME] = spec
    end
    spec.containerIds = spec.containerIds or {}

    local count = streamReadUInt8(streamId)

    for _ = 1, count do
        local key = streamReadString(streamId)
        local containerId = streamReadString(streamId)
        spec.containerIds[key] = containerId

        -- Register entity→containerId mapping for display hooks
        if RmFreshManager and RmFreshManager.registerClientEntity then
            RmFreshManager:registerClientEntity(self, containerId)
        end
    end

    -- Phase 2: Receive expiring counts and soonest hours for HUD display
    local numObjectInfos = streamReadUInt8(streamId)
    local counts = {}
    for i = 1, numObjectInfos do
        counts[i] = {
            count = streamReadUInt8(streamId),
            soonestHours = streamReadUInt16(streamId),
        }
    end
    RmObjectStorageAdapter.clientExpiringCounts[self] = counts

    Log:trace("OBJECTSTORAGE_READ_STREAM: received %d containerIds, %d expiring counts", count, numObjectInfos)
end

-- =============================================================================
-- HUD EXPIRING DISPLAY
-- =============================================================================

--- Count items with near-expiry batches in an objectInfo and find soonest expiry
--- Server-only: uses abstractObjectContainers to find containers
---@param objectInfo table The objectInfo from spec_objectStorage.objectInfos
---@param placeable table The storage placeable
---@return number Count of items with expiring batches
---@return number Soonest expiry in hours (0 if none expiring)
function RmObjectStorageAdapter.countExpiringInObjectInfo(objectInfo, placeable)
    if placeable == nil then return 0, 0 end
    local spec = placeable[RmObjectStorageAdapter.SPEC_TABLE_NAME]
    if not spec or not spec.abstractObjectContainers then return 0, 0 end
    if not objectInfo or not objectInfo.objects then return 0, 0 end

    local daysPerPeriod = (g_currentMission and g_currentMission.environment
        and g_currentMission.environment.daysPerPeriod) or 1
    local warningHours = RmFreshSettings:getWarningHours()

    local count = 0
    local soonestHours = math.huge
    for _, abstractObject in ipairs(objectInfo.objects) do
        local containerId = spec.abstractObjectContainers[abstractObject]
        if containerId then
            local container = RmFreshManager:getContainer(containerId)
            if container and container.batches and #container.batches > 0 then
                local fillTypeIndex = container.fillTypeIndex
                if fillTypeIndex then
                    local config = RmFreshSettings:getThresholdByIndex(fillTypeIndex)
                    -- Check first batch (oldest in FIFO order)
                    if RmBatch.isNearExpiration(container.batches[1], warningHours, config.expiration, daysPerPeriod) then
                        count = count + 1
                        local remainingHours = (config.expiration - container.batches[1].ageInPeriods) * daysPerPeriod * 24
                        if remainingHours < soonestHours then
                            soonestHours = remainingHours
                        end
                    end
                end
            end
        end
    end

    return count, count > 0 and soonestHours or 0
end

--- Get expiring count and soonest hours for an objectInfo (MP-aware)
--- Server: calculates from batch data
--- Client: uses synced cache
---@param objectInfo table The objectInfo from spec_objectStorage.objectInfos
---@param placeable table The storage placeable
---@param objectInfoIndex number 1-based index in spec.objectInfos
---@return number Count of items with expiring batches
---@return number Soonest expiry in hours (0 if none expiring)
function RmObjectStorageAdapter.getExpiringCount(objectInfo, placeable, objectInfoIndex)
    -- Server/Host: calculate from actual batch data
    if g_server ~= nil then
        return RmObjectStorageAdapter.countExpiringInObjectInfo(objectInfo, placeable)
    end

    -- Client: use synced cache
    local placeableData = RmObjectStorageAdapter.clientExpiringCounts[placeable]
    if placeableData ~= nil then
        local entry = placeableData[objectInfoIndex]
        if entry ~= nil then
            return entry.count or 0, entry.soonestHours or 0
        end
    end

    return 0, 0
end

--- Show freshness status in placeable HUD info
--- Shows expiring item counts per objectInfo category
--- CRITICAL: Placeables use updateInfo(superFunc, infoTable), NOT showInfo!
---@param superFunc function Original updateInfo function
---@param infoTable table Info table to modify
function RmObjectStorageAdapter:updateInfo(superFunc, infoTable)
    local startIndex = #infoTable -- Track BEFORE super populates entries
    superFunc(self, infoTable)

    local spec = self[RmObjectStorageAdapter.SPEC_TABLE_NAME]
    if not spec then return end

    local specOS = self.spec_objectStorage
    if not specOS or not specOS.objectInfos then return end

    local maxEntries = PlaceableObjectStorage.MAX_HUD_INFO_ENTRIES or 10

    for i = 1, math.min(#specOS.objectInfos, maxEntries) do
        local objectInfo = specOS.objectInfos[i]
        local expiringCount, soonestHours = RmObjectStorageAdapter.getExpiringCount(objectInfo, self, i)

        if expiringCount > 0 then
            -- Entry index: startIndex + 1 (capacity line) + i (objectInfo position)
            local entryIndex = startIndex + 1 + i
            local entry = infoTable[entryIndex]

            if entry then
                -- Append expiring count + time suffix
                local timeStr = RmBatch.formatRemainingShort(soonestHours)
                local expiringText = string.format(g_i18n:getText("fresh_storage_expiring"),
                    expiringCount, timeStr)
                entry.text = entry.text .. " " .. expiringText
                -- Yellow highlighting for warning
                entry.accentuate = true

                Log:trace("HUD_EXPIRING: objectInfo[%d] = %d expiring, soonest=%s", i, expiringCount, timeStr)
            end
        end
    end
end

-- =============================================================================
-- FILL LEVEL MANIPULATION (for console commands)
-- =============================================================================

--- Get fill level for a container from abstractObject
---@param containerId string Container ID
---@return number fillLevel Current fill level
---@return number fillType Fill type index
function RmObjectStorageAdapter:getFillLevel(containerId)
    local container = RmFreshManager:getContainer(containerId)
    if not container then return 0, 0 end

    local abstractObject = container.runtimeEntity
    if not abstractObject then
        Log:trace("OBJECTSTORAGE_GET_FILL: %s no runtimeEntity", containerId)
        return 0, container.fillTypeIndex or 0
    end

    -- Get fillLevel from abstractObject (different structure for Bale vs Vehicle)
    local fillLevel = 0
    local className = abstractObject.REFERENCE_CLASS_NAME

    if className == "Bale" and abstractObject.baleAttributes then
        fillLevel = abstractObject.baleAttributes.fillLevel or 0
    elseif className == "Vehicle" and abstractObject.palletAttributes then
        fillLevel = abstractObject.palletAttributes.fillLevel or 0
    end

    return fillLevel, container.fillTypeIndex or 0
end

--- Add fill level for a container (modifies abstractObject's fillLevel)
--- Used by expiration to remove expired fill from stored objects
---@param containerId string Container ID
---@param delta number Amount to add (negative to remove)
---@return boolean success True if fill was modified
function RmObjectStorageAdapter:addFillLevel(containerId, delta)
    local container = RmFreshManager:getContainer(containerId)
    if not container then return false end

    local abstractObject = container.runtimeEntity
    if not abstractObject then
        Log:trace("OBJECTSTORAGE_ADD_FILL: %s no runtimeEntity", containerId)
        return false
    end

    -- Modify fillLevel in abstractObject (different structure for Bale vs Vehicle)
    local className = abstractObject.REFERENCE_CLASS_NAME
    local oldLevel = 0
    local newLevel = 0

    if className == "Bale" and abstractObject.baleAttributes then
        oldLevel = abstractObject.baleAttributes.fillLevel or 0
        newLevel = math.max(0, oldLevel + delta)
        abstractObject.baleAttributes.fillLevel = newLevel
    elseif className == "Vehicle" and abstractObject.palletAttributes then
        oldLevel = abstractObject.palletAttributes.fillLevel or 0
        newLevel = math.max(0, oldLevel + delta)
        abstractObject.palletAttributes.fillLevel = newLevel
    else
        Log:trace("OBJECTSTORAGE_ADD_FILL: %s unknown class %s", containerId, className or "nil")
        return false
    end

    Log:debug("OBJECTSTORAGE_ADD_FILL: %s %s %.1f -> %.1f (delta=%.1f)",
        containerId, className, oldLevel, newLevel, delta)
    return true
end

--- Set fill level for a container
---@param containerId string Container ID
---@param level number Target fill level
---@return boolean success True if fill was modified
function RmObjectStorageAdapter:setFillLevel(containerId, level)
    -- Stored objects can't have their fill modified directly
    Log:debug("OBJECTSTORAGE_SET_FILL: %s level=%.1f (not supported for stored objects)",
        containerId, level)
    return false
end

-- =============================================================================
-- MANAGER CALLBACK
-- =============================================================================

--- Handle empty container after expiration
--- Removes the abstractObject from the placeable's storedObjects array
---@param containerId string Container ID
function RmObjectStorageAdapter:onContainerEmpty(containerId)
    Log:debug("OBJECTSTORAGE_EMPTY: %s - removing expired stored object", containerId)

    local container = RmFreshManager:getContainer(containerId)
    if not container then
        Log:trace("OBJECTSTORAGE_EMPTY: container not found")
        return
    end

    local abstractObject = container.runtimeEntity
    if not abstractObject then
        Log:trace("OBJECTSTORAGE_EMPTY: no runtimeEntity")
        RmFreshManager:unregisterContainer(containerId)
        return
    end

    -- Find the placeable that owns this abstractObject and remove it
    -- Iterate placeables with spec_objectStorage
    local removed = false
    if g_currentMission and g_currentMission.placeableSystem then
        local placeables = g_currentMission.placeableSystem.placeables
        for _, placeable in ipairs(placeables or {}) do
            local specOS = placeable.spec_objectStorage
            if specOS and specOS.storedObjects then
                for i = #specOS.storedObjects, 1, -1 do
                    if specOS.storedObjects[i] == abstractObject then
                        -- Remove from storedObjects array
                        table.remove(specOS.storedObjects, i)
                        specOS.numStoredObjects = #specOS.storedObjects

                        -- Also remove from our tracking
                        local spec = placeable[RmObjectStorageAdapter.SPEC_TABLE_NAME]
                        if spec and spec.abstractObjectContainers then
                            spec.abstractObjectContainers[abstractObject] = nil
                        end

                        -- Trigger objectInfos rebuild
                        if placeable.setObjectStorageObjectInfosDirty then
                            placeable:setObjectStorageObjectInfosDirty()
                        end

                        Log:info("OBJECTSTORAGE_EXPIRED: removed %s from %s",
                            abstractObject.REFERENCE_CLASS_NAME or "object",
                            placeable:getName() or "placeable")
                        removed = true
                        break
                    end
                end
            end
            if removed then break end
        end
    end

    if not removed then
        Log:trace("OBJECTSTORAGE_EMPTY: abstractObject not found in any placeable")
    end

    -- Unregister the Fresh container
    RmFreshManager:unregisterContainer(containerId)
end

-- =============================================================================
-- OLDEST OUT FIRST - Sort stored objects by batch age
-- =============================================================================

--- Hook updateObjectStorageObjectInfos to sort objects by batch age after rebuild
--- Ensures oldest items (by batch age) exit first when user retrieves
---@param superFunc function Original function
function RmObjectStorageAdapter:updateObjectStorageObjectInfosHook(superFunc)
    -- Call original (rebuilds objectInfos from storedObjects)
    superFunc(self)

    -- Server only - clients receive sorted objectInfos via stream
    if not self.isServer then return end

    -- Sort each group by batch age (oldest first)
    RmObjectStorageAdapter.sortObjectInfosByAge(self)
end

--- Sort objectInfo.objects arrays by batch age (oldest at [1])
--- Game always spawns objectInfo.objects[1], so oldest will exit first
---@param placeable table The placeable
function RmObjectStorageAdapter.sortObjectInfosByAge(placeable)
    local specOS = placeable.spec_objectStorage
    local ourSpec = placeable[RmObjectStorageAdapter.SPEC_TABLE_NAME]

    if not specOS or not specOS.objectInfos or not ourSpec then return end

    local sortedCount = 0

    for _, objectInfo in ipairs(specOS.objectInfos) do
        if objectInfo.objects and #objectInfo.objects > 1 then
            -- Sort by age descending (oldest/highest age at [1])
            table.sort(objectInfo.objects, function(a, b)
                local ageA = RmObjectStorageAdapter.getOldestBatchAge(ourSpec, a)
                local ageB = RmObjectStorageAdapter.getOldestBatchAge(ourSpec, b)
                return ageA > ageB -- Oldest first
            end)
            sortedCount = sortedCount + 1
        end
    end

    if sortedCount > 0 then
        Log:trace("OBJECTSTORAGE_SORT: sorted %d groups by batch age (oldest first)", sortedCount)
    end
end

--- Get oldest batch age for an abstractObject
--- Returns -1 for unknown/untracked items (they go to end of queue)
---@param ourSpec table Our spec table with abstractObjectContainers
---@param abstractObject table The abstract stored object
---@return number ageInPeriods Oldest batch age, or -1 if not tracked
function RmObjectStorageAdapter.getOldestBatchAge(ourSpec, abstractObject)
    if not ourSpec or not ourSpec.abstractObjectContainers then
        return -1
    end

    local containerId = ourSpec.abstractObjectContainers[abstractObject]
    if not containerId then
        return -1 -- Not tracked by Fresh
    end

    local container = RmFreshManager:getContainer(containerId)
    if not container or not container.batches or #container.batches == 0 then
        return -1 -- No batches
    end

    -- First batch = oldest (FIFO order)
    return container.batches[1].ageInPeriods or 0
end

-- =============================================================================
-- MP RUNTIME SYNC - Broadcast expiring counts
-- =============================================================================

--- Broadcast expiring counts for a single placeable to all clients
--- Server-only: calculates and sends expiring counts per objectInfo
---@param placeable table The placeable with object storage
function RmObjectStorageAdapter.broadcastExpiringCounts(placeable)
    if g_server == nil then return end

    local specOS = placeable.spec_objectStorage
    if not specOS or not specOS.objectInfos then return end

    -- Calculate expiring count and soonest hours per objectInfo
    local counts = {}
    for i, objectInfo in ipairs(specOS.objectInfos) do
        local count, soonestHours = RmObjectStorageAdapter.countExpiringInObjectInfo(objectInfo, placeable)
        if count > 0 then
            counts[i] = { count = count, soonestHours = soonestHours }
        end
    end

    -- Broadcast event to all clients
    g_server:broadcastEvent(RmStorageExpiringInfoEvent.new(placeable, counts))

    Log:trace("OBJECTSTORAGE_EXPIRING_BROADCAST: placeable=%s", placeable:getName() or "?")
end

--- Broadcast expiring counts for ALL placeables with object storage
--- Called after hourly aging to sync updated counts to clients
function RmObjectStorageAdapter.broadcastAllExpiringCounts()
    if g_server == nil then return end

    local placeableSystem = g_currentMission and g_currentMission.placeableSystem
    if not placeableSystem or not placeableSystem.placeables then return end

    local placeableCount = 0
    for _, placeable in pairs(placeableSystem.placeables) do
        local specOS = placeable.spec_objectStorage
        if specOS and specOS.storedObjects and #specOS.storedObjects > 0 then
            RmObjectStorageAdapter.broadcastExpiringCounts(placeable)
            placeableCount = placeableCount + 1
        end
    end

    if placeableCount > 0 then
        Log:debug("OBJECTSTORAGE_EXPIRING_BROADCAST_ALL: synced %d placeables", placeableCount)
    end
end

--- Hook for hourly aging - broadcast updated expiring counts
--- Installed at source time to ensure MP clients see updated counts
function RmObjectStorageAdapter.installHourlyBroadcastHook()
    if RmFreshManager == nil or RmFreshManager.processHourlyAging == nil then
        Log:warning("RmFreshManager.processHourlyAging not available - hourly broadcast disabled")
        return false
    end

    RmFreshManager.processHourlyAging = Utils.appendedFunction(
        RmFreshManager.processHourlyAging,
        function(_self)
            -- Broadcast updated expiring counts to clients after aging
            RmObjectStorageAdapter.broadcastAllExpiringCounts()
        end
    )

    Log:info("OBJECTSTORAGE_ADAPTER: Hourly broadcast hook installed")
    return true
end

-- Install hourly broadcast hook at source time
RmObjectStorageAdapter.installHourlyBroadcastHook()

-- =============================================================================
-- ADAPTER REGISTRATION
-- =============================================================================

RmFreshManager:registerAdapter(RmObjectStorageAdapter.ENTITY_TYPE, RmObjectStorageAdapter)

Log:info("OBJECTSTORAGE_ADAPTER: Specialization registered")
