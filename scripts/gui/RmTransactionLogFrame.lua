-- RmTransactionLogFrame.lua
-- Transaction log GUI frame for FS25 Transaction Log mod
-- Author: Ritter
-- Description: Displays transaction history in a GUI dialog

RmTransactionLogFrame = {}
local RmTransactionLogFrame_mt = Class(RmTransactionLogFrame, MessageDialog)

-- Constants
RmTransactionLogFrame.MAX_COMMENT_LENGTH = 200 -- Maximum characters allowed in comment input

-- UI Color constants (cached for performance)
RmTransactionLogFrame.POSITIVE_COLOR = { 0, 0.8, 0, 1 }     -- Darker green for positive amounts
RmTransactionLogFrame.NEGATIVE_COLOR = { 0.9, 0.2, 0.2, 1 } -- Darker red for negative amounts

RmTransactionLogFrame.CONTROLS = {
    "transactionTable",
    "tableSlider",
    "totalTransactionsLabel",
    "totalTransactionsValue",
    "buttonAddComment",
    "buttonClearLog",
    "buttonExportCSV"
}

---Creates a new RmTransactionLogFrame instance
---@param target table|nil the target object
---@param custom_mt table|nil optional custom metatable
---@return RmTransactionLogFrame the new frame instance
function RmTransactionLogFrame.new(target, custom_mt)
    RmUtils.logTrace("RmTransactionLogFrame:new()")
    local self = MessageDialog.new(target, custom_mt or RmTransactionLogFrame_mt)
    self.transactions = {}
    return self
end

function RmTransactionLogFrame:onGuiSetupFinished()
    RmUtils.logTrace("RmTransactionLogFrame:onGuiSetupFinished()")
    RmTransactionLogFrame:superClass().onGuiSetupFinished(self)
    self.transactionTable:setDataSource(self)
    self.transactionTable:setDelegate(self)
end

function RmTransactionLogFrame:onCreate()
    RmUtils.logTrace("RmTransactionLogFrame:onCreate()")
    RmTransactionLogFrame:superClass().onCreate(self)
end

function RmTransactionLogFrame:onOpen()
    RmUtils.logTrace("RmTransactionLogFrame:onOpen()")
    RmTransactionLogFrame:superClass().onOpen(self)

    -- Get transactions from the main transaction log
    if RmTransactionLog.transactions then
        self.transactions = RmTransactionLog.transactions
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

function RmTransactionLogFrame:onClose()
    RmUtils.logTrace("RmTransactionLogFrame:onClose()")
    self.transactions = {}
    RmTransactionLogFrame:superClass().onClose(self)
end

-- Table data source methods
function RmTransactionLogFrame:getNumberOfItemsInSection(list, section)
    if list == self.transactionTable then
        return #self.transactions
    else
        return 0
    end
end

function RmTransactionLogFrame:populateCellForItemInSection(list, section, index, cell)
    if list == self.transactionTable then
        local transaction = self.transactions[index]
        if transaction then
            -- Set transaction data in the cell
            cell:getAttribute("ingameDateTime"):setText(transaction.ingameDateTime or
                g_i18n:getText("ui_transaction_log_no_data"))
            cell:getAttribute("transactionStatistic"):setText(transaction.transactionStatistic or
                g_i18n:getText("ui_transaction_log_no_data"))

            -- Format amount and color
            local amount = transaction.amount or 0
            local amountText = string.format("%.2f", amount)
            local amountElement = cell:getAttribute("amount")
            amountElement:setText(amountText)

            -- Set color based on positive/negative amount
            if amount >= 0 then
                amountElement.textColor = RmTransactionLogFrame.POSITIVE_COLOR
            else
                amountElement.textColor = RmTransactionLogFrame.NEGATIVE_COLOR
            end

            -- Format and display farm balance
            local balance = transaction.currentFarmBalance or 0
            local balanceText = string.format("%.2f", balance)
            local balanceElement = cell:getAttribute("balance")
            balanceElement:setText(balanceText)

            -- Set color based on positive/negative balance
            if balance >= 0 then
                balanceElement.textColor = RmTransactionLogFrame.POSITIVE_COLOR
            else
                balanceElement.textColor = RmTransactionLogFrame.NEGATIVE_COLOR
            end

            cell:getAttribute("comment"):setText(transaction.comment or "")
        end
    end
end

-- Button handlers
function RmTransactionLogFrame:onClickClose()
    RmUtils.logTrace("RmTransactionLogFrame:onClickClose()")
    self:close()
end

