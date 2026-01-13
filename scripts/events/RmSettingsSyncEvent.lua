-- RmSettingsSyncEvent.lua
-- Purpose: Multiplayer settings sync event - sends user overrides to joining clients
-- Author: Ritter
-- Pattern: Follows RmFreshSyncEvent.lua structure

RmSettingsSyncEvent = {}
local RmSettingsSyncEvent_mt = Class(RmSettingsSyncEvent, Event)

InitEventClass(RmSettingsSyncEvent, "RmSettingsSyncEvent")

local Log = RmLogging.getLogger("Fresh")

-- =============================================================================
-- EVENT LIFECYCLE
-- =============================================================================

--- Empty constructor for deserialization
function RmSettingsSyncEvent.emptyNew()
    return Event.new(RmSettingsSyncEvent_mt)
end

--- Constructor with settings data
---@param settingsData table User overrides { global = {}, fillTypes = {} }
function RmSettingsSyncEvent.new(settingsData)
    local self = RmSettingsSyncEvent.emptyNew()
    self.settingsData = settingsData or { global = {}, fillTypes = {} }
    return self
end

-- =============================================================================
-- SERIALIZATION
-- =============================================================================

--- Serialize settings for network transmission
---@param streamId number Network stream ID
---@param connection table Network connection
function RmSettingsSyncEvent:writeStream(streamId, connection)
    Log:trace(">>> writeStream()")

    -- Write global settings
    local globals = {}
    for k, v in pairs(self.settingsData.global or {}) do
        table.insert(globals, { name = k, value = v })
    end
    streamWriteUInt8(streamId, #globals)

    for _, g in ipairs(globals) do
        streamWriteString(streamId, g.name)
        if type(g.value) == "boolean" then
            streamWriteUInt8(streamId, 1)
            streamWriteBool(streamId, g.value)
            Log:trace("    global: %s = %s (bool)", g.name, tostring(g.value))
        elseif type(g.value) == "number" then
            streamWriteUInt8(streamId, 2)
            streamWriteFloat32(streamId, g.value)
            Log:trace("    global: %s = %s (number)", g.name, tostring(g.value))
        else
            streamWriteUInt8(streamId, 3)
            streamWriteString(streamId, tostring(g.value))
            Log:trace("    global: %s = %s (string)", g.name, tostring(g.value))
        end
    end

    -- Write fillType overrides
    local fillTypes = {}
    for name, config in pairs(self.settingsData.fillTypes or {}) do
        table.insert(fillTypes, { name = name, config = config })
    end
    streamWriteUInt16(streamId, #fillTypes)

    for _, ft in ipairs(fillTypes) do
        streamWriteString(streamId, ft.name)
        local isDoNotExpire = (ft.config.expires == false)
        streamWriteBool(streamId, isDoNotExpire)
        if isDoNotExpire then
            Log:trace("    fillType: %s = expires=false", ft.name)
        elseif ft.config.period then
            streamWriteFloat32(streamId, ft.config.period)
            Log:trace("    fillType: %s = period=%.2f", ft.name, ft.config.period)
        end
    end

    Log:debug("SETTINGS_SYNC_WRITE: %d global, %d fillTypes", #globals, #fillTypes)
end

--- Deserialize settings from network
---@param streamId number Network stream ID
---@param connection table Network connection
function RmSettingsSyncEvent:readStream(streamId, connection)
    Log:trace(">>> readStream()")
    self.settingsData = { global = {}, fillTypes = {} }

    -- Read global settings
    local globalCount = streamReadUInt8(streamId)
    for _ = 1, globalCount do
        local name = streamReadString(streamId)
        local valueType = streamReadUInt8(streamId)
        local value
        if valueType == 1 then
            value = streamReadBool(streamId)
            Log:trace("    global: %s = %s (bool)", name, tostring(value))
        elseif valueType == 2 then
            value = streamReadFloat32(streamId)
            Log:trace("    global: %s = %s (number)", name, tostring(value))
        else
            value = streamReadString(streamId)
            Log:trace("    global: %s = %s (string)", name, tostring(value))
        end
        self.settingsData.global[name] = value
    end

    -- Read fillType overrides
    local ftCount = streamReadUInt16(streamId)
    for _ = 1, ftCount do
        local name = streamReadString(streamId)
        local isDoNotExpire = streamReadBool(streamId)
        if isDoNotExpire then
            self.settingsData.fillTypes[name] = { expires = false }
            Log:trace("    fillType: %s = expires=false", name)
        else
            local period = streamReadFloat32(streamId)
            self.settingsData.fillTypes[name] = { period = period }
            Log:trace("    fillType: %s = period=%.2f", name, period)
        end
    end

    Log:debug("SETTINGS_SYNC_READ: %d global, %d fillTypes", globalCount, ftCount)
    self:run(connection)
end

-- =============================================================================
-- EXECUTION
-- =============================================================================

--- Apply settings on client
---@param connection table Network connection (unused)
function RmSettingsSyncEvent:run(connection)
    -- Only apply on client (server already has the data)
    if g_server ~= nil then
        Log:trace("    run() skipped (server)")
        return
    end

    if RmFreshSettings == nil then
        Log:warning("SETTINGS_SYNC_RUN: RmFreshSettings not available")
        return
    end

    local globalCount = 0
    local ftCount = 0
    for _ in pairs(self.settingsData.global or {}) do globalCount = globalCount + 1 end
    for _ in pairs(self.settingsData.fillTypes or {}) do ftCount = ftCount + 1 end

    RmFreshSettings:setUserOverrides(self.settingsData)
    Log:info("SETTINGS_SYNC_RUN: Applied server settings (%d global, %d fillTypes)", globalCount, ftCount)

    -- Notify open Settings Frame to refresh UI after sync
    -- Uses displayedInstance (the currently visible frame) instead of primaryInstance
    if RmSettingsFrame ~= nil and RmSettingsFrame.displayedInstance ~= nil then
        RmSettingsFrame.displayedInstance:refreshData()
        RmSettingsFrame.displayedInstance:updateReadonlyState()
        Log:debug("SETTINGS_SYNC_RUN: Refreshed displayed Settings Frame (self=%s)",
            tostring(RmSettingsFrame.displayedInstance))
    end
end

-- =============================================================================
-- STATIC HELPER METHODS
-- =============================================================================

--- Send settings to a specific client (called on client join)
---@param connection table Network connection
function RmSettingsSyncEvent.sendToClient(connection)
    local settingsData = RmFreshSettings:getUserOverrides()
    connection:sendEvent(RmSettingsSyncEvent.new(settingsData))
    Log:debug("SETTINGS_SYNC: Sent to client")
end

--- Broadcast settings to all connected clients (called on settings change)
function RmSettingsSyncEvent.broadcastToClients()
    if g_server then
        local settingsData = RmFreshSettings:getUserOverrides()
        g_server:broadcastEvent(RmSettingsSyncEvent.new(settingsData))
        Log:debug("SETTINGS_SYNC: Broadcast to all clients")
    end
end
