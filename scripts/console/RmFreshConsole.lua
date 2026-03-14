-- RmFreshConsole.lua
-- Purpose: Console commands using RmFreshManager APIs
-- Author: Ritter
-- Architecture: Read-only commands using centralized FreshManager

RmFreshConsole = {}
RmFreshConsole.targets = {} -- index -> containerId for command targeting
RmFreshConsole.storageTargets = {} -- index -> uniqueId for storage command targeting

-- Get logger
local Log = RmLogging.getLogger("Fresh")

-- ============================================================================
-- Type Resolution
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
-- Admin Access Control
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
-- Console Command Registration
-- ============================================================================

--- Register console commands
function RmFreshConsole:registerCommands()
    -- Read-only commands (all users)
    addConsoleCommand("fList", "List containers (fList [type])", "consoleCommandList", self)
    addConsoleCommand("fInspect", "Inspect container (fInspect <#>)", "consoleCommandInspect", self)
    addConsoleCommand("fBatches", "Show batches (fBatches <#>)", "consoleCommandBatches", self)
    addConsoleCommand("fStorages", "Storage classes (fStorages [class|config])", "consoleCommandStorages", self)
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

    -- Inventory detail commands (read-only, all users)
    addConsoleCommand("fFillDetail", "FillType detail (fFillDetail <fillType>)", "consoleCommandFillDetail", self)
    addConsoleCommand("fStorageList", "Storage list (fStorageList)", "consoleCommandStorageList", self)
    addConsoleCommand("fStorageDetail", "Storage detail (fStorageDetail <#>)", "consoleCommandStorageDetail", self)

    -- Statistics/debug commands (read-only, all users)
    addConsoleCommand("fStats", "Show statistics", "consoleCommandStats", self)
    addConsoleCommand("fStatus", "Expiring soon (fStatus [hours])", "consoleCommandStatus", self)
    addConsoleCommand("fLog", "Show loss log (fLog [count])", "consoleCommandLog", self)
    addConsoleCommand("fDump", "Dump state to log", "consoleCommandDump", self)

    -- Statistics/debug admin commands (admin only)
    addConsoleCommand("fClearLog", "Clear loss log (admin)", "consoleCommandClearLog", self)
    addConsoleCommand("fReconcile", "Reconcile with game state (admin)", "consoleCommandReconcile", self)

    -- Storage class override commands (admin only)
    addConsoleCommand("fSetStorage", "Set storage class override (fSetStorage <#|items> <class>)", "consoleCommandSetStorage", self)
    addConsoleCommand("fClearStorage", "Clear storage class override (fClearStorage <#|items>)", "consoleCommandClearStorage", self)

    Log:info(
    "CONSOLE: fList, fInspect, fBatches, fStorages, fFillDetail, fStorageList, fStorageDetail, fAddBatch, fRemBatch, fSetAge, fSetAllAge, fAge, fAgeContainer, fExpire, fExpireAll, fStats, fStatus, fLog, fDump, fClearLog, fReconcile, fSetStorage, fClearStorage commands registered")
end

--- Unregister console commands
function RmFreshConsole:unregisterCommands()
    -- Read-only commands
    removeConsoleCommand("fList")
    removeConsoleCommand("fInspect")
    removeConsoleCommand("fBatches")
    removeConsoleCommand("fStorages")
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

    -- Inventory detail commands
    removeConsoleCommand("fFillDetail")
    removeConsoleCommand("fStorageList")
    removeConsoleCommand("fStorageDetail")

    -- Statistics/debug commands
    removeConsoleCommand("fStats")
    removeConsoleCommand("fStatus")
    removeConsoleCommand("fLog")
    removeConsoleCommand("fDump")
    removeConsoleCommand("fClearLog")
    removeConsoleCommand("fReconcile")
    removeConsoleCommand("fSetStorage")
    removeConsoleCommand("fClearStorage")

    self.targets = {}
    self.storageTargets = {}
    Log:debug("CONSOLE: commands unregistered")
end