---Shows dialog to add/edit comment for selected transaction
function RmTransactionLogFrame:onClickAddComment()
    RmUtils.logTrace("RmTransactionLogFrame:onClickAddComment()")

    -- Get the selected transaction
    local selectedIndex = self.transactionTable.selectedIndex
    if selectedIndex == nil or selectedIndex < 1 or selectedIndex > #self.transactions then
        RmUtils.logWarning("No transaction selected or invalid selection")
        return
    end

    local selectedTransaction = self.transactions[selectedIndex]
    if selectedTransaction then
        -- Create callback function to handle comment updates
        local function onCommentCallback(text, clickOk)
            if clickOk and text then
                -- Update the transaction in the main log
                if RmTransactionLog and RmTransactionLog.transactions and RmTransactionLog.transactions[selectedIndex] then
                    RmTransactionLog.transactions[selectedIndex].comment = text
                end

                -- Update local transactions and refresh display
                self.transactions[selectedIndex].comment = text
                self.transactionTable:reloadData()

                RmUtils.logDebug(string.format("Comment updated for transaction: %s", text))
            end
        end

        -- Show the comment dialog
        local existingComment = selectedTransaction.comment or ""
        local prompt = string.format(g_i18n:getText("ui_transaction_log_comment_prompt"),
            selectedTransaction.transactionType or g_i18n:getText("ui_transaction_log_unknown_type"),
            selectedTransaction.amount or 0)
        RmCommentInputDialog.show(onCommentCallback, nil, existingComment, prompt,
            RmTransactionLogFrame.MAX_COMMENT_LENGTH, nil)
    end
end

---Shows confirmation dialog to clear the transaction log
function RmTransactionLogFrame:onClickClearLog()
    RmUtils.logTrace("RmTransactionLogFrame:onClickClearLog()")

    -- Show confirmation dialog
    local confirmationText = string.format(g_i18n:getText("ui_transaction_log_clear_confirmation"), #self.transactions)

    YesNoDialog.show(self.onYesNoClearLog, self, confirmationText,
        g_i18n:getText("ui_transaction_log_clear_title"),
        g_i18n:getText("ui_transaction_log_clear_yes"),
        g_i18n:getText("ui_transaction_log_clear_no"))
end

function RmTransactionLogFrame:onYesNoClearLog(yes)
    if yes then
        -- Clear the transaction log
        if RmTransactionLog then
            RmTransactionLog.transactions = {}
            self.transactions = {}

            -- Update display
            self.totalTransactionsValue:setText("0")
            self.transactionTable:reloadData()

            RmUtils.logInfo("Transaction log cleared via GUI")
        end
    end
end

---Exports all transactions to a CSV file
function RmTransactionLogFrame:onClickExportCSV()
    RmUtils.logTrace("RmTransactionLogFrame:onClickExportCSV()")

    if #self.transactions == 0 then
        InfoDialog.show(g_i18n:getText("ui_transaction_log_export_no_data"))
        return
    end

    -- Use the exporter module to handle the export
    local success, message, filename = RmTransactionLogExporter.exportCurrentTransactions("manual")

    if success then
        -- Extract just the filename from the success message for display
        local csvFileName = filename or "transactions.csv"
        local directory = RmTransactionLogExporter.getExportDirectory() or ""

        -- Show user-friendly path for confirmation
        local displayPath = directory
        local modSettingsIndex = string.find(displayPath, "/modSettings/")
        local savegamePathIndex = string.find(displayPath, "/savegame")
        if modSettingsIndex then
            displayPath = string.sub(displayPath, modSettingsIndex)
        elseif savegamePathIndex then
            displayPath = string.sub(displayPath, savegamePathIndex)
        end

        local confirmationText = string.format(g_i18n:getText("ui_transaction_log_export_success"),
            #self.transactions, csvFileName, displayPath)
        InfoDialog.show(confirmationText)
    else
        RmUtils.logError("CSV export failed: " .. message)
        InfoDialog.show(g_i18n:getText("ui_transaction_log_export_error"))
    end
end

---Registers the transaction log frame with the GUI system
function RmTransactionLogFrame.register()
    RmUtils.logTrace("RmTransactionLogFrame.register()")
    local dialog = RmTransactionLogFrame.new(g_i18n)
    g_gui:loadGui(RmTransactionLog.dir .. "gui/RmTransactionLogFrame.xml", "RmTransactionLogFrame", dialog)
end

-- Static function to show the transaction log dialog
function RmTransactionLogFrame.showTransactionLog()
    RmUtils.logTrace("RmTransactionLogFrame.showTransactionLog()")

    -- Show the already registered dialog
    g_gui:showDialog("RmTransactionLogFrame")
end
