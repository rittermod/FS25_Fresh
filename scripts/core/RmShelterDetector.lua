-- RmShelterDetector.lua
-- Purpose: Detect whether a loose bale or pallet stands under a roof and keep its storage class current
-- Author: Ritter
-- Architecture: Server only. Owns the indoor-mask read and the roof ray, so neither the manager nor an
--   adapter touches them. A poll re-checks an item once it has moved and come to rest; the hourly pass
--   re-checks every loose item. Class writes go through RmFreshManager:setDetectedStorageClass.

RmShelterDetector = {}

local Log = RmLogging.getLogger("Fresh")

-- =============================================================================
-- CONSTANTS
-- =============================================================================

--- Time an item must stay still before it is probed, in ms of g_currentMission.time
RmShelterDetector.SETTLE_MS = 1000

--- Interval between two settle polls, in ms of frame time
RmShelterDetector.POLL_INTERVAL_MS = 1000

--- Length of the upward roof ray, in m
RmShelterDetector.RAY_LENGTH = 30

-- =============================================================================
-- STATE
-- =============================================================================

--- runtimeEntity -> { lastMoveTime, storageClass, faulted }; every pass replaces the whole table
RmShelterDetector.records = {}

--- The installed updateable, nil when none is installed (a client installs none)
RmShelterDetector.updateable = nil

--- Distance of the last roof hit, reset before every cast; read only by the probe TRACE line
RmShelterDetector.lastHitDistance = nil

-- =============================================================================
-- INTERNAL HELPERS
-- =============================================================================

--- Error handler for the poll boundary: log the call stack at the throw site, return the message
---@param err any Error raised inside the protected body
---@return string message Error text
local function onGuardError(err)
    printCallstack()
    return tostring(err)
end

--- Run a zero-arg function so a fault cannot escape into the engine's update loop
---@param label string Identifies the protected step in the error line
---@param fn function Zero-arg function to run
---@return boolean ok True when fn completed without error
local function runProtected(label, fn)
    local ok, err = xpcall(fn, onGuardError)
    if not ok then
        Log:error("PERIODIC_GUARD: %s: %s", label, tostring(err))
    end
    return ok
end

