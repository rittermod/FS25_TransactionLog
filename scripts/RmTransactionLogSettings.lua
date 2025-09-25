-- RmTransactionLogSettings.lua
-- Settings management system for FS25 Transaction Log mod
-- Author: Ritter
-- Description: Handles all settings persistence, validation, and management

RmTransactionLogSettings = {}
local RmTransactionLogSettings_mt = Class(RmTransactionLogSettings)

-- Settings definitions
RmTransactionLogSettings.DEFINITIONS = {
    autoExportFrequency = {
        ['default'] = 1,             -- Index for "Off" (0-based values, 1-based index)
        ['values'] = { 0, 1, 2, 3 }, -- Off, Daily, Monthly, Yearly
        ['strings'] = {
            g_i18n:getText("ui_off"),
            g_i18n:getText("setting_transactionlog_autoExport_daily"),
            g_i18n:getText("setting_transactionlog_autoExport_monthly"),
            g_i18n:getText("setting_transactionlog_autoExport_yearly")
        }
    }
}

RmTransactionLogSettings.MENU_ITEMS = {
    'autoExportFrequency',
}

---Creates a new RmTransactionLogSettings instance
---@return table the new settings instance
function RmTransactionLogSettings.new()
    local self = setmetatable({}, RmTransactionLogSettings_mt)

    -- Initialize default values from definitions
    for key, setting in pairs(RmTransactionLogSettings.DEFINITIONS) do
        local defaultIndex = setting.default or 1
        self[key] = setting.values[defaultIndex]
    end

    return self
end

---Sets a setting value with validation
---@param id string setting identifier
---@param value any value to set
---@return boolean success true if value was set successfully
function RmTransactionLogSettings:setValue(id, value)
    -- Parameter validation
    if id == nil then
        RmLogging.logWarning("setValue called with nil id")
        return false
    end
    if value == nil then
        RmLogging.logWarning("setValue called with nil value for setting: " .. tostring(id))
        return false
    end

    -- Validate setting exists
    if not RmTransactionLogSettings.DEFINITIONS[id] then
        RmLogging.logError("Unknown setting ID: " .. tostring(id))
        return false
    end

    -- Validate value is in allowed range
    local setting = RmTransactionLogSettings.DEFINITIONS[id]
    local isValidValue = false

    for _, allowedValue in ipairs(setting.values) do
        if value == allowedValue then
            isValidValue = true
            break
        end
    end

    if not isValidValue then
        RmLogging.logError("Invalid value " .. tostring(value) .. " for setting " .. id)
        return false
    end

    self[id] = value
    RmLogging.logDebug("Setting " .. id .. " set to: " .. tostring(value))
    return true
end

---Gets a setting value
---@param id string setting identifier
---@return any the setting value
function RmTransactionLogSettings:getValue(id)
    if id == nil then
        RmLogging.logWarning("getValue called with nil id")
        return nil
    end

    if not RmTransactionLogSettings.DEFINITIONS[id] then
        RmLogging.logWarning("Unknown setting ID in getValue: " .. tostring(id))
        return nil
    end

    return self[id]
end

---Gets the UI state index for a setting value
---@param id string setting identifier
---@param inputValue any optional value to check instead of current value
---@return number the state index (1-based)
function RmTransactionLogSettings:getStateIndex(id, inputValue)
    -- Parameter validation
    if id == nil then
        RmLogging.logWarning("getStateIndex called with nil id")
        return 1
    end

    -- Validate setting exists
    if not RmTransactionLogSettings.DEFINITIONS[id] then
        RmLogging.logError("Unknown setting ID in getStateIndex: " .. tostring(id))
        return 1
    end

    local setting = RmTransactionLogSettings.DEFINITIONS[id]
    if not setting.values or #setting.values == 0 then
        RmLogging.logError("Setting " .. id .. " has no valid values")
        return 1
    end

    local value = inputValue or self:getValue(id)
    local values = setting.values

    if type(value) == 'number' then
        local index = setting.default or 1
        local initialdiff = math.huge
        for i, v in pairs(values) do
            if type(v) == 'number' then
                local currentdiff = math.abs(v - value)
                if currentdiff < initialdiff then
                    initialdiff = currentdiff
                    index = i
                end
            end
        end
        return index
    else
        for i, v in pairs(values) do
            if value == v then
                return i
            end
        end
    end

    RmLogging.logWarning(id .. " using default index")
    return setting.default or 1
