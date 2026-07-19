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
    "buttonCycleView",
    "buttonBox",
    "emptyHintText"
}

-- Timeframe view modes (TL-49). The log can roll the already-farm-filtered rows up by time. Individual
-- shows raw transactions newest-first (behaviourally unchanged from earlier versions); the three combined
-- modes group + net-sum by (truncated date, statistic, subject-identity, location-identity). DISPLAY-ONLY:
-- no data-model / persistence / MP-codec / batching / capture change.
RmTransactionLogFrame.VIEW_MODE = {
    INDIVIDUAL = "individual",
    DAY = "day",
    PERIOD = "period",
    YEAR = "year",
}

-- Cycle order: the button (or MENU_EXTRA_2) advances Individual -> Day -> Period -> Year -> (wrap).
RmTransactionLogFrame.VIEW_MODE_ORDER = {
    RmTransactionLogFrame.VIEW_MODE.INDIVIDUAL,
    RmTransactionLogFrame.VIEW_MODE.DAY,
    RmTransactionLogFrame.VIEW_MODE.PERIOD,
    RmTransactionLogFrame.VIEW_MODE.YEAR,
}

-- Date-prefix length per COMBINED mode of the stored "YYYY-MM-DD HH:MM": Day = "YYYY-MM-DD" (10),
-- Period = "YYYY-MM" (7, one bucket per in-game period projected to a 1-12 calendar month), Year = "YYYY"
-- (4). Individual is intentionally absent (the caller never truncates in Individual mode).
RmTransactionLogFrame.VIEW_MODE_DATE_LEN = {
    [RmTransactionLogFrame.VIEW_MODE.DAY] = 10,
    [RmTransactionLogFrame.VIEW_MODE.PERIOD] = 7,
    [RmTransactionLogFrame.VIEW_MODE.YEAR] = 4,
}

-- l10n key for each mode's name, interpolated into the cycle-button label ("View: %s").
RmTransactionLogFrame.VIEW_MODE_LABEL_KEY = {
    [RmTransactionLogFrame.VIEW_MODE.INDIVIDUAL] = "ui_view_individual",
    [RmTransactionLogFrame.VIEW_MODE.DAY] = "ui_view_day",
    [RmTransactionLogFrame.VIEW_MODE.PERIOD] = "ui_view_period",
    [RmTransactionLogFrame.VIEW_MODE.YEAR] = "ui_view_year",
}

-- Session view mode: MODULE-LEVEL state (default Individual), remembered across dialog open/close for the
-- process because INSTANCE is created once and reused. NOT persisted to disk - a mid-session load of
-- another save keeps it; a game restart resets it to Individual. onOpen READS it, never resets it.
RmTransactionLogFrame.viewMode = RmTransactionLogFrame.VIEW_MODE.INDIVIDUAL

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

---Truncates a stored ingameDateTime ("YYYY-MM-DD HH:MM") to the bucket prefix for a COMBINED view mode.
---Pure and raise-free: a non-string dt, or an Individual/unknown mode (no length in VIEW_MODE_DATE_LEN),
---returns dt UNCHANGED. The stored string is already the calendar-projected date (the mod rolls the year
---in March, so Jan/Feb rows carry the next stored YYYY) - truncation needs no extra date maths.
---@param ingameDateTime any the stored datetime (normally a string; guarded for non-string)
---@param viewMode string one of RmTransactionLogFrame.VIEW_MODE
---@return any truncated the Day(10)/Period(7)/Year(4) prefix, or dt unchanged
function RmTransactionLogFrame.truncateDateTime(ingameDateTime, viewMode)
    local len = RmTransactionLogFrame.VIEW_MODE_DATE_LEN[viewMode]
    if len ~= nil and type(ingameDateTime) == "string" then
        return string.sub(ingameDateTime, 1, len)
    end
    return ingameDateTime
end

