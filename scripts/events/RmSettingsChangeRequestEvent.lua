-- RmSettingsChangeRequestEvent.lua
-- Purpose: Client-to-server settings modification request event
-- Author: Ritter
-- Pattern: Request event - client sends to server for admin validation

RmSettingsChangeRequestEvent = {}
local RmSettingsChangeRequestEvent_mt = Class(RmSettingsChangeRequestEvent, Event)

InitEventClass(RmSettingsChangeRequestEvent, "RmSettingsChangeRequestEvent")

local Log = RmLogging.getLogger("Fresh")

-- =============================================================================
-- EVENT LIFECYCLE
-- =============================================================================

--- Empty constructor for deserialization
function RmSettingsChangeRequestEvent.emptyNew()
    return Event.new(RmSettingsChangeRequestEvent_mt)
end

--- Constructor with operation data
---@param operation string Operation type: "setExpiration", "setDoNotExpire", "setGlobal", "resetAll"
---@param key string FillType name or global setting key (nil for resetAll)
---@param value any Period (number), expires (bool), or global value (nil for setDoNotExpire/resetAll)
function RmSettingsChangeRequestEvent.new(operation, key, value)
    local self = RmSettingsChangeRequestEvent.emptyNew()
    self.operation = operation or "unknown"
    self.key = key
    self.value = value
    return self
end

-- =============================================================================
-- SERIALIZATION
-- =============================================================================

--- Serialize request for network transmission
---@param streamId number Network stream ID
---@param _connection table Network connection (unused)
function RmSettingsChangeRequestEvent:writeStream(streamId, _connection)
    Log:trace(">>> RmSettingsChangeRequestEvent:writeStream()")
    Log:trace("    operation=%s, key=%s, value=%s",
        self.operation, tostring(self.key), tostring(self.value))

    streamWriteString(streamId, self.operation)
    streamWriteString(streamId, self.key or "")

    -- Encode value based on operation type
    if self.operation == "setExpiration" then
        streamWriteFloat32(streamId, self.value or 0)
    elseif self.operation == "setGlobal" then
        -- Global settings can be boolean
        if type(self.value) == "boolean" then
            streamWriteUInt8(streamId, 1)  -- Type marker: boolean
            streamWriteBool(streamId, self.value)
        else
            streamWriteUInt8(streamId, 2)  -- Type marker: number
            streamWriteFloat32(streamId, self.value or 0)
        end
    end
    -- setDoNotExpire and resetAll don't need additional value data

    Log:trace("<<< writeStream")
end

--- Deserialize request from network
---@param streamId number Network stream ID
---@param connection table Network connection
function RmSettingsChangeRequestEvent:readStream(streamId, connection)
    Log:trace(">>> RmSettingsChangeRequestEvent:readStream()")

    self.operation = streamReadString(streamId)
    self.key = streamReadString(streamId)
    if self.key == "" then self.key = nil end

    -- Decode value based on operation type
    if self.operation == "setExpiration" then
        self.value = streamReadFloat32(streamId)
    elseif self.operation == "setGlobal" then
        local valueType = streamReadUInt8(streamId)
        if valueType == 1 then
            self.value = streamReadBool(streamId)
        else
            self.value = streamReadFloat32(streamId)
        end
    end

    Log:trace("    operation=%s, key=%s, value=%s",
        self.operation, tostring(self.key), tostring(self.value))
    Log:trace("<<< readStream")

    self:run(connection)
end

-- =============================================================================
-- EXECUTION (Server-side)
-- =============================================================================

--- Execute request on server
---@param connection table Network connection from client
function RmSettingsChangeRequestEvent:run(connection)
    Log:trace(">>> RmSettingsChangeRequestEvent:run()")

    -- Safety check: must be on server
    if g_server == nil then
        Log:trace("    skipped (not server)")
        return
    end

    -- Validate admin permissions
    local user = g_currentMission.userManager:getUserByConnection(connection)
    local userName = user and user:getNickname() or "unknown"

    if not user or not user:getIsMasterUser() then
        Log:warning("SETTINGS_REQUEST: Rejected - not admin (user=%s)", userName)
        return
    end

    -- Execute operation
    local success = false
    if self.operation == "setExpiration" then
        if self.key and self.value then
            success = RmFreshSettings:setExpiration(self.key, self.value)
            Log:debug("SETTINGS_REQUEST: setExpiration(%s, %.2f) from=%s success=%s",
                self.key, self.value, userName, tostring(success))
        end

    elseif self.operation == "setDoNotExpire" then
        if self.key then
            RmFreshSettings:setDoNotExpire(self.key)
            success = true
            Log:debug("SETTINGS_REQUEST: setDoNotExpire(%s) from=%s", self.key, userName)
        end

    elseif self.operation == "setGlobal" then
        if self.key then
            RmFreshSettings:setGlobal(self.key, self.value)
            success = true
            Log:debug("SETTINGS_REQUEST: setGlobal(%s, %s) from=%s",
                self.key, tostring(self.value), userName)
        end

    elseif self.operation == "resetAll" then
        RmFreshSettings:resetAllOverrides()
        success = true
        Log:info("SETTINGS_REQUEST: resetAllOverrides() from=%s", userName)
    else
        Log:warning("SETTINGS_REQUEST: Unknown operation '%s' from=%s", self.operation, userName)
    end

    -- Note: onSettingsChanged() in RmFreshSettings handles broadcast to all clients
    -- No need to send explicit response - clients get the sync event

    Log:trace("<<< run completed, operation=%s, success=%s", self.operation, tostring(success))
end
