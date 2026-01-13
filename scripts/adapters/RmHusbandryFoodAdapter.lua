-- RmHusbandryFoodAdapter.lua
-- Purpose: Thin husbandry food adapter - bridges FS25 PlaceableHusbandryFood to centralized FreshManager
-- Author: Ritter
-- CRITICAL: PlaceableHusbandryFood uses its own fill system (spec_husbandryFood.fillLevels),
--           NOT the Storage class that PlaceableAdapter handles.

RmHusbandryFoodAdapter = {}
RmHusbandryFoodAdapter.MOD_NAME = g_currentModName
RmHusbandryFoodAdapter.SPEC_TABLE_NAME = ("spec_%s.rmHusbandryFoodAdapter"):format(g_currentModName)
RmHusbandryFoodAdapter.ENTITY_TYPE = "husbandryfood"  -- Distinct from PlaceableAdapter's "placeable"

local Log = RmLogging.getLogger("Fresh")

-- =============================================================================
-- IDENTITY
-- =============================================================================

--- Build identity structure for husbandry food container
--- HusbandryFood uses spec_husbandryFood.fillLevels directly (NOT Storage class)
---@param placeable table Placeable entity (husbandry with food)
---@param fillTypeName string Fill type name (string, not index)
---@param fillLevel number|nil Current fill level
---@return table identityMatch structure for registerContainer
function RmHusbandryFoodAdapter:buildIdentityMatch(placeable, fillTypeName, fillLevel)
    return {
        worldObject = {
            uniqueId = placeable.uniqueId,
        },
        storage = {
            fillTypeName = fillTypeName,
            amount = fillLevel or 0,
        },
    }
end

-- =============================================================================
-- SPECIALIZATION SETUP
-- =============================================================================

--- Only inject into placeables with PlaceableHusbandryFood
--- CRITICAL: Checks for PlaceableHusbandryFood, NOT PlaceableHusbandry
--- PlaceableHusbandry has general storage (milk, bedding) - handled by PlaceableAdapter
--- PlaceableHusbandryFood has food storage (what animals eat) - handled HERE
---@param specializations table The placeable type's specializations
---@return boolean hasPrerequisite true if PlaceableHusbandryFood present
function RmHusbandryFoodAdapter.prerequisitesPresent(specializations)
    return SpecializationUtil.hasSpecialization(PlaceableHusbandryFood, specializations)
end

--- Register event listeners for lifecycle and MP stream hooks
---@param placeableType table The placeable type
function RmHusbandryFoodAdapter.registerEventListeners(placeableType)
    SpecializationUtil.registerEventListener(placeableType, "onLoad", RmHusbandryFoodAdapter)
    SpecializationUtil.registerEventListener(placeableType, "onLoadFinished", RmHusbandryFoodAdapter)
    SpecializationUtil.registerEventListener(placeableType, "onDelete", RmHusbandryFoodAdapter)
    -- MP sync for client display
    SpecializationUtil.registerEventListener(placeableType, "onWriteStream", RmHusbandryFoodAdapter)
    SpecializationUtil.registerEventListener(placeableType, "onReadStream", RmHusbandryFoodAdapter)
    SpecializationUtil.registerEventListener(placeableType, "onWriteUpdateStream", RmHusbandryFoodAdapter)
    SpecializationUtil.registerEventListener(placeableType, "onReadUpdateStream", RmHusbandryFoodAdapter)
end

--- Register overwritten functions for fill tracking and display
--- CRITICAL: Hooks addFood/removeFood for fill tracking, updateInfo for HUD display
---@param placeableType table The placeable type
function RmHusbandryFoodAdapter.registerOverwrittenFunctions(placeableType)
    SpecializationUtil.registerOverwrittenFunction(placeableType, "addFood", RmHusbandryFoodAdapter.addFood)
    SpecializationUtil.registerOverwrittenFunction(placeableType, "removeFood", RmHusbandryFoodAdapter.removeFood)
    SpecializationUtil.registerOverwrittenFunction(placeableType, "updateInfo", RmHusbandryFoodAdapter.updateInfo)
end

-- =============================================================================
-- LIFECYCLE: onLoad
-- =============================================================================

--- Polling timeout for deferred registration: 10 seconds
local DEFER_TIMEOUT_MS = 10000