-- Collision-safe length-prefixed segment, mirroring RmTransactionBatcher.createBatchKey's `seg`: "" and
-- nil both collapse to "0:", and the length prefix means no value (an embedded "|"/":", or the literal
-- "nil") can alias a different composite into the same key. Kept private to this file.
local function keySegment(v)
    v = (v ~= nil and v ~= "") and tostring(v) or ""
    return string.format("%d:%s", #v, v)
end

-- Identity-dominant component: a stable id wins, else the name snapshot, else "" (absent). "" and nil key
-- identically (matching the row-level normalization), so a same-name/both-nil-id pair merges - it is
-- indistinguishable anyway - while distinct ids never merge even under equal names. Mirrors createBatchKey's
-- id-dominant location idiom; full same-name disambiguation is TL-30.
local function identityComponent(id, name)
    if id ~= nil and id ~= "" then return tostring(id) end
    if name ~= nil and name ~= "" then return tostring(name) end
    return ""
end

---Aggregates already-farm-filtered rows into one synthetic display row per
---(truncatedDate, statistic, subject-identity, location-identity) group, for a COMBINED view mode
---(Day/Period/Year). Individual mode is handled by the caller, never here. NOT pure in the strict sense:
---it reads RmTransactionLog.resolveStatistic (g_i18n) ONLY to build the Type SORT key, so a locale switch
---re-sorts but never re-buckets (grouping stays on the raw `statistic`). Defensive and raise-free on
---malformed rows (they degrade, they do not crash the open).
---
---Each returned synthetic row carries the fields populateCellForItemInSection reads - ingameDateTime
---(truncated), statistic, amount (2dp net sum), subjectName, locationName, comment="", currentFarmBalance
---(the bucket's CLOSING balance) - PLUS showBalance (bool). It carries NO id (aggregate rows are
---display-only; the action handlers bail in combined modes and selection is reset).
---
---Ordering: outer buckets by truncatedDate DESCENDING (lexicographic == chronological on the zero-padded
---format; a non-string / empty date buckets as "" and sorts last); inner rows by a strict TOTAL-order
---content key (resolveStatistic lower, subjectName lower, locationName lower, then the raw group key). The
---balance VALUE is the bucket's closing balance (currentFarmBalance of the newest (ingameDateTime, id) txn
---in that DATE bucket); its PLACEMENT is the bucket's topmost total-order row only (value and placement are
---decoupled by design). Every other row in the bucket gets showBalance=false.
---@param rows table|nil the farm-filtered rows
---@param viewMode string one of DAY / PERIOD / YEAR
---@return table aggregated synthetic display rows, ordered bucket-desc then inner total-order
function RmTransactionLogFrame.aggregateByTimeframe(rows, viewMode)
    -- groups[compositeKey] = accumulated synthetic row; bucketClose[truncatedDate] = { dt, id, balance }
    -- of the newest transaction seen in that DATE bucket (across all its groups).
    local groups = {}
    local order = {}          -- insertion order of group keys (stable base before sorting)
    local bucketClose = {}

    for _, r in ipairs(rows or {}) do
        local dt = r.ingameDateTime
        -- Bucket date is ALWAYS a string: a non-string dt truncates to "" (sorts last), never raising in
        -- the string comparators below.
        local truncated = RmTransactionLogFrame.truncateDateTime(dt, viewMode)
        if type(truncated) ~= "string" then
            truncated = ""
        end

        local subjectComponent = identityComponent(r.subjectId, r.subjectName)
        local locationComponent = identityComponent(r.locationId, r.locationName)
        local statisticKey = r.statistic
        local compositeKey = keySegment(truncated) .. keySegment(statisticKey)
            .. keySegment(subjectComponent) .. keySegment(locationComponent)

        local group = groups[compositeKey]
        if group == nil then
            group = {
                ingameDateTime = truncated,
                truncatedDate = truncated,
                statistic = statisticKey,
                subjectName = r.subjectName,
                locationName = r.locationName,
                comment = "",
                amount = 0,
                groupKey = compositeKey,
                -- Precomputed strict-total-order sort keys (computed ONCE per group, not per comparator
                -- call). resolveStatistic reads g_i18n; subject/location use the raw name snapshots.
                typeSort = string.lower(RmTransactionLog.resolveStatistic(statisticKey) or ""),
                subjectSort = string.lower(r.subjectName or ""),
                locationSort = string.lower(r.locationName or ""),
            }
            groups[compositeKey] = group
            order[#order + 1] = group
        end
        -- Net sum; a nil amount contributes 0.
        group.amount = group.amount + (r.amount or 0)

        -- Track the DATE bucket's closing balance = the newest (ingameDateTime, id) transaction's balance.
        -- Compare on the RAW full datetime (guarded to "" for non-string), then id. On a FULL (dt, id) tie
        -- (e.g. two nil-id rows both coercing to 0) the strict `>` keeps the FIRST-seen row's balance, i.e.
        -- master insertion order - stable because filterTransactionsByFarm preserves the master's
        -- ascending-id order.
        local rowDt = type(dt) == "string" and dt or ""
        local rowId = r.id or 0
        local close = bucketClose[truncated]
        if close == nil or rowDt > close.dt or (rowDt == close.dt and rowId > close.id) then
            bucketClose[truncated] = { dt = rowDt, id = rowId, balance = r.currentFarmBalance or 0 }
        end
    end

    -- Round each net sum to 2dp, mirroring RmTransactionLog.logTransaction's amount rounding, so float drift
    -- never shows e.g. -149.99999. Also stamp each group with its bucket's closing balance (value only;
    -- placement is decided after sorting).
    for _, group in ipairs(order) do
        group.amount = math.floor(group.amount * 100 + 0.5) / 100
        local close = bucketClose[group.truncatedDate]
        group.currentFarmBalance = close ~= nil and close.balance or 0
    end

    -- Order: outer bucket DESC, then the strict total-order inner content key. The raw group-key tail makes
    -- the comparator a strict total order even when two distinct statistic keys resolve to the same Type
    -- text, so a line holds the same slot in every bucket.
    table.sort(order, function(a, b)
        if a.truncatedDate ~= b.truncatedDate then
            return a.truncatedDate > b.truncatedDate
        end
        if a.typeSort ~= b.typeSort then
            return a.typeSort < b.typeSort
        end
        if a.subjectSort ~= b.subjectSort then
            return a.subjectSort < b.subjectSort
        end
        if a.locationSort ~= b.locationSort then
            return a.locationSort < b.locationSort
        end
        return a.groupKey < b.groupKey
    end)

    -- Mark the balance placement: only the first (topmost total-order) row of each DATE bucket shows it.
    local seenBucket = {}
    for _, group in ipairs(order) do
        group.showBalance = seenBucket[group.truncatedDate] ~= true
        seenBucket[group.truncatedDate] = true
    end

    return order
