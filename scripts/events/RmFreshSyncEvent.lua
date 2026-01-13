-- RmFreshSyncEvent.lua
-- Purpose: Full state sync event - sends all container data to joining client
-- Author: Ritter
-- Used by: RmFreshManager:sendFullStateToClient()

RmFreshSyncEvent = {}
local RmFreshSyncEvent_mt = Class(RmFreshSyncEvent, Event)

InitEventClass(RmFreshSyncEvent, "RmFreshSyncEvent")

local Log = RmLogging.getLogger("Fresh")

--- Empty constructor for deserialization
function RmFreshSyncEvent.emptyNew()
    return Event.new(RmFreshSyncEvent_mt)
end

--- Constructor with container data and loss log
---@param containersData table Containers table from RmFreshManager
---@param lossLog table|nil Loss log entries from RmLossTracker (optional)
function RmFreshSyncEvent.new(containersData, lossLog)
    local self = RmFreshSyncEvent.emptyNew()
    self.containersData = containersData or {}
    self.lossLog = lossLog or {}
    return self
end

--- Serialize containers for network transmission
---@param streamId number Network stream ID
---@param connection table Network connection
function RmFreshSyncEvent:writeStream(streamId, connection)
    -- Count containers
    local containerCount = 0
    for _ in pairs(self.containersData) do
        containerCount = containerCount + 1
    end

    streamWriteInt32(streamId, containerCount)

    for containerId, container in pairs(self.containersData) do
        -- Container header
        streamWriteString(streamId, containerId)

        -- Write entity reference using high-level API (handles nil gracefully)
        -- Client will resolve to their local entity instance
        -- Use runtimeEntity instead of entity
        NetworkUtil.writeNodeObject(streamId, container.runtimeEntity)

        streamWriteString(streamId, container.entityType or "vehicle")
        streamWriteUInt16(streamId, container.farmId or 0)
        streamWriteUInt16(streamId, container.fillTypeIndex or 0)

        -- Write identityMatch fields
        local uniqueId = ""
        local fillTypeName = ""
        if container.identityMatch then
            if container.identityMatch.worldObject then
                uniqueId = container.identityMatch.worldObject.uniqueId or ""
            end
            if container.identityMatch.storage then
                fillTypeName = container.identityMatch.storage.fillTypeName or ""
            end
        end
        streamWriteString(streamId, uniqueId)
        streamWriteString(streamId, fillTypeName)

        -- Write metadata
        local location = ""
        if container.metadata and container.metadata.location then
            location = container.metadata.location
        end
        streamWriteString(streamId, location)

        -- Write flat batches array (not nested in fillUnits)
        local batches = container.batches or {}
        local batchCount = #batches
        streamWriteUInt8(streamId, batchCount)

        for _, batch in ipairs(batches) do
            streamWriteFloat32(streamId, batch.amount or 0)
            streamWriteFloat32(streamId, batch.ageInPeriods or 0)
        end
    end

    -- Write loss log entries
    local lossLogCount = #self.lossLog
    streamWriteInt32(streamId, lossLogCount)

    for _, entry in ipairs(self.lossLog) do
        -- When (4 ints)
        streamWriteInt16(streamId, entry.year or 1)
        streamWriteUInt8(streamId, entry.period or 1)
        streamWriteUInt8(streamId, entry.dayInPeriod or 1)
        streamWriteUInt8(streamId, entry.hour or 0)
        -- What (string, 2 floats)
        streamWriteString(streamId, entry.fillTypeName or "")
        streamWriteFloat32(streamId, entry.amount or 0)
        streamWriteFloat32(streamId, entry.value or 0)
        -- Where (3 strings)
        streamWriteString(streamId, entry.location or "")
        streamWriteString(streamId, entry.objectUniqueId or "")
        streamWriteString(streamId, entry.entityType or "")
        -- Who (1 int)
        streamWriteUInt16(streamId, entry.farmId or 0)
    end

    Log:debug("SYNC_EVENT_WRITE: containers=%d lossLog=%d", containerCount, lossLogCount)
end

--- Deserialize containers from network
---@param streamId number Network stream ID
---@param connection table Network connection
function RmFreshSyncEvent:readStream(streamId, connection)
    self.containersData = {}

    local containerCount = streamReadInt32(streamId)

    for _ = 1, containerCount do
        local containerId = streamReadString(streamId)

        -- Read and resolve entity reference using high-level API
        -- This becomes runtimeEntity
        local runtimeEntity = NetworkUtil.readNodeObject(streamId)

        local entityType = streamReadString(streamId)
        local farmId = streamReadUInt16(streamId)
        local fillTypeIndex = streamReadUInt16(streamId)

        -- Read identityMatch fields
        local uniqueId = streamReadString(streamId)
        local fillTypeName = streamReadString(streamId)

        -- Read metadata
        local location = streamReadString(streamId)

        -- Read flat batches
        local batchCount = streamReadUInt8(streamId)
        local batches = {}
        for _ = 1, batchCount do
            table.insert(batches, {
                amount = streamReadFloat32(streamId),
                ageInPeriods = streamReadFloat32(streamId),
                expiredLogged = false
            })
        end

        -- Construct container
        local container = {
            id = containerId,
            entityType = entityType,
            farmId = farmId,
            fillTypeIndex = fillTypeIndex,
            runtimeEntity = runtimeEntity,
            identityMatch = {
                worldObject = { uniqueId = uniqueId },
                storage = { fillTypeName = fillTypeName }
            },
            batches = batches,
            metadata = { location = location }
        }

        self.containersData[containerId] = container
    end

    -- Read loss log entries
    self.lossLog = {}
    local lossLogCount = streamReadInt32(streamId)

    for _ = 1, lossLogCount do
        local entry = {
            -- When
            year = streamReadInt16(streamId),
            period = streamReadUInt8(streamId),
            dayInPeriod = streamReadUInt8(streamId),
            hour = streamReadUInt8(streamId),
            -- What
            fillTypeName = streamReadString(streamId),
            amount = streamReadFloat32(streamId),
            value = streamReadFloat32(streamId),
            -- Where
            location = streamReadString(streamId),
            objectUniqueId = streamReadString(streamId),
            entityType = streamReadString(streamId),
            -- Who
            farmId = streamReadUInt16(streamId),
        }
        table.insert(self.lossLog, entry)
    end

    Log:debug("SYNC_EVENT_READ: containers=%d lossLog=%d", containerCount, lossLogCount)
    self:run(connection)
end

--- Apply full state to client Manager
---@param connection table Network connection (unused)
function RmFreshSyncEvent:run(connection)
    if RmFreshManager == nil then
        Log:warning("SYNC_EVENT_RUN: RmFreshManager not available")
        return
    end

    -- Replace client state with server state
    RmFreshManager.containers = self.containersData

    -- Rebuild entityRefIndex using runtimeEntity
    RmFreshManager.entityRefIndex = {}
    for containerId, container in pairs(self.containersData) do
        if container.runtimeEntity ~= nil then
            RmFreshManager.entityRefIndex[container.runtimeEntity] = containerId
        end
    end

    local containerCount = 0
    for _ in pairs(self.containersData) do
        containerCount = containerCount + 1
    end

    -- Apply loss log to client
    if RmLossTracker ~= nil then
        RmLossTracker.lossLog = self.lossLog or {}
        Log:debug("SYNC_EVENT_RUN: Applied lossLog - %d entries", #RmLossTracker.lossLog)
    end

    Log:info("SYNC_EVENT_RUN: Applied full state - %d containers, %d lossLog entries", containerCount, #(self.lossLog or {}))
end