-- ============================================================================
-- fList Command
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

        -- Human-readable expiry time (adjusted for storage class multiplier)
        local expiresText = ""
        if oldest then
            local threshold = RmFreshSettings:getExpiration(fillTypeName)
            if threshold then
                local classInfo = RmFreshManager:resolveStorageClassInfo(container)
                local multiplier = classInfo and classInfo.multiplier or 1.0
                expiresText = " (" .. RmBatch.formatExpiresIn(oldest, threshold, daysPerPeriod, multiplier) .. ")"
            end
        end

        print(string.format("#%d: %s \"%s\" [%s] %s amount=%.0f batches=%d oldest=%sp%s",
            i, container.entityType, name, container.id, fillTypeName, totalAmount, batchCount, ageRaw, expiresText))
    end

    return string.format("Listed %d containers", #containers)
end

-- ============================================================================
-- fStorages Command
-- ============================================================================

--- Capitalize first letter of a string
---@param name string|nil
---@return string
local function capitalize(name)
    if name == nil or name == "" then return "?" end
    return name:sub(1, 1):upper() .. name:sub(2)
end

--- Console command: Show storage class info for all containers
---@param filterStr string|nil Optional class filter or "config"
---@return string Console output message
function RmFreshConsole:consoleCommandStorages(filterStr)
    self.targets = {}
    Log:trace(">>> consoleCommandStorages(filter=%s)", tostring(filterStr))

    -- Header: global toggle status
    local toggleStr = RmFreshSettings.storageAgingEnabled and "ENABLED" or "DISABLED"

    -- Header: class multiplier values (Exposed through Frozen)
    local SC = RmFreshManager.STORAGE_CLASS
    local multParts = {}
    for classValue = SC.EXPOSED, SC.FROZEN do
        local className = capitalize(RmFreshManager.STORAGE_CLASS_NAMES[classValue])
        local mult = RmFreshSettings:getClassMultiplier(classValue)
        table.insert(multParts, string.format("%s=%.2fx", className, mult))
    end
    local multLine = table.concat(multParts, " ")

    -- Handle "config" subcommand
    if filterStr and string.lower(filterStr) == "config" then
        return self:formatStorageConfig()
    end

    -- Parse optional class filter
    local classFilter = nil
    if filterStr ~= nil then
        classFilter = RmFreshManager:getStorageClassByName(filterStr)
        if classFilter == nil then
            -- Build valid class names list
            local validNames = {}
            for classValue = SC.EXPOSED, SC.DISABLED do
                table.insert(validNames, capitalize(RmFreshManager.STORAGE_CLASS_NAMES[classValue]))
            end
            return string.format("Unknown storage class '%s'. Valid: %s, config",
                filterStr, table.concat(validNames, ", "))
        end
    end

    -- Print header
    local filterLabel = classFilter and string.format(" (filter: %s)",
        capitalize(RmFreshManager.STORAGE_CLASS_NAMES[classFilter])) or ""
    print(string.format("=== Storage Classes%s ===", filterLabel))
    print(string.format("Storage Aging Effects: %s", toggleStr))
    print(string.format("Multipliers: %s", multLine))

    -- Get all containers
    local containers = {}
    for _, container in pairs(RmFreshManager:getAllContainers()) do
        table.insert(containers, container)
    end

    -- Sort by containerId for stable output
    table.sort(containers, function(a, b)
        return a.id < b.id
    end)

    -- Iterate and format
    local count = 0
    for _, container in ipairs(containers) do
        local fillTypeName = container.identityMatch and container.identityMatch.storage
            and container.identityMatch.storage.fillTypeName or "?"
        local info = RmFreshManager:resolveStorageClassInfo(container)

        -- Apply class filter
        if classFilter ~= nil and info.effective ~= classFilter then
            -- skip
        else
            count = count + 1
            self.targets[count] = container.id

            local overrideStr = info.override
                and capitalize(RmFreshManager.STORAGE_CLASS_NAMES[info.override])
                or "\xE2\x80\x94"
            local name = self:getEntityName(container)
            print(string.format("#%d: %s \"%s\" [%s] %s detected=%s override=%s maxBenefit=%s effective=%s mult=%.2fx",
                count, container.entityType, name, container.id, fillTypeName,
                capitalize(RmFreshManager.STORAGE_CLASS_NAMES[info.detected]),
                overrideStr,
                capitalize(RmFreshManager.STORAGE_CLASS_NAMES[info.maxBenefitClass]),
                capitalize(RmFreshManager.STORAGE_CLASS_NAMES[info.effective]),
                info.multiplier))
        end
    end

    if count == 0 and classFilter ~= nil then
        print(string.format("No containers with effective class: %s",
            capitalize(RmFreshManager.STORAGE_CLASS_NAMES[classFilter])))
    end

    return string.format("Listed %d containers", count)
end

--- Format storage class configuration for all perishable fillTypes
---@return string Console output summary
function RmFreshConsole:formatStorageConfig()
    print("=== Storage Class Config ===")

    local entries = {}
    for fillTypeIndex, _ in pairs(RmFreshSettings.perishableByIndex) do
        local fillTypeName = g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex)
        local maxClass = RmFreshSettings:getMaxBenefitClass(fillTypeIndex)
        local className = capitalize(RmFreshManager.STORAGE_CLASS_NAMES[maxClass])
        table.insert(entries, { name = fillTypeName or "?", className = className })
    end

    table.sort(entries, function(a, b) return a.name < b.name end)

    for _, entry in ipairs(entries) do
        print(string.format("%s: maxBenefitClass=%s", entry.name, entry.className))
    end

    print("(fillTypes without config default to Sheltered)")
    return string.format("Listed %d configured fillTypes", #entries)
end

-- ============================================================================
-- fInspect Command
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

    -- Storage class info
    local classInfo = RmFreshManager:resolveStorageClassInfo(container)
    local classNames = RmFreshManager.STORAGE_CLASS_NAMES
    local detectedName = classNames[classInfo.detected] or "?"
    local effectiveName = classNames[classInfo.effective] or "?"
    local maxBenefitName = classNames[classInfo.maxBenefitClass] or "?"
    if classInfo.override then
        local overrideName = classNames[classInfo.override] or "?"
        print(string.format("  storageClass: %s (detected: %s, override: %s) x%.2f", effectiveName, detectedName, overrideName, classInfo.multiplier))
    else
        print(string.format("  storageClass: %s (detected: %s) x%.2f", effectiveName, detectedName, classInfo.multiplier))
    end
    print(string.format("  maxBenefitClass: %s", maxBenefitName))

    -- Flat batches at container root
    local batches = container.batches or {}
    local total = RmBatch.getTotalAmount(batches)
    local oldest = RmBatch.getOldest(batches)
    local ageRaw = oldest and string.format("%.2f", oldest.ageInPeriods) or "0.00"
    local daysPerPeriod = (g_currentMission and g_currentMission.environment and g_currentMission.environment.daysPerPeriod) or 1
    local ageStr = oldest and RmBatch.formatAge(oldest, daysPerPeriod) or "0h"

    -- Human-readable expires-in (adjusted for storage class multiplier)
    local expiresStr = ""
    if oldest then
        local fillTypeName = container.identityMatch and container.identityMatch.storage
            and container.identityMatch.storage.fillTypeName
        local threshold = fillTypeName and RmFreshSettings:getExpiration(fillTypeName)
        if threshold then
            local multiplier = classInfo.multiplier
            expiresStr = string.format(", expires in %s", RmBatch.formatExpiresIn(oldest, threshold, daysPerPeriod, multiplier))
        end
    end

    print(string.format("\n  Batches: %d", #batches))
    print(string.format("  Total amount: %.0f", total))
    print(string.format("  Oldest: %sp, aged %s%s", ageRaw, ageStr, expiresStr))

    return ""
end

-- ============================================================================
-- fBatches Command
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
    local classInfo = RmFreshManager:resolveStorageClassInfo(container)
    local multiplier = classInfo and classInfo.multiplier or 1.0

    print(string.format("Container #%d \"%s\" (%s):", index, name, fillTypeName))

    for i, batch in ipairs(batches) do
        local ageRaw = string.format("%.2f", batch.ageInPeriods)
        local ageStr = RmBatch.formatAge(batch, daysPerPeriod)
        local expiresStr = threshold and RmBatch.formatExpiresIn(batch, threshold, daysPerPeriod, multiplier) or "?"
        print(string.format("  [%d] amount=%.0f, age=%sp (%s, expires %s)", i, batch.amount, ageRaw, ageStr, expiresStr))
    end

    return ""
end

-- ============================================================================
-- Execute Methods
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
-- Time Simulation Execute Methods
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
-- Force Expiration Execute Methods
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
-- Batch Manipulation Console Commands
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
-- Time/Expiration Console Commands
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
-- Statistics/Debug Console Commands
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

        -- Storage class label (omit for legacy entries without storageClass)
        local classStr = ""
        if entry.storageClass ~= nil then
            local className = RmFreshManager.STORAGE_CLASS_NAMES[entry.storageClass]
            if className then
                classStr = string.format(" [%s]", className:sub(1, 1):upper() .. className:sub(2))
            end
        end

        print(string.format("[%d] %s: %.0f at %s%s (farm %d, %s)",
            i, fillTypeName, amount, location, classStr, farmId, timeStr))
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
-- Admin Statistics/Debug Console Commands
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

-- ============================================================================
-- fSetStorage / fClearStorage Commands
-- ============================================================================

--- Resolve override key from index or "items" keyword
--- Returns overrideKey string, display label, or nil + error message
---@param indexOrKey string Index number or "items"
---@return string|nil overrideKey
---@return string labelOrError Display label (success) or error message (failure)
function RmFreshConsole:resolveOverrideKey(indexOrKey)
    if string.lower(indexOrKey) == "items" then
        return "itemsInWorld", "Items in World"
    end

    local index = tonumber(indexOrKey)
    if not index then
        return nil, "Usage: fSetStorage <#|items> <class>"
    end

    if next(self.targets) == nil then
        return nil, "No containers indexed. Run fList first."
    end
    if index < 1 or index > #self.targets then
        return nil, string.format("Invalid index. Valid range: 1-%d", #self.targets)
    end

    local containerId = self.targets[index]
    if not containerId then
        return nil, "Invalid index. Run fList first."
    end

    local container = RmFreshManager.containers[containerId]
    if not container then
        return nil, "Container not found"
    end

    -- Bales and pallets use combined "itemsInWorld" override (not per-item uniqueId)
    if container.entityType == "bale" or (container.metadata and container.metadata.isPallet) then
        return "itemsInWorld", "Items in World"
    end

    -- All other entity types use worldObject.uniqueId (for stored objects, this IS the parent placeable's uniqueId)
    local wo = container.identityMatch and container.identityMatch.worldObject
    local uniqueId = wo and wo.uniqueId
    if not uniqueId then
        return nil, "Container has no uniqueId (cannot override)"
    end

    local label = container.metadata and container.metadata.location or uniqueId
    return uniqueId, label
end

--- Console command: Set storage class override
--- Usage: fSetStorage <#|items> <class>
---@param indexOrKey string Container index from fList or "items"
---@param classStr string Storage class name (exposed, sheltered, indoor, cooled, frozen, disabled)
---@return string Console output message
function RmFreshConsole:consoleCommandSetStorage(indexOrKey, classStr)
    if not indexOrKey or not classStr then
        return "Usage: fSetStorage <#|items> <class>  (valid classes: exposed, sheltered, indoor, cooled, frozen, disabled)"
    end

    -- Parse class name
    local classValue = RmFreshManager:getStorageClassByName(classStr)
    if not classValue then
        return "Invalid class '" .. classStr .. "'. Valid: exposed, sheltered, indoor, cooled, frozen, disabled"
    end

    -- Resolve override key
    local overrideKey, label = self:resolveOverrideKey(indexOrKey)
    if not overrideKey then
        return label -- label contains the error message
    end

    -- Check admin (early feedback)
    local ok, err = self:requireAdmin("fSetStorage")
    if not ok then return err end

    -- Determine execution context
    local isServer = g_currentMission:getIsServer()
    local isMultiplayer = g_currentMission.missionDynamicInfo.isMultiplayer

    if not isMultiplayer or isServer then
        return self:executeSetStorage(overrideKey, classValue)
    else
        -- MP Client: send request to server
        g_client:getServerConnection():sendEvent(
            RmFreshConsoleRequestEvent.new("SET_STORAGE", "", 0, { key = overrideKey, classValue = classValue })
        )
        return "Request sent to server..."
    end
end

--- Console command: Clear storage class override
--- Usage: fClearStorage <#|items>
---@param indexOrKey string Container index from fList or "items"
---@return string Console output message
function RmFreshConsole:consoleCommandClearStorage(indexOrKey)
    if not indexOrKey then
        return "Usage: fClearStorage <#|items>"
    end

    -- Resolve override key
    local overrideKey, label = self:resolveOverrideKey(indexOrKey)
    if not overrideKey then
        return label -- label contains the error message
    end

    -- Check admin (early feedback)
    local ok, err = self:requireAdmin("fClearStorage")
    if not ok then return err end

    -- Determine execution context
    local isServer = g_currentMission:getIsServer()
    local isMultiplayer = g_currentMission.missionDynamicInfo.isMultiplayer

    if not isMultiplayer or isServer then
        return self:executeClearStorage(overrideKey)
    else
        -- MP Client: send request to server
        g_client:getServerConnection():sendEvent(
            RmFreshConsoleRequestEvent.new("CLEAR_STORAGE", "", 0, { key = overrideKey })
        )
        return "Request sent to server..."
    end
end

--- Execute set storage class override (runs on server)
---@param overrideKey string uniqueId or "itemsInWorld"
---@param classValue number Storage class enum value
---@return string Console output message
function RmFreshConsole:executeSetStorage(overrideKey, classValue)
    RmFreshSettings:setStorageClassOverride(overrideKey, classValue)
    local className = RmFreshManager.STORAGE_CLASS_NAMES[classValue] or "?"
    local label = overrideKey == "itemsInWorld" and "Items in World" or overrideKey
    return string.format("Override set: %s -> %s", label, className)
end

--- Execute clear storage class override (runs on server)
---@param overrideKey string uniqueId or "itemsInWorld"
---@return string Console output message
function RmFreshConsole:executeClearStorage(overrideKey)
    local existing = RmFreshSettings:getStorageClassOverride(overrideKey)
    if existing == nil then
        local label = overrideKey == "itemsInWorld" and "Items in World" or overrideKey
        return string.format("No override exists for %s", label)
    end
    RmFreshSettings:clearStorageClassOverride(overrideKey)
    local label = overrideKey == "itemsInWorld" and "Items in World" or overrideKey
    return string.format("Override cleared: %s (reverted to detected class)", label)
end

-- ============================================================================
-- fFillDetail Command
-- ============================================================================

--- Console command: Show per-storage breakdown for a fillType
--- Usage: fFillDetail [fillType]
--- Without args: lists available perishable fillTypes
--- With fillType name: shows per-storage detail with batches, class, expiry
---@param fillTypeStr string|nil FillType name (e.g., "WHEAT")
---@return string Console output message
function RmFreshConsole:consoleCommandFillDetail(fillTypeStr)
    -- Resolve farmId
    local farmId = nil
    if g_currentMission and g_currentMission.player and g_currentMission.player.farmId then
        farmId = g_currentMission.player.farmId
    elseif g_currentMission then
        farmId = g_currentMission:getFarmId()
    end

    -- No argument: list available fillTypes
    if fillTypeStr == nil then
        local list = RmFreshManager:getInventoryList(farmId)
        if #list == 0 then
            return "No perishable inventory found"
        end
        print("=== Available Perishable FillTypes ===")
        for _, entry in ipairs(list) do
            print(string.format("  %s: %.0f L", entry.fillTypeName, entry.totalAmount))
        end
        return "Usage: fFillDetail <fillType>"
    end

    -- Resolve fillType name (case-insensitive)
    local fillTypeName = string.upper(fillTypeStr)
    local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(fillTypeName)
    if fillTypeIndex == nil then
        return string.format("Unknown fillType '%s'", fillTypeStr)
    end

    -- Query detail from Manager
    local detail = RmFreshManager:getFillTypeDetail(fillTypeName, farmId)

    if #detail.containers == 0 then
        return string.format("No containers with %s found", fillTypeName)
    end

    -- Sort by amount descending for stable display order
    table.sort(detail.containers, function(a, b) return a.amount > b.amount end)

    -- Print header
    print(string.format("=== %s Detail ===", detail.fillTypeTitle))
    print(string.format("Total: %.0f L | Threshold: %s | Containers: %d",
        detail.totalAmount,
        detail.threshold and string.format("%.2f periods", detail.threshold) or "N/A",
        #detail.containers))
    print("")

    -- Populate targets and print per-container rows
    self.targets = {}
    for i, entry in ipairs(detail.containers) do
        self.targets[i] = entry.containerId

        local pct = detail.totalAmount > 0
            and string.format("%.0f%%", entry.amount / detail.totalAmount * 100)
            or "0%"

        local classStr = entry.className and string.format(" [%s]", entry.className) or ""

        print(string.format("#%d: %s \"%s\" %.0f L (%s)%s %s",
            i,
            entry.entityType,
            entry.storageName,
            entry.amount,
            pct,
            classStr,
            entry.expiresInDisplay))
    end

    return string.format("\n%d containers with %s", #detail.containers, fillTypeName)
end

-- ============================================================================
-- fStorageList Command
-- ============================================================================

--- Console command: Show all storages with totals and fillType counts
--- Usage: fStorageList
--- Populates self.storageTargets for follow-up fStorageDetail
---@return string Console output message
function RmFreshConsole:consoleCommandStorageList()
    -- Resolve farmId
    local farmId = nil
    if g_currentMission and g_currentMission.player and g_currentMission.player.farmId then
        farmId = g_currentMission.player.farmId
    elseif g_currentMission then
        farmId = g_currentMission:getFarmId()
    end

    local storages = RmFreshManager:getStorageList(farmId)

    if #storages == 0 then
        self.storageTargets = {}
        return "No storages with perishable inventory found"
    end

    -- Sort alphabetically by entityName for stable display
    table.sort(storages, function(a, b) return a.entityName:lower() < b.entityName:lower() end)

    print("=== Storage Inventory ===")

    self.storageTargets = {}
    for i, entry in ipairs(storages) do
        self.storageTargets[i] = entry.uniqueId

        local classStr = entry.className and string.format(" [%s]", entry.className) or ""

        print(string.format("#%d: \"%s\" [%s] %.0f L, %d fillType(s)%s",
            i,
            entry.entityName,
            entry.entityType,
            entry.totalAmount,
            entry.fillTypeCount,
            classStr))
    end

    return string.format("\n%d storages listed. Use fStorageDetail <#> for details.", #storages)
end

-- ============================================================================
-- fStorageDetail Command
-- ============================================================================

--- Console command: Show per-fillType breakdown for a storage
--- Usage: fStorageDetail <#>
--- Requires fStorageList to have been run first (populates storageTargets)
---@param indexStr string Storage index from fStorageList
---@return string Console output message
function RmFreshConsole:consoleCommandStorageDetail(indexStr)
    if next(self.storageTargets) == nil then
        return "No storages indexed. Run fStorageList first."
    end

    local index = tonumber(indexStr)
    if index == nil or index < 1 or index > #self.storageTargets then
        return string.format("Invalid index. Valid range: 1-%d", #self.storageTargets)
    end

    local uniqueId = self.storageTargets[index]

    -- Resolve farmId
    local farmId = nil
    if g_currentMission and g_currentMission.player and g_currentMission.player.farmId then
        farmId = g_currentMission.player.farmId
    elseif g_currentMission then
        farmId = g_currentMission:getFarmId()
    end

    local detail = RmFreshManager:getStorageDetail(uniqueId, farmId)

    if #detail.fillTypes == 0 then
        return string.format("No perishable goods in %s", detail.entityName)
    end

    -- Print header
    print(string.format("=== %s ===", detail.entityName))
    local classStr = detail.className and string.format(" | Class: %s", detail.className) or ""
    print(string.format("Type: %s | Total: %.0f L%s",
        detail.entityType, detail.totalAmount, classStr))
    print("")

    -- Print per-fillType rows
    for _, entry in ipairs(detail.fillTypes) do
        local pct = detail.totalAmount > 0
            and string.format("%.0f%%", entry.amount / detail.totalAmount * 100)
            or "0%"

        local effectiveStr = entry.effectiveClassName
            and string.format(" [%s]", entry.effectiveClassName) or ""

        print(string.format("  %s: %.0f L (%s)%s %s (%d batches)",
            entry.fillTypeTitle,
            entry.amount,
            pct,
            effectiveStr,
            entry.expiresInDisplay,
            entry.batchCount))
    end

    return string.format("\n%d fillType(s) in %s", #detail.fillTypes, detail.entityName)
end
