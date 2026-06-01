-- RmSettingsSyncEvent.lua
-- Purpose: Multiplayer settings sync event - sends user overrides to joining clients
-- Author: Ritter
-- Pattern: Follows RmFreshSyncEvent.lua structure

RmSettingsSyncEvent = {}
local RmSettingsSyncEvent_mt = Class(RmSettingsSyncEvent, Event)

InitEventClass(RmSettingsSyncEvent, "RmSettingsSyncEvent")

local Log = RmLogging.getLogger("Fresh")

-- =============================================================================
-- EVENT LIFECYCLE
-- =============================================================================

--- Empty constructor for deserialization
function RmSettingsSyncEvent.emptyNew()
    return Event.new(RmSettingsSyncEvent_mt)
end

--- Constructor with settings data
---@param settingsData table User overrides { global = {}, fillTypes = {} }
function RmSettingsSyncEvent.new(settingsData)
    local self = RmSettingsSyncEvent.emptyNew()
    self.settingsData = settingsData or { global = {}, fillTypes = {} }
    return self
end

-- =============================================================================
-- SERIALIZATION
-- =============================================================================

--- Serialize settings for network transmission
---@param streamId number Network stream ID
---@param connection table Network connection
function RmSettingsSyncEvent:writeStream(streamId, connection)
    Log:trace(">>> writeStream()")

    -- Write global settings
    local globals = {}
    for k, v in pairs(self.settingsData.global or {}) do
        table.insert(globals, { name = k, value = v })
    end
    streamWriteUInt8(streamId, #globals)

    for _, g in ipairs(globals) do
        streamWriteString(streamId, g.name)
        if type(g.value) == "boolean" then
            streamWriteUInt8(streamId, 1)
            streamWriteBool(streamId, g.value)
            Log:trace("    global: %s = %s (bool)", g.name, tostring(g.value))
        elseif type(g.value) == "number" then
            streamWriteUInt8(streamId, 2)
            streamWriteFloat32(streamId, g.value)
            Log:trace("    global: %s = %s (number)", g.name, tostring(g.value))
        else
            streamWriteUInt8(streamId, 3)
            streamWriteString(streamId, tostring(g.value))
            Log:trace("    global: %s = %s (string)", g.name, tostring(g.value))
        end
    end

    -- Write fillType overrides
    local fillTypes = {}
    for name, config in pairs(self.settingsData.fillTypes or {}) do
        table.insert(fillTypes, { name = name, config = config })
    end
    streamWriteUInt16(streamId, #fillTypes)

    for _, ft in ipairs(fillTypes) do
        streamWriteString(streamId, ft.name)
        local isDoNotExpire = (ft.config.expires == false)
        streamWriteBool(streamId, isDoNotExpire)
        if isDoNotExpire then
            Log:trace("    fillType: %s = expires=false", ft.name)
        elseif ft.config.period then
            streamWriteFloat32(streamId, ft.config.period)
            Log:trace("    fillType: %s = period=%.2f", ft.name, ft.config.period)
        end
    end

    -- Write storage class overrides
    local overrides = self.settingsData.storageClassOverrides or {}
    local overrideCount = 0
    for _ in pairs(overrides) do overrideCount = overrideCount + 1 end
    streamWriteUInt16(streamId, overrideCount)
    for key, classValue in pairs(overrides) do
        streamWriteString(streamId, key)
        streamWriteUInt8(streamId, classValue)
        Log:trace("    override: %s = %d", key, classValue)
    end

    -- Write max benefit class overrides
    local mbOverrides = self.settingsData.maxBenefitClassOverrides or {}
    local mbCount = 0
    for _ in pairs(mbOverrides) do mbCount = mbCount + 1 end
    streamWriteUInt16(streamId, mbCount)
    for fillTypeName, classValue in pairs(mbOverrides) do
        streamWriteString(streamId, fillTypeName)
        streamWriteUInt8(streamId, classValue)
        Log:trace("    maxBenefit: %s = %d", fillTypeName, classValue)
    end

    -- Write customDefaults section (additive). Carries the server's
    -- modSettings overlay so client getters recompute identically (preset, tiers).
    self:writeCustomDefaults(streamId, self.settingsData.customDefaults)

    Log:debug("SETTINGS_SYNC_WRITE: %d global, %d fillTypes, %d overrides, %d maxBenefit",
        #globals, #fillTypes, overrideCount, mbCount)
end

--- Serialize the customDefaults overlay section.
--- Wire order MUST mirror readCustomDefaults exactly.
---@param streamId number Network stream ID
---@param cd table|nil customDefaults { global, fillTypes, maxBenefit, classMultipliers, storageAgingEnabled, hiddenCategoryNames }
function RmSettingsSyncEvent:writeCustomDefaults(streamId, cd)
    cd = cd or {}

    -- global: UInt8 count; per entry String name + typed value (1=Bool,2=Float32,3=String)
    local globals = {}
    for k, v in pairs(cd.global or {}) do
        table.insert(globals, { name = k, value = v })
    end
    streamWriteUInt8(streamId, #globals)
    for _, g in ipairs(globals) do
        streamWriteString(streamId, g.name)
        if type(g.value) == "boolean" then
            streamWriteUInt8(streamId, 1)
            streamWriteBool(streamId, g.value)
        elseif type(g.value) == "number" then
            streamWriteUInt8(streamId, 2)
            streamWriteFloat32(streamId, g.value)
        else
            streamWriteUInt8(streamId, 3)
            streamWriteString(streamId, tostring(g.value))
        end
    end

    -- fillTypes: UInt16 count; per entry String name, Bool isDoNotExpire,
    --   if not -> Float32 period; then Bool hidden
    local fillTypes = {}
    for name, config in pairs(cd.fillTypes or {}) do
        table.insert(fillTypes, { name = name, config = config })
    end
    streamWriteUInt16(streamId, #fillTypes)
    for _, ft in ipairs(fillTypes) do
        streamWriteString(streamId, ft.name)
        local isDoNotExpire = (ft.config.expires == false)
        streamWriteBool(streamId, isDoNotExpire)
        if not isDoNotExpire then
            streamWriteFloat32(streamId, ft.config.period or 0)
        end
        streamWriteBool(streamId, ft.config.hidden == true)
    end

    -- maxBenefit: UInt16 count; per entry String name + UInt8 classValue
    local maxBenefit = {}
    for name, classValue in pairs(cd.maxBenefit or {}) do
        table.insert(maxBenefit, { name = name, classValue = classValue })
    end
    streamWriteUInt16(streamId, #maxBenefit)
    for _, mb in ipairs(maxBenefit) do
        streamWriteString(streamId, mb.name)
        streamWriteUInt8(streamId, mb.classValue)
    end

    -- classMultipliers: UInt8 count; per entry UInt8 classValue + Float32 multiplier
    local classMults = {}
    for classValue, multiplier in pairs(cd.classMultipliers or {}) do
        table.insert(classMults, { classValue = classValue, multiplier = multiplier })
    end
    streamWriteUInt8(streamId, #classMults)
    for _, cm in ipairs(classMults) do
        streamWriteUInt8(streamId, cm.classValue)
        streamWriteFloat32(streamId, cm.multiplier)
    end

    -- storageAgingEnabled: UInt8 presence tag (0=unset, 1=false, 2=true)
    local agingTag = 0
    if cd.storageAgingEnabled == false then
        agingTag = 1
    elseif cd.storageAgingEnabled == true then
        agingTag = 2
    end
    streamWriteUInt8(streamId, agingTag)

    -- hiddenCategories: UInt8 count; per entry String categoryName
    local cats = {}
    for catName, _ in pairs(cd.hiddenCategoryNames or {}) do
        table.insert(cats, catName)
    end
    streamWriteUInt8(streamId, #cats)
    for _, catName in ipairs(cats) do
        streamWriteString(streamId, catName)
    end

    Log:trace("    customDefaults: %d global, %d fillTypes, %d maxBenefit, %d classMult, aging=%d, %d categories",
        #globals, #fillTypes, #maxBenefit, #classMults, agingTag, #cats)
end

--- Deserialize settings from network
---@param streamId number Network stream ID
---@param connection table Network connection
function RmSettingsSyncEvent:readStream(streamId, connection)
    Log:trace(">>> readStream()")
    self.settingsData = { global = {}, fillTypes = {} }

    -- Read global settings
    local globalCount = streamReadUInt8(streamId)
    for _ = 1, globalCount do
        local name = streamReadString(streamId)
        local valueType = streamReadUInt8(streamId)
        local value
        if valueType == 1 then
            value = streamReadBool(streamId)
            Log:trace("    global: %s = %s (bool)", name, tostring(value))
        elseif valueType == 2 then
            value = streamReadFloat32(streamId)
            Log:trace("    global: %s = %s (number)", name, tostring(value))
        else
            value = streamReadString(streamId)
            Log:trace("    global: %s = %s (string)", name, tostring(value))
        end
        self.settingsData.global[name] = value
    end

    -- Read fillType overrides
    local ftCount = streamReadUInt16(streamId)
    for _ = 1, ftCount do
        local name = streamReadString(streamId)
        local isDoNotExpire = streamReadBool(streamId)
        if isDoNotExpire then
            self.settingsData.fillTypes[name] = { expires = false }
            Log:trace("    fillType: %s = expires=false", name)
        else
            local period = streamReadFloat32(streamId)
            self.settingsData.fillTypes[name] = { period = period }
            Log:trace("    fillType: %s = period=%.2f", name, period)
        end
    end

    -- Read storage class overrides
    local overrideCount = streamReadUInt16(streamId)
    self.settingsData.storageClassOverrides = {}
    for _ = 1, overrideCount do
        local key = streamReadString(streamId)
        local classValue = streamReadUInt8(streamId)
        self.settingsData.storageClassOverrides[key] = classValue
        Log:trace("    override: %s = %d", key, classValue)
    end

    -- Read max benefit class overrides
    local mbCount = streamReadUInt16(streamId)
    self.settingsData.maxBenefitClassOverrides = {}
    for _ = 1, mbCount do
        local fillTypeName = streamReadString(streamId)
        local classValue = streamReadUInt8(streamId)
        self.settingsData.maxBenefitClassOverrides[fillTypeName] = classValue
        Log:trace("    maxBenefit: %s = %d", fillTypeName, classValue)
    end

    -- Read customDefaults section (additive; mirrors writeCustomDefaults order exactly)
    self.settingsData.customDefaults = self:readCustomDefaults(streamId)

    Log:debug("SETTINGS_SYNC_READ: %d global, %d fillTypes, %d overrides, %d maxBenefit",
        globalCount, ftCount, overrideCount, mbCount)
    self:run(connection)
end

--- Deserialize the customDefaults overlay section.
--- Read order MUST mirror writeCustomDefaults exactly.
---@param streamId number Network stream ID
---@return table customDefaults { global, fillTypes, maxBenefit, classMultipliers, storageAgingEnabled, hiddenCategoryNames }
function RmSettingsSyncEvent:readCustomDefaults(streamId)
    local cd = {
        global = {},
        fillTypes = {},
        maxBenefit = {},
        classMultipliers = {},
        storageAgingEnabled = nil,
        hiddenCategoryNames = {},
    }

    -- global
    local globalCount = streamReadUInt8(streamId)
    for _ = 1, globalCount do
        local name = streamReadString(streamId)
        local valueType = streamReadUInt8(streamId)
        local value
        if valueType == 1 then
            value = streamReadBool(streamId)
        elseif valueType == 2 then
            value = streamReadFloat32(streamId)
        else
            value = streamReadString(streamId)
        end
        cd.global[name] = value
    end

    -- fillTypes
    local ftCount = streamReadUInt16(streamId)
    for _ = 1, ftCount do
        local name = streamReadString(streamId)
        local isDoNotExpire = streamReadBool(streamId)
        local period = nil
        if not isDoNotExpire then
            period = streamReadFloat32(streamId)
        end
        local hidden = streamReadBool(streamId)
        if hidden then
            cd.fillTypes[name] = { expires = false, hidden = true }
        elseif isDoNotExpire then
            cd.fillTypes[name] = { expires = false }
        else
            cd.fillTypes[name] = { period = period }
        end
    end

    -- maxBenefit
    local mbCount = streamReadUInt16(streamId)
    for _ = 1, mbCount do
        local name = streamReadString(streamId)
        local classValue = streamReadUInt8(streamId)
        cd.maxBenefit[name] = classValue
    end

    -- classMultipliers
    local cmCount = streamReadUInt8(streamId)
    for _ = 1, cmCount do
        local classValue = streamReadUInt8(streamId)
        local multiplier = streamReadFloat32(streamId)
        cd.classMultipliers[classValue] = multiplier
    end

    -- storageAgingEnabled (presence tag: 0=unset, 1=false, 2=true)
    local agingTag = streamReadUInt8(streamId)
    if agingTag == 1 then
        cd.storageAgingEnabled = false
    elseif agingTag == 2 then
        cd.storageAgingEnabled = true
    end

    -- hiddenCategories
    local catCount = streamReadUInt8(streamId)
    for _ = 1, catCount do
        local catName = streamReadString(streamId)
        cd.hiddenCategoryNames[catName] = true
    end

    Log:trace("    customDefaults read: %d global, %d fillTypes, %d maxBenefit, %d classMult, aging=%d, %d categories",
        globalCount, ftCount, mbCount, cmCount, agingTag, catCount)
    return cd
end

-- =============================================================================
-- EXECUTION
-- =============================================================================

--- Apply settings on client
---@param connection table Network connection (unused)
function RmSettingsSyncEvent:run(connection)
    -- Only apply on client (server already has the data)
    if g_server ~= nil then
        Log:trace("    run() skipped (server)")
        return
    end

    if RmFreshSettings == nil then
        Log:warning("SETTINGS_SYNC_RUN: RmFreshSettings not available")
        return
    end

    local globalCount = 0
    local ftCount = 0
    for _ in pairs(self.settingsData.global or {}) do globalCount = globalCount + 1 end
    for _ in pairs(self.settingsData.fillTypes or {}) do ftCount = ftCount + 1 end

    -- SINGLE ordered apply pass: userOverrides -> customDefaults
    -- (incl. category name->index resolution + storageAgingEnabled) -> storage/maxBenefit
    -- override tables -> a single rebuildIndexCache at the end.
    -- Reset storageAgingEnabled to the bundled baseline FIRST so a sync that removes both the
    -- savegame override and the custom-default flag reverts correctly.
    RmFreshSettings.storageAgingEnabled = RmFreshSettings.bundledStorageAgingEnabled
    RmFreshSettings:setUserOverrides(self.settingsData)
    RmFreshSettings:setCustomDefaults(self.settingsData.customDefaults or {})
    RmFreshSettings:setAllStorageClassOverrides(self.settingsData.storageClassOverrides or {})
    RmFreshSettings:setAllMaxBenefitClassOverrides(self.settingsData.maxBenefitClassOverrides or {})

    -- Apply storageAgingEnabled from synced globals (direct property, not just userOverrides)
    -- Note: setCustomDefaults may have already applied a customDefaults storageAgingEnabled;
    -- a savegame global override (synced here) takes precedence and wins last.
    local syncedStorageAging = self.settingsData.global and self.settingsData.global["storageAgingEnabled"]
    if syncedStorageAging ~= nil then
        RmFreshSettings.storageAgingEnabled = syncedStorageAging
    end

    -- Rebuild index cache ONCE on client to reflect all applied tiers
    RmFreshSettings:rebuildIndexCache()

    local overrideCount = 0
    for _ in pairs(self.settingsData.storageClassOverrides or {}) do overrideCount = overrideCount + 1 end
    Log:info("SETTINGS_SYNC_RUN: Applied server settings (%d global, %d fillTypes, %d overrides)",
        globalCount, ftCount, overrideCount)

    -- Notify open Settings Frame to refresh UI after sync
    -- Uses displayedInstance (the currently visible frame) instead of primaryInstance
    if RmSettingsFrame ~= nil and RmSettingsFrame.displayedInstance ~= nil then
        RmSettingsFrame.displayedInstance:refreshData()
        RmSettingsFrame.displayedInstance:updateReadonlyState()
        Log:debug("SETTINGS_SYNC_RUN: Refreshed displayed Settings Frame (self=%s)",
            tostring(RmSettingsFrame.displayedInstance))
    end
end

-- =============================================================================
-- STATIC HELPER METHODS
-- =============================================================================

--- Build a FRESH outbound sync payload.
--- Does NOT mutate the table returned by getUserOverrides(): we copy its global/
--- fillTypes refs into a new table and attach the additive sections (storage /
--- maxBenefit / customDefaults) here. customDefaults rides as its OWN section and is
--- never merged into userOverrides.global/fillTypes, so it cannot reach the save path.
---@return table A new settingsData payload table
function RmSettingsSyncEvent.buildSyncPayload()
    local userOverrides = RmFreshSettings:getUserOverrides()
    return {
        global = userOverrides.global,
        fillTypes = userOverrides.fillTypes,
        storageClassOverrides = RmFreshSettings:getAllStorageClassOverrides(),
        maxBenefitClassOverrides = RmFreshSettings:getAllMaxBenefitClassOverrides(),
        customDefaults = RmFreshSettings:getCustomDefaults(),
    }
end

--- Send settings to a specific client (called on client join)
---@param connection table Network connection
function RmSettingsSyncEvent.sendToClient(connection)
    connection:sendEvent(RmSettingsSyncEvent.new(RmSettingsSyncEvent.buildSyncPayload()))
    Log:debug("SETTINGS_SYNC: Sent to client")
end

--- Broadcast settings to all connected clients (called on settings change)
function RmSettingsSyncEvent.broadcastToClients()
    if g_server then
        g_server:broadcastEvent(RmSettingsSyncEvent.new(RmSettingsSyncEvent.buildSyncPayload()))
        Log:debug("SETTINGS_SYNC: Broadcast to all clients")
    end
end