end

---Builds the GUI display list for a farm: the farm-filtered rows for the given view mode, plus the
---spectator flag. PURE (no self / no GUI framework), so the load-bearing logic - filter applied, sort
---order / aggregation, hint decision - is unit-tested on real code. onOpen/refreshData are a thin apply
---over this.
---@param transactions table|nil the master transaction list
---@param farmId number|nil the viewing farm (0 = spectator, nil = no local player)
---@param viewMode string|nil one of VIEW_MODE (default Individual)
---@return table rows Individual: farm-filtered rows newest-first (ingameDateTime desc, id desc); combined:
---                  aggregated synthetic rows
---@return boolean isSpectator true when farmId is the spectator farm (0)
---@return number sourceCount the count of UNDERLYING farm-filtered transactions (BEFORE any aggregation),
---                  so the "Total Transactions" footer stays honest in a combined mode (where #rows is the
---                  bucket count, not the transaction count). Equals #rows in Individual mode.
function RmTransactionLogFrame.buildDisplayList(transactions, farmId, viewMode)
    viewMode = viewMode or RmTransactionLogFrame.VIEW_MODE.INDIVIDUAL

    -- Same-reference rows (an id-resolved comment edit still lands on the master); a fresh array so
    -- sorting never scrambles the master's insertion (= ascending-id) order.
    local rows = RmTransactionLog.filterTransactionsByFarm(transactions, farmId)
    local isSpectator = farmId == RmTransactionLogFrame.SPECTATOR_FARM_ID
    -- The true underlying transaction count for the footer, captured BEFORE a combined mode collapses the
    -- rows into buckets.
    local sourceCount = #rows

    if viewMode ~= RmTransactionLogFrame.VIEW_MODE.INDIVIDUAL then
        -- Combined mode: collapse into one synthetic row per timeframe/type/subject/location bucket. The
        -- spectator flag AND the pre-aggregation source count are STILL returned so the caller's hint logic
        -- and the "Total Transactions" footer stay correct.
        return RmTransactionLogFrame.aggregateByTimeframe(rows, viewMode), isSpectator, sourceCount
    end

    -- Individual mode (unchanged): newest first; deterministic within an equal minute by descending id.
    table.sort(rows, function(a, b)
        local ad, bd = a.ingameDateTime or "", b.ingameDateTime or ""
        if ad ~= bd then
            return ad > bd
        end
        return (a.id or 0) > (b.id or 0)
    end)

    return rows, isSpectator, sourceCount
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
    local rows, isSpectator, sourceCount = RmTransactionLogFrame.buildDisplayList(
        RmTransactionLog.transactions, myFarmId, RmTransactionLogFrame.viewMode)
    self.transactions = rows

    -- Update total transactions display. Show the UNDERLYING transaction count (buildDisplayList's 3rd
    -- return), NOT #self.transactions: in a combined mode the latter is the bucket count, which would
    -- mislabel the fixed "Total Transactions" footer. In Individual mode the two are equal.
    self.totalTransactionsValue:setText(tostring(sourceCount or #self.transactions))

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

    -- Apply the action-button gating for the current (READ, not reset) session view mode, and set the
    -- cycle-button label to match. In a combined mode the three action buttons are hidden regardless of
    -- role; in Individual they follow today's manager/admin gating.
    self:updateActionButtonVisibility()
    self:updateCycleButtonLabel()

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

---Applies the action-button visibility for the current session view mode, then re-flows the button box.
---Add Comment / Export / Clear Log show ONLY in Individual mode AND with today's manager/admin gating;
---they hide in every combined mode. In SP + on the listen-host the local player resolves as manager/admin
---so Individual mode is unchanged from today. Each button is nil-guarded (a nil binding is a fat-fingered
---control id). The button box does not re-flow on its own when a child's visibility changes, so a
---mid-session toggle must invalidate the id'd box explicitly or the remaining buttons keep their old slots.
function RmTransactionLogFrame:updateActionButtonVisibility()
    local isIndividual = RmTransactionLogFrame.viewMode == RmTransactionLogFrame.VIEW_MODE.INDIVIDUAL
    local isManager = RmTransactionLog.isLocalPlayerFarmManager()
    local isAdmin = RmTransactionLog.isLocalPlayerAdmin()

    if self.buttonAddComment ~= nil then
        self.buttonAddComment:setVisible(isIndividual and isManager)
    end
    if self.buttonExportCSV ~= nil then
        self.buttonExportCSV:setVisible(isIndividual and isManager)
    end
    if self.buttonClearLog ~= nil then
        self.buttonClearLog:setVisible(isIndividual and isAdmin)
    end

    if self.buttonBox ~= nil then
        self.buttonBox:invalidateLayout()
    end
end

---Sets the cycle-button text to "View: <mode name>" for the current session view mode. Nil-guarded (the
---button may be absent on a fat-fingered id). pcall-guards the format against a malformed
---ui_button_cycle_view translation in a non-English locale (mirrors onClickAddComment's prompt guard).
function RmTransactionLogFrame:updateCycleButtonLabel()
    if self.buttonCycleView == nil then
        return
    end
    local modeKey = RmTransactionLogFrame.VIEW_MODE_LABEL_KEY[RmTransactionLogFrame.viewMode]
        or RmTransactionLogFrame.VIEW_MODE_LABEL_KEY[RmTransactionLogFrame.VIEW_MODE.INDIVIDUAL]
    -- g_i18n nil-guard, matching resolveSpectatorHint's convention: fall back to the raw mode key so a
    -- missing g_i18n (or a getText raise) never crashes onOpen. In normal play g_i18n is always present.
    if g_i18n == nil then
        self.buttonCycleView:setText(modeKey)
        return
    end
    local modeName = g_i18n:getText(modeKey)
    local ok, label = pcall(string.format, g_i18n:getText("ui_button_cycle_view"), modeName)
    self.buttonCycleView:setText(ok and label or modeName)
end

---Advances the session view mode along VIEW_MODE_ORDER (Individual -> Day -> Period -> Year -> wrap),
---relabels the button, re-applies action-button visibility, resets the list selection, and repaints. The
---mode is MODULE-LEVEL so it survives dialog re-open. Returns true to mark the input event consumed.
function RmTransactionLogFrame:onClickCycleView()
    Log:trace("RmTransactionLogFrame:onClickCycleView()")

    local order = RmTransactionLogFrame.VIEW_MODE_ORDER
    local currentIndex = nil
    for i = 1, #order do
        if order[i] == RmTransactionLogFrame.viewMode then
            currentIndex = i
            break
        end
    end
    -- Advance with wrap; a viewMode somehow absent from the order falls back to the first entry (Individual).
    local nextIndex = (currentIndex ~= nil) and ((currentIndex % #order) + 1) or 1
    RmTransactionLogFrame.viewMode = order[nextIndex]

    self:updateCycleButtonLabel()
    self:updateActionButtonVisibility()

    -- Reset selection to the top: the row count AND meaning change with the mode, so a carried selectedIndex
    -- could address a row that no longer exists. reloadData (via refreshData) re-clamps; 1 matches the
    -- SmoothList default. Aggregate rows carry no id, so they are never edit-addressable regardless.
    self.transactionTable.selectedIndex = 1
    self:refreshData()

    return true
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

            -- Format and display farm balance. In a combined view a bucket shows its CLOSING balance ONCE,
            -- on its topmost row (showBalance); the rest set showBalance=false. SmoothList RECYCLES cell
            -- instances, so BOTH the text AND the color must be set on EVERY render, on BOTH branches - else
            -- a blanked row would keep a stale colored balance from the row previously painted into that cell.
            -- Individual rows carry no showBalance (nil), so they always show the balance (unchanged).
            local balanceElement = cell:getAttribute("balance")
            if transaction.showBalance == false then
                balanceElement:setText("")
                balanceElement.textColor = RmTransactionLogFrame.POSITIVE_COLOR
            else
                local balance = transaction.currentFarmBalance or 0
                balanceElement:setText(string.format("%.2f", balance))
                if balance >= 0 then
                    balanceElement.textColor = RmTransactionLogFrame.POSITIVE_COLOR
                else
                    balanceElement.textColor = RmTransactionLogFrame.NEGATIVE_COLOR
                end
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

    -- Defense-in-depth (TL-49): Add Comment is meaningless on aggregate rows (they carry no id), and the
    -- button is hidden in combined modes, but a focus/selection path or future refactor could still reach
    -- the handler - bail unless in Individual mode.
    if RmTransactionLogFrame.viewMode ~= RmTransactionLogFrame.VIEW_MODE.INDIVIDUAL then
        Log:debug("onClickAddComment: not in Individual view mode; ignoring")
        return
    end

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

    -- Defense-in-depth (TL-49): Clear Log is hidden in combined modes; bail unless in Individual mode so a
    -- stray focus/keybind path cannot reach the destructive confirm from an aggregate view.
    if RmTransactionLogFrame.viewMode ~= RmTransactionLogFrame.VIEW_MODE.INDIVIDUAL then
        Log:debug("onClickClearLog: not in Individual view mode; ignoring")
        return
    end

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

    -- Defense-in-depth (TL-49): Export stays raw individual rows and is hidden in combined modes; bail
    -- unless in Individual mode so an aggregate view never triggers an export.
    if RmTransactionLogFrame.viewMode ~= RmTransactionLogFrame.VIEW_MODE.INDIVIDUAL then
        Log:debug("onClickExportCSV: not in Individual view mode; ignoring")
        return
    end

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
