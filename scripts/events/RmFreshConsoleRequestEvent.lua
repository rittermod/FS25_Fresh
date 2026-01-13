-- RmFreshConsoleRequestEvent.lua
-- Purpose: Client-to-server request for console batch manipulation commands
-- Author: Ritter
-- Architecture: Implements server-side admin validation pattern

RmFreshConsoleRequestEvent = {}

-- Action types
RmFreshConsoleRequestEvent.ACTION_ADD_BATCH = 0
RmFreshConsoleRequestEvent.ACTION_REMOVE_BATCH = 1
RmFreshConsoleRequestEvent.ACTION_SET_AGE = 2
RmFreshConsoleRequestEvent.ACTION_SET_ALL_AGES = 3
RmFreshConsoleRequestEvent.ACTION_AGE = 4
RmFreshConsoleRequestEvent.ACTION_AGE_CONTAINER = 5
RmFreshConsoleRequestEvent.ACTION_EXPIRE = 6
RmFreshConsoleRequestEvent.ACTION_EXPIRE_ALL = 7
RmFreshConsoleRequestEvent.ACTION_CLEAR_LOG = 8
RmFreshConsoleRequestEvent.ACTION_RECONCILE = 9

local RmFreshConsoleRequestEvent_mt = Class(RmFreshConsoleRequestEvent, Event)

InitEventClass(RmFreshConsoleRequestEvent, "RmFreshConsoleRequestEvent")

local Log = RmLogging.getLogger("Fresh")

--- Empty constructor for deserialization
function RmFreshConsoleRequestEvent.emptyNew()
    return Event.new(RmFreshConsoleRequestEvent_mt)
end

--- Constructor with request data
---@param actionType string Action type ("ADD_BATCH", "REMOVE_BATCH", "SET_AGE", "SET_ALL_AGES")
---@param containerId string Container ID
---@param fillUnitIndex number|nil Fill unit index (nil for SET_ALL_AGES)
---@param data table Additional parameters (amount, age, batchIndex, etc.)
function RmFreshConsoleRequestEvent.new(actionType, containerId, fillUnitIndex, data)
    local self = RmFreshConsoleRequestEvent.emptyNew()
    self.actionType = actionType
    self.containerId = containerId
    self.fillUnitIndex = fillUnitIndex or 0
    self.data = data or {}
    return self
end

--- Map action string to action code
---@param actionType string Action type string
---@return number Action code
local function getActionCode(actionType)
    if actionType == "ADD_BATCH" then
        return RmFreshConsoleRequestEvent.ACTION_ADD_BATCH
    elseif actionType == "REMOVE_BATCH" then
        return RmFreshConsoleRequestEvent.ACTION_REMOVE_BATCH
    elseif actionType == "SET_AGE" then
        return RmFreshConsoleRequestEvent.ACTION_SET_AGE
    elseif actionType == "SET_ALL_AGES" then
        return RmFreshConsoleRequestEvent.ACTION_SET_ALL_AGES
    elseif actionType == "AGE" then
        return RmFreshConsoleRequestEvent.ACTION_AGE
    elseif actionType == "AGE_CONTAINER" then
        return RmFreshConsoleRequestEvent.ACTION_AGE_CONTAINER
    elseif actionType == "EXPIRE" then
        return RmFreshConsoleRequestEvent.ACTION_EXPIRE
    elseif actionType == "EXPIRE_ALL" then
        return RmFreshConsoleRequestEvent.ACTION_EXPIRE_ALL
    elseif actionType == "CLEAR_LOG" then
        return RmFreshConsoleRequestEvent.ACTION_CLEAR_LOG
    elseif actionType == "RECONCILE" then
        return RmFreshConsoleRequestEvent.ACTION_RECONCILE
    end
    return 0
end

