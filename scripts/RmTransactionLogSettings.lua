-- RmTransactionLogSettings.lua
-- Settings management system for FS25 Transaction Log mod
-- Author: Ritter
-- Description: Handles all settings persistence, validation, and management

RmTransactionLogSettings = {}
local RmTransactionLogSettings_mt = Class(RmTransactionLogSettings)
local Log = RmLogging.getLogger("TransactionLog")

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
        Log:warning("setValue called with nil id")
        return false
    end
    if value == nil then
        Log:warning("setValue called with nil value for setting: " .. tostring(id))
        return false
    end

    -- Validate setting exists
    if not RmTransactionLogSettings.DEFINITIONS[id] then
        Log:error("Unknown setting ID: " .. tostring(id))
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
        Log:error("Invalid value " .. tostring(value) .. " for setting " .. id)
        return false
    end

    self[id] = value
    Log:debug("Setting " .. id .. " set to: " .. tostring(value))
    return true
end

---Applies a setting value received from the server's authoritative broadcast (TL-14 client path).
---Validates + sets via setValue but NEVER persists: writeSettings is server-only (its own g_server
---guard makes a client call a no-op), and a client must not write the server's file. This is an
---intent-revealing wrapper so the client apply path (RmTransactionLog.applySettingFromNetwork) reads
---as a network apply, not a local edit.
---@param id string setting identifier
---@param value any value to set (an integer enum code on the wire)
---@return boolean success the setValue result (false if id unknown / value out of range)
function RmTransactionLogSettings:applyFromNetwork(id, value)
    return self:setValue(id, value)
end

---Gets a setting value
---@param id string setting identifier
---@return any the setting value
function RmTransactionLogSettings:getValue(id)
    if id == nil then
        Log:warning("getValue called with nil id")
        return nil
    end

    if not RmTransactionLogSettings.DEFINITIONS[id] then
        Log:warning("Unknown setting ID in getValue: " .. tostring(id))
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
        Log:warning("getStateIndex called with nil id")
        return 1
    end

    -- Validate setting exists
    if not RmTransactionLogSettings.DEFINITIONS[id] then
        Log:error("Unknown setting ID in getStateIndex: " .. tostring(id))
        return 1
    end

    local setting = RmTransactionLogSettings.DEFINITIONS[id]
    if not setting.values or #setting.values == 0 then
        Log:error("Setting " .. id .. " has no valid values")
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

    Log:warning(id .. " using default index")
    return setting.default or 1
end

-- =============================================================================
-- SETTINGS-FILE PATH RESOLUTION + ONE-TIME LOAD MIGRATION (TL-34)
-- The settings file was historically written to
--   modSettings/FS25_TransactionLogFS25_TransactionLog.xml   (mod name DOUBLED)
-- because Utils.getFilename concatenates baseDir .. filename with NO separator and the base string
-- lacked a trailing slash. These pure helpers resolve BOTH the correct nested path
-- and the byte-faithful legacy path so writeSettings/readSettings share ONE source of truth (they
-- can never diverge again), and readSettings can run a one-time migration that relocates an orphaned
-- legacy file - deleting the old copy ONLY after the new one is proven loadable, so no user's
-- settings are ever lost. They are RmTransactionLogSettings.* module functions (not file-locals) so
-- RmSettingsPathTests can drive them directly.
-- =============================================================================

---Resolves the settings-file paths from the mod-settings directory. PURE (Utils.getFilename is
---string-only, no disk access). The legacy path reproduces the EXACT pre-fix expression so an
---orphaned doubled-name file is detected byte-for-byte.
---@param dir string|nil g_modSettingsDirectory (nil on a headless / early-load edge)
---@return string|nil newPath nested correct path (.../FS25_TransactionLog/FS25_TransactionLog.xml); nil if dir is nil
---@return string|nil legacyPath doubled-name path (.../FS25_TransactionLogFS25_TransactionLog.xml); nil if dir is nil
function RmTransactionLogSettings.resolveSettingsPaths(dir)
    if dir == nil then
        return nil, nil
    end
    local base = dir .. "/FS25_TransactionLog"
    -- Trailing slash -> Utils.getFilename returns base.."/"..filename (correct nested file).
    local newPath = Utils.getFilename("FS25_TransactionLog.xml", base .. "/")
    -- No trailing slash -> the original bug: base..filename fuses folder and filename.
    local legacyPath = Utils.getFilename("FS25_TransactionLog.xml", base)
    return newPath, legacyPath
