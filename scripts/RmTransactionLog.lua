-- RmTransactionLog.lua
-- Main transaction logging system for FS25 Transaction Log mod
-- Author: Ritter
-- Description: Tracks and logs financial transactions in Farming Simulator 25

RmTransactionLog = {}
local RmTransactionLog_mt = Class(RmTransactionLog)

-- Constants
RmTransactionLog.START_YEAR = 2025      -- Start year for the transaction log (Year 1 = 2025)
RmTransactionLog.UPDATE_INTERVAL = 1000 -- Check batches every 1 second (1000ms)

-- Table to store transactions at the module level.
-- This mod is single instance.
RmTransactionLog.transactions = {}

-- Settings system
RmTransactionLog.CONTROLS = {}
RmTransactionLog.settings = nil -- Will be initialized in loadMap

-- Auto-export date tracking system
RmTransactionLog.previousDate = nil          -- Format: "YYYY-MM-DD"
RmTransactionLog.previousCalendarMonth = nil -- Format: "YYYY-MM"
RmTransactionLog.previousCalendarYear = nil  -- Format: "YYYY"

---Creates a new RmTransactionLog instance
---@param customMt table|nil optional custom metatable
---@return table the new transaction log instance
function RmTransactionLog.new(customMt)
    local self = setmetatable({}, customMt or RmTransactionLog_mt)
    self.transactions = RmTransactionLog.transactions -- Reference to shared transaction table
    return self
end

RmTransactionLog.dir = g_currentModDirectory
source(RmTransactionLog.dir .. "scripts/gui/RmTransactionLogFrame.lua")
source(RmTransactionLog.dir .. "scripts/gui/RmCommentInputDialog.lua")
source(RmTransactionLog.dir .. "scripts/RmUtils.lua")
source(RmTransactionLog.dir .. "scripts/RmTransactionBatcher.lua")
source(RmTransactionLog.dir .. "scripts/RmTransactionLogSettings.lua")
source(RmTransactionLog.dir .. "scripts/RmTransactionLogExporter.lua")

-- Set the log prefix for this module
RmUtils.setLogPrefix("[RmTransactionLog]")

-- Set the log level for this module (can be changed as needed)
-- Valid levels: "ERROR", "WARNING", "INFO", "DEBUG", "TRACE" or numeric values 1-5
RmUtils.setLogLevel("DEBUG") -- Uncomment to enable debug logging
-- RmUtils.setLogLevel("TRACE")  -- Uncomment to enable trace logging