--- Called when placeable is loaded
--- Initializes spec table for container tracking
---@param savegame table|nil Savegame data
function RmHusbandryFoodAdapter:onLoad(savegame)
    -- Server only - clients receive state via sync events
    if not self.isServer then return end

    -- Skip construction preview placeables (PlaceableAdapter pattern)
    local propertyState = self:getPropertyState()
    if propertyState == PlaceablePropertyState.CONSTRUCTION_PREVIEW or
       propertyState == PlaceablePropertyState.NONE then
        Log:trace("HUSBANDRY_FOOD_SKIP_NON_OWNED: propertyState=%d name=%s",
            propertyState or 0, self:getName() or "unknown")
        return
    end

    -- Initialize spec table (prerequisitesPresent guarantees spec_husbandryFood exists on type)
    local spec = self[RmHusbandryFoodAdapter.SPEC_TABLE_NAME]
    if spec == nil then
        self[RmHusbandryFoodAdapter.SPEC_TABLE_NAME] = {}
        spec = self[RmHusbandryFoodAdapter.SPEC_TABLE_NAME]
    end

    -- Initialize spec data structure (mirrors PlaceableAdapter)
    spec.containerIds = {}           -- fillTypeName -> containerId
    spec.dirtyFlag = self:getNextDirtyFlag()
    spec.deferredRegistration = false  -- Prevent double scheduling

    Log:debug("HUSBANDRY_FOOD_INIT: propertyState=%d uniqueId=%s name=%s",
        propertyState or 0, self.uniqueId or "?", self:getName() or "unknown")
end

-- =============================================================================
-- CONTAINER REGISTRATION HELPERS
-- =============================================================================

--- Register a container for a food fill type
--- Called from doRegistration (load) and addFood (dynamic)
---@param placeable table The husbandry placeable
---@param spec table The adapter spec table
---@param fillTypeIndex number Fill type index to register
---@param fillLevel number Current fill level (used for reconciliation matching)
---@param suppressInitialBatch boolean|nil If true, skip adding initial batch (let onFillChanged handle it)
---@return string|nil containerId The registered container ID
---@return boolean wasReconciled True if container was matched from saved data
function RmHusbandryFoodAdapter.registerFoodContainer(placeable, spec, fillTypeIndex, fillLevel, suppressInitialBatch)
    local fillTypeName = g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex)

    -- Check if already registered (prevent duplicates)
    if spec.containerIds[fillTypeName] ~= nil then
        Log:trace("    registerFoodContainer: already registered for %s", fillTypeName)
        return spec.containerIds[fillTypeName]
    end

    local identityMatch = RmHusbandryFoodAdapter:buildIdentityMatch(placeable, fillTypeName, fillLevel)

    local containerId, wasReconciled = RmFreshManager:registerContainer(
        "husbandryfood", identityMatch, placeable,
        { location = placeable:getName() or "Animal Building" }
    )

    spec.containerIds[fillTypeName] = containerId

    -- Add initial batch ONLY for NEW containers (not reconciled from save) AND not suppressed
    -- suppressInitialBatch=true when called from addFood (let onFillChanged handle batch for transfer pending)
    if not wasReconciled and containerId and fillLevel > 0 and not suppressInitialBatch then
        RmFreshManager:addBatch(containerId, fillLevel, 0)
    end

    Log:debug("HUSBANDRY_FOOD_REGISTERED: fillType=%s containerId=%s reconciled=%s name=%s",
        fillTypeName, containerId or "nil", tostring(wasReconciled), placeable:getName() or "?")

    return containerId, wasReconciled
end

