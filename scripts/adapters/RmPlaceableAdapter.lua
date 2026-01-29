-- RmPlaceableAdapter.lua
-- Purpose: Thin placeable adapter - bridges FS25 placeable storage events to centralized FreshManager
-- Author: Ritter
-- CRITICAL: Must stay under 150 lines (core skeleton) to validate thin adapter architecture
-- Note: Storage discovery, fill callbacks, and display logic added in subsequent stories (25-2 to 25-6)

RmPlaceableAdapter = {}
RmPlaceableAdapter.SPEC_TABLE_NAME = ("spec_%s.rmPlaceableAdapter"):format(g_currentModName)
RmPlaceableAdapter.ENTITY_TYPE = "placeable"

local Log = RmLogging.getLogger("Fresh")

-- =============================================================================
-- IDENTITY
-- =============================================================================

--- Get entity ID for a placeable
---@param placeable table Placeable entity
---@return string uniqueId FS25's stable uniqueId
function RmPlaceableAdapter:getEntityId(placeable)
    return placeable.uniqueId -- FS25's stable uniqueId
end

--- Build identity structure for a placeable storage
--- Called during registration to create identityMatch for Manager
---@param placeable table Placeable entity
---@param storage table Storage object (from spec_silo.storages[], etc.)
---@param fillTypeName string Fill type name (string, not index)
---@param fillLevel number|nil Current fill level (optional)
---@return table identityMatch structure for registerContainer
function RmPlaceableAdapter:buildIdentityMatch(placeable, storage, fillTypeName, fillLevel)
    Log:trace("BUILD_IDENTITY: placeable=%s fillType=%s amount=%.1f",
        placeable.uniqueId or "?", fillTypeName or "?", fillLevel or 0)

    return {
        worldObject = {
            uniqueId = placeable.uniqueId,
        },
        storage = {
            fillTypeName = fillTypeName,
            amount = fillLevel or 0,
            -- storageHint: For debugging only, NOT used for identity matching
        },
    }
end

-- =============================================================================
-- CAPABILITY DETECTION (Step 5)
-- =============================================================================

