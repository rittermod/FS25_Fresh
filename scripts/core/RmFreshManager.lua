-- RmFreshManager.lua
-- Purpose: Central hub for perishable tracking - container registry and batch orchestration
-- Author: Ritter
-- Architecture: THE central hub - all batch data lives here (Single Source of Truth)
--
-- =============================================================================
-- CONTAINER TYPE DEFINITION (Identity Model)
-- =============================================================================
--
-- GRANULARITY: One container = one fillType (not one entity!)
-- A vehicle with WHEAT and BARLEY has TWO containers, not one.
--
-- Container = {
--     -- Identity (OUR stable ID)
--     id = "fresh_xxx",              -- Generated via Utils.getUniqueId
--     entityType = "vehicle",        -- Adapter type: vehicle|bale|placeable|husbandry|stored
--
--     -- identityMatch (PERSISTED for heuristic matching on load)
--     identityMatch = {
--         worldObject = {
--             uniqueId = "vehicle8fd6...",  -- FS25 entity uniqueId (IF available)
--             -- Other adapter-specific fields for matching
--         },
--         storage = {
--             fillTypeName = "WHEAT",        -- String (STABLE across mods)
--             fillUnitIndex = 1,             -- For heuristic matching on multi-storage
--             amount = 4000,                 -- For disambiguation if needed
--             -- Other content-specific fields for matching
--         },
--     },
--
--     -- Runtime (NOT persisted, nil after load until reconciled)
--     runtimeEntity = nil,           -- FS25 entity reference (set during reconciliation)
--     fillTypeIndex = nil,           -- Cached from fillTypeName at runtime
--
--     -- Data
--     batches = {},                  -- Flat batch array (oldest first, FIFO)
--     farmId = 1,                    -- Owner farm for notifications/access (not identity)
--     metadata = {},                 -- Adapter-specific data
-- }
--
-- RECONCILIATION FLOW:
-- 1. onLoad: Containers loaded into reconciliationPool (runtimeEntity = nil)
-- 2. Adapter registers: buildIdentityMatch() creates match criteria
-- 3. Manager finds match in pool using heuristic algorithm
-- 4. On match: Container moved to containers, runtimeEntity set
-- 5. After all adapters: Remaining pool entries are orphans (entity deleted)
-- =============================================================================
--
-- Container ID Scheme: Generated IDs decoupled from FS25 entity IDs
--   Format: fresh_{16-char-md5} (e.g., "fresh_a1b2c3d4e5f67890")
--   Generated via Utils.getUniqueId("fresh", containers, "fresh_", 16)

RmFreshManager = {}

-- Get logger (RmLogging loaded before this module in main.lua)
local Log = RmLogging.getLogger("Fresh")

-- =============================================================================
-- STATE
-- =============================================================================

--- Container registry - the SINGLE SOURCE OF TRUTH for all batch data
--- Structure: id → Container (see Container type definition in header)
--- Do NOT access directly from adapters - use API methods
--- NOTE: Populated by adapters calling registerContainer() during their load lifecycle
RmFreshManager.containers = {}

--- Reconciliation Pool - holds loaded containers awaiting entity match
--- Structure: id → Container (same as containers, but runtimeEntity = nil)
--- LIFECYCLE:
---   1. onLoad populates pool from savegame
---   2. Adapters call tryClaimContainer() during their registration
---   3. Matched containers move to containers, orphans remain in pool
---   4. After reconciliation period, orphans are either garbage collected or logged
--- NOTE: This replaces the old entityIdIndex approach with a heuristic matching system
RmFreshManager.reconciliationPool = {}

-- =============================================================================
-- RECONCILIATION API
-- =============================================================================
-- These functions define the adapter ↔ manager reconciliation contract.
-- Adapters call these when they find entities that might have persisted data.
--
-- CALL ORDER (expected):
--   1. Adapter loads entity (onLoad/onPostLoad)
--   2. Adapter builds identityMatch = { worldObject = {...}, storage = {...} }
--   3. Adapter calls Manager:tryClaimContainer(identityMatch, runtimeEntity)
--   4. Manager searches reconciliationPool for best match
--   5. If matched: Container moved to containers, runtimeEntity set, returns containerId
--   6. If not matched: Returns nil, adapter creates new container
-- =============================================================================

--- Check if two identityMatch structures represent the same entity/content
--- Uses uniqueId as definitive match when present, falls back to generic comparison
---
--- ALGORITHM:
--- 1. Validate structure (nil checks)
--- 2. If saved.worldObject.uniqueId exists → compare ONLY uniqueId (definitive shortcut)
--- 3. If no uniqueId → fall back to generic key-value comparison for worldObject
--- 4. Compare ALL storage fields (with amount tolerance)
---
--- TOLERANCE: storage.amount uses proximity tolerance (5% or 10 units minimum)
--- to handle float precision, transfer timing, and game state drift
---
---@param saved table identityMatch from saved container (reconciliationPool)
---@param current table identityMatch from registering adapter
---@return boolean true if match
function RmFreshManager:identityMatches(saved, current)
    -- 1.2: Validate structure - return false if nil or missing required sub-tables
    if saved == nil or current == nil then
        Log:trace("MATCH_FAIL: nil identityMatch (saved=%s current=%s)",
            tostring(saved ~= nil), tostring(current ~= nil))
        return false
    end
    if saved.worldObject == nil or current.worldObject == nil then
        Log:trace("MATCH_FAIL: nil worldObject (saved=%s current=%s)",
            tostring(saved.worldObject ~= nil), tostring(current.worldObject ~= nil))
        return false
    end
    if saved.storage == nil or current.storage == nil then
        Log:trace("MATCH_FAIL: nil storage (saved=%s current=%s)",
            tostring(saved.storage ~= nil), tostring(current.storage ~= nil))
        return false
    end

    -- 1.3 + 1.4: uniqueId shortcut - definitive outer anchor when present
    -- If saved has uniqueId, it's THE definitive identifier (skip other worldObject fields)
    if saved.worldObject.uniqueId ~= nil then
        if saved.worldObject.uniqueId ~= current.worldObject.uniqueId then
            Log:trace("MATCH_FAIL: worldObject.uniqueId mismatch saved=%s current=%s",
                tostring(saved.worldObject.uniqueId), tostring(current.worldObject.uniqueId))
            return false
        end
        -- uniqueId matched! Skip other worldObject fields, proceed to storage
        Log:trace("MATCH_OK: worldObject.uniqueId=%s (definitive shortcut)", saved.worldObject.uniqueId)
    else
        -- 1.5: No uniqueId (e.g., Object Storage) - fall back to generic field comparison
        -- All saved worldObject fields must exist and match in current
        for key, savedValue in pairs(saved.worldObject) do
            if current.worldObject[key] ~= savedValue then
                Log:trace("MATCH_FAIL: worldObject.%s mismatch saved=%s current=%s",
                    key, tostring(savedValue), tostring(current.worldObject[key]))
                return false
            end
        end
    end

    -- 1.6: Compare ALL storage fields (with special handling for amount)
    for key, savedValue in pairs(saved.storage) do
        local currentValue = current.storage[key]

        if key == "amount" then
            -- Amount uses proximity tolerance (5% or 10 units minimum)
            -- Handles: float precision, transfer timing, game state drift
            local diff = math.abs(savedValue - (currentValue or 0))
            local tolerance = math.max(savedValue * 0.05, 10)
            if diff > tolerance then
                Log:trace("MATCH_FAIL: storage.amount diff=%.1f > tolerance=%.1f saved=%d current=%d",
                    diff, tolerance, savedValue, currentValue or 0)
                return false
            end
        else
            -- All other storage fields: exact match required
            if currentValue ~= savedValue then
                Log:trace("MATCH_FAIL: storage.%s mismatch saved=%s current=%s",
                    key, tostring(savedValue), tostring(currentValue))
                return false
            end
        end
    end

    return true
end

--- Find a matching container in the reconciliation pool
--- Iterates pool searching for containers that match the given identity
---
--- ALGORITHM:
--- 1. Filter by entityType first (quick rejection)
--- 2. Call identityMatches() for full identity comparison
--- 3. Return first match (order not guaranteed in Lua table iteration)
---
---@param entityType string Adapter type: "vehicle" | "bale" | "placeable" | etc.
---@param identityMatch table Identity structure from adapter { worldObject, storage }
---@return string|nil containerId if found
---@return table|nil container if found
function RmFreshManager:findMatchingContainer(entityType, identityMatch)
    local poolSize = 0
    for _ in pairs(self.reconciliationPool) do poolSize = poolSize + 1 end
    Log:trace(">>> findMatchingContainer(entityType=%s, uniqueId=%s, fillTypeName=%s) pool_size=%d",
        entityType or "nil",
        identityMatch and identityMatch.worldObject and identityMatch.worldObject.uniqueId or "nil",
        identityMatch and identityMatch.storage and identityMatch.storage.fillTypeName or "nil",
        poolSize)

    for containerId, container in pairs(self.reconciliationPool) do
        -- 2.3: Filter by entityType first (quick rejection)
        if container.entityType == entityType then
            -- 2.4: Full identity comparison
            if self:identityMatches(container.identityMatch, identityMatch) then
                -- 2.5: DEBUG log on match found
                Log:debug("RECONCILE_MATCH: found %s for %s", containerId, entityType)
                Log:trace("<<< findMatchingContainer = %s (match found)", containerId)
                return containerId, container
            end
        end
    end
    -- 2.6: No match found
    Log:trace("<<< findMatchingContainer = nil (no match)")
    return nil, nil
end

--- Entity Reference Index - maps entity object references to container IDs
--- Structure: entityRefIndex[entity] = containerId
--- Used for display hooks where we need entity → containerId lookup
--- NETWORK SAFE: Uses direct object references (not uniqueId strings or integer node IDs)
--- - Server: entity is the actual game object
--- - Client: entity is resolved via NetworkUtil.readNodeObject() during sync
--- LIFECYCLE: Updated on register/unregister
RmFreshManager.entityRefIndex = {}

--- Statistics tracking for reporting and debugging
--- totalExpired: Cumulative count of expired batches (incremented during onHourChanged)
---   Type: number
--- expiredByFillType: Breakdown by fill type index (maps fillTypeIndex to count)
---   Type: table {fillTypeIndex → count}
---   Example: { [5] = 10, [7] = 5 } means 10 WHEAT (index 5), 5 BARLEY (index 7) expired
--- lossLog: Recent expiration events for debugging and player notifications
---   Type: array of { fillType=number, amount=number, container=string, timestamp=number }
---   @skeleton Currently not populated - will be filled in onHourChanged() when fully implemented
RmFreshManager.statistics = {
    totalExpired = 0,
    expiredByFillType = {},
    lossLog = {}
}

--- Transfer context for coordinating fill operations
--- active: Whether a transfer is in progress
--- Future: sourceContainer, sourceFillUnit, amount, fillType

--- Console mode flag: when true, onFillChanged skips automatic batch creation
--- Used by console commands that need to add batches with specific age values
--- The fill change hook would otherwise create a batch with age=0
RmFreshManager.suppressFillChangeBatch = false
RmFreshManager.transferContext = {
    active = false
}

--- Dirty containers for MP delta sync optimization
--- Contains container IDs that have changed since last sync
--- Future: Used by MP sync to send only changed containers
RmFreshManager.dirtyContainers = {}

--- Initialization flag to prevent double-subscription
--- CRITICAL: Prevents multiple HOUR_CHANGED subscriptions
RmFreshManager.initialized = false

--- Reconciliation finalized flag
--- Set to true after first HOUR_CHANGED when all adapters have had time to register
--- Prevents orphan processing until reconciliation window closes
RmFreshManager.reconciliationFinalized = false

--- Adapter registry - maps entityType to adapter module
--- Structure: entityType → adapter module (e.g., { vehicle = RmVehicleAdapter })
--- Used by console commands to call adapter-specific methods like adjustFillLevel()
--- Populated by adapters calling registerAdapter() during their source() load
RmFreshManager.adapters = {}

--- Test isolation prefix - when set, global operations only affect containers with matching prefix
--- Used by RmFreshTests to prevent test operations from affecting real player containers
--- Set to RmFreshTests.TEST_PREFIX during test runs, nil during normal operation
--- Affects: simulateHours(), forceExpireAll()
RmFreshManager.testContainerPrefix = nil

--- Transfer pending batches: containerId → { batches, timestamp }
--- Used by TransferCoordinator to stage batches before fill occurs
--- Adapters check this when fill increases to use transferred ages
RmFreshManager.transferPending = {}

--- Transfer pending by fillType: fillTypeIndex → { batches, timestamp }
--- FALLBACK for physics-based transfers (pallets, undetected discharge paths)
--- When Dischargeable.dischargeToObject isn't called, this catches the transfer
--- Source staging on negative delta, consumed on positive delta
RmFreshManager.transferPendingByFillType = {}

--- Pending correction: fillTypeIndex → { containerId, timestamp }
--- RETROACTIVE FIX for same-frame timing issue where dest +delta fires before source -delta
--- When fresh batch is created (no pending), record it here so source can correct the age
--- Corrects first-tick fresh batches with actual source age
RmFreshManager.pendingCorrection = {}

--- Bulk transfer state (nil when not active)
--- Used by ProductionChainManager:distributeGoods() hook
--- Tracks multiple ADD→REMOVE pairs within a single distribution cycle
--- Structure when active: { active = true, pending = { fillType → [{containerId, amount, batches, isAdd, matched}] } }
RmFreshManager.bulkTransfer = nil

-- =============================================================================
-- CONTAINER LIFECYCLE API
-- =============================================================================

