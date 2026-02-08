-- RmFreshSettings.lua
-- Purpose: Settings data model with XML-based configuration loading
-- Author: Ritter
-- Pattern: Three-layer configuration (game fillTypes → mod defaults → user overrides)

RmFreshSettings = {}

-- Get logger (RmLogging loaded before this module in main.lua)
local Log = RmLogging.getLogger("Fresh")

-- =============================================================================
-- CONSTANTS
-- =============================================================================

--- Configuration path (relative to mod directory)
RmFreshSettings.MOD_DEFAULTS_PATH = "data/defaultSettings.xml"

--- Validation bounds for user override validation
RmFreshSettings.MIN_EXPIRATION = 1.0  -- 1 month minimum (periods)
RmFreshSettings.MAX_EXPIRATION = 60.0 -- 5 years maximum (periods)

--- Global setting defaults
RmFreshSettings.GLOBAL_DEFAULTS = {
    enableExpiration = true,
    showWarnings = true,
    showAgeDisplay = true,
    warningHours = 24,  -- Warn when expiring within N hours
    preset = "normal",  -- Difficulty preset (veryEasy/easy/normal/hard/custom)
}

--- Merge threshold for batch compaction (0.01 periods = ~7 in-game hours)
RmFreshSettings.MERGE_THRESHOLD = 0.01

--- Default thresholds for unknown fill types (used when fillType not configured)
RmFreshSettings.DEFAULT_THRESHOLDS = {
    expiration = 1.0
}

--- Preset difficulty multipliers applied to mod defaults
RmFreshSettings.PRESET_MULTIPLIERS = { veryEasy = 4.0, easy = 2.0, normal = 1.0, hard = 0.5 }
RmFreshSettings.PRESET_NAMES = { "veryEasy", "easy", "normal", "hard", "custom" }

-- =============================================================================
-- STATE STRUCTURES (initialized in initialize())
-- =============================================================================

--- Mod directory path (set during initialize())
RmFreshSettings.modDirectory = nil

--- All fillTypes from game (fillTypeName → { name, title })
RmFreshSettings.allFillTypes = {}

--- Mod defaults from fillTypeDefaults.xml (fillTypeName → { period = X } or { expires = false })
RmFreshSettings.modDefaults = {}

--- User overrides
--- Structure: { global = { key → value }, fillTypes = { fillTypeName → { period = X } or { expires = false } } }
RmFreshSettings.userOverrides = {
    global = {},
    fillTypes = {},
}

--- Runtime cache - index-keyed for fast lookups (rebuilt on settings change)
RmFreshSettings.perishableByIndex = {}

--- Batch mode flag: when true, onSettingsChanged() is suppressed
--- Used by applyBatchChanges() to apply multiple overrides with one notify
RmFreshSettings.suppressNotify = false

--- Fill type source tracking (populated by hooks during map load)
--- fillTypeName → { source = "basegame"|"dlc"|"mod"|"map", modName = string|nil }
RmFreshSettings.fillTypeSourceMap = {}

--- Internal flag: true while inside FillTypeManager:loadModFillTypes()
RmFreshSettings._isLoadingModFillTypes = false

-- =============================================================================
-- FILL TYPE SOURCE TRACKING
-- =============================================================================

