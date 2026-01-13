-- RmFreshIO.lua
-- Purpose: Save/load Fresh data to savegame XML files
-- Author: Ritter
-- Architecture: Centralized persistence - single save file contains all Fresh data
-- Functions: 5
--   Save: save, saveLog
--   Load: load, loadLog
--   Helper: getFilePath
-- Files: rm_FreshData.xml (essential), rm_FreshLog.xml (optional log)

RmFreshIO = {}

-- Get logger (RmLogging loaded before this module in main.lua)
local Log = RmLogging.getLogger("Fresh")

-- =============================================================================
-- CONSTANTS
-- =============================================================================

--- Data file name for essential Fresh data (containers, settings, statistics)
RmFreshIO.FILE_DATA = "rm_FreshData.xml"

--- Log file name for loss log (optional, can grow large)
RmFreshIO.FILE_LOG = "rm_FreshLog.xml"

--- File format version for compatibility checks
--- v2: Initial container schema (type field)
--- v3: Generated container IDs (entityId, entityType, storageIndex fields)
--- v4: Current identity model (identityMatch, flat batches, fillTypeName as string)
RmFreshIO.VERSION = 4

--- Settings file format version for compatibility checks
RmFreshIO.SETTINGS_VERSION = 1

--- XML Schema for save format validation (registered on first use)
--- Uses FS25 XMLSchema API for path validation and type checking
RmFreshIO.xmlSchema = nil

--- XML Schema for settings format validation (registered on first use)
--- Used for both mod defaults and user override files
RmFreshIO.settingsSchema = nil

--- XML Schema for loss log format validation (registered on first use)
RmFreshIO.logSchema = nil

-- =============================================================================
-- SCHEMA REGISTRATION
-- =============================================================================

--- Register XML schema for save format validation
--- Called once on first save/load operation
--- Uses FS25 XMLSchema API for path registration and type validation
function RmFreshIO.registerSchema()
    if RmFreshIO.xmlSchema ~= nil then
        return  -- Already registered
    end

    local schema = XMLSchema.new("freshData")

    -- Root version attribute
    schema:register(XMLValueType.INT, "freshData#version", "Save format version", 4)

    -- Container paths (using ? for array notation)
    local containerPath = "freshData.containers.container(?)"
    schema:register(XMLValueType.STRING, containerPath .. "#id", "Container ID")
    schema:register(XMLValueType.STRING, containerPath .. "#entityType", "Entity type")

    -- worldObject - entity identity anchor
    schema:register(XMLValueType.STRING, containerPath .. ".worldObject#uniqueId", "Entity uniqueId")
    schema:register(XMLValueType.STRING, containerPath .. ".worldObject#objectType", "Object type hint")

    -- storage - content identity
    schema:register(XMLValueType.STRING, containerPath .. ".storage#fillTypeName", "Fill type name")
    schema:register(XMLValueType.INT, containerPath .. ".storage#fillUnitIndex", "Fill unit index", 1)
    schema:register(XMLValueType.FLOAT, containerPath .. ".storage#amount", "Current amount", 0)

    -- storage - extended identity for stored objects (ObjectStorage)
    schema:register(XMLValueType.STRING, containerPath .. ".storage#className", "Object class (Bale/Vehicle)")
    schema:register(XMLValueType.INT, containerPath .. ".storage#storageFarmId", "Farm ID in storage identity")
    -- Bale-specific identity
    schema:register(XMLValueType.INT, containerPath .. ".storage#variationIndex", "Bale variation index")
    schema:register(XMLValueType.BOOL, containerPath .. ".storage#isMissionBale", "Is mission bale", false)
    schema:register(XMLValueType.FLOAT, containerPath .. ".storage#wrappingState", "Bale wrapping state", 0)
    -- Vehicle-specific identity
    schema:register(XMLValueType.BOOL, containerPath .. ".storage#isBigBag", "Is big bag", false)

    -- batches (flat array at container level)
    schema:register(XMLValueType.FLOAT, containerPath .. ".batches.batch(?)#amount", "Batch amount")
    schema:register(XMLValueType.FLOAT, containerPath .. ".batches.batch(?)#ageInPeriods", "Batch age", 0)

    -- metadata
    schema:register(XMLValueType.INT, containerPath .. ".metadata#farmId", "Owner farm ID", 0)
    schema:register(XMLValueType.BOOL, containerPath .. ".metadata#fermenting", "Is fermenting", false)
    schema:register(XMLValueType.STRING, containerPath .. ".metadata#location", "Location description")

    -- statistics
    schema:register(XMLValueType.INT, "freshData.statistics#totalExpired", "Total expired", 0)
    schema:register(XMLValueType.STRING, "freshData.statistics.expiredByFillType.fillType(?)#name", "Fill type name")
    schema:register(XMLValueType.INT, "freshData.statistics.expiredByFillType.fillType(?)#amount", "Expired amount")

    RmFreshIO.xmlSchema = schema
    Log:debug("SCHEMA_REGISTER: Fresh save format v%d schema registered", RmFreshIO.VERSION)