end

---Whether the one-time relocation should run: only when the correct nested file is ABSENT but a
---doubled-name legacy file EXISTS. PURE. Once the new file exists this is false forever (the
---migration is self-limiting).
---@param newExists boolean does the nested correct file exist
---@param legacyExists boolean does the doubled-name legacy file exist
---@return boolean
function RmTransactionLogSettings.shouldMigrate(newExists, legacyExists)
    return (not newExists) and legacyExists
end

---Chooses which file to read and whether the legacy copy is now safe to delete. PURE. Deletes
---legacy ONLY when the new file is proven loadable, so a corrupt/failed copy never destroys the good
---legacy settings; a missing/unreadable new file falls back to reading legacy in place and KEEPS it.
---@param newReadable boolean is the nested file present AND loadable (isXmlLoadable)
---@param legacyExists boolean does the doubled-name legacy file exist
---@return table plan { read = "new"|"legacy"|"default", deleteLegacy = boolean }
function RmTransactionLogSettings.chooseReadPlan(newReadable, legacyExists)
    if newReadable then
        return { read = "new", deleteLegacy = legacyExists }
    elseif legacyExists then
        return { read = "legacy", deleteLegacy = false }
    else
        return { read = "default", deleteLegacy = false }
    end
end

---Whether an XML file exists AND parses. Engine I/O (NOT pure): loadXMLFile returns 0 on a missing /
---0-byte / corrupt file; a non-zero handle is deleted immediately. This is the gate that guarantees a
---legacy file is never deleted in favour of an unreadable new copy.
---@param path string|nil
---@return boolean loadable
function RmTransactionLogSettings.isXmlLoadable(path)
    if path == nil then
        return false
    end
    if not fileExists(path) then
        return false
    end
    local handle = loadXMLFile("transactionLogSettings", path)
    if handle == 0 then
        return false
    end
    delete(handle)
    return true
end

---Collapses duplicate slashes so a delete inside modSettings is accepted. A mod may only delete files
---under its own modSettings folder, and that path check compares the path as-is - it does NOT collapse
---a doubled slash. `g_modSettingsDirectory` ends in "/", so `resolveSettingsPaths` paths carry a
---harmless `//` (the filesystem collapses it for read/write/copy), but the delete is REFUSED for a path
---that still contains the `//`, even though it names a real file. Collapse the `//` first. PURE
---(string-only).
---@param path string|nil
---@return string|nil
function RmTransactionLogSettings.toDeletablePath(path)
    if path == nil then
        return nil
    end
    return (path:gsub("//+", "/"))
end

---Writes all settings to XML file
function RmTransactionLogSettings:writeSettings()
    -- Server-authority guard: settings persistence is server-side; a client no-ops.
    if g_server == nil then return end
    local key = "transactionLogSettings"
    local userSettingsFile = RmTransactionLogSettings.resolveSettingsPaths(g_modSettingsDirectory)
    if userSettingsFile == nil then
        Log:warning("Cannot write settings: g_modSettingsDirectory is nil")
        return
    end

    local xmlFile = createXMLFile("settings", userSettingsFile, key)
    if xmlFile ~= 0 then
        local function setXmlValue(id)
            if not id or not RmTransactionLogSettings.DEFINITIONS[id] then
                Log:warning("Skipping invalid setting ID: " .. tostring(id))
                return
            end

            local xmlValueKey = "transactionLogSettings." .. id .. "#value"
            local value = self:getValue(id)
            if type(value) == 'number' then
                setXMLFloat(xmlFile, xmlValueKey, value)
            elseif type(value) == 'boolean' then
                setXMLBool(xmlFile, xmlValueKey, value)
            else
                Log:warning("Unsupported setting type for " .. id .. ": " .. type(value))
            end
        end

        for _, id in pairs(RmTransactionLogSettings.MENU_ITEMS) do
            setXmlValue(id)
        end

        saveXMLFile(xmlFile)
        delete(xmlFile)
        Log:info("Settings saved to " .. userSettingsFile)
    else
        Log:error("Failed to create settings file: " .. userSettingsFile)
    end