--- Perform actual container registration after uniqueId is confirmed
--- Pattern: Mirrors RmPlaceableAdapter.doRegistration exactly
---@param placeable table Placeable entity
---@param entityId string The placeable's uniqueId
function RmHusbandryFoodAdapter.doRegistration(placeable, entityId)
    Log:trace(">>> doRegistration(husbandryFood=%s, entityId=%s)",
        placeable:getName() or "?", entityId or "?")

    local spec = placeable[RmHusbandryFoodAdapter.SPEC_TABLE_NAME]
    if spec == nil then
        Log:trace("<<< doRegistration (no spec table)")
        return
    end

    -- Check if already registered
    if next(spec.containerIds) ~= nil then
        Log:trace("<<< doRegistration (already registered)")
        return
    end

    -- Get husbandry food spec
    local husbandryFoodSpec = placeable.spec_husbandryFood
    if husbandryFoodSpec == nil or husbandryFoodSpec.fillLevels == nil then
        Log:trace("<<< doRegistration (no fillLevels)")
        return
    end

    Log:debug("HUSBANDRY_FOOD_LOAD: uniqueId=%s name=%s",
        entityId or "?", placeable:getName() or "unknown")

    -- Register containers for existing perishable food
    local registered = 0
    for fillTypeIndex, fillLevel in pairs(husbandryFoodSpec.fillLevels) do
        if fillLevel > 0 and RmFreshSettings:isPerishableByIndex(fillTypeIndex) then
            -- Skip mixtures - they expand to ingredients when dumped
            local mixture = g_currentMission.animalFoodSystem:getMixtureByFillType(fillTypeIndex)
            if mixture == nil then
                RmHusbandryFoodAdapter.registerFoodContainer(placeable, spec, fillTypeIndex, fillLevel)
                registered = registered + 1
            else
                Log:trace("    skipping mixture fillType=%d", fillTypeIndex)
            end
        end
    end

    Log:trace("<<< doRegistration registered=%d containers", registered)
end

--- Defer registration until uniqueId is available (for purchased placeables)
--- Pattern: Mirrors RmPlaceableAdapter.deferRegistration exactly
---@param placeable table Placeable entity
function RmHusbandryFoodAdapter.deferRegistration(placeable)
    Log:trace(">>> deferRegistration(husbandryFood=%s)", placeable:getName() or "unknown")

    local spec = placeable[RmHusbandryFoodAdapter.SPEC_TABLE_NAME]
    if spec.deferredRegistration then
        Log:trace("<<< deferRegistration (already scheduled)")
        return
    end

    spec.deferredRegistration = true
    Log:debug("HUSBANDRY_FOOD_DEFER: %s (uniqueId not yet assigned)", placeable:getName() or "unknown")

    local startTime = g_currentMission.time

    g_currentMission:addUpdateable({
        placeable = placeable,
        update = function(self, _dt)
            -- Guard: mission teardown (review finding: avoid accessing nil g_currentMission)
            if g_currentMission == nil then
                return  -- Can't remove updateable, but will be cleaned up with mission
            end

            local p = self.placeable

            -- Success: uniqueId now available
            if p.uniqueId and p.uniqueId ~= "" then
                Log:trace("    deferred: uniqueId now available after %dms", g_currentMission.time - startTime)
                RmHusbandryFoodAdapter.doRegistration(p, p.uniqueId)
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
                Log:warning("HUSBANDRY_FOOD_NO_UNIQUEID: %s failed to get uniqueId after %dms",
                    p:getName() or "unknown", DEFER_TIMEOUT_MS)
                g_currentMission:removeUpdateable(self)
                return
            end
        end
    })

    Log:trace("<<< deferRegistration (scheduled, timeout=%dms)", DEFER_TIMEOUT_MS)
end

-- =============================================================================
-- LIFECYCLE: onLoadFinished
-- =============================================================================

--- Called when placeable finishes loading
--- Routes to doRegistration or deferRegistration based on uniqueId availability
---@param savegame table|nil Savegame data
function RmHusbandryFoodAdapter:onLoadFinished(savegame)
    Log:trace(">>> onLoadFinished(husbandryFood=%s)", self:getName() or "?")

    -- Server only - clients receive state via stream sync
    if not self.isServer then
        Log:trace("<<< onLoadFinished (client, skipping)")
        return
    end

    -- Skip construction preview placeables (PlaceableAdapter pattern)
    local propertyState = self:getPropertyState()
    if propertyState == PlaceablePropertyState.CONSTRUCTION_PREVIEW or
       propertyState == PlaceablePropertyState.NONE then
        Log:trace("<<< onLoadFinished (preview/none, skipping)")
        return
    end

    if RmFreshManager == nil then
        Log:error("HUSBANDRY_FOOD_LOAD_FINISHED: RmFreshManager not available")
        Log:trace("<<< onLoadFinished (no manager)")
        return
    end

    local spec = self[RmHusbandryFoodAdapter.SPEC_TABLE_NAME]
    if spec == nil then
        Log:trace("<<< onLoadFinished (no spec)")
        return
    end

    -- Check if uniqueId is available
    local entityId = self.uniqueId
    if entityId == nil or entityId == "" then
        -- Defer registration - uniqueId assigned after onLoadFinished for purchased placeables
        RmHusbandryFoodAdapter.deferRegistration(self)
        Log:trace("<<< onLoadFinished (deferred)")
        return
    end

    -- Register immediately (savegame placeables have uniqueId at onLoadFinished)
    RmHusbandryFoodAdapter.doRegistration(self, entityId)
    Log:trace("<<< onLoadFinished")