end

--- Register XML schema for settings format validation
--- Called once on first settings load/save operation
--- Unified format for both mod defaults and user overrides
function RmFreshIO.registerSettingsSchema()
    if RmFreshIO.settingsSchema ~= nil then
        return  -- Already registered
    end

    local schema = XMLSchema.new("freshSettings")

    -- Root version attribute
    schema:register(XMLValueType.INT, "freshSettings#version", "Format version", 1)

    -- Global settings (optional section)
    schema:register(XMLValueType.STRING, "freshSettings.global.setting(?)#name", "Setting name")
    schema:register(XMLValueType.STRING, "freshSettings.global.setting(?)#value", "Setting value")

    -- FillType settings
    schema:register(XMLValueType.STRING, "freshSettings.fillTypes.fillType(?)#name", "FillType name")
    schema:register(XMLValueType.FLOAT, "freshSettings.fillTypes.fillType(?)#period", "Expiration period")
    schema:register(XMLValueType.STRING, "freshSettings.fillTypes.fillType(?)#expires", "Expires flag")

    RmFreshIO.settingsSchema = schema
    Log:debug("SCHEMA_REGISTER: Fresh settings format v%d schema registered", RmFreshIO.SETTINGS_VERSION)
end

--- Register XML schema for loss log format validation
--- Called once on first log load/save operation
function RmFreshIO.registerLogSchema()
    if RmFreshIO.logSchema ~= nil then
        return  -- Already registered
    end

    local schema = XMLSchema.new("freshLog")

    -- Root version attribute
    schema:register(XMLValueType.INT, "freshLog#version", "Log format version", 4)

    -- Log entry paths (using ? for array notation)
    local entryPath = "freshLog.entry(?)"

    -- Timing fields
    schema:register(XMLValueType.INT, entryPath .. "#year", "Game year", 1)
    schema:register(XMLValueType.INT, entryPath .. "#period", "Game period/month", 1)
    schema:register(XMLValueType.INT, entryPath .. "#dayInPeriod", "Day in period", 1)
    schema:register(XMLValueType.INT, entryPath .. "#hour", "Game hour", 0)

    -- What expired
    schema:register(XMLValueType.STRING, entryPath .. "#fillTypeName", "Fill type name")
    schema:register(XMLValueType.FLOAT, entryPath .. "#amount", "Amount expired", 0)
    schema:register(XMLValueType.FLOAT, entryPath .. "#value", "Value of lost product", 0)

    -- Where (persistent identity)
    schema:register(XMLValueType.STRING, entryPath .. "#location", "Storage location")
    schema:register(XMLValueType.STRING, entryPath .. "#objectUniqueId", "Object unique ID")
    schema:register(XMLValueType.STRING, entryPath .. "#entityType", "Entity type")

    -- Who
    schema:register(XMLValueType.INT, entryPath .. "#farmId", "Owner farm ID", 0)

    RmFreshIO.logSchema = schema
    Log:debug("SCHEMA_REGISTER: Fresh log format v%d schema registered", RmFreshIO.VERSION)
end

-- =============================================================================
-- HELPER FUNCTIONS
-- =============================================================================

--- Get full file path for a Fresh data file
---@param savegameDir string Path to savegame directory
---@param filename string File name to append (e.g., FILE_DATA or FILE_LOG)
---@return string Full path to file
function RmFreshIO:getFilePath(savegameDir, filename)
    return savegameDir .. "/" .. filename
end

