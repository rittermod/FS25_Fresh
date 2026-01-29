-- RmFreshConsole.lua
-- Purpose: Console commands using RmFreshManager APIs
-- Author: Ritter
-- Architecture: Read-only commands using centralized FreshManager

RmFreshConsole = {}
RmFreshConsole.targets = {} -- index -> containerId for command targeting

-- Get logger
local Log = RmLogging.getLogger("Fresh")

-- ============================================================================
-- Type Resolution (AC: 7)
-- ============================================================================

--- Type aliases for convenience
--- NOTE: "husbandryfood" is the ENTITY_TYPE for husbandry food containers
---       PlaceableAdapter handles general husbandry storage (type "placeable")
RmFreshConsole.TYPE_ALIASES = {
    v = "vehicle",
    vehicle = "vehicle",
    b = "bale",
    bale = "bale",
    p = "placeable",
    placeable = "placeable",
    h = "husbandryfood",
    hf = "husbandryfood",
    husbandryfood = "husbandryfood",
    s = "stored",
    stored = "stored"
}

--- Resolve type string to canonical type name
---@param typeStr string|nil Type string from user input
---@return string|nil Canonical type name or nil if unknown
function RmFreshConsole:resolveType(typeStr)
    if typeStr == nil then
        return nil
    end
    return self.TYPE_ALIASES[string.lower(typeStr)]
end

--- Get valid type names for error messages
---@return string Comma-separated list of valid types
function RmFreshConsole:getValidTypeNames()
    return "vehicle (v), bale (b), placeable (p), husbandryfood (h/hf), stored (s), all"
end

-- ============================================================================
-- Helper Functions
-- ============================================================================

--- Get entity name from container
---@param container table Container entry
---@return string Entity name or fallback
function RmFreshConsole:getEntityName(container)
    -- Use runtimeEntity (preferred) or entity (legacy)
    local entity = container.runtimeEntity or container.entity
    if entity ~= nil and entity.getName ~= nil then
        local name = entity:getName()
        if name ~= nil and name ~= "" then
            return name
        end
    end
    if container.metadata and container.metadata.location then
        return container.metadata.location
    end
    return "unknown"
end

--- Get batch count for container
---@param container table Container entry
---@return number Count of batches
function RmFreshConsole:getBatchCount(container)
    if container.batches then
        return #container.batches
    end
    return 0
end

--- Get oldest batch for container
---@param container table Container entry
---@return table|nil Oldest batch or nil
function RmFreshConsole:getOldestBatch(container)
    return RmBatch.getOldest(container.batches)
end

-- ============================================================================
-- Admin Access Control (AC: 1, 5, 8, 11)
-- ============================================================================

--- Check if current user has admin access
--- Server (host or singleplayer) is always admin
--- Clients must have authenticated as master user
---@return boolean True if admin
function RmFreshConsole:isAdmin()
    -- Server (host or dedicated) is always admin
    if g_server ~= nil then
        return true
    end
    -- Client: check if master user (admin password entered)
    return g_currentMission.isMasterUser == true
end

--- Require admin access for a command
--- Returns success and optional error message
---@param commandName string Command name for error message
---@return boolean success True if admin
---@return string|nil errorMsg Error message if not admin
function RmFreshConsole:requireAdmin(commandName)
    if not self:isAdmin() then
        return false, string.format("Error: '%s' requires admin access", commandName)
    end
    return true
end

-- ============================================================================
-- Console Command Registration (AC: 10)
-- ============================================================================

--- Register console commands
function RmFreshConsole:registerCommands()
    -- Read-only commands (all users)
    addConsoleCommand("fList", "List containers (fList [type])", "consoleCommandList", self)
    addConsoleCommand("fInspect", "Inspect container (fInspect <#>)", "consoleCommandInspect", self)
    addConsoleCommand("fBatches", "Show batches (fBatches <#>)", "consoleCommandBatches", self)
    -- Note: fTest is registered by RmTestRunner when tests/ folder exists

    -- Batch manipulation commands (admin only) - removed fillUnit parameter
    addConsoleCommand("fAddBatch", "Add batch (fAddBatch <#> <amount> [age])", "consoleCommandAddBatch", self)
    addConsoleCommand("fRemBatch", "Remove batch (fRemBatch <#> <batchIdx>)", "consoleCommandRemBatch", self)
    addConsoleCommand("fSetAge", "Set batch age (fSetAge <#> <batchIdx> <age>)", "consoleCommandSetAge", self)
    addConsoleCommand("fSetAllAge", "Set all ages (fSetAllAge <#> [age])", "consoleCommandSetAllAge", self)

    -- Time/expiration commands (admin only)
    addConsoleCommand("fAge", "Simulate time (fAge <hours>)", "consoleCommandAge", self)
    addConsoleCommand("fAgeContainer", "Age container (fAgeContainer <#> <hours>)", "consoleCommandAgeContainer", self)
    addConsoleCommand("fExpire", "Force expire (fExpire <#> [batchIdx])", "consoleCommandExpire", self)
    addConsoleCommand("fExpireAll", "Expire all (fExpireAll <type|all>)", "consoleCommandExpireAll", self)

    -- Statistics/debug commands (read-only, all users)
    addConsoleCommand("fStats", "Show statistics", "consoleCommandStats", self)
    addConsoleCommand("fStatus", "Expiring soon (fStatus [hours])", "consoleCommandStatus", self)
    addConsoleCommand("fLog", "Show loss log (fLog [count])", "consoleCommandLog", self)
    addConsoleCommand("fDump", "Dump state to log", "consoleCommandDump", self)

    -- Statistics/debug admin commands (admin only)
    addConsoleCommand("fClearLog", "Clear loss log (admin)", "consoleCommandClearLog", self)
    addConsoleCommand("fReconcile", "Reconcile with game state (admin)", "consoleCommandReconcile", self)

    Log:info(
    "CONSOLE: fList, fInspect, fBatches, fAddBatch, fRemBatch, fSetAge, fSetAllAge, fAge, fAgeContainer, fExpire, fExpireAll, fStats, fStatus, fLog, fDump, fClearLog, fReconcile commands registered")
