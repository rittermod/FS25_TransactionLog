-- RmTransactionLogFrame.lua
-- Transaction log GUI frame for FS25 Transaction Log mod
-- Author: Ritter
-- Description: Displays transaction history in a GUI dialog

RmTransactionLogFrame = {}
local RmTransactionLogFrame_mt = Class(RmTransactionLogFrame, MessageDialog)
local Log = RmLogging.getLogger("TransactionLog")

-- Constants
-- Canonical comment length lives in RmTransactionLog (event-reachable); the frame references it so
-- the GUI input cap and the server-side clamp can never drift. main.lua orders the load
-- Settings -> RmTransactionLog -> this frame, so RmTransactionLog and its constant are defined before
-- this file is sourced; reordering it after the frame would nil-index the copy below at load.
RmTransactionLogFrame.MAX_COMMENT_LENGTH = RmTransactionLog.MAX_COMMENT_LENGTH

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

---Rebuilds the display list from the master and repaints the table + total + spectator hint. This
---is the DATA half of onOpen, extracted so RmTransactionLog.refreshOpenLog can repaint an already-open
---frame after a comment edit lands (locally or via the server's broadcast) without a reopen. Does NOT
---touch focus or the sound-suppressed bracket - those are open-time concerns only.
function RmTransactionLogFrame:refreshData()
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
end

function RmTransactionLogFrame:onOpen()
    Log:trace("RmTransactionLogFrame:onOpen()")
    RmTransactionLogFrame:superClass().onOpen(self)

    -- Mark the log open so RmTransactionLog.refreshOpenLog can repaint THIS instance after a comment
    -- edit lands (locally or via the server broadcast). Cleared in onClose. Independent of any g_gui
    -- name field (a dialog never sets currentGuiName).
    self.isLogOpen = true

    -- Role-gate the manager-only actions (TL-13): show Add Comment + Export only to a farm manager,
    -- hide them for a worker / spectator. In SP + on the listen-host the local player always resolves
    -- as a manager, so both stay visible (no SP regression). The button gate is UX; the server is the
    -- security boundary for the edit. setVisible(isManager) also re-shows on a later open of this
    -- reused instance. Nil-guarded like the emptyHintText binding: a nil control is a fat-fingered id.
    local isManager = RmTransactionLog.isLocalPlayerFarmManager()
    if self.buttonAddComment ~= nil then
        self.buttonAddComment:setVisible(isManager)
    end
    if self.buttonExportCSV ~= nil then
        self.buttonExportCSV:setVisible(isManager)
    end

    -- Admin-gate the destructive Clear Log (TL-15): show it only to an admin (master user), hide it for a
    -- worker / member / spectator. This CLOSES the TL-13 interim hazard (a non-manager kept a destructive
    -- Clear Log). Deliberately a separate gate from the manager one above: clearing is a whole-log
    -- (all-farms) master-user action, not a per-farm manager action. On SP + the listen-host getIsServer()
    -- is true, so it stays visible (no SP regression). Nil-guarded like the sibling buttons; the button gate
    -- is UX - the server master-user check is the security boundary.
    local isAdmin = RmTransactionLog.isLocalPlayerAdmin()
    if self.buttonClearLog ~= nil then
        self.buttonClearLog:setVisible(isAdmin)
    end

    self:refreshData()

    -- Set focus to the table
    self:setSoundSuppressed(true)
    FocusManager:setFocus(self.transactionTable)
    self:setSoundSuppressed(false)
end

function RmTransactionLogFrame:onClose()
    Log:trace("RmTransactionLogFrame:onClose()")
    self.isLogOpen = false
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

-- TEMPORARY (pre-TL-37 display surface): overlay the captured subject/location enrichment into the
-- comment column so coverage is eyeball-able during real gameplay before the dedicated GUI columns
-- (TL-20/21/37) land. PURE display synthesis - the stored `comment` field and all persisted data are
-- untouched (nothing here writes back, exports, or crosses the MP codec). Remove this whole helper and
-- restore `transaction.comment or ""` at the call site once real columns exist.
--   - subject only:                              "Barley"
--   - subject + location:                        "Barley @ Grain Elevator"
--   - batched (auto "Combined N transactions"):  replaced -> "Barley @ Grain Elevator (xN)"
--   - direct row + real user comment:            "Barley @ Grain Elevator | <comment>"
--   - no enrichment captured:                    the stored comment is shown unchanged
---@param transaction table the transaction record
---@return string display the string for the comment cell
function RmTransactionLogFrame.formatEnrichedComment(transaction)
    local subjectName = transaction.subjectName
    local locationName = transaction.locationName

    local enrichment = (subjectName ~= nil and subjectName ~= "") and subjectName or ""
    if locationName ~= nil and locationName ~= "" then
        enrichment = (enrichment ~= "" and (enrichment .. " @ ") or "@ ") .. locationName
    end

    local comment = transaction.comment or ""
    if enrichment == "" then
        -- Nothing captured for this row: leave the stored comment / "Combined N" as-is.
        return comment
    end

    -- Batched rows carry the auto-generated "Combined N transactions" (RmTransactionBatcher, English,
    -- not i18n) - replace it with the enrichment but keep the count compact as (xN).
    local combinedCount = string.match(comment, "^Combined (%d+) transactions$")
    if combinedCount ~= nil then
        return string.format("%s (x%s)", enrichment, combinedCount)
    end

    if comment == "" then
        return enrichment
    end
    -- Direct row with a real user comment: show the enrichment, keep the comment.
    return enrichment .. " | " .. comment
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

            cell:getAttribute("comment"):setText(RmTransactionLogFrame.formatEnrichedComment(transaction))
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

    -- Re-check the role gate at entry (TL-13): the button is hidden for a non-manager, but a keybind
    -- or focus path could still reach the handler, so bail defensively. The server re-validates the
    -- actual edit; this is client-side defense-in-depth.
    if not RmTransactionLog.isLocalPlayerFarmManager() then
        Log:debug("onClickAddComment: local player is not a farm manager; ignoring")
        return
    end

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
                -- Route the edit through the single server-authoritative request path (TL-13):
                -- it normalizes the comment, applies to the master by the captured STABLE id (never
                -- the display index), and - in MP on a pure client - asks the server to authorize
                -- (owning farm + farmManager role) and fan the clamped value out to the farm's
                -- members. In SP / on the listen-host it applies directly. Keep the local reloadData
                -- so THIS frame repaints immediately; the request path also repaints via
                -- refreshOpenLog, and the two are idempotent.
                RmTransactionLog.requestCommentEdit(targetId, text)
                self.transactionTable:reloadData()
                Log:debug(string.format("Comment edit requested for transaction id=%s: %s",
                    tostring(targetId), text))
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

    -- Re-check the admin gate at entry (TL-15): the button is hidden for a non-admin, but a keybind or
    -- focus path could still reach the handler, so bail defensively before the confirm dialog. Mirrors
    -- onClickAddComment / onClickExportCSV. The server re-validates the actual clear; this is client-side
    -- defense-in-depth.
    if not RmTransactionLog.isLocalPlayerAdmin() then
        Log:debug("onClickClearLog: local player is not an admin; ignoring")
        return
    end

    -- Count the MASTER, not the farm-filtered display: onYesNoClearLog wipes the whole master (all
    -- farms), so a listen-host must be told the true scope it is about to erase, never the smaller
    -- own-farm count.
    local masterCount = RmTransactionLog.transactions and #RmTransactionLog.transactions or 0
    local confirmationText = string.format(g_i18n:getText("ui_transaction_log_clear_confirmation"), masterCount)

    YesNoDialog.show(self.onYesNoClearLog, self, confirmationText,
        g_i18n:getText("ui_transaction_log_clear_title"),
        g_i18n:getText("ui_transaction_log_clear_yes"),
        g_i18n:getText("ui_transaction_log_clear_no"))
end

function RmTransactionLogFrame:onYesNoClearLog(yes)
    if yes and RmTransactionLog then
        -- Route the clear through the single server-authoritative request path (TL-15): on the authority
        -- (SP / listen-host) it wipes the master + broadcasts globally; on a pure client it sends the
        -- request and waits for the server's echoed broadcast (NO optimistic local wipe - a destructive
        -- clear waits for confirmation). refreshData rebuilds the display list from the master, updates the
        -- total, and reloads the table: on the authority path the master is already wiped so the frame
        -- repaints to zero at once; on a pure client it repaints the still-full list until the server echo's
        -- refreshOpenLog repaints it (near-instant on a reliable, ordered channel).
        RmTransactionLog.requestClearLog()
        self:refreshData()
        Log:info("Transaction log clear requested via GUI")
    end
end

---Exports all transactions to a CSV file
function RmTransactionLogFrame:onClickExportCSV()
    Log:trace("RmTransactionLogFrame:onClickExportCSV()")

    -- Re-check the role gate at entry (TL-13): the button is hidden for a non-manager, but a keybind
    -- or focus path could still reach the handler, so bail defensively. Export is client-local; this
    -- keeps a worker from exporting via a stray path, matching the Add Comment gate.
    if not RmTransactionLog.isLocalPlayerFarmManager() then
        Log:debug("onClickExportCSV: local player is not a farm manager; ignoring")
        return
    end

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
    -- Keep the singleton instance so RmTransactionLog.refreshOpenLog can repaint it after a comment
    -- edit lands while it is open (mirrors RmCommentInputDialog.INSTANCE). One dialog is created here
    -- and reused across every showDialog, so this reference stays valid for the session.
    RmTransactionLogFrame.INSTANCE = dialog
end

-- Static function to show the transaction log dialog
function RmTransactionLogFrame.showTransactionLog()
    Log:trace("RmTransactionLogFrame.showTransactionLog()")

    -- Show the already registered dialog
    g_gui:showDialog("RmTransactionLogFrame")
end
