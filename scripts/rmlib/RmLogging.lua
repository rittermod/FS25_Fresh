-- ============================================================================
-- RmLogging - Per-mod logging utility for Ritter Mods
-- ============================================================================
-- Usage:
--   local Log = RmLogging.getLogger("MyModName")
--   Log:info("Message with %s", "formatting")
--   Log:debug("Debug info")
--   Log:setLevel(RmLogging.LOG_LEVEL.DEBUG)
--
-- Features:
--   - Per-mod logger instances with independent log levels
--   - Auto-detected context suffix: [ModName|H] (Host), [ModName|C] (Client), [ModName|DS] (Dedicated)
--   - Console commands for runtime log level adjustment
--
-- Console commands:
--   rmShowLoglevel [name]          - Show log level(s)
--   rmSetLoglevel <name|*> <level> - Set log level
-- ============================================================================

-- Idempotent initialization (safe to source multiple times)
RmLogging = RmLogging or {}

-- Log level constants (preserve if already set)
RmLogging.LOG_LEVEL = RmLogging.LOG_LEVEL or {
    ERROR = 1,
    WARNING = 2,
    INFO = 3,
    DEBUG = 4,
    TRACE = 5
}

-- Registry of all logger instances (preserve across multiple sources)
RmLogging._loggers = RmLogging._loggers or {}

-- ============================================================================
-- RmLogger Class (per-mod instance)
-- ============================================================================

local RmLogger = {}
RmLogger.__index = RmLogger

---Create a new logger instance
---@param name string Logger name (typically mod name)
---@return table Logger instance
function RmLogger:new(name)
    local instance = setmetatable({}, RmLogger)
    instance.name = name
    instance.level = RmLogging.LOG_LEVEL.INFO
    instance._customPrefix = nil  -- Optional override, nil = use auto-generated
    return instance
end

---Get context suffix based on server/client state
---@return string Context suffix ("|H", "|C", "|DS", or "")
function RmLogger:_getContextSuffix()
    -- Check FS25 globals to determine execution context
    -- These are set during mission initialization
    if g_dedicatedServer ~= nil then
        return "|DS"  -- Dedicated Server
    elseif g_server ~= nil and g_client ~= nil then
        return "|H"   -- Host (Listen Server)
    elseif g_client ~= nil and g_server == nil then
        return "|C"   -- Client
    end
    return ""  -- Context not yet available (during mod loading)
end

---Build the log prefix dynamically
---@return string The prefix string (e.g., "[ModName|H]")
function RmLogger:_buildPrefix()
    if self._customPrefix then
        return self._customPrefix
    end
    return "[" .. self.name .. self:_getContextSuffix() .. "]"
end

---Set the log level for this logger
---@param level number|string Log level (RmLogging.LOG_LEVEL constant or string name)
function RmLogger:setLevel(level)
    if type(level) == "string" then
        local upperLevel = string.upper(level)
        if RmLogging.LOG_LEVEL[upperLevel] then
            self.level = RmLogging.LOG_LEVEL[upperLevel]
        else
            print(string.format("%s Invalid log level: %s", self:_buildPrefix(), level))
        end
    elseif type(level) == "number" and level >= 1 and level <= 5 then
        self.level = level
    else
        print(string.format("%s Invalid log level: %s", self:_buildPrefix(), tostring(level)))
    end
end

---Set a custom log prefix (optional override, clears auto-generation)
---@param prefix string|nil Custom prefix, or nil to restore auto-generation
function RmLogger:setPrefix(prefix)
    self._customPrefix = prefix
end

---Get the current log level name
---@return string Level name
function RmLogger:getLevelName()
    for name, value in pairs(RmLogging.LOG_LEVEL) do
        if value == self.level then
            return name
        end
    end
    return "UNKNOWN"
end

---Get the current context name for display
---@return string Context name ("Host", "Client", "Dedicated", or "")
function RmLogger:getContextName()
    if g_dedicatedServer ~= nil then
        return "Dedicated"
    elseif g_server ~= nil and g_client ~= nil then
        return "Host"
    elseif g_client ~= nil and g_server == nil then
        return "Client"
    end
    return ""
end

-- ============================================================================
-- Internal Logging Functions
-- ============================================================================

local function debugPrint(formatStr, ...)
    print(string.format("  Debug: " .. formatStr, ...))
end

local function tracePrint(formatStr, ...)
    print(string.format("  Trace: " .. formatStr, ...))