--- Register a container in the Manager
--- Called by adapters during their load lifecycle (onLoad, onPostLoad, etc.)
--- Reconciles with reconciliationPool OR creates new container
---
--- SERVER ONLY - registration is server-authoritative
---
---@param entityType string Container type: "vehicle" | "bale" | "placeable" | "husbandry" | "stored"
---@param identityMatch table Identity structure { worldObject, storage } for matching
---@param runtimeEntity table|nil FS25 entity reference, nil for stored containers
---@param metadata table|nil Adapter-specific data, may include:
---                          - location: Display name
---                          - playerCanFill: Can player/vehicles ADD to this container? (Step 4)
---                          - playerCanEmpty: Can player/vehicles REMOVE from this container? (Step 4)
---@return string|nil containerId The generated or reconciled container ID, nil on error
function RmFreshManager:registerContainer(entityType, identityMatch, runtimeEntity, metadata)
    -- TRACE: Function entry for AI debugging
    Log:trace(">>> registerContainer(entityType=%s, hasIdentityMatch=%s, hasRuntimeEntity=%s)",
        tostring(entityType),
        tostring(identityMatch ~= nil),
        tostring(runtimeEntity ~= nil))

    -- Validate entityType
    local validTypes = { vehicle = true, bale = true, placeable = true, husbandryfood = true, stored = true }
    if not validTypes[entityType] then
        Log:warning("registerContainer: invalid entityType %q (valid: vehicle, bale, placeable, husbandryfood, stored)",
            tostring(entityType))
        return nil
    end

    -- Validate identityMatch structure
    if identityMatch == nil then
        Log:warning("registerContainer: identityMatch cannot be nil")
        return nil
    end
    if identityMatch.worldObject == nil then
        Log:warning("registerContainer: identityMatch.worldObject cannot be nil")
        return nil
    end
    if identityMatch.storage == nil then
        Log:warning("registerContainer: identityMatch.storage cannot be nil")
        return nil
    end
    if identityMatch.storage.fillTypeName == nil then
        Log:warning("registerContainer: identityMatch.storage.fillTypeName cannot be nil")
        return nil
    end

    -- Resolve fillTypeIndex from fillTypeName
    local fillTypeIndex = self:resolveFillTypeIndex(identityMatch.storage.fillTypeName)
    if fillTypeIndex == nil then
        Log:warning("registerContainer: unknown fillTypeName %q (mod not loaded?)",
            identityMatch.storage.fillTypeName)
        -- Continue anyway - container can exist with nil fillTypeIndex
    end

    -- Step 4: Extract capability flags from metadata
    -- These flags indicate whether player/vehicles can interact with this container
    -- Used by onFillChanged to decide whether to use fillType fallback
    local playerCanFill = metadata and metadata.playerCanFill
    local playerCanEmpty = metadata and metadata.playerCanEmpty

    -- TRACE: Log reconciliation search parameters
    local poolSize = 0
    for _ in pairs(self.reconciliationPool) do poolSize = poolSize + 1 end
    Log:trace("RECONCILE_SEARCH: entityType=%s pool_size=%d uniqueId=%s fillTypeName=%s",
        entityType,
        poolSize,
        identityMatch.worldObject.uniqueId or "nil",
        identityMatch.storage.fillTypeName)

    -- RECONCILIATION: Check if we have a matching container in the pool
    local matchedId, matchedContainer = self:findMatchingContainer(entityType, identityMatch)

    -- TRACE: Log reconciliation result
    Log:trace("RECONCILE_RESULT: matchedId=%s matchFound=%s",
        tostring(matchedId),
        tostring(matchedContainer ~= nil))

    if matchedContainer then
        -- RECONCILE: Move from pool to containers
        self.reconciliationPool[matchedId] = nil

        -- Update runtime fields (identity from runtime is authoritative - reflects current game state)
        matchedContainer.identityMatch = identityMatch -- Use current runtime identity (may have more fields)
        matchedContainer.runtimeEntity = runtimeEntity
        matchedContainer.fillTypeIndex = fillTypeIndex

        -- Step 4: Update capability flags on reconciliation
        -- Capabilities are derived from current placeable structure, not saved data
        matchedContainer.playerCanFill = playerCanFill
        matchedContainer.playerCanEmpty = playerCanEmpty

        -- Move to active containers
        self.containers[matchedId] = matchedContainer

        -- Update entityRefIndex
        if runtimeEntity ~= nil then
            self.entityRefIndex[runtimeEntity] = matchedId
            Log:debug("ENTITY_REF_ADD: runtimeEntity→%s", matchedId)
        end

        Log:debug("CONTAINER_REG: reconciled %s type=%s fillType=%s playerCanFill=%s playerCanEmpty=%s",
            matchedId, entityType, identityMatch.storage.fillTypeName,
            tostring(playerCanFill), tostring(playerCanEmpty))

        return matchedId, true -- wasReconciled = true
    end

    -- NEW CONTAINER: Generate unique container ID
    local containerId = Utils.getUniqueId("fresh", self.containers, "fresh_", 16)

    -- Get farmId from runtimeEntity if available, or from metadata (for stored containers)
    -- NOTE: farmId=0 means "spectator/no owner" - treat as invalid and fallback to metadata
    local farmId = nil
    if runtimeEntity ~= nil and runtimeEntity.getOwnerFarmId ~= nil then
        local entityFarmId = runtimeEntity:getOwnerFarmId()
        if entityFarmId and entityFarmId ~= 0 then
            farmId = entityFarmId
        end
    end
    -- Fallback to metadata.farmId if entity didn't provide valid farmId
    if farmId == nil and metadata ~= nil and metadata.farmId ~= nil then
        farmId = metadata.farmId
    end

    -- Create container structure
    self.containers[containerId] = {
        -- Identity
        id = containerId,
        entityType = entityType,

        -- identityMatch (persisted for matching on load)
        identityMatch = identityMatch,

        -- Runtime (not persisted)
        runtimeEntity = runtimeEntity,
        fillTypeIndex = fillTypeIndex,

        -- Data (flat batches at root)
        batches = {},
        farmId = farmId or 0,
        metadata = metadata or {},

        -- Step 4: Capability flags for transfer correlation
        -- nil = unknown (use normal fallback logic)
        -- true = player/vehicles CAN interact
        -- false = player/vehicles CANNOT interact (skip fallback)
        playerCanFill = playerCanFill,
        playerCanEmpty = playerCanEmpty,
    }

    -- TRACE: Log container creation details
    Log:trace("CONTAINER_CREATE: id=%s farmId=%d fillTypeIndex=%s batchCount=0 playerCanFill=%s playerCanEmpty=%s",
        containerId,
        farmId or 0,
        tostring(fillTypeIndex),
        tostring(playerCanFill),
        tostring(playerCanEmpty))

    -- Update entityRefIndex (for display hook lookups)
    if runtimeEntity ~= nil then
        self.entityRefIndex[runtimeEntity] = containerId
        Log:debug("ENTITY_REF_ADD: runtimeEntity→%s", containerId)
    end

    Log:debug("CONTAINER_REG: new %s type=%s fillType=%s playerCanFill=%s playerCanEmpty=%s",
        containerId, entityType, identityMatch.storage.fillTypeName,
        tostring(playerCanFill), tostring(playerCanEmpty))

    -- Broadcast new container to clients
    self:broadcastContainerUpdate(containerId, RmFreshUpdateEvent.OP_REGISTER, self.containers[containerId])

    return containerId, false -- wasReconciled = false
end

--- Unregister a container from the Manager
--- Called by adapters during delete/unload lifecycle
--- Removes container and all associated batch data
---@param containerId string Container ID to unregister
---@return nil
function RmFreshManager:unregisterContainer(containerId)
    local container = self.containers[containerId]
    if container ~= nil then
        -- Clean entityRefIndex
        if container.entity ~= nil then
            self.entityRefIndex[container.entity] = nil
            Log:trace("UNREG_ENTITY_REF: cleared entity ref → %s", containerId)
        end
        if container.runtimeEntity ~= nil then
            self.entityRefIndex[container.runtimeEntity] = nil
            Log:trace("UNREG_ENTITY_REF: cleared runtimeEntity ref → %s", containerId)
        end

        -- Broadcast unregister to clients before removing
        self:broadcastContainerUpdate(containerId, RmFreshUpdateEvent.OP_UNREGISTER, nil)

        -- Remove container
        self.containers[containerId] = nil

        -- Housekeeping: remove stale references
        self.dirtyContainers[containerId] = nil
        if self.transferContext.sourceContainer == containerId then
            self.transferContext.active = false
            self.transferContext.sourceContainer = nil
        end

        Log:debug("CONTAINER_UNREG: containerId=%s type=%s", containerId, container.entityType)
    end
end

--- Broadcast container update to all clients
--- SERVER ONLY - clients do not call this, they receive events from server
---@param containerId string Container ID
---@param operation number RmFreshUpdateEvent.OP_REGISTER | OP_UPDATE | OP_UNREGISTER
---@param data table|nil Container data (REGISTER), fillUnit data (UPDATE), or nil (UNREGISTER)
function RmFreshManager:broadcastContainerUpdate(containerId, operation, data)
    if g_server == nil then return end

    g_server:broadcastEvent(RmFreshUpdateEvent.new(containerId, operation, data))

    Log:trace("MP_BROADCAST: containerId=%s op=%d", containerId, operation)
end