end

---Writes all settings to XML file
function RmTransactionLogSettings:writeSettings()
    local key = "transactionLogSettings"
    local userSettingsFile = Utils.getFilename("FS25_TransactionLog.xml",
        g_modSettingsDirectory .. "/FS25_TransactionLog")

    local xmlFile = createXMLFile("settings", userSettingsFile, key)
    if xmlFile ~= 0 then
        local function setXmlValue(id)
            if not id or not RmTransactionLogSettings.DEFINITIONS[id] then
                RmLogging.logWarning("Skipping invalid setting ID: " .. tostring(id))
                return
            end

            local xmlValueKey = "transactionLogSettings." .. id .. "#value"
            local value = self:getValue(id)
            if type(value) == 'number' then
                setXMLFloat(xmlFile, xmlValueKey, value)
            elseif type(value) == 'boolean' then
                setXMLBool(xmlFile, xmlValueKey, value)
            else
                RmLogging.logWarning("Unsupported setting type for " .. id .. ": " .. type(value))
            end
        end

        for _, id in pairs(RmTransactionLogSettings.MENU_ITEMS) do
            setXmlValue(id)
        end

        saveXMLFile(xmlFile)
        delete(xmlFile)
        RmLogging.logInfo("Settings saved to " .. userSettingsFile)
    else
        RmLogging.logError("Failed to create settings file: " .. userSettingsFile)
    end
end

---Reads settings from XML file
function RmTransactionLogSettings:readSettings()
    local userSettingsFile = Utils.getFilename("FS25_TransactionLog.xml",
        g_modSettingsDirectory .. "/FS25_TransactionLog")

    if not fileExists(userSettingsFile) then
        RmLogging.logInfo("Creating default settings file: " .. userSettingsFile)
        self:writeSettings()
        return
    end

    local xmlFile = loadXMLFile("transactionLogSettings", userSettingsFile)
    if xmlFile ~= 0 then
        local function getXmlValue(id)
            local setting = RmTransactionLogSettings.DEFINITIONS[id]
            if not setting then
                RmLogging.logWarning("Unknown setting in XML file: " .. tostring(id))
                return "MISSING"
            end

            local xmlValueKey = "transactionLogSettings." .. id .. "#value"
            local currentValue = self:getValue(id)
            local valueString = tostring(currentValue)

            if hasXMLProperty(xmlFile, xmlValueKey) then
                if type(currentValue) == 'number' then
                    local xmlValue = getXMLFloat(xmlFile, xmlValueKey)
                    if xmlValue ~= nil then
                        if self:setValue(id, xmlValue) then
                            if xmlValue == math.floor(xmlValue) then
                                valueString = tostring(xmlValue)
                            else
                                valueString = string.format("%.3f", xmlValue)
                            end
                        end
                    end
                elseif type(currentValue) == 'boolean' then
                    local xmlValue = getXMLBool(xmlFile, xmlValueKey)
                    if xmlValue ~= nil then
                        if self:setValue(id, xmlValue) then
                            valueString = tostring(xmlValue)
                        end
                    end
                end
                return valueString
            end
            return "DEFAULT"
        end

        RmLogging.logInfo("Loading Transaction Log settings:")
        for _, id in pairs(RmTransactionLogSettings.MENU_ITEMS) do
            local valueString = getXmlValue(id)
            RmLogging.logInfo("  " .. id .. ": " .. valueString)
        end

        delete(xmlFile)
    else
        RmLogging.logError("Failed to load settings file: " .. userSettingsFile)
    end
end
