-- Transaction Log Frame
-- Displays transaction history in a GUI dialog

TransactionLogFrame = {}
local TransactionLogFrame_mt = Class(TransactionLogFrame, MessageDialog)

-- Constants
TransactionLogFrame.MAX_COMMENT_LENGTH = 200  -- Maximum characters allowed in comment input

-- UI Color constants (cached for performance)
TransactionLogFrame.POSITIVE_COLOR = {0, 0.8, 0, 1}      -- Darker green for positive amounts
TransactionLogFrame.NEGATIVE_COLOR = {0.9, 0.2, 0.2, 1}  -- Darker red for negative amounts

TransactionLogFrame.CONTROLS = {
    "transactionTable",
    "tableSlider",
    "totalTransactionsLabel",
    "totalTransactionsValue",
    "buttonAddComment",
    "buttonClearLog",
    "buttonExportCSV"
}

function TransactionLogFrame.new(target, custom_mt)
    RmUtils.logTrace("TransactionLogFrame:new()")
    local self = MessageDialog.new(target, custom_mt or TransactionLogFrame_mt)
    self.transactions = {}
    return self
end

function TransactionLogFrame:onGuiSetupFinished()
    RmUtils.logTrace("TransactionLogFrame:onGuiSetupFinished()")
    TransactionLogFrame:superClass().onGuiSetupFinished(self)
    self.transactionTable:setDataSource(self)
    self.transactionTable:setDelegate(self)
end

function TransactionLogFrame:onCreate()
    RmUtils.logTrace("TransactionLogFrame:onCreate()")
    TransactionLogFrame:superClass().onCreate(self)
end

