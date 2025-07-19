local debugEnabled = false -- Set to true to enable debug logging
local logPrefix = "[RM_TransactionLog] "

function logInfo(...)
    logCommon(Logging.info, ...)
end

function logWarning(...)
    logCommon(Logging.warning, ...)
end

function logError(...)
    logCommon(Logging.error, ...)
end

function logDebug(...)
    if debugEnabled then
        logCommon(debugPrint, ...)
    end
end

function debugPrint(msg)
    if debugEnabled then
        print("  Debug: ".. msg )
    end
end

function logTable(tbl, indent, maxDepth, initialIndent)
    indent = indent or 0
    maxDepth = maxDepth or 2
    initialIndent = initialIndent or indent
    if (indent - initialIndent) >= maxDepth then
        print(string.rep("  ", indent) .. "...")
        return
    end
    for k, v in pairs(tbl) do
        local formatting = string.rep("  ", indent) .. tostring(k) .. ": "
        if type(v) == "table" then
            print(formatting)
            logTable(v, indent + 1, maxDepth, initialIndent)
        else
            logDebug(formatting .. tostring(v))
        end
    end
end

function logFunctionParameters(...)
    local args = {...}
    for i, v in ipairs(args) do
        logDebug(string.format("Parameter %d: (%s) %s", i, type(v), tostring(v)))
        if type(v) == "table" then
            logTable(v, 2)
        end
    end
end


function logCommon(logFunc, ...)
    for i = 1, select("#", ...) do
        -- Iterate over all arguments, using select to handle variable number of arguments
        -- ipairs and pairs do not work well with nil values, so we use select
        local v = select(i, ...)
        if type(v) == "nil" then
            v = "(nil)"
        end
        if type(v) == "table" then
            local str = ""
            -- Convert table top level to string for logging
            for k, val in pairs(v) do
                if type(val) == "table" then
                    val = "(table)"
                end
                str = str .. tostring(k) .. ": " .. tostring(val) .. ", "
            end
            v = str:sub(1, -3)
        end
        logFunc(logPrefix .. tostring(v))
    end
end