end

-- =============================================================================
-- LIFECYCLE: onDelete
-- =============================================================================

--- Called when placeable is deleted (sold/demolished)
--- Unregisters all containers and cleans up spec tables
function RmHusbandryFoodAdapter:onDelete()
    -- Server only - clients don't register containers
    if not self.isServer then return end

    local spec = self[RmHusbandryFoodAdapter.SPEC_TABLE_NAME]
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

    Log:debug("HUSBANDRY_FOOD_DELETE: %s unregistered %d containers",
        self:getName() or "unknown", count)

    -- Clean up spec tables (PlaceableAdapter pattern)
    spec.containerIds = nil
end

-- =============================================================================
-- HOOKS
-- =============================================================================

--- Hook food addition for fill tracking
--- CRITICAL: superFunc handles mixture expansion - ingredient calls follow
---@param superFunc function Original addFood function
---@param farmId number Farm ID
---@param deltaFillLevel number Amount to add
---@param fillTypeIndex number Fill type index
---@param ... any Additional arguments (fillPositionData, toolType, extraAttributes)
---@return number actualDelta Actual fill level change
function RmHusbandryFoodAdapter:addFood(superFunc, farmId, deltaFillLevel, fillTypeIndex, ...)
    -- TRACE entry per 12.5 guidelines
    Log:trace(">>> addFood(farmId=%d, delta=%.1f, fillType=%d)", farmId, deltaFillLevel, fillTypeIndex)

    -- Call superFunc first - it handles mixture expansion if applicable
    local result = superFunc(self, farmId, deltaFillLevel, fillTypeIndex, ...)

    -- Server only - clients receive state via sync events
    if not self.isServer then
        Log:trace("<<< addFood = %.1f (client skip)", result)
        return result
    end
    if result <= 0 then
        Log:trace("<<< addFood = %.1f (no fill)", result)
        return result
    end

    local spec = self[RmHusbandryFoodAdapter.SPEC_TABLE_NAME]
    if spec == nil then
        Log:trace("<<< addFood = %.1f (no spec)", result)
        return result
    end

    -- Skip mixtures WHEN game expands them - ingredient calls will follow
    -- If game doesn't expand (e.g., TMR in cow pasture), mixture check returns nil
    local mixture = g_currentMission.animalFoodSystem:getMixtureByFillType(fillTypeIndex)
    if mixture ~= nil then
        Log:trace("    skipping: mixture expansion pending for fillType=%d", fillTypeIndex)
        Log:trace("<<< addFood = %.1f (mixture)", result)
        return result
    end

    -- Only track perishable fill types
    if not RmFreshSettings:isPerishableByIndex(fillTypeIndex) then
        Log:trace("    skipping: non-perishable fillType=%d", fillTypeIndex)
        Log:trace("<<< addFood = %.1f (non-perishable)", result)
        return result
    end

    local fillTypeName = g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex)
    local containerId = spec.containerIds[fillTypeName]

    -- Dynamic registration if new perishable food type
    if containerId == nil then
        Log:trace("    dynamic registration: fillType=%s", fillTypeName)
        -- Get actual fill level for reconciliation matching (supports save/load)
        -- suppressInitialBatch=true: let onFillChanged handle batch (supports transfer pending)
        local actualFillLevel = self.spec_husbandryFood.fillLevels[fillTypeIndex] or result
        local wasReconciled
        containerId, wasReconciled = RmHusbandryFoodAdapter.registerFoodContainer(self, spec, fillTypeIndex, actualFillLevel, true)
        if not containerId then
            Log:trace("<<< addFood = %.1f (registration failed)", result)
            return result
        end
        Log:debug("HUSBANDRY_FOOD_REGISTER: fillType=%s containerId=%s reconciled=%s (dynamic)",
            fillTypeName, containerId, tostring(wasReconciled))

        -- If reconciled from save, skip onFillChanged - batches already restored
        if wasReconciled then
            Log:trace("    skipping onFillChanged (reconciled from save)")
            self:raiseDirtyFlags(spec.dirtyFlag)  -- Still sync to clients
            Log:debug("HUSBANDRY_FOOD_ADD: fillType=%s amount=%.1f containerId=%s (reconciled)",
                fillTypeName, result, containerId)
            Log:trace("<<< addFood = %.1f (reconciled)", result)
            return result
        end
    end

    -- Report fill change to Manager - handles transfer pending logic internally
    RmFreshManager:onFillChanged(containerId, 1, result, fillTypeIndex)
    self:raiseDirtyFlags(spec.dirtyFlag)

    Log:debug("HUSBANDRY_FOOD_ADD: fillType=%s amount=%.1f containerId=%s",
        fillTypeName, result, containerId)
    Log:trace("<<< addFood = %.1f", result)

    return result