-- =============================================================================
-- SAVE FUNCTIONS
-- =============================================================================

--- Save Fresh data to rm_FreshData.xml --- Writes containers using identity model: identityMatch (worldObject + storage), flat batches
--- CRITICAL: Do NOT save runtimeEntity/fillTypeIndex (runtime-only references)
---@param savegameDir string Path to savegame directory
---@param containers table Container registry from RmFreshManager (id → Container)
---@param statistics table Statistics from RmFreshManager
---@param settings table Settings from RmFreshConfig (currently unused, reserved)
---@return boolean true on success, false on failure
function RmFreshIO:save(savegameDir, containers, statistics, settings)
    local inputContainerCount = 0
    for _ in pairs(containers or {}) do inputContainerCount = inputContainerCount + 1 end
    Log:trace(">>> save(savegameDir=%s, containers=%d)", savegameDir or "nil", inputContainerCount)

    if savegameDir == nil or savegameDir == "" then
        Log:error("SAVE: savegameDir cannot be nil or empty")
        Log:trace("<<< save = false (invalid savegameDir)")
        return false
    end

    -- Validate input types
    if type(containers) ~= "table" then
        Log:error("SAVE: 'containers' must be a table")
        Log:trace("<<< save = false (invalid containers type)")
        return false
    end
    if type(statistics) ~= "table" then
        Log:error("SAVE: 'statistics' must be a table")
        Log:trace("<<< save = false (invalid statistics type)")
        return false
    end

    -- Register schema on first use
    RmFreshIO.registerSchema()

    local filePath = self:getFilePath(savegameDir, self.FILE_DATA)
    local xmlFile = XMLFile.create("freshData", filePath, "freshData", self.xmlSchema)
    if xmlFile == nil then
        Log:error("SAVE: Failed to create save file: %s", filePath)
        Log:trace("<<< save = false (XMLFile.create failed)")
        return false
    end

    -- Write version attribute (v4 = current identity model)
    xmlFile:setInt("freshData#version", self.VERSION)

    -- Write containers section
    local containerIndex = 0
    containers = containers or {}
    for containerId, container in pairs(containers) do
        local containerPath = string.format("freshData.containers.container(%d)", containerIndex)

        -- Container identity attributes
        xmlFile:setString(containerPath .. "#id", containerId)
        xmlFile:setString(containerPath .. "#entityType", container.entityType or "unknown")

        -- Write worldObject element (entity identity anchor)
        local worldObject = container.identityMatch and container.identityMatch.worldObject or {}
        if worldObject.uniqueId ~= nil then
            xmlFile:setString(containerPath .. ".worldObject#uniqueId", worldObject.uniqueId)
        end
        if worldObject.objectType ~= nil then
            xmlFile:setString(containerPath .. ".worldObject#objectType", worldObject.objectType)
        end

        -- Write storage element (content identity)
        local storage = container.identityMatch and container.identityMatch.storage or {}
        if storage.fillTypeName ~= nil then
            xmlFile:setString(containerPath .. ".storage#fillTypeName", storage.fillTypeName)
        end
        if storage.fillUnitIndex ~= nil then
            xmlFile:setInt(containerPath .. ".storage#fillUnitIndex", storage.fillUnitIndex)
        end
        -- Use current batch total for accurate reconciliation matching (not stale registration-time value)
        local currentAmount = RmBatch.getTotalAmount(container.batches or {})
        xmlFile:setFloat(containerPath .. ".storage#amount", currentAmount)

        -- Write extended identity for stored objects (ObjectStorage)
        if storage.className ~= nil then
            xmlFile:setString(containerPath .. ".storage#className", storage.className)
        end
        if storage.farmId ~= nil then
            xmlFile:setInt(containerPath .. ".storage#storageFarmId", storage.farmId)
        end
        -- Bale-specific identity fields
        if storage.variationIndex ~= nil then
            xmlFile:setInt(containerPath .. ".storage#variationIndex", storage.variationIndex)
        end
        if storage.isMissionBale ~= nil then
            xmlFile:setBool(containerPath .. ".storage#isMissionBale", storage.isMissionBale)
        end
        if storage.wrappingState ~= nil then
            xmlFile:setFloat(containerPath .. ".storage#wrappingState", storage.wrappingState)
        end
        -- Vehicle-specific identity fields
        if storage.isBigBag ~= nil then
            xmlFile:setBool(containerPath .. ".storage#isBigBag", storage.isBigBag)
        end

        -- Write flat batches array (batches at container level, not fillUnits)
        local batches = container.batches or {}
        for batchIndex, batch in ipairs(batches) do
            local batchPath = string.format("%s.batches.batch(%d)", containerPath, batchIndex - 1)
            xmlFile:setFloat(batchPath .. "#amount", batch.amount or 0)
            xmlFile:setFloat(batchPath .. "#ageInPeriods", batch.ageInPeriods or 0)
        end

        -- Write metadata
        local metaPath = containerPath .. ".metadata"
        xmlFile:setInt(metaPath .. "#farmId", container.farmId or 0)

        -- Write optional metadata fields
        if container.metadata ~= nil then
            if container.metadata.fermenting ~= nil then
                xmlFile:setBool(metaPath .. "#fermenting", container.metadata.fermenting)
            end
            if container.metadata.location ~= nil then
                xmlFile:setString(metaPath .. "#location", container.metadata.location)
            end
        end

        containerIndex = containerIndex + 1
    end
    Log:trace("SAVE: wrote %d containers", containerIndex)

    -- Write statistics section
    statistics = statistics or {}
    xmlFile:setInt("freshData.statistics#totalExpired", statistics.totalExpired or 0)

    -- Write expiredByFillType using fillTypeName (string) instead of index
    local expiredByFillType = statistics.expiredByFillType or {}
    local expiredIndex = 0
    for fillTypeIndex, amount in pairs(expiredByFillType) do
        local expiredPath = string.format("freshData.statistics.expiredByFillType.fillType(%d)", expiredIndex)
        -- Convert index to name for persistence (strings are stable)
        local fillTypeName = RmFreshManager:getFillTypeName(fillTypeIndex)
        xmlFile:setString(expiredPath .. "#name", fillTypeName)
        xmlFile:setInt(expiredPath .. "#amount", amount)
        expiredIndex = expiredIndex + 1
    end
    Log:trace("SAVE: wrote statistics with %d expired fillTypes", expiredIndex)

    -- Save and cleanup
    xmlFile:save()
    xmlFile:delete()

    Log:debug("SAVE: saved %d containers to %s (v%d format)",
        containerIndex, self.FILE_DATA, self.VERSION)
    Log:trace("<<< save = true (containers=%d)", containerIndex)
    return true
