-- RmFreshUpdateEvent.lua
-- Purpose: Delta sync event - sends single container changes to clients
-- Author: Ritter
-- Used by: RmFreshManager:broadcastContainerUpdate()

RmFreshUpdateEvent = {}

-- Operation types
RmFreshUpdateEvent.OP_REGISTER = 0
RmFreshUpdateEvent.OP_UPDATE = 1
RmFreshUpdateEvent.OP_UNREGISTER = 2

local RmFreshUpdateEvent_mt = Class(RmFreshUpdateEvent, Event)

InitEventClass(RmFreshUpdateEvent, "RmFreshUpdateEvent")

local Log = RmLogging.getLogger("Fresh")

--- Empty constructor for deserialization
function RmFreshUpdateEvent.emptyNew()
    return Event.new(RmFreshUpdateEvent_mt)
end

--- Constructor with delta data
---@param containerId string Container ID
---@param operation number Operation type (OP_REGISTER, OP_UPDATE, OP_UNREGISTER)
---@param data table|nil Operation data (container for REGISTER, batches for UPDATE, nil for UNREGISTER)
function RmFreshUpdateEvent.new(containerId, operation, data)
    local self = RmFreshUpdateEvent.emptyNew()
    self.containerId = containerId
    self.operation = operation
    self.data = data
    return self
end

--- Serialize delta for network transmission
---@param streamId number Network stream ID
---@param connection table Network connection
function RmFreshUpdateEvent:writeStream(streamId, connection)
    streamWriteString(streamId, self.containerId)
    streamWriteUInt8(streamId, self.operation)

    if self.operation == RmFreshUpdateEvent.OP_REGISTER then
        -- Write full container data
        local container = self.data

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

        -- Write flat batches array
        local batches = container.batches or {}
        local batchCount = #batches
        streamWriteUInt8(streamId, batchCount)

        for _, batch in ipairs(batches) do
            streamWriteFloat32(streamId, batch.amount or 0)
            streamWriteFloat32(streamId, batch.ageInPeriods or 0)
        end

    elseif self.operation == RmFreshUpdateEvent.OP_UPDATE then
        -- Write updated batches array (flat, not per-fillUnit)
        local batches = self.data.batches or {}
        local batchCount = #batches
        streamWriteUInt8(streamId, batchCount)

        for _, batch in ipairs(batches) do
            streamWriteFloat32(streamId, batch.amount or 0)
            streamWriteFloat32(streamId, batch.ageInPeriods or 0)
        end

    -- elseif self.operation == OP_UNREGISTER then
        -- No additional data needed
    end

    Log:debug("UPDATE_EVENT_WRITE: containerId=%s op=%d", self.containerId, self.operation)
end

--- Deserialize delta from network
---@param streamId number Network stream ID
---@param connection table Network connection
function RmFreshUpdateEvent:readStream(streamId, connection)
    self.containerId = streamReadString(streamId)
    self.operation = streamReadUInt8(streamId)

    if self.operation == RmFreshUpdateEvent.OP_REGISTER then
        -- Read runtimeEntity
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
        self.data = {
            id = self.containerId,
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

    elseif self.operation == RmFreshUpdateEvent.OP_UPDATE then
        -- Read updated batches array (flat)
        local batchCount = streamReadUInt8(streamId)
        local batches = {}
        for _ = 1, batchCount do
            table.insert(batches, {
                amount = streamReadFloat32(streamId),
                ageInPeriods = streamReadFloat32(streamId),
                expiredLogged = false
            })
        end

        self.data = { batches = batches }

    elseif self.operation == RmFreshUpdateEvent.OP_UNREGISTER then
        -- No payload for unregister
        self.data = nil

    else
        -- Unknown operation
        self.data = nil
        Log:warning("UPDATE_EVENT_READ: Unknown operation %d", self.operation)
    end

    Log:debug("UPDATE_EVENT_READ: containerId=%s op=%d", self.containerId, self.operation)
    self:run(connection)
end

--- Apply delta to client Manager
---@param connection table Network connection (unused)
function RmFreshUpdateEvent:run(connection)
    if RmFreshManager == nil then
        Log:warning("UPDATE_EVENT_RUN: RmFreshManager not available")
        return
    end

    if self.operation == RmFreshUpdateEvent.OP_REGISTER then
        -- Add new container
        RmFreshManager.containers[self.containerId] = self.data

        -- Update entityRefIndex using runtimeEntity
        if self.data.runtimeEntity ~= nil then
            RmFreshManager.entityRefIndex[self.data.runtimeEntity] = self.containerId
        end

        Log:debug("UPDATE_EVENT_RUN: REGISTER containerId=%s", self.containerId)

    elseif self.operation == RmFreshUpdateEvent.OP_UPDATE then
        -- Update existing container's flat batches
        local container = RmFreshManager.containers[self.containerId]
        if container then
            container.batches = self.data.batches
            Log:debug("UPDATE_EVENT_RUN: UPDATE containerId=%s batches=%d",
                self.containerId, #self.data.batches)
        else
            Log:warning("UPDATE_EVENT_RUN: Container not found for UPDATE: %s", self.containerId)
        end

    elseif self.operation == RmFreshUpdateEvent.OP_UNREGISTER then
        -- Remove container
        local container = RmFreshManager.containers[self.containerId]
        if container then
            -- Clean entityRefIndex using runtimeEntity
            if container.runtimeEntity ~= nil then
                RmFreshManager.entityRefIndex[container.runtimeEntity] = nil
            end

            RmFreshManager.containers[self.containerId] = nil
            Log:debug("UPDATE_EVENT_RUN: UNREGISTER containerId=%s", self.containerId)
        end

    else
        Log:warning("UPDATE_EVENT_RUN: Unknown operation %d for container %s",
            self.operation, self.containerId)
    end
end
