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
RmFreshSettings.MIN_EXPIRATION = 1.0   -- 1 month minimum (periods)
RmFreshSettings.MAX_EXPIRATION = 60.0  -- 5 years maximum (periods)

--- Warning threshold multiplier (calculated at runtime, not stored per-fillType)
--- Future: Could become a global setting if users want to configure it
RmFreshSettings.DEFAULT_WARNING = 0.75  -- 75% of expiration period

--- Global setting defaults
RmFreshSettings.GLOBAL_DEFAULTS = {
    enableExpiration = true,
    showWarnings = true,
    showAgeDisplay = true,
}

--- Merge threshold for batch compaction (0.01 periods = ~7 in-game hours)
RmFreshSettings.MERGE_THRESHOLD = 0.01

--- Default thresholds for unknown fill types (used when fillType not configured)
RmFreshSettings.DEFAULT_THRESHOLDS = {
    expiration = 1.0,
    warning = 0.75
}

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

--- Get expiration period for a fillType (3-layer merge: user → mod → nil)
--- Returns nil for fillTypes that don't expire
---@param fillTypeName string The fillType name (e.g., "WHEAT")
---@return number|nil Expiration period in months, or nil if doesn't expire
function RmFreshSettings:getExpiration(fillTypeName)
    -- Layer 1: Check user override (highest priority)
    local userOverride = self.userOverrides.fillTypes[fillTypeName]
    if userOverride ~= nil then
        if userOverride.expires == false then
            return nil  -- User explicitly set "do not expire"
        end
        if userOverride.period ~= nil then
            return userOverride.period
        end
    end

    -- Layer 2: Check mod default
    local modDefault = self.modDefaults[fillTypeName]
    if modDefault ~= nil then
        if modDefault.expires == false then
            return nil  -- Mod default is "do not expire"
        end
        if modDefault.period ~= nil then
            return modDefault.period
        end
    end

    -- Layer 3: Not configured = do not expire
    return nil
end

--- Get warning threshold age for a fillType
--- Returns expiration * DEFAULT_WARNING, or nil if doesn't expire
---@param fillTypeName string The fillType name
---@return number|nil Warning age threshold in periods, or nil if doesn't expire
function RmFreshSettings:getWarningThreshold(fillTypeName)
    local expiration = self:getExpiration(fillTypeName)
    if expiration == nil then
        return nil
    end
    return expiration * self.DEFAULT_WARNING
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
                    warning = self.DEFAULT_WARNING
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

--- Get the AGE when warning should show for a fill type (index-based)
---@param fillTypeIndex number Fill type index
---@return number Warning age threshold in periods
function RmFreshSettings:getWarningThresholdByIndex(fillTypeIndex)
    local config = self:getThresholdByIndex(fillTypeIndex)
    return config.expiration * self.DEFAULT_WARNING
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

    -- Rescan world for newly-perishable containers (RIT-139)
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

--- Clear all user overrides (both fillTypes AND global settings)
function RmFreshSettings:resetAllOverrides()
    local ftCount = self:tableCount(self.userOverrides.fillTypes)
    local globalCount = self:tableCount(self.userOverrides.global)

    -- Log what we're about to clear (for debugging)
    Log:debug("SETTINGS_RESET: Before clear - BREAD override=%s, BUTTER override=%s",
        tostring(self.userOverrides.fillTypes["BREAD"] and self.userOverrides.fillTypes["BREAD"].period),
        tostring(self.userOverrides.fillTypes["BUTTER"] and self.userOverrides.fillTypes["BUTTER"].expires))
    Log:debug("SETTINGS_RESET: modDefaults BREAD=%s, BUTTER=%s",
        tostring(self.modDefaults["BREAD"] and self.modDefaults["BREAD"].period),
        tostring(self.modDefaults["BUTTER"] and self.modDefaults["BUTTER"].period))

    -- Clear BOTH fillTypes AND global overrides
    self.userOverrides.fillTypes = {}
    self.userOverrides.global = {}

    Log:debug("SETTINGS_RESET: After clear - BREAD override=%s, getExpiration(BREAD)=%s",
        tostring(self.userOverrides.fillTypes["BREAD"]),
        tostring(self:getExpiration("BREAD")))

    Log:debug("SETTINGS_RESET: Cleared %d fillType and %d global overrides", ftCount, globalCount)

    -- Notify dependents and sync MP
    if ftCount > 0 or globalCount > 0 then
        self:onSettingsChanged()
    end
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
