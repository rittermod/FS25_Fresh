-- main.lua
-- Purpose: Load mod dependencies in correct order
-- Author: Ritter
-- Architecture: Centralized FreshManager with adapters

local modName = g_currentModName
local modDirectory = g_currentModDirectory

-- =============================================================================
-- INFRASTRUCTURE
-- =============================================================================

source(modDirectory .. "scripts/rmlib/RmLogging.lua")
Log = RmLogging.getLogger("Fresh")
-- Log:setLevel(RmLogging.LOG_LEVEL.DEBUG)

-- =============================================================================
-- CORE MODULES
-- =============================================================================

source(modDirectory .. "scripts/core/RmBatch.lua")
source(modDirectory .. "scripts/core/RmFreshSettings.lua")
source(modDirectory .. "scripts/core/RmFreshManager.lua")
source(modDirectory .. "scripts/core/RmLossTracker.lua")
source(modDirectory .. "scripts/core/RmTransferCoordinator.lua")
source(modDirectory .. "scripts/core/RmFreshIO.lua")

-- =============================================================================
-- EVENTS
-- =============================================================================

source(modDirectory .. "scripts/events/RmFreshSyncEvent.lua")
source(modDirectory .. "scripts/events/RmFreshUpdateEvent.lua")
source(modDirectory .. "scripts/events/RmLossLogSyncEvent.lua")
source(modDirectory .. "scripts/events/RmFreshConsoleRequestEvent.lua")
source(modDirectory .. "scripts/events/RmFreshConsoleResponseEvent.lua")
source(modDirectory .. "scripts/events/RmStorageExpiringInfoEvent.lua")
source(modDirectory .. "scripts/events/RmFreshNotificationEvent.lua")
source(modDirectory .. "scripts/events/RmSettingsSyncEvent.lua")
source(modDirectory .. "scripts/events/RmSettingsChangeRequestEvent.lua")

-- =============================================================================
-- GUI
-- =============================================================================

source(modDirectory .. "scripts/gui/RmFreshMenu.lua")
source(modDirectory .. "scripts/gui/RmFreshInfoBox.lua")
source(modDirectory .. "scripts/gui/RmFreshAgeDisplay.lua")
source(modDirectory .. "scripts/gui/frames/RmOverviewFrame.lua")
source(modDirectory .. "scripts/gui/frames/RmStatsFrame.lua")
source(modDirectory .. "scripts/gui/frames/RmSettingsFrame.lua")

-- =============================================================================
-- ADAPTERS
-- =============================================================================

source(modDirectory .. "scripts/adapters/RmVehicleAdapter.lua")
source(modDirectory .. "scripts/adapters/RmBaleAdapter.lua")
source(modDirectory .. "scripts/adapters/RmPlaceableAdapter.lua")
source(modDirectory .. "scripts/adapters/RmHusbandryFoodAdapter.lua")
source(modDirectory .. "scripts/adapters/RmObjectStorageAdapter.lua")

-- =============================================================================
-- CONSOLE
-- =============================================================================

source(modDirectory .. "scripts/console/RmFreshConsole.lua")

-- =============================================================================
-- TESTING (conditional - delete tests/ folder for production)
-- =============================================================================

local testRunnerPath = modDirectory .. "scripts/tests/RmTestRunner.lua"
if fileExists(testRunnerPath) then
    source(testRunnerPath)
end


-- Get logger for specialization registration
local Log = RmLogging.getLogger("Fresh")

-- =============================================================================
-- LIFECYCLE HOOKS
-- =============================================================================

--- Hook ProductionChainManager for bulk transfer mode
--- Wraps distributeGoods() with beginBulkTransfer()/endBulkTransfer()
--- Enables age preservation during production chain auto-delivery
--- SERVER ONLY - production distribution is server-authoritative
local function installProductionChainHook()
    -- Server only
    if g_server == nil then return end

    -- Check ProductionChainManager exists
    if ProductionChainManager == nil or ProductionChainManager.distributeGoods == nil then
        Log:warning("ProductionChainManager.distributeGoods not found - bulk transfers won't preserve age")
        return
    end

    -- Hook distributeGoods with bulk transfer mode
    ProductionChainManager.distributeGoods = Utils.overwrittenFunction(
        ProductionChainManager.distributeGoods,
        function(manager, superFunc)
            Log:trace(">>> ProductionChainManager.distributeGoods (hooked)")
            RmFreshManager:beginBulkTransfer()
            superFunc(manager)
            RmFreshManager:endBulkTransfer()
            Log:trace("<<< ProductionChainManager.distributeGoods")
        end
    )
    Log:debug("ProductionChainManager.distributeGoods hooked for bulk transfers")
end

