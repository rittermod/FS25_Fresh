---@class RmLossTracker
---Loss tracking module - owns lossLog, provides recording and calculation
RmLossTracker = {}

-- The loss log (transaction log, source of truth)
RmLossTracker.lossLog = {}

local Log = RmLogging.getLogger("Fresh")

--- Record an expiration event to the loss log
---@param container table Container data (from RmFreshManager.containers[id])
---@param amount number Amount that expired
---@param location string|nil Location name (from metadata)
function RmLossTracker:recordExpiration(container, amount, location)
    if not g_server then return end
    if not container then return end

    local env = g_currentMission.environment
    -- fillTypeName is in identityMatch.storage, not on container root
    local fillTypeName = container.identityMatch and container.identityMatch.storage and container.identityMatch.storage.fillTypeName
    local loc = location or (container.metadata and container.metadata.location) or "Unknown"

    -- Get farmId: prefer live entity value (fixes bale timing issue where ownerFarmId=0 at registration)
    -- At expiration time, ownership is definitely set
    local farmId = container.farmId or 0
    if farmId == 0 and container.runtimeEntity then
        local entity = container.runtimeEntity
        if entity.getOwnerFarmId then
            farmId = entity:getOwnerFarmId() or 0
        elseif entity.ownerFarmId and entity.ownerFarmId > 0 then
            farmId = entity.ownerFarmId
        end
        Log:trace("LOSS_FARMID_LIVE: container.farmId=%d entity.farmId=%d", container.farmId or 0, farmId)
    end

    -- Get persistent world object ID from identity match
    local objectUniqueId = nil
    if container.identityMatch and container.identityMatch.worldObject then
        objectUniqueId = container.identityMatch.worldObject.uniqueId
    end

    -- Calculate value at time of expiration (includes seasonal price factor)
    local value = 0
    local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(fillTypeName)
    if fillTypeIndex then
        local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
        if fillType and fillType.pricePerLiter then
            -- Get seasonal factor for current period (1-12)
            local seasonalFactor = 1.0
            local currentPeriod = env.currentPeriod or 1
            if fillType.economy and fillType.economy.factors and fillType.economy.factors[currentPeriod] then
                seasonalFactor = fillType.economy.factors[currentPeriod]
            end
            -- Get game difficulty price multiplier
            local priceMultiplier = EconomyManager.getPriceMultiplier()
            -- Calculate total value
            local pricePerLiter = fillType.pricePerLiter * seasonalFactor * priceMultiplier
            value = amount * pricePerLiter
            Log:trace("LOSS_VALUE: %s price=%.4f (base=%.4f * season=%.2f * eco=%.2f) value=%.2f",
                fillTypeName, pricePerLiter, fillType.pricePerLiter, seasonalFactor, priceMultiplier, value)
        end
    end

    -- Build loss entry
    local entry = {
        -- When
        year = env.currentYear or 1,
        period = env.currentPeriod or 1,
        dayInPeriod = env.currentDayInPeriod or 1,
        hour = env.currentHour or 0,

        -- What
        fillTypeName = fillTypeName,
        amount = amount,
        value = value,

        -- Where (persistent identity)
        location = loc,
        objectUniqueId = objectUniqueId,
        entityType = container.entityType or "unknown",

        -- Who
        farmId = farmId,
    }

    -- Add to server's loss log
    table.insert(self.lossLog, entry)

    -- Broadcast to all clients (MP delta sync)
    if g_currentMission.missionDynamicInfo.isMultiplayer then
        g_server:broadcastEvent(RmLossLogSyncEvent.new(entry))
        Log:debug("LOSS_BROADCAST: sent to clients")
    end

    Log:debug("LOSS_RECORDED: %s %.0f at %s (farm %d, Y%d P%d D%d H%d)",
        fillTypeName, amount, loc, farmId,
        env.currentYear or 1, env.currentPeriod or 1, env.currentDayInPeriod or 1, env.currentHour or 0)
end

--- Clear the loss log
function RmLossTracker:clearLog()
    self.lossLog = {}
    Log:debug("LOSS_LOG_CLEARED")
end

--- Check if log entry matches filters
---@param entry table Log entry
---@param filters table|nil Filter criteria
---@return boolean
function RmLossTracker:matchesLossFilters(entry, filters)
    if not filters then return true end

    if filters.farmId and entry.farmId ~= filters.farmId then return false end
    if filters.fillTypeName and entry.fillTypeName ~= filters.fillTypeName then return false end
    if filters.year and entry.year ~= filters.year then return false end
    if filters.period and entry.period ~= filters.period then return false end
    if filters.entityType and entry.entityType ~= filters.entityType then return false end
    if filters.objectUniqueId and entry.objectUniqueId ~= filters.objectUniqueId then return false end

    return true
end