--- Send full state to a joining client
--- SERVER ONLY - called when a new client connects
---@param connection table Network connection to the joining client
function RmFreshManager:sendFullStateToClient(connection)
    if g_server == nil then return end

    -- 1. Send settings FIRST (before container data)
    -- Client needs server's expiration thresholds for display calculations
    RmSettingsSyncEvent.sendToClient(connection)

    -- 2. Then send container data + loss log
    connection:sendEvent(RmFreshSyncEvent.new(self.containers, RmLossTracker.lossLog))

    Log:info("MP_FULL_SYNC: sent settings + %d containers + %d lossLog entries to client",
        self:getContainerCount(), #RmLossTracker.lossLog)
end

--- Get a container by ID
--- Returns nil if container not found (not an error - container may not be tracked)
---@param containerId string Container ID to look up
---@return table|nil Container entry or nil if not found
function RmFreshManager:getContainer(containerId)
    return self.containers[containerId]
end

--- Get all containers of a specific type
--- Used for operations like "age all vehicle batches" or console commands
---@param containerType string Container type to filter by: "vehicle" | "bale" | "placeable" | "husbandry" | "stored"
---@return table Array of container entries matching the type
function RmFreshManager:getContainersByType(containerType)
    local result = {}
    for _, container in pairs(self.containers) do
        if container.entityType == containerType then
            table.insert(result, container)
        end
    end
    return result
end

--- Get all containers in the registry
--- Returns the containers table directly (not a copy)
--- Used for iteration in console commands and save/load
---@return table The containers registry table (id → Container)
function RmFreshManager:getAllContainers()
    return self.containers
end

--- Get container ID by entity reference
--- NETWORK SAFE: Uses direct object reference lookup (not uniqueId or node ID)
--- Used by adapter display hooks to find container for an entity
--- Works on both server (direct entity) and client (NetworkUtil-resolved entity)
---@param entity table The entity object (Vehicle, Bale, etc.)
---@return string|nil Container ID or nil if entity not tracked
function RmFreshManager:getContainerIdByEntity(entity)
    if entity == nil then return nil end
    return self.entityRefIndex[entity]
end

--- Register entity→container mapping on client (MP sync)
--- Called by adapters when they receive containerId via their stream hooks
--- NETWORK SAFE: Establishes entity reference mapping on client for display hooks
--- This is the client-side counterpart to server's registerContainer()
---@param entity table The entity object (Vehicle, Bale, etc.)
---@param containerId string The container ID received from server
function RmFreshManager:registerClientEntity(entity, containerId)
    if entity == nil or containerId == nil or containerId == "" then
        Log:trace("CLIENT_ENTITY_REG: skipped (nil entity or containerId)")
        return
    end

    -- Update entityRefIndex for display hook lookups
    self.entityRefIndex[entity] = containerId

    -- Verify container exists (should have been synced via RmFreshSyncEvent)
    local container = self.containers[containerId]
    local hasContainer = container ~= nil

    Log:trace("CLIENT_ENTITY_REG: entity→%s containerExists=%s", containerId, tostring(hasContainer))
end

-- =============================================================================
-- LIFECYCLE FUNCTIONS
-- =============================================================================

--- Initialize the Manager
--- Subscribes to game events (HOUR_CHANGED for aging)
--- CRITICAL: Must be called from main.lua onLoadMapFinished() lifecycle
--- CRITICAL: Must only be called ONCE per session - uses initialized flag to prevent double-subscription
---@return nil
function RmFreshManager:initialize()
    if self.initialized then
        Log:warning("RmFreshManager already initialized - skipping")
        return
    end

    -- Subscribe to HOUR_CHANGED for hourly aging
    g_messageCenter:subscribe(MessageType.HOUR_CHANGED, self.onHourChanged, self)

    -- Subscribe to DAY_CHANGED for daily loss notifications (29-4)
    g_messageCenter:subscribe(MessageType.DAY_CHANGED, self.onDayChanged, self)

    self.initialized = true
    Log:info("RmFreshManager initialized")
end

--- Cleanup on map unload
--- Unsubscribes from events and resets state
function RmFreshManager:destroy()
    if not self.initialized then
        return
    end

    -- Unsubscribe from HOUR_CHANGED
    g_messageCenter:unsubscribe(MessageType.HOUR_CHANGED, self)

    -- Unsubscribe from DAY_CHANGED (29-4)
    g_messageCenter:unsubscribe(MessageType.DAY_CHANGED, self)

    -- Clear containers and indexes
    self.containers = {}
    self.reconciliationPool = {}
    self.entityRefIndex = {}

    -- Clear transfer pending tables
    self.transferPending = {}
    self.transferPendingByFillType = {}
    self.pendingCorrection = {}

    self.initialized = false
    self.reconciliationFinalized = false
    Log:info("RmFreshManager destroyed")
end

--- Finalize reconciliation after all adapters have had time to register
--- Called on first HOUR_CHANGED tick - orphan containers are logged and removed
--- SERVER ONLY - reconciliation is server-authoritative
---@return number orphanCount Number of containers removed from pool
function RmFreshManager:finalizeReconciliation()
    if g_server == nil then return 0 end

    local poolSize = 0
    for _ in pairs(self.reconciliationPool) do poolSize = poolSize + 1 end
    Log:trace(">>> finalizeReconciliation() pool_size=%d finalized=%s",
        poolSize, tostring(self.reconciliationFinalized))

    if self.reconciliationFinalized then
        Log:trace("<<< finalizeReconciliation = 0 (already finalized)")
        return 0 -- Already finalized
    end

    local orphanCount = 0
    local orphanIds = {}

    -- Log and collect orphans from reconciliationPool
    for containerId, container in pairs(self.reconciliationPool) do
        orphanCount = orphanCount + 1
        table.insert(orphanIds, containerId)

        -- Log orphan details for debugging
        local fillTypeName = container.identityMatch and
            container.identityMatch.storage and
            container.identityMatch.storage.fillTypeName or "unknown"
        Log:debug("ORPHAN: %s type=%s fillType=%s batches=%d (entity no longer exists)",
            containerId, container.entityType or "unknown", fillTypeName, #(container.batches or {}))
    end

    -- Clear the pool (orphans are discarded - entity no longer exists)
    self.reconciliationPool = {}

    -- Mark finalized
    self.reconciliationFinalized = true

    if orphanCount > 0 then
        Log:info("RECONCILE_FINALIZE: removed %d orphan containers (entities deleted since save)", orphanCount)
    else
        Log:debug("RECONCILE_FINALIZE: all containers reconciled successfully")
    end

    Log:trace("<<< finalizeReconciliation = %d", orphanCount)
    return orphanCount
end

--- Called every in-game hour
--- SERVER ONLY - processes aging, expirations, and triggers sync
--- CRITICAL: Server guard prevents client execution (clients receive state via sync events)
---@return nil
function RmFreshManager:onHourChanged()
    if g_server == nil then return end -- Server only - NEVER SKIP THIS

    -- Finalize reconciliation on first tick (adapters have had time to register)
    if not self.reconciliationFinalized then
        self:finalizeReconciliation()
    end

    -- Periodic reconciliation: fix drift from missed fill events (small amounts compound over time)
    local reconStats = self:reconcileAll()
    if reconStats.totalAdded > 0 or reconStats.totalRemoved > 0 then
        Log:info("HOURLY_RECONCILE: added=%.1f removed=%.1f", reconStats.totalAdded, reconStats.totalRemoved)
    end

    -- Check if expiration is enabled globally (AC #12)
    if not RmFreshSettings:isExpirationEnabled() then
        Log:trace("HOURLY_AGING: Skipped - expiration disabled")
        return
    end

    -- Process aging for all containers
    self:processHourlyAging()
end

--- Handle day change - delegate to LossTracker for notifications (29-4)
--- SERVER ONLY - notifications are sent from server
function RmFreshManager:onDayChanged()
    if not g_server then return end
    RmLossTracker:onDayChanged(self.containers)
end

--- Called during save game
--- Delegates to RmFreshIO for persistence of containers and statistics
--- CRITICAL: Called from main.lua saveToXMLFile hook
---@param savegameDir string Path to savegame directory
---@return nil
function RmFreshManager:onSave(savegameDir)
    Log:debug("SAVE: preparing %d containers for persistence", self:getContainerCount())

    -- Save main data file (containers, statistics)
    local success = RmFreshIO:save(savegameDir, self.containers, self.statistics, nil)
    if not success then
        Log:error("SAVE: Failed to save Fresh data")
    end

    -- Save log separately (can fail independently - log is optional)
    Log:debug("SAVE_LOG: RmLossTracker.lossLog has %d entries", #RmLossTracker.lossLog)
    RmFreshIO:saveLog(savegameDir, RmLossTracker.lossLog)

    -- Save user settings
    local settingsPath = savegameDir .. "/rm_FreshSettings.xml"
    local overrides = RmFreshSettings:getUserOverrides()
    RmFreshIO:saveSettings(settingsPath, overrides)
end

--- Called during load game
--- Delegates to RmFreshIO for loading, populates reconciliationPool
--- CRITICAL: Called from main.lua EARLY in loadMapFinished (before adapters)
--- NOTE: Adapters will claim containers from reconciliationPool during their load
---   Unclaimed containers become orphans (processed in finalizeReconciliation)
---@param savegameDir string Path to savegame directory
---@return nil
function RmFreshManager:onLoad(savegameDir)
    Log:debug("LOAD: restoring container data from savegame")

    -- Load user settings FIRST (before container data)
    local settingsPath = savegameDir .. "/rm_FreshSettings.xml"
    local settingsData = RmFreshIO:loadSettings(settingsPath)
    RmFreshSettings:setUserOverrides(settingsData)

    local data = RmFreshIO:load(savegameDir)
    if data then
        -- Load to reconciliationPool (NOT containers)
        -- Adapters will claim containers via registerContainer() → findMatchingContainer()
        self.reconciliationPool = data.reconciliationPool or {}

        -- Restore statistics
        self.statistics = data.statistics or self.statistics

        -- Load log separately (RmLossTracker owns the lossLog data)
        RmLossTracker.lossLog = RmFreshIO:loadLog(savegameDir)
        Log:debug("LOAD_LOG: RmLossTracker.lossLog now has %d entries", #RmLossTracker.lossLog)

        -- Reset reconciliation flag (will finalize on first HOUR_CHANGED)
        self.reconciliationFinalized = false

        -- Count pool size for logging
        local poolSize = 0
        for _ in pairs(self.reconciliationPool) do poolSize = poolSize + 1 end

        Log:info("LOAD: loaded %d containers to reconciliationPool (awaiting adapter claims)",
            poolSize)
    else
        Log:debug("LOAD: No Fresh save data found (new game or legacy format)")
    end
end

-- Entity reference index rebuilt via rebuildEntityRefIndex()

--- Rebuild entity reference index from loaded container data
--- Called on client after RmFreshSyncEvent to enable display lookups
--- Populates: entityRefIndex[entity] → containerId
---@return nil
function RmFreshManager:rebuildEntityRefIndex()
    local containerCount = self:getContainerCount()
    Log:trace(">>> rebuildEntityRefIndex() - processing %d containers", containerCount)

    self.entityRefIndex = {}
    local refCount = 0

    for containerId, container in pairs(self.containers) do
        -- Build entity reference index (for display hook lookups)
        if container.entity ~= nil then
            self.entityRefIndex[container.entity] = containerId
            refCount = refCount + 1
        end
        -- runtimeEntity is the current field name
        if container.runtimeEntity ~= nil then
            self.entityRefIndex[container.runtimeEntity] = containerId
            refCount = refCount + 1
        end
    end

    Log:debug("REBUILD_REF_INDEX: indexed %d containers by entity ref", refCount)
end

--- Validate containers - removes orphaned entries where entity/runtimeEntity is nil
--- CRITICAL TIMING: Must be called AFTER all adapters have had a chance to register
--- Adapters reconcile containers during their load lifecycle, setting entity reference
--- Containers that still have entity=nil after all adapters load are orphans (deleted from game)
--- Call this from main.lua AFTER loadMapFinished when all adapters have registered
--- Checks both entity (legacy) and runtimeEntity fields
---@return number Number of orphans removed
function RmFreshManager:validateContainers()
    local orphanCount = 0
    local orphanIds = {}

    -- Identify orphans: containers loaded from save but not reconciled by any adapter
    for containerId, container in pairs(self.containers) do
        -- Test isolation: only process test containers when in test mode
        if self:shouldProcessContainer(containerId) then
            -- Check both entity (legacy) and runtimeEntity
            local hasEntity = container.entity ~= nil or container.runtimeEntity ~= nil
            if not hasEntity then
                table.insert(orphanIds, containerId)
                orphanCount = orphanCount + 1
            end
        end
    end

    -- Remove orphans
    for _, containerId in ipairs(orphanIds) do
        local container = self.containers[containerId]
        Log:debug("VALIDATE_ORPHAN: removing containerId=%s (entity not found in game)",
            containerId)

        -- Remove container
        self.containers[containerId] = nil
    end

    if orphanCount > 0 then
        Log:info("VALIDATE: Removed %d orphaned containers (game objects no longer exist)", orphanCount)
    else
        Log:debug("VALIDATE: All %d containers reconciled successfully", self:getContainerCount())
    end

    return orphanCount
end

-- =============================================================================
-- BATCH OPERATIONS
-- =============================================================================

--- Add a batch to a container
--- Appends batch in FIFO order to container.batches
--- DEPENDENCY: Container must be registered first via registerContainer()
---@param containerId string Container ID
---@param amount number Batch amount
---@param ageInPeriods number|nil Initial age in periods (default 0)
---@param skipMerge boolean|nil Skip merge step (for batches awaiting correction)
---@return nil
function RmFreshManager:addBatch(containerId, amount, ageInPeriods, skipMerge)
    local container = self.containers[containerId]
    if not container then
        Log:error("addBatch: container not found: %s", containerId)
        return
    end

    -- Guard against invalid amounts (infinity, NaN, negative)
    if amount == math.huge or amount == -math.huge or amount ~= amount then
        Log:warning("BATCH_ADD_INVALID: container=%s amount=%s (skipping)", containerId, tostring(amount))
        return
    end
    if amount <= 0 then
        return -- Silent skip for zero/negative amounts
    end

    -- Create and add batch to flat array
    local batch = RmBatch.create(amount, ageInPeriods or 0)
    table.insert(container.batches, batch)

    -- Merge similar batches to prevent proliferation (unless skipped for pending correction)
    if not skipMerge then
        RmBatch.mergeSimilarBatches(container.batches, RmFreshSettings.MERGE_THRESHOLD)
    end

    -- Mark dirty for MP sync
    self.dirtyContainers[containerId] = true

    -- Broadcast update to clients (server only)
    self:broadcastContainerUpdate(containerId, RmFreshUpdateEvent.OP_UPDATE, {
        batches = container.batches
    })

    Log:debug("BATCH_ADD: container=%s amount=%.1f age=%.4f batches=%d",
        containerId, amount, ageInPeriods or 0, #container.batches)
end

--- Consume batches from a container in FIFO order
--- Returns consumed batches with their ages for transfer chain
--- SERVER ONLY - mutates batch data
---@param containerId string Container ID
---@param amount number Amount to consume
---@return table { consumed = number, batches = array of {amount, ageInPeriods} }
function RmFreshManager:consumeBatches(containerId, amount)
    if g_server == nil then
        return { consumed = 0, batches = {} }
    end

    local container = self.containers[containerId]
    if not container then
        Log:debug("consumeBatches: container not found: %s", containerId)
        return { consumed = 0, batches = {} }
    end

    if not container.batches then
        return { consumed = 0, batches = {} }
    end

    local result = RmBatch.consumeFIFO(container.batches, amount)

    -- Mark dirty for MP sync
    self.dirtyContainers[containerId] = true

    -- Broadcast update to clients (only if something was consumed)
    if result.consumed > 0 then
        self:broadcastContainerUpdate(containerId, RmFreshUpdateEvent.OP_UPDATE, {
            batches = container.batches
        })
    end

    Log:debug("BATCH_CONSUME: container=%s requested=%.1f consumed=%.1f remaining=%d",
        containerId, amount, result.consumed, #container.batches)

    return result
end

--- Get batches for a container
--- Returns empty table if container not found (not an error)
--- @note CRITICAL: Returned table is a READ-ONLY reference to internal data
--- @note Do NOT modify returned batches directly - use addBatch()/consumeBatches() instead
--- @note Direct modification will corrupt internal state and break FIFO invariants
---@param containerId string Container ID
---@return table Array of batches (oldest first) or empty table - DO NOT MODIFY
function RmFreshManager:getBatches(containerId)
    local container = self.containers[containerId]
    if container == nil then
        return {}
    end

    return container.batches or {}
end

--- Clear all batches from a container (EXPERIMENTAL)
--- Used by TransferCoordinator.transferAllBatches after moving batches to destination
--- SERVER ONLY
---@param containerId string Container ID
---@return boolean success True if batches were cleared
function RmFreshManager:clearBatches(containerId)
    if g_server == nil then return false end

    local container = self.containers[containerId]
    if container == nil then
        Log:trace("CLEAR_BATCHES: container %s not found", containerId or "nil")
        return false
    end

    local oldCount = #(container.batches or {})
    container.batches = {}

    Log:debug("CLEAR_BATCHES: %s cleared %d batches", containerId, oldCount)
    return true
end

--- Handle fill level changes reported by adapters
--- Called when fill amount increases (add batch) or decreases (consume batches)
--- SERVER ONLY - all batch mutations are server-authoritative
--- NOTE: fillUnitIndex kept in signature for adapter compatibility/logging, not used for batch lookup
---@param containerId string Container ID
---@param fillUnitIndex number Fill unit index (1-based) - for logging/adapter reference
---@param delta number Change in fill level (positive = add, negative = consume)
---@param fillType number Fill type index - validated against container's fillTypeIndex
---@return nil
function RmFreshManager:onFillChanged(containerId, fillUnitIndex, delta, fillType)
    if g_server == nil then return end -- Server only

    -- Skip non-perishable fills
    if not RmFreshSettings:isPerishableByIndex(fillType) then
        Log:trace("FILL_CHANGED_SKIP: container=%s fillType=%d (not perishable)",
            containerId, fillType)
        return
    end

    -- Validate fillType matches container's fillTypeIndex
    local container = self.containers[containerId]
    if container and container.fillTypeIndex and container.fillTypeIndex ~= fillType then
        if delta > 0 then
            -- Fill type changed with new fill: clear old batches, update fillType
            Log:debug("FILL_TYPE_CHANGE: container=%s old=%d new=%d (clearing %d batches)",
                containerId, container.fillTypeIndex, fillType, #(container.batches or {}))
            container.batches = {}
            container.fillTypeIndex = fillType
            -- Also update identityMatch for display and save/load
            if container.identityMatch and container.identityMatch.storage then
                container.identityMatch.storage.fillTypeName = g_fillTypeManager:getFillTypeNameByIndex(fillType)
            end
        else
            -- Consumption with mismatched type: log warning, allow consumption
            Log:warning("FILL_TYPE_MISMATCH: container=%s stored=%d event=%d (consuming anyway)",
                containerId, container.fillTypeIndex, fillType)
        end
    end

    Log:debug("FILL_CHANGED: container=%s fu=%d delta=%.1f fillType=%d",
        containerId, fillUnitIndex, delta, fillType)

    if delta > 0 then
        -- Check for pending transfer batches FIRST
        local pendingBatches = self:getTransferPending(containerId)

        -- TRACE: Log pending lookup result (AI debugging per 12.5 guidelines)
        Log:trace("FILL_CHANGED_PENDING_CHECK: container=%s found=%s count=%d",
            containerId, tostring(pendingBatches ~= nil), pendingBatches and #pendingBatches or 0)

        if pendingBatches then
            -- Calculate pending total for logging
            local pendingTotal = 0
            for _, b in ipairs(pendingBatches) do
                pendingTotal = pendingTotal + b.amount
            end

            Log:trace("FILL_CHANGED_PENDING_DETAIL: container=%s pendingTotal=%.1f delta=%.1f suppress=%s",
                containerId, pendingTotal, delta, tostring(self.suppressFillChangeBatch))

            if not self.suppressFillChangeBatch then
                -- Consume pending batches up to delta amount (handles partial transfers)
                local remaining = delta
                local batchCount = 0
                local batchesBefore = #(self.containers[containerId] and self.containers[containerId].batches or {})

                for _, batch in ipairs(pendingBatches) do
                    if remaining <= 0 then break end
                    local toAdd = math.min(batch.amount, remaining)
                    self:addBatch(containerId, toAdd, batch.age)
                    remaining = remaining - toAdd
                    batchCount = batchCount + 1
                end

                local batchesAfter = #(self.containers[containerId] and self.containers[containerId].batches or {})

                -- DEBUG: Log transfer received with state transition (per 12.5 guidelines)
                Log:debug("FILL_CHANGED_TRANSFER: container=%s delta=%.1f pendingBatches=%d batches: %d->%d",
                    containerId, delta, batchCount, batchesBefore, batchesAfter)

                -- DEBUG: Log if partial transfer detected
                if math.abs(pendingTotal - delta) > 0.1 then
                    Log:debug("FILL_CHANGED_PARTIAL: container=%s pending=%.1f actual=%.1f (%.0f%% consumed)",
                        containerId, pendingTotal, delta, (delta / pendingTotal) * 100)
                end
            else
                -- Suppressed: pending already cleared by getTransferPending, discard
                Log:trace("FILL_CHANGED_PENDING_DISCARDED: container=%s batches=%d (suppress=true)",
                    containerId, #pendingBatches)
            end
        elseif self:handleBulkTransferFillChange(containerId, delta, fillType) then
            -- Priority 2: Bulk transfer mode (production chain distribution)
            -- Handled by bulk mode - queued for matching with source REMOVE
            return
        elseif container and container.playerCanFill == false then
            -- Step 6: Production output - skip fillType fallback entirely
            -- Production outputs (milk, factory products) should NEVER use stale fallback
            -- They are created fresh by the game, not transferred from player
            if not self.suppressFillChangeBatch then
                self:addBatch(containerId, delta, 0)
                Log:debug("FILL_CHANGED_PRODUCTION_OUTPUT: container=%s delta=%.1f (playerCanFill=false, fresh batch)",
                    containerId, delta)
            end
        else
            -- No containerId pending, not bulk mode, not production output - check fillType fallback
            local fallbackBatches = self:getTransferPendingByFillType(fillType)

            if fallbackBatches then
                -- Calculate fallback total for logging
                local fallbackTotal = 0
                for _, b in ipairs(fallbackBatches) do
                    fallbackTotal = fallbackTotal + b.amount
                end

                Log:trace("FILL_CHANGED_FALLBACK_FOUND: container=%s fillType=%d total=%.1f delta=%.1f",
                    containerId, fillType, fallbackTotal, delta)

                if not self.suppressFillChangeBatch then
                    -- Consume fallback batches up to delta amount
                    local remaining = delta
                    local batchCount = 0
                    local batchesBefore = #(self.containers[containerId] and self.containers[containerId].batches or {})

                    for _, batch in ipairs(fallbackBatches) do
                        if remaining <= 0 then break end
                        local toAdd = math.min(batch.amount, remaining)
                        self:addBatch(containerId, toAdd, batch.age)
                        remaining = remaining - toAdd
                        batchCount = batchCount + 1
                    end

                    -- Step 2 fix: Handle remainder not covered by fallback batches
                    -- This happens when fallback amount < delta (e.g., 0.8L fallback for 43.9L delta)
                    -- The remainder represents fill that wasn't part of the correlated transfer
                    if remaining > 0.001 then
                        self:addBatch(containerId, remaining, 0)
                        Log:debug("FILL_CHANGED_FALLBACK_REMAINDER: container=%s remainder=%.1f age=0",
                            containerId, remaining)
                    end

                    local batchesAfter = #(self.containers[containerId] and self.containers[containerId].batches or {})

                    Log:debug(
                        "FILL_CHANGED_FALLBACK_TRANSFER: container=%s delta=%.1f fallbackBatches=%d batches: %d->%d",
                        containerId, delta, batchCount, batchesBefore, batchesAfter)
                else
                    Log:trace("FILL_CHANGED_FALLBACK_DISCARDED: container=%s batches=%d (suppress=true)",
                        containerId, #fallbackBatches)
                end
            elseif not self.suppressFillChangeBatch then
                -- No pending by containerId, bulk mode, or fillType = fresh fill (age 0)
                -- FIX: Use normal merge (not skipMerge) - correction still works on merged batch
                -- If no correction comes (buy station, harvester), merged batch stays age=0 (correct)
                self:addBatch(containerId, delta, 0)
                -- Note: addBatch already logs BATCH_ADD at debug level

                -- Record for retroactive correction
                -- If source -delta fires after this (same frame), it can correct this batch's age
                -- For non-transfer fills (buy station), correction simply expires unused
                self.pendingCorrection[fillType] = {
                    containerId = containerId,
                    timestamp = g_time or 0
                }
                Log:trace("FILL_CHANGED_CORRECTION_RECORDED: fillType=%d container=%s (awaiting source)",
                    fillType, containerId)
            else
                Log:trace("FILL_CHANGED_SUPPRESSED: console mode, skipping automatic batch creation")
            end
        end
    elseif delta < 0 then
        -- Fill removed: consume FIFO
        -- Priority 2: Bulk transfer mode (production chain distribution)
        if self:handleBulkTransferFillChange(containerId, delta, fillType) then
            -- Handled by bulk mode - batches consumed and matched to destination ADD
            return
        end

        -- Skip if console mode (console handles batch removal directly)
        if not self.suppressFillChangeBatch then
            -- Stage batches by fillType BEFORE consuming
            -- This enables age preservation for physics-based transfers
            -- where Dischargeable.dischargeToObject isn't called
            local peeked = self:peekBatches(containerId, -delta)
            if peeked.totalAmount > 0 then
                -- Step 6: Only set fillType pending if container can be player-emptied
                -- Production inputs/bedding (playerCanEmpty=false) are consumed internally, not transferred
                -- nil is treated as true for backward compatibility
                if container == nil or container.playerCanEmpty ~= false then
                    self:setTransferPendingByFillType(fillType, peeked.batches)
                    Log:trace("FILL_CHANGED_SOURCE_STAGED: container=%s fillType=%d amount=%.1f batches=%d",
                        containerId, fillType, peeked.totalAmount, #peeked.batches)

                    -- Retroactive correction for same-frame timing
                    -- If destination already created a fresh batch (ADD before REMOVE), correct its age
                    local correction = self.pendingCorrection[fillType]
                    if correction and correction.containerId ~= containerId then
                        local timeDiff = (g_time or 0) - correction.timestamp
                        -- Same frame = within 50ms (accounts for frame timing variance)
                        if timeDiff < 50 then
                            local destContainer = self.containers[correction.containerId]
                            if destContainer and #destContainer.batches > 0 then
                                -- Find the most recent batch (last in array) and correct its age
                                local lastBatch = destContainer.batches[#destContainer.batches]
                                local oldAge = lastBatch.ageInPeriods
                                local newAge = peeked.batches[1].age -- Use oldest source batch age
                                lastBatch.ageInPeriods = newAge

                                -- Re-sort batches after age change (maintains FIFO order)
                                RmBatch.mergeSimilarBatches(destContainer.batches, RmFreshSettings.MERGE_THRESHOLD)

                                Log:debug(
                                    "FILL_CHANGED_CORRECTION_APPLIED: dest=%s age=%.4f->%.4f batches=%d (source=%s timeDiff=%dms)",
                                    correction.containerId, oldAge, newAge, #destContainer.batches, containerId, timeDiff)

                                -- Broadcast the corrected batch to clients
                                self:broadcastContainerUpdate(correction.containerId, RmFreshUpdateEvent.OP_UPDATE,
                                    destContainer)

                                -- Clear fillType pending - it was consumed by the correction
                                -- Prevents double-use by normal fallback path
                                self.transferPendingByFillType[fillType] = nil
                            end
                        else
                            Log:trace("FILL_CHANGED_CORRECTION_EXPIRED: fillType=%d timeDiff=%dms (>50ms)",
                                fillType, timeDiff)
                        end
                    end
                    -- Clear correction record (consumed or expired)
                    self.pendingCorrection[fillType] = nil
                else
                    -- playerCanEmpty=false: consumption only, don't stage for transfer
                    Log:debug("FILL_CHANGED_CONSUMPTION_ONLY: container=%s fillType=%d amount=%.1f (playerCanEmpty=false, not staged)",
                        containerId, fillType, peeked.totalAmount)
                end
            end

            -- Now consume the batches
            self:consumeBatches(containerId, -delta)
        else
            Log:trace("FILL_CHANGED_SUPPRESSED: console mode, skipping automatic batch consumption")
        end
    end
end

-- =============================================================================
-- CONSOLE SUPPORT - Batch Manipulation
-- =============================================================================

--- Set age of a specific batch
--- SERVER ONLY - console command support
---@param containerId string Container ID
---@param batchIndex number Batch index (1-based, oldest first)
---@param age number New age in periods
---@return boolean success, string message
function RmFreshManager:setBatchAge(containerId, batchIndex, age)
    if g_server == nil then return false, "Server only" end

    local container = self.containers[containerId]
    if not container then
        return false, "Container not found"
    end

    if not container.batches then
        return false, "No batches in container"
    end

    local batch = container.batches[batchIndex]
    if not batch then
        return false, "Batch not found"
    end

    local oldAge = batch.ageInPeriods
    batch.ageInPeriods = age

    -- Broadcast update
    self:broadcastContainerUpdate(containerId, RmFreshUpdateEvent.OP_UPDATE, {
        batches = container.batches
    })

    Log:debug("CONSOLE_OP: method=setBatchAge containerId=%s result=success", containerId)
    Log:trace("BATCH_AGE_SET: container=%s batch=%d oldAge=%.4f newAge=%.4f",
        containerId, batchIndex, oldAge, age)

    return true, string.format("Age set: %.4f → %.4f", oldAge, age)
end

--- Remove a specific batch by index
--- SERVER ONLY - console command support
---@param containerId string Container ID
---@param batchIndex number Batch index (1-based, oldest first)
---@return table|nil removed batch, string message
function RmFreshManager:removeBatchByIndex(containerId, batchIndex)
    if g_server == nil then return nil, "Server only" end

    local container = self.containers[containerId]
    if not container then
        return nil, "Container not found"
    end

    if not container.batches then
        return nil, "No batches in container"
    end

    local batch = container.batches[batchIndex]
    if not batch then
        return nil, "Batch not found"
    end

    -- Remove batch from array
    table.remove(container.batches, batchIndex)

    -- Broadcast update
    self:broadcastContainerUpdate(containerId, RmFreshUpdateEvent.OP_UPDATE, {
        batches = container.batches
    })

    Log:debug("CONSOLE_OP: method=removeBatchByIndex containerId=%s result=success", containerId)
    Log:trace("BATCH_REMOVED: container=%s batch=%d amount=%.1f age=%.4f",
        containerId, batchIndex, batch.amount, batch.ageInPeriods)

    return batch, string.format("Removed batch: %.1f units, age %.4f", batch.amount, batch.ageInPeriods)
end

--- Set age of all batches in a container
--- SERVER ONLY - console command support
---@param containerId string Container ID
---@param age number New age in periods
---@return boolean success, string message
function RmFreshManager:setAllBatchAges(containerId, age)
    if g_server == nil then return false, "Server only" end

    local container = self.containers[containerId]
    if not container then
        return false, "Container not found"
    end

    local batchCount = 0
    if container.batches then
        for _, batch in ipairs(container.batches) do
            batch.ageInPeriods = age
            batchCount = batchCount + 1
        end

        -- Broadcast update
        self:broadcastContainerUpdate(containerId, RmFreshUpdateEvent.OP_UPDATE, {
            batches = container.batches
        })
    end

    Log:debug("CONSOLE_OP: method=setAllBatchAges containerId=%s batchCount=%d result=success",
        containerId, batchCount)

    return true, string.format("Set age %.4f on %d batches", age, batchCount)
end

-- =============================================================================
-- CONSOLE SUPPORT - Test Isolation Helper
-- =============================================================================

--- Check if a container should be processed in global operations
--- Used for test isolation - when testContainerPrefix is set, only matching containers are processed
--- This prevents automated tests from affecting real player containers
---@param containerId string Container ID to check
---@return boolean True if container should be processed
function RmFreshManager:shouldProcessContainer(containerId)
    if self.testContainerPrefix == nil then
        return true -- Normal mode: process all containers
    end
    -- Test mode: only process containers with matching prefix
    return containerId:sub(1, #self.testContainerPrefix) == self.testContainerPrefix
end

-- =============================================================================
-- AGING LOGIC (Core + Console Support)
-- =============================================================================

--- Core aging logic - ages all containers by specified hours
--- PRIVATE - use processHourlyAging() for real aging, simulateHours() for testing
--- Formula: ageIncrement = hours / (daysPerPeriod * 24)
--- TEST ISOLATION: When testContainerPrefix is set, only processes matching containers
---@param hours number Hours to age
---@return table { containersProcessed, batchesExpired, amountExpired }
function RmFreshManager:_applyAging(hours)
    local daysPerPeriod = 1
    if g_currentMission and g_currentMission.environment then
        daysPerPeriod = g_currentMission.environment.daysPerPeriod or 1
    end

    -- Age increment: hours → periods
    local increment = hours / (daysPerPeriod * 24)

    local stats = {
        containersProcessed = 0,
        batchesExpired = 0,
        amountExpired = 0
    }

    -- Collect entities to delete after expiration (bales with fillLevel=0)
    -- Must delete AFTER loop to avoid modifying containers during iteration
    local entitiesToDelete = {}

    for containerId, container in pairs(self.containers) do
        -- Test isolation: skip non-test containers when in test mode
        if self:shouldProcessContainer(containerId) then
            stats.containersProcessed = stats.containersProcessed + 1

            -- Skip aging for fillTypes no longer perishable (AC #13: settings changes apply immediately)
            if not RmFreshSettings:isPerishableByIndex(container.fillTypeIndex) then
                Log:trace("SKIP_AGE: container=%s (fillType no longer perishable)", containerId)
                -- Skip aging for fermenting bales, etc.
            elseif not self:shouldAge(container) then
                Log:trace("SKIP_AGE: container=%s (shouldAge=false)", containerId)
            else
                -- Sync fillType for bales before aging (handles GRASS→SILAGE transformation)
                self:syncBaleFillType(containerId, container)

                if container.batches and #container.batches > 0 then
                    -- Age all batches
                    for _, batch in ipairs(container.batches) do
                        RmBatch.age(batch, increment)
                    end

                    -- Process expirations
                    local config = RmFreshSettings:getThresholdByIndex(container.fillTypeIndex)
                    local removedAmount = RmBatch.removeExpired(container.batches, config.expiration)

                    if removedAmount > 0 then
                        stats.amountExpired = stats.amountExpired + removedAmount
                        stats.batchesExpired = stats.batchesExpired + 1 -- Count containers with expirations

                        -- Record loss for statistics
                        local location = container.metadata and container.metadata.location or "Unknown"
                        RmLossTracker:recordExpiration(container, removedAmount, location)

                        -- Remove expired fill from game entity (adapter uses containerId)
                        local adapter = self:getAdapterForType(container.entityType)
                        if adapter and container.runtimeEntity then
                            self.suppressFillChangeBatch = true
                            adapter:addFillLevel(containerId, -removedAmount)
                            self.suppressFillChangeBatch = false
                            Log:debug("EXPIRE_REMOVE: container=%s removed=%.1f", containerId, removedAmount)

                            -- Check if container is now empty - let adapter handle cleanup
                            if adapter.onContainerEmpty and adapter.getFillLevel then
                                -- Check actual game state via adapter (handles drift)
                                local fillLevel = adapter:getFillLevel(containerId)
                                if fillLevel <= 0 then
                                    table.insert(entitiesToDelete, {
                                        containerId = containerId,
                                        adapter = adapter
                                    })
                                end
                            end
                        end
                    end

                    -- Broadcast update to clients
                    self:broadcastContainerUpdate(containerId, RmFreshUpdateEvent.OP_UPDATE, {
                        batches = container.batches
                    })
                end
            end -- end of shouldAge else block
        end
    end

    -- Handle empty containers after loop (safe iteration pattern from v1)
    for _, entry in ipairs(entitiesToDelete) do
        Log:debug("CONTAINER_EMPTY: %s calling adapter cleanup", entry.containerId)
        -- Let adapter handle cleanup (unregister, delete entity, etc.)
        entry.adapter:onContainerEmpty(entry.containerId)
    end

    return stats
end

--- Process real hourly aging - called from onHourChanged
--- SERVER ONLY - ages all containers by 1 hour
--- Entry point for actual game time aging (not testing)
---@return table { containersProcessed, batchesExpired, amountExpired }
function RmFreshManager:processHourlyAging()
    if g_server == nil then return { containersProcessed = 0, batchesExpired = 0, amountExpired = 0 } end

    local stats = self:_applyAging(1)

    if stats.amountExpired > 0 then
        Log:info("HOURLY_AGING: containers=%d expired=%.1f units",
            stats.containersProcessed, stats.amountExpired)
    else
        Log:trace("HOURLY_AGING: containers=%d (no expirations)", stats.containersProcessed)
    end

    return stats
end

--- Simulate time passage for testing (console command: fAge)
--- SERVER ONLY - ages all containers by specified hours
--- Entry point for console testing (not real game time)
---@param hours number Hours to simulate
---@return table { containersProcessed, batchesExpired, amountExpired }
function RmFreshManager:simulateHours(hours)
    if g_server == nil then return { containersProcessed = 0, batchesExpired = 0, amountExpired = 0 } end

    local stats = self:_applyAging(hours)

    Log:debug("CONSOLE_OP: method=simulateHours hours=%d containers=%d expired=%.1f",
        hours, stats.containersProcessed, stats.amountExpired)

    return stats
end

--- Simulate time passage for a single container
--- Ages batches and processes expirations for one container only
--- SERVER ONLY - console command support
---@param containerId string Container ID
---@param hours number Hours to simulate
---@return table { batchesExpired, amountExpired } or nil if container not found
function RmFreshManager:simulateHoursForContainer(containerId, hours)
    if g_server == nil then return nil end

    local container = self.containers[containerId]
    if not container then
        return nil
    end

    local daysPerPeriod = 1
    if g_currentMission and g_currentMission.environment then
        daysPerPeriod = g_currentMission.environment.daysPerPeriod or 1
    end

    -- Age increment: hours → periods
    local increment = hours / (daysPerPeriod * 24)

    local stats = {
        batchesExpired = 0,
        amountExpired = 0
    }

    -- Skip aging for fermenting bales, etc.
    if not self:shouldAge(container) then
        Log:trace("SKIP_AGE: container=%s (shouldAge=false)", containerId)
        return stats -- Return empty stats - nothing processed
    end

    -- Sync fillType for bales before aging (handles GRASS→SILAGE transformation)
    self:syncBaleFillType(containerId, container)

    -- Use flat batches
    if container.batches and #container.batches > 0 then
        -- Age all batches
        for _, batch in ipairs(container.batches) do
            RmBatch.age(batch, increment)
        end

        -- Process expirations using container's fillTypeIndex
        local fillType = container.fillTypeIndex or 0
        local config = RmFreshSettings:getThresholdByIndex(fillType)
        local removedAmount = RmBatch.removeExpired(container.batches, config.expiration)

        if removedAmount > 0 then
            stats.amountExpired = stats.amountExpired + removedAmount
            stats.batchesExpired = stats.batchesExpired + 1

            -- Record loss for statistics
            local location = container.metadata and container.metadata.location or "Unknown"
            RmLossTracker:recordExpiration(container, removedAmount, location)

            -- Remove expired fill from game entity (adapter uses containerId)
            local adapter = self:getAdapterForType(container.entityType)
            if adapter and container.runtimeEntity then
                self.suppressFillChangeBatch = true
                adapter:addFillLevel(containerId, -removedAmount)
                self.suppressFillChangeBatch = false
                Log:debug("EXPIRE_SYNC: container=%s removed=%.1f", containerId, removedAmount)
            end
        end

        -- Broadcast update
        self:broadcastContainerUpdate(containerId, RmFreshUpdateEvent.OP_UPDATE, {
            batches = container.batches
        })
    end

    Log:debug("CONSOLE_OP: method=simulateHoursForContainer containerId=%s hours=%d expired=%.1f",
        containerId, hours, stats.amountExpired)

    return stats
end

-- =============================================================================
-- CONSOLE SUPPORT - Force Operations
-- =============================================================================

--- Force expire a specific batch
--- Sets batch age beyond expiration threshold
--- SERVER ONLY - console command support
---@param containerId string Container ID
---@param batchIndex number Batch index (1-based, oldest first)
---@return number|nil expired amount, string message
function RmFreshManager:forceExpire(containerId, batchIndex)
    if g_server == nil then return nil, "Server only" end

    local container = self.containers[containerId]
    if not container then
        return nil, "Container not found"
    end

    if not container.batches then
        return nil, "No batches found"
    end

    local batch = container.batches[batchIndex]
    if not batch then
        return nil, "Batch not found"
    end

    -- Store amount before removal
    local expiredAmount = batch.amount
    local fillType = container.fillTypeIndex

    -- Remove fill from game entity via adapter (adapter uses containerId)
    local adapter = self:getAdapterForType(container.entityType)
    if adapter and container.runtimeEntity then
        self.suppressFillChangeBatch = true
        Log:trace("FORCE_EXPIRE: calling adapter for containerId=%s", containerId)
        adapter:addFillLevel(containerId, -expiredAmount)
        self.suppressFillChangeBatch = false
    end

    -- Get expiration threshold for this fill type
    local config = RmFreshSettings:getThresholdByIndex(fillType)
    local threshold = config.expiration

    -- Set age beyond threshold (epsilon ensures batch is definitively expired)
    -- Using 0.001 as epsilon: small enough to not matter for display, large enough to avoid float comparison issues
    batch.ageInPeriods = threshold + 0.001

    -- Remove expired batches from tracking
    RmBatch.removeExpired(container.batches, threshold)

    -- Broadcast update
    self:broadcastContainerUpdate(containerId, RmFreshUpdateEvent.OP_UPDATE, {
        batches = container.batches
    })

    Log:debug("CONSOLE_OP: method=forceExpire containerId=%s expired=%.1f", containerId, expiredAmount)

    return expiredAmount, string.format("Force expired %.1f units", expiredAmount)
end

--- Force expire all batches by entity type
--- Expires all batches in all containers of the specified type
--- SERVER ONLY - console command support
--- NOTE: Broadcasts per-container. For large server optimization, consider bulk sync event.
--- TEST ISOLATION: When testContainerPrefix is set, only processes matching containers
---@param entityType string Entity type: "vehicle" | "bale" | "placeable" | "husbandry" | "stored"
---@return table { containersAffected, totalExpired }
function RmFreshManager:forceExpireAll(entityType)
    if g_server == nil then return { containersAffected = 0, totalExpired = 0 } end

    local stats = {
        containersAffected = 0,
        totalExpired = 0
    }

    -- Get adapter for this entity type
    local adapter = self:getAdapterForType(entityType)

    for containerId, container in pairs(self.containers) do
        -- Test isolation: skip non-test containers when in test mode
        if container.entityType == entityType and self:shouldProcessContainer(containerId) then
            if container.batches and #container.batches > 0 then
                -- Get expiration threshold for this fill type
                local config = RmFreshSettings:getThresholdByIndex(container.fillTypeIndex)
                local threshold = config.expiration

                -- Calculate total to expire
                local containerExpired = 0
                for _, batch in ipairs(container.batches) do
                    batch.ageInPeriods = threshold + 0.001
                    containerExpired = containerExpired + batch.amount
                end

                -- Remove fill from game entity via adapter (adapter uses containerId)
                if adapter and container.runtimeEntity and containerExpired > 0 then
                    Log:trace("FORCE_EXPIRE_ALL: calling adapter for containerId=%s", containerId)
                    adapter:addFillLevel(containerId, -containerExpired)
                end

                -- Remove expired batches from tracking
                RmBatch.removeExpired(container.batches, threshold)

                -- Broadcast update
                self:broadcastContainerUpdate(containerId, RmFreshUpdateEvent.OP_UPDATE, {
                    batches = container.batches
                })

                if containerExpired > 0 then
                    stats.containersAffected = stats.containersAffected + 1
                    stats.totalExpired = stats.totalExpired + containerExpired
                end
            end
        end
    end

    Log:debug("CONSOLE_OP: method=forceExpireAll entityType=%s containers=%d expired=%.1f",
        entityType, stats.containersAffected, stats.totalExpired)

    return stats
end

-- =============================================================================
-- DISPLAY & ADAPTER SUPPORT
-- =============================================================================

--- Get display information for a container
--- Returns formatted expiration info for UI display
--- Used by adapters in showInfo() hooks
---@param containerId string Container ID
---@return table|nil Display info { text = string, isWarning = boolean, isExpiring = boolean } or nil
function RmFreshManager:getDisplayInfo(containerId)
    local container = self.containers[containerId]
    if not container then return nil end

    if not container.batches or #container.batches == 0 then
        return nil
    end

    local oldest = container.batches[1]
    local config = RmFreshSettings:getThresholdByIndex(container.fillTypeIndex)
    local daysPerPeriod = (g_currentMission and g_currentMission.environment and g_currentMission.environment.daysPerPeriod) or
    1

    local text = RmBatch.formatExpiresIn(oldest, config.expiration, daysPerPeriod)
    local warningAge = RmFreshSettings:getWarningThresholdByIndex(container.fillTypeIndex)

    return {
        text = text,
        isWarning = oldest.ageInPeriods >= warningAge,
        isExpiring = oldest.ageInPeriods >= config.expiration,
    }
end

--- Determine if a container should age
--- Delegates to adapter-specific logic (e.g., fermentation check for bales)
--- Returns true by default (most containers age)
---@param container table Container entry
---@return boolean True if container should age
function RmFreshManager:shouldAge(container)
    if container == nil then
        return true
    end

    if container.runtimeEntity == nil then
        return true -- Default: age if entity not available
    end

    local adapter = self:getAdapterForType(container.entityType)
    if adapter and adapter.shouldAge then
        return adapter:shouldAge(container.runtimeEntity)
    end

    return true -- Default: age
end

--- Sync fillType from bale entity to container
--- Called before aging to ensure fillType is current after fermentation completes
--- Bale-specific: GRASS_WINDROW → SILAGE transformation during fermentation
--- CRITICAL: Preserves batches (transformation, not replacement)
---
--- ASSUMPTION: Bales undergo single-step transformations (GRASS→SILAGE).
--- Multi-step refills (GRASS→other→SILAGE) are out of scope.
---
---@param containerId string Container ID
---@param container table Container entry
function RmFreshManager:syncBaleFillType(containerId, container)
    if container.entityType ~= "bale" then return end
    if container.runtimeEntity == nil then return end

    local baleFillType = container.runtimeEntity.fillType
    if baleFillType == nil then return end

    -- Check if fillType changed (e.g., fermentation complete: GRASS → SILAGE)
    if container.fillTypeIndex ~= baleFillType and RmFreshSettings:isPerishableByIndex(baleFillType) then
        -- Defensive fillType name lookup (handles mod conflicts, shutdown edge cases)
        local function getFillTypeName(fillTypeIndex)
            if fillTypeIndex == nil then return "nil" end
            local ok, name = pcall(function()
                return g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex)
            end)
            if not ok or name == nil then
                return "FT_" .. tostring(fillTypeIndex)
            end
            return name
        end

        local oldName = getFillTypeName(container.fillTypeIndex)
        local newName = getFillTypeName(baleFillType)
        Log:debug("BALE_TRANSFORM: container=%s %s->%s (batches preserved)",
            containerId, oldName, newName)

        -- SYNC fillType but KEEP batches (transformation, not replacement)
        container.fillTypeIndex = baleFillType
        -- Also update identityMatch for save consistency
        if container.identityMatch and container.identityMatch.storage then
            container.identityMatch.storage.fillTypeName = getFillTypeName(baleFillType)
        end
    end
end

--- Register an adapter module for a container type
--- Called by adapters at the end of their module file (after source() loads it)
--- Enables console commands to access adapter-specific methods like adjustFillLevel()
---@param entityType string Container type: "vehicle" | "bale" | "placeable" | "husbandry" | "stored"
---@param adapter table Adapter module (e.g., RmVehicleAdapter)
---@return nil
function RmFreshManager:registerAdapter(entityType, adapter)
    local validTypes = { vehicle = true, bale = true, placeable = true, husbandryfood = true, stored = true }
    if not validTypes[entityType] then
        Log:error("registerAdapter: invalid entityType %q (valid: vehicle, bale, placeable, husbandryfood, stored)",
            tostring(entityType))
        return
    end

    self.adapters[entityType] = adapter
    Log:debug("ADAPTER_REG: entityType=%s adapter=%s", entityType, tostring(adapter))
end

--- Get adapter module for a container type
--- Used by console commands and reconciliation
---@param containerType string Container type: "vehicle" | "bale" | "placeable" | "husbandry" | "stored"
---@return table|nil Adapter module or nil if not registered
function RmFreshManager:getAdapterForType(containerType)
    return self.adapters[containerType]
end

-- =============================================================================
-- HELPER FUNCTIONS
-- =============================================================================

--- Get count of registered containers
--- Used for logging and debugging
---@return number Number of containers in registry
function RmFreshManager:getContainerCount()
    local count = 0
    for _ in pairs(self.containers) do
        count = count + 1
    end
    return count
end

--- Count fill units in a container
--- Used for logging reconciliation
---@param container table Container entry
---@return number Number of fill units with data
function RmFreshManager:countFillUnits(container)
    if container == nil or container.fillUnits == nil then
        return 0
    end
    local count = 0
    for _ in pairs(container.fillUnits) do
        count = count + 1
    end
    return count
end

-- =============================================================================
-- FILLTYPE NAME HELPERS
-- =============================================================================

--- Legacy compatibility map for fill type names
--- Maps old/alternative names to current FS25 names
--- Add entries here if mods or old saves use different naming conventions
RmFreshManager.FILLTYPE_LEGACY_MAP = {
    -- Example legacy mappings (add as needed for compatibility):
    -- ["GRAIN_WHEAT"] = "WHEAT",
    -- ["GRAIN_BARLEY"] = "BARLEY",
}

--- Resolve fillTypeName string to fillTypeIndex number
--- Used when loading containers - converts stored names to runtime indices
--- fillTypeName is the persisted form, fillTypeIndex is runtime-only
---
--- NORMALIZATION: Names are converted to uppercase for consistent matching
--- COMPATIBILITY: Legacy name aliases are checked via FILLTYPE_LEGACY_MAP
---
--- DEFENSIVE: Returns nil for unknown/modded fillTypes that aren't loaded
--- Caller should check for nil and skip containers with unresolvable fillTypes
---
---@param fillTypeName string Fill type name (e.g., "WHEAT", "wheat", "Wheat")
---@return number|nil fillTypeIndex or nil if not found
---@example
---   local idx = RmFreshManager:resolveFillTypeIndex("WHEAT")
---   local idx2 = RmFreshManager:resolveFillTypeIndex("wheat")  -- also works
---   if idx then container.fillTypeIndex = idx end
function RmFreshManager:resolveFillTypeIndex(fillTypeName)
    Log:trace(">>> resolveFillTypeIndex(%q)", tostring(fillTypeName))

    if fillTypeName == nil or fillTypeName == "" then
        Log:trace("<<< resolveFillTypeIndex = nil (empty input)")
        return nil
    end

    -- Normalize to uppercase for consistent matching
    local normalized = string.upper(tostring(fillTypeName))

    -- Check legacy compatibility map for old/alternative names
    local mapped = self.FILLTYPE_LEGACY_MAP[normalized]
    if mapped then
        Log:trace("FILLTYPE_RESOLVE: Legacy mapping %s → %s", normalized, mapped)
        normalized = mapped
    end

    -- Use FS25 fillTypeManager to resolve name → index
    local ok, result = pcall(function()
        return g_fillTypeManager:getFillTypeIndexByName(normalized)
    end)

    if not ok then
        -- result contains error message when pcall fails
        Log:trace("FILLTYPE_RESOLVE: pcall failed for %q (error: %s)", normalized, tostring(result))
        Log:trace("<<< resolveFillTypeIndex = nil (pcall failed)")
        return nil
    end

    -- getFillTypeIndexByName returns nil for unknown types
    if result == nil then
        Log:debug("FILLTYPE_RESOLVE: Unknown fillType %q (mod not loaded?)", normalized)
        Log:trace("<<< resolveFillTypeIndex = nil (unknown type)")
        return nil
    end

    Log:trace("<<< resolveFillTypeIndex = %d", result)
    return result
end

--- Get fillTypeName string from fillTypeIndex number
--- Used when saving containers - converts runtime indices to stable names
--- fillTypeName is the persisted form, fillTypeIndex is runtime-only
---
--- DEFENSIVE: Returns fallback string for unknown indices (shouldn't happen)
--- Format: "FT_{index}" for unknown types to preserve data without crashing
---
---@param fillTypeIndex number Fill type index (e.g., FillType.WHEAT)
---@return string fillTypeName (e.g., "WHEAT") or "FT_{index}" fallback
---@example
---   local name = RmFreshManager:getFillTypeName(FillType.WHEAT)
---   container.identityMatch.storage.fillTypeName = name
function RmFreshManager:getFillTypeName(fillTypeIndex)
    Log:trace(">>> getFillTypeName(%s)", tostring(fillTypeIndex))

    if fillTypeIndex == nil then
        Log:trace("<<< getFillTypeName = %q (nil input)", "FT_nil")
        return "FT_nil"
    end

    -- Use FS25 fillTypeManager to resolve index → name
    local ok, result = pcall(function()
        return g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex)
    end)

    if not ok then
        -- result contains error message when pcall fails
        local fallback = "FT_" .. tostring(fillTypeIndex)
        Log:trace("FILLTYPE_NAME: pcall failed for index %d (error: %s)", fillTypeIndex, tostring(result))
        Log:trace("<<< getFillTypeName = %q (pcall failed)", fallback)
        return fallback
    end

    -- getFillTypeNameByIndex returns nil for unknown indices
    if result == nil then
        local fallback = "FT_" .. tostring(fillTypeIndex)
        Log:debug("FILLTYPE_NAME: Unknown fillType index %d", fillTypeIndex)
        Log:trace("<<< getFillTypeName = %q (unknown index)", fallback)
        return fallback
    end

    Log:trace("<<< getFillTypeName = %q", result)
    return result
end

-- =============================================================================
-- REFACTOR VALIDATION
-- =============================================================================

--- Validate that refactor was applied correctly
--- Run this in tests/CI to ensure removed functions are not referenced
--- and new structures exist as expected
---@return boolean success True if validation passes
---@return string|nil errorMessage Error description if validation fails
function RmFreshManager:debugValidatePostRefactor()
    local errors = {}

    -- Verify entityIdIndex is removed (should not exist)
    if self.entityIdIndex ~= nil then
        table.insert(errors, "entityIdIndex should be removed but still exists")
    end

    -- Verify rebuildEntityIdIndex is removed (should not exist as function)
    if type(self.rebuildEntityIdIndex) == "function" then
        table.insert(errors, "rebuildEntityIdIndex() should be removed but still exists")
    end

    -- Verify reconciliationPool exists as table
    if type(self.reconciliationPool) ~= "table" then
        table.insert(errors, "reconciliationPool should be a table")
    end

    -- Verify entityRefIndex exists as table
    if type(self.entityRefIndex) ~= "table" then
        table.insert(errors, "entityRefIndex should be a table")
    end

    -- Verify rebuildEntityRefIndex exists as function (replacement)
    if type(self.rebuildEntityRefIndex) ~= "function" then
        table.insert(errors, "rebuildEntityRefIndex() should exist as function")
    end

    -- Verify fillType helpers exist
    if type(self.resolveFillTypeIndex) ~= "function" then
        table.insert(errors, "resolveFillTypeIndex() should exist")
    end
    if type(self.getFillTypeName) ~= "function" then
        table.insert(errors, "getFillTypeName() should exist")
    end

    -- Verify legacy map exists
    if type(self.FILLTYPE_LEGACY_MAP) ~= "table" then
        table.insert(errors, "FILLTYPE_LEGACY_MAP should be a table")
    end

    if #errors > 0 then
        local msg = "Refactor validation failed:\n  - " .. table.concat(errors, "\n  - ")
        Log:error(msg)
        return false, msg
    end

    Log:debug("DEBUG_VALIDATE: Refactor validation passed")
    return true, nil
end

-- =============================================================================
-- CONSOLE SUPPORT - Statistics & Reconciliation
-- =============================================================================

--- Reconciliation threshold - ignore drift smaller than this (float noise)
RmFreshManager.RECONCILE_THRESHOLD = 0.5

--- Get statistics object
--- Returns the statistics table for display and debugging
---@return table Statistics { totalExpired, expiredByFillType, lossLog }
function RmFreshManager:getStatistics()
    return self.statistics
end

--- Get recent loss log entries
--- Returns the most recent entries from RmLossTracker.lossLog
--- SERVER ONLY - lossLog only exists on server
---@param limit number|nil Maximum entries to return (default 10, 0 returns empty)
---@return table Array of loss log entries (newest first in returned array)
function RmFreshManager:getLossLog(limit)
    limit = limit or 10

    -- Edge case: limit 0 returns empty
    if limit <= 0 then
        return {}
    end

    -- Use RmLossTracker.lossLog
    local log = RmLossTracker.lossLog or {}
    local logSize = #log

    -- Return all if log smaller than limit
    if logSize <= limit then
        -- Return copy in reverse order (newest first)
        local result = {}
        for i = logSize, 1, -1 do
            table.insert(result, log[i])
        end
        return result
    end

    -- Return most recent 'limit' entries (newest first)
    local result = {}
    for i = logSize, logSize - limit + 1, -1 do
        table.insert(result, log[i])
    end
    return result
end

--- Clear the loss log
--- Delegates to RmLossTracker:clearLog()
--- SERVER ONLY
---@return nil
function RmFreshManager:clearLossLog()
    if g_server == nil then return end

    RmLossTracker:clearLog()
    Log:debug("CONSOLE_OP: method=clearLossLog result=success")
end

--- Get containers with goods expiring within specified hours
--- Used by fStatus console command and future GUI displays
--- Calculates remaining hours using daysPerPeriod-aware formula
--- MULTIPLAYER: farmId filter enables "show my goods" for each player
---
--- @param hours number Hours until expiration threshold (e.g., 24 for "next day")
--- @param farmId number|nil Filter by farm (nil = all farms, for admin/debug)
--- @return table { totalAmount, thresholdHours, containers[] }
---   containers sorted by expiresInHours ascending (soonest first)
---   each container: { containerId, entityType, fillTypeName, expiringAmount, expiresInHours, farmId, name }
function RmFreshManager:getExpiringWithin(hours, farmId)
    -- Default to 24 hours if not specified
    hours = hours or 24

    -- Get environment time settings for period→hours conversion
    local daysPerPeriod = 1
    if g_currentMission and g_currentMission.environment then
        daysPerPeriod = g_currentMission.environment.daysPerPeriod or 1
    end
    local hoursPerPeriod = daysPerPeriod * 24

    -- Build result structure
    local result = {
        totalAmount = 0,
        thresholdHours = hours,
        containers = {}
    }

    -- Iterate all containers
    for containerId, container in pairs(self.containers) do
        -- Apply farmId filter if specified
        if farmId == nil or container.farmId == farmId then
            -- Get fill type config for expiration threshold
            local fillTypeName = container.identityMatch and container.identityMatch.storage
                and container.identityMatch.storage.fillTypeName or nil

            if fillTypeName and container.fillTypeIndex then
                local config = RmFreshSettings:getThresholdByIndex(container.fillTypeIndex)
                local expirationThreshold = config.expiration

                -- Calculate expiring batches
                local expiringAmount = 0
                local soonestExpiresInHours = nil

                for _, batch in ipairs(container.batches or {}) do
                    local remainingPeriods = expirationThreshold - batch.ageInPeriods
                    local remainingHours = remainingPeriods * hoursPerPeriod

                    -- Include batches at or approaching expiration within threshold
                    if remainingHours >= 0 and remainingHours <= hours then
                        expiringAmount = expiringAmount + batch.amount
                        if soonestExpiresInHours == nil or remainingHours < soonestExpiresInHours then
                            soonestExpiresInHours = remainingHours
                        end
                    end
                end

                -- Only add container if it has expiring goods
                if expiringAmount > 0 then
                    -- Resolve entity name for display
                    local name = "unknown"
                    local entity = container.runtimeEntity
                    if entity ~= nil and entity.getName ~= nil then
                        local entityName = entity:getName()
                        if entityName ~= nil and entityName ~= "" then
                            name = entityName
                        end
                    elseif container.metadata and container.metadata.location then
                        name = container.metadata.location
                    end

                    table.insert(result.containers, {
                        containerId = containerId,
                        entityType = container.entityType,
                        fillTypeName = fillTypeName,
                        expiringAmount = expiringAmount,
                        expiresInHours = soonestExpiresInHours,
                        farmId = container.farmId,
                        name = name,
                    })
                    result.totalAmount = result.totalAmount + expiringAmount
                end
            end
        end
    end

    -- Sort by soonest expiry first
    table.sort(result.containers, function(a, b)
        return a.expiresInHours < b.expiresInHours
    end)

    Log:debug("STATUS_QUERY: hours=%d farmId=%s total=%.0f containers=%d",
        hours, tostring(farmId), result.totalAmount, #result.containers)

    return result
end

-- =============================================================================
-- DISPLAY AGGREGATION API
-- =============================================================================

--- Get inventory summary aggregated by fillType for a specific farm
--- @param farmId number The farm to filter by (REQUIRED - use g_currentMission:getFarmId())
--- @return table { fillTypeName = { totalAmount, oldestAge, containerCount, isWarning }, ... }
function RmFreshManager:getInventorySummary(farmId)
    local summary = {}

    -- farmId=0 means unowned (no farm) - return empty
    if farmId == nil or farmId == 0 then
        Log:trace("INVENTORY_SUMMARY: farmId=%s, returning empty", tostring(farmId))
        return summary
    end

    local containerCount = 0
    for containerId, container in pairs(self.containers) do
        -- Only include containers belonging to this farm
        if container.farmId == farmId then
            local fillTypeName = container.identityMatch
                and container.identityMatch.storage
                and container.identityMatch.storage.fillTypeName

            if fillTypeName and #container.batches > 0 then
                Log:trace("INVENTORY_PROCESS: %s fillType=%s batches=%d",
                    containerId, fillTypeName, #container.batches)

                -- Initialize fillType entry if needed
                if not summary[fillTypeName] then
                    -- Get warning threshold (75% of expiration time)
                    local threshold = RmFreshSettings:getExpiration(fillTypeName)
                    local warningThreshold = threshold and (threshold * 0.75) or nil

                    summary[fillTypeName] = {
                        fillTypeName = fillTypeName,
                        fillTypeIndex = container.fillTypeIndex,
                        totalAmount = 0,
                        expiringAmount = 0, -- Amount at/above warning threshold
                        oldestAge = 0,
                        containerCount = 0,
                        isWarning = false,
                        warningThreshold = warningThreshold, -- Store for batch checks
                    }
                end

                local entry = summary[fillTypeName]

                -- Sum amounts from all batches, tracking expiring amounts
                for _, batch in ipairs(container.batches) do
                    entry.totalAmount = entry.totalAmount + batch.amount
                    -- Track oldest age across all batches
                    if batch.ageInPeriods > entry.oldestAge then
                        entry.oldestAge = batch.ageInPeriods
                    end
                    -- Track expiring amount (batches at/above warning threshold)
                    if entry.warningThreshold and batch.ageInPeriods >= entry.warningThreshold then
                        entry.expiringAmount = entry.expiringAmount + batch.amount
                    end
                end

                entry.containerCount = entry.containerCount + 1
                containerCount = containerCount + 1

                -- Set warning flag if any batch is at warning level
                if entry.expiringAmount > 0 then
                    entry.isWarning = true
                end
            end
        end
    end

    -- Count fillTypes for logging
    local fillTypeCount = 0
    for _ in pairs(summary) do fillTypeCount = fillTypeCount + 1 end

    Log:debug("INVENTORY_SUMMARY: farm=%d -> %d fillTypes, %d containers",
        farmId, fillTypeCount, containerCount)

    return summary
end

--- Get sorted inventory list for display
--- @param farmId number The farm to filter by (REQUIRED)
--- @param sortBy string|nil "fillType" (default), "amount", "age"
--- @return table Array of inventory entries sorted
function RmFreshManager:getInventoryList(farmId, sortBy)
    local summary = self:getInventorySummary(farmId)
    local list = {}

    for _, entry in pairs(summary) do
        -- Add display-friendly fields
        entry.fillTypeTitle = g_fillTypeManager:getFillTypeTitleByIndex(entry.fillTypeIndex) or entry.fillTypeName
        -- Calculate time until expiry (threshold - current age)
        local threshold = RmFreshSettings:getExpiration(entry.fillTypeName)
        local expiresIn = threshold and (threshold - entry.oldestAge) or 0
        entry.expiresIn = math.max(0, expiresIn)  -- Store for sorting
        entry.ageDisplay = string.format(g_i18n:getText("fresh_expires_months"), entry.expiresIn)
        entry.amountDisplay = string.format("%.0f L", entry.totalAmount)
        -- Add expiring amount display (shows how much is at/above warning threshold)
        if entry.expiringAmount > 0 then
            entry.expiringAmountDisplay = string.format("%.0f L", entry.expiringAmount)
        else
            entry.expiringAmountDisplay = nil
        end
        table.insert(list, entry)
    end

    -- Sort
    sortBy = sortBy or "fillType"
    if sortBy == "expiring" then
        -- Sort by expiring amount (descending), then by total amount as tiebreaker
        table.sort(list, function(a, b)
            if a.expiringAmount ~= b.expiringAmount then
                return a.expiringAmount > b.expiringAmount
            end
            return a.totalAmount > b.totalAmount
        end)
    elseif sortBy == "age" then
        -- Sort by expiresIn ASC (soonest to expire first)
        table.sort(list, function(a, b) return a.expiresIn < b.expiresIn end)
    else
        table.sort(list, function(a, b) return a.fillTypeTitle < b.fillTypeTitle end)
    end

    return list
end

--- Get recent loss log entries for a specific farm
--- @param farmId number The farm to filter by (REQUIRED)
--- @param count number|nil Max entries to return (default 10)
--- @return table Array of recent log entries (newest first)
function RmFreshManager:getLossLogRecent(farmId, count)
    count = count or 10
    local log = RmLossTracker.lossLog or {}
    local recent = {}

    -- farmId=0 means unowned (no farm) - return empty
    if farmId == nil or farmId == 0 then
        Log:trace("LOSS_LOG_RECENT: farmId=%s, returning empty", tostring(farmId))
        return recent
    end

    -- Iterate from newest to oldest, collecting farm-filtered entries
    for i = #log, 1, -1 do
        local entry = log[i]
        -- Only include entries for this farm
        if entry.farmId == farmId then
            local year = entry.year or 1
            local period = entry.period or 1
            local day = entry.dayInPeriod or 1
            local hour = entry.hour or 0
            local entryValue = entry.value or 0
            local displayEntry = {
                day = day,
                period = period,
                year = year,
                hour = hour,
                fillTypeName = entry.fillTypeName,
                fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(entry.fillTypeName),
                fillTypeTitle = g_fillTypeManager:getFillTypeTitleByIndex(g_fillTypeManager:getFillTypeIndexByName(entry.fillTypeName)) or entry.fillTypeName,
                amount = entry.amount,
                amountDisplay = string.format("%.0f L", entry.amount),
                value = entryValue,
                valueDisplay = entryValue > 0 and g_i18n:formatMoney(entryValue, 0, true) or "-",
                location = entry.location or "Unknown",
                -- Formatted datetime for display: YY-PP-DD HH:00
                dateTimeDisplay = string.format("%02d-%02d-%02d %02d:00", year, period, day, hour),
            }
            table.insert(recent, displayEntry)
            Log:trace("LOSS_LOG_ENTRY: Y%d P%d D%d H%d %s %.0fL at %s",
                year, period, day, hour,
                entry.fillTypeName, entry.amount, entry.location or "?")
            if #recent >= count then
                break
            end
        end
    end

    Log:debug("LOSS_LOG_RECENT: farm=%d -> %d entries (of %d total in log)",
        farmId, #recent, #log)

    return recent
end

--- Get loss statistics summary for display (farm-filtered)
--- @param farmId number The farm to filter by (REQUIRED)
--- @return table { totalExpired, todayExpired, thisMonthExpired, last12MonthsExpired, breakdown }
function RmFreshManager:getLossStatsSummary(farmId)
    local log = RmLossTracker.lossLog or {}

    -- Get current time info for period calculations
    local env = g_currentMission and g_currentMission.environment
    local currentYear = env and env.currentYear or 1
    local currentPeriod = env and env.currentPeriod or 1
    local currentDay = env and env.currentDayInPeriod or 1

    Log:debug("LOSS_STATS_TIME: gameDate=Y%d P%d D%d, logEntries=%d",
        currentYear, currentPeriod, currentDay, #log)

    -- farmId=0 means unowned (no farm) - return empty stats
    if farmId == nil or farmId == 0 then
        Log:trace("LOSS_STATS: farmId=%s, returning empty", tostring(farmId))
        return {
            totalExpired = 0,
            totalExpiredDisplay = "0 L",
            totalValue = 0,
            totalValueDisplay = "-",
            todayExpired = 0,
            todayExpiredDisplay = "0 L",
            todayValue = 0,
            todayValueDisplay = "-",
            thisMonthExpired = 0,
            thisMonthExpiredDisplay = "0 L",
            thisMonthValue = 0,
            thisMonthValueDisplay = "-",
            last12MonthsExpired = 0,
            last12MonthsExpiredDisplay = "0 L",
            last12MonthsValue = 0,
            last12MonthsValueDisplay = "-",
            breakdown = {},
            breakdownCount = 0,
        }
    end

    -- Calculate totals from lossLog (filtered by farm)
    local totalExpired = 0
    local todayExpired = 0
    local thisMonthExpired = 0
    local last12MonthsExpired = 0
    local totalValue = 0
    local todayValue = 0
    local thisMonthValue = 0
    local last12MonthsValue = 0
    local byFillType = {}
    local byFillTypeValue = {}

    for _, entry in ipairs(log) do
        if entry.farmId == farmId then
            local entryValue = entry.value or 0
            totalExpired = totalExpired + entry.amount
            totalValue = totalValue + entryValue

            -- Check if "today" (same year, period, day)
            if entry.year == currentYear and entry.period == currentPeriod and entry.dayInPeriod == currentDay then
                todayExpired = todayExpired + entry.amount
                todayValue = todayValue + entryValue
            end

            -- Check if "this month" (same year and period)
            if entry.year == currentYear and entry.period == currentPeriod then
                thisMonthExpired = thisMonthExpired + entry.amount
                thisMonthValue = thisMonthValue + entryValue
            end

            -- Check if "last 12 months" (within 12 periods rolling)
            -- Also aggregate by fillType for breakdown (last 12 months only)
            local periodsAgo = (currentYear - entry.year) * 12 + (currentPeriod - entry.period)
            if periodsAgo >= 0 and periodsAgo < 12 then
                last12MonthsExpired = last12MonthsExpired + entry.amount
                last12MonthsValue = last12MonthsValue + entryValue
                -- Aggregate by fillType (amount and value) - last 12 months only
                byFillType[entry.fillTypeName] = (byFillType[entry.fillTypeName] or 0) + entry.amount
                byFillTypeValue[entry.fillTypeName] = (byFillTypeValue[entry.fillTypeName] or 0) + entryValue
            end
        end
    end

    -- Build breakdown list (sorted by amount)
    local breakdown = {}
    for fillTypeName, amount in pairs(byFillType) do
        local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(fillTypeName)
        local value = byFillTypeValue[fillTypeName] or 0
        table.insert(breakdown, {
            fillTypeName = fillTypeName,
            fillTypeIndex = fillTypeIndex,
            fillTypeTitle = g_fillTypeManager:getFillTypeTitleByIndex(fillTypeIndex) or fillTypeName,
            amount = amount,
            amountDisplay = string.format("%.0f L", amount),
            value = value,
            valueDisplay = value > 0 and g_i18n:formatMoney(value, 0, true) or "-",
        })
    end
    table.sort(breakdown, function(a, b) return a.amount > b.amount end)

    Log:debug("LOSS_STATS: farm=%d -> total=%.0fL ($%.0f), today=%.0fL, month=%.0fL, 12mo=%.0fL, %d fillTypes",
        farmId, totalExpired, totalValue, todayExpired, thisMonthExpired, last12MonthsExpired, #breakdown)

    return {
        totalExpired = totalExpired,
        totalExpiredDisplay = string.format("%.0f L", totalExpired),
        totalValue = totalValue,
        totalValueDisplay = totalValue > 0 and g_i18n:formatMoney(totalValue, 0, true) or "-",
        todayExpired = todayExpired,
        todayExpiredDisplay = string.format("%.0f L", todayExpired),
        todayValue = todayValue,
        todayValueDisplay = todayValue > 0 and g_i18n:formatMoney(todayValue, 0, true) or "-",
        thisMonthExpired = thisMonthExpired,
        thisMonthExpiredDisplay = string.format("%.0f L", thisMonthExpired),
        thisMonthValue = thisMonthValue,
        thisMonthValueDisplay = thisMonthValue > 0 and g_i18n:formatMoney(thisMonthValue, 0, true) or "-",
        last12MonthsExpired = last12MonthsExpired,
        last12MonthsExpiredDisplay = string.format("%.0f L", last12MonthsExpired),
        last12MonthsValue = last12MonthsValue,
        last12MonthsValueDisplay = last12MonthsValue > 0 and g_i18n:formatMoney(last12MonthsValue, 0, true) or "-",
        breakdown = breakdown,
        breakdownCount = #breakdown,
    }
end

--- Reconcile a single container with game state
--- Compares tracked batch totals with actual fill levels and fixes drift
--- SERVER ONLY
--- Uses flat container.batches, single fillType per container
---@param containerId string Container ID
---@return table { skipped, added, removed } or nil if not found
function RmFreshManager:reconcileContainer(containerId)
    if g_server == nil then
        return { skipped = true, reason = "client" }
    end

    local container = self.containers[containerId]
    if not container then
        return nil
    end

    -- Test isolation: skip non-test containers when in test mode
    -- Belt-and-suspenders: check here in addition to reconcileAll()
    if not self:shouldProcessContainer(containerId) then
        return { skipped = true, reason = "test isolation", containerId = containerId }
    end

    -- Test containers have no runtimeEntity - skip reconciliation
    if container.runtimeEntity == nil then
        return { skipped = true, reason = "no runtimeEntity", containerId = containerId }
    end

    local adapter = self:getAdapterForType(container.entityType)
    if not adapter or not adapter.getFillLevel then
        return { skipped = true, reason = "no adapter", containerId = containerId }
    end

    -- Single fillType per container (flat batches at root)
    local trackedTotal = RmBatch.getTotalAmount(container.batches or {})

    -- Get actual fill level from game via adapter (pcall for safety)
    local ok, actualFill = pcall(function()
        return adapter:getFillLevel(containerId)
    end)

    -- Handle adapter errors gracefully
    if not ok or type(actualFill) ~= "number" then
        Log:trace("RECONCILE: container=%s - adapter error or non-numeric result", containerId)
        return { skipped = true, reason = "adapter error", containerId = containerId }
    end

    local delta = actualFill - trackedTotal
    local stats = {
        skipped = false,
        added = 0,
        removed = 0
    }

    -- Only reconcile if drift exceeds threshold
    if math.abs(delta) > self.RECONCILE_THRESHOLD then
        if delta > 0 then
            -- Under-tracked: add to newest batch or create new
            self:reconcileAdd(containerId, delta)
            stats.added = delta
        else
            -- Over-tracked: consume from batches
            self:reconcileRemove(containerId, -delta)
            stats.removed = -delta
        end

        Log:debug("RECONCILE: container=%s tracked=%.1f actual=%.1f added=%.1f removed=%.1f",
            containerId, trackedTotal, actualFill, stats.added, stats.removed)
    end

    return stats
end

--- Reconcile all containers
--- Iterates all containers and reconciles each with game state
--- SERVER ONLY
--- TEST ISOLATION: When testContainerPrefix is set, only processes matching containers
--- Uses suppressReconcileBroadcast to avoid spamming MP clients with updates
---@return table { containersProcessed, containersSkipped, totalAdded, totalRemoved }
function RmFreshManager:reconcileAll()
    if g_server == nil then
        return { containersProcessed = 0, containersSkipped = 0, totalAdded = 0, totalRemoved = 0 }
    end

    local stats = {
        containersProcessed = 0,
        containersSkipped = 0,
        totalAdded = 0,
        totalRemoved = 0
    }

    -- Suppress individual broadcasts during bulk reconcile
    self.suppressReconcileBroadcast = true
    local modifiedContainers = {}

    for containerId, _ in pairs(self.containers) do
        -- Test isolation: skip non-test containers when in test mode
        if self:shouldProcessContainer(containerId) then
            local containerStats = self:reconcileContainer(containerId)

            if containerStats then
                if containerStats.skipped then
                    stats.containersSkipped = stats.containersSkipped + 1
                else
                    stats.containersProcessed = stats.containersProcessed + 1
                    stats.totalAdded = stats.totalAdded + (containerStats.added or 0)
                    stats.totalRemoved = stats.totalRemoved + (containerStats.removed or 0)

                    -- Track modified containers for consolidated broadcast
                    if (containerStats.added or 0) > 0 or (containerStats.removed or 0) > 0 then
                        table.insert(modifiedContainers, containerId)
                    end
                end
            end
        end
    end

    -- Re-enable broadcasts
    self.suppressReconcileBroadcast = false

    -- Send consolidated broadcast for all modified containers
    for _, containerId in ipairs(modifiedContainers) do
        local container = self.containers[containerId]
        if container then
            -- Broadcast flat batches structure
            self:broadcastContainerUpdate(containerId, RmFreshUpdateEvent.OP_UPDATE, {
                batches = container.batches
            })
        end
    end

    Log:debug("RECONCILE_ALL: processed=%d skipped=%d added=%.1f removed=%.1f broadcast=%d",
        stats.containersProcessed, stats.containersSkipped, stats.totalAdded, stats.totalRemoved, #modifiedContainers)

    return stats
end

--- Helper: Add amount during reconciliation (under-tracked scenario)
--- Adds to newest batch or creates new batch with age 0
--- SERVER ONLY - internal helper
--- Respects suppressReconcileBroadcast flag during bulk operations
---@param containerId string Container ID
---@param amount number Amount to add
function RmFreshManager:reconcileAdd(containerId, amount)
    local container = self.containers[containerId]
    if not container then return end

    -- Flat batches at container root
    local batches = container.batches or {}

    if #batches > 0 then
        -- Add to newest batch (last in array - FIFO order means oldest first)
        local newest = batches[#batches]
        newest.amount = newest.amount + amount
    else
        -- No batches exist, create new with age 0
        table.insert(batches, RmBatch.create(amount, 0))
        container.batches = batches
    end

    -- Broadcast update (skip if suppressed during bulk reconcile)
    if not self.suppressReconcileBroadcast then
        self:broadcastContainerUpdate(containerId, RmFreshUpdateEvent.OP_UPDATE, {
            batches = container.batches
        })
    end

    Log:trace("RECONCILE_ADD: container=%s amount=%.1f batches=%d", containerId, amount, #container.batches)
end

--- Helper: Remove amount during reconciliation (over-tracked scenario)
--- Consumes FIFO from oldest batches
--- SERVER ONLY - internal helper
--- Respects suppressReconcileBroadcast flag during bulk operations
---@param containerId string Container ID
---@param amount number Amount to remove
function RmFreshManager:reconcileRemove(containerId, amount)
    local container = self.containers[containerId]
    if not container then return end

    -- Flat batches at container root
    if not container.batches then return end

    -- Use existing FIFO consumption
    RmBatch.consumeFIFO(container.batches, amount)

    -- Broadcast update (skip if suppressed during bulk reconcile)
    if not self.suppressReconcileBroadcast then
        self:broadcastContainerUpdate(containerId, RmFreshUpdateEvent.OP_UPDATE, {
            batches = container.batches
        })
    end

    Log:trace("RECONCILE_REMOVE: container=%s amount=%.1f batches=%d", containerId, amount, #container.batches)
end

-- =============================================================================
-- TRANSFER PENDING API
-- =============================================================================
-- These APIs enable age-preserving transfers between containers.
-- TransferCoordinator stages batches BEFORE superFunc, adapters consume them during fill.
--
-- USAGE FLOW:
-- 1. TransferCoordinator hooks transfer function BEFORE superFunc
-- 2. peekBatches(source) → preview what batches would transfer
-- 3. setTransferPending(destination, batches) → stage them for destination
-- 4. superFunc executes the actual transfer
-- 5. Destination adapter's fill callback calls getTransferPending()
-- 6. If pending → use those batches (preserves ages)
-- 7. If no pending → create fresh batch (age=0) - normal flow
-- =============================================================================

--- Set pending batches for an incoming transfer
--- Called by TransferCoordinator BEFORE superFunc to stage source batches
--- Adapters check for pending during fill increase to use transferred ages
---@param containerId string Destination container ID
---@param batches table Array of batch objects { amount, age }
function RmFreshManager:setTransferPending(containerId, batches)
    if not containerId or not batches then return end

    self.transferPending[containerId] = {
        batches = batches,
        timestamp = g_time
    }

    Log:debug("TRANSFER_PENDING_SET: containerId=%s batches=%d",
        containerId, #batches)
end

--- Get and clear pending batches for a container
--- Called by adapter onFillChanged when fill increases
--- Returns batches AND clears the entry (one-time retrieval)
---@param containerId string Container ID
---@return table|nil batches Array of { amount, age } or nil if no pending
function RmFreshManager:getTransferPending(containerId)
    if not containerId then return nil end

    local pending = self.transferPending[containerId]
    if pending then
        self.transferPending[containerId] = nil
        Log:debug("TRANSFER_PENDING_USED: containerId=%s batches=%d",
            containerId, #pending.batches)
        return pending.batches
    end
    return nil
end

--- Peek batches from a container (FIFO preview, does NOT consume)
--- Used by TransferCoordinator to preview what batches would be transferred
--- CRITICAL: Does not modify container.batches - just returns a preview
---@param containerId string Source container ID
---@param amount number Amount to peek
---@return table { batches = {...}, totalAmount = N }
function RmFreshManager:peekBatches(containerId, amount)
    if not containerId or not amount then
        return { batches = {}, totalAmount = 0 }
    end

    local container = self:getContainer(containerId)
    if not container or not container.batches then
        return { batches = {}, totalAmount = 0 }
    end

    local peeked = {}
    local remaining = amount

    for _, batch in ipairs(container.batches) do
        if remaining <= 0 then break end

        local peekAmount = math.min(batch.amount, remaining)
        table.insert(peeked, {
            amount = peekAmount,
            age = batch.ageInPeriods -- Use ageInPeriods for consistency with batch structure
        })
        remaining = remaining - peekAmount
    end

    Log:trace("PEEK_BATCHES: containerId=%s requested=%.1f peeked=%d batches totalAmount=%.1f",
        containerId, amount, #peeked, amount - remaining)

    return {
        batches = peeked,
        totalAmount = amount - remaining
    }
end

-- =============================================================================
-- TRANSFER PENDING BY FILLTYPE
-- =============================================================================
-- FALLBACK for physics-based transfers where Dischargeable.dischargeToObject
-- is not called (pallets tipping, some trailer dumps, FillVolume-based paths).
--
-- When source loses fill, we stage by fillType. When destination gains fill,
-- we check containerId first (TransferCoordinator), then fillType as fallback.
-- =============================================================================

--- Set pending batches by fillType (fallback staging)
--- Called from onFillChanged when source loses fill (delta < 0)
--- Allows destination to retrieve by fillType if containerId staging wasn't done
---@param fillType number Fill type index
---@param batches table Array of batch objects { amount, age }
function RmFreshManager:setTransferPendingByFillType(fillType, batches)
    if not fillType or not batches or #batches == 0 then return end

    self.transferPendingByFillType[fillType] = {
        batches = batches,
        timestamp = g_time
    }

    Log:debug("TRANSFER_PENDING_FILLTYPE_SET: fillType=%d batches=%d",
        fillType, #batches)
end

--- Get and clear pending batches by fillType (fallback retrieval)
--- Called after containerId check fails - uses fillType correlation
--- Returns batches AND clears the entry (one-time retrieval)
--- Has short TTL (2 seconds) to avoid stale data from previous transfers
---@param fillType number Fill type index
---@return table|nil batches Array of { amount, age } or nil if no pending
function RmFreshManager:getTransferPendingByFillType(fillType)
    if not fillType then return nil end

    local pending = self.transferPendingByFillType[fillType]
    if pending then
        -- Check TTL: expire after 2 seconds to avoid stale correlations
        local age = g_time - pending.timestamp
        if age > 2000 then
            Log:trace("TRANSFER_PENDING_FILLTYPE_EXPIRED: fillType=%d age=%dms (TTL=2000ms)",
                fillType, age)
            self.transferPendingByFillType[fillType] = nil
            return nil
        end

        self.transferPendingByFillType[fillType] = nil
        Log:debug("TRANSFER_PENDING_FILLTYPE_USED: fillType=%d batches=%d age=%dms",
            fillType, #pending.batches, age)
        return pending.batches
    end
    return nil
end

-- =============================================================================
-- BULK TRANSFER MODE (Production Points)
-- =============================================================================
-- ProductionChainManager:distributeGoods() performs multiple transfers in a loop.
-- Each transfer is ADD (destination) then REMOVE (source) within a single frame.
-- Bulk mode queues ADDs, matches them to REMOVEs, and applies batch arrays (FIFO).
-- Key insight: Use batch arrays, NOT weighted average, to preserve FIFO ordering.
-- =============================================================================

--- Begin bulk transfer mode
--- Called by ProductionChainManager hook BEFORE distributeGoods() loop
--- SERVER ONLY - production distribution is server-authoritative
function RmFreshManager:beginBulkTransfer()
    if g_server == nil then return end

    Log:trace(">>> beginBulkTransfer()")
    self.bulkTransfer = {
        active = true,
        pending = {}, -- fillType → array of {containerId, amount, batches, isAdd, matched}
    }
end

--- End bulk transfer mode
--- Called by ProductionChainManager hook AFTER distributeGoods() loop
--- Handles unmatched ADDs by creating fresh batches (production output with no source)
--- SERVER ONLY
function RmFreshManager:endBulkTransfer()
    if g_server == nil then return end

    Log:trace(">>> endBulkTransfer()")

    if not self.bulkTransfer then
        Log:trace("<<< endBulkTransfer (not active)")
        return
    end

    -- Handle unmatched ADDs (create fresh batches)
    for fillType, entries in pairs(self.bulkTransfer.pending) do
        for _, entry in ipairs(entries) do
            if entry.isAdd and not entry.matched then
                local fillTypeName = g_fillTypeManager:getFillTypeNameByIndex(fillType)
                Log:warning("BULK_UNMATCHED: %s +%.1f had no matching REMOVE, creating fresh",
                    fillTypeName, entry.amount)
                self:addBatch(entry.containerId, entry.amount, 0)
            end
        end
    end

    self.bulkTransfer = nil
    Log:trace("<<< endBulkTransfer()")
end

--- Handle fill change during bulk transfer mode
--- Queues ADDs, matches REMOVEs to queued ADDs, applies batch arrays
--- SERVER ONLY
---@param containerId string Container ID
---@param delta number Change in fill level (positive = add, negative = consume)
---@param fillType number Fill type index
---@return boolean handled True if handled by bulk mode, false to continue normal flow
function RmFreshManager:handleBulkTransferFillChange(containerId, delta, fillType)
    if not self.bulkTransfer or not self.bulkTransfer.active then
        return false
    end

    local fillTypeName = g_fillTypeManager:getFillTypeNameByIndex(fillType)
    Log:trace(">>> handleBulkTransferFillChange(container=%s, delta=%+.1f, ft=%s)",
        containerId, delta, fillTypeName)

    -- Initialize pending array for this fillType
    if not self.bulkTransfer.pending[fillType] then
        self.bulkTransfer.pending[fillType] = {}
    end
    local pending = self.bulkTransfer.pending[fillType]

    if delta > 0 then
        -- ADD: Queue it, wait for matching REMOVE
        table.insert(pending, {
            containerId = containerId,
            amount = delta,
            batches = nil,
            isAdd = true,
            matched = false,
        })
        Log:trace("    queued ADD: container=%s, amount=%.1f", containerId, delta)
    else
        -- REMOVE: Consume batches, find matching ADD, apply batch array
        local consumeAmount = math.abs(delta)
        local result = self:consumeBatches(containerId, consumeAmount)
        local consumedBatches = result.batches

        Log:trace("    REMOVE consumed %d batches from %s", #consumedBatches, containerId)

        -- Find matching ADD (same fillType, similar amount, unmatched)
        local tolerance = consumeAmount * 0.01 -- 1% tolerance
        local matched = false

        for _, entry in ipairs(pending) do
            if entry.isAdd and not entry.matched then
                if math.abs(entry.amount - consumeAmount) <= tolerance then
                    Log:debug("BULK_MATCH: %s +%.1f matched REMOVE -%.1f, applying %d batches",
                        fillTypeName, entry.amount, consumeAmount, #consumedBatches)

                    -- Apply source's batch array to destination (preserves FIFO)
                    for _, batch in ipairs(consumedBatches) do
                        self:addBatch(entry.containerId, batch.amount, batch.ageInPeriods)
                    end

                    entry.matched = true
                    matched = true
                    break
                end
            end
        end

        if not matched then
            -- Queue REMOVE for potential later ADD (handles REMOVE→ADD order)
            table.insert(pending, {
                containerId = containerId,
                amount = consumeAmount,
                batches = consumedBatches,
                isAdd = false,
                matched = false,
            })
            Log:trace("    queued REMOVE (no matching ADD yet)")
        end
    end

    Log:trace("<<< handleBulkTransferFillChange = true")
    return true
end