--- Detect player interaction capabilities for a container
--- Uses LoadingStation/UnloadingStation to determine if player/vehicles can
--- fill or empty a specific fillType from this placeable.
---
--- **Why this works:** Stations define which fillTypes they accept.
--- - UnloadingStation = player can UNLOAD INTO (fill) this fillType
--- - LoadingStation = player can LOAD FROM (empty) this fillType
---
--- Example: Cow barn's UnloadingStation accepts HAY, STRAW, TMR but NOT MILK.
---          Cow barn's LoadingStation accepts MILK but NOT HAY/STRAW/TMR.
---
---@param placeable table Placeable entity
---@param fillTypeIndex number Fill type index to check
---@return boolean playerCanFill Can player/vehicles ADD to this container?
---@return boolean playerCanEmpty Can player/vehicles REMOVE from this container?
function RmPlaceableAdapter.detectCapabilities(placeable, fillTypeIndex)
    Log:trace(">>> detectCapabilities(placeable=%s, fillType=%d)",
        placeable and placeable.uniqueId or "nil", fillTypeIndex or 0)

    local playerCanFill = false
    local playerCanEmpty = false

    if not placeable or not fillTypeIndex then
        Log:trace("<<< detectCapabilities (nil input) = false, false")
        return false, false
    end

    -- spec_silo (silos, grain storage)
    if placeable.spec_silo then
        local s = placeable.spec_silo
        if s.unloadingStation and s.unloadingStation.getIsFillTypeSupported
            and s.unloadingStation:getIsFillTypeSupported(fillTypeIndex) then
            playerCanFill = true
            Log:trace("    spec_silo.unloadingStation supports fillType → playerCanFill=true")
        end
        if s.loadingStation and s.loadingStation.getIsFillTypeSupported
            and s.loadingStation:getIsFillTypeSupported(fillTypeIndex) then
            playerCanEmpty = true
            Log:trace("    spec_silo.loadingStation supports fillType → playerCanEmpty=true")
        end
    end

    -- spec_siloExtension (silo extensions share station with parent)
    -- Note: SiloExtension uses parent's stations, handled via spec_silo above
    -- if placed, they register via spec_silo anyway

    -- spec_husbandry (animal buildings - cow barn, pig pen, etc.)
    if placeable.spec_husbandry then
        local s = placeable.spec_husbandry
        if s.unloadingStation and s.unloadingStation.getIsFillTypeSupported
            and s.unloadingStation:getIsFillTypeSupported(fillTypeIndex) then
            playerCanFill = true
            Log:trace("    spec_husbandry.unloadingStation supports fillType → playerCanFill=true")
        end
        if s.loadingStation and s.loadingStation.getIsFillTypeSupported
            and s.loadingStation:getIsFillTypeSupported(fillTypeIndex) then
            playerCanEmpty = true
            Log:trace("    spec_husbandry.loadingStation supports fillType → playerCanEmpty=true")
        end
    end

    -- spec_productionPoint (mills, BGA, dairy, etc.) - NESTED path!
    if placeable.spec_productionPoint and placeable.spec_productionPoint.productionPoint then
        local pp = placeable.spec_productionPoint.productionPoint
        if pp.unloadingStation and pp.unloadingStation.getIsFillTypeSupported
            and pp.unloadingStation:getIsFillTypeSupported(fillTypeIndex) then
            playerCanFill = true
            Log:trace("    spec_productionPoint.unloadingStation supports fillType → playerCanFill=true")
        end
        if pp.loadingStation and pp.loadingStation.getIsFillTypeSupported
            and pp.loadingStation:getIsFillTypeSupported(fillTypeIndex) then
            playerCanEmpty = true
            Log:trace("    spec_productionPoint.loadingStation supports fillType → playerCanEmpty=true")
        end
    end

    -- spec_factory (greenhouses, etc.)
    -- Factory has NO LoadingStation/UnloadingStation - production output only
    -- Both capabilities remain false → production output behavior (always fresh)

    -- =========================================================================
    -- OVERRIDES: Correct station-based detection for specific cases
    -- The station API returns true for ALL fillTypes in connected storage,
    -- but doesn't distinguish inputs from outputs. These overrides fix that.
    -- =========================================================================

    -- Override 1: Husbandry milk outputs (MILK, GOATMILK, BUFFALOMILK)
    -- Milk is animal production output - players can't fill it, but can collect
    if placeable.spec_husbandryMilk and placeable.spec_husbandryMilk.fillTypes then
        for _, milkFillType in ipairs(placeable.spec_husbandryMilk.fillTypes) do
            if milkFillType == fillTypeIndex then
                playerCanFill = false
                playerCanEmpty = true -- Can collect milk via LoadingStation
                Log:trace("    spec_husbandryMilk override → playerCanFill=false (production output)")
                break
            end
        end
    end

    -- Override 2: Husbandry straw input (bedding)
    -- Straw is a bedding input - players can tip it in, but can't bulk-load it out
    if placeable.spec_husbandryStraw and placeable.spec_husbandryStraw.inputFillType then
        if fillTypeIndex == placeable.spec_husbandryStraw.inputFillType then
            playerCanFill = true   -- Can tip straw via UnloadingStation
            playerCanEmpty = false -- Can't bulk-load straw out (consumed for bedding)
            Log:trace("    spec_husbandryStraw override → playerCanEmpty=false (bedding input)")
        end
    end

    -- Override 3: Production point PURE outputs (not also inputs)
    -- Some fillTypes are both input AND output (e.g., SILAGE in cow food production)
    -- Only set playerCanFill=false for fillTypes that are ONLY outputs, not also inputs
    -- Reference: FS25_InfoDisplayExtension logic for input/output/both classification
    if placeable.spec_productionPoint and placeable.spec_productionPoint.productionPoint then
        local pp = placeable.spec_productionPoint.productionPoint
        if pp.productions then
            -- Step 1: Build set of all input fillTypes across all productions
            local inputFillTypes = {}
            for _, production in pairs(pp.productions) do
                if production.inputs then
                    for _, input in pairs(production.inputs) do
                        if input.type then
                            inputFillTypes[input.type] = true
                        end
                    end
                end
            end

            -- Step 2: Check if this fillType is a PURE output (in outputs but NOT in inputs)
            local isPureOutput = false
            for _, production in pairs(pp.productions) do
                if production.outputs then
                    for _, output in pairs(production.outputs) do
                        if output.type == fillTypeIndex then
                            -- Found in outputs - check if also in inputs
                            if not inputFillTypes[fillTypeIndex] then
                                isPureOutput = true
                                Log:trace("    fillType %d is PURE output (not in inputs)", fillTypeIndex)
                            else
                                Log:trace("    fillType %d is BOTH input AND output → keeping playerCanFill",
                                    fillTypeIndex)
                            end
                            break
                        end
                    end
                end
                if isPureOutput then break end
            end

            if isPureOutput then
                playerCanFill = false
                -- playerCanEmpty: keep station-based result (may be bulk output or pallet)
                Log:trace("    spec_productionPoint PURE output override → playerCanFill=false")
            end
        end
    end

    Log:trace("<<< detectCapabilities = playerCanFill=%s, playerCanEmpty=%s",
        tostring(playerCanFill), tostring(playerCanEmpty))
    Log:debug("CAPABILITY_DETECT: placeable=%s fillType=%d playerCanFill=%s playerCanEmpty=%s",
        placeable.uniqueId or "?", fillTypeIndex, tostring(playerCanFill), tostring(playerCanEmpty))

    return playerCanFill, playerCanEmpty
end

-- =============================================================================
-- STORAGE DISCOVERY
-- =============================================================================