end

--- Unregister console commands
function RmFreshConsole:unregisterCommands()
    -- Read-only commands
    removeConsoleCommand("fList")
    removeConsoleCommand("fInspect")
    removeConsoleCommand("fBatches")
    -- Note: fTest is unregistered by RmTestRunner when tests/ folder exists

    -- Batch manipulation commands
    removeConsoleCommand("fAddBatch")
    removeConsoleCommand("fRemBatch")
    removeConsoleCommand("fSetAge")
    removeConsoleCommand("fSetAllAge")

    -- Time/expiration commands
    removeConsoleCommand("fAge")
    removeConsoleCommand("fAgeContainer")
    removeConsoleCommand("fExpire")
    removeConsoleCommand("fExpireAll")

    -- Statistics/debug commands
    removeConsoleCommand("fStats")
    removeConsoleCommand("fStatus")
    removeConsoleCommand("fLog")
    removeConsoleCommand("fDump")
    removeConsoleCommand("fClearLog")
    removeConsoleCommand("fReconcile")

    self.targets = {}
    Log:debug("CONSOLE: commands unregistered")
end

-- ============================================================================
-- fList Command (AC: 3, 4, 8)
-- ============================================================================

--- Console command: List containers from RmFreshManager
---@param typeStr string|nil Type filter (optional)
---@return string Console output message
function RmFreshConsole:consoleCommandList(typeStr)
    self.targets = {}

    local containers = {}

    if typeStr == nil or string.lower(typeStr) == "all" then
        -- Get all containers, convert table to array
        for _, container in pairs(RmFreshManager:getAllContainers()) do
            table.insert(containers, container)
        end
    else
        local resolvedType = self:resolveType(typeStr)
        if resolvedType == nil then
            return string.format("Unknown type '%s'. Valid: %s", typeStr, self:getValidTypeNames())
        end
        containers = RmFreshManager:getContainersByType(resolvedType)
    end

    if #containers == 0 then
        return "No containers found"
    end

    -- Sort by containerId for stable output
    table.sort(containers, function(a, b)
        return a.id < b.id
    end)

    local daysPerPeriod = (g_currentMission and g_currentMission.environment and g_currentMission.environment.daysPerPeriod) or 1

    print("=== Perishable Containers ===")
    for i, container in ipairs(containers) do
        self.targets[i] = container.id

        local name = self:getEntityName(container)
        local batchCount = self:getBatchCount(container)
        local oldest = self:getOldestBatch(container)
        local ageRaw = oldest and string.format("%.2f", oldest.ageInPeriods) or "0.00"
        local totalAmount = RmBatch.getTotalAmount(container.batches or {})

        -- Show fillType from identityMatch
        local fillTypeName = container.identityMatch and container.identityMatch.storage
            and container.identityMatch.storage.fillTypeName or "?"

        -- Human-readable expiry time
        local expiresText = ""
        if oldest then
            local threshold = RmFreshSettings:getExpiration(fillTypeName)
            if threshold then
                expiresText = " (" .. RmBatch.formatExpiresIn(oldest, threshold, daysPerPeriod) .. ")"
            end
        end

        print(string.format("#%d: %s \"%s\" [%s] %s amount=%.0f batches=%d oldest=%sp%s",
            i, container.entityType, name, container.id, fillTypeName, totalAmount, batchCount, ageRaw, expiresText))
    end

    return string.format("Listed %d containers", #containers)
end

-- ============================================================================
-- fInspect Command (AC: 5, 8)
-- ============================================================================

--- Console command: Show detailed container info
---@param indexStr string Container index from fList
---@return string Console output message
function RmFreshConsole:consoleCommandInspect(indexStr)
    if next(self.targets) == nil then
        return "No containers indexed. Run fList first."
    end

    local index = tonumber(indexStr)
    if index == nil or index < 1 or index > #self.targets then
        return string.format("Invalid index. Valid range: 1-%d", #self.targets)
    end

    local containerId = self.targets[index]
    local container = RmFreshManager:getContainer(containerId)

    if container == nil then
        return "Container no longer exists. Run fList to refresh."
    end

    print(string.format("Container #%d: %s", index, container.id))
    print(string.format("  name: \"%s\"", self:getEntityName(container)))
    print(string.format("  entityType: %s", container.entityType))
    print(string.format("  farmId: %d", container.farmId or 0))

    -- Show identityMatch info
    if container.identityMatch then
        local im = container.identityMatch
        if im.worldObject then
            print(string.format("  worldObject.uniqueId: %s", im.worldObject.uniqueId or "nil"))
        end
        if im.storage then
            print(string.format("  fillType: %s", im.storage.fillTypeName or "?"))
            print(string.format("  fillUnitHint: %d", im.storage.fillUnitHint or 1))
        end
    end

    -- Step 4: Show capability flags
    local canFill = container.playerCanFill
    local canEmpty = container.playerCanEmpty
    if canFill ~= nil or canEmpty ~= nil then
        print(string.format("  playerCanFill: %s", canFill == nil and "nil" or tostring(canFill)))
        print(string.format("  playerCanEmpty: %s", canEmpty == nil and "nil" or tostring(canEmpty)))
    end

    -- Flat batches at container root
    local batches = container.batches or {}
    local total = RmBatch.getTotalAmount(batches)
    local oldest = RmBatch.getOldest(batches)
    local ageRaw = oldest and string.format("%.2f", oldest.ageInPeriods) or "0.00"
    local daysPerPeriod = (g_currentMission and g_currentMission.environment and g_currentMission.environment.daysPerPeriod) or 1
    local ageStr = oldest and RmBatch.formatAge(oldest, daysPerPeriod) or "0h"

    -- Human-readable expires-in
    local expiresStr = ""
    if oldest then
        local fillTypeName = container.identityMatch and container.identityMatch.storage
            and container.identityMatch.storage.fillTypeName
        local threshold = fillTypeName and RmFreshSettings:getExpiration(fillTypeName)
        if threshold then
            expiresStr = string.format(", expires in %s", RmBatch.formatExpiresIn(oldest, threshold, daysPerPeriod))
        end
    end

    print(string.format("\n  Batches: %d", #batches))
    print(string.format("  Total amount: %.0f", total))
    print(string.format("  Oldest: %sp, aged %s%s", ageRaw, ageStr, expiresStr))

    return ""
end

-- ============================================================================
-- fBatches Command (AC: 6, 8)
-- ============================================================================

--- Console command: Show batches for a container ---@param indexStr string Container index from fList
---@return string Console output message
function RmFreshConsole:consoleCommandBatches(indexStr)
    if next(self.targets) == nil then
        return "No containers indexed. Run fList first."
    end

    local index = tonumber(indexStr)
    if index == nil or index < 1 or index > #self.targets then
        return string.format("Invalid index. Valid range: 1-%d", #self.targets)
    end

    local containerId = self.targets[index]
    local container = RmFreshManager:getContainer(containerId)

    if container == nil then
        return "Container no longer exists. Run fList to refresh."
    end

    -- Flat batches at container root
    local batches = container.batches or {}
    if #batches == 0 then
        return "No batches in container"
    end

    local fillTypeName = container.identityMatch and container.identityMatch.storage
        and container.identityMatch.storage.fillTypeName or "UNKNOWN"
    local name = self:getEntityName(container)
    local daysPerPeriod = (g_currentMission and g_currentMission.environment and g_currentMission.environment.daysPerPeriod) or 1
    local threshold = RmFreshSettings:getExpiration(fillTypeName)

    print(string.format("Container #%d \"%s\" (%s):", index, name, fillTypeName))

    for i, batch in ipairs(batches) do
        local ageRaw = string.format("%.2f", batch.ageInPeriods)
        local ageStr = RmBatch.formatAge(batch, daysPerPeriod)
        local expiresStr = threshold and RmBatch.formatExpiresIn(batch, threshold, daysPerPeriod) or "?"
        print(string.format("  [%d] amount=%.0f, age=%sp (%s, expires %s)", i, batch.amount, ageRaw, ageStr, expiresStr))
    end

    return ""
end

-- ============================================================================
-- Execute Methods (AC: 2, 3, 4, 6, 7, 9, 10, 12)
-- Server-side execution for batch manipulation commands
-- ============================================================================

--- Execute add batch operation --- Adds to BOTH game fill (via adapter) AND batch tracking (via Manager)
--- Order: Game fill FIRST, then Manager (abort if game fails to prevent desync)
---@param containerId string Container ID
---@param amount number Amount to add
---@param age number|nil Age (default 0)
---@return string Result message
function RmFreshConsole:executeAddBatch(containerId, amount, age)
    age = age or 0

    -- Get container
    local container = RmFreshManager:getContainer(containerId)
    if not container then
        return "Error: Container not found. Run fList to refresh."
    end

    -- Get adapter for entity type
    local adapter = RmFreshManager:getAdapterForType(container.entityType)
    if not adapter then
        return string.format("Error: No adapter for entity type '%s'", container.entityType)
    end

    -- Check runtime entity exists
    if not container.runtimeEntity then
        return "Error: Container has no runtime entity reference"
    end

    -- Get fill level before (adapter uses containerId)
    local fillBefore, _ = adapter:getFillLevel(containerId)

    -- Suppress automatic batch creation from fill change hook (we'll add batch with specified age)
    RmFreshManager.suppressFillChangeBatch = true

    -- Add to game fill FIRST (via adapter) - abort if fails to prevent desync
    local adapterSuccess = adapter:addFillLevel(containerId, amount)
    if adapterSuccess == false then
        RmFreshManager.suppressFillChangeBatch = false
        return "Error: Failed to add fill to game entity. Batch not created."
    end

    -- Verify fill actually changed (additional safety check)
    local fillAfter, _ = adapter:getFillLevel(containerId)
    local actualDelta = fillAfter - fillBefore

    if actualDelta <= 0 then
        RmFreshManager.suppressFillChangeBatch = false
        return string.format("Error: Game fill unchanged (capacity full?). Fill: %.0f. Batch not created.", fillAfter)
    end

    -- Add to batch tracking with ACTUAL amount added
    RmFreshManager:addBatch(containerId, actualDelta, age)

    -- Re-enable automatic batch creation
    RmFreshManager.suppressFillChangeBatch = false

    return string.format("Added batch: %.0f units at age %.2f. Fill level: %.0f -> %.0f",
        actualDelta, age, fillBefore, fillAfter)
end

--- Execute remove batch operation --- Removes from BOTH game fill AND batch tracking
--- Order: Game fill FIRST, then Manager (abort if game fails to prevent desync)
---@param containerId string Container ID
---@param batchIndex number Batch index (1-based)
---@return string Result message
function RmFreshConsole:executeRemBatch(containerId, batchIndex)
    -- Get container
    local container = RmFreshManager:getContainer(containerId)
    if not container then
        return "Error: Container not found. Run fList to refresh."
    end

    -- Flat batches at container root
    local batches = container.batches or {}
    local batch = batches[batchIndex]
    if not batch then
        return string.format("Error: Batch [%d] not found. Use fBatches to see batches (valid range: 1-%d).", batchIndex,
            #batches)
    end
    local batchAmount = batch.amount
    local batchAge = batch.ageInPeriods

    -- Get adapter
    local adapter = RmFreshManager:getAdapterForType(container.entityType)
    if not adapter then
        return string.format("Error: No adapter for entity type '%s'", container.entityType)
    end

    -- Check runtime entity exists
    if not container.runtimeEntity then
        return "Error: Container has no runtime entity reference"
    end

    -- Get fill level before (adapter uses containerId)
    local fillBefore, _ = adapter:getFillLevel(containerId)

    -- Suppress automatic batch consumption from fill change hook (we'll remove batch directly)
    RmFreshManager.suppressFillChangeBatch = true

    -- Remove from game fill FIRST (via adapter) - abort if fails to prevent desync
    local adapterSuccess = adapter:addFillLevel(containerId, -batchAmount)
    if adapterSuccess == false then
        RmFreshManager.suppressFillChangeBatch = false
        return "Error: Failed to remove fill from game entity. Batch not removed."
    end

    -- Verify fill actually changed
    local fillAfter, _ = adapter:getFillLevel(containerId)

    -- Remove from batch tracking
    local removedBatch, message = RmFreshManager:removeBatchByIndex(containerId, batchIndex)

    -- Re-enable automatic batch handling
    RmFreshManager.suppressFillChangeBatch = false

    if not removedBatch then
        -- Game fill was removed but Manager failed - log warning (rare edge case)
        Log:warning("CONSOLE_DESYNC: Game fill removed but Manager removal failed: %s", message or "unknown")
        return string.format("Warning: Game fill removed but batch tracking failed: %s", message or "unknown")
    end

    return string.format("Removed batch [%d]: %.0f units, age %.2f. Fill level: %.0f -> %.0f",
        batchIndex, batchAmount, batchAge, fillBefore, fillAfter)
end

--- Execute set batch age operation --- Only modifies batch tracking (game fill unchanged)
---@param containerId string Container ID
---@param batchIndex number Batch index (1-based)
---@param age number New age
---@return string Result message
function RmFreshConsole:executeSetAge(containerId, batchIndex, age)
    -- No fillUnitIndex parameter
    local success, message = RmFreshManager:setBatchAge(containerId, batchIndex, age)

    if not success then
        -- Add actionable hints to common errors
        if message == "Container not found" then
            return "Error: Container not found. Run fList to refresh."
        elseif message == "Fill unit not found" then
            return "Error: Fill unit not found. Use fBatches to see fillUnits."
        elseif message == "Batch not found" then
            return "Error: Batch not found. Use fBatches to see valid batch indices."
        end
        return "Error: " .. (message or "Failed to set batch age")
    end

    return message
end

--- Execute set all batch ages operation
--- Only modifies batch tracking (game fill unchanged)
---@param containerId string Container ID
---@param age number|nil New age (default 0 for fresh)
---@return string Result message
function RmFreshConsole:executeSetAllAge(containerId, age)
    age = age or 0 -- Default to fresh

    local success, message = RmFreshManager:setAllBatchAges(containerId, age)

    if not success then
        -- Add actionable hints to common errors
        if message == "Container not found" then
            return "Error: Container not found. Run fList to refresh."
        end
        return "Error: " .. (message or "Failed to set batch ages")
    end

    return message
end

-- ============================================================================
-- Time Simulation Execute Methods (AC: 2, 3, 4, 6, 14)
-- ============================================================================

--- Execute global time simulation
--- Ages all containers by specified hours, processes expirations
---@param hours number Hours to simulate
---@return string Result message
function RmFreshConsole:executeAge(hours)
    local stats = RmFreshManager:simulateHours(hours)

    if stats == nil then
        return "Error: Failed to simulate time"
    end

    return string.format("Aged all containers by %.0f hours.\nProcessed %d containers, %d batches expired (%.0f units)",
        hours, stats.containersProcessed, stats.batchesExpired, stats.amountExpired)
end

--- Execute container-specific time simulation
--- Ages only the specified container by hours
---@param containerId string Container ID
---@param hours number Hours to simulate
---@return string Result message
function RmFreshConsole:executeAgeContainer(containerId, hours)
    local stats = RmFreshManager:simulateHoursForContainer(containerId, hours)

    if stats == nil then
        return "Error: Container not found. Run fList to refresh."
    end

    return string.format("Aged container by %.0f hours.\n%d batches expired (%.0f units)",
        hours, stats.batchesExpired, stats.amountExpired)
end

-- ============================================================================
-- Force Expiration Execute Methods (AC: 8, 9, 10, 12, 13, 14)
-- ============================================================================

--- Execute single batch expiration ---@param containerId string Container ID
---@param batchIndex number Batch index (1-based)
---@return string Result message
function RmFreshConsole:executeExpire(containerId, batchIndex)
    -- No fillUnitIndex parameter
    local expiredAmount, msg = RmFreshManager:forceExpire(containerId, batchIndex)

    if expiredAmount == nil then
        -- Add actionable hints
        if msg == "Container not found" then
            return "Error: Container not found. Run fList to refresh."
        elseif msg == "No batches found" then
            return "Error: No batches in container. Use fBatches to see batches."
        elseif msg == "Batch not found" then
            return "Error: Batch not found. Use fBatches to see batch indices."
        end
        return "Error: " .. (msg or "Failed to expire batch")
    end

    return string.format("Expired batch [%d]: %.0f units", batchIndex, expiredAmount)
end

--- Execute container expiration - expires all batches in a container --- Iterates from highest index to lowest to avoid index shifting
---@param containerId string Container ID
---@return string Result message
function RmFreshConsole:executeExpireContainer(containerId)
    local container = RmFreshManager:getContainer(containerId)
    if not container then
        return "Error: Container not found. Run fList to refresh."
    end

    local batches = container.batches or {}
    local batchCount = #batches
    local totalExpired = 0

    if batchCount == 0 then
        return "No batches to expire"
    end

    -- Iterate backwards to avoid index shifting
    for i = #batches, 1, -1 do
        local expiredAmount = RmFreshManager:forceExpire(containerId, i)
        if expiredAmount then
            totalExpired = totalExpired + expiredAmount
        end
    end

    return string.format("Expired %d batches: %.0f units", batchCount, totalExpired)
end

--- Execute type-filtered expiration - expires all containers of specified type
---@param entityType string Entity type (vehicle, bale, etc.)
---@return string Result message
function RmFreshConsole:executeExpireAll(entityType)
    -- Validate entity type
    local resolvedType = self:resolveType(entityType)
    if not resolvedType then
        return string.format("Error: Unknown type '%s'. Valid: %s", tostring(entityType), self:getValidTypeNames())
    end

    local stats = RmFreshManager:forceExpireAll(resolvedType)

    if stats == nil then
        return "Error: Failed to expire containers"
    end

    return string.format("Expired all %s containers: %d containers, %.0f units",
        resolvedType, stats.containersAffected, stats.totalExpired)
end

--- Execute all-types expiration - expires ALL containers
---@return string Result message
function RmFreshConsole:executeExpireAllTypes()
    local entityTypes = { "vehicle", "bale", "placeable", "husbandryfood", "stored" }
    local totalContainers = 0
    local totalExpired = 0

    for _, entityType in ipairs(entityTypes) do
        local stats = RmFreshManager:forceExpireAll(entityType)
        if stats then
            totalContainers = totalContainers + stats.containersAffected
            totalExpired = totalExpired + stats.totalExpired
        end
    end

    return string.format("Expired ALL containers: %d containers, %.0f units", totalContainers, totalExpired)
end

-- ============================================================================
-- Batch Manipulation Console Commands (AC: 13, 14, 15, 16)
-- ============================================================================

--- Console command: Add batch to container --- Usage: fAddBatch <#> <amount> [age]
---@param indexStr string Container index from fList
---@param amountStr string Amount to add
---@param ageStr string|nil Age (default 0)
---@return string Console output message
function RmFreshConsole:consoleCommandAddBatch(indexStr, amountStr, ageStr)
    -- Parse arguments
    local index = tonumber(indexStr)
    local amount = tonumber(amountStr)
    local age = tonumber(ageStr) or 0

    if not index or not amount then
        return "Usage: fAddBatch <#> <amount> [age]"
    end

    -- Validate index
    if next(self.targets) == nil then
        return "No containers indexed. Run fList first."
    end

    if index < 1 or index > #self.targets then
        return string.format("Invalid index. Valid range: 1-%d", #self.targets)
    end

    local containerId = self.targets[index]
    if not containerId then
        return "Invalid index. Run fList first."
    end

    -- Check admin (early feedback)
    local ok, err = self:requireAdmin("fAddBatch")
    if not ok then return err end

    -- Determine execution context
    local isServer = g_currentMission:getIsServer()
    local isMultiplayer = g_currentMission.missionDynamicInfo.isMultiplayer

    if not isMultiplayer or isServer then
        -- Singleplayer OR Host: execute directly (no fillUnit param)
        return self:executeAddBatch(containerId, amount, age)
    else
        -- MP Client: send request to server (no fillUnit param)
        g_client:getServerConnection():sendEvent(
            RmFreshConsoleRequestEvent.new("ADD_BATCH", containerId, nil, { amount = amount, age = age })
        )
        return "Request sent to server..."
    end
end

--- Console command: Remove batch from container --- Usage: fRemBatch <#> <batchIdx>
---@param indexStr string Container index from fList
---@param batchIdxStr string Batch index (1-based)
---@return string Console output message
function RmFreshConsole:consoleCommandRemBatch(indexStr, batchIdxStr)
    -- Parse arguments
    local index = tonumber(indexStr)
    local batchIdx = tonumber(batchIdxStr)

    if not index or not batchIdx then
        return "Usage: fRemBatch <#> <batchIdx>"
    end

    -- Validate index
    if next(self.targets) == nil then
        return "No containers indexed. Run fList first."
    end

    if index < 1 or index > #self.targets then
        return string.format("Invalid index. Valid range: 1-%d", #self.targets)
    end

    local containerId = self.targets[index]
    if not containerId then
        return "Invalid index. Run fList first."
    end

    -- Check admin (early feedback)
    local ok, err = self:requireAdmin("fRemBatch")
    if not ok then return err end

    -- Determine execution context
    local isServer = g_currentMission:getIsServer()
    local isMultiplayer = g_currentMission.missionDynamicInfo.isMultiplayer

    if not isMultiplayer or isServer then
        -- Singleplayer OR Host: execute directly (no fillUnit param)
        return self:executeRemBatch(containerId, batchIdx)
    else
        -- MP Client: send request to server (no fillUnit param)
        g_client:getServerConnection():sendEvent(
            RmFreshConsoleRequestEvent.new("REMOVE_BATCH", containerId, nil, { batchIndex = batchIdx })
        )
        return "Request sent to server..."
    end
end

--- Console command: Set batch age --- Usage: fSetAge <#> <batchIdx> <age>
---@param indexStr string Container index from fList
---@param batchIdxStr string Batch index (1-based)
---@param ageStr string New age
---@return string Console output message
function RmFreshConsole:consoleCommandSetAge(indexStr, batchIdxStr, ageStr)
    -- Parse arguments
    local index = tonumber(indexStr)
    local batchIdx = tonumber(batchIdxStr)
    local age = tonumber(ageStr)

    if not index or not batchIdx or not age then
        return "Usage: fSetAge <#> <batchIdx> <age>"
    end

    -- Validate index
    if next(self.targets) == nil then
        return "No containers indexed. Run fList first."
    end

    if index < 1 or index > #self.targets then
        return string.format("Invalid index. Valid range: 1-%d", #self.targets)
    end

    local containerId = self.targets[index]
    if not containerId then
        return "Invalid index. Run fList first."
    end

    -- Check admin (early feedback)
    local ok, err = self:requireAdmin("fSetAge")
    if not ok then return err end

    -- Determine execution context
    local isServer = g_currentMission:getIsServer()
    local isMultiplayer = g_currentMission.missionDynamicInfo.isMultiplayer

    if not isMultiplayer or isServer then
        -- Singleplayer OR Host: execute directly (no fillUnit param)
        return self:executeSetAge(containerId, batchIdx, age)
    else
        -- MP Client: send request to server (no fillUnit param)
        g_client:getServerConnection():sendEvent(
            RmFreshConsoleRequestEvent.new("SET_AGE", containerId, nil, { batchIndex = batchIdx, age = age })
        )
        return "Request sent to server..."
    end
end

--- Console command: Set all batch ages in a container
--- Usage: fSetAllAge <#> [age]
---@param indexStr string Container index from fList
---@param ageStr string|nil New age (default 0 for fresh)
---@return string Console output message
function RmFreshConsole:consoleCommandSetAllAge(indexStr, ageStr)
    -- Parse arguments
    local index = tonumber(indexStr)
    local age = tonumber(ageStr) or 0 -- Default to fresh

    if not index then
        return "Usage: fSetAllAge <#> [age]"
    end

    -- Validate index
    if next(self.targets) == nil then
        return "No containers indexed. Run fList first."
    end

    if index < 1 or index > #self.targets then
        return string.format("Invalid index. Valid range: 1-%d", #self.targets)
    end

    local containerId = self.targets[index]
    if not containerId then
        return "Invalid index. Run fList first."
    end

    -- Check admin (early feedback)
    local ok, err = self:requireAdmin("fSetAllAge")
    if not ok then return err end

    -- Determine execution context
    local isServer = g_currentMission:getIsServer()
    local isMultiplayer = g_currentMission.missionDynamicInfo.isMultiplayer

    if not isMultiplayer or isServer then
        -- Singleplayer OR Host: execute directly
        return self:executeSetAllAge(containerId, age)
    else
        -- MP Client: send request to server
        g_client:getServerConnection():sendEvent(
            RmFreshConsoleRequestEvent.new("SET_ALL_AGES", containerId, nil, { age = age })
        )
        return "Request sent to server..."
    end
end

-- ============================================================================
-- Time/Expiration Console Commands (AC: 1, 5, 7, 11, 15, 16)
-- ============================================================================

--- Console command: Simulate time passing globally
--- Usage: fAge <hours>
---@param hoursStr string Hours to simulate
---@return string Console output message
function RmFreshConsole:consoleCommandAge(hoursStr)
    -- Parse arguments
    local hours = tonumber(hoursStr)

    if not hours then
        return "Usage: fAge <hours>"
    end

    -- Validate hours bounds (prevent floating-point edge cases)
    if hours < 0 then
        return "Error: hours must be non-negative"
    end
    if hours > 100000 then
        return "Error: hours too large (max 100000)"
    end

    -- Check admin (early feedback)
    local ok, err = self:requireAdmin("fAge")
    if not ok then return err end

    -- Determine execution context
    local isServer = g_currentMission:getIsServer()
    local isMultiplayer = g_currentMission.missionDynamicInfo.isMultiplayer

    if not isMultiplayer or isServer then
        -- Singleplayer OR Host: execute directly
        return self:executeAge(hours)
    else
        -- MP Client: send request to server
        g_client:getServerConnection():sendEvent(
            RmFreshConsoleRequestEvent.new("AGE", "", 0, { hours = hours })
        )
        return "Request sent to server..."
    end
end

--- Console command: Simulate time passing for a specific container
--- Usage: fAgeContainer <#> <hours>
---@param indexStr string Container index from fList
---@param hoursStr string Hours to simulate
---@return string Console output message
function RmFreshConsole:consoleCommandAgeContainer(indexStr, hoursStr)
    -- Parse arguments
    local index = tonumber(indexStr)
    local hours = tonumber(hoursStr)

    if not index or not hours then
        return "Usage: fAgeContainer <#> <hours>"
    end

    -- Validate hours bounds (prevent floating-point edge cases)
    if hours < 0 then
        return "Error: hours must be non-negative"
    end
    if hours > 100000 then
        return "Error: hours too large (max 100000)"
    end

    -- Validate index
    if next(self.targets) == nil then
        return "No containers indexed. Run fList first."
    end

    if index < 1 or index > #self.targets then
        return string.format("Invalid index. Valid range: 1-%d", #self.targets)
    end

    local containerId = self.targets[index]
    if not containerId then
        return "Invalid index. Run fList first."
    end

    -- Check admin (early feedback)
    local ok, err = self:requireAdmin("fAgeContainer")
    if not ok then return err end

    -- Determine execution context
    local isServer = g_currentMission:getIsServer()
    local isMultiplayer = g_currentMission.missionDynamicInfo.isMultiplayer

    if not isMultiplayer or isServer then
        -- Singleplayer OR Host: execute directly
        return self:executeAgeContainer(containerId, hours)
    else
        -- MP Client: send request to server
        g_client:getServerConnection():sendEvent(
            RmFreshConsoleRequestEvent.new("AGE_CONTAINER", containerId, 0, { hours = hours })
        )
        return "Request sent to server..."
    end
end

--- Console command: Force expire batches --- Usage: fExpire <#> [batchIdx]
--- With batchIdx: expire single batch; without: expire all batches in container
---@param indexStr string Container index from fList
---@param batchIdxStr string|nil Batch index (1-based)
---@return string Console output message
function RmFreshConsole:consoleCommandExpire(indexStr, batchIdxStr)
    -- Parse container index (required)
    local index = tonumber(indexStr)

    if not index then
        return "Usage: fExpire <#> [batchIdx]"
    end

    -- Validate index
    if next(self.targets) == nil then
        return "No containers indexed. Run fList first."
    end

    if index < 1 or index > #self.targets then
        return string.format("Invalid index. Valid range: 1-%d", #self.targets)
    end

    local containerId = self.targets[index]
    if not containerId then
        return "Invalid index. Run fList first."
    end

    -- Check admin (early feedback)
    local ok, err = self:requireAdmin("fExpire")
    if not ok then return err end

    -- Parse optional batchIdx
    local batchIdx = tonumber(batchIdxStr)

    -- Determine execution context
    local isServer = g_currentMission:getIsServer()
    local isMultiplayer = g_currentMission.missionDynamicInfo.isMultiplayer

    if not isMultiplayer or isServer then
        -- Singleplayer OR Host: execute directly (no fillUnit param)
        if batchIdx then
            -- With batchIdx: single batch
            return self:executeExpire(containerId, batchIdx)
        else
            -- Without batchIdx: entire container
            return self:executeExpireContainer(containerId)
        end
    else
        -- MP Client: send request to server (no fillUnit param)
        -- Encode mode: batchIdx > 0 = single batch, batchIdx = -1 = container
        local mode = batchIdx or -1
        g_client:getServerConnection():sendEvent(
            RmFreshConsoleRequestEvent.new("EXPIRE", containerId, nil, { batchIndex = mode })
        )
        return "Request sent to server..."
    end
end

-- ============================================================================
-- Statistics/Debug Console Commands (AC: 1-10)
-- Read-only commands - no admin required
-- ============================================================================

--- Console command: Show statistics summary
--- Usage: fStats
--- Displays container count, total expired, and breakdown by fill type
---@return string Console output message
function RmFreshConsole:consoleCommandStats()
    -- Check if running on server (statistics only exist on server)
    if g_server == nil then
        -- MP client: statistics are server-only
        return "Statistics only available on server"
    end

    local stats = RmFreshManager:getStatistics()
    if not stats then
        return "Error: Statistics not available"
    end

    local containerCount = RmFreshManager:getContainerCount()
    local totalExpired = stats.totalExpired or 0

    print("=== Fresh Statistics ===")
    print(string.format("Containers tracked: %d", containerCount))
    print(string.format("Total expired: %.0f", totalExpired))

    -- Show breakdown by fill type if data exists
    local expiredByType = stats.expiredByFillType or {}
    local hasBreakdown = false
    for fillTypeIndex, amount in pairs(expiredByType) do
        if amount > 0 then
            hasBreakdown = true
            break
        end
    end

    if hasBreakdown then
        print("\nExpired by fill type:")
        for fillTypeIndex, amount in pairs(expiredByType) do
            if amount > 0 then
                local fillTypeName = g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex) or "UNKNOWN"
                print(string.format("  %s: %.0f", fillTypeName, amount))
            end
        end
    else
        print("\nNo expirations recorded yet")
    end

    return ""
end

--- Console command: Show containers with goods expiring within specified hours
--- Usage: fStatus [hours]
--- Shows goods owned by current player that will expire within threshold
--- Uses daysPerPeriod-aware calculation for accurate time display
---@param hoursStr string|nil Hours threshold (default 24)
---@return string Console output message
function RmFreshConsole:consoleCommandStatus(hoursStr)
    -- Parse hours parameter (default 24)
    local hours = tonumber(hoursStr) or 24

    -- Validate hours
    if hours <= 0 then
        return "Error: hours must be positive"
    end
    if hours > 100000 then
        return "Error: hours too large (max 100000)"
    end

    -- Get current player's farmId for filtering
    local farmId = nil
    if g_currentMission and g_currentMission.player and g_currentMission.player.farmId then
        farmId = g_currentMission.player.farmId
    elseif g_currentMission then
        farmId = g_currentMission:getFarmId()
    end

    -- Query expiring containers from Manager
    local result = RmFreshManager:getExpiringWithin(hours, farmId)

    -- Handle empty result
    if #result.containers == 0 then
        return string.format("Nothing expiring within %d hours", hours)
    end

    -- Display header
    print(string.format("=== Expiring within %d hours ===", hours))
    print(string.format("Total: %.0f L", result.totalAmount))
    print("")

    -- Display containers (sorted by soonest expiry)
    for i, info in ipairs(result.containers) do
        -- Format hours display: show decimal for < 10 hours, integer otherwise
        local hoursDisplay
        if info.expiresInHours < 1 then
            hoursDisplay = string.format("%.0fm", info.expiresInHours * 60) -- Show minutes
        elseif info.expiresInHours < 10 then
            hoursDisplay = string.format("%.1fh", info.expiresInHours)
        else
            hoursDisplay = string.format("%.0fh", info.expiresInHours)
        end

        print(string.format("#%d: %s \"%s\" [%s] %s %.0f L (%s)",
            i,
            info.entityType,
            info.name,
            info.containerId,
            info.fillTypeName,
            info.expiringAmount,
            hoursDisplay))
    end

    return string.format("\n%d containers with expiring goods", #result.containers)
end

--- Console command: Show loss log entries
--- Usage: fLog [count]
--- Displays recent expiration events from RmLossTracker.lossLog
---@param countStr string|nil Number of entries (default 10)
---@return string Console output message
function RmFreshConsole:consoleCommandLog(countStr)
    -- Check if running on server (lossLog only exists on server)
    if g_server == nil then
        return "Loss log only available on server"
    end

    local count = tonumber(countStr) or 10

    local entries = RmFreshManager:getLossLog(count)

    if #entries == 0 then
        return "No losses recorded"
    end

    print(string.format("=== Recent Losses (%d entries) ===", #entries))

    for i, entry in ipairs(entries) do
        -- Loss log entry format: fillTypeName (string), year/period/dayInPeriod/hour, amount, location, farmId
        local fillTypeName = entry.fillTypeName or "UNKNOWN"
        local amount = entry.amount or 0
        local location = entry.location or "unknown"
        local farmId = entry.farmId or 0

        -- Format time as "Y1 P3 D2 H14" (Year Period Day Hour)
        local timeStr = string.format("Y%d P%d D%d H%d",
            entry.year or 1, entry.period or 1, entry.dayInPeriod or 1, entry.hour or 0)

        print(string.format("[%d] %s: %.0f at %s (farm %d, %s)",
            i, fillTypeName, amount, location, farmId, timeStr))
    end

    return ""
end

--- Console command: Dump full state to log file
--- Usage: fDump
--- Writes complete container and batch data to game log
---@return string Console output message
function RmFreshConsole:consoleCommandDump()
    -- Check if running on server (container data only exists on server)
    if g_server == nil then
        return "Dump only available on server"
    end

    local containers = RmFreshManager:getAllContainers()
    local containerCount = 0

    -- Write to log file (using print goes to console, Log goes to log file)
    Log:info("=== FRESH DUMP START ===")

    for containerId, container in pairs(containers) do
        containerCount = containerCount + 1
        local name = self:getEntityName(container)

        -- Show identityMatch info
        local fillTypeName = container.identityMatch and container.identityMatch.storage
            and container.identityMatch.storage.fillTypeName or "?"
        local uniqueId = container.identityMatch and container.identityMatch.worldObject
            and container.identityMatch.worldObject.uniqueId or "nil"

        Log:info("Container: %s (%s) type=%s uniqueId=%s fillType=%s",
            containerId, name, container.entityType, uniqueId, fillTypeName)

        -- Flat batches at container root
        local batches = container.batches or {}
        local total = RmBatch.getTotalAmount(batches)

        Log:info("  Batches: %d, total=%.0f", #batches, total)

        for bIdx, batch in ipairs(batches) do
            Log:info("    [%d] amount=%.1f age=%.4f", bIdx, batch.amount, batch.ageInPeriods)
        end
    end

    -- Also dump statistics
    local stats = RmFreshManager:getStatistics()
    Log:info("Statistics: totalExpired=%.0f lossLogSize=%d",
        stats.totalExpired or 0, #(stats.lossLog or {}))

    Log:info("=== FRESH DUMP END ===")

    return string.format("Dumped %d containers to log file. Check game log for details.", containerCount)
end

-- ============================================================================
-- Admin Statistics/Debug Console Commands (AC: 11-15)
-- Admin-only commands - require admin access
-- ============================================================================

--- Execute clear log operation
--- Clears the loss log, preserving statistics
---@return string Result message
function RmFreshConsole:executeClearLog()
    RmFreshManager:clearLossLog()
    return "Loss log cleared"
end

--- Execute reconcile operation
--- Reconciles all containers with game state
---@return string Result message
function RmFreshConsole:executeReconcile()
    local stats = RmFreshManager:reconcileAll()

    if stats.containersProcessed == 0 and stats.containersSkipped == 0 then
        return "No containers to reconcile"
    end

    return string.format("Reconciled %d containers (skipped %d). Added: %.0f, Removed: %.0f",
        stats.containersProcessed, stats.containersSkipped, stats.totalAdded, stats.totalRemoved)
end

--- Console command: Clear loss log (admin only)
--- Usage: fClearLog
---@return string Console output message
function RmFreshConsole:consoleCommandClearLog()
    -- Check admin (early feedback)
    local ok, err = self:requireAdmin("fClearLog")
    if not ok then return err end

    -- Determine execution context
    local isServer = g_currentMission:getIsServer()
    local isMultiplayer = g_currentMission.missionDynamicInfo.isMultiplayer

    if not isMultiplayer or isServer then
        -- Singleplayer OR Host: execute directly
        return self:executeClearLog()
    else
        -- MP Client: send request to server
        g_client:getServerConnection():sendEvent(
            RmFreshConsoleRequestEvent.new("CLEAR_LOG", "", 0, {})
        )
        return "Request sent to server..."
    end
end

--- Console command: Reconcile containers (admin only)
--- Usage: fReconcile
--- Fixes drift between tracked batches and actual game fill levels
---@return string Console output message
function RmFreshConsole:consoleCommandReconcile()
    -- Check admin (early feedback)
    local ok, err = self:requireAdmin("fReconcile")
    if not ok then return err end

    -- Determine execution context
    local isServer = g_currentMission:getIsServer()
    local isMultiplayer = g_currentMission.missionDynamicInfo.isMultiplayer

    if not isMultiplayer or isServer then
        -- Singleplayer OR Host: execute directly
        return self:executeReconcile()
    else
        -- MP Client: send request to server
        g_client:getServerConnection():sendEvent(
            RmFreshConsoleRequestEvent.new("RECONCILE", "", 0, {})
        )
        return "Request sent to server..."
    end
end

--- Console command: Force expire all containers of a type or all
--- Usage: fExpireAll <type|all>
---@param typeStr string|nil Type filter or "all"
---@return string Console output message
function RmFreshConsole:consoleCommandExpireAll(typeStr)
    -- Require type parameter to prevent accidental mass expiration
    if not typeStr then
        return string.format("Usage: fExpireAll <type|all>\nTypes: %s", self:getValidTypeNames())
    end

    -- Check admin (early feedback)
    local ok, err = self:requireAdmin("fExpireAll")
    if not ok then return err end

    -- Determine execution context
    local isServer = g_currentMission:getIsServer()
    local isMultiplayer = g_currentMission.missionDynamicInfo.isMultiplayer

    if not isMultiplayer or isServer then
        -- Singleplayer OR Host: execute directly
        if string.lower(typeStr) == "all" then
            return self:executeExpireAllTypes()
        else
            return self:executeExpireAll(typeStr)
        end
    else
        -- MP Client: send request to server
        -- Use containerId field to pass entityType (or "all")
        g_client:getServerConnection():sendEvent(
            RmFreshConsoleRequestEvent.new("EXPIRE_ALL", typeStr, 0, {})
        )
        return "Request sent to server..."
    end
end