end

--- Save loss log to rm_FreshLog.xml (v4 expanded format)
--- No automatic pruning - log grows indefinitely until manual clear
---@param savegameDir string Path to savegame directory
---@param lossLog table Array of loss log entries from RmLossTracker
---@return boolean true on success, false on failure
function RmFreshIO:saveLog(savegameDir, lossLog)
    lossLog = lossLog or {}
    Log:trace(">>> saveLog(savegameDir=%s, entries=%d)", savegameDir or "nil", #lossLog)

    if savegameDir == nil or savegameDir == "" then
        Log:error("SAVE_LOG: savegameDir cannot be nil or empty")
        Log:trace("<<< saveLog = false (invalid savegameDir)")
        return false
    end

    -- Register schema on first use (matches load pattern)
    RmFreshIO.registerLogSchema()

    local filePath = self:getFilePath(savegameDir, self.FILE_LOG)

    -- Use XMLFile API with schema for validation
    local xmlFile = XMLFile.create("freshLog", filePath, "freshLog", self.logSchema)
    if xmlFile == nil then
        Log:error("SAVE_LOG: Failed to create log file: %s", filePath)
        Log:trace("<<< saveLog = false (XMLFile.create failed)")
        return false
    end

    -- Write version attribute
    xmlFile:setInt("freshLog#version", self.VERSION)

    -- Write log entries with full fields (v4 expanded format)
    for i, entry in ipairs(lossLog) do
        local entryPath = string.format("freshLog.entry(%d)", i - 1)
        -- Timing
        xmlFile:setInt(entryPath .. "#year", entry.year or 1)
        xmlFile:setInt(entryPath .. "#period", entry.period or 1)
        xmlFile:setInt(entryPath .. "#dayInPeriod", entry.dayInPeriod or 1)
        xmlFile:setInt(entryPath .. "#hour", entry.hour or 0)
        -- What
        xmlFile:setString(entryPath .. "#fillTypeName", entry.fillTypeName or "UNKNOWN")
        xmlFile:setFloat(entryPath .. "#amount", entry.amount or 0)
        xmlFile:setFloat(entryPath .. "#value", entry.value or 0)
        -- Where (persistent identity)
        xmlFile:setString(entryPath .. "#location", entry.location or "Unknown")
        xmlFile:setString(entryPath .. "#objectUniqueId", entry.objectUniqueId or "")
        xmlFile:setString(entryPath .. "#entityType", entry.entityType or "unknown")
        -- Who
        xmlFile:setInt(entryPath .. "#farmId", entry.farmId or 0)

        Log:trace("    entry[%d]: %s %.0f at %s (farm %d)",
            i, entry.fillTypeName or "?", entry.amount or 0, entry.location or "?", entry.farmId or 0)
    end

    -- Save and cleanup (NEW API)
    xmlFile:save()
    xmlFile:delete()

    Log:debug("SAVE_LOG: saved %d log entries to %s (v%d format)", #lossLog, self.FILE_LOG, self.VERSION)
    Log:trace("<<< saveLog = true")
    return true
end

-- =============================================================================
-- SETTINGS LOAD/SAVE FUNCTIONS
-- =============================================================================

--- Load settings from any Fresh settings XML file
--- Works for both mod defaults and user overrides (unified format)
---@param filePath string Full path to XML file
---@return table { global = {}, fillTypes = {} }
function RmFreshIO:loadSettings(filePath)
    Log:trace(">>> loadSettings(filePath=%s)", filePath or "nil")

    if filePath == nil or filePath == "" then
        Log:trace("<<< loadSettings = {} (no path)")
        return { global = {}, fillTypes = {} }
    end

    RmFreshIO.registerSettingsSchema()

    local xmlFile = XMLFile.loadIfExists("freshSettings", filePath, self.settingsSchema)
    if xmlFile == nil then
        Log:debug("LOAD_SETTINGS: File not found: %s", filePath)
        return { global = {}, fillTypes = {} }
    end

    local result = { global = {}, fillTypes = {} }
    local version = xmlFile:getInt("freshSettings#version", 1)
    Log:trace("LOAD_SETTINGS: version=%d", version)
    -- Future: Add migration logic here when SETTINGS_VERSION > 1

    -- Parse global settings (optional section)
    xmlFile:iterate("freshSettings.global.setting", function(_, path)
        local name = xmlFile:getString(path .. "#name")
        local valueStr = xmlFile:getString(path .. "#value")
        if name and valueStr then
            if valueStr == "true" then
                result.global[name] = true
            elseif valueStr == "false" then
                result.global[name] = false
            else
                result.global[name] = tonumber(valueStr) or valueStr
            end
            Log:trace("LOAD_SETTINGS: global.%s = %s", name, valueStr)
        end
    end)

    -- Parse fillType settings
    xmlFile:iterate("freshSettings.fillTypes.fillType", function(_, path)
        local name = xmlFile:getString(path .. "#name")
        if name then
            local expires = xmlFile:getString(path .. "#expires")
            local period = xmlFile:getFloat(path .. "#period", nil)

            if expires == "false" then
                result.fillTypes[name] = { expires = false }
                Log:trace("LOAD_SETTINGS: %s = expires=false", name)
            elseif period and period > 0 then
                result.fillTypes[name] = { period = period }
                Log:trace("LOAD_SETTINGS: %s = period=%.2f", name, period)
            elseif period then
                Log:warning("LOAD_SETTINGS: Invalid period %.2f for %s", period, name)
                result.fillTypes[name] = { expires = false }
            end
        end
    end)

    xmlFile:delete()

    Log:debug("LOAD_SETTINGS: Loaded %d global, %d fillTypes from %s",
        self:countTable(result.global), self:countTable(result.fillTypes), filePath)
    return result
end

--- Save settings to Fresh settings XML file
---@param filePath string Full path to XML file
---@param data table { global = {}, fillTypes = {} }
---@return boolean Success
function RmFreshIO:saveSettings(filePath, data)
    data = data or { global = {}, fillTypes = {} }
    Log:trace(">>> saveSettings(filePath=%s)", filePath or "nil")

    if filePath == nil or filePath == "" then
        Log:error("SAVE_SETTINGS: filePath cannot be nil or empty")
        return false
    end

    RmFreshIO.registerSettingsSchema()

    local xmlFile = XMLFile.create("freshSettings", filePath, "freshSettings", self.settingsSchema)
    if xmlFile == nil then
        Log:error("SAVE_SETTINGS: Failed to create: %s", filePath)
        return false
    end

    xmlFile:setInt("freshSettings#version", self.SETTINGS_VERSION)

    -- Write global settings
    local globalIdx = 0
    for key, value in pairs(data.global or {}) do
        local path = string.format("freshSettings.global.setting(%d)", globalIdx)
        xmlFile:setString(path .. "#name", key)
        xmlFile:setString(path .. "#value", tostring(value))
        globalIdx = globalIdx + 1
    end

    -- Write fillType settings
    local ftIdx = 0
    for name, config in pairs(data.fillTypes or {}) do
        local path = string.format("freshSettings.fillTypes.fillType(%d)", ftIdx)
        xmlFile:setString(path .. "#name", name)
        if config.expires == false then
            xmlFile:setString(path .. "#expires", "false")
        elseif config.period then
            xmlFile:setFloat(path .. "#period", config.period)
        end
        ftIdx = ftIdx + 1
    end

    xmlFile:save()
    xmlFile:delete()

    Log:debug("SAVE_SETTINGS: Saved %d global, %d fillTypes to %s", globalIdx, ftIdx, filePath)
    return true
end

-- =============================================================================
-- LOAD FUNCTIONS
-- =============================================================================

--- Load Fresh data from rm_FreshData.xml --- Returns nil if file doesn't exist (new game) or version < 4 (clean slate upgrade)
--- CRITICAL: Loads to reconciliationPool, NOT containers - runtimeEntity will be nil
---@param savegameDir string Path to savegame directory
---@return table|nil { reconciliationPool = {}, statistics = {} } or nil if no save/incompatible
function RmFreshIO:load(savegameDir)
    Log:trace(">>> load(savegameDir=%s)", savegameDir or "nil")

    if savegameDir == nil or savegameDir == "" then
        Log:error("LOAD: savegameDir cannot be nil or empty")
        Log:trace("<<< load = nil (invalid savegameDir)")
        return nil
    end

    -- Register schema on first use
    RmFreshIO.registerSchema()

    local filePath = self:getFilePath(savegameDir, self.FILE_DATA)
    local xmlFile = XMLFile.loadIfExists("freshData", filePath, self.xmlSchema)
    if not xmlFile then
        Log:debug("LOAD: No save file found (new game or first load)")
        Log:trace("<<< load = nil (no save file)")
        return nil
    end

    -- Read and validate version
    local version = xmlFile:getInt("freshData#version", 1)
    if version < 4 then
        -- Clean slate: ignore legacy saves (v1-v3)
        Log:info("LOAD: Legacy save format v%d ignored - starting fresh (v%d required)",
            version, self.VERSION)
        xmlFile:delete()
        Log:trace("<<< load = nil (legacy format v%d)", version)
        return nil
    end

    -- Initialize result structure (uses reconciliationPool, not containers)
    local data = {
        reconciliationPool = {},
        statistics = {
            totalExpired = 0,
            expiredByFillType = {},
            lossLog = {}
        }
    }

    -- Parse containers section → reconciliationPool
    xmlFile:iterate("freshData.containers.container", function(_, containerPath)
        local containerId = xmlFile:getString(containerPath .. "#id")
        if containerId == nil or containerId == "" then
            Log:warning("LOAD: Skipping container with missing id")
            return
        end

        local entityType = xmlFile:getString(containerPath .. "#entityType", "unknown")

        -- Reconstruct identityMatch from <worldObject> and <storage> elements
        local identityMatch = {
            worldObject = {},
            storage = {}
        }

        -- Read worldObject (entity identity anchor)
        local uniqueId = xmlFile:getString(containerPath .. ".worldObject#uniqueId")
        if uniqueId ~= nil and uniqueId ~= "" then
            identityMatch.worldObject.uniqueId = uniqueId
        end
        local objectType = xmlFile:getString(containerPath .. ".worldObject#objectType")
        if objectType ~= nil and objectType ~= "" then
            identityMatch.worldObject.objectType = objectType
        end

        -- Read storage (content identity)
        local fillTypeName = xmlFile:getString(containerPath .. ".storage#fillTypeName")
        if fillTypeName ~= nil and fillTypeName ~= "" then
            identityMatch.storage.fillTypeName = fillTypeName
        end
        local fillUnitIndex = xmlFile:getInt(containerPath .. ".storage#fillUnitIndex")
        if fillUnitIndex ~= nil and fillUnitIndex > 0 then
            identityMatch.storage.fillUnitIndex = fillUnitIndex
        end
        local amount = xmlFile:getFloat(containerPath .. ".storage#amount")
        if amount ~= nil then
            identityMatch.storage.amount = amount
        end

        -- Read extended identity for stored objects (ObjectStorage)
        local className = xmlFile:getString(containerPath .. ".storage#className")
        if className ~= nil and className ~= "" then
            identityMatch.storage.className = className
        end
        local storageFarmId = xmlFile:getInt(containerPath .. ".storage#storageFarmId")
        if storageFarmId ~= nil then
            identityMatch.storage.farmId = storageFarmId
        end
        -- Bale-specific identity fields
        local variationIndex = xmlFile:getInt(containerPath .. ".storage#variationIndex")
        if variationIndex ~= nil then
            identityMatch.storage.variationIndex = variationIndex
        end
        local isMissionBale = xmlFile:getBool(containerPath .. ".storage#isMissionBale")
        if isMissionBale ~= nil then
            identityMatch.storage.isMissionBale = isMissionBale
        end
        local wrappingState = xmlFile:getFloat(containerPath .. ".storage#wrappingState")
        if wrappingState ~= nil then
            identityMatch.storage.wrappingState = wrappingState
        end
        -- Vehicle-specific identity fields
        local isBigBag = xmlFile:getBool(containerPath .. ".storage#isBigBag")
        if isBigBag ~= nil then
            identityMatch.storage.isBigBag = isBigBag
        end

        -- Create container structure
        local container = {
            id = containerId,
            entityType = entityType,
            identityMatch = identityMatch,
            runtimeEntity = nil,  -- CRITICAL: Set during reconciliation
            fillTypeIndex = nil,  -- CRITICAL: Resolved at runtime
            batches = {},
            farmId = 0,
            metadata = {}
        }

        -- Read flat batches array (at container level)
        xmlFile:iterate(containerPath .. ".batches.batch", function(_, batchPath)
            local batchAmount = xmlFile:getFloat(batchPath .. "#amount", 0)
            local ageInPeriods = xmlFile:getFloat(batchPath .. "#ageInPeriods", 0)
            table.insert(container.batches, {
                amount = batchAmount,
                ageInPeriods = ageInPeriods
            })
        end)

        -- Skip empty containers (no batches = nothing to reconcile)
        if #container.batches == 0 then
            Log:trace("LOAD: Skipping empty container %s (entityType=%s, no batches)",
                containerId, entityType)
            return  -- Skip this container, don't add to pool
        end

        -- Read metadata
        local metaPath = containerPath .. ".metadata"
        container.farmId = xmlFile:getInt(metaPath .. "#farmId", 0)

        local fermenting = xmlFile:getBool(metaPath .. "#fermenting")
        if fermenting ~= nil then
            container.metadata.fermenting = fermenting
        end
        local location = xmlFile:getString(metaPath .. "#location")
        if location ~= nil and location ~= "" then
            container.metadata.location = location
        end

        -- Add to reconciliationPool (NOT containers)
        data.reconciliationPool[containerId] = container
    end)
    Log:trace("LOAD: parsed %d containers to reconciliationPool", self:countTable(data.reconciliationPool))

    -- Parse statistics section
    data.statistics.totalExpired = xmlFile:getInt("freshData.statistics#totalExpired", 0)

    -- Read expiredByFillType (stored as fillTypeName, convert to fillTypeIndex at runtime)
    xmlFile:iterate("freshData.statistics.expiredByFillType.fillType", function(_, expiredPath)
        local fillTypeName = xmlFile:getString(expiredPath .. "#name")
        local amount = xmlFile:getInt(expiredPath .. "#amount", 0)
        if fillTypeName ~= nil and fillTypeName ~= "" then
            -- Convert fillTypeName to fillTypeIndex at runtime
            local fillTypeIndex = RmFreshManager:resolveFillTypeIndex(fillTypeName)
            if fillTypeIndex ~= nil then
                data.statistics.expiredByFillType[fillTypeIndex] = amount
            else
                Log:trace("LOAD: Skipping expired stat for unknown fillType: %s", fillTypeName)
            end
        end
    end)
    Log:trace("LOAD: parsed statistics (totalExpired=%d)", data.statistics.totalExpired)

    -- Cleanup
    xmlFile:delete()

    local poolCount = self:countTable(data.reconciliationPool)
    Log:debug("LOAD: loaded %d containers to reconciliationPool from %s (v%d format)",
        poolCount, self.FILE_DATA, version)
    Log:trace("<<< load = data (containers=%d, v%d)", poolCount, version)
    return data
end

--- Load loss log from rm_FreshLog.xml (v4 expanded format)
--- Returns empty array if file doesn't exist
---@param savegameDir string Path to savegame directory
---@return table Array of loss log entries (may be empty)
function RmFreshIO:loadLog(savegameDir)
    Log:trace(">>> loadLog(savegameDir=%s)", savegameDir or "nil")

    if savegameDir == nil or savegameDir == "" then
        Log:error("LOAD_LOG: savegameDir cannot be nil or empty")
        Log:trace("<<< loadLog = {} (invalid savegameDir)")
        return {}
    end

    -- Register schema on first use (matches save pattern)
    RmFreshIO.registerLogSchema()

    local filePath = self:getFilePath(savegameDir, self.FILE_LOG)
    local xmlFile = XMLFile.loadIfExists("freshLog", filePath, self.logSchema)
    if not xmlFile then
        Log:debug("LOAD_LOG: No log file found (this is normal)")
        Log:trace("<<< loadLog = {} (no file)")
        return {}
    end

    -- Read version (informational only - v4 is first real format)
    local version = xmlFile:getInt("freshLog#version", 1)
    Log:trace("    file version: %d", version)

    -- Parse log entries (v4 expanded format)
    local lossLog = {}
    local entryCount = 0
    xmlFile:iterate("freshLog.entry", function(_, entryPath)
        local objectUniqueId = xmlFile:getString(entryPath .. "#objectUniqueId", "")
        local entry = {
            -- Timing
            year = xmlFile:getInt(entryPath .. "#year", 1),
            period = xmlFile:getInt(entryPath .. "#period", 1),
            dayInPeriod = xmlFile:getInt(entryPath .. "#dayInPeriod", 1),
            hour = xmlFile:getInt(entryPath .. "#hour", 0),
            -- What
            fillTypeName = xmlFile:getString(entryPath .. "#fillTypeName", "UNKNOWN"),
            amount = xmlFile:getFloat(entryPath .. "#amount", 0),
            value = xmlFile:getFloat(entryPath .. "#value", 0),
            -- Where (persistent identity)
            location = xmlFile:getString(entryPath .. "#location", "Unknown"),
            objectUniqueId = objectUniqueId ~= "" and objectUniqueId or nil,
            entityType = xmlFile:getString(entryPath .. "#entityType", "unknown"),
            -- Who
            farmId = xmlFile:getInt(entryPath .. "#farmId", 0),
        }
        table.insert(lossLog, entry)
        entryCount = entryCount + 1

        Log:trace("    parsed[%d]: %s %.0f (Y%d P%d D%d)",
            entryCount, entry.fillTypeName, entry.amount, entry.year, entry.period, entry.dayInPeriod)
    end)

    -- Cleanup
    xmlFile:delete()

    Log:debug("LOAD_LOG: loaded %d log entries from %s (v%d format)", #lossLog, self.FILE_LOG, version)
    Log:trace("<<< loadLog = %d entries", #lossLog)
    return lossLog
end

-- =============================================================================
-- INTERNAL HELPERS
-- =============================================================================

--- Count entries in a table (works for both array and hash tables)
---@param t table Table to count
---@return number Number of entries
function RmFreshIO:countTable(t)
    if t == nil then return 0 end
    local count = 0
    for _ in pairs(t) do
        count = count + 1
    end
    return count
end