--- Map action code to action string
---@param code number Action code
---@return string Action type string
local function getActionString(code)
    if code == RmFreshConsoleRequestEvent.ACTION_ADD_BATCH then
        return "ADD_BATCH"
    elseif code == RmFreshConsoleRequestEvent.ACTION_REMOVE_BATCH then
        return "REMOVE_BATCH"
    elseif code == RmFreshConsoleRequestEvent.ACTION_SET_AGE then
        return "SET_AGE"
    elseif code == RmFreshConsoleRequestEvent.ACTION_SET_ALL_AGES then
        return "SET_ALL_AGES"
    elseif code == RmFreshConsoleRequestEvent.ACTION_AGE then
        return "AGE"
    elseif code == RmFreshConsoleRequestEvent.ACTION_AGE_CONTAINER then
        return "AGE_CONTAINER"
    elseif code == RmFreshConsoleRequestEvent.ACTION_EXPIRE then
        return "EXPIRE"
    elseif code == RmFreshConsoleRequestEvent.ACTION_EXPIRE_ALL then
        return "EXPIRE_ALL"
    elseif code == RmFreshConsoleRequestEvent.ACTION_CLEAR_LOG then
        return "CLEAR_LOG"
    elseif code == RmFreshConsoleRequestEvent.ACTION_RECONCILE then
        return "RECONCILE"
    end
    return "UNKNOWN"
end

--- Serialize request for network transmission (client -> server)
---@param streamId number Network stream ID
---@param connection table Network connection
function RmFreshConsoleRequestEvent:writeStream(streamId, connection)
    local actionCode = getActionCode(self.actionType)
    streamWriteUInt8(streamId, actionCode)
    streamWriteString(streamId, self.containerId)
    streamWriteUInt8(streamId, self.fillUnitIndex)

    -- Write action-specific data
    if self.actionType == "ADD_BATCH" then
        streamWriteFloat32(streamId, self.data.amount or 0)
        streamWriteFloat32(streamId, self.data.age or 0)
    elseif self.actionType == "REMOVE_BATCH" then
        streamWriteUInt8(streamId, self.data.batchIndex or 1)
    elseif self.actionType == "SET_AGE" then
        streamWriteUInt8(streamId, self.data.batchIndex or 1)
        streamWriteFloat32(streamId, self.data.age or 0)
    elseif self.actionType == "SET_ALL_AGES" then
        streamWriteFloat32(streamId, self.data.age or 0)
    elseif self.actionType == "AGE" then
        streamWriteFloat32(streamId, self.data.hours or 0)
    elseif self.actionType == "AGE_CONTAINER" then
        streamWriteFloat32(streamId, self.data.hours or 0)
    elseif self.actionType == "EXPIRE" then
        -- batchIndex: >0 = single batch, 0 = fillUnit, -1 = container
        streamWriteInt8(streamId, self.data.batchIndex or -1)
    elseif self.actionType == "EXPIRE_ALL" then
        -- entityType passed via containerId field, no additional data
    elseif self.actionType == "CLEAR_LOG" then
        -- No additional data
    elseif self.actionType == "RECONCILE" then
        -- No additional data
    end

    Log:debug("CONSOLE_REQUEST_WRITE: action=%s containerId=%s", self.actionType, self.containerId)
end

--- Deserialize request from network (on server)
---@param streamId number Network stream ID
---@param connection table Network connection
function RmFreshConsoleRequestEvent:readStream(streamId, connection)
    local actionCode = streamReadUInt8(streamId)
    self.actionType = getActionString(actionCode)
    self.containerId = streamReadString(streamId)
    self.fillUnitIndex = streamReadUInt8(streamId)
    self.data = {}

    -- Read action-specific data
    if self.actionType == "ADD_BATCH" then
        self.data.amount = streamReadFloat32(streamId)
        self.data.age = streamReadFloat32(streamId)
    elseif self.actionType == "REMOVE_BATCH" then
        self.data.batchIndex = streamReadUInt8(streamId)
    elseif self.actionType == "SET_AGE" then
        self.data.batchIndex = streamReadUInt8(streamId)
        self.data.age = streamReadFloat32(streamId)
    elseif self.actionType == "SET_ALL_AGES" then
        self.data.age = streamReadFloat32(streamId)
    elseif self.actionType == "AGE" then
        self.data.hours = streamReadFloat32(streamId)
    elseif self.actionType == "AGE_CONTAINER" then
        self.data.hours = streamReadFloat32(streamId)
    elseif self.actionType == "EXPIRE" then
        self.data.batchIndex = streamReadInt8(streamId)
    elseif self.actionType == "EXPIRE_ALL" then
        -- entityType passed via containerId field, no additional data
    elseif self.actionType == "CLEAR_LOG" then
        -- No additional data
    elseif self.actionType == "RECONCILE" then
        -- No additional data
    end

    Log:debug("CONSOLE_REQUEST_READ: action=%s containerId=%s", self.actionType, self.containerId)
    self:run(connection)
