--[[
    RmFreshMenu.lua
    Fresh mod menu controller extending TabbedMenu
]]

-- Keep existing module table, add metatable
RmFreshMenu = RmFreshMenu or {}
local RmFreshMenu_mt = Class(RmFreshMenu, TabbedMenu)

local Log = RmLogging.getLogger("Fresh")

-- Store mod directory at source time (g_currentModDirectory is only valid during source())
local modDirectory = g_currentModDirectory

-- Note: In FS25, controls are auto-linked from XML element IDs. No registerControls() needed.

function RmFreshMenu.new(target, custom_mt)
    local self = TabbedMenu.new(target, custom_mt or RmFreshMenu_mt)
    self.isOpen = false
    self.menuToggleActionEventId = nil -- For toggle-to-close feature
    return self
end

function RmFreshMenu.setupGui()
    -- 1. Load profiles first (use stored modDirectory, not g_currentModDirectory)
    g_gui:loadProfiles(Utils.getFilename("gui/guiProfiles.xml", modDirectory))

    -- 2. Register custom icon texture (must be before frame XML load so imageSliceId resolves)
    g_overlayManager:addTextureConfigFile(Utils.getFilename("gui/menu_icons.xml", modDirectory), "fresh")

    -- 3. Load frames (must be before menu XML for FrameReference resolution)
    RmOverviewFrame.setupGui()
    RmFillTypeDetailFrame.setupGui()
    RmStorageDetailFrame.setupGui()
    RmStatsFrame.setupGui()
    RmShelfLifeFrame.setupGui()
    RmSettingsFrame.setupGui()

    -- 4. Create menu instance
    g_freshMenu = RmFreshMenu.new()

    -- 5. Load menu XML
    g_gui:loadGui(
        Utils.getFilename("gui/freshMenu.xml", modDirectory),
        "FreshMenu",
        g_freshMenu,
        false -- false = full GUI, true = frame only
    )

    Log:debug("RmFreshMenu.setupGui() complete")
end

function RmFreshMenu:onGuiSetupFinished()
    RmFreshMenu:superClass().onGuiSetupFinished(self)
    self:setupMenuPages()
end

function RmFreshMenu:setupMenuPages()
    local basePredicate = function() return g_currentMission ~= nil end
    local expirationPredicate = function()
        return g_currentMission ~= nil and RmFreshSettings:getGlobal("enableExpiration") ~= false
    end

    -- Register Overview page (first tab - default on menu open)
    self:registerPage(self.overviewFrame, 1, expirationPredicate)
    self:addPageTab(self.overviewFrame, nil, nil, "fresh.icon_overview")

    -- Register FillType Detail page (second tab)
    self:registerPage(self.fillTypeDetailFrame, 2, expirationPredicate)
    self:addPageTab(self.fillTypeDetailFrame, nil, nil, "fresh.icon_product")

    -- Register Storage Detail page (third tab)
    self:registerPage(self.storageDetailFrame, 3, expirationPredicate)
    self:addPageTab(self.storageDetailFrame, nil, nil, "fresh.icon_storage")

    -- Register Statistics page (fourth tab)
    self:registerPage(self.statsFrame, 4, expirationPredicate)
    self:addPageTab(self.statsFrame, nil, nil, "fresh.icon_stats")

    -- Register Shelf Life page (fifth tab)
    self:registerPage(self.shelfLifeFrame, 5, expirationPredicate)
    self:addPageTab(self.shelfLifeFrame, nil, nil, "fresh.icon_shelflife")

    -- Register Settings page (sixth tab - always available)
    self:registerPage(self.settingsFrame, 6, basePredicate)
    self:addPageTab(self.settingsFrame, nil, nil, "fresh.icon_settings")

    Log:debug("Menu pages: overview (idx=1), fillTypeDetail (idx=2), storageDetail (idx=3), statistics (idx=4), shelfLife (idx=5), settings (idx=6)")
end

--- Update top-level page/tab visibility based on current settings
--- Called when enableExpiration changes while menu is open
function RmFreshMenu:updatePageVisibility()
    if not self.isOpen then return end

    self:updatePages()

    -- If current page was disabled, navigate to Settings
    if self.currentPage ~= nil then
        local stillEnabled = false
        for _, page in ipairs(self.enabledPages) do
            if page == self.currentPage then
                stillEnabled = true
                break
            end
        end
        if not stillEnabled then
            self:goToPage(self.settingsFrame, true)
        end
    end
end

