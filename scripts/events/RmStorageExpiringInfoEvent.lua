-- RmStorageExpiringInfoEvent.lua
-- Purpose: Sync object storage expiring counts from server to clients for HUD display
-- Author: Ritter
-- Used by: RmObjectStorageAdapter for runtime sync

RmStorageExpiringInfoEvent = {}
local RmStorageExpiringInfoEvent_mt = Class(RmStorageExpiringInfoEvent, Event)

InitEventClass(RmStorageExpiringInfoEvent, "RmStorageExpiringInfoEvent")

local Log = RmLogging.getLogger("Fresh")

--- Empty constructor for deserialization
--- Called by engine when receiving event from network
---@return RmStorageExpiringInfoEvent New empty event instance
function RmStorageExpiringInfoEvent.emptyNew()
    return Event.new(RmStorageExpiringInfoEvent_mt)
end

--- Constructor with expiring count data for a single placeable
--- Called on server to create event for broadcasting
---@param placeable table The placeable with object storage
---@param counts table Table of { [objectInfoIndex] = count } for non-zero entries
---@return RmStorageExpiringInfoEvent New event instance with data
function RmStorageExpiringInfoEvent.new(placeable, counts)
    local self = RmStorageExpiringInfoEvent.emptyNew()
    self.placeable = placeable
    self.counts = counts or {}
    return self
end

--- Serialize event data for network transmission
--- Called on server when sending to clients
---@param streamId number Network stream ID
---@param connection table Network connection (unused)
function RmStorageExpiringInfoEvent:writeStream(streamId, connection)
    -- Use NetworkUtil.getObjectId for placeable reference
    local placeableId = NetworkUtil.getObjectId(self.placeable)
    streamWriteInt32(streamId, placeableId)

    -- Count non-zero entries
    local numEntries = 0
    for _ in pairs(self.counts) do
        numEntries = numEntries + 1
    end

    -- Write number of entries
    streamWriteUInt8(streamId, numEntries)

    -- Write each entry: objectInfoIndex, count
    for objectInfoIndex, count in pairs(self.counts) do
        streamWriteUInt8(streamId, objectInfoIndex)
        streamWriteUInt8(streamId, count)
    end

    Log:trace("STORAGE_EXPIRING_EVENT_WRITE: placeableId=%d entries=%d", placeableId, numEntries)
end

--- Deserialize event data from network
--- Called on client when receiving from server
---@param streamId number Network stream ID
---@param connection table Network connection (unused)
function RmStorageExpiringInfoEvent:readStream(streamId, connection)
    local placeableId = streamReadInt32(streamId)
    local placeable = NetworkUtil.getObject(placeableId)

    local numEntries = streamReadUInt8(streamId)

    -- Read all entries to keep stream in sync
    local counts = {}
    for _ = 1, numEntries do
        local objectInfoIndex = streamReadUInt8(streamId)
        local count = streamReadUInt8(streamId)
        counts[objectInfoIndex] = count
    end

    Log:trace("STORAGE_EXPIRING_EVENT_READ: placeableId=%d entries=%d", placeableId, numEntries)

    -- Validate placeable exists
    if placeable == nil then
        Log:trace("STORAGE_EXPIRING_EVENT_READ: Placeable not synced yet, ignoring")
        return
    end

    -- Apply counts to client-side cache
    RmObjectStorageAdapter.clientExpiringCounts[placeable] = counts

    Log:trace("STORAGE_EXPIRING_EVENT_READ: Updated clientExpiringCounts")
end
