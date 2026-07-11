-- RmTransactionLogFrame.lua
-- Transaction log GUI frame for FS25 Transaction Log mod
-- Author: Ritter
-- Description: Displays transaction history in a GUI dialog

RmTransactionLogFrame = {}
local RmTransactionLogFrame_mt = Class(RmTransactionLogFrame, MessageDialog)
local Log = RmLogging.getLogger("TransactionLog")

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
    Log:trace("RmTransactionLogFrame:new()")
    local self = MessageDialog.new(target, custom_mt or RmTransactionLogFrame_mt)
    self.transactions = {}
    return self
end

function RmTransactionLogFrame:onGuiSetupFinished()
    Log:trace("RmTransactionLogFrame:onGuiSetupFinished()")
    RmTransactionLogFrame:superClass().onGuiSetupFinished(self)
    self.transactionTable:setDataSource(self)
    self.transactionTable:setDelegate(self)
end

function RmTransactionLogFrame:onCreate()
    Log:trace("RmTransactionLogFrame:onCreate()")
    RmTransactionLogFrame:superClass().onCreate(self)
end

function RmTransactionLogFrame:onOpen()
    Log:trace("RmTransactionLogFrame:onOpen()")
    RmTransactionLogFrame:superClass().onOpen(self)

    -- Build the display list as a SHALLOW COPY of the master log: elements stay
    -- references to the master records (so an id-resolved comment edit still lands),
    -- but sorting the copy never scrambles the master's insertion order.
    self.transactions = {}
    if RmTransactionLog.transactions then
        for i, transaction in ipairs(RmTransactionLog.transactions) do
            self.transactions[i] = transaction
        end
        -- Newest first; deterministic within an equal minute by descending id.
        table.sort(self.transactions, function(a, b)
            local ad, bd = a.ingameDateTime or "", b.ingameDateTime or ""
            if ad ~= bd then
                return ad > bd
            end
            return (a.id or 0) > (b.id or 0)
        end)
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
    Log:trace("RmTransactionLogFrame:onClose()")
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
            -- Resolve the stored statistic key to the active language at render time.
            cell:getAttribute("transactionStatistic"):setText(
                RmTransactionLog.resolveStatistic(transaction.statistic))

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
    Log:trace("RmTransactionLogFrame:onClickClose()")
    self:close()
end

---Shows dialog to add/edit comment for selected transaction
function RmTransactionLogFrame:onClickAddComment()
    Log:trace("RmTransactionLogFrame:onClickAddComment()")

    -- Get the selected transaction
    local selectedIndex = self.transactionTable.selectedIndex
    if selectedIndex == nil or selectedIndex < 1 or selectedIndex > #self.transactions then
        Log:warning("No transaction selected or invalid selection")
        return
    end

    local selectedTransaction = self.transactions[selectedIndex]
    if selectedTransaction then
        -- Address the row by its stable id, not the display index: the display list is a
        -- sorted copy, so selectedIndex does not map to the master's insertion order. This
        -- is the addressing pattern TL-9's network layer builds on.
        local targetId = selectedTransaction.id

        -- Create callback function to handle comment updates
        local function onCommentCallback(text, clickOk)
            if clickOk and text then
                -- Resolve the master row by id (first match wins, defending against a stray
                -- duplicate). In SP the display holds live master references so this always
                -- succeeds; a miss is a defensive WARNING + no-op, never silent data loss.
                local target = nil
                if RmTransactionLog and RmTransactionLog.transactions then
                    for _, row in ipairs(RmTransactionLog.transactions) do
                        if row.id == targetId then
                            target = row
                            break
                        end
                    end
                end

                if target then
                    target.comment = text
                    self.transactionTable:reloadData()
                    Log:debug(string.format("Comment updated for transaction id=%s: %s",
                        tostring(targetId), text))
                else
                    Log:warning("Comment edit: no transaction with id=%s (no-op)", tostring(targetId))
                end
            end
        end

        -- Resolve the stored type key for the prompt. pcall-guard the format against a
        -- malformed comment-prompt translation (bad specifier / wrong arg count); a '%'
        -- inside the interpolated type argument is itself harmless in Lua string.format.
        local typeText = RmTransactionLog.resolveType(selectedTransaction.title,
            selectedTransaction.customEnv, selectedTransaction.constant)
        local existingComment = selectedTransaction.comment or ""
        local ok, prompt = pcall(string.format, g_i18n:getText("ui_transaction_log_comment_prompt"),
            typeText, selectedTransaction.amount or 0)
        if not ok then
            prompt = typeText
        end
        RmCommentInputDialog.show(onCommentCallback, nil, existingComment, prompt,
            RmTransactionLogFrame.MAX_COMMENT_LENGTH, nil)
    end
end

---Shows confirmation dialog to clear the transaction log
function RmTransactionLogFrame:onClickClearLog()
    Log:trace("RmTransactionLogFrame:onClickClearLog()")

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

            Log:info("Transaction log cleared via GUI")
        end
    end
end

---Exports all transactions to a CSV file
function RmTransactionLogFrame:onClickExportCSV()
    Log:trace("RmTransactionLogFrame:onClickExportCSV()")

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
        Log:error("CSV export failed: " .. message)
        InfoDialog.show(g_i18n:getText("ui_transaction_log_export_error"))
    end
end

---Registers the transaction log frame with the GUI system
function RmTransactionLogFrame.register()
    Log:trace("RmTransactionLogFrame.register()")
    local dialog = RmTransactionLogFrame.new(g_i18n)
    g_gui:loadGui(RmTransactionLog.dir .. "gui/RmTransactionLogFrame.xml", "RmTransactionLogFrame", dialog)
end

-- Static function to show the transaction log dialog
function RmTransactionLogFrame.showTransactionLog()
    Log:trace("RmTransactionLogFrame.showTransactionLog()")

    -- Show the already registered dialog
    g_gui:showDialog("RmTransactionLogFrame")
end