--- Lifecycle hook: called on map load
local function onLoadMapFinished()
    if g_currentMission == nil then
        Log:warning("onLoadMapFinished: g_currentMission is nil")
        return
    end

    -- Initialize settings (builds modDefaults from XML, includes perishableByIndex cache)
    RmFreshSettings:initialize(modDirectory)

    -- Install bale adapter hooks (after config, before Manager load)
    RmBaleAdapter.install()

    -- Get savegame directory for load/save operations
    local savegameDir = g_currentMission.missionInfo.savegameDirectory

    -- Load existing container data from savegame (if any)
    if savegameDir ~= nil then
        RmFreshManager:onLoad(savegameDir)
    end

    -- Initialize Manager (subscribe to HOUR_CHANGED)
    RmFreshManager:initialize()

    -- Install transfer hooks (after Manager, before console)
    RmTransferCoordinator.install()

    -- Install production chain hook for bulk transfers
    installProductionChainHook()

    -- Register console commands
    RmFreshConsole:registerCommands()

    -- Install Fresh menu keybind
    RmFreshMenu.install()

    -- Setup Fresh menu GUI
    RmFreshMenu.setupGui()

    -- Install age display HUD hooks
    RmFreshAgeDisplay.install()

    Log:info("Fresh initialized")
end

--- Lifecycle hook: called on savegame
local function onSaveGame()
    if g_currentMission == nil then return end
    if g_server == nil then return end -- Server only

    local savegameDir = g_currentMission.missionInfo.savegameDirectory
    if savegameDir == nil then
        Log:warning("onSaveGame: savegameDirectory is nil")
        return
    end

    RmFreshManager:onSave(savegameDir)
end

--- Lifecycle hook: called on map unload
local function onDeleteMap()
    -- Uninstall age display (remove drawable)
    RmFreshAgeDisplay.uninstall()

    -- Unregister console commands
    RmFreshConsole:unregisterCommands()

    -- Cleanup Manager (unsubscribe from HOUR_CHANGED)
    RmFreshManager:destroy()

    Log:info("Fresh cleanup complete")
end

--- Register lifecycle hooks
local function registerHooks()
    -- Hook map load
    BaseMission.loadMapFinished = Utils.appendedFunction(
        BaseMission.loadMapFinished,
        onLoadMapFinished
    )

    -- Hook save
    FSBaseMission.saveSavegame = Utils.appendedFunction(
        FSBaseMission.saveSavegame,
        onSaveGame
    )

    -- Hook map unload
    BaseMission.delete = Utils.prependedFunction(
        BaseMission.delete,
        onDeleteMap
    )

    -- Hook client join for full state sync
    FSBaseMission.sendInitialClientState = Utils.appendedFunction(
        FSBaseMission.sendInitialClientState,
        function(_baseMission, connection, _user, _farm)
            RmFreshManager:sendFullStateToClient(connection)
        end
    )

    Log:info("Lifecycle hooks registered")
end

-- =============================================================================
-- SPECIALIZATION REGISTRATION
-- =============================================================================

--- Inject RmVehicleAdapter into FillUnit vehicle types
local function validateVehicleTypes(typeManager)
    if typeManager.typeName ~= "vehicle" then
        return
    end

    local specName = modName .. ".rmVehicleAdapter"
    local numInserted = 0

    for vehicleName, vehicleType in pairs(g_vehicleTypeManager.types) do
        if SpecializationUtil.hasSpecialization(FillUnit, vehicleType.specializations) then
            g_vehicleTypeManager:addSpecialization(vehicleName, specName)
            numInserted = numInserted + 1
            Log:debug("Injected vehicle adapter: %s", vehicleName)
        end
    end

    if numInserted > 0 then
        Log:info("Injected vehicle adapter into %d vehicle types", numInserted)
    end
end

--- Inject RmPlaceableAdapter into storage-bearing placeable types
local function validatePlaceableTypes(typeManager)
    if typeManager.typeName ~= "placeable" then
        return
    end

    local specName = modName .. ".rmPlaceableAdapter"
    local numInserted = 0

    for placeableName, placeableType in pairs(g_placeableTypeManager.types) do
        -- Check for any storage-bearing specs (matches prerequisitesPresent)
        if SpecializationUtil.hasSpecialization(PlaceableSilo, placeableType.specializations)
            or SpecializationUtil.hasSpecialization(PlaceableSiloExtension, placeableType.specializations)
            or SpecializationUtil.hasSpecialization(PlaceableHusbandry, placeableType.specializations)
            or SpecializationUtil.hasSpecialization(PlaceableFactory, placeableType.specializations)
            or SpecializationUtil.hasSpecialization(PlaceableProductionPoint, placeableType.specializations) then
            g_placeableTypeManager:addSpecialization(placeableName, specName)
            numInserted = numInserted + 1
            Log:debug("Injected placeable adapter: %s", placeableName)
        end
    end

    if numInserted > 0 then
        Log:info("Injected placeable adapter into %d placeable types", numInserted)
    end
