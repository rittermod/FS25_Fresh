-- RmFreshNotificationEvent.lua
-- Purpose: Deliver loss notification message from server to clients
-- Author: Ritter
-- Story: 29-4 - Daily Notification System

---@class RmFreshNotificationEvent
---Simple event to deliver loss notification message to client
RmFreshNotificationEvent = {}
local RmFreshNotificationEvent_mt = Class(RmFreshNotificationEvent, Event)

InitEventClass(RmFreshNotificationEvent, "RmFreshNotificationEvent")

--- Empty constructor for deserialization
function RmFreshNotificationEvent.emptyNew()
    local self = Event.new(RmFreshNotificationEvent_mt)
    return self
end

--- Constructor with message
---@param message string Notification message to display
function RmFreshNotificationEvent.new(message)
    local self = RmFreshNotificationEvent.emptyNew()
    self.message = message
    return self
end

--- Serialize message for network transmission
---@param streamId number Network stream ID
---@param connection table Network connection
function RmFreshNotificationEvent:writeStream(streamId, connection)
    streamWriteString(streamId, self.message or "")
end

--- Deserialize message from network
---@param streamId number Network stream ID
---@param connection table Network connection
function RmFreshNotificationEvent:readStream(streamId, connection)
    self.message = streamReadString(streamId)
    self:run(connection)
end

--- Display the notification on client
---@param connection table Network connection (unused)
function RmFreshNotificationEvent:run(connection)
    -- Client side: display the notification
    if self.message and self.message ~= "" then
        g_currentMission.hud:addSideNotification(
            FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
            self.message,
            nil,
            GuiSoundPlayer.SOUND_SAMPLES.NOTIFICATION
        )
    end
end