--- Write one class to every container of an entity through the manager
---@param containerIds table Array of container ids belonging to the entity
---@param storageClass number Storage class to write
---@return number changed Number of containers whose class changed
local function writeClass(containerIds, storageClass)
    local changed = 0
    for _, containerId in ipairs(containerIds) do
        if RmFreshManager:setDetectedStorageClass(containerId, storageClass) then
            changed = changed + 1
        end
    end
    Log:trace("<<< writeClass(%d containers, class=%s) changed=%d", #containerIds, tostring(storageClass), changed)
    return changed
end

--- Collect the loose-item containers the poll may touch, grouped by their runtime entity
---@return table order Entities in first-seen order
---@return table groups entity -> { entityType, containerIds }
local function collectLooseEntities()
    local order = {}
    local groups = {}
    for containerId, container in pairs(RmFreshManager:getAllContainers()) do
        if container.runtimeEntity ~= nil
            and RmFreshManager:isLooseItemContainer(container)
            and RmFreshManager:shouldProcessContainer(containerId) then
            local entity = container.runtimeEntity
            local group = groups[entity]
            if group == nil then
                group = { entityType = container.entityType, containerIds = {} }
                groups[entity] = group
                table.insert(order, entity)
            end
            table.insert(group.containerIds, containerId)
        end
    end
    Log:trace("<<< collectLooseEntities = %d entities", #order)
    return order, groups
end

--- Probe one entity when it is due, or bring its containers in line with its recorded class
---@param entity table Runtime entity (bale or pallet)
---@param group table { entityType, containerIds }
---@param oldRecord table|nil Record from the previous pass
---@param now number Current g_currentMission.time in ms
---@param force boolean Probe regardless of motion (hourly pass)
---@param counts table Accumulator { probed, changed, skipped }
---@return table|nil record Record to keep for this entity, nil for none
local function processEntity(entity, group, oldRecord, now, force, counts)
    local uniqueId = tostring(entity.uniqueId)

    if oldRecord ~= nil and oldRecord.faulted and not force then
        Log:trace("SHELTER_POLL: uniqueId=%s faulted earlier, waiting for the hourly pass", uniqueId)
        counts.skipped = counts.skipped + 1
        return oldRecord
    end

    -- A missing adapter or getShelterProbe raises here and is contained by the caller's guard
    local adapter = RmFreshManager:getAdapterForType(group.entityType)
    local x, y, z, lastMoveTime = adapter:getShelterProbe(entity)
    if x == nil then
        Log:trace("SHELTER_POLL: uniqueId=%s has no probe position, skipped this pass", uniqueId)
        counts.skipped = counts.skipped + 1
        return oldRecord
    end

    local checkedMoveTime = oldRecord and oldRecord.lastMoveTime
    if not force and not RmShelterDetector.isSettled(lastMoveTime, checkedMoveTime, now) then
        -- A container added to a resting, checked item (rescan, dynamic registration) takes its recorded class
        if oldRecord ~= nil and oldRecord.storageClass ~= nil then
            counts.changed = counts.changed + writeClass(group.containerIds, oldRecord.storageClass)
        end
        Log:trace("SHELTER_POLL: uniqueId=%s not due (lastMoveTime=%s checked=%s now=%s)",
            uniqueId, tostring(lastMoveTime), tostring(checkedMoveTime), tostring(now))
        return oldRecord
    end

    local storageClass, isIndoor, hasRoof = RmShelterDetector.probe(x, y, z)
    counts.probed = counts.probed + 1
    Log:trace("SHELTER_PROBE: uniqueId=%s x=%.2f z=%.2f indoor=%s roof=%s hitDistance=%s class=%s",
        uniqueId, x, z, tostring(isIndoor), tostring(hasRoof),
        tostring(RmShelterDetector.lastHitDistance), tostring(RmFreshManager.STORAGE_CLASS_NAMES[storageClass]))

    counts.changed = counts.changed + writeClass(group.containerIds, storageClass)
    return { lastMoveTime = lastMoveTime, storageClass = storageClass, faulted = false }
end

-- =============================================================================
-- PUBLIC API
-- =============================================================================

--- True when an item moved since its last check and has been still for more than SETTLE_MS
---@param lastMoveTime number Server time of the item's last move (ms)
---@param checkedMoveTime number|nil lastMoveTime recorded at the last probe, nil when never probed
---@param now number Current g_currentMission.time (ms)
---@return boolean settled True when the item is due for a probe
function RmShelterDetector.isSettled(lastMoveTime, checkedMoveTime, now)
    -- Strictly greater: an item counts as at rest only after a full SETTLE_MS without a move
    local settled = lastMoveTime ~= checkedMoveTime and now - lastMoveTime > RmShelterDetector.SETTLE_MS
    Log:trace("<<< isSettled(last=%s checked=%s now=%s) = %s",
        tostring(lastMoveTime), tostring(checkedMoveTime), tostring(now), tostring(settled))
    return settled
end

--- Class for a mask and ray result: SHELTERED only when both say sheltered, EXPOSED otherwise
---@param isIndoor boolean Indoor-mask result at the item's x/z
---@param hasRoof boolean Roof-ray result above the item
---@return number storageClass RmFreshManager.STORAGE_CLASS value
function RmShelterDetector.classify(isIndoor, hasRoof)
    local SC = RmFreshManager.STORAGE_CLASS
    local storageClass = (isIndoor and hasRoof) and SC.SHELTERED or SC.EXPOSED
    Log:trace("<<< classify(indoor=%s roof=%s) = %s", tostring(isIndoor), tostring(hasRoof), tostring(storageClass))
    return storageClass
end

--- Indoor-mask read at a world x/z (seam: real by default, swapped by tests)
---@param x number World x
---@param z number World z
---@return boolean isIndoor True when the mask cell is indoor
function RmShelterDetector.isIndoorAt(x, z)
    local isIndoor = g_currentMission.indoorMask:getIsIndoorAtWorldPosition(x, z) == true
    Log:trace("<<< isIndoorAt(%.2f, %.2f) = %s", x, z, tostring(isIndoor))
    return isIndoor
end

--- Upward BUILDING ray from a world point (seam: real by default, swapped by tests)
---@param x number World x of the ray origin
---@param y number World y of the ray origin
---@param z number World z of the ray origin
---@return boolean hasRoof True when the ray hits a building collision within RAY_LENGTH
function RmShelterDetector.hasRoofAbove(x, y, z)
    RmShelterDetector.lastHitDistance = nil
    local hits = raycastClosest(x, y, z, 0, 1, 0, RmShelterDetector.RAY_LENGTH,
        "onRoofRayHit", RmShelterDetector, CollisionFlag.BUILDING)
    local hasRoof = (hits or 0) > 0
    Log:trace("<<< hasRoofAbove(%.2f, %.2f, %.2f) hits=%s distance=%s = %s",
        x, y, z, tostring(hits), tostring(RmShelterDetector.lastHitDistance), tostring(hasRoof))
    return hasRoof
end

--- raycastClosest callback: record the hit distance for the probe TRACE line
---@param _target table The callback target (RmShelterDetector)
---@param hitObjectId number Id of the hit collision node
---@param _x number Hit world x
---@param _y number Hit world y
---@param _z number Hit world z
---@param distance number Distance from the ray origin to the hit
function RmShelterDetector.onRoofRayHit(_target, hitObjectId, _x, _y, _z, distance)
    RmShelterDetector.lastHitDistance = distance
    Log:trace("ROOF_RAY_HIT: node=%s distance=%s", tostring(hitObjectId), tostring(distance))
end

--- Probe one world point: the indoor mask first, the roof ray only when the mask says indoor
---@param x number World x
---@param y number World y of the ray origin
---@param z number World z
---@return number storageClass SHELTERED or EXPOSED
---@return boolean isIndoor Indoor-mask result
---@return boolean hasRoof Roof-ray result (false when the ray was not cast)
function RmShelterDetector.probe(x, y, z)
    -- Mask first: a cheap cell read that rejects most outdoor items. The mask alone is not enough,
    -- because roads and water are painted indoor on the base maps; the ray confirms a real roof.
    local isIndoor = RmShelterDetector.isIndoorAt(x, z)
    local hasRoof = false
    if isIndoor then
        hasRoof = RmShelterDetector.hasRoofAbove(x, y, z)
    else
        Log:trace("SHELTER_PROBE: mask outdoor at %.2f/%.2f, ray not cast", x, z)
    end
    return RmShelterDetector.classify(isIndoor, hasRoof), isIndoor, hasRoof
end

--- One pass over every loose item: probe the due ones, catch up resting siblings, prune gone entities
---@param now number Current g_currentMission.time (ms)
---@param force boolean true probes every item regardless of motion (hourly pass)
---@return table counts { entities, probed, changed, skipped, faulted }
function RmShelterDetector.pollOnce(now, force)
    local order, groups = collectLooseEntities()
    local counts = { entities = #order, probed = 0, changed = 0, skipped = 0, faulted = 0 }
    local oldRecords = RmShelterDetector.records
    local newRecords = {}

    for _, entity in ipairs(order) do
        local oldRecord = oldRecords[entity]
        local ok, result = pcall(processEntity, entity, groups[entity], oldRecord, now, force, counts)
        if ok then
            newRecords[entity] = result
        else
            -- Contained per item: record it as faulted so the unforced poll does not retry it every second
            Log:warning("SHELTER_FAULT: uniqueId=%s type=%s: %s",
                tostring(entity.uniqueId), tostring(groups[entity].entityType), tostring(result))
            counts.faulted = counts.faulted + 1
            newRecords[entity] = {
                lastMoveTime = oldRecord and oldRecord.lastMoveTime,
                storageClass = oldRecord and oldRecord.storageClass,
                faulted = true,
            }
        end
    end

    -- Entities not seen in this pass (deleted, stored, now non-perishable) drop out here
    RmShelterDetector.records = newRecords

    if counts.probed > 0 or counts.changed > 0 or counts.faulted > 0 then
        Log:trace("SHELTER_POLL: force=%s entities=%d probed=%d changed=%d skipped=%d faulted=%d",
            tostring(force), counts.entities, counts.probed, counts.changed, counts.skipped, counts.faulted)
    end
    return counts
end

--- Hourly pass: re-probe every loose item, moved or not (a shed built or sold over a resting item)
---@param now number Current g_currentMission.time (ms)
---@return table counts { entities, probed, changed, skipped, faulted }
function RmShelterDetector.recheckAll(now)
    local counts = RmShelterDetector.pollOnce(now, true)
    Log:debug("SHELTER_RECHECK: entities=%d probed=%d changed=%d skipped=%d faulted=%d",
        counts.entities, counts.probed, counts.changed, counts.skipped, counts.faulted)
    return counts
end

-- =============================================================================
-- GAME HOOKS
-- =============================================================================

--- Install the server poll; a client installs nothing and reads the synced class
function RmShelterDetector.install()
    if g_server == nil then
        Log:trace("SHELTER_INSTALL: skipped (not the server)")
        return
    end

    local updateable = { elapsedMs = 0 }
    local frameDt = 0

    -- Built once, so a frame allocates no closure; runs only while the mission runs, when every
    -- placeable has finished loading and painted its indoor areas
    --- Add the last frame time and run one unforced pass each POLL_INTERVAL_MS while the mission runs
    local function tick()
        if g_currentMission.isRunning then
            updateable.elapsedMs = updateable.elapsedMs + frameDt
            if updateable.elapsedMs >= RmShelterDetector.POLL_INTERVAL_MS then
                updateable.elapsedMs = 0
                RmShelterDetector.pollOnce(g_currentMission.time, false)
            end
        end
    end

    --- Engine updateable callback: keep the frame time and run the tick under the poll guard
    ---@param _self table The updateable (unused)
    ---@param dt number Frame time in ms
    function updateable.update(_self, dt)
        frameDt = dt
        runProtected("shelterPoll", tick)
    end

    g_currentMission:addUpdateable(updateable)
    RmShelterDetector.updateable = updateable
    Log:info("Shelter detector installed (poll %d ms, settle %d ms, ray %d m)",
        RmShelterDetector.POLL_INTERVAL_MS, RmShelterDetector.SETTLE_MS, RmShelterDetector.RAY_LENGTH)
end

--- Remove the poll when one was installed, and clear every per-entity record
function RmShelterDetector.uninstall()
    if RmShelterDetector.updateable ~= nil then
        g_currentMission:removeUpdateable(RmShelterDetector.updateable)
        RmShelterDetector.updateable = nil
        Log:debug("SHELTER_UNINSTALL: poll removed")
    else
        Log:trace("SHELTER_UNINSTALL: no poll installed")
    end
    RmShelterDetector.records = {}
    RmShelterDetector.lastHitDistance = nil
end
