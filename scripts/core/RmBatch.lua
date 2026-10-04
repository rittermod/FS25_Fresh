-- RmBatch.lua
-- Purpose: Reusable batch operations for perishable goods (container-agnostic)
-- Author: Ritter
-- Architecture: Part of core/ foundation (Pure utility, no FS25 API except g_i18n)
-- Functions: create, age, isExpired, format, real remaining time, FIFO consume, merge, etc.

RmBatch = {}

-- Get logger (RmLogging loaded before this module in main.lua)
local Log = RmLogging.getLogger("Fresh")

--- Smallest batch amount displays and warnings count; matches consumeFIFO's cleanup threshold.
RmBatch.MIN_AMOUNT = 0.001

--- Create a new batch
---@param amount number Quantity in this batch
---@param ageInPeriods number Initial age (default 0)
---@return table PerishableBatch { amount, ageInPeriods, expiredLogged }
function RmBatch.create(amount, ageInPeriods)
    return {
        amount = amount,
        ageInPeriods = ageInPeriods or 0,
        expiredLogged = false -- Prevents duplicate expiration log entries
    }
end

--- Age a batch by increment
---@param batch table PerishableBatch
---@param increment number Age increment (1 / (daysPerPeriod * 24))
function RmBatch.age(batch, increment)
    batch.ageInPeriods = batch.ageInPeriods + increment
end

--- Check if batch is expired
---@param batch table PerishableBatch
---@param threshold number Expiration threshold (default 1.0)
---@return boolean
function RmBatch.isExpired(batch, threshold)
    return batch.ageInPeriods >= (threshold or 1.0)
end

--- Near expiration when real hours left <= warningHours (an expired batch counts); never at multiplier 0.
---@param batch table PerishableBatch
---@param warningHours number Hours threshold (e.g., 24)
---@param expirationThreshold number Expiration threshold in periods
---@param daysPerPeriod number Days per in-game month
---@param multiplier number|nil Storage class aging multiplier (default 1.0, 0 = disabled/never expires)
---@return boolean
function RmBatch.isNearExpiration(batch, warningHours, expirationThreshold, daysPerPeriod, multiplier)
    multiplier = multiplier or 1.0
    if multiplier == 0 then
        return false -- Disabled storage class: never expires, never near expiration
    end
    local remainingPeriods = (expirationThreshold or 1.0) - batch.ageInPeriods
    local remainingHours = remainingPeriods * (daysPerPeriod or 1) * 24 / multiplier
    return remainingHours <= (warningHours or 24)
end

--- Format batch age for console output: hours under 48h, else days
---@param batch table PerishableBatch
---@return string Age in days (e.g., "0 days", "15 days", "45 days")
function RmBatch.formatAge(batch, daysPerPeriod)
    daysPerPeriod = daysPerPeriod or 1
    local totalHours = batch.ageInPeriods * daysPerPeriod * 24
    if totalHours < 48 then
        return string.format("%dh", math.floor(totalHours))
    else
        return string.format("%dd", math.floor(totalHours / 24))
    end
end

--- Localized time to expiry: hours under 48h, days under 60d, else months (fresh_expired, fresh_expires_* keys).
---@param batch table PerishableBatch
---@param threshold number Expiration threshold in periods
---@param daysPerPeriod number Days per in-game month (from environment)
---@param multiplier number|nil Storage class aging multiplier (default 1.0, 0 = disabled/never expires)
---@return string Formatted expiration time (e.g., "12 hours", "4 days", "2 months")
function RmBatch.formatExpiresIn(batch, threshold, daysPerPeriod, multiplier)
    local remainingPeriods = threshold - batch.ageInPeriods

    if remainingPeriods <= 0 then
        return g_i18n:getText("fresh_expired")
    end

    multiplier = multiplier or 1.0
    if multiplier == 0 then
        return g_i18n:getText("fresh_expires_never")
    end

    local remainingHours = remainingPeriods * daysPerPeriod * 24 / multiplier

    if remainingHours < 48 then
        -- Hours (< 2 days remaining)
        local hours = math.max(1, math.floor(remainingHours))
        if hours == 1 then
            return g_i18n:getText("fresh_expires_hour")
        else
            return string.format(g_i18n:getText("fresh_expires_hours"), hours)
        end
    elseif remainingHours < 1440 then
        -- Days (< 60 days remaining)
        local days = math.max(1, math.floor(remainingHours / 24))
        if days == 1 then
            return g_i18n:getText("fresh_expires_day")
        else
            return string.format(g_i18n:getText("fresh_expires_days"), days)
        end
    else
        -- Months (>= 60 days remaining)
        local months = remainingPeriods / multiplier
        return string.format(g_i18n:getText("fresh_expires_months"), months)
    end