end

--- Inject RmHusbandryFoodAdapter into PlaceableHusbandryFood placeable types
--- NOTE: Coexists with PlaceableAdapter - husbandry buildings often have BOTH
---       general storage (spec_husbandry.storage) AND food storage (spec_husbandryFood.fillLevels)
local function validateHusbandryFoodTypes(typeManager)
    if typeManager.typeName ~= "placeable" then
        return
    end

    local specName = modName .. ".rmHusbandryFoodAdapter"
    local numInserted = 0

    for placeableName, placeableType in pairs(g_placeableTypeManager.types) do
        if SpecializationUtil.hasSpecialization(PlaceableHusbandryFood, placeableType.specializations) then
            g_placeableTypeManager:addSpecialization(placeableName, specName)
            numInserted = numInserted + 1
            Log:debug("Injected husbandry food adapter: %s", placeableName)
        end
    end

    if numInserted > 0 then
        Log:info("Injected husbandry food adapter into %d placeable types", numInserted)
    end
end

--- Inject RmObjectStorageAdapter into PlaceableObjectStorage placeable types
--- NOTE: Targets barns, sheds that store pallets/bales (PlaceableObjectStorage)
local function validateObjectStorageTypes(typeManager)
    if typeManager.typeName ~= "placeable" then
        return
    end

    local specName = modName .. ".rmObjectStorageAdapter"
    local numInserted = 0

    for placeableName, placeableType in pairs(g_placeableTypeManager.types) do
        if SpecializationUtil.hasSpecialization(PlaceableObjectStorage, placeableType.specializations) then
            g_placeableTypeManager:addSpecialization(placeableName, specName)
            numInserted = numInserted + 1
            Log:debug("Injected object storage adapter: %s", placeableName)
        end
    end

    if numInserted > 0 then
        Log:info("Injected object storage adapter into %d placeable types", numInserted)
    end
end

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

local function init()
    -- Register vehicle adapter specialization
    g_specializationManager:addSpecialization(
        "rmVehicleAdapter",
        "RmVehicleAdapter",
        Utils.getFilename("scripts/adapters/RmVehicleAdapter.lua", modDirectory),
        nil
    )
    Log:info("Vehicle adapter specialization registered")

    -- Register placeable adapter specialization
    -- NOTE: Placeables use g_placeableSpecializationManager, NOT g_specializationManager
    g_placeableSpecializationManager:addSpecialization(
        "rmPlaceableAdapter",
        "RmPlaceableAdapter",
        Utils.getFilename("scripts/adapters/RmPlaceableAdapter.lua", modDirectory),
        nil
    )
    Log:info("Placeable adapter specialization registered")

    -- Register husbandry food adapter specialization
    -- NOTE: Targets PlaceableHusbandryFood (food storage), NOT PlaceableHusbandry (general storage)
    g_placeableSpecializationManager:addSpecialization(
        "rmHusbandryFoodAdapter",
        "RmHusbandryFoodAdapter",
        Utils.getFilename("scripts/adapters/RmHusbandryFoodAdapter.lua", modDirectory),
        nil
    )
    Log:info("Husbandry Food adapter specialization registered")

    -- Register object storage adapter specialization
    -- NOTE: Targets PlaceableObjectStorage (barns, sheds that store pallets/bales)
    g_placeableSpecializationManager:addSpecialization(
        "rmObjectStorageAdapter",
        "RmObjectStorageAdapter",
        Utils.getFilename("scripts/adapters/RmObjectStorageAdapter.lua", modDirectory),
        nil
    )
    Log:info("Object Storage adapter specialization registered")

    -- Hook to inject vehicle adapter into FillUnit vehicle types
    TypeManager.validateTypes = Utils.appendedFunction(
        TypeManager.validateTypes,
        validateVehicleTypes
    )

    -- Hook to inject placeable adapter into storage-bearing placeable types
    TypeManager.validateTypes = Utils.appendedFunction(
        TypeManager.validateTypes,
        validatePlaceableTypes
    )

    -- Hook to inject husbandry food adapter into PlaceableHusbandryFood types
    TypeManager.validateTypes = Utils.appendedFunction(
        TypeManager.validateTypes,
        validateHusbandryFoodTypes
    )

    -- Hook to inject object storage adapter into PlaceableObjectStorage types
    TypeManager.validateTypes = Utils.appendedFunction(
        TypeManager.validateTypes,
        validateObjectStorageTypes
    )

    -- Register lifecycle hooks
    registerHooks()
end

init()