--- Discover all Storage objects in a placeable
--- Pattern credit: TSStockCheck by Time Wasting Productions
---@param placeable table Placeable entity
---@return table Array of { storage, sourceSpec } objects
function RmPlaceableAdapter.discoverStorages(placeable)
    -- Defensive: nil placeable guard
    if placeable == nil then
        Log:trace(">>> discoverStorages(placeable=nil) - returning empty")
        return {}
    end

    Log:trace(">>> discoverStorages(placeable=%s)", placeable:getName() or "unknown")

    local storages = {}

    -- Silo: ARRAY of storages (multiple bins in one silo placeable)
    if placeable.spec_silo ~= nil and placeable.spec_silo.storages ~= nil then
        for _, storage in ipairs(placeable.spec_silo.storages) do
            if storage ~= nil then
                table.insert(storages, { storage = storage, sourceSpec = "silo" })
                Log:trace("    found storage from spec_silo.storages")
            end
        end
    end

    -- SiloExtension: single storage (separate placeable, own uniqueId)
    if placeable.spec_siloExtension ~= nil and placeable.spec_siloExtension.storage ~= nil then
        table.insert(storages, {
            storage = placeable.spec_siloExtension.storage,
            sourceSpec = "siloExtension"
        })
        Log:trace("    found storage from spec_siloExtension")
    end

    -- Husbandry: animal buildings (PlaceableHusbandry.lua uses Storage.new())
    -- NOTE: This is for general husbandry storage, NOT food - food is handled by HusbandryFoodAdapter
    if placeable.spec_husbandry ~= nil and placeable.spec_husbandry.storage ~= nil then
        table.insert(storages, {
            storage = placeable.spec_husbandry.storage,
            sourceSpec = "husbandry"
        })
        Log:trace("    found storage from spec_husbandry")
    end

    -- Factory: greenhouses, carpentry, etc. (PlaceableFactory.lua uses Storage.new())
    if placeable.spec_factory ~= nil and placeable.spec_factory.storage ~= nil then
        table.insert(storages, {
            storage = placeable.spec_factory.storage,
            sourceSpec = "factory"
        })
        Log:trace("    found storage from spec_factory")
    end

    -- ProductionPoint: mills, BGA, etc. (ProductionPoint.lua uses Storage class)
    -- NOTE: Triple-nested path requires explicit nil checks at each level
    if placeable.spec_productionPoint ~= nil and
        placeable.spec_productionPoint.productionPoint ~= nil and
        placeable.spec_productionPoint.productionPoint.storage ~= nil then
        table.insert(storages, {
            storage = placeable.spec_productionPoint.productionPoint.storage,
            sourceSpec = "productionPoint"
        })
        Log:trace("    found storage from spec_productionPoint")
    end

    Log:trace("<<< discoverStorages = %d storages", #storages)
    Log:debug("PLACEABLE_STORAGE_FOUND: %s found %d storages", placeable:getName() or "unknown", #storages)

    return storages
end

-- =============================================================================
-- FILL LEVEL MANIPULATION (for console commands)
-- =============================================================================

--- Get fill level for a container by containerId
---@param containerId string Container ID
---@return number fillLevel Current fill level
---@return number fillType Fill type index
function RmPlaceableAdapter:getFillLevel(containerId)
    Log:trace(">>> getFillLevel(containerId=%s)", containerId or "nil")

    local container = RmFreshManager:getContainer(containerId)
    if not container then
        Log:trace("<<< getFillLevel (no container)")
        return 0, 0
    end

    local placeable = container.runtimeEntity
    if not placeable then
        Log:trace("<<< getFillLevel (no runtimeEntity)")
        return 0, 0
    end

    local spec = placeable[RmPlaceableAdapter.SPEC_TABLE_NAME]
    if not spec or not spec.storageRefs then
        Log:trace("<<< getFillLevel (no spec/storageRefs)")
        return 0, 0
    end

    local storage = spec.storageRefs[containerId]
    if not storage then
        Log:trace("<<< getFillLevel (no storage ref)")
        return 0, 0
    end

    local fillTypeIndex = container.fillTypeIndex
    if not fillTypeIndex then
        Log:trace("<<< getFillLevel (no fillTypeIndex)")
        return 0, 0
    end

    local fillLevel = storage:getFillLevel(fillTypeIndex) or 0

    Log:trace("<<< getFillLevel = %.1f, fillType=%d", fillLevel, fillTypeIndex)
    return fillLevel, fillTypeIndex
end

--- Add fill level for a container by containerId
---@param containerId string Container ID
---@param delta number Amount to add (negative to remove)
---@return boolean success True if fill was modified
function RmPlaceableAdapter:addFillLevel(containerId, delta)
    Log:trace(">>> addFillLevel(containerId=%s, delta=%.1f)", containerId or "nil", delta or 0)

    local container = RmFreshManager:getContainer(containerId)
    if not container then
        Log:trace("<<< addFillLevel (no container)")
        return false
    end

    local placeable = container.runtimeEntity
    if not placeable then
        Log:trace("<<< addFillLevel (no runtimeEntity)")
        return false
    end

    local spec = placeable[RmPlaceableAdapter.SPEC_TABLE_NAME]
    if not spec or not spec.storageRefs then
        Log:trace("<<< addFillLevel (no spec/storageRefs)")
        return false
    end

    local storage = spec.storageRefs[containerId]
    if not storage then
        Log:trace("<<< addFillLevel (no storage ref)")
        return false
    end

    local fillTypeIndex = container.fillTypeIndex
    if not fillTypeIndex then
        Log:trace("<<< addFillLevel (no fillTypeIndex)")
        return false
    end

    local fillTypeName = g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex)
    local currentLevel = storage:getFillLevel(fillTypeIndex) or 0
    local newLevel = math.max(0, currentLevel + delta) -- Prevent negative

    storage:setFillLevel(newLevel, fillTypeIndex)

    -- DEBUG log for state change (per architecture-impl.md 12.5)
    Log:debug("PLACEABLE_FILL_SET: container=%s %.1f → %.1f %s",
        containerId, currentLevel, newLevel, fillTypeName or "?")

    Log:trace("<<< addFillLevel (success)")
    return true
end

--- Set fill level for a container by containerId
---@param containerId string Container ID
---@param level number Target fill level
---@return boolean success True if fill was modified
function RmPlaceableAdapter:setFillLevel(containerId, level)
    Log:trace(">>> setFillLevel(containerId=%s, level=%.1f)", containerId or "nil", level or 0)

    local currentFill, _ = self:getFillLevel(containerId)
    local delta = level - currentFill
    local success = self:addFillLevel(containerId, delta)

    Log:trace("<<< setFillLevel (delta=%.1f, success=%s)", delta, tostring(success))
    return success
end

-- =============================================================================
-- LOOKUP API
-- =============================================================================

--- Get containerId for a placeable storage and fillType
--- Used by TransferCoordinator to resolve destination containers
--- NOTE: Uses discoverStorages() to find placeable owning the storage
--- CRITICAL: PlaceableAdapter uses POOLED containers - one per (placeable, fillTypeName)
---           Multiple storages with same fillType share ONE container
--- SERVER-ONLY: This function iterates Manager.containers which is empty on clients
---@param storage table Storage object
---@param fillType number Fill type index
---@return string|nil containerId or nil if not found
function RmPlaceableAdapter:getContainerIdForStorage(storage, fillType)
    if not storage then
        Log:trace("PLACEABLE_LOOKUP: storage=nil -> nil")
        return nil
    end
    if not fillType then
        Log:trace("PLACEABLE_LOOKUP: fillType=nil -> nil")
        return nil
    end

    -- Client-side warning: Manager.containers is empty on clients
    if g_server == nil then
        Log:trace("PLACEABLE_LOOKUP: called on client (Manager.containers empty)")
    end

    local fillTypeName = g_fillTypeManager:getFillTypeNameByIndex(fillType)
    if not fillTypeName then
        Log:trace("PLACEABLE_LOOKUP: invalid fillType=%d -> nil", fillType)
        return nil
    end

    -- Track which placeables we've already checked (avoid duplicate discoverStorages calls)
    local checkedPlaceables = {}

    -- Search through placeable containers to find which placeable owns this storage
    -- Uses shouldProcessContainer for test isolation (review finding 25-8)
    for containerId, container in pairs(RmFreshManager.containers) do
        if container.entityType == "placeable" and RmFreshManager:shouldProcessContainer(containerId) then
            local placeable = container.runtimeEntity
            if placeable and not checkedPlaceables[placeable] then
                checkedPlaceables[placeable] = true

                -- Check ALL storages of this placeable (not just storageRefs)
                local storages = RmPlaceableAdapter.discoverStorages(placeable)
                for _, storageInfo in ipairs(storages) do
                    if storageInfo.storage == storage then
                        -- Found the placeable that owns this storage!
                        -- Return the POOLED container for this fillType
                        local spec = placeable[RmPlaceableAdapter.SPEC_TABLE_NAME]
                        if spec and spec.containerIds then
                            local cId = spec.containerIds[fillTypeName]
                            Log:trace("PLACEABLE_LOOKUP: storage=%s fillType=%s -> containerId=%s",
                                tostring(storage), fillTypeName, cId or "nil")
                            return cId
                        end
                    end
                end
            end
        end
    end

    Log:trace("PLACEABLE_LOOKUP: storage=%s fillType=%s -> nil (no match)",
        tostring(storage), fillTypeName)
    return nil
end

-- =============================================================================
-- FILL LEVEL CALLBACK
-- =============================================================================

--- Register fill level callback for a storage
--- Pattern: One callback per storage, handles all fillTypes in that storage
---@param placeable table Placeable entity
---@param spec table Adapter spec table
---@param storage table Storage object
function RmPlaceableAdapter.registerStorageCallback(placeable, spec, storage)
    -- Avoid duplicate registration
    if spec.registeredStorages[storage] then
        Log:trace("    callback already registered for this storage, skipping")
        return
    end

    -- Storage uses callback pattern: fillLevelChangedListeners
    -- Note: fillInfo, toolType, farmId available but unused in Fresh mod
    storage:addFillLevelChangedListeners(function(fillType, delta, _fillInfo, _toolType, _farmId)
        RmPlaceableAdapter.onStorageFillChanged(placeable, spec, storage, fillType, delta)
    end)

    spec.registeredStorages[storage] = true
    Log:debug("PLACEABLE_CALLBACK_REGISTERED: placeable=%s storage=%s",
        placeable:getName() or "unknown", tostring(storage))
end

--- Handle fill level change from storage callback
---@param placeable table Placeable entity
---@param spec table Adapter spec table
---@param storage table Storage object that changed
---@param fillTypeIndex number Fill type index
---@param delta number Fill level change (positive = add, negative = remove)
function RmPlaceableAdapter.onStorageFillChanged(placeable, spec, storage, fillTypeIndex, delta)
    Log:trace(">>> onStorageFillChanged(placeable=%s, fillType=%d, delta=%.1f)",
        placeable:getName() or "?", fillTypeIndex or 0, delta or 0)

    if not placeable.isServer then
        Log:trace("<<< onStorageFillChanged (client, skipping)")
        return
    end
    if delta == 0 then
        Log:trace("<<< onStorageFillChanged (delta=0, skipping)")
        return
    end

    local fillTypeName = g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex)
    local containerId = spec.containerIds[fillTypeName]

    -- Dynamic registration: new perishable fill type being added
    if containerId == nil and delta > 0 and RmFreshSettings:isPerishableByIndex(fillTypeIndex) then
        local fillLevel = storage:getFillLevel(fillTypeIndex)
        local identityMatch = RmPlaceableAdapter:buildIdentityMatch(
            placeable, storage, fillTypeName, fillLevel
        )

        -- Step 5: Detect capabilities for dynamic registration
        local playerCanFill, playerCanEmpty = RmPlaceableAdapter.detectCapabilities(
            placeable, fillTypeIndex
        )

        local wasReconciled
        containerId, wasReconciled = RmFreshManager:registerContainer(
            "placeable", identityMatch, placeable,
            {
                location = placeable:getName() or "Silo",
                playerCanFill = playerCanFill,
                playerCanEmpty = playerCanEmpty
            }
        )

        spec.containerIds[fillTypeName] = containerId
        if containerId then
            spec.storageRefs[containerId] = storage
        end

        if wasReconciled then
            Log:debug("PLACEABLE_RECONCILED: fillType=%s containerId=%s (skipping delta)",
                fillTypeName, containerId or "nil")
            Log:trace("<<< onStorageFillChanged (reconciled)")
            return
        end

        Log:debug("PLACEABLE_DYNAMIC_REG: fillType=%s containerId=%s",
            fillTypeName, containerId or "nil")
    end

    if containerId then
        -- fillUnitIndex=1 for placeables (single fillType per container)
        RmFreshManager:onFillChanged(containerId, 1, delta, fillTypeIndex)
        Log:debug("PLACEABLE_FILL_CHANGED: container=%s delta=%+.1f fillType=%s",
            containerId, delta, fillTypeName or "?")
    end

    Log:trace("<<< onStorageFillChanged")