end

--- Hook food removal for FIFO consumption tracking
---@param superFunc function Original removeFood function
---@param absDeltaFillLevel number Absolute amount to remove
---@param fillTypeIndex number Fill type index
---@return number actualDelta Actual fill level removed
function RmHusbandryFoodAdapter:removeFood(superFunc, absDeltaFillLevel, fillTypeIndex)
    -- TRACE entry per 12.5 guidelines
    Log:trace(">>> removeFood(delta=%.1f, fillType=%d)", absDeltaFillLevel, fillTypeIndex)

    -- Call superFunc first
    local result = superFunc(self, absDeltaFillLevel, fillTypeIndex)

    -- Server only
    if not self.isServer then
        Log:trace("<<< removeFood = %.1f (client skip)", result)
        return result
    end
    if result <= 0 then
        Log:trace("<<< removeFood = %.1f (no removal)", result)
        return result
    end

    local spec = self[RmHusbandryFoodAdapter.SPEC_TABLE_NAME]
    if spec == nil then
        Log:trace("<<< removeFood = %.1f (no spec)", result)
        return result
    end

    -- Skip mixtures when game expands them
    local mixture = g_currentMission.animalFoodSystem:getMixtureByFillType(fillTypeIndex)
    if mixture ~= nil then
        Log:trace("    skipping: mixture expansion for fillType=%d", fillTypeIndex)
        Log:trace("<<< removeFood = %.1f (mixture)", result)
        return result
    end

    -- Skip non-perishable
    if not RmFreshSettings:isPerishableByIndex(fillTypeIndex) then
        Log:trace("    skipping: non-perishable fillType=%d", fillTypeIndex)
        Log:trace("<<< removeFood = %.1f (non-perishable)", result)
        return result
    end

    local fillTypeName = g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex)
    local containerId = spec.containerIds[fillTypeName]

    if containerId then
        -- Forward negative delta to Manager for FIFO consumption
        RmFreshManager:onFillChanged(containerId, 1, -result, fillTypeIndex)
        self:raiseDirtyFlags(spec.dirtyFlag)

        Log:debug("HUSBANDRY_FOOD_REMOVE: fillType=%s amount=%.1f containerId=%s",
            fillTypeName, result, containerId)
    else
        -- No container registered - food was consumed before Fresh tracking started
        Log:debug("HUSBANDRY_FOOD_REMOVE: fillType=%s amount=%.1f (untracked)",
            fillTypeName, result)
    end

    Log:trace("<<< removeFood = %.1f", result)
    return result
end