--- Calculate total losses with optional filters
---@param filters table|nil { farmId, fillTypeName, year, period, entityType, objectUniqueId }
---@return number total, table byFillType
function RmLossTracker:calculateLosses(filters)
    local total = 0
    local byFillType = {}

    for _, entry in ipairs(self.lossLog) do
        if self:matchesLossFilters(entry, filters) then
            total = total + entry.amount
            byFillType[entry.fillTypeName] = (byFillType[entry.fillTypeName] or 0) + entry.amount
        end
    end

    return total, byFillType
end

--- Get losses for a specific day (for daily notification)
---@param farmId number Farm to filter by
---@param year number
---@param period number
---@param dayInPeriod number
---@return number totalUnits
function RmLossTracker:getLossesForDay(farmId, year, period, dayInPeriod)
    local total = 0
    for _, entry in ipairs(self.lossLog) do
        if entry.farmId == farmId and
           entry.year == year and
           entry.period == period and
           entry.dayInPeriod == dayInPeriod then
            total = total + entry.amount
        end
    end
    return total
end

--- Get previous day's date components
---@return number year, number period, number dayInPeriod
function RmLossTracker:getPreviousDay()
    local env = g_currentMission.environment
    local year = env.currentYear
    local period = env.currentPeriod
    local day = env.currentDayInPeriod - 1

    if day < 1 then
        -- Roll back to previous period
        period = period - 1
        if period < 1 then
            period = 12
            year = year - 1
        end
        day = env.daysPerPeriod or 1  -- Last day of previous period
    end

    return year, period, day
end

-- =============================================================================
-- DAILY NOTIFICATION METHODS
-- =============================================================================

--- Build notification message from total units lost (localized)
---@param totalUnits number Total units that expired
---@return string|nil message Notification message or nil if no losses
function RmLossTracker:buildDailyLossMessage(totalUnits)
    if not totalUnits or totalUnits <= 0 then
        return nil
    end
    -- Uses l10n key from languages/l10n_en.xml: fresh_dailyLossNotification
    return string.format(g_i18n:getText("fresh_dailyLossNotification"), totalUnits)
end

--- Send notification to all players of a specific farm
---@param farmId number Farm ID to notify
---@param message string Message to display
function RmLossTracker:notifyFarm(farmId, message)
    if not g_server then return end

    Log:debug("NOTIFY_FARM: farm=%d message=%s", farmId, message)

    -- In multiplayer: send event to farm's players
    if g_currentMission.missionDynamicInfo.isMultiplayer then
        for _, connection in pairs(g_server.clientConnections) do
            local user = g_currentMission.userManager:getUserByConnection(connection)
            if user then
                local player = g_currentMission:getPlayerByConnection(connection)
                if player and player.farmId == farmId then
                    connection:sendEvent(RmFreshNotificationEvent.new(message))
                end
            end
        end
    end

    -- Host/singleplayer: check if current player is on this farm
    local currentFarmId = g_currentMission:getFarmId()
    if currentFarmId == farmId then
        g_currentMission.hud:addSideNotification(
            FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
            message,
            nil,
            GuiSoundPlayer.SOUND_SAMPLES.NOTIFICATION
        )
    end
end

--- Handle day change - send loss notifications for previous day
---@param containers table RmFreshManager.containers (for farmId discovery)
function RmLossTracker:onDayChanged(containers)
    if not g_server then return end

    Log:trace(">>> RmLossTracker:onDayChanged()")

    local prevYear, prevPeriod, prevDay = self:getPreviousDay()
    Log:debug("DAILY_NOTIFY: checking losses for Y%d P%d D%d (lossLog has %d entries)",
        prevYear, prevPeriod, prevDay, #self.lossLog)

    -- Get unique farmIds from lossLog entries for the previous day
    -- NOTE: We use lossLog (not containers) because containers may have been deleted after expiration
    local farmIds = {}
    for _, entry in ipairs(self.lossLog) do
        if entry.year == prevYear and entry.period == prevPeriod and entry.dayInPeriod == prevDay then
            if entry.farmId then
                farmIds[entry.farmId] = true
            end
        end
    end

    -- Count unique farms with losses
    local farmCount = 0
    for _ in pairs(farmIds) do farmCount = farmCount + 1 end
    Log:debug("DAILY_NOTIFY: found %d farms with losses on previous day", farmCount)

    -- Send notification to each farm with losses
    for farmId, _ in pairs(farmIds) do
        local totalLost = self:getLossesForDay(farmId, prevYear, prevPeriod, prevDay)
        Log:debug("DAILY_NOTIFY: farm=%d totalLost=%.0f", farmId, totalLost)
        if totalLost > 0 then
            local message = self:buildDailyLossMessage(totalLost)
            if message then
                self:notifyFarm(farmId, message)
            end
        end
    end

    Log:trace("<<< RmLossTracker:onDayChanged()")
end