end

---Reads settings from XML file
function RmTransactionLogSettings:readSettings()
    -- Server-authority guard: settings persistence is server-side; a client no-ops.
    if g_server == nil then return end

    local newPath, legacyPath = RmTransactionLogSettings.resolveSettingsPaths(g_modSettingsDirectory)
    if newPath == nil then
        Log:warning("Cannot read settings: g_modSettingsDirectory is nil")
        return
    end

    -- One-time load migration (TL-34): if only the doubled-name legacy file exists, copy it into the
    -- correct nested path. overwrite=true is harmless here - shouldMigrate already proved new is absent.
    -- Precondition: RmTransactionLog.loadMap createFolders the nested dir immediately before calling
    -- readSettings, so the copy destination exists; a copy that still fails falls back to reading the
    -- legacy file in place (no data loss).
    local didMigrate = RmTransactionLogSettings.shouldMigrate(fileExists(newPath), fileExists(legacyPath))
    if didMigrate then
        copyFile(legacyPath, newPath, true)
    end

    -- Decide what to read and whether the legacy copy is now safe to remove. Judge success by the
    -- post-op state (loadable + fileExists), never the native copy/delete return. Legacy is deleted
    -- ONLY when the new file is proven loadable, so a failed/corrupt copy leaves the good legacy intact.
    local newReadable = RmTransactionLogSettings.isXmlLoadable(newPath)
    local plan = RmTransactionLogSettings.chooseReadPlan(newReadable, fileExists(legacyPath))

    if plan.deleteLegacy then
        -- Normalise "//" before the delete: the modSettings delete restriction refuses a path that
        -- still contains the doubled slash, even though it names a real file (see toDeletablePath). A
        -- refused/failed delete is non-fatal - the correct nested file is already written and read.
        local deletablePath = RmTransactionLogSettings.toDeletablePath(legacyPath)
        deleteFile(deletablePath)
        if fileExists(deletablePath) then
            Log:warning("Could not remove legacy settings file: " .. deletablePath)
        elseif didMigrate then
            Log:info("Migrated settings into " .. newPath .. " and removed the legacy file")
        else
            Log:info("Removed stale legacy settings file: " .. deletablePath)
        end
    end

    if plan.read == "default" then
        -- unreadable-new (corrupt nested file, no legacy) is distinct from a fresh install: WARN so the
        -- reset-to-defaults is diagnosable (honours the spec's "unreadable-new -> WARNING" log rule).
        if fileExists(newPath) then
            Log:warning("Existing settings file is unreadable; recreating defaults: " .. newPath)
        else
            Log:info("Creating default settings file: " .. newPath)
        end
        self:writeSettings()
        return
    end

    if plan.read == "legacy" then
        Log:warning("New settings file missing or unreadable; reading legacy file in place: " .. legacyPath)
    end

    local userSettingsFile = (plan.read == "new") and newPath or legacyPath

    local xmlFile = loadXMLFile("transactionLogSettings", userSettingsFile)
    if xmlFile ~= 0 then
        local function getXmlValue(id)
            local setting = RmTransactionLogSettings.DEFINITIONS[id]
            if not setting then
                Log:warning("Unknown setting in XML file: " .. tostring(id))
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

        Log:info("Loading Transaction Log settings:")
        for _, id in pairs(RmTransactionLogSettings.MENU_ITEMS) do
            local valueString = getXmlValue(id)
            Log:info("  " .. id .. ": " .. valueString)
        end

        delete(xmlFile)
    else
        Log:error("Failed to load settings file: " .. userSettingsFile)
    end
end