end

-- =============================================================================
-- CONTAINER REGISTRATION
-- =============================================================================

--- Polling timeout for deferred registration: 10 seconds (600 frames at 60fps)
local DEFER_TIMEOUT_MS = 10000

--- Register containers for all perishable fill types in a storage
--- One container per (placeable, fillTypeName) pair - NOT per storage
--- Step 3: Register ALL supported perishable fillTypes,
--- not just ones with fill > 0. Ensures container exists before first fill.
---@param placeable table Placeable entity
---@param spec table Adapter spec table
---@param storage table Storage object
---@return number registered Count of containers registered
function RmPlaceableAdapter.registerStorageContents(placeable, spec, storage)
    Log:trace(">>> registerStorageContents(storage=%s, placeable=%s)",
        tostring(storage), placeable:getName() or "unknown")

    local registered = 0

    -- Step 3 fix: Iterate ALL supported fillTypes, not just ones with fill
    -- This ensures containers exist for production outputs (e.g., milk) before first fill
    local supportedFillTypes = storage:getSupportedFillTypes() or {}

    for fillTypeIndex, _ in pairs(supportedFillTypes) do
        local fillTypeName = g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex)
        local isPerishable = RmFreshSettings:isPerishableByIndex(fillTypeIndex)
        local fillLevel = storage:getFillLevel(fillTypeIndex) or 0

        Log:trace("    checking fillType=%s level=%.1f isPerishable=%s",
            fillTypeName or "?", fillLevel, tostring(isPerishable))

        -- Step 3: Register if perishable (regardless of fillLevel)
        if isPerishable then
            local alreadyRegistered = spec.containerIds[fillTypeName] ~= nil
            Log:trace("    alreadyRegistered=%s", tostring(alreadyRegistered))

            if not alreadyRegistered then
                local identityMatch = RmPlaceableAdapter:buildIdentityMatch(
                    placeable, storage, fillTypeName, fillLevel
                )

                -- Step 5: Detect capabilities from LoadingStation/UnloadingStation
                local playerCanFill, playerCanEmpty = RmPlaceableAdapter.detectCapabilities(
                    placeable, fillTypeIndex
                )

                local containerId, wasReconciled = RmFreshManager:registerContainer(
                    "placeable", identityMatch, placeable,
                    {
                        location = placeable:getName() or "Silo",
                        playerCanFill = playerCanFill,
                        playerCanEmpty = playerCanEmpty
                    }
                )

                spec.containerIds[fillTypeName] = containerId
                if containerId then
                    spec.storageRefs[containerId] = storage
                end
                registered = registered + 1

                Log:trace("    wasReconciled=%s (skipAddBatch=%s)",
                    tostring(wasReconciled), tostring(wasReconciled))

                -- Add initial batch only for NEW containers with actual fill
                if not wasReconciled and containerId and fillLevel > 0 then
                    RmFreshManager:addBatch(containerId, fillLevel, 0)
                end

                -- Step 3: Log differently for empty vs filled registrations
                if fillLevel > 0 then
                    Log:debug("PLACEABLE_REGISTERED: fillType=%s containerId=%s reconciled=%s name=%s",
                        fillTypeName, containerId or "nil", tostring(wasReconciled), placeable:getName() or "unknown")
                else
                    Log:debug(
                        "PLACEABLE_REGISTERED_EMPTY: fillType=%s containerId=%s name=%s (pre-registered for production)",
                        fillTypeName, containerId or "nil", placeable:getName() or "unknown")
                end
            end
        end
    end

    -- Register fill level callback for this storage (once per storage)
    RmPlaceableAdapter.registerStorageCallback(placeable, spec, storage)

    Log:trace("<<< registerStorageContents registered=%d", registered)
    return registered