end

--- Execute request on server (validates admin, executes command, sends response)
---@param connection table Network connection (sender)
function RmFreshConsoleRequestEvent:run(connection)
    -- This runs on SERVER only

    -- 1. Validate admin rights (NEVER trust client)
    local user = g_currentMission.userManager:getUserByConnection(connection)

    if user == nil then
        Log:warning("CONSOLE_REQUEST_RUN: User not found for connection (action=%s)", self.actionType)
        connection:sendEvent(RmFreshConsoleResponseEvent.new(false, "User not found", self.actionType))
        return
    end

    if not user:getIsMasterUser() then
        Log:debug("CONSOLE_REQUEST_RUN: Admin access denied for user %s", user:getId() or "unknown")
        connection:sendEvent(RmFreshConsoleResponseEvent.new(false, "Admin access required", self.actionType))
        return
    end

    -- 2. Execute the requested command
    local success = true
    local message = ""

    if self.actionType == "ADD_BATCH" then
        message = RmFreshConsole:executeAddBatch(
            self.containerId,
            self.fillUnitIndex,
            self.data.amount,
            self.data.age
        )
    elseif self.actionType == "REMOVE_BATCH" then
        message = RmFreshConsole:executeRemBatch(
            self.containerId,
            self.fillUnitIndex,
            self.data.batchIndex
        )
    elseif self.actionType == "SET_AGE" then
        message = RmFreshConsole:executeSetAge(
            self.containerId,
            self.fillUnitIndex,
            self.data.batchIndex,
            self.data.age
        )
    elseif self.actionType == "SET_ALL_AGES" then
        message = RmFreshConsole:executeSetAllAge(
            self.containerId,
            self.data.age
        )
    elseif self.actionType == "AGE" then
        message = RmFreshConsole:executeAge(self.data.hours)
    elseif self.actionType == "AGE_CONTAINER" then
        message = RmFreshConsole:executeAgeContainer(self.containerId, self.data.hours)
    elseif self.actionType == "EXPIRE" then
        -- Decode mode from batchIndex: >0 = single batch, 0 = fillUnit, -1 = container
        local batchIndex = self.data.batchIndex
        if batchIndex > 0 then
            message = RmFreshConsole:executeExpire(self.containerId, self.fillUnitIndex, batchIndex)
        elseif batchIndex == 0 then
            message = RmFreshConsole:executeExpireFillUnit(self.containerId, self.fillUnitIndex)
        else
            message = RmFreshConsole:executeExpireContainer(self.containerId)
        end
    elseif self.actionType == "EXPIRE_ALL" then
        -- entityType (or "all") passed via containerId field
        local entityType = self.containerId
        if string.lower(entityType) == "all" then
            message = RmFreshConsole:executeExpireAllTypes()
        else
            message = RmFreshConsole:executeExpireAll(entityType)
        end
    elseif self.actionType == "CLEAR_LOG" then
        message = RmFreshConsole:executeClearLog()
    elseif self.actionType == "RECONCILE" then
        message = RmFreshConsole:executeReconcile()
    else
        success = false
        message = "Unknown action type: " .. tostring(self.actionType)
    end

    -- Check if message indicates an error
    if message and message:sub(1, 5) == "Error" then
        success = false
    end

    Log:debug("CONSOLE_REQUEST_RUN: action=%s success=%s message=%s",
        self.actionType, tostring(success), message)

    -- 3. Send response to requester (Manager already broadcasts container update)
    connection:sendEvent(RmFreshConsoleResponseEvent.new(success, message, self.actionType))
end