function TransactionLogFrame:onOpen()
    RmUtils.logTrace("TransactionLogFrame:onOpen()")
    TransactionLogFrame:superClass().onOpen(self)
    
    -- Get transactions from the main transaction log
    if RM_TransactionLog.transactions then
        self.transactions = RM_TransactionLog.transactions
        -- Sort transactions by in-game time, newest first
        table.sort(self.transactions, function(a, b)
            return (a.ingameDateTime or "") > (b.ingameDateTime or "")
        end)
    else
        self.transactions = {}
    end
    
    -- Update total transactions display
    self.totalTransactionsValue:setText(tostring(#self.transactions))
    
    -- Reload the table data
    self.transactionTable:reloadData()
    
    -- Set focus to the table
    self:setSoundSuppressed(true)
    FocusManager:setFocus(self.transactionTable)
    self:setSoundSuppressed(false)
end

function TransactionLogFrame:onClose()
    RmUtils.logTrace("TransactionLogFrame:onClose()")
    self.transactions = {}
    TransactionLogFrame:superClass().onClose(self)
end

-- Table data source methods
function TransactionLogFrame:getNumberOfItemsInSection(list, section)
    if list == self.transactionTable then
        return #self.transactions
    else
        return 0
    end
end

function TransactionLogFrame:populateCellForItemInSection(list, section, index, cell)
    if list == self.transactionTable then
        local transaction = self.transactions[index]
        if transaction then
            -- Set transaction data in the cell
            cell:getAttribute("ingameDateTime"):setText(transaction.ingameDateTime or g_i18n:getText("ui_transaction_log_no_data"))
            cell:getAttribute("farmId"):setText(tostring(transaction.farmId or g_i18n:getText("ui_transaction_log_no_data")))
            cell:getAttribute("transactionType"):setText(transaction.transactionType or g_i18n:getText("ui_transaction_log_no_data"))
            cell:getAttribute("transactionStatistic"):setText(transaction.transactionStatistic or g_i18n:getText("ui_transaction_log_no_data"))
            
            -- Format amount with currency symbol and color
            local amount = transaction.amount or 0
            -- todo: Add currency symbol?
            local amountText = string.format("%.2f", amount)
            local amountElement = cell:getAttribute("amount")
            amountElement:setText(amountText)
            
            -- Set color based on positive/negative amount
            if amount >= 0 then
                amountElement.textColor = TransactionLogFrame.POSITIVE_COLOR
            else
                amountElement.textColor = TransactionLogFrame.NEGATIVE_COLOR
            end
            
            -- Format and display farm balance
            local balance = transaction.currentFarmBalance or 0
            local balanceText = string.format("%.2f", balance)
            local balanceElement = cell:getAttribute("balance")
            balanceElement:setText(balanceText)
            
            -- Set color based on positive/negative balance
            if balance >= 0 then
                balanceElement.textColor = TransactionLogFrame.POSITIVE_COLOR
            else
                balanceElement.textColor = TransactionLogFrame.NEGATIVE_COLOR
            end
            
            cell:getAttribute("comment"):setText(transaction.comment or "")
        end
    end
end

-- Button handlers
function TransactionLogFrame:onClickClose()
    RmUtils.logTrace("TransactionLogFrame:onClickClose()")
    self:close()
end

function TransactionLogFrame:onClickAddComment()
    RmUtils.logTrace("TransactionLogFrame:onClickAddComment()")
    
    -- Get the selected transaction
    local selectedIndex = self.transactionTable.selectedIndex
    if selectedIndex == nil or selectedIndex < 1 or selectedIndex > #self.transactions then
        RmUtils.logWarning("No transaction selected or invalid selection")
        return
    end
    
    local selectedTransaction = self.transactions[selectedIndex]
    if selectedTransaction then
        -- Create callback function to handle comment updates
        local function onCommentCallback(text, clickOk, args)
            if clickOk and text then
                -- Update the transaction in the main log
                if RM_TransactionLog and RM_TransactionLog.transactions and RM_TransactionLog.transactions[selectedIndex] then
                    RM_TransactionLog.transactions[selectedIndex].comment = text
                end
                
                -- Update local transactions and refresh display
                self.transactions[selectedIndex].comment = text
                self.transactionTable:reloadData()
                
                RmUtils.logDebug(string.format("Comment updated for transaction: %s", text))
            end
        end
        
        -- Show the comment dialog
        local existingComment = selectedTransaction.comment or ""
        local prompt = string.format(g_i18n:getText("ui_transaction_log_comment_prompt"), selectedTransaction.transactionType or g_i18n:getText("ui_transaction_log_unknown_type"), selectedTransaction.amount or 0)
        CommentInputDialog.show(onCommentCallback, nil, existingComment, prompt, TransactionLogFrame.MAX_COMMENT_LENGTH, nil)
    end
end

function TransactionLogFrame:onClickClearLog()
    RmUtils.logTrace("TransactionLogFrame:onClickClearLog()")
    
    -- Show confirmation dialog
    local confirmationText = string.format(g_i18n:getText("ui_transaction_log_clear_confirmation"), #self.transactions)
    
    YesNoDialog.show(self.onYesNoClearLog, self, confirmationText, g_i18n:getText("ui_transaction_log_clear_title"), g_i18n:getText("ui_transaction_log_clear_yes"), g_i18n:getText("ui_transaction_log_clear_no"))
end

function TransactionLogFrame:onYesNoClearLog(yes)
    if yes then
        -- Clear the transaction log
        if RM_TransactionLog then
            RM_TransactionLog.transactions = {}
            self.transactions = {}
            
            -- Update display
            self.totalTransactionsValue:setText("0")
            self.transactionTable:reloadData()
            
            RmUtils.logInfo("Transaction log cleared via GUI")
        end
    end
end

function TransactionLogFrame:onClickExportCSV()
    RmUtils.logTrace("TransactionLogFrame:onClickExportCSV()")
    
    if #self.transactions == 0 then
        InfoDialog.show(g_i18n:getText("ui_transaction_log_export_no_data"))
        return
    end
    
    -- Get the modSettings folder path with validation
    local modSettingsDir = g_modSettingsDirectory and (g_modSettingsDirectory .. "FS25_TransactionLog/") or nil
    if not modSettingsDir or modSettingsDir == "" then
        RmUtils.logError("g_modSettingsDirectory not available, falling back to savegame directory")
        modSettingsDir = g_currentMission.missionInfo.savegameDirectory
        if not modSettingsDir or modSettingsDir == "" then
            RmUtils.logError("No valid directory available for CSV export")
            InfoDialog.show(g_i18n:getText("ui_transaction_log_export_error"))
            return
        end
    end
    
    local savegameIndex = g_currentMission.missionInfo.savegameIndex or 0
    local timestamp = getDate("%Y%m%d%H%M%S")
    local csvFileName = string.format("tl_transactions_sg%02d_%s.csv", savegameIndex, timestamp)
    local csvFilePath = modSettingsDir .. csvFileName
    
    -- Helper function to escape CSV fields (moved outside loop for performance)
    local function escapeCSVField(field)
        if string.find(field, '[,"]') then
            -- Replace quotes with double quotes and wrap in quotes
            field = string.gsub(field, '"', '""')
            field = '"' .. field .. '"'
        end
        return field
    end
    
    -- Create CSV content
    local csvContent = {}
    
    -- Add CSV header
    table.insert(csvContent, "Real DateTime,In-game DateTime,Farm ID,Type,Income/Expenditure,Amount,Balance,Comment")
    
    -- Add transaction data
    for _, transaction in ipairs(self.transactions) do
        local realDateTime = transaction.realDateTime or ""
        local ingameDateTime = transaction.ingameDateTime or ""
        local farmId = tostring(transaction.farmId or "")
        local transactionType = escapeCSVField(transaction.transactionType or "")
        local transactionStatistic = transaction.transactionStatistic or ""
        local amount = tonumber(transaction.amount) or 0
        local balance = tonumber(transaction.currentFarmBalance) or 0
        local comment = escapeCSVField(transaction.comment or "")
        
        local csvRow = string.format("%s,%s,%s,%s,%s,%.2f,%.2f,%s",
            realDateTime, ingameDateTime, farmId, transactionType, transactionStatistic, amount, balance, comment)
        table.insert(csvContent, csvRow)
    end
    
    -- Write CSV file
    local csvText = table.concat(csvContent, "\n")
    local file = io.open(csvFilePath, "w")
    if file then
        file:write(csvText)
        file:close()
        RmUtils.logInfo(string.format("Exported %d transactions to CSV: %s", #self.transactions, csvFilePath))
        
        -- Show confirmation dialog with file path
        -- Extract path from /modSettings/ or /savegame onwards for display
        local displayPath = modSettingsDir
        local modSettingsIndex = string.find(displayPath, "/modSettings/")
        local savegameIndex = string.find(displayPath, "/savegame")
        if modSettingsIndex then
            displayPath = string.sub(displayPath, modSettingsIndex)
        elseif savegameIndex then
            displayPath = string.sub(displayPath, savegameIndex)
        end
        local confirmationText = string.format(g_i18n:getText("ui_transaction_log_export_success"), #self.transactions, csvFileName, displayPath)
        InfoDialog.show(confirmationText)
    else
        RmUtils.logError("Failed to create CSV file: " .. csvFilePath)
        InfoDialog.show(g_i18n:getText("ui_transaction_log_export_error"))
    end
end

function TransactionLogFrame.register()
    RmUtils.logTrace("TransactionLogFrame.register()")
    local dialog = TransactionLogFrame.new(g_i18n)
    g_gui:loadGui(RM_TransactionLog.dir .. "gui/TransactionLogFrame.xml", "TransactionLogFrame", dialog)
end

-- Static function to show the transaction log dialog
function TransactionLogFrame.showTransactionLog()
    RmUtils.logTrace("TransactionLogFrame.showTransactionLog()")
    
    -- Create and show the dialog
    local dialog = TransactionLogFrame.new()
    g_gui:showDialog("TransactionLogFrame")
end