--- Install hooks on FillTypeManager to track fill type origins.
--- MUST be called at script source time (before loadMapData runs).
function RmFreshSettings.installFillTypeSourceHooks()
    -- Hook 1: Flag when inside loadModFillTypes
    FillTypeManager.loadModFillTypes = Utils.overwrittenFunction(
        FillTypeManager.loadModFillTypes,
        function(manager, superFunc)
            RmFreshSettings._isLoadingModFillTypes = true
            superFunc(manager)
            RmFreshSettings._isLoadingModFillTypes = false
        end
    )

    -- Hook 2: Classify new fill types after each loadFillTypes call
    FillTypeManager.loadFillTypes = Utils.overwrittenFunction(
        FillTypeManager.loadFillTypes,
        function(manager, superFunc, xmlFile, baseDirectory, isBaseType, customEnv, finalizeType)
            -- Reset source map on first call (basegame load)
            if isBaseType then
                RmFreshSettings.fillTypeSourceMap = {}
            end

            -- Snapshot existing fill type names
            local existingNames = {}
            for _, ft in ipairs(manager.fillTypes) do
                existingNames[ft.name] = true
            end

            -- Call original
            local result = superFunc(manager, xmlFile, baseDirectory, isBaseType, customEnv, finalizeType)

            -- Determine source category
            local source
            if isBaseType then
                source = "basegame"
            elseif RmFreshSettings._isLoadingModFillTypes then
                if customEnv and g_modManager then
                    local mod = g_modManager:getModByName(customEnv)
                    if mod and mod.isDLC then
                        source = "dlc"
                    else
                        source = "mod"
                    end
                else
                    source = "mod"
                end
            else
                -- Called from loadMapData (not loadModFillTypes)
                -- customEnv = missionInfo.customEnvironment (nil for basegame maps, mod name for mod/DLC maps)
                if customEnv and g_modManager then
                    local mod = g_modManager:getModByName(customEnv)
                    if mod and mod.isDLC then
                        source = "dlc"
                    else
                        source = "map"
                    end
                else
                    source = "map"
                end
            end

            -- Record source for newly added fill types only
            local newCount = 0
            for _, ft in ipairs(manager.fillTypes) do
                if not existingNames[ft.name] and not RmFreshSettings.fillTypeSourceMap[ft.name] then
                    RmFreshSettings.fillTypeSourceMap[ft.name] = {
                        source = source,
                        modName = customEnv,
                    }
                    newCount = newCount + 1
                end
            end

            if newCount > 0 then
                Log:debug("FILLTYPE_SOURCE: %d new fillTypes -> source=%s (customEnv=%s)",
                    newCount, source, tostring(customEnv))
            end

            return result
        end
    )

    Log:debug("Fill type source tracking hooks installed")
end

--- Get the source origin of a fill type
---@param fillTypeName string The fill type name
---@return string source "basegame"|"dlc"|"mod"|"map"|"unknown"
---@return string|nil modName The mod/DLC name if applicable
function RmFreshSettings:getFillTypeSource(fillTypeName)
    local entry = self.fillTypeSourceMap[fillTypeName]
    if entry then
        return entry.source, entry.modName
    end

    -- Fallback: hudOverlayFilename heuristic for fill types missed by hooks
    if g_fillTypeManager then
        local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(fillTypeName)
        if fillTypeIndex then
            local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
            if fillType and fillType.hudOverlayFilename then
                if string.startsWith(fillType.hudOverlayFilename, "dataS/") then
                    return "basegame", nil
                end
            end
        end
    end

    return "unknown", nil
end

-- =============================================================================
-- UTILITY FUNCTIONS
-- =============================================================================

