RM_TransactionLog = {}

-- Table to store transactions
RM_TransactionLog.transactions = {}

RM_TransactionLog.dir = g_currentModDirectory
source(RM_TransactionLog.dir .. "gui/TransactionLogFrame.lua")
source(RM_TransactionLog.dir .. "gui/CommentInputDialog.lua")
source(RM_TransactionLog.dir .. "scripts/RM_Utils.lua")

function RM_TransactionLog:logTransaction(amount, farmId, moneyTypeTitle, currentFarmBalance)
    if math.abs(amount) < 0.01 then
        -- Ignore transactions that are very small, typically land flattening etc
        logDebug("Transaction amount is too small, ignoring: " .. tostring(amount))
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
    local year = g_currentMission.environment.currentYear
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
        currentFarmBalance = currentFarmBalance or 0,
        comment = "",
    }

    table.insert(self.transactions, 1, transaction)
    logInfo(string.format("[RM_TransactionLog] Transaction logged: %s %s | Farm ID: %d | Amount: %.2f | Type: %s | Current Balance: %.2f",
            transaction.realDateTime, transaction.ingameDateTime, transaction.farmId, transaction.amount, transaction.transactionType, transaction.currentFarmBalance))
    logDebug("[RM_TransactionLog] Transaction table size:", #self.transactions)
end

function RM_TransactionLog:showTransactionLog()
    logDebug("Showing transaction log GUI")
    if g_gui:getIsGuiVisible() then
        return
    end
    g_gui:showDialog("TransactionLogFrame")
end

function RM_TransactionLog.changeFarmBalance(farm, amount, moneyType, ...)
    logDebug("Farm balance changed with parameters:")
    logFunctionParameters(farm, amount, moneyType, ...)

    -- Log the transaction
    if moneyType == nil then
        -- for some reason moneyType can be nil, so we handle that case
        moneyType = MoneyType.OTHER
        logWarning("moneyType is nil, using MoneyType.OTHER")
    end

    local currentBalance = farm:getBalance()
    logDebug(string.format("Current farm balance after change: %.2f", currentBalance))
    local currentEquity = farm:getEquity()
    logDebug(string.format("Current farm equity before change: %.2f", currentEquity))

    RM_TransactionLog:logTransaction(amount, farm.farmId, moneyType.title, currentBalance)

end

function RM_TransactionLog:saveToXmlFile()
    logInfo("Saving transaction log to XML file...")
    if #RM_TransactionLog.transactions == 0 then
        logInfo("No transactions to save.")
        return
    end
    local savegameFolderPath = g_currentMission.missionInfo.savegameDirectory .. "/"
    local rootKey = "RM_TransactionLog"
    local xmlFile = createXMLFile(rootKey, savegameFolderPath .. "transaction_log.xml", rootKey);
    if xmlFile == nil then
        logError("Failed to create XML file for transaction log.")
        return
    end
    local i = 0
    for _, transaction in pairs(RM_TransactionLog.transactions) do
        local transactionKey = string.format("%s.transactions.transaction(%d)", rootKey, i)
        setXMLString(xmlFile, transactionKey .. "#realDateTime", transaction.realDateTime)
        setXMLString(xmlFile, transactionKey .. "#ingameDateTime", transaction.ingameDateTime)
        setXMLInt(xmlFile, transactionKey .. "#farmId", transaction.farmId)
        setXMLFloat(xmlFile, transactionKey .. "#amount", transaction.amount)
        setXMLString(xmlFile, transactionKey .. "#transactionType", transaction.transactionType)
        setXMLFloat(xmlFile, transactionKey .. "#currentFarmBalance", transaction.currentFarmBalance or 0)
        setXMLString(xmlFile, transactionKey .. "#comment", transaction.comment or "")
        i = i + 1
    end

    saveXMLFile(xmlFile);
    logInfo(string.format("Saved %d transactions to transaction_log.xml.", i))
    delete(xmlFile);
end

function RM_TransactionLog:loadFromXMLFile()
    if not g_currentMission or not g_currentMission.missionInfo or not g_currentMission.missionInfo.savegameDirectory then
        logWarning("No current savegameDirectory available. No transactions to load. Ignore this if you are loading a new game.")
        return
    end
    local savegameFolderPath = g_currentMission.missionInfo.savegameDirectory .. "/"
    if not fileExists(savegameFolderPath .. "transaction_log.xml") then
        logWarning("No transaction log XML file found at path:", savegameFolderPath .. "transaction_log.xml")
        logWarning("No transactions to load. Ignore this if it is the first time loading savegame with this mod or you have just cleared the log.")
        return
    end

    local xmlFile = loadXMLFile("RM_TransactionLog", savegameFolderPath .. "transaction_log.xml")
    if xmlFile == nil then
        logError("Could not load transaction log XML file:", savegameFolderPath .. "transaction_log.xml")
        return
    end

    local rootKey = "RM_TransactionLog"
    local i = 0
    while true do
        local transactionKey = string.format("%s.transactions.transaction(%d)", rootKey, i)
        if not hasXMLProperty(xmlFile, transactionKey) then
            logDebug("No more transactions found in XML file at index: " .. i)
            break
        end

        local transaction = {
            realDateTime = getXMLString(xmlFile, transactionKey .. "#realDateTime"),
            ingameDateTime = getXMLString(xmlFile, transactionKey .. "#ingameDateTime"),
            farmId = getXMLInt(xmlFile, transactionKey .. "#farmId"),
            amount = getXMLFloat(xmlFile, transactionKey .. "#amount"),
            transactionType = getXMLString(xmlFile, transactionKey .. "#transactionType"),
            currentFarmBalance = getXMLFloat(xmlFile, transactionKey .. "#currentFarmBalance") or 0,
            comment = getXMLString(xmlFile, transactionKey .. "#comment") or "",
        }

        table.insert(RM_TransactionLog.transactions, transaction)
        i = i + 1
    end

    delete(xmlFile)
    logInfo(string.format("Transaction log loaded from XML file. Loaded %d transactions.", #RM_TransactionLog.transactions))
end

function RM_TransactionLog:loadMap()
    logDebug("Mod loaded!")
    -- Append the mod's save function to the existing savegame function
    FSBaseMission.saveSavegame = Utils.appendedFunction(FSBaseMission.saveSavegame, RM_TransactionLog.saveToXmlFile)
    -- Load existing transactions from XML file
    self:loadFromXMLFile()

    -- Load GUI profiles
    g_gui:loadProfiles(RM_TransactionLog.dir .. "gui/guiProfiles.xml")

    -- Register Transaction Log GUI
    TransactionLogFrame.register()

    -- Register Comment Input Dialog
    CommentInputDialog.register()
end

function RM_TransactionLog:addPlayerActionEvents(self, controlling)
    logDebug("Adding player action events")
    local triggerUp, triggerDown, triggerAlways, startActive, callbackState, disableConflictingBindings = false, true, false, true, nil, true
    local success, actionEventId, otherEvents = g_inputBinding:registerActionEvent(InputAction.RM_SHOW_TRANSACTION_LOG, RM_TransactionLog, RM_TransactionLog.showTransactionLog, triggerUp, triggerDown, triggerAlways, startActive, callbackState, disableConflictingBindings);
    if not success then
        logError("Failed to register action event for RM_SHOW_TRANSACTION_LOG")
        return
    end
    -- Hide the action event text
    g_inputBinding:setActionEventTextVisibility(actionEventId, false)
end

PlayerInputComponent.registerGlobalPlayerActionEvents = Utils.appendedFunction(
        PlayerInputComponent.registerGlobalPlayerActionEvents, RM_TransactionLog.addPlayerActionEvents)

Farm.changeBalance = Utils.appendedFunction(Farm.changeBalance, RM_TransactionLog.changeFarmBalance)


addModEventListener(RM_TransactionLog)


-- Probably obsolete, but keeping for reference for now
--function RM_TransactionLog:addMoney(amount, farmId, moneyType, ...)
--    logDebug("g_currentMission:addMoney called with:")
--    logFunctionParameters(amount, farmId, moneyType, ...)
--
--    RM_TransactionLog:logTransaction(amount, farmId, moneyType.title)
--
--end
--function RM_TransactionLog:currentMissionStarted()
--    logDebug("Current mission started")
--
--    -- Append the mod's addMoney function to the existing g_currentMission.addMoney function
--    -- Not sure this is the right hook, since it also captures money transactions not related to the player
--    if g_currentMission.addMoney == nil then
--        logError("g_currentMission.addMoney is nil, cannot append function.")
--        return
--    end
--    g_currentMission.addMoney = Utils.appendedFunction(g_currentMission.addMoney, RM_TransactionLog.addMoney)
--end
--g_messageCenter:subscribe(MessageType.CURRENT_MISSION_START, RM_TransactionLog.currentMissionStarted)