end

--- Rescan all placeables for newly-perishable storage fillTypes
--- Called when settings change makes a fillType perishable
---@return number count Number of new containers registered
function RmPlaceableAdapter.rescanForPerishables()
    if not g_currentMission or not g_currentMission.placeableSystem then return 0 end

    Log:trace(">>> RmPlaceableAdapter.rescanForPerishables()")
    local count = 0
    for _, placeable in ipairs(g_currentMission.placeableSystem.placeables) do
        local spec = placeable[RmPlaceableAdapter.SPEC_TABLE_NAME]
        if spec and spec.containerIds then
            local storages = RmPlaceableAdapter.discoverStorages(placeable)
            for _, storageInfo in ipairs(storages) do
                count = count + RmPlaceableAdapter.registerStorageContents(
                    placeable, spec, storageInfo.storage
                )
            end
        end
    end
    Log:trace("<<< RmPlaceableAdapter.rescanForPerishables = %d", count)
    return count
end

--- Defer registration until uniqueId is available (for purchased placeables)
--- Pattern from VehicleAdapter with timeout protection
---@param placeable table Placeable entity
function RmPlaceableAdapter.deferRegistration(placeable)
    Log:trace(">>> deferRegistration(placeable=%s)", placeable:getName() or "unknown")

    local spec = placeable[RmPlaceableAdapter.SPEC_TABLE_NAME]
    if spec.deferredRegistration then
        Log:trace("<<< deferRegistration (already scheduled)")
        return
    end

    spec.deferredRegistration = true
    Log:debug("PLACEABLE_DEFER: %s (uniqueId not yet assigned)", placeable:getName() or "unknown")

    local startTime = g_currentMission.time

    g_currentMission:addUpdateable({
        placeable = placeable,
        update = function(self, _dt)
            -- Guard: mission teardown (review finding: avoid accessing nil g_currentMission)
            if g_currentMission == nil then
                return -- Can't remove updateable, but will be cleaned up with mission
            end

            local p = self.placeable

            -- Success: uniqueId now available
            if p.uniqueId and p.uniqueId ~= "" then
                Log:trace("    deferred: uniqueId now available after %dms", g_currentMission.time - startTime)
                RmPlaceableAdapter.doRegistration(p, p.uniqueId)
                g_currentMission:removeUpdateable(self)
                return
            end

            -- Cancelled: placeable deleted before uniqueId assigned
            if p.isDeleted then
                Log:trace("    deferred: placeable deleted, cancelling")
                g_currentMission:removeUpdateable(self)
                return
            end

            -- Timeout: polling exhausted
            if (g_currentMission.time - startTime) > DEFER_TIMEOUT_MS then
                Log:warning("PLACEABLE_NO_UNIQUEID: %s failed to get uniqueId after %dms",
                    p:getName() or "unknown", DEFER_TIMEOUT_MS)
                g_currentMission:removeUpdateable(self)
                return
            end
        end
    })

    Log:trace("<<< deferRegistration (scheduled, timeout=%dms)", DEFER_TIMEOUT_MS)
