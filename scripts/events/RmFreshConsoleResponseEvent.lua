-- RmFreshConsoleResponseEvent.lua
-- Purpose: Server-to-client response for console batch manipulation commands
-- Author: Ritter
-- Architecture: Provides feedback to client after server executes command

RmFreshConsoleResponseEvent = {}

local RmFreshConsoleResponseEvent_mt = Class(RmFreshConsoleResponseEvent, Event)

InitEventClass(RmFreshConsoleResponseEvent, "RmFreshConsoleResponseEvent")

local Log = RmLogging.getLogger("Fresh")

--- Empty constructor for deserialization
function RmFreshConsoleResponseEvent.emptyNew()
    return Event.new(RmFreshConsoleResponseEvent_mt)
end

--- Constructor with response data
---@param success boolean Whether the command succeeded
---@param message string Result message to display
---@param actionType string Original action type (for context)
function RmFreshConsoleResponseEvent.new(success, message, actionType)
    local self = RmFreshConsoleResponseEvent.emptyNew()
    self.success = success
    self.message = message or ""
    self.actionType = actionType or ""
    return self
end

--- Serialize response for network transmission (server -> client)
---@param streamId number Network stream ID
---@param connection table Network connection
function RmFreshConsoleResponseEvent:writeStream(streamId, connection)
    streamWriteBool(streamId, self.success)
    streamWriteString(streamId, self.message)
    streamWriteString(streamId, self.actionType)

    Log:debug("CONSOLE_RESPONSE_WRITE: success=%s action=%s", tostring(self.success), self.actionType)
end

--- Deserialize response from network (on client)
---@param streamId number Network stream ID
---@param connection table Network connection
function RmFreshConsoleResponseEvent:readStream(streamId, connection)
    self.success = streamReadBool(streamId)
    self.message = streamReadString(streamId)
    self.actionType = streamReadString(streamId)

    Log:debug("CONSOLE_RESPONSE_READ: success=%s action=%s", tostring(self.success), self.actionType)
    self:run(connection)
end

--- Display response to client (in-game notification)
---@param connection table Network connection (unused)
function RmFreshConsoleResponseEvent:run(connection)
    -- This runs on CLIENT only

    -- Display message via in-game notification system
    if g_currentMission ~= nil and g_currentMission.hud ~= nil then
        -- Use appropriate notification type based on success
        if self.success then
            g_currentMission.hud:showInGameMessage(
                "Fresh",
                self.message,
                -1,
                nil
            )
        else
            g_currentMission.hud:showInGameMessage(
                "Fresh Error",
                self.message,
                -1,
                nil
            )
        end
    end

    Log:debug("CONSOLE_RESPONSE_RUN: success=%s message=%s", tostring(self.success), self.message)
end
