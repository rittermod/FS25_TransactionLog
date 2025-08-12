RmUtils = {}
local RmUtils_mt = Class(RmUtils)

-- Module constants
RmUtils.DEBUG_ENABLED = false
RmUtils.TRACE_ENABLED = false
RmUtils.LOG_PREFIX = "[RmUtils]"

-- Log levels (higher numbers = more verbose)
RmUtils.LOG_LEVEL = {
    ERROR = 1,
    WARNING = 2,
    INFO = 3,
    DEBUG = 4,
    TRACE = 5
}

-- Current log level (default to INFO)
RmUtils.CURRENT_LOG_LEVEL = RmUtils.LOG_LEVEL.INFO

local function debugPrint(msg)
    print(string.format("  Debug: %s", msg))
end

local function tracePrint(msg)
    print(string.format("  Trace: %s", msg))
end

local function logCommon(logFunc, ...)
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if type(v) == "nil" then
            v = "(nil)"
        end
        if type(v) == "table" then
            local parts = {}
            for k, val in pairs(v) do
                if type(val) == "table" then
                    val = "(table)"
                end
                table.insert(parts, string.format("%s: %s", tostring(k), tostring(val)))
            end
            v = table.concat(parts, ", ")
        end
        logFunc(string.format("%s %s", RmUtils.LOG_PREFIX, tostring(v)))
    end
end

---Logs info messages
---@param ... any Values to log
function RmUtils.logInfo(...)
    if RmUtils.CURRENT_LOG_LEVEL >= RmUtils.LOG_LEVEL.INFO then
        logCommon(Logging.info, ...)
    end
end

---Logs warning messages
---@param ... any Values to log
function RmUtils.logWarning(...)
    if RmUtils.CURRENT_LOG_LEVEL >= RmUtils.LOG_LEVEL.WARNING then
        logCommon(Logging.warning, ...)
    end
end

---Logs error messages
---@param ... any Values to log
function RmUtils.logError(...)
    if RmUtils.CURRENT_LOG_LEVEL >= RmUtils.LOG_LEVEL.ERROR then
        logCommon(Logging.error, ...)
    end
end

---Logs debug messages if debug is enabled
---@param ... any Values to log
function RmUtils.logDebug(...)
    if RmUtils.CURRENT_LOG_LEVEL >= RmUtils.LOG_LEVEL.DEBUG then
        logCommon(debugPrint, ...)
    end
end

---Logs trace messages if trace is enabled
---@param ... any Values to log
function RmUtils.logTrace(...)
    if RmUtils.CURRENT_LOG_LEVEL >= RmUtils.LOG_LEVEL.TRACE then
        logCommon(tracePrint, ...)
    end
end

---Converts table to string representation with configurable depth
---@param tbl table Table to convert
---@param indent number|nil Current indentation level
---@param maxDepth number|nil Maximum depth to traverse
---@param initialIndent number|nil Initial indentation level
---@return string String representation of the table
function RmUtils.tableToString(tbl, indent, maxDepth, initialIndent)
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
            table.insert(result, RmUtils.tableToString(v, indent + 1, maxDepth, initialIndent))
        else
            table.insert(result, string.format("%s%s", formatting, tostring(v)))
        end
    end

    return table.concat(result, "\n")
end

---Converts function parameters to string representation
---@param ... any Function parameters to convert
---@return string String representation of parameters
function RmUtils.functionParametersToString(...)
    local args = { ... }
    local result = {}

    for i, v in ipairs(args) do
        table.insert(result, string.format("Parameter %d: (%s) %s", i, type(v), tostring(v)))
        if type(v) == "table" then
            table.insert(result, RmUtils.tableToString(v, 0, 2))
        end
    end

    return table.concat(result, "\n")
end

---Sets the log prefix for all logging functions
---@param prefix string|nil New log prefix (defaults to "[RmUtils]")
function RmUtils.setLogPrefix(prefix)
    RmUtils.LOG_PREFIX = prefix or "[RmUtils]"
end

---Sets the current log level
---@param level number|string Log level (use RmUtils.LOG_LEVEL constants or string names)
function RmUtils.setLogLevel(level)
    if type(level) == "string" then
        -- Convert string to log level constant
        local upperLevel = string.upper(level)
        if RmUtils.LOG_LEVEL[upperLevel] then
            RmUtils.CURRENT_LOG_LEVEL = RmUtils.LOG_LEVEL[upperLevel]
            -- Update legacy flags for backward compatibility
            RmUtils.DEBUG_ENABLED = RmUtils.CURRENT_LOG_LEVEL >= RmUtils.LOG_LEVEL.DEBUG
            RmUtils.TRACE_ENABLED = RmUtils.CURRENT_LOG_LEVEL >= RmUtils.LOG_LEVEL.TRACE
        else
            RmUtils.logError("Invalid log level string: %s. Valid levels: ERROR, WARNING, INFO, DEBUG, TRACE", level)
        end
    elseif type(level) == "number" then
        -- Validate numeric log level
        if level >= 1 and level <= 5 then
            RmUtils.CURRENT_LOG_LEVEL = level
            -- Update legacy flags for backward compatibility
            RmUtils.DEBUG_ENABLED = RmUtils.CURRENT_LOG_LEVEL >= RmUtils.LOG_LEVEL.DEBUG
            RmUtils.TRACE_ENABLED = RmUtils.CURRENT_LOG_LEVEL >= RmUtils.LOG_LEVEL.TRACE
        else
            RmUtils.logError("Invalid log level number: %s. Valid range: 1-5", tostring(level))
        end
    else
        RmUtils.logError("Invalid log level type: %s. Expected string or number", type(level))
    end
end

---Gets the current log level name
---@return string Current log level name
function RmUtils.getLogLevel()
    for name, value in pairs(RmUtils.LOG_LEVEL) do
        if value == RmUtils.CURRENT_LOG_LEVEL then
            return name
        end
    end
    return "UNKNOWN"
end