---Logs a single transaction to the transaction log
---@param amount number transaction amount (will be made absolute)
---@param farmId number the farm ID that performed the transaction
---@param moneyTypeTitle string localized transaction type title
---@param moneyTypeStatistic string transaction statistic type
---@param currentFarmBalance number current farm balance after transaction
---@param comment string|nil optional comment for the transaction
function RmTransactionLog.logTransaction(amount, farmId, moneyTypeTitle, moneyTypeStatistic, currentFarmBalance, comment)
    -- Parameter validation
    if amount == nil then
        RmUtils.logWarning("logTransaction called with nil amount")
        return
    end
    if farmId == nil then
        RmUtils.logWarning("logTransaction called with nil farmId")
        return
    end

    -- Round to two decimals and get absolute value
    local amount_check = math.abs(math.floor(amount * 100 + 0.5) / 100)
    if amount_check == 0.00 then
        RmUtils.logDebug("logTransaction called with amount 0, ignoring transaction")
        return
    end

    -- Convert the ingame datetime to a calender datetime.
    -- Adjust month to be 1-12 range. Periods starts in march, so we add 2 to align with the calendar.
    -- Then we adjust the month if it exceeds 12 (i.e., January and February).
    local month = g_currentMission.environment.currentPeriod + 2
    if month > 12 then
        month = month - 12
    end
    -- Ingame year changes in March, so we need to adjust the "calendar" year
    local year = g_currentMission.environment.currentYear + RmTransactionLog.START_YEAR - 1
    if month < 3 then
        year = year + 1
    end
    -- For ingame day we just use the current day in the period
    local day = g_currentMission.environment.currentDayInPeriod
    local hour = g_currentMission.environment.currentHour
    local minute = g_currentMission.environment.currentMinute
    local ingameDateTime = string.format("%04d-%02d-%02d %02d:%02d", year, month, day, hour, minute)
    local realDateTime = getDate("%Y-%m-%dT%H:%M:%S%z")
    local transaction = {
        realDateTime = realDateTime,
        ingameDateTime = ingameDateTime,
        farmId = farmId,
        amount = amount,
        transactionType = g_i18n:getText(moneyTypeTitle) or moneyTypeTitle,
        transactionStatistic = g_i18n:getText("finance_" .. moneyTypeStatistic) or moneyTypeStatistic,
        currentFarmBalance = currentFarmBalance or 0,
        comment = comment or "",
    }

    table.insert(RmTransactionLog.transactions, transaction)
    RmUtils.logInfo(string.format(
        "Transaction logged: %s %s | Farm ID: %s | Amount: %.2f | Type: %s %s | Balance: %.2f",
        transaction.realDateTime, transaction.ingameDateTime, transaction.farmId,
        transaction.amount, transaction.transactionType, transaction.transactionStatistic,
        transaction.currentFarmBalance))
    RmUtils.logTrace("Transaction table size:", #RmTransactionLog.transactions)
end

---Shows the transaction log GUI dialog
function RmTransactionLog.showTransactionLog()
    RmUtils.logDebug("Showing transaction log GUI")
    if g_gui:getIsGuiVisible() then
        return
    end
    g_gui:showDialog("RmTransactionLogFrame")
end

---Gets current calendar date using existing date conversion logic
---@return string dateStr Format: "YYYY-MM-DD"
---@return string monthStr Format: "YYYY-MM"
---@return string yearStr Format: "YYYY"
function RmTransactionLog.getCurrentCalendarDate()
    -- Use existing date conversion logic from logTransaction
    local month = g_currentMission.environment.currentPeriod + 2
    if month > 12 then
        month = month - 12
    end
    local year = g_currentMission.environment.currentYear + RmTransactionLog.START_YEAR - 1
    if month < 3 then
        year = year + 1
    end
    local day = g_currentMission.environment.currentDayInPeriod

    local dateStr = string.format("%04d-%02d-%02d", year, month, day)
    local monthStr = string.format("%04d-%02d", year, month)
    local yearStr = string.format("%04d", year)

    return dateStr, monthStr, yearStr
end

---Stores date information for auto-export tracking
---@param dateStr string current date in "YYYY-MM-DD" format
---@param monthStr string current month in "YYYY-MM" format
---@param yearStr string current year in "YYYY" format
function RmTransactionLog.storeDateInfo(dateStr, monthStr, yearStr)
    RmTransactionLog.previousDate = dateStr
    RmTransactionLog.previousCalendarMonth = monthStr
    RmTransactionLog.previousCalendarYear = yearStr
end

---Initializes auto-export date tracking system
function RmTransactionLog.initializeAutoExportTracking()
    local currentDate, currentMonth, currentYear = RmTransactionLog.getCurrentCalendarDate()
    RmTransactionLog.storeDateInfo(currentDate, currentMonth, currentYear)
    RmUtils.logDebug("Auto-export date tracking initialized with current date: " .. currentDate)
end

---Handles day change events for auto-export functionality
function RmTransactionLog.onDayChanged(self)
    local currentDate, currentMonth, currentYear = RmTransactionLog.getCurrentCalendarDate()
    local autoExportSetting = RmTransactionLog.settings:getValue("autoExportFrequency")

    if autoExportSetting > 0 then -- If any auto-export is enabled
        local yearChanged = currentYear ~= RmTransactionLog.previousCalendarYear
        local monthChanged = currentMonth ~= RmTransactionLog.previousCalendarMonth
        local dayChanged = currentDate ~= RmTransactionLog.previousDate

        if yearChanged and autoExportSetting == 3 then -- Yearly
            RmTransactionLog.performAutoExport("yearly", RmTransactionLog.previousCalendarYear)
        end
        if monthChanged and autoExportSetting == 2 then -- Monthly
            RmTransactionLog.performAutoExport("monthly", RmTransactionLog.previousCalendarMonth)
        end
        if dayChanged and autoExportSetting == 1 then -- Daily
            RmTransactionLog.performAutoExport("daily", RmTransactionLog.previousDate)
        end
    end

    -- Store current date info for next day
    RmTransactionLog.storeDateInfo(currentDate, currentMonth, currentYear)
end

---Filters transactions by date period pattern
---@param transactions table array of transaction objects
---@param periodPattern string date pattern to match against (e.g., "2024-12-09", "2024-12", "2024")
---@return table filteredTransactions array of matching transactions
function RmTransactionLog.filterTransactionsByPeriod(transactions, periodPattern)
    local filteredTransactions = {}

    for _, transaction in ipairs(transactions) do
        if transaction.ingameDateTime then
            local transactionDate = transaction.ingameDateTime
            -- Match based on period pattern (escape dashes for pattern matching)
            if string.find(transactionDate, "^" .. string.gsub(periodPattern, "%-", "%%-")) then
                table.insert(filteredTransactions, transaction)
            end
        end
    end

    RmUtils.logDebug(string.format("Filtered %d/%d transactions for period: %s",
        #filteredTransactions, #transactions, periodPattern))

    return filteredTransactions
end

---Generates auto-export filename suffix based on type and period
---@param exportType string "daily", "monthly", or "yearly"
---@param periodIdentifier string date pattern (e.g., "2024-12-09", "2024-12", "2024")
---@return string suffix for filename
function RmTransactionLog.generateAutoExportSuffix(exportType, periodIdentifier)
    if exportType == "daily" then
        -- periodIdentifier = "2024-12-09" → suffix = "auto_20241209"
        return "auto_" .. string.gsub(periodIdentifier, "-", "")
    elseif exportType == "monthly" then
        -- periodIdentifier = "2024-12" → suffix = "auto_202412"
        return "auto_" .. string.gsub(periodIdentifier, "-", "")
    elseif exportType == "yearly" then
        -- periodIdentifier = "2024" → suffix = "auto_2024"
        return "auto_" .. periodIdentifier
    end
    return "auto_unknown"
end

---Performs auto-export for specified period
---@param exportType string "daily", "monthly", or "yearly"
---@param periodIdentifier string date pattern for the period to export
function RmTransactionLog.performAutoExport(exportType, periodIdentifier)
    RmUtils.logInfo(string.format("Performing auto-export: %s for period %s", exportType, periodIdentifier))

    -- Flush all pending batches before exporting to ensure we capture all transactions
    RmTransactionBatcher.flushAllBatches(RmTransactionLog.logTransaction)

    -- Filter transactions from the specified period only
    local allTransactions = RmTransactionLog.transactions or {}
    local filteredTransactions = RmTransactionLog.filterTransactionsByPeriod(allTransactions, periodIdentifier)

    if #filteredTransactions == 0 then
        RmUtils.logInfo(string.format("No transactions found for %s auto-export period: %s",
            exportType, periodIdentifier))
        return
    end

    -- Generate auto-export filename based on type
    local suffix = RmTransactionLog.generateAutoExportSuffix(exportType, periodIdentifier)
    local directory = RmTransactionLogExporter.getExportDirectory()

    if not directory then
        RmUtils.logError("Auto-export failed: No export directory available")
        return
    end

    -- Perform export
    local success, message, filename = RmTransactionLogExporter.exportWithAutoFilename(
        filteredTransactions, directory, suffix)

    if success then
        RmUtils.logInfo(string.format("Auto-exported %d transactions (%s) to: %s",
            #filteredTransactions, exportType, filename))
    else
        RmUtils.logError(string.format("Auto-export (%s) failed: %s", exportType, message))
    end
end

---Hook function for Farm.changeBalance to capture transactions
---@param self table the farm instance
---@param amount number transaction amount
---@param moneyType table money type with title and statistic properties
function RmTransactionLog.changeFarmBalance(self, amount, moneyType, ...)
    RmUtils.logTrace("Farm balance changed with parameters:")
    RmUtils.logTrace(RmUtils.functionParametersToString(self, amount, moneyType, ...))

    -- Parameter validation
    if self == nil then
        RmUtils.logWarning("changeFarmBalance called with nil farm")
        return
    end
    if amount == nil then
        RmUtils.logWarning("changeFarmBalance called with nil amount")
        return
    end

    if self.farmId ~= g_currentMission:getFarmId() then
        RmUtils.logDebug(string.format(
            "changeFarmBalance called with farmId: %s, but current farmId is: %s",
            tostring(self.farmId), tostring(g_currentMission:getFarmId())))
        return
    end

    -- Log the transaction
    if moneyType == nil then
        -- for some reason moneyType can be nil, so we handle that case
        moneyType = MoneyType.OTHER
        RmUtils.logWarning("moneyType is nil, using MoneyType.OTHER")
    end

    local currentBalance = self:getBalance()
    RmUtils.logDebug(string.format("Current farm balance after change: %.2f", currentBalance))
    local currentEquity = self:getEquity()
    RmUtils.logDebug(string.format("Current farm equity before change: %.2f", currentEquity))

    -- Use batching system for batchable transactions, log others directly
    if RmTransactionBatcher.shouldBatch(moneyType.statistic) then
        RmTransactionBatcher.addToBatch(amount, self.farmId, moneyType.title, moneyType.statistic, currentBalance,
            RmTransactionLog.logTransaction)
    else
        RmTransactionLog.logTransaction(amount, self.farmId, moneyType.title, moneyType.statistic, currentBalance)
    end
end

---Saves all transactions to XML file in savegame directory
function RmTransactionLog.saveToXmlFile(self)
    RmUtils.logInfo("Saving transaction log to XML file...")

    -- Flush all pending batches before saving
    RmTransactionBatcher.flushAllBatches(RmTransactionLog.logTransaction)

    if #RmTransactionLog.transactions == 0 then
        RmUtils.logInfo("No transactions to save.")
        return
    end
    local savegameFolderPath = g_currentMission.missionInfo.savegameDirectory .. "/"
    local rootKey = "RmTransactionLog"
    local xmlFile = createXMLFile(rootKey, savegameFolderPath .. "tl_transactions.xml", rootKey);
    if xmlFile == nil then
        RmUtils.logError("Failed to create XML file for transaction log.")
        return
    end
    local i = 0
    for _, transaction in ipairs(RmTransactionLog.transactions) do
        local transactionKey = string.format("%s.transactions.transaction(%d)", rootKey, i)
        setXMLString(xmlFile, transactionKey .. "#realDateTime", transaction.realDateTime)
        setXMLString(xmlFile, transactionKey .. "#ingameDateTime", transaction.ingameDateTime)
        setXMLInt(xmlFile, transactionKey .. "#farmId", transaction.farmId)
        setXMLFloat(xmlFile, transactionKey .. "#amount", transaction.amount)
        setXMLString(xmlFile, transactionKey .. "#transactionType", transaction.transactionType)
        setXMLString(xmlFile, transactionKey .. "#transactionStatistic", transaction.transactionStatistic or "")
        setXMLFloat(xmlFile, transactionKey .. "#currentFarmBalance", transaction.currentFarmBalance or 0)
        setXMLString(xmlFile, transactionKey .. "#comment", transaction.comment or "")
        i = i + 1
    end

    saveXMLFile(xmlFile);
    RmUtils.logInfo(string.format("Saved %d transactions to tl_transactions.xml.", i))
    delete(xmlFile);
end

---Loads transactions from XML file in savegame directory
function RmTransactionLog.loadFromXMLFile()
    if not g_currentMission or not g_currentMission.missionInfo.savegameDirectory then
        RmUtils.logWarning(
            "No current savegameDirectory available. No transactions to load. Ignore this if you are loading a new game.")
        return
    end
    local savegameFolderPath = g_currentMission.missionInfo.savegameDirectory .. "/"
    if not fileExists(savegameFolderPath .. "tl_transactions.xml") then
        RmUtils.logWarning("No transaction log XML file found at path:", savegameFolderPath .. "tl_transactions.xml")
        RmUtils.logWarning(
            "No transactions to load. Ignore this if it is the first time loading savegame with this mod or you have just cleared the log.")
        return
    end

    local xmlFile = loadXMLFile("RmTransactionLog", savegameFolderPath .. "tl_transactions.xml")
    if xmlFile == nil then
        RmUtils.logError("Could not load transaction log XML file:", savegameFolderPath .. "tl_transactions.xml")
        return
    end

    local rootKey = "RmTransactionLog"
    local i = 0
    while true do
        local transactionKey = string.format("%s.transactions.transaction(%d)", rootKey, i)
        if not hasXMLProperty(xmlFile, transactionKey) then
            RmUtils.logDebug("No more transactions found in XML file at index: " .. i)
            break
        end

        local transaction = {
            realDateTime = getXMLString(xmlFile, transactionKey .. "#realDateTime"),
            ingameDateTime = getXMLString(xmlFile, transactionKey .. "#ingameDateTime"),
            farmId = getXMLInt(xmlFile, transactionKey .. "#farmId"),
            amount = getXMLFloat(xmlFile, transactionKey .. "#amount"),
            transactionType = getXMLString(xmlFile, transactionKey .. "#transactionType"),
            transactionStatistic = getXMLString(xmlFile, transactionKey .. "#transactionStatistic") or "",
            currentFarmBalance = getXMLFloat(xmlFile, transactionKey .. "#currentFarmBalance") or 0,
            comment = getXMLString(xmlFile, transactionKey .. "#comment") or "",
        }

        table.insert(RmTransactionLog.transactions, transaction)
        i = i + 1
    end

    delete(xmlFile)
    RmUtils.logInfo(string.format("Transaction log loaded from XML file. Loaded %d transactions.",
        #RmTransactionLog.transactions))
end

function RmTransactionLog.loadMap(self)
    RmUtils.logDebug("Mod loaded!")
    local modSettingsDir = g_modSettingsDirectory and (g_modSettingsDirectory .. "/FS25_TransactionLog") or nil
    if modSettingsDir then
        createFolder(modSettingsDir)
    end

    -- Initialize and load settings (settings must be available before UI interactions)
    RmTransactionLog.settings = RmTransactionLogSettings.new()
    RmTransactionLog.settings:readSettings()

    -- Verify settings initialization succeeded
    if not RmTransactionLog.settings then
        RmUtils.logError("Critical: Settings initialization failed")
        return
    end

    RmUtils.logDebug("Settings system initialized successfully")

    -- Initialize auto-export date tracking system
    RmTransactionLog.initializeAutoExportTracking()

    -- Subscribe to day change events for auto-export functionality
    g_messageCenter:subscribe(MessageType.DAY_CHANGED, RmTransactionLog.onDayChanged, RmTransactionLog)

    -- Append the mod's save function to the existing savegame function
    FSBaseMission.saveSavegame = Utils.appendedFunction(FSBaseMission.saveSavegame, RmTransactionLog.saveToXmlFile)
    -- Load existing transactions from XML file
    RmTransactionLog.loadFromXMLFile()

    -- Load GUI profiles
    g_gui:loadProfiles(RmTransactionLog.dir .. "gui/guiProfiles.xml")

    -- Register Transaction Log GUI
    RmTransactionLogFrame.register()

    -- Register Comment Input Dialog
    RmCommentInputDialog.register()
end

function RmTransactionLog.addPlayerActionEvents(self, controlling)
    RmUtils.logDebug("Adding player action events")
    local triggerUp, triggerDown, triggerAlways = false, true, false
    local startActive, callbackState, disableConflictingBindings = true, nil, true
    local success, actionEventId = g_inputBinding:registerActionEvent(
        InputAction.RM_SHOW_TRANSACTION_LOG, RmTransactionLog, RmTransactionLog.showTransactionLog,
        triggerUp, triggerDown, triggerAlways, startActive, callbackState, disableConflictingBindings)
    if not success and controlling ~= "VEHICLE" then
        RmUtils.logError("Failed to register action event for RM_SHOW_TRANSACTION_LOG")
        return
    end
    -- Hide the action event text
    g_inputBinding:setActionEventTextVisibility(actionEventId, false)
end

function RmTransactionLog.currentMissionStarted(self)
    RmUtils.logDebug("Current mission started")

    -- Append the mod's addMoney function to the existing g_currentMission.addMoney function
    -- Not sure this is the right hook, since it also captures money transactions not related to the player
    if g_currentMission.addMoney == nil then
        RmUtils.logError("g_currentMission.addMoney is nil, cannot append function.")
        return
    end
    -- hopefully this wil not be needed. Seems all transactions are logged through  farm.changeBalance
    -- g_currentMission.addMoney = Utils.appendedFunction(g_currentMission.addMoney, RmTransactionLog.addMoney)

    -- Register for update events to handle batch processing
    g_currentMission:addUpdateable(RmTransactionLog)
end

-- Update tracking state
RmTransactionLog.updateTimer = 0

function RmTransactionLog.update(self, dt)
    -- Validate dt parameter
    if type(dt) ~= "number" then
        RmUtils.logError("Update called with invalid dt parameter: %s (type: %s)", tostring(dt), type(dt))
        return
    end

    RmTransactionLog.updateTimer = RmTransactionLog.updateTimer + dt

    if RmTransactionLog.updateTimer >= RmTransactionLog.UPDATE_INTERVAL then
        RmTransactionLog.updateTimer = 0
        RmTransactionBatcher.updateBatches(RmTransactionLog.logTransaction)
    end
end

g_messageCenter:subscribe(MessageType.CURRENT_MISSION_START, RmTransactionLog.currentMissionStarted)


PlayerInputComponent.registerGlobalPlayerActionEvents = Utils.appendedFunction(
    PlayerInputComponent.registerGlobalPlayerActionEvents, RmTransactionLog.addPlayerActionEvents)

Farm.changeBalance = Utils.appendedFunction(Farm.changeBalance, RmTransactionLog.changeFarmBalance)

-- Settings menu integration
local inGameMenu = g_gui.screenControllers[InGameMenu]
local settingsPage = inGameMenu.pageSettings
local settingsLayout = settingsPage.generalSettingsLayout

RmTransactionLogControls = {}
RmTransactionLogControls.name = settingsPage.name

function RmTransactionLogControls.onMenuOptionChanged(self, state, menuOption)
    local id = menuOption.id
    local settingDef = RmTransactionLogSettings.DEFINITIONS[id]
    if not settingDef then
        RmUtils.logError("Unknown setting in onMenuOptionChanged: " .. tostring(id))
        return
    end

    local value = settingDef.values[state]

    if value ~= nil then
        RmUtils.logDebug("SET " .. id .. " = " .. tostring(value))
        -- Settings are initialized in loadMap() and should be available during UI interactions
        if RmTransactionLog.settings then
            if RmTransactionLog.settings:setValue(id, value) then
                RmTransactionLog.settings:writeSettings()
            else
                RmUtils.logError("Failed to set setting " .. id .. ", not saving settings")
            end
        else
            RmUtils.logError("Settings not initialized, cannot save setting: " .. id)
        end
    end
end

function RmTransactionLog.addMenuOption(id)
    local function updateFocusIds(element)
        if not element then
            return
        end
        element.focusId = FocusManager:serveAutoFocusId()
        for _, child in pairs(element.elements) do
            updateFocusIds(child)
        end
    end

    local settingDef = RmTransactionLogSettings.DEFINITIONS[id]
    if not settingDef then
        RmUtils.logError("Unknown setting definition for: " .. tostring(id))
        return
    end

    local original = settingsPage.multiVolumeVoiceBox
    local options = settingDef.strings
    local callback = "onMenuOptionChanged"

    local menuOptionBox = original:clone(settingsLayout)
    if not menuOptionBox then
        RmUtils.logError("could not create menu option box")
        return
    end
    menuOptionBox.id = id .. "box"

    local menuOption = menuOptionBox.elements[1]
    if not menuOption then
        RmUtils.logError("could not create menu option")
        return
    end

    menuOption.id = id
    menuOption.target = RmTransactionLogControls

    menuOption:setCallback("onClickCallback", callback)
    menuOption:setDisabled(false)

    local toolTip = menuOption.elements[1]
    toolTip:setText(g_i18n:getText("tooltip_transactionlog_" .. id))

    local setting = menuOptionBox.elements[2]
    setting:setText(g_i18n:getText("setting_transactionlog_" .. id))

    menuOption:setTexts({ unpack(options) })
    -- Settings may not be initialized yet during UI setup, use default state
    if RmTransactionLog.settings then
        menuOption:setState(RmTransactionLog.settings:getStateIndex(id))
    else
        menuOption:setState(settingDef.default or 1)
    end

    RmTransactionLog.CONTROLS[id] = menuOption

    updateFocusIds(menuOptionBox)
    table.insert(settingsPage.controlsList, menuOptionBox)

    return menuOption
end

-- Create section title
local sectionTitle = nil
for _, elem in ipairs(settingsLayout.elements) do
    if elem.name == "sectionHeader" then
        sectionTitle = elem:clone(settingsLayout)
        break
    end
end
if sectionTitle then
    sectionTitle:setText(g_i18n:getText("menu_TransactionLog_title"))
else
    local title = TextElement.new()
    title:applyProfile("fs25_settingsSectionHeader", true)
    title:setText(g_i18n:getText("menu_TransactionLog_title"))
    title.name = "sectionHeader"
    settingsLayout:addElement(title)
end

sectionTitle.focusId = FocusManager:serveAutoFocusId()
table.insert(settingsPage.controlsList, sectionTitle)
RmTransactionLog.CONTROLS[sectionTitle.name] = sectionTitle

-- Add menu options
for _, id in pairs(RmTransactionLogSettings.MENU_ITEMS) do
    RmTransactionLog.addMenuOption(id)
end
settingsLayout:invalidateLayout()

-- Allow keyboard navigation of menu options
FocusManager.setGui = Utils.appendedFunction(FocusManager.setGui, function(_, gui)
    if gui == "ingameMenuSettings" then
        -- Let the focus manager know about our custom controls now (earlier than this point seems to fail)
        for _, control in pairs(RmTransactionLog.CONTROLS) do
            if not control.focusId or not FocusManager.currentFocusData.idToElementMapping[control.focusId] then
                if not FocusManager:loadElementFromCustomValues(control, nil, nil, false, false) then
                    RmUtils.logWarning("Could not register control " ..
                        (control.id or control.name or control.focusId) .. " with the focus manager")
                end
            end
        end
        -- Invalidate the layout so the up/down connections are analyzed again by the focus manager
        local settingsPage = g_gui.screenControllers[InGameMenu].pageSettings
        settingsPage.generalSettingsLayout:invalidateLayout()
    end
end)

InGameMenuSettingsFrame.onFrameOpen = Utils.appendedFunction(InGameMenuSettingsFrame.onFrameOpen, function()
    local isAdmin = g_currentMission:getIsServer() or g_currentMission.isMasterUser

    for _, id in pairs(RmTransactionLogSettings.MENU_ITEMS) do
        local menuOption = RmTransactionLog.CONTROLS[id]
        if menuOption then
            -- Settings should be initialized by the time UI is opened during gameplay
            if RmTransactionLog.settings then
                menuOption:setState(RmTransactionLog.settings:getStateIndex(id))
            else
                RmUtils.logWarning("Settings not initialized when opening settings frame")
                local settingDef = RmTransactionLogSettings.DEFINITIONS[id]
                menuOption:setState(settingDef and settingDef.default or 1)
            end
            menuOption:setDisabled(not isAdmin)
        end
    end
end)

addModEventListener(RmTransactionLog)