--- Count entries in a table (since Lua's # only works for arrays)
---@param t table The table to count
---@return number The number of entries
function RmFreshSettings:tableCount(t)
    local count = 0
    for _ in pairs(t or {}) do
        count = count + 1
    end
    return count
end

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

--- Initialize the settings module - load game fillTypes and mod defaults
--- DEPENDENCY: Must be called AFTER g_fillTypeManager is available (during map load)
---@param modDir string The mod directory path
function RmFreshSettings:initialize(modDir)
    self.modDirectory = modDir

    -- Load all fillTypes from game
    self:loadGameFillTypes()

    -- Load mod author defaults from XML
    self:loadModDefaults()

    -- Build index-based cache for adapter performance
    self:rebuildIndexCache()

    -- Log initialization summary
    Log:info("RmFreshSettings initialized: %d fillTypes, %d mod defaults, %d perishable",
        self:getFillTypeCount(), self:getModDefaultCount(), self:tableCount(self.perishableByIndex))
end

--- Load all fillTypes from g_fillTypeManager
--- Stores name and title for each fillType
function RmFreshSettings:loadGameFillTypes()
    self.allFillTypes = {}

    if g_fillTypeManager == nil then
        Log:warning("SETTINGS_LOAD: g_fillTypeManager not available")
        return
    end

    local fillTypes = g_fillTypeManager:getFillTypes()
    if fillTypes == nil then
        Log:warning("SETTINGS_LOAD: getFillTypes() returned nil")
        return
    end

    for _, fillType in pairs(fillTypes) do
        if fillType.name ~= nil then
            self.allFillTypes[fillType.name] = {
                name = fillType.name,
                title = fillType.title or fillType.name,
            }
            Log:trace("SETTINGS_FILLTYPE: %s (title=%s)", fillType.name, fillType.title or "nil")
        end
    end

    Log:debug("SETTINGS_LOAD: Loaded %d fillTypes from game", self:getFillTypeCount())
end

--- Load mod author defaults from defaultSettings.xml
--- Delegates parsing to RmFreshIO:loadSettings() for unified format handling
function RmFreshSettings:loadModDefaults()
    self.modDefaults = {}

    if self.modDirectory == nil then
        Log:warning("SETTINGS_LOAD: modDirectory not set")
        return
    end

    local xmlPath = self.modDirectory .. self.MOD_DEFAULTS_PATH
    local data = RmFreshIO:loadSettings(xmlPath)
    self.modDefaults = data.fillTypes or {}

    Log:debug("SETTINGS_LOAD: Loaded %d mod defaults", self:tableCount(self.modDefaults))
end

-- =============================================================================
-- QUERY FUNCTIONS
-- =============================================================================

--- Get expiration period for a fillType (3-layer merge: user → preset×mod → nil)
--- Returns nil for fillTypes that don't expire
--- User override ALWAYS wins (safety: prevents inventory loss on mod update)
---@param fillTypeName string The fillType name (e.g., "WHEAT")
---@return number|nil Expiration period in months, or nil if doesn't expire
function RmFreshSettings:getExpiration(fillTypeName)
    -- Layer 1: User override ALWAYS wins (safety: prevents inventory loss on mod update)
    local userOverride = self.userOverrides.fillTypes[fillTypeName]
    if userOverride ~= nil then
        if userOverride.expires == false then
            Log:trace("EXPIRATION: %s -> nil (user override expires=false)", fillTypeName)
            return nil
        end
        if userOverride.period ~= nil then
            Log:trace("EXPIRATION: %s -> %.2f (user override)", fillTypeName, userOverride.period)
            return userOverride.period
        end
    end

    -- Layer 2: Mod default (with optional preset multiplier)
    local modDefault = self.modDefaults[fillTypeName]
    if modDefault ~= nil then
        if modDefault.expires == false then
            Log:trace("EXPIRATION: %s -> nil (mod default expires=false)", fillTypeName)
            return nil
        end
        if modDefault.period ~= nil then
            local preset = self:getGlobal("preset") or "custom"
            if preset ~= "custom" then
                local multiplier = self.PRESET_MULTIPLIERS[preset] or 1.0
                local result = math.min(modDefault.period * multiplier, self.MAX_EXPIRATION)
                Log:trace("EXPIRATION: %s -> %.2f (preset=%s, default=%.2f, x%.1f)",
                    fillTypeName, result, preset, modDefault.period, multiplier)
                return result
            end
            Log:trace("EXPIRATION: %s -> %.2f (mod default, custom mode)", fillTypeName, modDefault.period)
            return modDefault.period
        end
    end

    -- Layer 3: Not configured = do not expire
    return nil
end

--- Check if a fillType is perishable (has expiration set)
---@param fillTypeName string The fillType name
---@return boolean True if fillType has expiration configured
function RmFreshSettings:isPerishable(fillTypeName)
    return self:getExpiration(fillTypeName) ~= nil
end

--- Get all fillType names as a sorted array
---@return table Array of fillType names (sorted alphabetically)
function RmFreshSettings:getAllFillTypes()
    local names = {}
    for name, _ in pairs(self.allFillTypes) do
        table.insert(names, name)
    end
    table.sort(names)
    return names
end

--- Get count of all fillTypes
---@return number Number of fillTypes loaded from game
function RmFreshSettings:getFillTypeCount()
    return self:tableCount(self.allFillTypes)
end

--- Get count of mod defaults
---@return number Number of fillTypes with mod defaults
function RmFreshSettings:getModDefaultCount()
    return self:tableCount(self.modDefaults)
end

-- =============================================================================
-- INDEX-BASED API
-- These methods use fillTypeIndex for adapter performance
-- =============================================================================

--- Rebuild the index-based cache from name-based settings
--- Called during initialize() and after any settings change
function RmFreshSettings:rebuildIndexCache()
    self.perishableByIndex = {}
    local count = 0

    for fillTypeName, _ in pairs(self.allFillTypes) do
        local expiration = self:getExpiration(fillTypeName)
        if expiration ~= nil then
            local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(fillTypeName)
            if fillTypeIndex ~= nil then
                self.perishableByIndex[fillTypeIndex] = {
                    expiration = expiration,
                }
                count = count + 1
                Log:trace("INDEX_CACHE: %s (idx=%d) -> exp=%.2f", fillTypeName, fillTypeIndex, expiration)
            end
        end
    end

    Log:debug("INDEX_CACHE: Rebuilt with %d perishable fillTypes", count)
end

--- Check if a fill type is perishable (index-based for adapter performance)
---@param fillTypeIndex number Fill type index
---@return boolean True if fill type is configured as perishable
function RmFreshSettings:isPerishableByIndex(fillTypeIndex)
    return self.perishableByIndex[fillTypeIndex] ~= nil
end

--- Get expiration threshold for a fill type (index-based)
---@param fillTypeIndex number Fill type index
---@return table Threshold config { expiration = number, warning = number }
function RmFreshSettings:getThresholdByIndex(fillTypeIndex)
    return self.perishableByIndex[fillTypeIndex] or self.DEFAULT_THRESHOLDS
end

--- Get the warning hours setting (hours before expiration to show warning)
---@return number Warning hours threshold
function RmFreshSettings:getWarningHours()
    return self:getGlobal("warningHours") or 24
end

--- Check if global expiration is enabled
--- When false, batches pause aging entirely (not just "never expire")
---@return boolean True if expiration is enabled
function RmFreshSettings:isExpirationEnabled()
    return self:getGlobal("enableExpiration") ~= false
end

-- =============================================================================
-- SETTINGS CHANGE NOTIFICATION
-- =============================================================================

--- Called after any settings change to notify dependents and sync MP
--- Rebuilds index cache and broadcasts to connected clients
--- IMPORTANT: Do NOT call from setUserOverrides() - that's the sync receiver
function RmFreshSettings:onSettingsChanged()
    if self.suppressNotify then
        Log:trace("    onSettingsChanged suppressed (batch mode)")
        return
    end

    Log:trace(">>> onSettingsChanged()")

    -- Rebuild index cache (replaces RmFreshConfig:initialize())
    self:rebuildIndexCache()
    Log:trace("    Index cache rebuilt")

    -- Broadcast to MP clients (server only)
    local broadcast = false
    if g_server and RmSettingsSyncEvent then
        RmSettingsSyncEvent.broadcastToClients()
        broadcast = true
    end

    -- Rescan world for newly-perishable containers
    if g_server and RmFreshManager then
        RmFreshManager:rescanForNewPerishables()
    end

    local globalCount = self:tableCount(self.userOverrides.global)
    local ftCount = self:tableCount(self.userOverrides.fillTypes)
    Log:debug("SETTINGS_CHANGED: %d global, %d fillTypes (broadcast=%s)",
        globalCount, ftCount, tostring(broadcast))
end

-- =============================================================================
-- USER OVERRIDE FUNCTIONS
-- =============================================================================

--- Set user override for fillType expiration
--- Validates bounds and stores override
---@param fillTypeName string The fillType name
---@param period number Expiration period in months
---@return boolean True if set successfully, false if validation failed
function RmFreshSettings:setExpiration(fillTypeName, period)
    -- Validate fillType exists
    if self.allFillTypes[fillTypeName] == nil then
        Log:warning("SETTINGS_SET: Unknown fillType %s", fillTypeName)
        return false
    end

    -- Validate period bounds
    if period < self.MIN_EXPIRATION or period > self.MAX_EXPIRATION then
        Log:warning("SETTINGS_SET: Period %.2f out of bounds [%.1f, %.1f] for %s",
            period, self.MIN_EXPIRATION, self.MAX_EXPIRATION, fillTypeName)
        return false
    end

    -- Store override
    self.userOverrides.fillTypes[fillTypeName] = { period = period }
    Log:debug("SETTINGS_SET: %s -> period=%.2f (user override)", fillTypeName, period)

    -- Notify dependents and sync MP
    self:onSettingsChanged()

    return true
end

--- Set user override to mark fillType as non-expiring
---@param fillTypeName string The fillType name
function RmFreshSettings:setDoNotExpire(fillTypeName)
    -- Validate fillType exists
    if self.allFillTypes[fillTypeName] == nil then
        Log:warning("SETTINGS_SET: Unknown fillType %s", fillTypeName)
        return
    end

    self.userOverrides.fillTypes[fillTypeName] = { expires = false }
    Log:debug("SETTINGS_SET: %s -> expires=false (user override)", fillTypeName)

    -- Notify dependents and sync MP
    self:onSettingsChanged()
end

--- Remove user override for a fillType (reverts to mod default or game default)
---@param fillTypeName string The fillType name
function RmFreshSettings:resetOverride(fillTypeName)
    if self.userOverrides.fillTypes[fillTypeName] ~= nil then
        self.userOverrides.fillTypes[fillTypeName] = nil
        Log:debug("SETTINGS_RESET: %s override removed", fillTypeName)

        -- Notify dependents and sync MP
        self:onSettingsChanged()
    end
end

--- Apply multiple fillType changes with a single onSettingsChanged() call
--- Used by settings frame to batch UI interactions on frame close
---@param changes table { fillTypeName = { action = string, value = number|nil } }
function RmFreshSettings:applyBatchChanges(changes)
    if not changes or not next(changes) then return end

    local count = 0
    for _ in pairs(changes) do count = count + 1 end
    Log:trace(">>> applyBatchChanges(count=%d)", count)

    self.suppressNotify = true
    for fillTypeName, change in pairs(changes) do
        if change.action == "setDoNotExpire" then
            self:setDoNotExpire(fillTypeName)
        elseif change.action == "setExpiration" then
            self:setExpiration(fillTypeName, change.value)
        end
    end
    self.suppressNotify = false

    self:onSettingsChanged()

    Log:debug("SETTINGS_BATCH: applied %d fillType changes", count)
    Log:trace("<<< applyBatchChanges")
end

--- Clear all user overrides (both fillTypes AND global settings)
function RmFreshSettings:resetAllOverrides()
    local ftCount = self:tableCount(self.userOverrides.fillTypes)
    local globalCount = self:tableCount(self.userOverrides.global)

    -- Clear BOTH fillTypes AND global overrides
    self.userOverrides.fillTypes = {}
    self.userOverrides.global = {}

    Log:debug("SETTINGS_RESET: Cleared %d fillType and %d global overrides", ftCount, globalCount)

    -- Notify dependents and sync MP
    if ftCount > 0 or globalCount > 0 then
        self:onSettingsChanged()
    end
end

--- Clear fillType overrides that are redundant (match mod default exactly)
--- Called when switching to a preset so the preset multiplier can take effect
--- Keeps overrides where the user intentionally changed the value from the default
function RmFreshSettings:clearRedundantOverrides()
    local removed = 0
    for name, override in pairs(self.userOverrides.fillTypes) do
        local modDefault = self.modDefaults[name]
        if modDefault ~= nil then
            local redundant = false
            if override.expires == false and modDefault.expires == false then
                redundant = true
            elseif override.period and modDefault.period and override.period == modDefault.period then
                redundant = true
            end
            if redundant then
                self.userOverrides.fillTypes[name] = nil
                removed = removed + 1
            end
        end
    end
    if removed > 0 then
        Log:debug("SETTINGS_PRESET: Cleared %d redundant fillType overrides (matching mod defaults)", removed)
    end
    return removed
end

-- =============================================================================
-- GLOBAL SETTINGS API
-- =============================================================================

--- Get a global setting value
---@param key string The setting key (e.g., "enableExpiration")
---@return any The setting value (user override → default)
function RmFreshSettings:getGlobal(key)
    -- Check user override first
    if self.userOverrides.global[key] ~= nil then
        return self.userOverrides.global[key]
    end

    -- Fall back to default
    return self.GLOBAL_DEFAULTS[key]
end

--- Set a global setting value
---@param key string The setting key
---@param value any The setting value
function RmFreshSettings:setGlobal(key, value)
    self.userOverrides.global[key] = value
    Log:debug("SETTINGS_GLOBAL: %s = %s", key, tostring(value))

    -- Notify dependents and sync MP
    self:onSettingsChanged()
end

-- =============================================================================
-- IO ACCESSORS (for RmFreshIO integration)
-- =============================================================================

--- Get user overrides for IO save or MP sync
---@return table { global = {}, fillTypes = {} }
function RmFreshSettings:getUserOverrides()
    -- Clean redundant overrides before returning (keeps save file lean)
    self:clearRedundantOverrides()
    return self.userOverrides
end

--- Set user overrides from IO load or MP sync
---@param overrides table { global = {}, fillTypes = {} }
function RmFreshSettings:setUserOverrides(overrides)
    self.userOverrides = overrides or { global = {}, fillTypes = {} }

    -- Ensure both sub-tables exist (defensive coding)
    if self.userOverrides.global == nil then
        self.userOverrides.global = {}
    end
    if self.userOverrides.fillTypes == nil then
        self.userOverrides.fillTypes = {}
    end

    Log:debug("SETTINGS: User overrides set (%d global, %d fillTypes)",
        self:tableCount(self.userOverrides.global),
        self:tableCount(self.userOverrides.fillTypes))
end