end

---Common logging implementation
---@param logFunc function The logging function to use
---@param prefix string The log prefix
---@param ... any Values to log
local function logCommon(logFunc, prefix, ...)
    local numArgs = select("#", ...)
    if numArgs == 0 then
        return
    end

    local firstArg = select(1, ...)

    if numArgs == 1 then
        local v = firstArg
        if type(v) == "nil" then
            v = "(nil)"
        elseif type(v) == "table" then
            local parts = {}
            for k, val in pairs(v) do
                if type(val) == "table" then
                    val = "(table)"
                end
                table.insert(parts, string.format("%s: %s", tostring(k), tostring(val)))
            end
            v = table.concat(parts, ", ")
        end
        logFunc(prefix .. " %s", tostring(v))
    else
        -- Multiple arguments - first is format string
        local success, message = pcall(string.format, firstArg, select(2, ...))
        if success then
            logFunc(prefix .. " %s", message)
        else
            -- Fallback if format fails
            logFunc(prefix .. " %s", tostring(firstArg))
        end
    end
end

-- ============================================================================
-- Logger Instance Methods
-- ============================================================================

---Log an info message
---@param ... any Message and format arguments
function RmLogger:info(...)
    if self.level >= RmLogging.LOG_LEVEL.INFO then
        logCommon(Logging.info, self:_buildPrefix(), ...)
    end
end

---Log a warning message
---@param ... any Message and format arguments
function RmLogger:warning(...)
    if self.level >= RmLogging.LOG_LEVEL.WARNING then
        logCommon(Logging.warning, self:_buildPrefix(), ...)
    end
end

---Log an error message
---@param ... any Message and format arguments
function RmLogger:error(...)
    if self.level >= RmLogging.LOG_LEVEL.ERROR then
        logCommon(Logging.error, self:_buildPrefix(), ...)
    end
end

---Log a debug message
---@param ... any Message and format arguments
function RmLogger:debug(...)
    if self.level >= RmLogging.LOG_LEVEL.DEBUG then
        logCommon(debugPrint, self:_buildPrefix(), ...)
    end
end

---Log a trace message
---@param ... any Message and format arguments
function RmLogger:trace(...)
    if self.level >= RmLogging.LOG_LEVEL.TRACE then
        logCommon(tracePrint, self:_buildPrefix(), ...)
    end
end

-- ============================================================================
-- Factory Method
-- ============================================================================

---Get or create a logger instance by name
---@param name string Logger name (typically mod name)
---@return table Logger instance
function RmLogging.getLogger(name)
    if not RmLogging._loggers[name] then
        RmLogging._loggers[name] = RmLogger:new(name)
    end
    return RmLogging._loggers[name]
end

-- ============================================================================
-- Utility Functions
-- ============================================================================

---Get level name from numeric value
---@param value number Level value
---@return string Level name
function RmLogging.getLevelNameByValue(value)
    for name, v in pairs(RmLogging.LOG_LEVEL) do
        if v == value then
            return name
        end
    end
    return "UNKNOWN"
end

---Convert table to string representation with configurable depth
---@param tbl table Table to convert
---@param indent number|nil Current indentation level
---@param maxDepth number|nil Maximum depth to traverse
---@param initialIndent number|nil Initial indentation level
---@return string String representation of the table
function RmLogging.tableToString(tbl, indent, maxDepth, initialIndent)
    indent = indent or 0
    maxDepth = maxDepth or 2
    initialIndent = initialIndent or indent
    local result = {}

    if (indent - initialIndent) >= maxDepth then
        table.insert(result, string.rep("  ", indent) .. "...")
        return table.concat(result, "\n")
    end

    for k, v in pairs(tbl) do
        local formatting = string.format("%s%s: ", string.rep("  ", indent), tostring(k))
        if type(v) == "table" then
            table.insert(result, formatting)
            table.insert(result, RmLogging.tableToString(v, indent + 1, maxDepth, initialIndent))
        else
            table.insert(result, string.format("%s%s", formatting, tostring(v)))
        end
    end

    return table.concat(result, "\n")
end

---Convert function parameters to string representation
---@param ... any Function parameters to convert
---@return string String representation of parameters
function RmLogging.functionParametersToString(...)
    local args = { ... }
    local result = {}

    for i, v in ipairs(args) do
        table.insert(result, string.format("Parameter %d: (%s) %s", i, type(v), tostring(v)))
        if type(v) == "table" then
            table.insert(result, RmLogging.tableToString(v, 0, 2))
        end
    end

    return table.concat(result, "\n")
