-- Transaction Log Frame
-- Displays transaction history in a GUI dialog

TransactionLogFrame = {}
local TransactionLogFrame_mt = Class(TransactionLogFrame, MessageDialog)

-- Constants
TransactionLogFrame.MAX_COMMENT_LENGTH = 200  -- Maximum characters allowed in comment input

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
    logTrace("TransactionLogFrame:new()")
    local self = MessageDialog.new(target, custom_mt or TransactionLogFrame_mt)
    self.transactions = {}
    return self
end

function TransactionLogFrame:onGuiSetupFinished()
    logTrace("TransactionLogFrame:onGuiSetupFinished()")
    TransactionLogFrame:superClass().onGuiSetupFinished(self)
    self.transactionTable:setDataSource(self)
    self.transactionTable:setDelegate(self)
end

function TransactionLogFrame:onCreate()
    logTrace("TransactionLogFrame:onCreate()")
    TransactionLogFrame:superClass().onCreate(self)
end

function TransactionLogFrame:onOpen()
    logTrace("TransactionLogFrame:onOpen()")
    TransactionLogFrame:superClass().onOpen(self)
    
    -- Get transactions from the main transaction log
    if RM_TransactionLog.transactions then
        self.transactions = RM_TransactionLog.transactions
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
    logTrace("TransactionLogFrame:onClose()")
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
            
            -- Format amount with currency symbol and color
            local amount = transaction.amount or 0
            -- todo: Add currency symbol?
            local amountText = string.format("%.2f", amount)
            local amountElement = cell:getAttribute("amount")
            amountElement:setText(amountText)
            
            -- Set color based on positive/negative amount
            if amount >= 0 then
                amountElement.textColor = {0, 0.8, 0, 1} -- Darker green for positive
            else
                amountElement.textColor = {0.9, 0.2, 0.2, 1} -- Darker red for negative with better contrast
            end
            
            -- Format and display farm balance
            local balance = transaction.currentFarmBalance or 0
            local balanceText = string.format("%.2f", balance)
            local balanceElement = cell:getAttribute("balance")
            balanceElement:setText(balanceText)
            
            -- Set color based on positive/negative balance
            if balance >= 0 then
                balanceElement.textColor = {0, 0.8, 0, 1} -- Darker green for positive
            else
                balanceElement.textColor = {0.9, 0.2, 0.2, 1} -- Darker red for negative with better contrast
            end
            
            cell:getAttribute("comment"):setText(transaction.comment or "")
        end
    end
end

-- Button handlers
function TransactionLogFrame:onClickClose()
    logTrace("TransactionLogFrame:onClickClose()")
    self:close()
end

function TransactionLogFrame:onClickAddComment()
    logTrace("TransactionLogFrame:onClickAddComment()")
    
    -- Get the selected transaction
    local selectedIndex = self.transactionTable.selectedIndex
    if selectedIndex == nil or selectedIndex < 1 or selectedIndex > #self.transactions then
        logWarning("No transaction selected or invalid selection")
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
                
                logDebug(string.format("Comment updated for transaction: %s", text))
            end
        end
        
        -- Show the comment dialog
        local existingComment = selectedTransaction.comment or ""
        local prompt = string.format(g_i18n:getText("ui_transaction_log_comment_prompt"), selectedTransaction.transactionType or g_i18n:getText("ui_transaction_log_unknown_type"), selectedTransaction.amount or 0)
        CommentInputDialog.show(onCommentCallback, nil, existingComment, prompt, TransactionLogFrame.MAX_COMMENT_LENGTH, nil)
    end
end

function TransactionLogFrame:onClickClearLog()
    logTrace("TransactionLogFrame:onClickClearLog()")
    
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
            
            logInfo("Transaction log cleared via GUI")
        end
    end
end

function TransactionLogFrame:onClickExportCSV()
    logTrace("TransactionLogFrame:onClickExportCSV()")
    
    if #self.transactions == 0 then
        InfoDialog.show(g_i18n:getText("ui_transaction_log_export_no_data"))
        return
    end
    
    -- Get the savegame folder path (same as XML file)
    local savegameFolderPath = g_currentMission.missionInfo.savegameDirectory .. "/"
    local csvFileName = "transaction_log.csv"
    local csvFilePath = savegameFolderPath .. csvFileName
    
    -- Create CSV content
    local csvContent = {}
    
    -- Add CSV header
    table.insert(csvContent, "Real DateTime,In-game DateTime,Farm ID,Transaction Type,Amount,Balance,Comment")
    
    -- Add transaction data
    for _, transaction in ipairs(self.transactions) do
        local realDateTime = transaction.realDateTime or ""
        local ingameDateTime = transaction.ingameDateTime or ""
        local farmId = tostring(transaction.farmId or "")
        local transactionType = transaction.transactionType or ""
        local amount = tostring(transaction.amount or "0")
        local balance = tostring(transaction.currentFarmBalance or "0")
        local comment = transaction.comment or ""
        
        -- Escape commas and quotes in CSV fields
        local function escapeCSVField(field)
            if string.find(field, '[,"]') then
                -- Replace quotes with double quotes and wrap in quotes
                field = string.gsub(field, '"', '""')
                field = '"' .. field .. '"'
            end
            return field
        end

        transactionType = escapeCSVField(transactionType)
        comment = escapeCSVField(comment)
        
        local csvRow = string.format("%s,%s,%s,%s,%.2f,%.2f,%s",
            realDateTime, ingameDateTime, farmId, transactionType, amount, balance, comment)
        table.insert(csvContent, csvRow)
    end
    
    -- Write CSV file
    local csvText = table.concat(csvContent, "\n")
    local file = io.open(csvFilePath, "w")
    if file then
        file:write(csvText)
        file:close()
        logInfo(string.format("Exported %d transactions to CSV: %s", #self.transactions, csvFilePath))
        
        -- Show confirmation dialog with file path
        local confirmationText = string.format(g_i18n:getText("ui_transaction_log_export_success"), #self.transactions, "savegameX/"..csvFileName)
        InfoDialog.show(confirmationText)
    else
        logError("Failed to create CSV file: " .. csvFilePath)
        InfoDialog.show(g_i18n:getText("ui_transaction_log_export_error"))
    end
end

function TransactionLogFrame.register()
    logTrace("TransactionLogFrame.register()")
    local dialog = TransactionLogFrame.new(g_i18n)
    g_gui:loadGui(RM_TransactionLog.dir .. "gui/TransactionLogFrame.xml", "TransactionLogFrame", dialog)
end

-- Static function to show the transaction log dialog
function TransactionLogFrame.showTransactionLog()
    logTrace("TransactionLogFrame.showTransactionLog()")
    
    -- Create and show the dialog
    local dialog = TransactionLogFrame.new()
    g_gui:showDialog("TransactionLogFrame")
end