function RmFreshMenu:setupMenuButtonInfo()
    RmFreshMenu:superClass().setupMenuButtonInfo(self)

    -- Set up back button callback for ESC key
    self.clickBackCallback = self:makeSelfCallback(self.onButtonBack)

    self.backButtonInfo = {
        inputAction = InputAction.MENU_BACK,
        text = g_i18n:getText("button_back"),
        callback = self.clickBackCallback
    }

    self.defaultMenuButtonInfo = { self.backButtonInfo }
    self.defaultMenuButtonInfoByActions[InputAction.MENU_BACK] = self.backButtonInfo
    self.defaultButtonActionCallbacks = {
        [InputAction.MENU_BACK] = self.clickBackCallback
    }
end

function RmFreshMenu:onButtonBack()
    self:exitMenu()
end

function RmFreshMenu:onOpen()
    RmFreshMenu:superClass().onOpen(self)
    self.isOpen = true

    -- Mark storage tab dirty so it repopulates with current building/vehicle list
    -- The instance's sc4Populated flag is reset here; populateStorageTab() runs in onFrameOpen
    RmSettingsFrame.sc4Dirty = true

    -- Register toggle action on the menu itself so keybinding works while menu is open
    local _, actionEventId = g_inputBinding:registerActionEvent(
        "RM_FRESH_MENU",
        self,
        self.onToggleAction,
        false, -- triggerUp
        true,  -- triggerDown
        false, -- triggerAlways
        true   -- startActive
    )

    if actionEventId then
        self.menuToggleActionEventId = actionEventId
        g_inputBinding:setActionEventTextVisibility(actionEventId, false)
        Log:debug("Menu opened, toggle action registered: %s", tostring(actionEventId))
    else
        Log:debug("Menu opened (toggle action not registered)")
    end
end

function RmFreshMenu:onClose()
    -- Remove toggle action before closing
    if self.menuToggleActionEventId then
        g_inputBinding:removeActionEvent(self.menuToggleActionEventId)
        self.menuToggleActionEventId = nil
        Log:debug("Menu toggle action removed")
    end

    RmFreshMenu:superClass().onClose(self)
    self.isOpen = false
    Log:debug("Menu closed")
end

--- Callback for toggle action while menu is open
function RmFreshMenu:onToggleAction()
    self:exitMenu()
end

function RmFreshMenu.open()
    if not g_gui:getIsGuiVisible() then
        g_gui:showGui("FreshMenu")
    end
end

function RmFreshMenu.toggle()
    if g_freshMenu and g_freshMenu.isOpen then
        g_freshMenu:exitMenu()
    else
        RmFreshMenu.open()
    end
end

-- =============================================================================
-- INPUT BINDING
-- =============================================================================

--- Register input action via PlayerInputComponent hook
-- This pattern is from FS25_NotificationLog - works reliably
function RmFreshMenu.addPlayerActionEvents(playerInputComponent, controlling)
    local triggerUp = false     -- Don't trigger on key up
    local triggerDown = true    -- Trigger on key down
    local triggerAlways = false -- Not continuous
    local startActive = true    -- Active from start
    local callbackState = nil
    local disableConflictingBindings = true

    local success, actionEventId = g_inputBinding:registerActionEvent(
        "RM_FRESH_MENU",
        RmFreshMenu,
        RmFreshMenu.toggle,
        triggerUp, triggerDown, triggerAlways, startActive,
        callbackState, disableConflictingBindings
    )

    if not success then
        if controlling == "VEHICLE" or (actionEventId ~= nil and actionEventId ~= "") then
            -- VEHICLE context returns false even on success (FS25 quirk)
            -- Non-empty actionEventId means duplicate registration (benign)
            Log:debug("RM_FRESH_MENU registration returned false (controlling=%s, eventId=%s)", tostring(controlling), tostring(actionEventId))
        else
            Log:debug("RM_FRESH_MENU action not registered (controlling=%s)", tostring(controlling))
        end
        return
    end

    -- Hide the action event text from HUD
    g_inputBinding:setActionEventTextVisibility(actionEventId, false)
    Log:debug("RM_FRESH_MENU action registered, eventId=%s", tostring(actionEventId))
end

--- Install hook into PlayerInputComponent
function RmFreshMenu.install()
    PlayerInputComponent.registerGlobalPlayerActionEvents = Utils.appendedFunction(
        PlayerInputComponent.registerGlobalPlayerActionEvents,
        RmFreshMenu.addPlayerActionEvents
    )
    Log:debug("RmFreshMenu.install() - PlayerInputComponent hook installed")
end