--- HUD display hook for freshness info
--- Pattern: Follow RmPlaceableAdapter:updateInfo (lines 766-829)
--- CRITICAL: Call superFunc FIRST - it populates infoTable with fill type entries
---@param superFunc function Original updateInfo function
---@param infoTable table Info table to modify
function RmHusbandryFoodAdapter:updateInfo(superFunc, infoTable)
    Log:trace(">>> updateInfo(husbandryFood=%s)", self.uniqueId or "?")

    local startCount = #infoTable  -- Track count BEFORE superFunc
    superFunc(self, infoTable)

    local spec = self[RmHusbandryFoodAdapter.SPEC_TABLE_NAME]
    if spec == nil then
        Log:trace("<<< updateInfo (no spec)")
        return
    end
    if spec.containerIds == nil or next(spec.containerIds) == nil then
        Log:trace("<<< updateInfo (no containerIds)")
        return
    end

    -- Build expiring amounts per fillType
    local expiringByFillType = {}
    local totalExpiring = 0

    for fillTypeName, containerId in pairs(spec.containerIds) do
        local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(fillTypeName)
        if fillTypeIndex then
            local batches = RmFreshManager:getBatches(containerId)
            local thresholds = RmFreshSettings:getThresholdByIndex(fillTypeIndex)

            for _, batch in ipairs(batches or {}) do
                if RmBatch.isNearExpiration(batch, thresholds.warning, thresholds.expiration) then
                    expiringByFillType[fillTypeIndex] =
                        (expiringByFillType[fillTypeIndex] or 0) + batch.amount
                    totalExpiring = totalExpiring + batch.amount
                end
            end
        end
    end

    -- Only modify entries when there's something expiring
    if totalExpiring == 0 then
        Log:trace("<<< updateInfo (no expiring goods)")
        return
    end

    -- Modify existing entries (after startCount) OR add new ones
    for fillTypeIndex, expiringAmount in pairs(expiringByFillType) do
        if expiringAmount > 0 then
            local fillTypeTitle = g_fillTypeManager:getFillTypeTitleByIndex(fillTypeIndex)
            local formattedVolume = g_i18n:formatVolume(expiringAmount)
            local suffix = string.format(g_i18n:getText("fresh_storage_expiring_volume"), formattedVolume)

            -- Try to find and modify existing entry
            local found = false
            for i = startCount + 1, #infoTable do
                local entry = infoTable[i]
                if entry and entry.title == fillTypeTitle then
                    entry.text = entry.text .. " " .. suffix
                    entry.accentuate = true
                    found = true
                    break
                end
            end

            -- If not found in superFunc entries, add new warning entry
            if not found then
                table.insert(infoTable, {
                    title = fillTypeTitle,
                    text = suffix,
                    accentuate = true
                })
            end
        end
    end

    -- TRACE exit log with expiring summary
    local expiringCount = 0
    for _ in pairs(expiringByFillType) do expiringCount = expiringCount + 1 end
    Log:trace("<<< updateInfo: %d fillTypes with expiring goods", expiringCount)
end

-- =============================================================================
-- FILL MANIPULATION METHODS
-- =============================================================================

--- Get fill level for a container by containerId
--- Pattern: Follow RmPlaceableAdapter:getFillLevel (lines 131-168)
---@param containerId string Container ID
---@return number fillLevel Current fill level
---@return number fillTypeIndex Fill type index
function RmHusbandryFoodAdapter:getFillLevel(containerId)
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

    local husbandryFoodSpec = placeable.spec_husbandryFood
    if not husbandryFoodSpec or not husbandryFoodSpec.fillLevels then
        Log:trace("<<< getFillLevel (no spec_husbandryFood)")
        return 0, 0
    end

    -- Derive fillTypeIndex from identityMatch
    local fillTypeName = container.identityMatch and container.identityMatch.storage
        and container.identityMatch.storage.fillTypeName
    if not fillTypeName then
        Log:trace("<<< getFillLevel (no fillTypeName in identityMatch)")
        return 0, 0
    end
    local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(fillTypeName)
    if not fillTypeIndex then
        Log:trace("<<< getFillLevel (fillType not found: %s)", fillTypeName)
        return 0, 0
    end

    local fillLevel = husbandryFoodSpec.fillLevels[fillTypeIndex] or 0

    Log:trace("<<< getFillLevel = %.1f, fillType=%d", fillLevel, fillTypeIndex)
    return fillLevel, fillTypeIndex
end

--- Add fill level for a container by containerId
---@param containerId string Container ID
---@param delta number Amount to add (negative to remove)
---@return boolean success True if fill was modified
function RmHusbandryFoodAdapter:addFillLevel(containerId, delta)
    Log:trace(">>> addFillLevel(containerId=%s, delta=%.1f)", containerId or "nil", delta or 0)

    local container = RmFreshManager:getContainer(containerId)
    if not container then
        Log:trace("<<< addFillLevel (no container)")
        return false
    end

    local placeable = container.runtimeEntity
    if not placeable or not placeable.spec_husbandryFood then
        Log:trace("<<< addFillLevel (no runtimeEntity/spec)")
        return false
    end

    -- Derive fillTypeIndex from identityMatch
    local fillTypeName = container.identityMatch and container.identityMatch.storage
        and container.identityMatch.storage.fillTypeName
    if not fillTypeName then
        Log:trace("<<< addFillLevel (no fillTypeName in identityMatch)")
        return false
    end
    local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(fillTypeName)
    if not fillTypeIndex then
        Log:trace("<<< addFillLevel (fillType not found: %s)", fillTypeName)
        return false
    end
    local farmId = placeable:getOwnerFarmId()

    if delta > 0 then
        placeable:addFood(farmId, delta, fillTypeIndex)
    elseif delta < 0 then
        placeable:removeFood(math.abs(delta), fillTypeIndex)
    end

    Log:trace("<<< addFillLevel (success)")
    return true
