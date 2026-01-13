-- RmLossLogSyncEvent.lua
-- Purpose: Delta sync event - sends a single loss log entry to clients
-- Author: Ritter
-- Used by: RmLossTracker:recordExpiration() for real-time loss sync

RmLossLogSyncEvent = {}
local RmLossLogSyncEvent_mt = Class(RmLossLogSyncEvent, Event)

InitEventClass(RmLossLogSyncEvent, "RmLossLogSyncEvent")

local Log = RmLogging.getLogger("Fresh")

--- Empty constructor for deserialization
function RmLossLogSyncEvent.emptyNew()
    return Event.new(RmLossLogSyncEvent_mt)
end

--- Constructor with loss entry data
---@param entry table Loss log entry
function RmLossLogSyncEvent.new(entry)
    local self = RmLossLogSyncEvent.emptyNew()
    self.entry = entry or {}
    return self
end

--- Serialize loss entry for network transmission
---@param streamId number Network stream ID
---@param connection table Network connection
function RmLossLogSyncEvent:writeStream(streamId, connection)
    local entry = self.entry
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

    Log:debug("LOSSLOG_SYNC_WRITE: %s %.0f (farm %d)", entry.fillTypeName or "?", entry.amount or 0, entry.farmId or 0)
end

--- Deserialize loss entry from network
---@param streamId number Network stream ID
---@param connection table Network connection
function RmLossLogSyncEvent:readStream(streamId, connection)
    self.entry = {
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

    Log:debug("LOSSLOG_SYNC_READ: %s %.0f (farm %d)", self.entry.fillTypeName or "?", self.entry.amount or 0, self.entry.farmId or 0)
    self:run(connection)
end

--- Apply loss entry to client's RmLossTracker
---@param connection table Network connection (unused)
function RmLossLogSyncEvent:run(connection)
    if RmLossTracker == nil then
        Log:warning("LOSSLOG_SYNC_RUN: RmLossTracker not available")
        return
    end

    -- Append entry to client's loss log
    table.insert(RmLossTracker.lossLog, self.entry)

    Log:debug("LOSSLOG_SYNC_RUN: Added %s %.0f to client lossLog (now %d entries)",
        self.entry.fillTypeName or "?", self.entry.amount or 0, #RmLossTracker.lossLog)
end
