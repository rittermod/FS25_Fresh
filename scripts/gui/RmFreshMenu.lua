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

-- Note: In FS25, controls are automatically exposed from XML element IDs.
-- No need to call registerControls() - this is handled by g_gui:loadGui()

function RmFreshMenu.new(target, custom_mt)
    Log:trace("RmFreshMenu.new()")
    local self = TabbedMenu.new(target, custom_mt or RmFreshMenu_mt)
    self.isOpen = false
    self.menuToggleActionEventId = nil -- For toggle-to-close feature
    return self
end

function RmFreshMenu.setupGui()
    -- 1. Load profiles first (use stored modDirectory, not g_currentModDirectory)
    g_gui:loadProfiles(Utils.getFilename("gui/guiProfiles.xml", modDirectory))

    -- 2. Load frames (must be before menu XML for FrameReference resolution)
    RmOverviewFrame.setupGui()
    RmStatsFrame.setupGui()
    RmSettingsFrame.setupGui()

    -- 3. Create menu instance
    g_freshMenu = RmFreshMenu.new()

    -- 4. Load menu XML
    g_gui:loadGui(
        Utils.getFilename("gui/freshMenu.xml", modDirectory),
        "FreshMenu",
        g_freshMenu,
        false -- false = full GUI, true = frame only
    )

    Log:debug("RmFreshMenu.setupGui() complete")
end

function RmFreshMenu:onGuiSetupFinished()
    Log:trace("RmFreshMenu:onGuiSetupFinished()")
    RmFreshMenu:superClass().onGuiSetupFinished(self)
    self:setupMenuPages()
end

function RmFreshMenu:setupMenuPages()
    Log:trace(">>> RmFreshMenu:setupMenuPages()")
    local predicate = function() return g_currentMission ~= nil end

    -- Register Overview page (first tab - default on menu open)
    self:registerPage(self.overviewFrame, 1, predicate)
    self:addPageTab(self.overviewFrame, nil, nil, "gui.icon_ingameMenu_calendar")

    -- Register Statistics page (second tab)
    self:registerPage(self.statsFrame, 2, predicate)
    self:addPageTab(self.statsFrame, nil, nil, "gui.icon_ingameMenu_finances")

    -- Register Settings page (third tab)
    self:registerPage(self.settingsFrame, 3, predicate)
    self:addPageTab(self.settingsFrame, nil, nil, "gui.icon_options_generalSettings2")

    Log:debug("Menu pages: overview (idx=1), statistics (idx=2), settings (idx=3)")
    Log:trace("<<< RmFreshMenu:setupMenuPages()")
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
    Log:trace("RmFreshMenu:onToggleAction() - closing menu via keybinding")
    self:exitMenu()
end

function RmFreshMenu.open()
    if not g_gui:getIsGuiVisible() then
        g_gui:showGui("FreshMenu")
    end
end

function RmFreshMenu.toggle()
    Log:trace("RmFreshMenu.toggle() isOpen=%s", tostring(g_freshMenu and g_freshMenu.isOpen))

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

    if success then
        g_inputBinding:setActionEventTextVisibility(actionEventId, false)
        Log:debug("RM_FRESH_MENU action registered, eventId=%s", tostring(actionEventId))
    else
        Log:error("Failed to register RM_FRESH_MENU action")
    end
end

--- Install hook into PlayerInputComponent
function RmFreshMenu.install()
    PlayerInputComponent.registerGlobalPlayerActionEvents = Utils.appendedFunction(
        PlayerInputComponent.registerGlobalPlayerActionEvents,
        RmFreshMenu.addPlayerActionEvents
    )
    Log:debug("RmFreshMenu.install() - PlayerInputComponent hook installed")
end