end

-- ============================================================================
-- Console Commands
-- ============================================================================

---Console command: Show log level(s)
---@param nameArg string|nil Logger name or nil for all
---@return string Output for console
function RmLogging:consoleShowLogLevel(nameArg)
    if nameArg and nameArg ~= "" then
        local logger = self._loggers[nameArg]
        if logger then
            local ctx = logger:getContextName()
            local ctxStr = ctx ~= "" and (" [" .. ctx .. "]") or ""
            return string.format("%s: %s (%d)%s", nameArg, logger:getLevelName(), logger.level, ctxStr)
        end
        return string.format("Logger '%s' not found. Use rmShowLoglevel to see all.", nameArg)
    end

    -- Show all loggers
    if not next(self._loggers) then
        return "No loggers registered yet."
    end

    local lines = { "Registered loggers:" }
    -- Sort by name for consistent output
    local names = {}
    for name in pairs(self._loggers) do
        table.insert(names, name)
    end
    table.sort(names)

    for _, name in ipairs(names) do
        local logger = self._loggers[name]
        local ctx = logger:getContextName()
        local ctxStr = ctx ~= "" and (" [" .. ctx .. "]") or ""
        table.insert(lines, string.format("  %s: %s (%d)%s", name, logger:getLevelName(), logger.level, ctxStr))
    end
    table.insert(lines, "\nLevels: ERROR(1), WARNING(2), INFO(3), DEBUG(4), TRACE(5)")
    table.insert(lines, "Context: H=Host, C=Client, DS=Dedicated Server")
    return table.concat(lines, "\n")
end

---Console command: Set log level
---@param nameArg string Logger name or "*" for all
---@param levelArg string Level name or number
---@return string Output for console
function RmLogging:consoleSetLogLevel(nameArg, levelArg)
    if not nameArg or nameArg == "" then
        return "Usage: rmSetLoglevel <name|*> <level>\nUse rmShowLoglevel to see registered loggers."
    end

    if not levelArg or levelArg == "" then
        return "Usage: rmSetLoglevel " .. nameArg .. " <level>\nLevels: ERROR, WARNING, INFO, DEBUG, TRACE (or 1-5)"
    end

    -- Parse level
    local newLevel = tonumber(levelArg)
    if not newLevel then
        newLevel = self.LOG_LEVEL[string.upper(levelArg)]
    end
    if not newLevel or newLevel < 1 or newLevel > 5 then
        return string.format("Invalid level '%s'. Valid: ERROR, WARNING, INFO, DEBUG, TRACE (or 1-5)", levelArg)
    end

    -- Apply to all or specific
    if nameArg == "*" then
        local count = 0
        for _, logger in pairs(self._loggers) do
            logger.level = newLevel
            count = count + 1
        end
        if count == 0 then
            return "No loggers registered yet."
        end
        local levelName = self.getLevelNameByValue(newLevel)
        return string.format("All %d logger(s) set to %s (%d)", count, levelName, newLevel)
    else
        local logger = self._loggers[nameArg]
        if not logger then
            return string.format("Logger '%s' not found. Use rmShowLoglevel to see all.", nameArg)
        end
        local oldLevel = logger:getLevelName()
        logger.level = newLevel
        return string.format("%s: %s -> %s", nameArg, oldLevel, logger:getLevelName())
    end
end

-- ============================================================================
-- Console Command Registration
-- ============================================================================

---Register console commands (call this from mission start hook)
---Safe to call multiple times - will only register once
function RmLogging.registerConsoleCommands()
    if RmLogging._consoleCommandsRegistered then
        return
    end

    addConsoleCommand("rmShowLoglevel", "Shows RmLogging levels: rmShowLoglevel [name]", "consoleShowLogLevel", RmLogging)
    addConsoleCommand("rmSetLoglevel", "Sets log level: rmSetLoglevel <name|*> <level>", "consoleSetLogLevel", RmLogging)
    RmLogging._consoleCommandsRegistered = true
end

---Unregister console commands (call this from mission delete hook)
function RmLogging.unregisterConsoleCommands()
    if not RmLogging._consoleCommandsRegistered then
        return
    end

    removeConsoleCommand("rmShowLoglevel")
    removeConsoleCommand("rmSetLoglevel")
    RmLogging._consoleCommandsRegistered = false
end