end

--- Perform actual container registration after uniqueId is confirmed
---@param placeable table Placeable entity
---@param entityId string The placeable's uniqueId
function RmPlaceableAdapter.doRegistration(placeable, entityId)
    Log:trace(">>> doRegistration(placeable=%s, entityId=%s)",
        placeable:getName() or "?", entityId or "?")

    local spec = placeable[RmPlaceableAdapter.SPEC_TABLE_NAME]
    if spec == nil then
        Log:trace("<<< doRegistration (no spec table)")
        return
    end

    -- Check if already registered
    if next(spec.containerIds) ~= nil then
        Log:trace("<<< doRegistration (already registered)")
        return
    end

    Log:debug("PLACEABLE_LOAD: propertyState=%d uniqueId=%s name=%s",
        placeable:getPropertyState() or 0, entityId or "?", placeable:getName() or "unknown")

    local storages = RmPlaceableAdapter.discoverStorages(placeable)
    Log:trace("    discovered %d storages", #storages)

    if #storages == 0 then
        Log:trace("<<< doRegistration registered=0 (no storages)")
        return
    end

    local totalRegistered = 0
    for _, storageInfo in ipairs(storages) do
        local count = RmPlaceableAdapter.registerStorageContents(placeable, spec, storageInfo.storage)
        totalRegistered = totalRegistered + (count or 0)
    end

    Log:trace("<<< doRegistration registered=%d", totalRegistered)
end

-- =============================================================================
-- SPECIALIZATION SETUP
-- =============================================================================

--- Check if placeable has any storage-bearing specializations
--- Checks for: PlaceableSilo, PlaceableSiloExtension, PlaceableHusbandry, PlaceableFactory, PlaceableProductionPoint
---@param specializations table Specializations table
---@return boolean True if placeable has storage capabilities
function RmPlaceableAdapter.prerequisitesPresent(specializations)
    return SpecializationUtil.hasSpecialization(PlaceableSilo, specializations)
        or SpecializationUtil.hasSpecialization(PlaceableSiloExtension, specializations)
        or SpecializationUtil.hasSpecialization(PlaceableHusbandry, specializations)
        or SpecializationUtil.hasSpecialization(PlaceableFactory, specializations)
        or SpecializationUtil.hasSpecialization(PlaceableProductionPoint, specializations)
end

--- Register event listeners for placeable lifecycle and MP sync
---@param placeableType table Placeable type table
function RmPlaceableAdapter.registerEventListeners(placeableType)
    SpecializationUtil.registerEventListener(placeableType, "onLoad", RmPlaceableAdapter)
    SpecializationUtil.registerEventListener(placeableType, "onLoadFinished", RmPlaceableAdapter)
    SpecializationUtil.registerEventListener(placeableType, "onDelete", RmPlaceableAdapter)
    -- MP sync for client display
    SpecializationUtil.registerEventListener(placeableType, "onWriteStream", RmPlaceableAdapter)
    SpecializationUtil.registerEventListener(placeableType, "onReadStream", RmPlaceableAdapter)
end

--- Register overwritten functions for HUD display
--- CRITICAL: Placeables use updateInfo, NOT showInfo (different from vehicles!)
---@param placeableType table Placeable type table
function RmPlaceableAdapter.registerOverwrittenFunctions(placeableType)
    SpecializationUtil.registerOverwrittenFunction(placeableType, "updateInfo", RmPlaceableAdapter.updateInfo)
end

-- =============================================================================
-- LIFECYCLE HOOKS (Implemented in Stories 25-2, 25-3)
-- =============================================================================

--- Called when placeable loads
--- Creates spec table for container tracking
---@param _savegame table|nil Savegame data (unused, kept for FS25 API)
function RmPlaceableAdapter:onLoad(_savegame)
    -- Server only - clients receive container state via sync events
    if not self.isServer then return end

    -- Skip construction preview placeables (similar to vehicle shop preview)
    -- PlaceablePropertyState: NONE=1, OWNED=2, CONSTRUCTION_PREVIEW=3
    local propertyState = self:getPropertyState()
    if propertyState == PlaceablePropertyState.CONSTRUCTION_PREVIEW or
        propertyState == PlaceablePropertyState.NONE then
        Log:trace("PLACEABLE_SKIP_NON_OWNED: propertyState=%d name=%s",
            propertyState or 0, self:getName() or "unknown")
        return
    end

    -- Create spec table for container tracking
    -- containerIds: fillTypeName → containerId (one per fillType, not per storage)
    -- storageRefs: containerId → storage reference (for fill manipulation in 25-5)
    -- registeredStorages: storage → true (for callback deduplication in 25-4)
    self[RmPlaceableAdapter.SPEC_TABLE_NAME] = {
        containerIds = {},           -- fillTypeName → containerId
        storageRefs = {},            -- containerId → storage reference
        registeredStorages = {},     -- storage → true (for callback deduplication)
        deferredRegistration = false -- Prevent double scheduling
    }

    Log:trace("PLACEABLE_SPEC_INIT: propertyState=%d uniqueId=%s name=%s",
        propertyState or 0, self.uniqueId or "?", self:getName() or "unknown")
end

--- Called when placeable finishes loading
--- Registers containers for all perishable storage contents
---@param _savegame table|nil Savegame data (unused, kept for FS25 API)
function RmPlaceableAdapter:onLoadFinished(_savegame)
    Log:trace(">>> onLoadFinished(placeable=%s, savegame=%s)",
        self:getName() or "?", _savegame ~= nil and "loaded" or "nil")

    -- Server only - clients receive container state via sync events
    if not self.isServer then
        Log:trace("<<< onLoadFinished (client, skipping)")
        return
    end

    -- Skip construction preview placeables (similar to vehicle shop preview)
    local propertyState = self:getPropertyState()
    if propertyState == PlaceablePropertyState.CONSTRUCTION_PREVIEW or
        propertyState == PlaceablePropertyState.NONE then
        Log:trace("<<< onLoadFinished (preview/none, skipping)")
        return
    end

    if RmFreshManager == nil then
        Log:error("PLACEABLE_LOAD_FINISHED: RmFreshManager not available")
        Log:trace("<<< onLoadFinished (no manager)")
        return
    end

    local spec = self[RmPlaceableAdapter.SPEC_TABLE_NAME]
    if spec == nil then
        Log:trace("<<< onLoadFinished (no spec)")
        return
    end

    -- Check if uniqueId is available
    local entityId = self.uniqueId
    if entityId == nil or entityId == "" then
        -- Defer registration - uniqueId assigned after onLoadFinished for purchased placeables
        RmPlaceableAdapter.deferRegistration(self)
        Log:trace("<<< onLoadFinished (deferred)")
        return
    end

    -- Register immediately (savegame placeables have uniqueId at onLoadFinished)
    RmPlaceableAdapter.doRegistration(self, entityId)
    Log:trace("<<< onLoadFinished")
end

--- Called when placeable is deleted
--- Unregisters all containers for this placeable
function RmPlaceableAdapter:onDelete()
    -- Server only - clients don't register containers
    if not self.isServer then return end

    local spec = self[RmPlaceableAdapter.SPEC_TABLE_NAME]
    if spec == nil then return end

    local count = 0
    if spec.containerIds then
        for _, containerId in pairs(spec.containerIds) do
            if containerId and RmFreshManager then
                RmFreshManager:unregisterContainer(containerId)
                count = count + 1
            end
        end
    end

    Log:debug("PLACEABLE_DELETE: %s unregistering %d containers",
        self.uniqueId or "?", count)

    -- Clean up spec tables (FS25 pattern)
    spec.containerIds = nil
    spec.storageRefs = nil
    spec.registeredStorages = nil
end

-- =============================================================================
-- MP STREAM SYNC
-- =============================================================================

--- Sync containerIds to joining client
--- Sends (fillTypeName, containerId) pairs for display hooks on client
---@param streamId number Network stream ID
---@param _connection table Network connection (unused)
function RmPlaceableAdapter:onWriteStream(streamId, _connection)
    Log:trace(">>> onWriteStream(placeable=%s)", self.uniqueId or "?")

    local spec = self[RmPlaceableAdapter.SPEC_TABLE_NAME]
    local containerIds = spec and spec.containerIds or {}

    -- Count containers
    local count = 0
    for _ in pairs(containerIds) do count = count + 1 end

    streamWriteUInt8(streamId, count)

    for fillTypeName, containerId in pairs(containerIds) do
        streamWriteString(streamId, fillTypeName)
        streamWriteString(streamId, containerId)
    end

    Log:trace("<<< onWriteStream: sent %d containerIds", count)
end

--- Receive containerIds on client join
--- Receives (fillTypeName, containerId) pairs and registers with Manager for display
---@param streamId number Network stream ID
---@param _connection table Network connection (unused)
function RmPlaceableAdapter:onReadStream(streamId, _connection)
    Log:trace(">>> onReadStream(placeable=%s)", self.uniqueId or "?")

    -- Create minimal spec table if not exists (client may not have called onLoad)
    local spec = self[RmPlaceableAdapter.SPEC_TABLE_NAME]
    if spec == nil then
        spec = { containerIds = {} }
        self[RmPlaceableAdapter.SPEC_TABLE_NAME] = spec
    end
    spec.containerIds = spec.containerIds or {}

    local count = streamReadUInt8(streamId)

    for _ = 1, count do
        local fillTypeName = streamReadString(streamId)
        local containerId = streamReadString(streamId)
        spec.containerIds[fillTypeName] = containerId

        -- Register entity→containerId mapping for display hooks
        if RmFreshManager and RmFreshManager.registerClientEntity then
            RmFreshManager:registerClientEntity(self, containerId)
        end
    end

    Log:trace("<<< onReadStream: received %d containerIds", count)
end

-- =============================================================================
-- DISPLAY HOOK
-- =============================================================================

--- Show freshness status in placeable HUD info
--- CRITICAL: Placeables use updateInfo(superFunc, infoTable), NOT showInfo(superFunc, box)!
--- Pattern: Modify entries in infoTable AFTER superFunc populates them
---@param superFunc function Original updateInfo function
---@param infoTable table Info table to modify
function RmPlaceableAdapter:updateInfo(superFunc, infoTable)
    Log:trace(">>> updateInfo(placeable=%s)", self.uniqueId or "?")

    local startCount = #infoTable -- Track count BEFORE superFunc
    superFunc(self, infoTable)

    local spec = self[RmPlaceableAdapter.SPEC_TABLE_NAME]
    if spec == nil then
        Log:trace("<<< updateInfo (no spec)")
        return
    end
    if spec.containerIds == nil or next(spec.containerIds) == nil then
        Log:trace("<<< updateInfo (no containerIds)")
        return
    end

    -- Build expiring amounts and soonest expiry per fillType
    local daysPerPeriod = (g_currentMission and g_currentMission.environment
        and g_currentMission.environment.daysPerPeriod) or 1
    local warningHours = RmFreshSettings:getWarningHours()
    local expiringByFillType = {}  -- fillTypeIndex → { amount, soonestHours }
    local totalExpiring = 0

    for fillTypeName, containerId in pairs(spec.containerIds) do
        local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(fillTypeName)
        if fillTypeIndex then
            local batches = RmFreshManager:getBatches(containerId)
            local config = RmFreshSettings:getThresholdByIndex(fillTypeIndex)

            for _, batch in ipairs(batches or {}) do
                if batch.amount >= RmBatch.MIN_AMOUNT
                    and RmBatch.isNearExpiration(batch, warningHours, config.expiration, daysPerPeriod) then
                    local entry = expiringByFillType[fillTypeIndex]
                    if not entry then
                        entry = { amount = 0, soonestHours = math.huge }
                        expiringByFillType[fillTypeIndex] = entry
                    end
                    entry.amount = entry.amount + batch.amount
                    totalExpiring = totalExpiring + batch.amount
                    -- Track soonest expiry (oldest batch = lowest remaining hours)
                    local remainingHours = (config.expiration - batch.ageInPeriods) * daysPerPeriod * 24
                    if remainingHours < entry.soonestHours then
                        entry.soonestHours = remainingHours
                    end
                end
            end
        end
    end

    -- Only modify entries when there's something expiring
    if totalExpiring == 0 then
        Log:trace("<<< updateInfo (no expiring goods)")
        return
    end

    -- Modify existing entries (after startCount)
    for fillTypeIndex, expData in pairs(expiringByFillType) do
        if expData.amount > 0 then
            local fillTypeTitle = g_fillTypeManager:getFillTypeTitleByIndex(fillTypeIndex)

            for i = startCount + 1, #infoTable do
                local entry = infoTable[i]
                if entry and entry.title == fillTypeTitle then
                    local formattedVolume = g_i18n:formatVolume(expData.amount)
                    local timeStr = RmBatch.formatRemainingShort(expData.soonestHours)
                    local suffix = string.format(g_i18n:getText("fresh_storage_expiring_volume"),
                        formattedVolume, timeStr)
                    entry.text = entry.text .. " " .. suffix
                    entry.accentuate = true
                    break
                end
            end
        end
    end

    -- TRACE exit log with expiring summary
    local expiringCount = 0
    for _ in pairs(expiringByFillType) do expiringCount = expiringCount + 1 end
    Log:trace("<<< updateInfo: %d fillTypes with expiring goods", expiringCount)
end

-- =============================================================================
-- EMPTY CONTAINER CALLBACK (from Manager after expiration)
-- =============================================================================

--- Handle empty container after expiration
--- Placeables generally stay (unlike pallets) - just remove tracking
---@param containerId string Container ID
function RmPlaceableAdapter:onContainerEmpty(containerId)
    local container = RmFreshManager:getContainer(containerId)
    if not container then return end

    Log:debug("PLACEABLE_EMPTY: %s (container tracking removed, placeable kept)", containerId)

    -- Unregister from Manager - placeable stays
    RmFreshManager:unregisterContainer(containerId)
end

-- =============================================================================
-- ADAPTER REGISTRATION
-- =============================================================================

RmFreshManager:registerAdapter(RmPlaceableAdapter.ENTITY_TYPE, RmPlaceableAdapter)

Log:info("PLACEABLE_ADAPTER: Specialization registered")
