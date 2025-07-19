RmDebugEnabled = true -- Set to true to enable debug logging
RmTraceEnabled = true -- Set to true to enable trace logging

RmLogPrefix = "[RM_TransactionLog] "

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
    if RmDebugEnabled then
        logCommon(debugPrint, ...)
    end
end

function logTrace(...)
    if RmTraceEnabled then
        logCommon(tracePrint, ...)
    end
end

function debugPrint(msg)
    print("  Debug: ".. msg )
end

function tracePrint(msg)
    print("  Trace: ".. msg )
end

function tableToString(tbl, indent, maxDepth, initialIndent)
    indent = indent or 0
    maxDepth = maxDepth or 2
    initialIndent = initialIndent or indent
    local result = {}
    
    if (indent - initialIndent) >= maxDepth then
        table.insert(result, string.rep("  ", indent) .. "...")
        return table.concat(result, "\n")
    end
    
    for k, v in pairs(tbl) do
        local formatting = string.rep("  ", indent) .. tostring(k) .. ": "
        if type(v) == "table" then
            table.insert(result, formatting)
            table.insert(result, tableToString(v, indent + 1, maxDepth, initialIndent))
        else
            table.insert(result, formatting .. tostring(v))
        end
    end
    
    return table.concat(result, "\n")
end

function functionParametersToString(...)
    local args = {...}
    local result = {}
    
    for i, v in ipairs(args) do
        table.insert(result, string.format("Parameter %d: (%s) %s", i, type(v), tostring(v)))
        if type(v) == "table" then
            table.insert(result, tableToString(v, 0, 2))
        end
    end
    
    return table.concat(result, "\n")
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
            local parts = {}
            -- Convert table top level to string for logging
            for k, val in pairs(v) do
                if type(val) == "table" then
                    val = "(table)"
                end
                table.insert(parts, tostring(k) .. ": " .. tostring(val))
            end
            v = table.concat(parts, ", ")
        end
        logFunc(RmLogPrefix .. tostring(v))
    end
end

