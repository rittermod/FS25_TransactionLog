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

-- Spectator farm (a player not in any farm). The engine reports farmId 0 for such a player; a
-- spectator has no farm log to show, so the frame shows a "join a farm" hint instead of an empty
-- table.
RmTransactionLogFrame.SPECTATOR_FARM_ID = 0

-- English fallback for the spectator hint, used when the l10n key is absent in the active locale
-- (getText would otherwise render the engine's "Missing '...'" placeholder). English-only is
-- intentional debt; other locales backfill via the translation workflow.
RmTransactionLogFrame.SPECTATOR_HINT_FALLBACK =
    "You are not a member of a farm. Join a farm to see its transaction log."

RmTransactionLogFrame.CONTROLS = {
    "transactionTable",
    "tableSlider",
    "totalTransactionsLabel",
    "totalTransactionsValue",
    "buttonAddComment",
    "buttonClearLog",
    "buttonExportCSV",
    "emptyHintText"
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

---Builds the GUI display list for a farm: the farm-filtered rows newest-first, plus the spectator
---flag. PURE (no self / no GUI framework), so the load-bearing logic - filter applied, sort order,
---hint decision - is unit-tested on real code. onOpen is a thin apply over this.
---@param transactions table|nil the master transaction list
---@param farmId number|nil the viewing farm (0 = spectator, nil = no local player)
---@return table rows farm-filtered rows sorted newest-first (ingameDateTime desc, id desc)
---@return boolean isSpectator true when farmId is the spectator farm (0)
function RmTransactionLogFrame.buildDisplayList(transactions, farmId)
    -- Same-reference rows (an id-resolved comment edit still lands on the master); a fresh array so
    -- sorting never scrambles the master's insertion (= ascending-id) order.
    local rows = RmTransactionLog.filterTransactionsByFarm(transactions, farmId)

    -- Newest first; deterministic within an equal minute by descending id.
    table.sort(rows, function(a, b)
        local ad, bd = a.ingameDateTime or "", b.ingameDateTime or ""
        if ad ~= bd then
            return ad > bd
        end
        return (a.id or 0) > (b.id or 0)
    end)

    return rows, farmId == RmTransactionLogFrame.SPECTATOR_FARM_ID
end

---Resolves the spectator-hint text, hasText-guarded so a missing key (non-English locale) renders
---the hardcoded English fallback rather than the engine's "Missing '...'" placeholder.
---@return string
function RmTransactionLogFrame.resolveSpectatorHint()
    local key = "ui_transaction_log_spectator_hint"
    if g_i18n ~= nil and g_i18n:hasText(key) then
        return g_i18n:getText(key)
    end
    return RmTransactionLogFrame.SPECTATOR_HINT_FALLBACK
end

function RmTransactionLogFrame:onOpen()
    Log:trace("RmTransactionLogFrame:onOpen()")
    RmTransactionLogFrame:superClass().onOpen(self)

    -- Farm-scope the view through the shared pure filter: defence-in-depth on a pure client (its
    -- store is already scoped by the join/switch snapshot) and a real narrowing on a listen-host
    -- whose master holds every farm. In SP getFarmId() is 1 and only farm 1 exists, so the filter
    -- is a no-op.
    local myFarmId = g_currentMission ~= nil and g_currentMission:getFarmId() or nil
    local rows, isSpectator = RmTransactionLogFrame.buildDisplayList(RmTransactionLog.transactions, myFarmId)
    self.transactions = rows

    -- Update total transactions display
    self.totalTransactionsValue:setText(tostring(#self.transactions))

    -- Spectator hint: shown only when the viewer is not in a farm (farm 0). A farm member with zero
    -- rows sees the normal empty table, no hint. Nil-guarded like RmCommentInputDialog's button
    -- visibility; a nil binding means a fat-fingered control id/profile, so surface it once rather
    -- than degrade silently to no-hint.
    if self.emptyHintText ~= nil then
        self.emptyHintText:setText(RmTransactionLogFrame.resolveSpectatorHint())
        self.emptyHintText:setVisible(isSpectator)
    elseif isSpectator then
        Log:warning("emptyHintText control missing; spectator hint not shown")
    end

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

    -- Count the MASTER, not the farm-filtered display: onYesNoClearLog wipes the whole master (all
    -- farms), so a listen-host must be told the true scope it is about to erase, never the smaller
    -- own-farm count. Clear stays a whole-log action here; the per-farm, admin-gated networked clear
    -- is a later task.
    local masterCount = RmTransactionLog.transactions and #RmTransactionLog.transactions or 0
    local confirmationText = string.format(g_i18n:getText("ui_transaction_log_clear_confirmation"), masterCount)

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

    -- Export only THIS client's farm, re-derived from the LIVE farm inside the exporter (so a stale
    -- display after a farm switch cannot leak or misreport). Branch on the exporter's own empty
    -- result, not the display count: the old #self.transactions pre-guard was stale (a
    -- switch-to-spectator with the dialog open leaves the display non-empty while the live-farm
    -- export is empty), which would wrongly show the generic error instead of "no data".
    local success, message, filename, exportedCount = RmTransactionLogExporter.exportCurrentFarmTransactions("manual")

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

        -- Report the count actually exported from the LIVE farm (the exporter's 4th return), not the
        -- display count, which can be stale relative to the live farm (mid-open farm switch / MP
        -- live-add). Falls back to the display count if the exporter did not report one.
        local confirmationText = string.format(g_i18n:getText("ui_transaction_log_export_success"),
            exportedCount or #self.transactions, csvFileName, displayPath)
        InfoDialog.show(confirmationText)
    elseif message == RmTransactionLogExporter.NO_DATA_MESSAGE then
        -- Nothing for this farm to export (spectator, or a farm with no rows) - the honest
        -- "no data" dialog, not the generic export error.
        InfoDialog.show(g_i18n:getText("ui_transaction_log_export_no_data"))
    else
        Log:error("CSV export failed: " .. tostring(message))
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