end

--- Set fill level for a container by containerId
---@param containerId string Container ID
---@param level number Target fill level
---@return boolean success True if fill was modified
function RmHusbandryFoodAdapter:setFillLevel(containerId, level)
    Log:trace(">>> setFillLevel(containerId=%s, level=%.1f)", containerId or "nil", level or 0)

    local currentFill, _ = self:getFillLevel(containerId)
    local delta = level - currentFill
    local success = self:addFillLevel(containerId, delta)

    Log:trace("<<< setFillLevel (delta=%.1f, success=%s)", delta, tostring(success))
    return success
end

-- =============================================================================
-- MP STREAM SYNC
-- =============================================================================
-- NOTE: HusbandryFoodAdapter uses update streams (onWriteUpdateStream/onReadUpdateStream)
-- unlike PlaceableAdapter because:
-- 1. Dynamic registration can occur (new perishable food type added mid-session via addFood)
-- 2. PlaceableAdapter fillTypes are fixed at construction, no dynamic registration
-- 3. Without update streams, client HUD wouldn't show dynamically-added containers until reconnect
-- If this proves unnecessary in practice, simplify in future refactor.
-- =============================================================================

--- MP stream sync - send container state to joining client
--- Pattern: Follow RmPlaceableAdapter:onWriteStream (lines 706-724)
---@param streamId number Network stream ID
---@param connection table Network connection
function RmHusbandryFoodAdapter:onWriteStream(streamId, connection)
    Log:trace(">>> onWriteStream(husbandryFood=%s)", self.uniqueId or "?")

    -- Skip if writing TO server (we're on client) (12.5: log decision branches)
    if connection:getIsServer() then
        Log:trace("    connection check: to server, skipping")
        Log:trace("<<< onWriteStream (to server, skip)")
        return
    end
    Log:trace("    connection check: to client, sending")

    local spec = self[RmHusbandryFoodAdapter.SPEC_TABLE_NAME]
    local containerIds = spec and spec.containerIds or {}

    -- Count containers
    local count = 0
    for _ in pairs(containerIds) do count = count + 1 end

    streamWriteUInt8(streamId, count)
    Log:trace("    writing %d containers to stream", count)

    local i = 0
    for fillTypeName, containerId in pairs(containerIds) do
        i = i + 1
        streamWriteString(streamId, fillTypeName)
        streamWriteString(streamId, containerId)
        Log:trace("    [%d] sent: %s -> %s", i, fillTypeName, containerId)
    end

    Log:trace("<<< onWriteStream: sent %d containerIds", count)
end

--- MP stream sync - receive container state on client join
--- Pattern: Follow RmPlaceableAdapter:onReadStream (lines 730-755)
---@param streamId number Network stream ID
---@param connection table Network connection
function RmHusbandryFoodAdapter:onReadStream(streamId, connection)
    Log:trace(">>> onReadStream(husbandryFood=%s)", self.uniqueId or "?")

    -- Only process data FROM server (12.5: log decision branches)
    if not connection:getIsServer() then
        Log:trace("    connection check: not from server, skipping")
        Log:trace("<<< onReadStream (not from server, skip)")
        return
    end
    Log:trace("    connection check: from server, processing")

    -- Create minimal spec table if not exists (client may not have called onLoad)
    local spec = self[RmHusbandryFoodAdapter.SPEC_TABLE_NAME]
    if spec == nil then
        spec = { containerIds = {} }
        self[RmHusbandryFoodAdapter.SPEC_TABLE_NAME] = spec
        Log:trace("    spec table created (client had no onLoad)")
    end
    spec.containerIds = spec.containerIds or {}

    local count = streamReadUInt8(streamId)
    Log:trace("    reading %d containers from stream", count)

    for i = 1, count do
        local fillTypeName = streamReadString(streamId)
        local containerId = streamReadString(streamId)
        spec.containerIds[fillTypeName] = containerId
        Log:trace("    [%d] stored: %s -> %s", i, fillTypeName, containerId)

        -- Register entity->containerId mapping for display hooks
        if RmFreshManager and RmFreshManager.registerClientEntity then
            RmFreshManager:registerClientEntity(self, containerId)
            -- 12.5: DEBUG for significant events
            Log:debug("HUSBANDRY_CLIENT_REGISTERED: containerId=%s fillType=%s entity=%s",
                containerId, fillTypeName, self.uniqueId or "?")
        end
    end

    Log:trace("<<< onReadStream: received %d containerIds", count)
end

--- MP update stream - send dirty container updates
--- Called by FS25 when entity dirty flags are set
---@param streamId number Network stream ID
---@param connection table Network connection
---@param dirtyMask number Dirty flags mask
function RmHusbandryFoodAdapter:onWriteUpdateStream(streamId, connection, dirtyMask)
    -- Skip if writing TO server (12.5: log decision branches)
    if connection:getIsServer() then
        Log:trace("onWriteUpdateStream: to server, skipping")
        return
    end

    local spec = self[RmHusbandryFoodAdapter.SPEC_TABLE_NAME]

    -- Check if our dirty flag is set in the mask
    local isDirty = spec ~= nil and spec.dirtyFlag ~= nil and
                    bitAND(dirtyMask, spec.dirtyFlag) ~= 0
    Log:trace("onWriteUpdateStream: isDirty=%s (mask=%s, flag=%s)",
        tostring(isDirty), tostring(dirtyMask), tostring(spec and spec.dirtyFlag))

    if streamWriteBool(streamId, isDirty) then
        Log:trace(">>> onWriteUpdateStream(husbandryFood=%s, dirty=true)", self.uniqueId or "?")

        local containerIds = spec.containerIds or {}

        local count = 0
        for _ in pairs(containerIds) do count = count + 1 end

        streamWriteUInt8(streamId, count)
        Log:trace("    writing %d containers to update stream", count)

        local i = 0
        for fillTypeName, containerId in pairs(containerIds) do
            i = i + 1
            streamWriteString(streamId, fillTypeName)
            streamWriteString(streamId, containerId)
            Log:trace("    [%d] sent: %s -> %s", i, fillTypeName, containerId)
        end

        Log:trace("<<< onWriteUpdateStream: sent %d containerIds (dirty)", count)
    end
end

--- MP update stream - receive dirty container updates
---@param streamId number Network stream ID
---@param timestamp number Update timestamp
---@param connection table Network connection
function RmHusbandryFoodAdapter:onReadUpdateStream(streamId, timestamp, connection)
    -- Only process data FROM server (12.5: log decision branches)
    if not connection:getIsServer() then
        Log:trace("onReadUpdateStream: not from server, skipping")
        return
    end

    if streamReadBool(streamId) then
        Log:trace(">>> onReadUpdateStream(husbandryFood=%s, dirty=true)", self.uniqueId or "?")

        -- Create minimal spec table if needed
        local spec = self[RmHusbandryFoodAdapter.SPEC_TABLE_NAME]
        if spec == nil then
            spec = { containerIds = {} }
            self[RmHusbandryFoodAdapter.SPEC_TABLE_NAME] = spec
            Log:trace("    spec table created (client had no onLoad)")
        end
        spec.containerIds = spec.containerIds or {}

        local count = streamReadUInt8(streamId)
        Log:trace("    reading %d containers from update stream", count)

        for i = 1, count do
            local fillTypeName = streamReadString(streamId)
            local containerId = streamReadString(streamId)
            spec.containerIds[fillTypeName] = containerId
            Log:trace("    [%d] stored: %s -> %s", i, fillTypeName, containerId)

            if RmFreshManager and RmFreshManager.registerClientEntity then
                RmFreshManager:registerClientEntity(self, containerId)
                -- 12.5: DEBUG for significant events
                Log:debug("HUSBANDRY_CLIENT_REGISTERED: containerId=%s fillType=%s entity=%s (update)",
                    containerId, fillTypeName, self.uniqueId or "?")
            end
        end

        Log:trace("<<< onReadUpdateStream: received %d containerIds (update)", count)
    else
        Log:trace("onReadUpdateStream: no dirty data")
    end
end

-- =============================================================================
-- ADAPTER REGISTRATION
-- =============================================================================

RmFreshManager:registerAdapter(RmHusbandryFoodAdapter.ENTITY_TYPE, RmHusbandryFoodAdapter)

-- =============================================================================
-- MODULE LOAD
-- =============================================================================

Log:info("RmHusbandryFoodAdapter specialization loaded")
