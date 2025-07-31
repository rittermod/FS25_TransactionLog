RmTransactionLog = {}
local RmTransactionLog_mt = Class(RmTransactionLog)

-- Constants
RmTransactionLog.startYear = 2025 -- Start year for the transaction log (Year 1 = 2025)

-- Table to store transactions at the module level.
-- This mod is single instance.
RmTransactionLog.transactions = {}

function RmTransactionLog.new(customMt)
    local self = setmetatable({}, customMt or RmTransactionLog_mt)
    self.transactions = RmTransactionLog.transactions -- Reference to shared transaction table
    return self
end

RmTransactionLog.dir = g_currentModDirectory
source(RmTransactionLog.dir .. "gui/RmTransactionLogFrame.lua")
source(RmTransactionLog.dir .. "gui/RmCommentInputDialog.lua")
source(RmTransactionLog.dir .. "scripts/RmUtils.lua")
source(RmTransactionLog.dir .. "scripts/RmTransactionBatcher.lua")



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

    if amount == 0 then
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
    local year = g_currentMission.environment.currentYear + RmTransactionLog.startYear - 1
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
        "Transaction logged: %s %s | Farm ID: %s | Amount: %.2f | Type: %s %s | Current Balance: %.2f",
        transaction.realDateTime, transaction.ingameDateTime, transaction.farmId, transaction.amount,
        transaction.transactionType, transaction.transactionStatistic, transaction.currentFarmBalance))
    RmUtils.logTrace("Transaction table size:", #RmTransactionLog.transactions)
end

function RmTransactionLog.showTransactionLog()
    RmUtils.logDebug("Showing transaction log GUI")
    if g_gui:getIsGuiVisible() then
        return
    end
    g_gui:showDialog("RmTransactionLogFrame")
end

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
        RmUtils.logDebug("changeFarmBalance called with farmId: " ..
        tostring(self.farmId) .. ", but current farmId is: " .. tostring(g_currentMission:getFarmId()))
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

function RmTransactionLog.saveToXmlFile()
    RmUtils.logInfo("Saving transaction log to XML file...")
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

function RmTransactionLog.loadMap()
    RmUtils.logDebug("Mod loaded!")
    local modSettingsDir = g_modSettingsDirectory and (g_modSettingsDirectory .. "/FS25_TransactionLog") or nil
    if modSettingsDir then
        createFolder(modSettingsDir)
    end
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
    local triggerUp, triggerDown, triggerAlways, startActive, callbackState, disableConflictingBindings = false, true,
        false, true, nil, true
    local success, actionEventId, otherEvents = g_inputBinding:registerActionEvent(InputAction.RM_SHOW_TRANSACTION_LOG,
        RmTransactionLog, RmTransactionLog.showTransactionLog, triggerUp, triggerDown, triggerAlways, startActive,
        callbackState, disableConflictingBindings);
    if not success then
        RmUtils.logError("Failed to register action event for RM_SHOW_TRANSACTION_LOG")
        return
    end
    -- Hide the action event text
    g_inputBinding:setActionEventTextVisibility(actionEventId, false)
end

function RmTransactionLog.currentMissionStarted()
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

-- Update tracking for batch processing
RmTransactionLog.updateTimer = 0
RmTransactionLog.UPDATE_INTERVAL = 1000 -- Check batches every 1 second (1000ms)

function RmTransactionLog.update(self, dt)
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


addModEventListener(RmTransactionLog)