end

--- Real periods left, for ranking; a non-positive value is threshold - age in age periods (only sign and order count)
---@param batch table PerishableBatch
---@param threshold number Expiration threshold in periods (callers skip ranking when it is nil)
---@param multiplier number Aging multiplier (0 = never expires)
---@return number remaining threshold - age when expired, math.huge when multiplier is 0, else divided by it
function RmBatch.getRealRemaining(batch, threshold, multiplier)
    local remaining = threshold - batch.ageInPeriods
    if remaining <= 0 then
        return remaining
    end
    if multiplier == 0 then
        return math.huge
    end
    return remaining / multiplier
end

--- Compact HUD form of formatExpiresIn (same breakpoints, unlocalized h/d/m units).
---@param remainingHours number Hours remaining until expiration
---@return string Compact time string (e.g., "24h", "3d", "2.1m")
function RmBatch.formatRemainingShort(remainingHours)
    if remainingHours <= 0 then
        return "0h"
    elseif remainingHours < 48 then
        return string.format("%dh", math.max(1, math.floor(remainingHours)))
    elseif remainingHours < 1440 then
        return string.format("%dd", math.floor(remainingHours / 24))
    else
        return string.format("%.1fm", remainingHours / (24 * 30))
    end
end

--- Get total amount across all batches
---@param batches table Array of PerishableBatch
---@return number Total amount
function RmBatch.getTotalAmount(batches)
    local total = 0
    for _, batch in ipairs(batches) do
        total = total + batch.amount
    end
    return total
end

--- Get oldest batch (first in array)
---@param batches table Array of PerishableBatch
---@return table|nil Oldest batch or nil if empty
function RmBatch.getOldest(batches)
    if batches == nil or #batches == 0 then return nil end
    return batches[1] -- First batch = oldest (FIFO order)
end

--- Remove expired batches and return removed amount
---@param batches table Array of PerishableBatch (modified in place)
---@param threshold number Expiration threshold
---@return number Total amount removed
function RmBatch.removeExpired(batches, threshold)
    local removed = 0
    local i = 1
    while i <= #batches do
        if RmBatch.isExpired(batches[i], threshold) then
            removed = removed + batches[i].amount
            table.remove(batches, i)
        else
            i = i + 1
        end
    end
    return removed
end

--- Calculate weighted average age of all batches
---@param batches table Array of { amount, ageInPeriods }
---@return number Weighted average age, or 0 if no batches
function RmBatch.weightedAverageAge(batches)
    if batches == nil or #batches == 0 then
        return 0
    end

    local totalAmount = 0
    local weightedAgeSum = 0

    for _, batch in ipairs(batches) do
        totalAmount = totalAmount + batch.amount
        weightedAgeSum = weightedAgeSum + (batch.amount * batch.ageInPeriods)
    end

    return totalAmount > 0 and (weightedAgeSum / totalAmount) or 0
end

--- Weighted average age of the amount consumeFIFO would take, without consuming it.
---@param batches table Array of PerishableBatch (NOT modified)
---@param amount number Amount to peek
---@return number Weighted average age of batches that would be consumed, or 0 if no batches
function RmBatch.peekFIFO(batches, amount)
    if batches == nil or #batches == 0 or amount <= 0 then
        return 0
    end

    local remaining = amount
    local weightedAgeSum = 0
    local totalAmount = 0

    for _, batch in ipairs(batches) do
        if remaining <= 0 then break end

        local amountFromBatch = math.min(batch.amount, remaining)
        weightedAgeSum = weightedAgeSum + (amountFromBatch * batch.ageInPeriods)
        totalAmount = totalAmount + amountFromBatch
        remaining = remaining - amountFromBatch
    end

    if totalAmount == 0 then
        return 0
    end

    return weightedAgeSum / totalAmount
