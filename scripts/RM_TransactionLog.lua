RM_TransactionLog = {}
local RM_TransactionLog_mt = Class(RM_TransactionLog)

-- Constants
RM_TransactionLog.MIN_TRANSACTION_THRESHOLD = 0.01  -- Minimum transaction amount to log

-- Table to store transactions (module level for compatibility)
RM_TransactionLog.transactions = {}

function RM_TransactionLog.new(customMt)
    local self = setmetatable({}, customMt or RM_TransactionLog_mt)
    self.transactions = RM_TransactionLog.transactions  -- Reference to shared transaction table
    return self
end

RM_TransactionLog.dir = g_currentModDirectory
source(RM_TransactionLog.dir .. "gui/TransactionLogFrame.lua")
source(RM_TransactionLog.dir .. "gui/CommentInputDialog.lua")
source(RM_TransactionLog.dir .. "scripts/RM_Utils.lua")
source(RM_TransactionLog.dir .. "scripts/RM_TransactionBatcher.lua")



function RM_TransactionLog.logTransaction(amount, farmId, moneyTypeTitle, moneyTypeStatistic, currentFarmBalance, comment)
    -- Parameter validation
    if amount == nil then
        RmUtils.logWarning("logTransaction called with nil amount")
        return
    end
    if farmId == nil then
        RmUtils.logWarning("logTransaction called with nil farmId")
        return
    end
    
    -- if math.abs(amount) < RM_TransactionLog.MIN_TRANSACTION_THRESHOLD then
    --     -- Ignore transactions that are very small, typically land flattening etc
    --     RmUtils.logDebug("Transaction amount is too small, ignoring: " .. tostring(amount))
    --     return
    -- end

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
        transactionStatistic = g_i18n:getText("finance_"..moneyTypeStatistic) or moneyTypeStatistic,
        currentFarmBalance = currentFarmBalance or 0,
        comment = comment or "",
    }

    table.insert(RM_TransactionLog.transactions, transaction)
    RmUtils.logInfo(string.format("Transaction logged: %s %s | Farm ID: %s | Amount: %.2f | Type: %s %s | Current Balance: %.2f",
            transaction.realDateTime, transaction.ingameDateTime, transaction.farmId, transaction.amount, transaction.transactionType, transaction.transactionStatistic, transaction.currentFarmBalance))
    RmUtils.logTrace("Transaction table size:", #RM_TransactionLog.transactions)
end

function RM_TransactionLog.showTransactionLog()
    RmUtils.logDebug("Showing transaction log GUI")
    if g_gui:getIsGuiVisible() then
        return
    end
    g_gui:showDialog("TransactionLogFrame")
end

function RM_TransactionLog.changeFarmBalance(self, amount, moneyType, ...)
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
       RmUtils.logDebug("changeFarmBalance called with farmId: " .. tostring(self.farmId) .. ", but current farmId is: " .. tostring(g_currentMission:getFarmId()))
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

    -- Use batching system instead of direct logging
    RM_TransactionBatcher.addToBatch(amount, "farm-"..self.farmId, moneyType.title, moneyType.statistic, currentBalance, RM_TransactionLog.logTransaction)

end

function RM_TransactionLog.saveToXmlFile()
    RmUtils.logInfo("Saving transaction log to XML file...")
    if #RM_TransactionLog.transactions == 0 then
        RmUtils.logInfo("No transactions to save.")
        return
    end
    local savegameFolderPath = g_currentMission.missionInfo.savegameDirectory .. "/"
    local rootKey = "RM_TransactionLog"
    local xmlFile = createXMLFile(rootKey, savegameFolderPath .. "tl_transactions.xml", rootKey);
    if xmlFile == nil then
        RmUtils.logError("Failed to create XML file for transaction log.")
        return
    end
    local i = 0
    for _, transaction in ipairs(RM_TransactionLog.transactions) do
        local transactionKey = string.format("%s.transactions.transaction(%d)", rootKey, i)
        setXMLString(xmlFile, transactionKey .. "#realDateTime", transaction.realDateTime)
        setXMLString(xmlFile, transactionKey .. "#ingameDateTime", transaction.ingameDateTime)
        setXMLString(xmlFile, transactionKey .. "#farmId", transaction.farmId)
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

function RM_TransactionLog.loadFromXMLFile()
    if not g_currentMission or not g_currentMission.missionInfo.savegameDirectory then
        RmUtils.logWarning("No current savegameDirectory available. No transactions to load. Ignore this if you are loading a new game.")
        return
    end
    local savegameFolderPath = g_currentMission.missionInfo.savegameDirectory .. "/"
    if not fileExists(savegameFolderPath .. "tl_transactions.xml") then
        RmUtils.logWarning("No transaction log XML file found at path:", savegameFolderPath .. "tl_transactions.xml")
        RmUtils.logWarning("No transactions to load. Ignore this if it is the first time loading savegame with this mod or you have just cleared the log.")
        return
    end

    local xmlFile = loadXMLFile("RM_TransactionLog", savegameFolderPath .. "tl_transactions.xml")
    if xmlFile == nil then
        RmUtils.logError("Could not load transaction log XML file:", savegameFolderPath .. "tl_transactions.xml")
        return
    end

    local rootKey = "RM_TransactionLog"
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
            farmId = getXMLString(xmlFile, transactionKey .. "#farmId"),
            amount = getXMLFloat(xmlFile, transactionKey .. "#amount"),
            transactionType = getXMLString(xmlFile, transactionKey .. "#transactionType"),
            transactionStatistic = getXMLString(xmlFile, transactionKey .. "#transactionStatistic") or "",
            currentFarmBalance = getXMLFloat(xmlFile, transactionKey .. "#currentFarmBalance") or 0,
            comment = getXMLString(xmlFile, transactionKey .. "#comment") or "",
        }

        table.insert(RM_TransactionLog.transactions, transaction)
        i = i + 1
    end

    delete(xmlFile)
    RmUtils.logInfo(string.format("Transaction log loaded from XML file. Loaded %d transactions.", #RM_TransactionLog.transactions))
end

function RM_TransactionLog.loadMap()
    RmUtils.logDebug("Mod loaded!")
    local modSettingsDir = g_modSettingsDirectory and (g_modSettingsDirectory .. "/FS25_TransactionLog") or nil
    if modSettingsDir then
        createFolder(modSettingsDir)
    end
    -- Append the mod's save function to the existing savegame function
    FSBaseMission.saveSavegame = Utils.appendedFunction(FSBaseMission.saveSavegame, RM_TransactionLog.saveToXmlFile)
    -- Load existing transactions from XML file
    RM_TransactionLog.loadFromXMLFile()

    -- Load GUI profiles
    g_gui:loadProfiles(RM_TransactionLog.dir .. "gui/guiProfiles.xml")

    -- Register Transaction Log GUI
    TransactionLogFrame.register()

    -- Register Comment Input Dialog  
    CommentInputDialog.register()
end

function RM_TransactionLog.addPlayerActionEvents(self, controlling)
    RmUtils.logDebug("Adding player action events")
    local triggerUp, triggerDown, triggerAlways, startActive, callbackState, disableConflictingBindings = false, true, false, true, nil, true
    local success, actionEventId, otherEvents = g_inputBinding:registerActionEvent(InputAction.RM_SHOW_TRANSACTION_LOG, RM_TransactionLog, RM_TransactionLog.showTransactionLog, triggerUp, triggerDown, triggerAlways, startActive, callbackState, disableConflictingBindings);
    if not success then
        RmUtils.logError("Failed to register action event for RM_SHOW_TRANSACTION_LOG")
        return
    end
    -- Hide the action event text
    g_inputBinding:setActionEventTextVisibility(actionEventId, false)
end




function RM_TransactionLog.addMoney(self, amount, farmId, moneyType, ...)
    -- amount, farmId, moneyType, addMoneyChange, forceShowMoneyChange
   RmUtils.logTrace("g_currentMission:addMoney called with:")
   RmUtils.logTrace(RmUtils.functionParametersToString(amount, farmId, moneyType, ...))
   
   -- Parameter validation
   if amount == nil then
       RmUtils.logWarning("addMoney called with nil amount")
       return
   end
   if farmId == nil then
       RmUtils.logWarning("addMoney called with nil farmId")
       return
   end
   
   if farmId ~= g_currentMission:getFarmId() then
       RmUtils.logDebug("addMoney called with farmId: " .. tostring(farmId) .. ", but current farmId is: " .. tostring(g_currentMission:getFarmId()))
       return
   end

   -- Cache expensive lookup to avoid duplicate calls
   local currentFarm = g_farmManager:getFarmById(g_currentMission:getFarmId())
   local currentBalance = currentFarm and currentFarm:getBalance() or 0
   RmUtils.logDebug(string.format("Current farm balance after change: %.2f", currentBalance))

   -- Use batching system instead of direct logging
   RM_TransactionBatcher.addToBatch(amount, "mission-"..farmId, moneyType.title, moneyType.statistic, currentBalance, RM_TransactionLog.logTransaction)

end

function RM_TransactionLog.currentMissionStarted()
   RmUtils.logDebug("Current mission started")

   -- Append the mod's addMoney function to the existing g_currentMission.addMoney function
   -- Not sure this is the right hook, since it also captures money transactions not related to the player
   if g_currentMission.addMoney == nil then
       RmUtils.logError("g_currentMission.addMoney is nil, cannot append function.")
       return
   end
   g_currentMission.addMoney = Utils.appendedFunction(g_currentMission.addMoney, RM_TransactionLog.addMoney)
   
   -- Hook into mission update for batch processing
   if g_currentMission.update then
       g_currentMission.update = Utils.appendedFunction(g_currentMission.update, function()
           RM_TransactionBatcher.updateBatches(RM_TransactionLog.logTransaction)
       end)
   end
end


g_messageCenter:subscribe(MessageType.CURRENT_MISSION_START, RM_TransactionLog.currentMissionStarted)


PlayerInputComponent.registerGlobalPlayerActionEvents = Utils.appendedFunction(
        PlayerInputComponent.registerGlobalPlayerActionEvents, RM_TransactionLog.addPlayerActionEvents)

Farm.changeBalance = Utils.appendedFunction(Farm.changeBalance, RM_TransactionLog.changeFarmBalance)


addModEventListener(RM_TransactionLog)
