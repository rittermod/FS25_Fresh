-- RmBaleAdapter.lua
-- Purpose: Thin bale adapter - bridges FS25 bale events to centralized FreshManager
-- Author: Ritter
-- Architecture: Hook-based pattern (bales aren't registered with SpecializationManager)

RmBaleAdapter = {}
RmBaleAdapter.ENTITY_TYPE = "bale"
RmBaleAdapter.SPEC_TABLE_NAME = ("spec_%s.rmBaleAdapter"):format(g_currentModName)

local Log = RmLogging.getLogger("Fresh")

--- Wrap hook callbacks in pcall to prevent breaking base game methods
local function safeHook(fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then
            Log:error("BALE_ADAPTER hook error: %s", tostring(err))
        end
    end
end

-- =============================================================================
-- IDENTITY
-- =============================================================================

function RmBaleAdapter:getEntityId(bale)
    return bale.uniqueId -- FS25's stable uniqueId
end

--- Detect if bale is currently fermenting (wrapped but not complete)
--- Uses FS25's built-in Bale:getIsFermenting() which handles all edge cases
function RmBaleAdapter:isFermenting(bale)
    if bale == nil then return false end
    if bale.getIsFermenting == nil then return false end -- Safety check
    return bale:getIsFermenting()
end

--- Determine if bale should age (non-fermenting bales age)
--- Fermenting bales are excluded from aging until fermentation completes
---@param bale table Bale entity
---@return boolean True if bale should age, false if fermenting
function RmBaleAdapter:shouldAge(bale)
    return not self:isFermenting(bale)
end

--- Build identity structure for a bale
--- Called during registration to create identityMatch for Manager
---@param bale table Bale entity
---@param fillTypeOverride number|nil Fill type index (for prepended hooks where bale.fillType not set)
---@param fillLevelOverride number|nil Fill level (for prepended hooks where bale.fillLevel not set)
---@return table identityMatch structure for registerContainer
function RmBaleAdapter:buildIdentityMatch(bale, fillTypeOverride, fillLevelOverride)
    -- Use overrides when provided (critical for savegame load where bale properties aren't set yet)
    local fillType = fillTypeOverride or bale.fillType
    local fillLevel = fillLevelOverride or bale.fillLevel or 0
    local fillTypeName = g_fillTypeManager:getFillTypeNameByIndex(fillType)

    Log:trace("BALE_BUILD_IDENTITY: uniqueId=%s fillType=%s amount=%.1f (override=%s)",
        bale.uniqueId or "?", fillTypeName or "?", fillLevel, tostring(fillTypeOverride ~= nil))

    return {
        worldObject = {
            uniqueId = bale.uniqueId,
        },
        storage = {
            fillTypeName = fillTypeName,
            amount = fillLevel,
        },
    }
end

-- =============================================================================
-- FILL LEVEL MANIPULATION (for console commands)
-- Uses containerId as identifier - adapter resolves entity internally
-- =============================================================================

--- Get fill level for a container by containerId
---@param containerId string Container ID
---@return number fillLevel Current fill level
---@return number fillType Fill type index
function RmBaleAdapter:getFillLevel(containerId)
    local container = RmFreshManager:getContainer(containerId)
    if not container then return 0, 0 end

    local bale = container.runtimeEntity
    if not bale then return 0, 0 end

    return bale.fillLevel or 0, bale.fillType or 0
end

--- Add fill level for a container by containerId
---@param containerId string Container ID
---@param delta number Amount to add (negative to remove)
---@return boolean success True if fill was modified
function RmBaleAdapter:addFillLevel(containerId, delta)
    local container = RmFreshManager:getContainer(containerId)
    if not container then return false end

    local bale = container.runtimeEntity
    if not bale then return false end
    if bale.setFillLevel == nil then return false end -- Handle mock entities in tests

    local newLevel = (bale.fillLevel or 0) + delta
    bale:setFillLevel(math.max(0, newLevel))
    return true
end

--- Set fill level for a container by containerId
---@param containerId string Container ID
---@param level number Target fill level
---@return boolean success True if fill was modified
function RmBaleAdapter:setFillLevel(containerId, level)
    local container = RmFreshManager:getContainer(containerId)
    if not container then return false end

    local bale = container.runtimeEntity
    if not bale then return false end
    if bale.setFillLevel == nil then return false end -- Handle mock entities in tests

    bale:setFillLevel(level)
    return true
end

-- =============================================================================
-- LOOKUP API
-- =============================================================================

--- Get containerId for a bale
--- Used by TransferCoordinator to resolve source containers
--- NETWORK SAFE: Works on both server and client (uses synced spec.containerId)
---@param bale table Bale entity
---@return string|nil containerId or nil if not registered
function RmBaleAdapter:getContainerIdForBale(bale)
    if not bale then
        Log:trace("BALE_LOOKUP: bale=nil -> nil")
        return nil
    end

    local spec = bale[RmBaleAdapter.SPEC_TABLE_NAME]
    if not spec then
        Log:trace("BALE_LOOKUP: uniqueId=%s -> nil (no spec)",
            tostring(bale.uniqueId))
        return nil
    end

    local containerId = spec.containerId

    Log:trace("BALE_LOOKUP: uniqueId=%s -> containerId=%s",
        tostring(bale.uniqueId), containerId or "nil")

    return containerId
end

--- Called when container becomes empty after expiration
--- Bales should be deleted when empty (unlike vehicles which just stay empty)
---@param containerId string Container ID
function RmBaleAdapter:onContainerEmpty(containerId)
    local container = RmFreshManager:getContainer(containerId)
    if not container then return end

    local bale = container.runtimeEntity
    if not bale then return end

    Log:info("BALE_EXPIRED_DELETE: %s uniqueId=%s removed (empty after expiration)",
        containerId, tostring(bale.uniqueId or "unknown"))

    -- Unregister from Manager first
    RmFreshManager:unregisterContainer(containerId)

    -- Then delete the game entity
    bale:delete()
end

-- =============================================================================
-- FILL LEVEL HOOK (overwrittenFunction pattern)
-- =============================================================================

--- Hook for Bale.setFillLevel - captures delta and reports to Manager
--- CRITICAL: Calls superFunc FIRST for game stability, then wraps our logic in pcall
--- Handles two scenarios:
---   1. New bale (not registered) → delegate to onFillLevelSet for registration
---   2. Existing bale (registered) → calculate delta and report to Manager
---@param bale table Bale entity
---@param superFunc function Original setFillLevel function
---@param newFillLevel number New fill level to set
---@param ... any Additional arguments passed to setFillLevel
function RmBaleAdapter.setFillLevelHook(bale, superFunc, newFillLevel, ...)
    -- Capture BEFORE state (safe - just reading)
    local oldFillLevel = bale.fillLevel or 0
    local fillType = bale.fillType

    -- CRITICAL: Call original function FIRST - game MUST work even if we error
    superFunc(bale, newFillLevel, ...)

    -- Now wrap OUR logic in pcall for safety
    local ok, err = pcall(function()
        -- Server-only processing
        if g_server == nil then return end

        -- Skip if loading from savegame (applyBaleAttributes handles this)
        if bale._rmFreshLoading then return end

        local spec = bale[RmBaleAdapter.SPEC_TABLE_NAME]

        -- Not registered yet = new bale creation, delegate to onFillLevelSet
        if not spec or not spec.containerId then
            RmBaleAdapter.onFillLevelSet(bale, newFillLevel)
            return
        end

        -- Already registered: report delta to Manager
        local delta = newFillLevel - oldFillLevel
        if delta == 0 then return end

        -- Skip delta if container was just reconciled (already has batches)
        -- This is a safety check - _rmFreshLoading should already prevent this for savegame loads
        if spec.wasReconciled then
            spec.wasReconciled = nil -- Clear flag after first check
            Log:trace("BALE_FILL_CHANGED: %s skipped (wasReconciled)", spec.containerId)
            return
        end

        RmFreshManager:onFillChanged(spec.containerId, 1, delta, fillType)
        Log:trace("BALE_FILL_CHANGED: %s delta=%+.1f ft=%d", spec.containerId, delta, fillType)
    end)

    if not ok then
        -- Enhanced error logging with context per code review recommendation
        local spec = bale[RmBaleAdapter.SPEC_TABLE_NAME]
        local containerId = spec and spec.containerId or "unregistered"
        local uniqueId = bale.uniqueId or "unknown"
        local delta = newFillLevel - oldFillLevel
        Log:error("BALE_ADAPTER setFillLevelHook error: container=%s uniqueId=%s delta=%.1f err=%s",
            tostring(containerId), tostring(uniqueId), delta, tostring(err))
    end
end

-- =============================================================================
-- HOOK INSTALLATION
-- =============================================================================

function RmBaleAdapter.install()
    -- Hook Bale.setFillLevel for new bale registration AND fill change tracking
    -- Uses overwrittenFunction to capture old fill level BEFORE original executes
    -- NOTE: Do NOT wrap entire hook in safeHook - superFunc must always run
    Bale.setFillLevel = Utils.overwrittenFunction(
        Bale.setFillLevel,
        RmBaleAdapter.setFillLevelHook
    )

    -- Hook Bale.applyBaleAttributes for savegame loading
    -- Called BEFORE setFillLevel during savegame restore
    -- CRITICAL: Pass attributes.fillType AND attributes.fillLevel because bale properties are NOT SET YET!
    Bale.applyBaleAttributes = Utils.prependedFunction(Bale.applyBaleAttributes, safeHook(function(bale, attributes)
        bale._rmFreshLoading = true -- Prevent double-registration
        local fillType = attributes and attributes.fillType or nil
        local fillLevel = attributes and attributes.fillLevel or nil
        RmBaleAdapter.onLoadHook(bale, fillType, fillLevel)
    end))

    -- Hook Bale.delete for cleanup before deletion
    Bale.delete = Utils.prependedFunction(Bale.delete, safeHook(function(bale)
        RmBaleAdapter.onDeleteHook(bale)
    end))

    -- Hook Bale.setWrappingState for wrapper wrap detection
    -- Uses appendedFunction because we just need to update tracking AFTER game processes wrapping
    --
    -- TIMING NOTE: Hook fires AFTER the game method executes.
    -- If wrapping happens during active aging simulation, shouldAge check may
    -- use old fermenting flag until next frame. This is acceptable because:
    -- 1. Wrapping is rare mid-simulation (user action, not automated)
    -- 2. One-frame delay is negligible for aging calculations
    -- 3. Next aging cycle will use correct flag
    Bale.setWrappingState = Utils.appendedFunction(
        Bale.setWrappingState,
        safeHook(function(bale, wrappingState, updateFermentation)
            RmBaleAdapter.onWrappingStateChanged(bale, wrappingState)
        end)
    )

    -- Hook Bale.showInfo for HUD display
    -- Uses appendedFunction - we add info AFTER game's showInfo runs
    Bale.showInfo = Utils.appendedFunction(
        Bale.showInfo,
        safeHook(function(bale, box)
            RmBaleAdapter.showInfoHook(bale, box)
        end)
    )

    -- Hook Bale.writeStream for MP sync (server → client on join)
    -- Appends containerId after game's bale data so client can set up spec table
    -- CRITICAL: Bales don't use NetworkUtil like vehicles - they have their own stream
    Bale.writeStream = Utils.appendedFunction(
        Bale.writeStream,
        safeHook(function(bale, streamId, connection)
            RmBaleAdapter.writeStreamHook(bale, streamId, connection)
        end)
    )

    -- Hook Bale.readStream for MP sync (client receives from server)
    -- Reads containerId and sets up spec table on client for display hooks
    Bale.readStream = Utils.appendedFunction(
        Bale.readStream,
        safeHook(function(bale, streamId, connection)
            RmBaleAdapter.readStreamHook(bale, streamId, connection)
        end)
    )

    -- Register adapter with Manager
    RmFreshManager:registerAdapter(RmBaleAdapter.ENTITY_TYPE, RmBaleAdapter)

    Log:info("BALE_ADAPTER: Hooks installed")
end

--- Rescan all bales for newly-perishable fill types
--- Called when settings change makes a fillType perishable
---@return number count Number of new containers registered
function RmBaleAdapter.rescanForPerishables()
    if not g_baleManager or not g_baleManager.bales then return 0 end

    Log:trace(">>> RmBaleAdapter.rescanForPerishables()")
    local count = 0

    for _, bale in ipairs(g_baleManager.bales) do
        -- Check if already registered (has spec with containerId)
        local spec = bale[RmBaleAdapter.SPEC_TABLE_NAME]
        if not spec or not spec.containerId then
            -- Not registered - check if now perishable
            local fillType = bale.fillType
            if fillType and RmFreshSettings:isPerishableByIndex(fillType) then
                local entityId = bale.uniqueId
                if entityId and entityId ~= "" then
                    local fermenting = RmBaleAdapter:isFermenting(bale)
                    RmBaleAdapter.doRegistration(bale, entityId, fermenting)
                    count = count + 1

                    Log:debug("RESCAN_BALE: uniqueId=%s fillType=%d fermenting=%s",
                        entityId, fillType, tostring(fermenting))
                end
            end
        end
    end

    Log:trace("<<< RmBaleAdapter.rescanForPerishables = %d", count)
    return count
end

-- =============================================================================
-- LIFECYCLE HOOKS
-- =============================================================================

--- Called when bale fill level is set (new bale creation)
function RmBaleAdapter.onFillLevelSet(bale, fillLevel)
    if g_server == nil then return end -- Server only

    -- Skip if already registered
    local spec = bale[RmBaleAdapter.SPEC_TABLE_NAME]
    if spec and spec.containerId then return end

    -- Skip non-perishable fill types
    if not RmFreshSettings:isPerishableByIndex(bale.fillType) then return end

    -- Check if uniqueId is available (testing if deferred registration is needed)
    local entityId = bale.uniqueId
    if entityId == nil or entityId == "" then
        -- Log warning to test if this ever happens - if it does, we need deferred registration
        Log:warning("uniqueId is nil on setFillLevel hook - deferred registration may be needed")
        return
    end

    -- Detect fermentation state using helper
    local fermenting = RmBaleAdapter:isFermenting(bale)
    RmBaleAdapter.doRegistration(bale, entityId, fermenting)
end

--- Called when loading bale from savegame
--- @param bale table Bale entity
--- @param fillTypeOverride number|nil Fill type from attributes (use instead of bale.fillType at prepended time)
--- @param fillLevelOverride number|nil Fill level from attributes (use instead of bale.fillLevel at prepended time)
function RmBaleAdapter.onLoadHook(bale, fillTypeOverride, fillLevelOverride)
    if g_server == nil then return end -- Server only

    -- Skip if already registered
    local spec = bale[RmBaleAdapter.SPEC_TABLE_NAME]
    if spec and spec.containerId then return end

    -- Use override if provided (from attributes), otherwise fall back to bale.fillType
    -- CRITICAL: At prepended time, bale.fillType may be stale/wrong - use attributes.fillType!
    local fillType = fillTypeOverride or bale.fillType

    -- Skip non-perishable fill types
    if not RmFreshSettings:isPerishableByIndex(fillType) then return end

    -- Check if uniqueId is available (testing if deferred registration is needed)
    local entityId = bale.uniqueId
    if entityId == nil or entityId == "" then
        -- Log warning to test if this ever happens - if it does, we need deferred registration
        Log:warning("uniqueId is nil on applyBaleAttributes hook - deferred registration may be needed")
        return
    end

    -- DON'T check fermenting here - prepended hook runs before game sets fermentation values
    -- Pass nil so doRegistration won't override saved metadata.fermenting during reconciliation
    -- The saved value persists; onWrappingStateChanged updates if wrapping changes later
    -- Pass fillType and fillLevel overrides for correct reconciliation matching
    RmBaleAdapter.doRegistration(bale, entityId, nil, fillTypeOverride, fillLevelOverride)
end

--- Perform actual container registration
--- @param bale table Bale entity
--- @param entityId string Entity's uniqueId
--- @param fermenting boolean|nil Fermenting state (nil = don't set, preserve saved value)
--- @param fillTypeOverride number|nil Fill type (for prepended hooks where bale.fillType not set)
--- @param fillLevelOverride number|nil Fill level (for prepended hooks where bale.fillLevel not set)
function RmBaleAdapter.doRegistration(bale, entityId, fermenting, fillTypeOverride, fillLevelOverride)
    local spec = bale[RmBaleAdapter.SPEC_TABLE_NAME]
    if spec and spec.containerId then return end -- Already registered

    -- Build identity structure (pass overrides for savegame load timing)
    local identityMatch = RmBaleAdapter:buildIdentityMatch(bale, fillTypeOverride, fillLevelOverride)

    -- Build metadata - only include fermenting if explicitly set (not nil)
    -- This allows saved metadata.fermenting to persist during reconciliation
    -- NOTE: farmId may be 0 at registration time (bale ownership set later by game)
    -- RmLossTracker:recordExpiration() captures live farmId at expiration time
    local baleFarmId = nil
    if bale.getOwnerFarmId then
        baleFarmId = bale:getOwnerFarmId()
    end
    if (not baleFarmId or baleFarmId == 0) and bale.getBaleAttributes then
        local attrs = bale:getBaleAttributes()
        if attrs and attrs.farmId then
            baleFarmId = attrs.farmId
        end
    end
    if not baleFarmId or baleFarmId == 0 then
        baleFarmId = g_currentMission:getFarmId()
    end
    local metadata = {
        location = "Bale",
        farmId = baleFarmId
    }
    if fermenting ~= nil then
        metadata.fermenting = fermenting
    end

    -- registerContainer(entityType, identityMatch, runtimeEntity, metadata)
    -- Returns: (containerId, wasReconciled)
    local containerId, wasReconciled = RmFreshManager:registerContainer(
        "bale",
        identityMatch,
        bale,
        metadata
    )

    -- Store spec - fermenting may be nil for savegame load (will check at display time)
    -- wasReconciled: true if container matched from save (already has batches)
    bale[RmBaleAdapter.SPEC_TABLE_NAME] = {
        containerId = containerId,
        fermenting = fermenting,      -- nil is ok, showInfoHook uses isFermenting() anyway
        wasReconciled = wasReconciled -- Track for batch creation decision
    }

    Log:debug("BALE_REGISTERED: uniqueId=%s containerId=%s fillType=%s reconciled=%s",
        entityId, containerId, identityMatch.storage.fillTypeName, tostring(wasReconciled))

    -- Create initial batch for NEW containers only (not reconciled from save)
    -- Reconciled containers already have batches from saved data
    -- Use fillLevelOverride if provided (prepended hook), otherwise bale.fillLevel
    local fillLevel = fillLevelOverride or bale.fillLevel
    if not wasReconciled and fillLevel and fillLevel > 0 then
        RmFreshManager:addBatch(containerId, fillLevel, 0)
        Log:debug("BALE_INITIAL_BATCH: %s amount=%.1f age=0", containerId, fillLevel)
    end
end

--- Called when bale is about to be deleted
--- TRANSFER FIX v2: Stage batches and apply amount-based retroactive correction
--- This enables age preservation for bale→placeable and bale→husbandry transfers
--- where FS25 deletes the bale WITHOUT calling setFillLevel() first
---
--- v2 FIX: Uses amount-based split correction to only correct the transferred amount,
--- preserving any original fresh content already in the destination.
---
--- For ObjectStorage: No conflict - ObjectStorage captures batches BEFORE this hook runs
--- For manual deletion: Batches staged but unused (overwritten by next transfer)
--- For expiration: No batches left (consumed by expiration), nothing to stage
function RmBaleAdapter.onDeleteHook(bale)
    if g_server == nil then return end -- Server only

    local spec = bale[RmBaleAdapter.SPEC_TABLE_NAME]
    if not spec or not spec.containerId then return end

    local containerId = spec.containerId
    local container = RmFreshManager:getContainer(containerId)

    if container then
        local batches = container.batches
        local fillType = container.fillTypeIndex

        -- Only stage if bale has batches AND fillType (avoids empty/expired bales)
        if batches and #batches > 0 and fillType then
            -- Build batch list for staging and calculate total transferred amount
            local batchesToStage = {}
            local transferredAmount = 0
            for _, batch in ipairs(batches) do
                table.insert(batchesToStage, { amount = batch.amount, age = batch.ageInPeriods })
                transferredAmount = transferredAmount + batch.amount
            end

            -- Stage by fillType for destination fallback
            RmFreshManager:setTransferPendingByFillType(fillType, batchesToStage)

            -- Check for retroactive correction (destination already received fill)
            local correction = RmFreshManager.pendingCorrection[fillType]
            if correction and correction.containerId ~= containerId then
                local timeDiff = (g_time or 0) - correction.timestamp
                -- Extended window for bale transfers (700ms+ based on log analysis)
                if timeDiff < 1000 then
                    local destContainer = RmFreshManager:getContainer(correction.containerId)
                    if destContainer and destContainer.batches and #destContainer.batches > 0 then
                        -- v2: Amount-based correction - only correct transferredAmount worth
                        -- This preserves original fresh content in destination
                        local sourceAge = batchesToStage[1].age
                        local remainingToCorrect = transferredAmount
                        local correctedTotal = 0

                        -- Process batches in reverse order (most recent first)
                        for i = #destContainer.batches, 1, -1 do
                            if remainingToCorrect <= 0 then break end

                            local destBatch = destContainer.batches[i]
                            if destBatch.ageInPeriods == 0 then
                                if destBatch.amount <= remainingToCorrect then
                                    -- Entire batch was from bale transfer
                                    destBatch.ageInPeriods = sourceAge
                                    correctedTotal = correctedTotal + destBatch.amount
                                    remainingToCorrect = remainingToCorrect - destBatch.amount
                                else
                                    -- Split: part from bale, part original fresh
                                    local fromBale = remainingToCorrect
                                    destBatch.amount = destBatch.amount - fromBale

                                    -- Insert new batch for transferred amount
                                    table.insert(destContainer.batches, {
                                        amount = fromBale,
                                        ageInPeriods = sourceAge
                                    })
                                    correctedTotal = correctedTotal + fromBale
                                    remainingToCorrect = 0
                                end
                            end
                        end

                        if correctedTotal > 0 then
                            -- Re-merge after correction
                            RmBatch.mergeSimilarBatches(destContainer.batches, RmFreshSettings.MERGE_THRESHOLD)

                            Log:debug("BALE_DELETE_CORRECTION: dest=%s corrected=%.1f/%.1f age→%.4f",
                                correction.containerId, correctedTotal, transferredAmount, sourceAge)

                            -- Broadcast update to clients
                            RmFreshManager:broadcastContainerUpdate(correction.containerId,
                                RmFreshUpdateEvent.OP_UPDATE, destContainer)
                        end
                    end
                end
                RmFreshManager.pendingCorrection[fillType] = nil
            end

            Log:debug("BALE_DELETE_STAGED: containerId=%s fillType=%d batches=%d amount=%.1f",
                containerId, fillType, #batchesToStage, transferredAmount)
        end
    end

    -- Unregister (original behavior)
    if RmFreshManager then
        RmFreshManager:unregisterContainer(containerId)
        Log:debug("BALE_DELETE: containerId=%s", containerId)
    else
        Log:warning("BALE_DELETE: Manager unavailable, orphaning container %s", containerId)
    end
end

--- Called when bale wrapping state changes
--- Updates spec.fermenting flag when wrapper wraps an existing bale
--- This handles the case where a baler creates unwrapped bale, then wrapper wraps it later
---
--- DUAL-TRACKING PATTERN: Both spec.fermenting and container.metadata.fermenting are updated.
--- - spec.fermenting: Source of truth on entity, used by shouldAge() for live bale checks
--- - container.metadata.fermenting: Mirror in Manager container, used when accessing
---   container data without entity reference (e.g., console inspect, save/load)
--- Keeping both in sync ensures consistent behavior regardless of access path.
---
---@param bale table Bale entity
---@param wrappingState number New wrapping state (0=unwrapped, 1=wrapped)
function RmBaleAdapter.onWrappingStateChanged(bale, wrappingState)
    if g_server == nil then return end -- Server only

    local spec = bale[RmBaleAdapter.SPEC_TABLE_NAME]
    if not spec or not spec.containerId then return end -- Not tracked

    -- Check if fermentation state changed
    local wasFermenting = spec.fermenting or false
    local nowFermenting = RmBaleAdapter:isFermenting(bale)

    if wasFermenting ~= nowFermenting then
        spec.fermenting = nowFermenting

        -- Update container metadata in Manager (mirror for container-level access)
        local container = RmFreshManager:getContainer(spec.containerId)
        if container and container.metadata then
            container.metadata.fermenting = nowFermenting
        end

        Log:debug("BALE_WRAP_STATE: %s fermenting=%s->%s wrappingState=%.2f",
            spec.containerId, tostring(wasFermenting), tostring(nowFermenting), wrappingState)
    end
end

-- =============================================================================
-- DISPLAY HOOK
-- =============================================================================

--- Show freshness/fermentation status in bale HUD info
--- Appended to Bale.showInfo - runs AFTER game's display
--- NO server guard needed - display runs on all machines
--- NETWORK SAFE: Uses entity reference lookup (works on server and client)
---@param bale table Bale entity
---@param box table InfoBox for adding lines
function RmBaleAdapter.showInfoHook(bale, box)
    -- Use entity reference lookup (works on both server and client)
    local containerId = RmFreshManager:getContainerIdByEntity(bale)
    if not containerId then
        Log:trace("BALE_SHOW_INFO: no containerId for bale (not tracked or non-perishable)")
        return
    end

    -- Fermenting bales: skip display (base game shows fermentation %)
    if RmBaleAdapter:isFermenting(bale) then
        Log:trace("BALE_SHOW_INFO: %s fermenting, skipping display", containerId)
        return
    end

    -- Non-fermenting: show expires-in, add warning line if near expiration
    local info = RmFreshManager:getDisplayInfo(containerId)
    if info then
        Log:trace("BALE_SHOW_INFO: %s displaying '%s'", containerId, info.text)
        box:addLine(g_i18n:getText("fresh_expires_in"), info.text)
        if info.isWarning then
            box:addLine(g_i18n:getText("fresh_near_expiration"), nil, true)
        end
    else
        Log:trace("BALE_SHOW_INFO: %s no display info from Manager", containerId)
    end

    -- Draw age distribution display (if enabled)
    if RmFreshAgeDisplay and RmFreshAgeDisplay.drawForBale then
        RmFreshAgeDisplay.drawForBale(bale)
    end
end

-- =============================================================================
-- MULTIPLAYER STREAM HOOKS
-- =============================================================================
-- Bales use their own writeStream/readStream for MP sync, NOT NetworkUtil.
-- We piggyback on this stream to sync containerId to clients.
-- Adapter handles stream format, Manager owns data.

--- Server → Client: Write containerId to stream
---@param bale table Bale entity
---@param streamId number Network stream ID
---@param connection table Network connection
function RmBaleAdapter.writeStreamHook(bale, streamId, connection)
    -- Get containerId from Manager (single source of truth)
    local containerId = RmFreshManager:getContainerIdByEntity(bale) or ""
    streamWriteString(streamId, containerId)

    -- Trace logging for debugging MP sync
    if containerId ~= "" then
        Log:trace("BALE_WRITE_STREAM: containerId=%s uniqueId=%s",
            containerId, tostring(bale.uniqueId))
    else
        Log:trace("BALE_WRITE_STREAM: no containerId for bale uniqueId=%s (not tracked)",
            tostring(bale.uniqueId))
    end
end

--- Client receives: Read containerId and register with Manager
---@param bale table Bale entity
---@param streamId number Network stream ID
---@param connection table Network connection
function RmBaleAdapter.readStreamHook(bale, streamId, connection)
    local containerId = streamReadString(streamId)

    Log:trace("BALE_READ_STREAM: received containerId='%s' for bale", containerId)

    if containerId ~= "" then
        -- Delegate to Manager - it owns the entity→container mapping
        RmFreshManager:registerClientEntity(bale, containerId)
    end
end