end

--- Consume amount oldest-first; returns the consumed batches with their own ages (for transfers).
---@param batches table Array of PerishableBatch (modified in place)
---@param amount number Amount to consume
---@return table { consumed = number, batches = array of {amount, ageInPeriods} }
function RmBatch.consumeFIFO(batches, amount)
    local remaining = amount
    local consumedBatches = {}
    local totalConsumed = 0

    while remaining > 0 and #batches > 0 do
        local oldest = batches[1]
        if oldest.amount <= remaining then
            -- Consume entire batch - add to consumed list with original age
            table.insert(consumedBatches, {
                amount = oldest.amount,
                ageInPeriods = oldest.ageInPeriods
            })
            totalConsumed = totalConsumed + oldest.amount
            remaining = remaining - oldest.amount
            table.remove(batches, 1)
        else
            -- Partial consumption - split batch, consumed portion keeps same age
            table.insert(consumedBatches, {
                amount = remaining,
                ageInPeriods = oldest.ageInPeriods
            })
            totalConsumed = totalConsumed + remaining
            oldest.amount = oldest.amount - remaining
            -- Clean up empty/near-zero batches (floating-point artifacts)
            if oldest.amount < 0.001 then
                table.remove(batches, 1)
            end
            remaining = 0
        end
    end

    return { consumed = totalConsumed, batches = consumedBatches }
end

--- Sort oldest first, then merge adjacent batches whose ages differ by <= threshold periods (weighted age).
---@param batches table Array of PerishableBatch (modified in place, sorted by age descending)
---@param threshold number|nil Age difference threshold for merging (default 0.01 periods)
---@return number Count of merges performed
function RmBatch.mergeSimilarBatches(batches, threshold)
    if batches == nil or #batches < 2 then
        return 0 -- Nothing to merge
    end

    threshold = threshold or 0.01 -- Default, in periods
    local initialCount = #batches

    -- Log input state (only if multiple batches - reduces noise)
    if initialCount >= 3 then
        local ages = {}
        for idx, b in ipairs(batches) do
            ages[idx] = string.format("%.4f", b.ageInPeriods)
        end
        Log:trace("MERGE_INPUT: n=%d, ages=[%s]", initialCount, table.concat(ages, ", "))
    end

    -- Sort by age descending (oldest first for FIFO consumption)
    -- This ensures similar ages are adjacent for merge comparison
    -- Non-adjacent similar-age batches now become adjacent
    table.sort(batches, function(a, b)
        return a.ageInPeriods > b.ageInPeriods
    end)

    local mergeCount = 0
    local i = 1

    -- Adjacent merge pass - O(n) after sort
    -- Chain merge: don't increment i after merge to check if result merges with next
    while i < #batches do
        local current = batches[i]
        local nextBatch = batches[i + 1]

        local ageDiff = math.abs(current.ageInPeriods - nextBatch.ageInPeriods)

        if ageDiff <= threshold then
            -- Merge: weighted average age, combined amount
            local totalAmount = current.amount + nextBatch.amount
            local weightedAge = (current.amount * current.ageInPeriods +
                nextBatch.amount * nextBatch.ageInPeriods) / totalAmount

            Log:trace("MERGE_OP: %.0fL@%.4f + %.0fL@%.4f -> %.0fL@%.4f (diff=%.4f)",
                current.amount, current.ageInPeriods,
                nextBatch.amount, nextBatch.ageInPeriods,
                totalAmount, weightedAge, ageDiff)

            current.amount = totalAmount
            current.ageInPeriods = weightedAge

            -- Remove the merged batch
            table.remove(batches, i + 1)
            mergeCount = mergeCount + 1
            -- Don't increment i - check if new merged batch can merge with next
        else
            i = i + 1
        end
    end

    -- Log result summary
    if mergeCount > 0 then
        Log:debug("MERGE_RESULT: %d->%d batches (%d merges)", initialCount, #batches, mergeCount)
    end

    return mergeCount
end
