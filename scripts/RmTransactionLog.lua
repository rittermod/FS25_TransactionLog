-- RmTransactionLog.lua
-- Main transaction logging system for FS25 Transaction Log mod
-- Author: Ritter
-- Description: Tracks and logs financial transactions in Farming Simulator 25

RmTransactionLog = {}
local RmTransactionLog_mt = Class(RmTransactionLog)

-- Constants
RmTransactionLog.START_YEAR = 2025      -- Start year for the transaction log (Year 1 = 2025)
RmTransactionLog.UPDATE_INTERVAL = 1000 -- Check batches every 1 second (1000ms)

-- Canonical maximum comment length (codepoints). This is the SINGLE source of truth for the
-- 200-char cap: the GUI input dialog references it (RmTransactionLogFrame.MAX_COMMENT_LENGTH) and
-- the server-authoritative edit path re-clamps to it, so a crafted RmEditCommentEvent can never
-- persist an oversized comment. Defined at load so the frame can read it: main.lua orders this
-- module ahead of gui/RmTransactionLogFrame, which copies the constant at load time.
RmTransactionLog.MAX_COMMENT_LENGTH = 200

-- Table to store transactions at the module level.
-- This mod is single instance.
RmTransactionLog.transactions = {}

-- Settings system
RmTransactionLog.CONTROLS = {}
RmTransactionLog.settings = nil -- Will be initialized in loadMap

-- Auto-export date tracking system
RmTransactionLog.previousDate = nil          -- Format: "YYYY-MM-DD"
RmTransactionLog.previousCalendarMonth = nil -- Format: "YYYY-MM"
RmTransactionLog.previousCalendarYear = nil  -- Format: "YYYY"

-- Pending-context holder (TL-19; extended TL-36): a synchronous set/consume-once channel that hands a
-- subject (WHAT) and a location (WHERE) from a call-site into the universal Farm.changeBalance sink,
-- which sees only farm / amount / moneyType. A call-site prepend-hook sets these IMMEDIATELY before the
-- intended addMoney; changeFarmBalance consumes them once at entry (clearing all FIVE) and threads them
-- into BOTH the DIRECT logTransaction record AND (TL-22) the batchable addToBatch call. Storage is FIVE
-- scalar module fields behind a RECORD-shaped API (TL-36 decision 2a): setPendingContext(context) reads
-- context.<field>, consumePendingContext() RETURNS a record + clears the scalars. Default nil; set on the
-- authority only (setPendingContext is g_server-guarded). SellingStation sales (subject TL-26, location
-- TL-25), animal trades (TL-23), shop buy/sell (TL-24), production direct-sells (subject + location,
-- TL-28), and BuyingStation input purchases (subject, TL-27) set context via capture hooks; the deferred
-- FillTrigger / AI-helper input paths (TL-44) still record no subject.
RmTransactionLog.pendingSubjectId = nil    -- best-effort key: fillType/animal name, store-item xmlFilename, or nil (verbatim)
RmTransactionLog.pendingSubjectName = nil  -- always-set display snapshot (capture-hook contract; verbatim)
RmTransactionLog.pendingSubjectKind = nil  -- open-vocab kind: fillType/animal/storeItem seeds (verbatim)
RmTransactionLog.pendingLocationId = nil   -- placeable uniqueId string, SellingStation sales since TL-25, production direct-sells since TL-28 (verbatim)
RmTransactionLog.pendingLocationName = nil -- placeable display-name snapshot, SellingStation sales since TL-25, production direct-sells since TL-28 (verbatim)

---Creates a new RmTransactionLog instance
---@param customMt table|nil optional custom metatable
---@return table the new transaction log instance
function RmTransactionLog.new(customMt)
    local self = setmetatable({}, customMt or RmTransactionLog_mt)
    self.transactions = RmTransactionLog.transactions -- Reference to shared transaction table
    return self
end

-- Mod directory, read at RUNTIME by the GUI-load sites (RmTransactionLog.showDialog,
-- RmTransactionLogFrame, RmCommentInputDialog). This is NOT used for sourcing: main.lua owns the
-- load order and sources every module via its own g_currentModDirectory.
RmTransactionLog.dir = g_currentModDirectory

local Log = RmLogging.getLogger("TransactionLog")
Log:setLevel("DEBUG") -- Uncomment to enable debug logging
-- Log:setLevel("TRACE")  -- Uncomment to enable trace logging

-- Schema version stamped on the root of the persisted transaction file. Bumped to
-- 2 for the key-based storage model (snapshot money-type keys, resolve on display).
RmTransactionLog.SCHEMA_VERSION = 2

-- Server-side monotonic Int32 allocator for stable per-row transaction ids. Assigned
-- in logTransaction (one id per FINAL row, batched rows numbered at flush), persisted
-- as an additive `#id` attribute, and reconstructed as max+1 on load (single source of
-- truth - never persisted as its own attribute). Set unconditionally on every load exit
-- path; intentionally NOT reset when the log is cleared, so ids stay monotonic across a
-- clear and a late batch flush can never reuse one.
RmTransactionLog.nextTransactionId = 1

-- Lazily-built map from a money type's runtime id to its MoneyType constant name
-- (e.g. 60 -> "VEHICLE_RUNNING_COSTS"). Built on first capture, post-registration.
RmTransactionLog.moneyTypeConstantById = nil

-- ============================================================
-- Money-type identity + display resolution
-- ============================================================

---Builds an id->constant-name map from a MoneyType-like table.
---A money type value is a table carrying an `id`; the constant is the field name
---it is stored under (MoneyType.OTHER etc.). Aliases (two names, same id) resolve
---deterministically to the lexicographically smallest name so a captured constant
---is stable across sessions.
---@param moneyTypeTable table the MoneyType table (or a fixture with the same shape)
---@return table map id (number) -> constant name (string)
function RmTransactionLog.buildMoneyTypeConstantMap(moneyTypeTable)
    local map = {}
    for name, value in pairs(moneyTypeTable) do
        if type(value) == "table" and value.id ~= nil then
            local existing = map[value.id]
            if existing == nil or name < existing then
                map[value.id] = name
            end
        end
    end
    return map
end

---Looks up a constant name for an id in a prebuilt map, self-healing a miss with
---one reverse scan and caching the result (a real name, or `false` for a negative)
---so repeated misses stay off the scan path.
---@param map table id -> constant name (mutated to cache the lookup)
---@param moneyTypeTable table source table to reverse-scan on a miss
---@param id number|nil money type id
---@return string|nil constant name, or nil when the id has no named constant
function RmTransactionLog.lookupConstant(map, moneyTypeTable, id)
    if id == nil then
        return nil
    end
    local cached = map[id]
    if cached ~= nil then
        if cached == false then
            return nil
        end
        return cached
    end
    -- Miss: reverse-scan for a late-registered type, deterministic smallest name.
    local best = nil
    for name, value in pairs(moneyTypeTable) do
        if type(value) == "table" and value.id == id then
            if best == nil or name < best then
                best = name
            end
        end
    end
    map[id] = best or false
    return best
end

---Resolves the MoneyType constant name for a runtime id, building the map on the
---first call (guaranteed post-registration).
---@param id number|nil money type id
---@return string|nil constant name, or nil when unknown
function RmTransactionLog.getMoneyTypeConstant(id)
    if RmTransactionLog.moneyTypeConstantById == nil then
        RmTransactionLog.moneyTypeConstantById = RmTransactionLog.buildMoneyTypeConstantMap(MoneyType)
    end
    return RmTransactionLog.lookupConstant(RmTransactionLog.moneyTypeConstantById, MoneyType, id)
end

---Resolves a stored money-type title key to display text for the active language.
---Fallback chain: localized title via getText(title, customEnv) (customEnv best-effort)
----> constant name -> raw title key -> "--". getText never returns nil, so every step is hasText-guarded.
---@param titleKey string|nil i18n key (e.g. "finance_other")
---@param customEnv string|nil owning mod env, best-effort (nil for base/many mods)
---@param constant string|nil derived constant name, secondary fallback
---@return string display text
function RmTransactionLog.resolveType(titleKey, customEnv, constant)
    if titleKey ~= nil and titleKey ~= "" and g_i18n:hasText(titleKey, customEnv) then
        return g_i18n:getText(titleKey, customEnv)
    end
    if constant ~= nil and constant ~= "" then
        return constant
    end
    if titleKey ~= nil and titleKey ~= "" then
        return titleKey
    end
    return g_i18n:getText("ui_transaction_log_no_data")
end

---Resolves a stored statistic key to its category display text.
---Fallback chain: getText("finance_"..statistic), modless (no customEnv) -> raw
---statistic -> "--". hasText-guarded (getText never returns nil).
---@param statistic string|nil statistic key (e.g. "other")
---@return string display text
function RmTransactionLog.resolveStatistic(statistic)
    if statistic ~= nil and statistic ~= "" then
        local key = "finance_" .. statistic
        if g_i18n:hasText(key) then
            return g_i18n:getText(key)
        end
        return statistic
    end
    return g_i18n:getText("ui_transaction_log_no_data")
end

---@class RmTransactionRecord one captured transaction's raw inputs -- keys mirror the stored row.
---@field amount number transaction amount (signed: negative = expense) -- required
---@field farmId number the farm ID that performed the transaction -- required
---@field title string|nil money-type title i18n key (moneyType.title, e.g. "finance_other")
---@field statistic string|nil money-type statistic key (moneyType.statistic, e.g. "other")
---@field customEnv string|nil owning mod env for the title key, best-effort (nil for base)
---@field constant string|nil derived MoneyType constant name (e.g. "VEHICLE_REPAIR")
---@field currentFarmBalance number|nil farm balance after the transaction (nil -> 0)
---@field comment string|nil optional comment for the transaction (nil -> "")
---@field subjectId string|nil enrichment WHAT: best-effort stable key (fillType/animal name, store-item xmlFilename, or nil) (set for SellingStation sales since TL-26, animal trades since TL-23, shop buy/sell since TL-24, production direct-sells since TL-28, and BuyingStation input purchases since TL-27)
---@field subjectName string|nil enrichment WHAT: always-set resolved display snapshot (capture-hook contract; set for SellingStation sales since TL-26, animal trades since TL-23, shop buy/sell since TL-24, production direct-sells since TL-28, and BuyingStation input purchases since TL-27)
---@field subjectKind string|nil enrichment WHAT: open-vocab kind discriminator (fillType/animal/storeItem seeds; set for SellingStation sales since TL-26, animal trades since TL-23, shop buy/sell since TL-24, production direct-sells since TL-28, and BuyingStation input purchases since TL-27)
---@field locationId string|nil enrichment WHERE: placeable uniqueId string (set for SellingStation sales since TL-25, production direct-sells since TL-28)
---@field locationName string|nil enrichment WHERE: placeable display-name snapshot (set for SellingStation sales since TL-25, production direct-sells since TL-28)

---Logs a single transaction to the transaction log.
---Stores the money-type snapshot RAW (i18n keys + identity), never resolved text -
---display resolution happens in the GUI/exporter, keeping the log language-agnostic.
---Takes ONE record table (TL-35) rather than positional params, so a field can only ever land in
---its own row slot -- positional misalignment is impossible. A misspelled KEY still degrades to nil
---under the `or` fallbacks below (the same silent failure a mistyped local had); the mapping test
---pins the known fields.
---@param record RmTransactionRecord the transaction fields (see RmTransactionRecord above)
function RmTransactionLog.logTransaction(record)
    -- GUARD FIRST: a nil / non-table record early-returns BEFORE any record.* read (indexing a
    -- non-table raises in Lua 5.1) AND before the id allocation (so a bad call burns no id). Only
    -- after this guard is it safe to read the named fields into locals (the body below stays
    -- byte-identical to the positional version -- same local names, same order, same logic).
    if record == nil or type(record) ~= "table" then
        Log:warning("logTransaction called with non-table record: %s", tostring(record))
        return
    end
    local amount = record.amount
    local farmId = record.farmId
    local title = record.title
    local statistic = record.statistic
    local customEnv = record.customEnv
    local constant = record.constant
    local currentFarmBalance = record.currentFarmBalance
    local comment = record.comment
    local subjectId = record.subjectId
    local subjectName = record.subjectName
    local subjectKind = record.subjectKind
    local locationId = record.locationId
    local locationName = record.locationName

    -- Parameter validation
    if amount == nil then
        Log:warning("logTransaction called with nil amount")
        return
    end
    if farmId == nil then
        Log:warning("logTransaction called with nil farmId")
        return
    end
    -- Defense-in-depth at the true insertion+sync boundary: never insert a bad-farm row into the
    -- master list nor fire the sync trigger for it. changeFarmBalance rejects these first, so this
    -- guards any other caller. ORDER MATTERS: the `farmId == nil` check above MUST stay before this
    -- one -- `nil <= 0` raises in Lua 5.1, so reordering would crash on a nil-farm transaction.
    if farmId <= 0 then
        Log:warning("logTransaction called with non-positive farmId: %s", tostring(farmId))
        return
    end

    -- Round to two decimals and get absolute value
    local amount_check = math.abs(math.floor(amount * 100 + 0.5) / 100)
    if amount_check == 0.00 then
        Log:trace("logTransaction called with amount 0, ignoring transaction")
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
    local year = g_currentMission.environment.currentYear + RmTransactionLog.START_YEAR - 1
    if month < 3 then
        year = year + 1
    end
    -- For ingame day we just use the current day in the period
    local day = g_currentMission.environment.currentDayInPeriod
    local hour = g_currentMission.environment.currentHour
    local minute = g_currentMission.environment.currentMinute
    local ingameDateTime = string.format("%04d-%02d-%02d %02d:%02d", year, month, day, hour, minute)
    local realDateTime = getDate("%Y-%m-%dT%H:%M:%S%z")
    -- Allocate the stable id AFTER the guards above so a rejected transaction never
    -- burns one. Batched rows reach here at flush and are numbered in flush order.
    local id = RmTransactionLog.nextTransactionId
    RmTransactionLog.nextTransactionId = id + 1
    -- Store keys/identity RAW; resolve to display text only in the GUI/exporter.
    -- Empty customEnv/constant/subjectId/subjectName/subjectKind/locationId/locationName normalize to
    -- nil (never concat/getText onto nil), each INDEPENDENTLY. TL-18/TL-36 plumb subject/location as
    -- additive nil-normalized fields; TL-19 consumes the pending-context holder in changeFarmBalance and
    -- threads it here on the DIRECT path. SellingStation sales set the subject (TL-26) AND location (TL-25);
    -- animal trades (TL-23) set the subject and take THIS direct path (newAnimalsCost/soldAnimals are
    -- non-batchable); shop buy/sell (TL-24) sets the subject; production direct-sells (TL-28) set subject +
    -- location; BuyingStation input purchases (TL-27) are batchable and ride the batcher, NOT this direct
    -- path; a txn with no captured subject/location records these nil. subjectId is a
    -- best-effort key; subjectName is the always-set display
    -- snapshot (a capture-hook contract, not enforced here); subjectKind is an open-vocab discriminator.
    local transaction = {
        id = id,
        realDateTime = realDateTime,
        ingameDateTime = ingameDateTime,
        farmId = farmId,
        amount = amount,
        title = title,
        statistic = statistic,
        customEnv = (customEnv ~= "" and customEnv) or nil,
        constant = (constant ~= "" and constant) or nil,
        currentFarmBalance = currentFarmBalance or 0,
        comment = comment or "",
        subjectId = (subjectId ~= "" and subjectId) or nil,
        subjectName = (subjectName ~= "" and subjectName) or nil,
        subjectKind = (subjectKind ~= "" and subjectKind) or nil,
        locationId = (locationId ~= "" and locationId) or nil,
        locationName = (locationName ~= "" and locationName) or nil,
    }

    table.insert(RmTransactionLog.transactions, transaction)
    Log:debug(string.format(
        "Transaction logged: id=%d | %s %s | Farm ID: %s | Amount: %.2f | Title: %s | Statistic: %s | Constant: %s | Balance: %.2f",
        transaction.id, transaction.realDateTime, transaction.ingameDateTime, transaction.farmId,
        transaction.amount, tostring(transaction.title), tostring(transaction.statistic),
        tostring(transaction.constant), transaction.currentFarmBalance))
    Log:trace("Transaction table size: %d", #RmTransactionLog.transactions)

    -- Single sync trigger (TL-10): once the row is in the master list, deliver it to ONLY the
    -- owning farm's remote clients. This is the ONE place sync fires -- it covers direct inserts
    -- AND batched-at-flush rows alike, since flushBatch routes every collapsed row back through
    -- logTransaction (one send per final row, so batching still reduces event volume). sendToFarm
    -- guards internally, so this is a clean no-op on a client, on a bad farmId, or on a nil
    -- mission. In singleplayer this DOES run (the host is the authority) but delivers nothing --
    -- the client list is empty and the native send skips the host loopback -- so SP is behaviorally
    -- unchanged; real cross-client delivery begins only when the MP flag flips at TL-12.
    RmTransactionLogSync.sendToFarm(transaction.farmId, RmAddTransactionEvent.new(transaction))
end

-- ============================================================
-- Comment editing (TL-13): server-authoritative, addressed by stable id
-- ============================================================

---Clamp a comment to MAX_COMMENT_LENGTH codepoints and coerce nil -> "". Codepoint-safe via the
---engine utf8 globals (utf8Strlen / utf8Substr, whose start is 0-based) so a multi-byte comment is
---truncated on a character boundary, never mid-sequence. An empty string is a valid CLEARED comment
---(distinct from the nil coalesce). This is the ONE clamp both sides run through - the client before
---its optimistic apply + send, the server before applying + re-broadcasting a (possibly crafted)
---event - so an oversized or nil comment can never reach the master list.
---@param comment string|nil raw comment (possibly oversized, possibly nil)
---@return string clamped comment ("" when nil)
function RmTransactionLog.clampComment(comment)
    if comment == nil then
        return ""
    end
    if type(comment) ~= "string" then
        comment = tostring(comment)
    end
    -- utf8Strlen / utf8Substr are engine globals present whenever the mod runs (in-game only). Guard
    -- their presence defensively so a non-game host degrades to a byte clamp instead of raising.
    if utf8Strlen ~= nil and utf8Substr ~= nil then
        if utf8Strlen(comment) > RmTransactionLog.MAX_COMMENT_LENGTH then
            return utf8Substr(comment, 0, RmTransactionLog.MAX_COMMENT_LENGTH)
        end
        return comment
    end
    if #comment > RmTransactionLog.MAX_COMMENT_LENGTH then
        return string.sub(comment, 1, RmTransactionLog.MAX_COMMENT_LENGTH)
    end
    return comment
end

---Find the master row with the given stable id (first match wins - a stray duplicate resolves
---deterministically to the earliest-inserted row). Rows are addressed by id, NEVER by display index
---(the GUI display list is a sorted copy). PURE - reads the module master, mutates nothing.
---@param id number the stable transaction id
---@return table|nil row the master row, or nil when absent (cleared / not yet delivered)
function RmTransactionLog.findRowById(id)
    for _, row in ipairs(RmTransactionLog.transactions) do
        if row.id == id then
            return row
        end
    end
    return nil
end

---Apply a comment to the master row addressed by stable id (first match wins). Clamps the comment
---(codepoint-safe, nil -> "") before writing, so every write path lands a normalized value. Returns
---whether a row was found: the server skips its re-broadcast when this returns false (the row
---vanished between validate and apply).
---@param id number the stable transaction id
---@param comment string|nil the new comment (clamped here)
---@return boolean found true when a row matched and was updated
function RmTransactionLog.applyCommentById(id, comment)
    local row = RmTransactionLog.findRowById(id)
    if row == nil then
        return false
    end
    row.comment = RmTransactionLog.clampComment(comment)
    return true
end

---Whether the LOCAL player may manage this farm - the Add Comment / Export button gate. Delegates
---to the verified engine permission check with NO connection / farmId, which resolves the local
---player: on SP + listen-host (getIsServer() and connection == nil) it short-circuits true, else it
---returns player.isFarmManager or the "farmManager" permission flag. So SP is unchanged (always a
---manager) and a pure client's workers are gated out. NEVER Farm:isUserFarmManager (it always
---returns false, so it cannot report manager status). Nil-safe for teardown / headless (no mission -> not a manager).
---@return boolean isManager
function RmTransactionLog.isLocalPlayerFarmManager()
    if g_currentMission == nil then
        return false
    end
    return g_currentMission:getHasPlayerPermission("farmManager")
end

---Whether the LOCAL player is an admin (master user) - the Clear Log button gate (TL-15). This is the
---exact `isAdmin` idiom the settings frame already uses inline (getIsServer() or isMasterUser), extracted
---to one seam the GUI + tests share. On SP + listen-host getIsServer() is true, so the host is always an
---admin (no SP regression); a pure client's non-admins gate out. Returns a STRICT boolean (`== true`
---normalizes a nil isMasterUser, which setVisible needs). Nil-safe for teardown / headless (no mission ->
---not an admin). Deliberately asymmetric with isLocalPlayerFarmManager: a whole-log clear is a master-user
---(admin) action across ALL farms, not a per-farm manager action (decision 1).
---@return boolean isAdmin
function RmTransactionLog.isLocalPlayerAdmin()
    if g_currentMission == nil then
        return false
    end
    return g_currentMission:getIsServer() or g_currentMission.isMasterUser == true
end

---Repaint the transaction-log frame when it is open, so an applied comment shows without a reopen.
---Best-effort and headless-safe: a no-op before the frame instance exists or when the log is closed.
---Gated on the frame's own `isLogOpen` flag (set in onOpen / cleared in onClose), NOT on
---`g_gui.currentGuiName` - showing a `MessageDialog` via `showDialog` updates `currentDialogName`,
---not `currentGuiName` (only a full-screen change sets that), so a name check would never match and
---the refresh would be dead. The flag is also robust to a comment dialog layered on top. The editing
---client's own repaint is ALSO guaranteed by the GUI callback's reloadData; this additionally covers
---a farm member who receives the server's broadcast with the log already open.
function RmTransactionLog.refreshOpenLog()
    local frame = RmTransactionLogFrame ~= nil and RmTransactionLogFrame.INSTANCE or nil
    if frame ~= nil and frame.isLogOpen and frame.refreshData ~= nil then
        frame:refreshData()
    end
end

---Request a comment edit for the row addressed by stable id - the ONE entry point the GUI calls.
---Normalizes the comment once (codepoint clamp, nil -> ""), then splits by authority:
---  * Authority (SP / listen-host): the local player already passed the button gate, so apply to
---    the master by id, repaint, and re-broadcast the clamped value to that farm's members
---    (sendToFarm is a no-op in SP - empty client list - and skips the host loopback in MP).
---  * Pure client: apply OPTIMISTICALLY by id + repaint, then send RmEditCommentEvent to the
---    server, which is the security boundary (it re-validates farm ownership + the farmManager role,
---    then re-broadcasts). NO rollback on a server reject (accepted residual): a gated manager is
---    never rejected, and a crafted reject is display-only and self-heals on the next TL-11 snapshot.
---@param id number the stable transaction id of the row to edit
---@param comment string|nil the new comment (normalized here)
function RmTransactionLog.requestCommentEdit(id, comment)
    -- Guard a non-numeric id: a captured row always carries a numeric id, but a stray / orphan row
    -- with none would otherwise reach `streamWriteInt32(nil)` on the pure-client send and raise a
    -- script error. Quiet DEBUG drop, matching every other rejection in this feature.
    if type(id) ~= "number" then
        Log:debug("requestCommentEdit: non-numeric id %s; ignoring", tostring(id))
        return
    end
    local normalized = RmTransactionLog.clampComment(comment)
    if g_server ~= nil then
        -- Authority: apply directly to the master, then fan out to the farm's remote members.
        if RmTransactionLog.applyCommentById(id, normalized) then
            RmTransactionLog.refreshOpenLog()
            local row = RmTransactionLog.findRowById(id)
            if row ~= nil then
                RmTransactionLogSync.sendToFarm(row.farmId, RmEditCommentEvent.new(id, normalized))
            end
        end
    else
        -- Pure client: optimistic local apply, then ask the server to authorize + persist.
        RmTransactionLog.applyCommentById(id, normalized)
        RmTransactionLog.refreshOpenLog()
        if g_client ~= nil then
            local serverConnection = g_client:getServerConnection()
            if serverConnection ~= nil then
                serverConnection:sendEvent(RmEditCommentEvent.new(id, normalized))
            end
        end
    end
end

-- ============================================================
-- Pending context (TL-19): synchronous set/consume-once channel for transaction enrichment.
-- A call-site prepend-hook stashes a subject/location here IMMEDIATELY before the intended addMoney;
-- changeFarmBalance consumes it once at entry. SellingStation sales set the subject (TL-26) AND location
-- (TL-25); animal trades (TL-23), shop buy/sell (TL-24), and BuyingStation input purchases (TL-27) set the
-- subject; production direct-sells (TL-28) set subject + location; the deferred FillTrigger / AI-helper
-- input paths (TL-44) still record no subject.
-- ============================================================

---Stash the subject (WHAT) + location (WHERE) for the NEXT authoritative changeBalance. Takes ONE
---`context` record whose fields are each optional (absent -> nil). NIL-GUARDED: a nil or partial `context`
---is treated as an empty context (every field reads back nil) and NEVER raises -- indexing `context or {}`.
---AUTHORITY-GUARDED: a no-op on a pure client (g_server == nil) so a stray or future client-side set can
---never seed stale context -- capture is server-authoritative, and a client's changeFarmBalance no-ops at
---its own g_server guard anyway. Grammar-agnostic: stores whatever strings are passed VERBATIM (the "" ->
---nil normalization + any grammar live at the capture hooks / logTransaction, not here). The real contract
---for the capture hooks: call this synchronously right before the addMoney, because a single global holder
---is safe ONLY within one synchronous set->consume stack (Design Notes F6).
---@param context table|nil a record {subjectId, subjectName, subjectKind, locationId, locationName}; any field optional
function RmTransactionLog.setPendingContext(context)
    if g_server == nil then return end
    context = context or {}
    RmTransactionLog.pendingSubjectId = context.subjectId
    RmTransactionLog.pendingSubjectName = context.subjectName
    RmTransactionLog.pendingSubjectKind = context.subjectKind
    RmTransactionLog.pendingLocationId = context.locationId
    RmTransactionLog.pendingLocationName = context.locationName
end

---Atomically read-and-clear the pending context. RETURNS a record
---`{subjectId, subjectName, subjectKind, locationId, locationName}` and resets all five scalar fields to
---nil in the one call. A second consume before the next set returns a record whose fields are all-nil --
---intentional consume-once, not an error. This is the single clear point: changeFarmBalance binds it once
---at entry (`local ctx = consumePendingContext()`) so EVERY authoritative changeBalance clears the holder,
---which is the leak guarantee (context can never cross to a LATER unrelated transaction). NOT called from
---logTransaction -- that runs again at batch flush, when the holder is unrelated; the flushed row gets nil
---via logTransaction's explicit args.
---@return table context a record {subjectId, subjectName, subjectKind, locationId, locationName} (fields may be nil)
function RmTransactionLog.consumePendingContext()
    local context = {
        subjectId = RmTransactionLog.pendingSubjectId,
        subjectName = RmTransactionLog.pendingSubjectName,
        subjectKind = RmTransactionLog.pendingSubjectKind,
        locationId = RmTransactionLog.pendingLocationId,
        locationName = RmTransactionLog.pendingLocationName,
    }
    RmTransactionLog.pendingSubjectId = nil
    RmTransactionLog.pendingSubjectName = nil
    RmTransactionLog.pendingSubjectKind = nil
    RmTransactionLog.pendingLocationId = nil
    RmTransactionLog.pendingLocationName = nil
    return context
end

-- ============================================================
-- SellingStation subject + location capture (TL-26 subject / TL-25 location): the mod's FIRST prepend.
-- Reads the sold fillType (WHAT) AND the station's location (WHERE) off SellingStation.sellFillType BEFORE
-- the engine credits the money, and stashes them as ONE pending context (via setPendingContext) so the
-- already-appended changeFarmBalance consumes it and the sale's row carries the fill type + the station.
-- ProductionPoint direct-sell subject + location is captured in TL-28 (its own overwrite block below).
-- ============================================================

-- One-shot install guard: set true once the prepend is wrapped, so a second install call (a stray
-- re-source or a test) never stacks a second prepend on the shared SellingStation.sellFillType chain.
RmTransactionLog.sellFillTypeHookInstalled = false

---Resolve a selling station's WHERE (location) to an owning-placeable id + display-name snapshot. PURE and
---RAISE-FREE BY CONSTRUCTION -- this runs inside the sellFillType prepend, and a raise there would prevent
---the real sale -- so every access is type()-guarded and there is NO pcall. Returns two VALUE snapshots:
---plain strings copied at call time, retaining NO reference to the placeable, so a placeable deleted before
---the batch flush cannot cause a stale deref. No globals, no g_server read. The four load-bearing guards:
---  1. OUTER: a non-table sellingStation returns nil, nil (indexing .owningPlaceable would otherwise raise).
---  2. locationId: owningPlaceable:getUniqueId() ONLY when the placeable AND its getUniqueId are present;
---     kept only when a non-empty string (nil/"" for a runtime-placed, not-yet-saved placeable).
---  3. locationName primary (station label): sellingStation:getName() ONLY when getName AND the placeable
---     AND placeable.getName are all present -- calling getName() on some stations can dereference the
---     owning placeable, so without a present placeable (and its getName) it could raise and break the
---     sale. Kept only when a non-empty string.
---  4. locationName fallback (placeable name): when the primary yielded nil, owningPlaceable:getName()
---     (placeable + getName guarded), kept only when a non-empty string. This deliberately surfaces the
---     placeable's own name even when the station label came back empty -- benign and more informative (spec Ask First).
---@param sellingStation table|nil the SellingStation instance
---@return string|nil locationId the owning placeable's uniqueId (nil when absent / not-yet-saved / empty)
---@return string|nil locationName the station label, else the placeable name, else nil
function RmTransactionLog.resolveSellingStationLocation(sellingStation)
    if type(sellingStation) ~= "table" then
        return nil, nil
    end
    local placeable = sellingStation.owningPlaceable
    local placeableIsTable = type(placeable) == "table"

    local locationId = nil
    if placeableIsTable and type(placeable.getUniqueId) == "function" then
        local uid = placeable:getUniqueId()
        if type(uid) == "string" and uid ~= "" then
            locationId = uid
        end
    end

    local locationName = nil
    -- Primary: the station's own label. Calling getName() on some stations can dereference the owning
    -- placeable, so BOTH the placeable and its getName must be present before the call, to stay raise-free.
    if type(sellingStation.getName) == "function" and placeableIsTable
        and type(placeable.getName) == "function" then
        local name = sellingStation:getName()
        if type(name) == "string" and name ~= "" then
            locationName = name
        end
    end
    -- Fallback: the owning placeable's own name (surfaced when the station label came back empty).
    if locationName == nil and placeableIsTable and type(placeable.getName) == "function" then
        local pName = placeable:getName()
        if type(pName) == "string" and pName ~= "" then
            locationName = pName
        end
    end

    return locationId, locationName
end

---Prepend callback for SellingStation.sellFillType: resolve the sold fillType (WHAT) AND the station's
---location (WHERE) TOGETHER, and stash them as ONE pending context for the money credit that follows in the
---same synchronous stack. Subject and location are two ORTHOGONAL dimensions captured at the same site
---(self IS the station), folded into ONE setPendingContext because a second call would clobber the first
---(TL-25). The signature mirrors sellFillType's params so fillTypeIndex is read positionally (4th incl.
---self); sellingStation (self) is now USED (TL-25) to resolve the location. Server-authority is enforced
---ONCE, at setPendingContext (g_server-guarded) - deliberately NO duplicate g_server guard here, so a
---client-side prepend is a harmless read that no-ops at the setter. RAISE-FREE: every read is type()-guarded
---(no pcall), because a raise in the prepend would prevent the real sale. The two dimensions degrade
---INDEPENDENTLY: an unresolvable fillType (nil index, absent/methodless g_fillTypeManager, non-table desc)
---leaves the subject nil WITHOUT dropping the location, and a placeable-less station leaves the location nil
---without dropping the subject; a nil name/title/id nil-normalizes downstream. Past the farmId leak guard
---the callback ALWAYS sets once (subject and/or location, possibly all-nil) -- an all-nil set is harmless:
---changeFarmBalance consumes+clears on every authoritative call, so it behaves exactly like no set.
---@param sellingStation table|nil the SellingStation instance (TL-25: read for location via resolveSellingStationLocation)
---@param farmId number|nil the selling farm's id
---@param fillDelta number|nil the amount sold (unused here; present to mirror the signature)
---@param fillTypeIndex number|nil the sold fillType's runtime index
function RmTransactionLog.captureSellFillTypeContext(sellingStation, farmId, fillDelta, fillTypeIndex, ...)
    Log:trace("captureSellFillTypeContext: farmId=%s fillTypeIndex=%s",
        tostring(farmId), tostring(fillTypeIndex))
    -- Leak guard (SOLE early-return): addMoney credits changeBalance for amount 0 (a zero-price sale is
    -- consumed normally), but EARLY-RETURNS without changeBalance when farmId is 0 (spectator) or the farm
    -- is unknown. A context set for such a sale -- subject OR location -- would never be consumed and would
    -- leak onto the NEXT server transaction, so skip when farmId is nil/0. (A nonzero-but-unknown farmId is
    -- a bounded, self-healing residual: the next capture-hook sale overwrites the holder.)
    if farmId == nil or farmId == 0 then
        Log:trace("  skipped: nil/0 farmId (leak guard)")
        return
    end

    -- WHERE: resolve the station's location (raise-free, value snapshot). Orthogonal to the subject below.
    local locationId, locationName = RmTransactionLog.resolveSellingStationLocation(sellingStation)

    -- WHAT: resolve the sold fillType into three nil-degrading locals. Hardened type/function guards so a
    -- truthy non-table manager, a non-function method, or a non-table desc nil-degrades WITHOUT raising and
    -- WITHOUT dropping the location (NO early-return -- the two dimensions are independent). .name is the
    -- stable UPPERCASE key ("BARLEY"); .title the localized snapshot ("Barley"); each nil-normalizes
    -- independently downstream, so a desc missing either sets that field nil.
    local subjectId, subjectName, subjectKind = nil, nil, nil
    if fillTypeIndex ~= nil
        and type(g_fillTypeManager) == "table"
        and type(g_fillTypeManager.getFillTypeByIndex) == "function" then
        local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
        if type(fillType) == "table" then
            subjectId = fillType.name
            subjectName = fillType.title
            subjectKind = "fillType"
        end
    end

    -- ONE merged set (past the leak guard, always once): subject and/or location, possibly all-nil.
    Log:trace("  set context: subjectId=%s subjectName=%s subjectKind=%s locationId=%s locationName=%s",
        tostring(subjectId), tostring(subjectName), tostring(subjectKind),
        tostring(locationId), tostring(locationName))
    RmTransactionLog.setPendingContext({
        subjectId = subjectId,
        subjectName = subjectName,
        subjectKind = subjectKind,
        locationId = locationId,
        locationName = locationName,
    })
end

---Install the SellingStation.sellFillType prepend ONCE, at file scope. Idempotent + presence-guarded:
---wraps only when SellingStation and its sellFillType method exist AND the hook is not already installed;
---a second call (a stray re-source or a test) is a silent no-op. Logs a WARNING and skips when the
---target is absent (empty-degrade: the mod still loads; sales just record a nil subject).
---@return boolean installedThisCall true if this call wrapped the prepend, false if already installed or skipped
function RmTransactionLog.installSellingStationCaptureHook()
    if RmTransactionLog.sellFillTypeHookInstalled then
        return false
    end
    if SellingStation == nil or SellingStation.sellFillType == nil then
        Log:warning("SellingStation.sellFillType unavailable; sold-fillType subject capture disabled")
        return false
    end
    SellingStation.sellFillType = Utils.prependedFunction(
        SellingStation.sellFillType, RmTransactionLog.captureSellFillTypeContext)
    RmTransactionLog.sellFillTypeHookInstalled = true
    Log:debug("Installed SellingStation.sellFillType subject-capture prepend")
    return true
end

-- ============================================================
-- Animal buy/sell subject capture (TL-23): the mod's SECOND prepend site. Reads the traded animal's
-- subType off AnimalBuyEvent.run / AnimalSellEvent.run BEFORE the engine credits the money, resolves it to
-- a subject {subjectId=subType.name, subjectName=fillType.title, subjectKind="animal"}, and stashes it via
-- setPendingContext so the already-appended changeFarmBalance consumes it and the (non-batchable,
-- DIRECT-path) newAnimalsCost/soldAnimals row carries the animal. Location stays nil (a later ticket).
-- ============================================================

-- Per-target one-shot install guards: each is set true once its prepend is wrapped, so a second install
-- call never stacks a duplicate prepend, yet a target absent at first call is still wrapped on a later call
-- (NO permanent lockout). One independent flag per target (AnimalBuyEvent.run, AnimalSellEvent.run).
RmTransactionLog.animalBuyHookInstalled = false
RmTransactionLog.animalSellHookInstalled = false

---Resolve an animal subType index to the enrichment subject record. PINNED contract: return a
---{subjectId, subjectName, subjectKind="animal"} record whenever a subType TABLE resolves (subjectId and
---subjectName may EACH be nil independently); return nil ONLY when no subType resolves. subjectId is the
---animal's stable UPPERCASE key (subType.name, e.g. "COW"); subjectName is the localized fillType title
---(e.g. "Cow"/"Kuh") via g_fillTypeManager; subjectKind is the exact TL-36 camelCase seed "animal". A
---record with kind + two nils is a VALID degrade (display falls back subjectId -> "--").
---@param subTypeIndex number|nil the animal subType's runtime index
---@return table|nil context {subjectId, subjectName, subjectKind="animal"} or nil when no subType resolves
function RmTransactionLog.resolveAnimalSubjectContext(subTypeIndex)
    if subTypeIndex == nil then
        return nil
    end
    if g_currentMission == nil or g_currentMission.animalSystem == nil then
        return nil
    end
    local subType = g_currentMission.animalSystem:getSubTypeByIndex(subTypeIndex)
    if type(subType) ~= "table" then
        return nil
    end
    -- subjectId: the animal's stable UPPERCASE key; nil/"" -> nil (normalized independently of subjectName).
    local subjectId = (subType.name ~= nil and subType.name ~= "") and subType.name or nil
    -- subjectName: the fillType's localized title, resolved best-effort; nil/"" -> nil INDEPENDENTLY of
    -- subjectId, so an absent g_fillTypeManager or a title-less desc leaves a kind-only record.
    local subjectName = nil
    if g_fillTypeManager ~= nil then
        local fillType = g_fillTypeManager:getFillTypeByIndex(subType.fillTypeIndex)
        if type(fillType) == "table" and fillType.title ~= nil and fillType.title ~= "" then
            subjectName = fillType.title
        end
    end
    return {
        subjectId = subjectId,
        subjectName = subjectName,
        subjectKind = "animal",
    }
end

---Prepend callback for AnimalBuyEvent.run: resolve the bought animal's subType (event.subTypeIndex) and
---stash it as the pending subject for the money credit that follows in the same synchronous stack.
---Utils.prependedFunction forwards the hooked call's args to this callback, so `event` is the
---AnimalBuyEvent instance (the hooked self) and `connection` is the passed-through connection.
---Empty-degrades (sets NO context, never raises) on a non-table event or an unresolvable subtype (incl.
---the server-to-client REPLY event, which
---carries only errorCode -> nil subTypeIndex). Server-authority is enforced ONCE at setPendingContext
---(g_server-guarded) - deliberately NO duplicate g_server guard here (TL-36 single-guard-point contract).
---On a server-REJECTED trade (the base validate fails AFTER this prepend set context) run returns without
---addMoney, so the set subject leaks onto the NEXT authoritative changeBalance - an ACCEPTED, bounded,
---self-healing residual (farmId is not a run param, so TL-26's farmId guard is unavailable; see the spec
---Design Notes). Do NOT "fix" this by hooking addAnimals/changeNumAnimals - those fire in non-monetary
---contexts (loading/birth/transport) and leak WORSE.
---@param event table the AnimalBuyEvent instance (the hooked self, forwarded by prependedFunction)
---@param connection table|nil the network connection (unused; forwarded by prependedFunction)
function RmTransactionLog.captureAnimalBuyContext(event, connection, ...)
    if type(event) ~= "table" then
        return
    end
    Log:trace("captureAnimalBuyContext: subTypeIndex=%s", tostring(event.subTypeIndex))
    local ctx = RmTransactionLog.resolveAnimalSubjectContext(event.subTypeIndex)
    if ctx ~= nil then
        RmTransactionLog.setPendingContext(ctx)
    end
end

---Prepend callback for AnimalSellEvent.run: resolve the sold animal via its cluster
---(event.object:getClusterById(event.clusterId).subTypeIndex) and stash it as the pending subject for the
---money credit. Utils.prependedFunction forwards the hooked call's args, so `event` is the AnimalSellEvent
---instance (the hooked self). Empty-degrades (NO context, no raise) on a
---non-table event/object, a missing getClusterById, a nil clusterId, a nil/non-table cluster, or a
---non-number subtype (incl. the reply event, whose object is nil). getClusterById returns nil (not a
---raise) for an unknown/stale clusterId, so a sold-out-from-under race degrades cleanly via the
---nil-cluster guard; and because the base sell already resolves the cluster before crediting, this prepend
---adds NO new crash path even for a malformed input. The same ACCEPTED failed/raced-trade subject leak as
---the buy callback applies (bounded + self-healing; see the buy docstring + spec Design Notes). No
---duplicate g_server guard (authority is at setPendingContext).
---@param event table the AnimalSellEvent instance (the hooked self, forwarded by prependedFunction)
---@param connection table|nil the network connection (unused; forwarded by prependedFunction)
function RmTransactionLog.captureAnimalSellContext(event, connection, ...)
    if type(event) ~= "table" then
        return
    end
    if type(event.object) ~= "table" or type(event.object.getClusterById) ~= "function"
        or event.clusterId == nil then
        return
    end
    local cluster = event.object:getClusterById(event.clusterId)
    if type(cluster) ~= "table" then
        return
    end
    local subTypeIndex = cluster.subTypeIndex
    if type(subTypeIndex) ~= "number" then
        return
    end
    Log:trace("captureAnimalSellContext: subTypeIndex=%s", tostring(subTypeIndex))
    local ctx = RmTransactionLog.resolveAnimalSubjectContext(subTypeIndex)
    if ctx ~= nil then
        RmTransactionLog.setPendingContext(ctx)
    end
end

---Install the AnimalBuyEvent.run / AnimalSellEvent.run prepends ONCE, at file scope. Idempotent +
---PER-TARGET presence-guarded: each target is wrapped only when its event class + run method exist AND that
---target's flag is unset, then its flag is set. A re-call wraps any not-yet-wrapped present target (a target
---absent at first call but present later is still wrapped - NO permanent lockout). Logs a WARNING per absent
---target (empty-degrade: the mod still loads; that trade path just records a nil subject).
---@return boolean installedThisCall true if this call wrapped at least one prepend, false otherwise
function RmTransactionLog.installAnimalTradeCaptureHooks()
    local installedAny = false
    if not RmTransactionLog.animalBuyHookInstalled then
        if AnimalBuyEvent ~= nil and AnimalBuyEvent.run ~= nil then
            AnimalBuyEvent.run = Utils.prependedFunction(
                AnimalBuyEvent.run, RmTransactionLog.captureAnimalBuyContext)
            RmTransactionLog.animalBuyHookInstalled = true
            installedAny = true
            Log:debug("Installed AnimalBuyEvent.run subject-capture prepend")
        else
            Log:warning("AnimalBuyEvent.run unavailable; bought-animal subject capture disabled")
        end
    end
    if not RmTransactionLog.animalSellHookInstalled then
        if AnimalSellEvent ~= nil and AnimalSellEvent.run ~= nil then
            AnimalSellEvent.run = Utils.prependedFunction(
                AnimalSellEvent.run, RmTransactionLog.captureAnimalSellContext)
            RmTransactionLog.animalSellHookInstalled = true
            installedAny = true
            Log:debug("Installed AnimalSellEvent.run subject-capture prepend")
        else
            Log:warning("AnimalSellEvent.run unavailable; sold-animal subject capture disabled")
        end
    end
    return installedAny
end

-- ============================================================
-- Shop buy/sell subject capture (TL-24): the mod's THIRD prepend site-group. Reads the bought/sold store
-- item off the six base-game shop entry points BEFORE the engine credits the money, resolves it to
-- {subjectId=storeItem.xmlFilename, subjectName=<display>, subjectKind="storeItem"}, and stashes it via
-- setPendingContext so the already-appended changeFarmBalance consumes it and the resulting row carries the
-- item. FIVE statistics are non-batchable (newVehiclesCost / soldVehicles / soldBuildings / newHandtoolsCost
-- / soldHandtools -> DIRECT path); the placeable BUY statistic constructionCost IS batchable (it is shared
-- with landscaping), so that one path rides the TL-22/36 context-threaded batch and its flushed row carries
-- the subject. Either way changeFarmBalance threads the consumed context onward, so no batcher change is in
-- scope. Location stays nil for shop buy/sell (shop purchases have no station self; TL-25's location capture
-- covers selling-station sales only). ProductionPoint direct-sell captures subject + location in TL-28.
-- ============================================================

-- Per-target one-shot install guards (one per shop entry point): each is set true once its prepend is
-- wrapped, so a second install call never stacks a duplicate prepend, yet a target absent at first call is
-- still wrapped on a later call (NO permanent lockout). Independent flags so an absent target skips ONLY
-- itself and never locks out a present sibling.
RmTransactionLog.buyVehicleHookInstalled = false
RmTransactionLog.buyPlaceableHookInstalled = false
RmTransactionLog.buyHandToolHookInstalled = false
RmTransactionLog.sellVehicleHookInstalled = false
RmTransactionLog.sellHandToolHookInstalled = false
RmTransactionLog.sellPlaceableHookInstalled = false

---Build the enrichment subject record for a shop store item. PURE, with field-wise INDEPENDENT nil-degrade:
---subjectId is the store item's stable xmlFilename KEY, subjectName is the display snapshot (a caller
---override wins over the base storeItem.name, so a SELL can pass the config/brand-aware runtime getName()),
---and subjectKind is the exact TL-36 camelCase seed "storeItem". Either id or name may be nil INDEPENDENTLY
---(the display fallback covers a nil subjectName); each empty string normalizes to nil (matching the
---resolveAnimalSubjectContext idiom). Returns nil ONLY when nothing is resolvable, so the caller can skip
---setPendingContext entirely.
---@param storeItem table|nil the StoreItem (carries .xmlFilename + .name)
---@param displayNameOverride string|nil a display name preferred over storeItem.name (a sell's getName())
---@return table|nil subject {subjectId, subjectName, subjectKind="storeItem"} or nil when nothing resolves
function RmTransactionLog.buildStoreItemSubject(storeItem, displayNameOverride)
    local isTable = type(storeItem) == "table"
    local id = (isTable and storeItem.xmlFilename ~= "" and storeItem.xmlFilename) or nil
    local override = (displayNameOverride ~= nil and displayNameOverride ~= "" and displayNameOverride) or nil
    local name = override or (isTable and storeItem.name ~= "" and storeItem.name) or nil
    if id == nil and name == nil then
        return nil
    end
    return {
        subjectId = id,
        subjectName = name,
        subjectKind = "storeItem",
    }
end

---Prepend callback for the three shop BUY entry points (BuyVehicleData / BuyPlaceableData / BuyHandToolData
---onBought). Utils.prependedFunction forwards the hooked call's args, so `buyData` is the Buy*Data instance
---(the hooked self). Reads buyData.storeItem into the pending subject for the money credit that follows in
---the same synchronous stack. Sets NO context (and never raises) when: the self is not a table; the owning
---farm is nil/0 (spectator/unknown -- addMoney early-returns without changeBalance, so a set context would
---leak onto the NEXT transaction; mirrors the TL-26 farmId guard); the buy is isFreeOfCharge (a
---mission/tutorial grant fires no addMoney); or leaseVehicle is set (leasing is a NOT-enrichable category --
---the LEASING_COSTS row stays unenriched; the field is nil on the non-vehicle Buy*Data, which is correctly
---falsy). Server-authority is enforced ONCE at setPendingContext (g_server-guarded) - NO duplicate guard
---here. Residual: if the acquisition does not complete (a canceled/failed load), no money credit follows
---and this prepend cannot detect that, so the armed context leaks to the next changeBalance -- an ACCEPTED,
---bounded, self-healing residual (see spec Design Notes).
---@param buyData table the Buy*Data instance (the hooked self, forwarded by prependedFunction)
function RmTransactionLog.captureBoughtStoreItemContext(buyData, ...)
    if type(buyData) ~= "table" or buyData.ownerFarmId == nil or buyData.ownerFarmId == 0
        or buyData.isFreeOfCharge or buyData.leaseVehicle then
        return
    end
    Log:trace("captureBoughtStoreItemContext: ownerFarmId=%s storeItem=%s",
        tostring(buyData.ownerFarmId), tostring(buyData.storeItem))
    local ctx = RmTransactionLog.buildStoreItemSubject(buyData.storeItem)
    if ctx ~= nil then
        RmTransactionLog.setPendingContext(ctx)
    end
end

---Shared SELL adapter for a runtime object that exposes getName() + configFileName (a vehicle or hand
---tool). Resolves the display name via getName() and the stable key via the store item behind
---configFileName (g_storeManager:getItemByXMLFilename lowercases internally, so a mixed-case configFileName
---resolves). The mod's OWN accesses are type-/callability-guarded (getName presence, g_storeManager
---presence, configFileName is a string) so a renamed/absent method or a drifted field degrades to a
---partial/no subject in mod code, never a raise. NOTE: the never-raise guarantee covers the mod's OWN
---accesses; a base-game getName() that is present but itself raises is the engine's contract, outside the
---mod's degrade scope (it does not, in normal server-side selling). Local: the two sell callbacks delegate here.
---@param obj table|nil the sold runtime object (event.vehicle / event.handTool)
local function captureSoldConfigObjectContext(obj)
    if type(obj) ~= "table" then
        return
    end
    local name = (type(obj.getName) == "function" and obj:getName()) or nil
    local storeItem = nil
    -- Guard configFileName is a string BEFORE the lookup: getItemByXMLFilename -> string.lower would raise
    -- on a non-string/non-number drifted value, so fail closed in mod code rather than lean on engine tolerance.
    if type(obj.configFileName) == "string" and type(g_storeManager) == "table"
        and type(g_storeManager.getItemByXMLFilename) == "function" then
        storeItem = g_storeManager:getItemByXMLFilename(obj.configFileName)
    end
    local ctx = RmTransactionLog.buildStoreItemSubject(storeItem, name)
    if ctx ~= nil then
        RmTransactionLog.setPendingContext(ctx)
    end
end

---Prepend callback for SellVehicleEvent.run: capture the sold vehicle (event.vehicle) as the subject.
---prependedFunction forwards the hooked args, so `event` is the SellVehicleEvent instance. Delegates to the
---shared config-object adapter. Empty-degrades (NO context, no raise) on a non-table event or a nil vehicle
---(incl. the server-to-client REPLY event, whose vehicle is nil). The dominant SELL leak is the in-run
---validation gate (permission / in-use) that a prepend cannot reach -- an ACCEPTED, bounded, self-healing
---event-hook residual (sibling to the TL-23 animal-sell leak; see spec Design Notes). No duplicate g_server
---guard (authority at setPendingContext).
---@param event table the SellVehicleEvent instance (the hooked self, forwarded by prependedFunction)
function RmTransactionLog.captureSoldVehicleContext(event, ...)
    captureSoldConfigObjectContext(type(event) == "table" and event.vehicle or nil)
end

---Prepend callback for SellHandToolEvent.run: capture the sold hand tool (event.handTool). Mirrors the
---vehicle sell via the shared adapter. Empty-degrades (NO context, no raise) on a non-table event or a nil
---handTool (incl. the reply event). Same accepted validation-gate leak + single-guard-point contract as the
---vehicle sell.
---@param event table the SellHandToolEvent instance (the hooked self, forwarded by prependedFunction)
function RmTransactionLog.captureSoldHandToolContext(event, ...)
    captureSoldConfigObjectContext(type(event) == "table" and event.handTool or nil)
end

---Prepend callback for SellPlaceableEvent.run: capture the sold placeable via its store item
---(event.placeable.storeItem) -- NOT placeable:getName() (the usually-nil player custom name; location for
---shop sales is out of TL-25's selling-station scope). prependedFunction forwards the hooked args, so `event` is the SellPlaceableEvent
---instance. Empty-degrades (NO context, no raise) on a non-table event, a nil placeable (incl. the reply
---event), or a nil/absent storeItem. Also SKIPS a forFree sale (event.forFree): a free sale has no money
---change, so arming the subject would leak it onto the NEXT changeBalance (e.g. a landscaping
---constructionCost row when a free removal precedes a terrain edit). event.forFree is a field on the event
---we prepend -- the sell-side mirror of the buy callback's isFreeOfCharge skip, NOT a tighter post-validation
---seam. The permission / in-use validation-gate leak (decided inside run, unreachable from a prepend) remains
---the accepted, bounded, self-healing residual.
---@param event table the SellPlaceableEvent instance (the hooked self, forwarded by prependedFunction)
function RmTransactionLog.captureSoldPlaceableContext(event, ...)
    if type(event) ~= "table" or event.forFree then
        return
    end
    local placeable = event.placeable
    if type(placeable) ~= "table" then
        return
    end
    local ctx = RmTransactionLog.buildStoreItemSubject(placeable.storeItem)
    if ctx ~= nil then
        RmTransactionLog.setPendingContext(ctx)
    end
end

-- Descriptor for the six shop prepend targets. className is read from _G at install time (so a target
-- absent-then-present is still wrapped -- NO lockout), method is the wrapped function, callback is the
-- RmTransactionLog capture function (resolved by name), flag is the per-target one-shot guard field, and
-- label names the transaction kind in the log line.
local SHOP_HOOK_TARGETS = {
    { className = "BuyVehicleData",     method = "onBought", callback = "captureBoughtStoreItemContext", flag = "buyVehicleHookInstalled",    label = "bought-vehicle" },
    { className = "BuyPlaceableData",   method = "onBought", callback = "captureBoughtStoreItemContext", flag = "buyPlaceableHookInstalled",  label = "bought-placeable" },
    { className = "BuyHandToolData",    method = "onBought", callback = "captureBoughtStoreItemContext", flag = "buyHandToolHookInstalled",   label = "bought-hand-tool" },
    { className = "SellVehicleEvent",   method = "run",      callback = "captureSoldVehicleContext",     flag = "sellVehicleHookInstalled",   label = "sold-vehicle" },
    { className = "SellHandToolEvent",  method = "run",      callback = "captureSoldHandToolContext",    flag = "sellHandToolHookInstalled",  label = "sold-hand-tool" },
    { className = "SellPlaceableEvent", method = "run",      callback = "captureSoldPlaceableContext",   flag = "sellPlaceableHookInstalled", label = "sold-placeable" },
}

---Install the six shop buy/sell prepends ONCE, at file scope. Idempotent + PER-TARGET presence-guarded:
---each target is wrapped only when its class + method exist AND that target's flag is unset, then its flag
---is set. A re-call wraps any not-yet-wrapped present target (a target absent at first call but present
---later is still wrapped - NO permanent lockout). Logs a WARNING per absent target (empty-degrade: the mod
---still loads; that shop path just records a nil subject). Reads each class from _G at call time so the
---no-lockout re-wrap sees a late-registered class. In practice all six targets are CORE base-game globals
---defined during engine script load (before any mod's extraSourceFiles), so they are always present at the
---single file-scope install call and the no-lockout re-wrap is defensive insurance (mirrors the TL-23
---installer, which is likewise called once).
---@return boolean installedThisCall true if this call wrapped at least one prepend, false otherwise
function RmTransactionLog.installShopSubjectHooks()
    local installedAny = false
    for _, target in ipairs(SHOP_HOOK_TARGETS) do
        if not RmTransactionLog[target.flag] then
            local class = _G[target.className]
            if type(class) == "table" and type(class[target.method]) == "function" then
                class[target.method] = Utils.prependedFunction(
                    class[target.method], RmTransactionLog[target.callback])
                RmTransactionLog[target.flag] = true
                installedAny = true
                Log:debug("Installed %s.%s %s subject-capture prepend",
                    target.className, target.method, target.label)
            else
                Log:warning("%s.%s unavailable; %s subject capture disabled",
                    target.className, target.method, target.label)
            end
        end
    end
    return installedAny
end

-- ============================================================
-- Production direct-sell subject + location capture (TL-28): the mod's FIRST overwrite site-group. When a
-- production sells its outputs directly, each output is credited separately (one credit per output), so a
-- single prepend (which arms the pending holder once, up front) can only tag the first credit. Instead we
-- OVERWRITE the two direct-sell functions and reimplement their observable payout
-- behavior, adding exactly one behavior: arm each iteration's own output as the subject (WHAT) and the
-- production as the location (WHERE) immediately before that iteration's credit, so the already-appended
-- changeFarmBalance consumes the right context per row. This is a full reimplementation (superFunc is
-- unused); only the mod-owned resolve/arm helpers below are raise-free, while the reproduced economic reads
-- (fill-type category, per-liter price) intentionally carry the same runtime assumptions as the base game.
-- ============================================================

-- Per-target one-shot install guards, one per overwritten function. A target absent (or with a drifted
-- install-time dependency) at first call is skipped and left un-flagged, so a later call can still install
-- it -- no permanent lockout, mirroring the shop installer.
RmTransactionLog.productionUpdateSoldHookInstalled = false
RmTransactionLog.productionDirectSellHookInstalled = false

---Resolve a production's WHERE (location) to its owning-placeable id + a display-name snapshot. PURE and
---RAISE-FREE BY CONSTRUCTION -- this runs inside an overwritten payout function, so a raise here would
---break the sale -- so every access is type()/callability-guarded and there is NO pcall. Returns two plain
---string snapshots copied at call time (retaining no reference to the placeable), so a placeable deleted
---before a batch flush cannot cause a stale deref. locationId is the owning placeable's stable unique id
---(nil for a not-yet-synchronized placeable, or an empty id, both normalized to nil). locationName prefers
---the production's own name, falling back to the owning placeable's name -- read defensively (rather than
---via the production's own name accessor, which can raise when its owning placeable is absent), so re-audit
---here if that naming behavior changes. A locationName of
---nil (neither name present) is an accepted degrade.
---@param production table|nil the ProductionPoint instance
---@return string|nil locationId the owning placeable's unique id (nil when absent / not-yet-saved / empty)
---@return string|nil locationName the production name, else the owning placeable name, else nil
function RmTransactionLog.resolveProductionLocation(production)
    if type(production) ~= "table" then
        return nil, nil
    end
    local placeable = production.owningPlaceable
    local placeableIsTable = type(placeable) == "table"

    local locationId = nil
    if placeableIsTable and type(placeable.getUniqueId) == "function" then
        local uid = placeable:getUniqueId()
        if type(uid) == "string" and uid ~= "" then
            locationId = uid
        end
    end

    local locationName = nil
    if type(production.name) == "string" and production.name ~= "" then
        locationName = production.name
    elseif placeableIsTable and type(placeable.getName) == "function" then
        local placeableName = placeable:getName()
        if type(placeableName) == "string" and placeableName ~= "" then
            locationName = placeableName
        end
    end

    return locationId, locationName
end

---Build the enrichment context (subject + location) for one directly-sold production output. RAISE-FREE:
---the fill-type lookup is hardened (a truthy non-table manager, a non-function method, or a non-table desc
---nil-degrades the subject WITHOUT dropping the location, and vice-versa -- the two dimensions are
---orthogonal). The subject is the output fill type: subjectId = its stable key (.name), subjectName = its
---localized title, subjectKind = the exact seed "fillType"; each field nil-normalizes downstream if the
---desc lacks it. Always returns a record (any field may be nil); an all-nil record is harmless (consumed +
---cleared exactly like no set).
---@param production table|nil the ProductionPoint instance (for the location)
---@param fillTypeIndex number|nil the output fill type's runtime index (for the subject)
---@return table context a record {subjectId, subjectName, subjectKind, locationId, locationName}
function RmTransactionLog.buildProductionDirectSellContext(production, fillTypeIndex)
    local subjectId, subjectName, subjectKind = nil, nil, nil
    if fillTypeIndex ~= nil
        and type(g_fillTypeManager) == "table"
        and type(g_fillTypeManager.getFillTypeByIndex) == "function" then
        local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
        if type(fillType) == "table" then
            subjectId = fillType.name
            subjectName = fillType.title
            subjectKind = "fillType"
        end
    end

    local locationId, locationName = RmTransactionLog.resolveProductionLocation(production)

    return {
        subjectId = subjectId,
        subjectName = subjectName,
        subjectKind = subjectKind,
        locationId = locationId,
        locationName = locationName,
    }
end

---Body seam called once per output, immediately before that output's money credit: stash its subject +
---the production location as the pending context for the credit that follows in the same synchronous stack.
---Leak-guarded on the owning farm (nil/0 -> skip arming): a credit for farm 0 (spectator/unknown) early-
---returns without changeBalance, so an armed context would leak onto the NEXT server transaction. ownerFarmId
---is a per-production field, constant across the payout loop, so the guard is all-or-nothing within a call.
---A nonzero ownerFarmId whose farm is not registered (getFarmById nil - a mid-deletion race, or a reserved
---id) is NOT caught here; addMoney likewise early-returns without changeBalance, leaving the same bounded,
---self-healing residual the sibling capture hooks carry (the next authoritative credit overwrites the holder).
---Server-authority is enforced once, at setPendingContext (g_server-guarded) -- no duplicate guard here.
---@param production table the ProductionPoint instance (the overwritten self)
---@param fillTypeIndex number|nil the output fill type's runtime index
function RmTransactionLog.armProductionDirectSellContext(production, fillTypeIndex)
    local ownerFarmId = (type(production) == "table" and production.ownerFarmId) or nil
    if ownerFarmId == nil or ownerFarmId == 0 then
        return
    end
    Log:trace("armProductionDirectSellContext: ownerFarmId=%s fillTypeIndex=%s",
        tostring(ownerFarmId), tostring(fillTypeIndex))
    RmTransactionLog.setPendingContext(
        RmTransactionLog.buildProductionDirectSellContext(production, fillTypeIndex))
end

-- Map a produced fill type to its income ledger category (observable: products post as sold-products, BGA
-- feedstock as BGA income, and everything else as generic harvest income; the product check takes
-- precedence). This reproduces base classification, so the category read intentionally carries the base
-- game's own runtime assumption (it is NOT independently hardened -- that would diverge from base behavior).
local function classifyProductionIncome(outputType)
    if g_fillTypeManager:getIsFillTypeInCategory(outputType, "PRODUCT") then
        return MoneyType.SOLD_PRODUCTS
    elseif g_fillTypeManager:getIsFillTypeInCategory(outputType, "PRODUCT_BGA") then
        return MoneyType.INCOME_BGA
    end
    return MoneyType.HARVEST_INCOME
end

-- Arm the per-output enrichment and then post its credit, as one step, so the pending subject/location is
-- set on the holder immediately before the money change that consumes it. Shared by both overwrites; the
-- caller supplies the already-computed payout and its ledger category.
local function armAndPostDirectSale(production, outputType, payout, ledgerType)
    RmTransactionLog.armProductionDirectSellContext(production, outputType)
    production.mission:addMoney(payout, production.ownerFarmId, ledgerType, true)
end

---Overwrite of ProductionPoint:updateBalaceDirectlySoldOutputs (base name kept so the wrap targets the real
---method). Reimplements the observable behavior: for an owned, server-side production, pay out every fill
---type queued for direct sale at its full per-liter price, classify each into its income ledger, credit it,
---and reset that queued amount to zero (a value assignment, which is safe while iterating). The one added
---behavior is arming each output's subject + the production location immediately before its credit.
---superFunc is intentionally unused -- tagging each per-output credit requires reimplementing the loop.
---@param self table the ProductionPoint instance
---@param superFunc function the wrapped original (unused)
function RmTransactionLog.overwriteUpdateBalaceDirectlySoldOutputs(self, superFunc, ...)
    if not (self.isOwned and self.isServer) then
        return
    end
    for outputType, pendingLitres in pairs(self.soldFillTypesToPayOut) do
        local ledgerType = classifyProductionIncome(outputType)
        local payout = pendingLitres * g_currentMission.economyManager:getPricePerLiter(outputType)
        armAndPostDirectSale(self, outputType, payout, ledgerType)
        self.soldFillTypesToPayOut[outputType] = 0
    end
end

---Overwrite of ProductionPoint:directlySellOutputs. Reimplements the observable behavior: for each output
---configured for direct sale, sell the amount currently in storage at the direct-sale discounted per-liter
---price, post it as sold-products income, and empty that output's storage. Outputs holding nothing are
---skipped. The one added behavior is arming each sold output's subject + the production location immediately
---before its credit -- placed INSIDE the positive-amount branch, so an empty output never leaves an
---unconsumed armed context. There is deliberately no owned/server guard in this body -- this path is only
---reached for owned, server-side productions, so a guard here would be redundant; superFunc is unused (full
---reimplementation).
---@param self table the ProductionPoint instance
---@param superFunc function the wrapped original (unused)
function RmTransactionLog.overwriteDirectlySellOutputs(self, superFunc, ...)
    local discountFactor = ProductionPoint.DIRECT_SELL_PRICE_FACTOR
    for outputType in pairs(self.outputFillTypeIdsDirectSell) do
        local storedLitres = self.storage:getFillLevel(outputType)
        if storedLitres > 0 then
            local payout = discountFactor * storedLitres * g_currentMission.economyManager:getPricePerLiter(outputType)
            armAndPostDirectSale(self, outputType, payout, MoneyType.SOLD_PRODUCTS)
            self.storage:setFillLevel(0, outputType)
        end
    end
end

-- Descriptor for the two production direct-sell overwrite targets. method is the real ProductionPoint
-- method to wrap, overwrite names the RmTransactionLog reimplementation, flag is the per-target one-shot
-- guard, dependenciesOk is an install-time PRESENCE check for the exact engine constants that target's
-- reimplementation hard-codes (a narrow check -- runtime API shapes cannot be verified at file scope), and
-- label names the site in the log line.
local PRODUCTION_HOOK_TARGETS = {
    {
        method = "updateBalaceDirectlySoldOutputs",
        overwrite = "overwriteUpdateBalaceDirectlySoldOutputs",
        flag = "productionUpdateSoldHookInstalled",
        label = "production paid-out direct sale",
        dependenciesOk = function()
            return type(MoneyType) == "table"
                and MoneyType.HARVEST_INCOME ~= nil
                and MoneyType.SOLD_PRODUCTS ~= nil
                and MoneyType.INCOME_BGA ~= nil
        end,
    },
    {
        method = "directlySellOutputs",
        overwrite = "overwriteDirectlySellOutputs",
        flag = "productionDirectSellHookInstalled",
        label = "production direct sale",
        dependenciesOk = function()
            return type(MoneyType) == "table"
                and MoneyType.SOLD_PRODUCTS ~= nil
                and type(ProductionPoint.DIRECT_SELL_PRICE_FACTOR) == "number"
        end,
    },
}

---Install the production direct-sell overwrites ONCE, at file scope. PER-TARGET presence + dependency
---gated: a target is overwritten only when ProductionPoint + its method exist AND that target's install-
---time dependencies are intact, then its flag is set. When the method is absent OR a dependency has drifted,
---that target is SKIPPED with a WARNING and left un-flagged -- the base function runs unchanged (the row
---keeps its coarse label), no overwrite is installed, and a later call can still install it (no lockout).
---A skip is never-wrong; it just captures nothing for that target. Both branches never crash and never
---double-count.
---@return boolean installedThisCall true if this call installed at least one overwrite, false otherwise
function RmTransactionLog.installProductionDirectSellHooks()
    local installedAny = false
    for _, target in ipairs(PRODUCTION_HOOK_TARGETS) do
        if not RmTransactionLog[target.flag] then
            local methodPresent = type(ProductionPoint) == "table"
                and type(ProductionPoint[target.method]) == "function"
            if methodPresent and target.dependenciesOk() then
                ProductionPoint[target.method] = Utils.overwrittenFunction(
                    ProductionPoint[target.method], RmTransactionLog[target.overwrite])
                RmTransactionLog[target.flag] = true
                installedAny = true
                Log:debug("Installed ProductionPoint.%s %s capture overwrite", target.method, target.label)
            else
                Log:warning("ProductionPoint.%s unavailable or dependency drifted; %s capture disabled (base behavior unchanged)",
                    target.method, target.label)
            end
        end
    end
    return installedAny
end

-- ============================================================
-- Production running-cost location capture (TL-46): a guarded PREPEND on ProductionPoint.claimProductionCosts.
-- The per-production running cost (MoneyType.PRODUCTION_COSTS, claimed ~hourly) has no fillType, so this arms
-- the owning production's LOCATION only (WHERE) via setPendingContext immediately before the single addMoney,
-- so the already-appended changeFarmBalance consumes it and the productionCosts row carries the production. A
-- PREPEND (not an overwrite like TL-28's per-output loop) fits because claimProductionCosts has a SINGLE
-- guarded addMoney and its return is unused; arming-only cannot drift from a base body change, only a rename.
-- REUSES resolveProductionLocation (TL-28). Subject stays nil (a running cost has no fillType). The OTHER
-- productionCosts source (auto-deliver transfer costs in ProductionChainManager:distributeGoods) credits inside
-- a loop -> out of scope (a separate backlog), so those stay unattributed.
-- ============================================================

-- One-shot install guard: set true once the prepend is wrapped, so a second install call (a stray re-source
-- or a test) never stacks a second prepend on the shared ProductionPoint.claimProductionCosts chain. A target
-- absent at first call leaves it false so a later call re-wraps (NO permanent lockout).
RmTransactionLog.productionClaimCostHookInstalled = false

---Prepend callback for ProductionPoint.claimProductionCosts, invoked BEFORE the base runs: arm the owning
---production's LOCATION (WHERE only -- a running cost has no fillType, so no subject) as the pending context
---for the (negative) money charge that follows in the same synchronous stack, so the already-appended
---changeFarmBalance consumes it and the productionCosts row carries the production. RAISE-FREE: every read is
---type()-guarded (no pcall), because a raise in the prepend would break the real charge.
---
---Arm IFF the charge will actually happen: gate on the PER-INSTANCE fields the charge itself depends on
---(production.isOwned AND production.isServer AND 0 < production.productionCostsToClaim), NOT the global
---g_server -- so the armed context is consumed by the immediately-following credit and never leaks. The
---pending-balance field still holds its amount when the prepend runs (it is cleared as the charge is taken).
---claimProductionCosts runs ~hourly per production and mostly does NOT charge; an unconditional arm would leak
---a location onto the next unrelated changeBalance.
---
---Then leak-guard the owner farm with changeFarmBalance's EXACT reject range (type ~= number / <= 0 / > MAX --
---covers spectator 0, guided-tour 14, invalid 15), as the TL-27 BuyingStation capture hook also replicates:
---addMoney does not credit changeBalance for such a farm, so arming for it would leak. A valid-range but
---not-yet-registered id (getFarmById nil -- a mid-deletion race) is NOT caught here; that charge likewise never
---reaches changeBalance, leaving the same bounded, self-healing residual armProductionDirectSellContext
---documents (the next authoritative credit overwrites the holder).
---Server-authority is enforced ONCE, at setPendingContext (g_server-guarded) -- no duplicate guard here.
---@param production table|nil the ProductionPoint instance (self; the prepend forwards it)
function RmTransactionLog.armProductionClaimCostContext(production, ...)
    -- Arm only when the charge will actually happen, reading the PER-INSTANCE fields the charge depends on (NOT
    -- global g_server): an owned, server-side production with a positive pending running-cost balance. That
    -- pending balance is cleared as the charge is taken, so reading it here (before the charge) still sees the
    -- amount that will be charged.
    if not (type(production) == "table"
        and production.isOwned
        and production.isServer
        and type(production.productionCostsToClaim) == "number"
        and production.productionCostsToClaim > 0) then
        return
    end
    -- Leak guard: mirror changeFarmBalance's reject range EXACTLY (type-guarded <= 0 OR > MAX_NUM_FARMS), so a
    -- spectator (farm 0) / reserved (14/15) / invalid / non-number owner -- none actually credited -- cannot
    -- arm a leak. ownerFarmId is a per-production field, constant across the single charge, so all-or-nothing.
    local ownerFarmId = production.ownerFarmId
    if type(ownerFarmId) ~= "number" or ownerFarmId <= 0 or ownerFarmId > FarmManager.MAX_NUM_FARMS then
        return
    end
    local locationId, locationName = RmTransactionLog.resolveProductionLocation(production)
    Log:trace("armProductionClaimCostContext: ownerFarmId=%s locationId=%s locationName=%s",
        tostring(ownerFarmId), tostring(locationId), tostring(locationName))
    -- Location ONLY -- the three subject fields are omitted (nil): a running cost has no fillType.
    RmTransactionLog.setPendingContext({ locationId = locationId, locationName = locationName })
end

---Install the ProductionPoint.claimProductionCosts location-capture prepend ONCE, at file scope. Idempotent +
---presence-guarded: wraps only when ProductionPoint and its claimProductionCosts method exist AND the hook is
---not already installed; a second call (a stray re-source or a test) is a silent no-op. Logs a WARNING and
---skips when the target is absent (degrade-not-break: the mod still loads; production-cost rows just record no
---location). The flag prevents a self double-wrap; it is not a runtime recovery guarantee (production sources
---the module once, so a target absent at load stays absent).
---@return boolean installedThisCall true if this call wrapped the prepend, false if already installed or skipped
function RmTransactionLog.installProductionClaimCostHook()
    if RmTransactionLog.productionClaimCostHookInstalled then
        return false
    end
    if type(ProductionPoint) ~= "table" or type(ProductionPoint.claimProductionCosts) ~= "function" then
        Log:warning("ProductionPoint.claimProductionCosts unavailable; production-cost location capture disabled")
        return false
    end
    ProductionPoint.claimProductionCosts = Utils.prependedFunction(
        ProductionPoint.claimProductionCosts, RmTransactionLog.armProductionClaimCostContext)
    RmTransactionLog.productionClaimCostHookInstalled = true
    Log:debug("Installed ProductionPoint.claimProductionCosts location-capture prepend")
    return true
end

-- ============================================================
-- BuyingStation input-purchase subject capture (TL-27): a RETURN-PRESERVING capture wrap on
-- BuyingStation.addFillLevelToFillableObject (the mod's SECOND overwrittenFunction site, after TL-28). Arms
-- the purchased fillType as the subject BEFORE the engine credits the (negative) money, then forwards to the
-- base and RETURNS its result -- resolves the fillType to {subjectId=fillType.name, subjectName=fillType.title,
-- subjectKind="fillType"} and stashes it via setPendingContext so the already-appended changeFarmBalance
-- consumes it and the input purchase's row (batchable purchaseFuel/purchaseSeeds/purchaseFertilizer/
-- purchaseWater/other) carries the fill type. This uses Utils.overwrittenFunction rather than a bare
-- Utils.prependedFunction because this method's return value is load-bearing -- the game uses it to keep a
-- fill going, and a return-discarding wrapper makes the fill stop after one tick (observed in-game) --
-- see wrapBuyingStationFill. Subject ONLY -- location is out of scope (no input-purchase location ticket
-- exists). FillTrigger (public gas stations) and the AI-helper input paths are deferred: each credits inside a
-- loop or per frame, needing a full reimplementation (see the TL-27 spec's Never section).
-- ============================================================

-- One-shot install guard: set true once the prepend is wrapped, so a second install call (a stray re-source
-- or a test) never stacks a second prepend on the shared BuyingStation.addFillLevelToFillableObject chain. A
-- target absent at first call leaves it false so a later call re-wraps (NO permanent lockout).
RmTransactionLog.buyingStationHookInstalled = false

---Capture callback for BuyingStation.addFillLevelToFillableObject, invoked by wrapBuyingStationFill BEFORE the
---base runs: resolve the purchased fillType (WHAT) and stash it as the pending subject for the (negative)
---money charge that follows in the same synchronous stack, so the already-appended changeFarmBalance consumes
---it and the input-purchase row carries the fill type. PURE arming -- it sets context and returns nothing; the
---wrap forwards the base's return (see wrapBuyingStationFill). Subject ONLY -- location is deliberately not set
---(out of scope; no input-purchase location ticket exists). The signature mirrors the base method's params
---(self first -- it is a colon method), so fillTypeIndex is read positionally (4th incl. self).
---
---RAISE-FREE: every read is type()/callability-guarded (no pcall), because a raise in the prepend would break
---the real purchase. The FillType.UNKNOWN compare is raise-safe: type(FillType)=="table" is checked first, so
---an absent FillType (odd load order) can never be dereferenced (the mod holds no other FillType.* reference).
---
---Leak guard (SOLE early-returns): replicate the base's own entry guard from ENTRY-KNOWABLE params (a nil
---fillableObject / UNKNOWN or nil fillTypeIndex / zero fillDelta / nil toolType make the base return 0 without
---crediting), using a stricter type(fillableObject)~="table" since we call :getOwnerFarmId() on it; then skip
---when getOwnerFarmId() is outside changeFarmBalance's valid range (type~="number" or <=0 or
--- > FarmManager.MAX_NUM_FARMS -- mirrors that guard EXACTLY, BROADER than the SellingStation hook's ==0, so a
---negative / reserved (14/15) / >MAX / non-number id cannot arm a leak: a spectator (farm 0) or an
---unknown/invalid farm is never actually credited (the money never reaches changeBalance), so arming context
---for it would leak onto the next txn). Two OTHER conditions are NOT
---entry-knowable, so a topped-off tank or a broke farm (both common in play) arms context with no charge,
---mis-attributing the fill type to EXACTLY ONE subsequent authoritative transaction. changeFarmBalance clears
---the holder on every call, bounding this to one row; it is the same REAL, bounded residual TL-23 accepted --
---not "self-healing".
---
---Server-authority is enforced ONCE, at setPendingContext (g_server-guarded) -- deliberately NO duplicate
---g_server guard here, so a client-side prepend is a harmless read that no-ops at the setter. Past the leak
---guard the callback ALWAYS sets once (possibly all-nil): an all-nil set is harmless -- changeFarmBalance
---consumes+clears on every authoritative call, so it behaves exactly like no set. The subject degrades to nil
---on a nil index / absent/methodless g_fillTypeManager / non-table desc; a nil .name or .title nil-normalizes
---that field INDEPENDENTLY downstream.
---@param buyingStation table|nil the BuyingStation instance (self; unused -- present to mirror the signature)
---@param fillableObject table|nil the object being filled (:getOwnerFarmId gives the charged farm)
---@param fillUnitIndex number|nil the target fill unit (unused; present to mirror the signature)
---@param fillTypeIndex number|nil the purchased fillType's runtime index
---@param fillDelta number|nil the requested fill amount (entry guard: base no-ops on 0)
---@param fillInfo any the fill info (unused; present to mirror the signature)
---@param toolType number|nil the tool type (entry guard: base no-ops on nil)
function RmTransactionLog.captureBuyingStationFillContext(buyingStation, fillableObject, fillUnitIndex,
        fillTypeIndex, fillDelta, fillInfo, toolType, ...)
    -- Leak guard (SOLE early-returns): replicate the base's entry guard from entry-knowable params, then the
    -- farmId range. FillType.UNKNOWN compared raise-safely (FillType may be absent under odd load orders).
    if type(fillableObject) ~= "table" or fillTypeIndex == nil
        or (type(FillType) == "table" and fillTypeIndex == FillType.UNKNOWN)
        or fillDelta == 0 or toolType == nil then
        return
    end
    if type(fillableObject.getOwnerFarmId) ~= "function" then
        return
    end
    local farmId = fillableObject:getOwnerFarmId()
    Log:trace("captureBuyingStationFillContext: farmId=%s fillTypeIndex=%s",
        tostring(farmId), tostring(fillTypeIndex))
    -- Mirror changeFarmBalance's reject range EXACTLY (type-guarded <=0 OR > FarmManager.MAX_NUM_FARMS),
    -- broader than the SellingStation hook's ==0. A spectator (farm 0), an unknown/invalid farm, or a
    -- reserved/out-of-range id is never actually credited (the money never reaches changeBalance), so a
    -- context set for such a purchase would never be consumed and would leak onto the next transaction;
    -- skipping the whole invalid range (negative / reserved / >MAX / non-number) keeps that from arming. The
    -- topped-off-tank / broke-farm case (a fill that adds nothing, or an unaffordable one) is NOT
    -- entry-knowable and stays a bounded one-row residual -- see the docstring.
    if type(farmId) ~= "number" or farmId <= 0 or farmId > FarmManager.MAX_NUM_FARMS then
        Log:trace("  skipped: farmId outside the valid capture range (leak guard)")
        return
    end

    -- WHAT: resolve the purchased fillType into three nil-degrading locals. Hardened type/function guards so a
    -- truthy non-table manager, a non-function method, or a non-table desc nil-degrades WITHOUT raising. .name
    -- is the stable UPPERCASE key ("DIESEL"); .title the localized snapshot ("Diesel"); each nil-normalizes
    -- independently downstream, so a desc missing either sets that field nil.
    local subjectId, subjectName, subjectKind = nil, nil, nil
    if type(g_fillTypeManager) == "table"
        and type(g_fillTypeManager.getFillTypeByIndex) == "function" then
        local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
        if type(fillType) == "table" then
            subjectId = fillType.name
            subjectName = fillType.title
            subjectKind = "fillType"
        end
    end

    -- Subject only (past the leak guard, always once): location deliberately NOT set (out of scope). An
    -- all-nil set is harmless -- changeFarmBalance consumes+clears on every authoritative call, so it behaves
    -- exactly like no set.
    Log:trace("  set context: subjectId=%s subjectName=%s subjectKind=%s (location out of scope, nil)",
        tostring(subjectId), tostring(subjectName), tostring(subjectKind))
    RmTransactionLog.setPendingContext({
        subjectId = subjectId,
        subjectName = subjectName,
        subjectKind = subjectKind,
    })
end

---overwrittenFunction adapter for BuyingStation.addFillLevelToFillableObject. Arms the purchased-fillType
---subject (via the pure captureBuyingStationFillContext) BEFORE the base runs, then forwards to superFunc and
---RETURNS its result UNCHANGED. overwrittenFunction (NOT prependedFunction) is REQUIRED here: this method's
---return value (the applied fill amount) is load-bearing -- the game reads it to decide whether to keep
---filling, so a return-discarding wrapper makes the fill stop after one tick. A bare Utils.prependedFunction
---does not preserve the wrapped function's return; Utils.overwrittenFunction lets us return the base's result
---unchanged. Observed in-game. Arming is a harmless side effect; the return path is byte-identical to the base.
---@param self table the BuyingStation instance
---@param superFunc function the base addFillLevelToFillableObject
---@return number|nil fillDelta the base's applied fill amount, forwarded unchanged
function RmTransactionLog.wrapBuyingStationFill(self, superFunc, ...)
    RmTransactionLog.captureBuyingStationFillContext(self, ...)
    return superFunc(self, ...)
end

---Install the BuyingStation.addFillLevelToFillableObject capture wrap ONCE, at file scope. Idempotent +
---presence-guarded, NO permanent lockout: reads BuyingStation from _G at call time and sets the install flag
---only AFTER wrapping (the TL-24 installer discipline), so a target absent at first call is still wrapped on a
---later call; a second call once wrapped is a silent no-op. Logs a WARNING and skips when the target is
---absent (empty-degrade: the mod still loads; input purchases just record a nil subject). BuyingStation is a
---core base-game global defined during engine script load, so the lockout is theoretical -- but no-lockout is
---the repo's preferred form. Uses Utils.overwrittenFunction (RETURN-PRESERVING), NOT prependedFunction -- see
---wrapBuyingStationFill for why the base's return must be forwarded.
---@return boolean installedThisCall true if this call wrapped the method, false if already installed or skipped
function RmTransactionLog.installBuyingStationCaptureHook()
    if RmTransactionLog.buyingStationHookInstalled then
        return false
    end
    local class = _G.BuyingStation
    if type(class) ~= "table" or type(class.addFillLevelToFillableObject) ~= "function" then
        Log:warning("BuyingStation.addFillLevelToFillableObject unavailable; input-purchase subject capture disabled")
        return false
    end
    class.addFillLevelToFillableObject = Utils.overwrittenFunction(
        class.addFillLevelToFillableObject, RmTransactionLog.wrapBuyingStationFill)
    RmTransactionLog.buyingStationHookInstalled = true
    Log:debug("Installed BuyingStation.addFillLevelToFillableObject subject-capture wrap (return-preserving)")
    return true
end

-- ============================================================
-- Settings change transport (TL-14): server-authoritative apply + persist + broadcast,
-- with join-time settings sync. The GUI calls requestSettingChange; the server is the boundary.
-- ============================================================

---UI-entry router for a settings change - the ONE seam RmTransactionLogControls.onMenuOptionChanged
---calls. Settings-nil guarded (matches the requestCommentEdit / onMenuOptionChanged idiom - a change
---before loadMap initialized settings is a quiet no-op). Splits by authority:
---  * Authority (SP / listen-host, g_server ~= nil): apply + persist + broadcast directly via
---    applySettingAuthoritative.
---  * Pure client: send an RmSettingsChangeEvent REQUEST to the server (the security boundary),
---    guarding BOTH g_client and the server connection for teardown. NO optimistic local apply (differs
---    from TL-13's requestCommentEdit): a remote admin waits for the server's echoed broadcast. The
---    control's visual state already advanced on the click, and the settings OBJECT self-heals on the
---    next onFrameOpen (getStateIndex re-read) - settings changes are infrequent, so the round-trip is
---    acceptable and avoids a rollback path.
---@param id string setting id (a DEFINITIONS key)
---@param value number the new enum value (integer)
function RmTransactionLog.requestSettingChange(id, value)
    if RmTransactionLog.settings == nil then
        Log:debug("requestSettingChange: settings not initialized; ignoring change to %s", tostring(id))
        return
    end
    -- Guard a non-numeric value at this public UI seam (mirrors requestCommentEdit's non-numeric-id
    -- guard): the wire is Int32, and the client send would otherwise reach streamWriteInt32(nil) and
    -- raise. The UI already guards value ~= nil; this defends the seam against a future caller.
    if type(value) ~= "number" then
        Log:debug("requestSettingChange: non-numeric value %s for %s; ignoring", tostring(value), tostring(id))
        return
    end
    if g_server ~= nil then
        RmTransactionLog.applySettingAuthoritative(id, value)
    else
        local serverConnection = g_client and g_client:getServerConnection()
        if serverConnection ~= nil then
            serverConnection:sendEvent(RmSettingsChangeEvent.new(id, value))
        end
    end
end

---Server apply (authority-only). ONLY ever entered under g_server ~= nil, which both callers
---guarantee: requestSettingChange's authority branch AND handleSettingChangeRequest (after its master
---gate). FIRST a no-op short-circuit - if value already equals settings:getValue(id), return without
---persisting or broadcasting, because setValue returns true even for the already-current value (no
---equality short-circuit lives in setValue), and a redundant admin click must NOT rewrite the XML nor
---spam every client. Otherwise setValue is the second gate (rejects an unknown id / out-of-range
---value); only on success persist (writeSettings, itself g_server-guarded) and g_server:broadcastEvent
---the new value GLOBALLY - NOT broadcastEventToFarm, since settings are not farm-scoped. This is the
---FIRST direct g_server:broadcastEvent in the mod (the row layer only uses broadcastEventToFarm); it
---is the correct primitive for a global setting (@see Server.broadcastEvent). broadcastEvent defaults
---sendLocal=false, so we mutate local state (setValue) FIRST then broadcast; the host loopback is
---skipped, so the host never re-applies via applySettingFromNetwork. In SP / a listen-host with no
---remote clients the broadcast is a behavioral no-op - SP persists exactly as before.
---@param id string setting id
---@param value number the new enum value
function RmTransactionLog.applySettingAuthoritative(id, value)
    local settings = RmTransactionLog.settings
    if settings == nil then return end
    if value == settings:getValue(id) then return end
    if settings:setValue(id, value) then
        settings:writeSettings()
        g_server:broadcastEvent(RmSettingsChangeEvent.new(id, value))
        RmTransactionLog.refreshSettingsControls()
    end
end

---Server-side request handler - the SINGLE security boundary. Only reachable server-side (the
---connection:getIsServer() == false branch of RmSettingsChangeEvent:run). Guard order mirrors
---onPlayerFarmChanged and is load-bearing: g_server FIRST (getIsUserIdMasterUser asserts server-only,
---so this guard is the invariant that keeps it in-context - a defensive call or a test mock without
---isServer would otherwise raise); then g_currentMission / userManager non-nil (survive teardown - a
---late network event during shutdown is exactly where an unguarded boundary nil-crashes); then resolve
---the user and reject a nil user (unknown / torn-down connection) BEFORE user:getId(); then reject a
---nil userId; then reject (DEBUG log + return) unless the sender is a MASTER USER via
---userManager:getIsUserIdMasterUser(userId). NEVER the broken getIsConnectionMasterUser stub (it
---always returns false) and NEVER Farm:isUserFarmManager.
---There is no master short-circuit for a remote admin the way getHasPlayerPermission has, which is why
---settings uses the direct userId check, not a farm-permission call. On pass, applySettingAuthoritative.
---This is the single boundary for REMOTE (client-origin) requests; the local authority path
---(requestSettingChange under g_server ~= nil) is the trusted machine and applies directly, skipping
---this gate by design (the host is inherently privileged).
---@param connection table the requesting client's connection
---@param id string setting id
---@param value number the new enum value
function RmTransactionLog.handleSettingChangeRequest(connection, id, value)
    if g_server == nil then return end
    local mission = g_currentMission
    if mission == nil or mission.userManager == nil then return end
    local user = mission.userManager:getUserByConnection(connection)
    if user == nil then
        Log:debug("handleSettingChangeRequest: no user for connection; dropping change")
        return
    end
    local userId = user:getId()
    if userId == nil then
        Log:debug("handleSettingChangeRequest: user has no id; dropping change")
        return
    end
    if not mission.userManager:getIsUserIdMasterUser(userId) then
        Log:debug("handleSettingChangeRequest: user %s is not a master user; dropping change", tostring(userId))
        return
    end
    RmTransactionLog.applySettingAuthoritative(id, value)
end

---Client apply of the server's authoritative broadcast (the server-origin branch of run). Validates +
---sets via settings:applyFromNetwork (NO persist - persistence is server-only), then repaints an open
---settings frame. Only reached on a pure client: the broadcast uses sendLocal=false and the join send
---skips the loopback, so the host never enters this path.
---@param id string setting id
---@param value number the new enum value
function RmTransactionLog.applySettingFromNetwork(id, value)
    local settings = RmTransactionLog.settings
    if settings == nil then return end
    settings:applyFromNetwork(id, value)
    RmTransactionLog.refreshSettingsControls()
end

---Send ONE joining connection the CURRENT value of every settings menu item (one RmSettingsChangeEvent
---per MENU_ITEMS id) so its menu shows the truth on join. Guards FIRST - authority (g_server), a
---non-nil connection, and a NON-loopback connection (getIsLocal, the concrete host-skip mirroring
---sendSnapshotToConnection) - then settings non-nil. connection:sendEvent to one resolved connection is
---the base-game single-target idiom (@see FinanceStatsEvent inside sendInitialClientState), NOT the
---per-farm broadcastEventToFarm. Settings are GLOBAL (not farm-scoped), so onSendInitialClientState
---calls this for EVERY joiner incl. a spectator, BEFORE the transaction-snapshot's farm-0 gate.
---@param connection table the joining client's connection
function RmTransactionLog.sendSettingsToConnection(connection)
    if g_server == nil or connection == nil or connection:getIsLocal() then return end
    local settings = RmTransactionLog.settings
    if settings == nil then return end
    for _, id in ipairs(RmTransactionLogSettings.MENU_ITEMS) do
        -- getValue returns nil for a MENU_ITEMS id absent from DEFINITIONS (a config drift); skip it
        -- rather than feed streamWriteInt32(nil) and crash the whole join initial-state send.
        local value = settings:getValue(id)
        if value ~= nil then
            connection:sendEvent(RmSettingsChangeEvent.new(id, value))
        end
    end
end

---Repaint the settings controls to match the current settings object, after an authoritative apply or
---a broadcast apply. CONTROLS-empty / control-nil safe (harmless on a headless dedicated server where
---CONTROLS is never populated - the file-scope menu bootstrap is the pre-existing GUI-presence concern,
---not this helper's responsibility). setState does NOT fire onClickCallback (onFrameOpen already calls
---setState(getStateIndex(id)) on every open without re-saving, RmTransactionLog.lua onFrameOpen), so
---this has no callback side effect / re-entrancy and does not re-persist.
function RmTransactionLog.refreshSettingsControls()
    local settings = RmTransactionLog.settings
    if settings == nil then return end
    for _, id in ipairs(RmTransactionLogSettings.MENU_ITEMS) do
        local control = RmTransactionLog.CONTROLS[id]
        if control ~= nil then
            control:setState(settings:getStateIndex(id))
        end
    end
end

-- ============================================================
-- Clear-log transport (TL-15): server-authoritative, master-user-gated WHOLE-LOG clear. The GUI calls
-- requestClearLog; the server is the boundary. Closes gaps G7/G11 (the TL-13 interim hazard where a
-- worker retained a destructive, unsynced Clear Log). Whole-log scope (decision 1): a master user is
-- trusted over ALL farms' data, so the fan-out is the GLOBAL g_server:broadcastEvent, NOT the farm-scoped
-- broadcastEventToFarm the row layer uses.
-- ============================================================

---The alias-proof whole-log wipe, shared by the client-echo path (RmClearLogEvent:run under g_server ==
---nil) AND applyClearAuthoritative. Clears the existing RmTransactionLog.transactions table IN PLACE
---(by index, NOT `= {}`), keeping table identity - mirrors RmTransactionSnapshotEvent:run's clear half
---for pattern consistency; the real correctness requirement is that derived views repaint (refreshOpenLog),
---since the open frame holds a filtered COPY. Deliberately does NOT reset nextTransactionId: ids stay
---monotonic across a clear so a late batch flush can never reuse one (see nextTransactionId's contract).
---Nil-safe for teardown / headless.
function RmTransactionLog.clearTransactionsInPlace()
    local transactions = RmTransactionLog.transactions
    if transactions == nil then return end
    for i = #transactions, 1, -1 do
        transactions[i] = nil
    end
end

---Server apply + global fan-out (authority-only; only ever entered under g_server ~= nil, which both
---callers - the requestClearLog authority branch AND handleClearRequest after its master gate -
---guarantee). Order is load-bearing: flushAllBatches FIRST (drain in-flight batches so a pending flush
---cannot repopulate the log seconds after a "successful" clear - the SAME pre-persist idiom already run
---before every save, saveToXmlFile), THEN the in-place wipe + refreshOpenLog (repaint the host's own open
---frame, headless-safe no-op on a dedi) + g_server:broadcastEvent (the genuinely GLOBAL broadcast, since a
---whole-log clear crosses every farm - NOT broadcastEventToFarm). No no-op short-circuit for an
---already-empty log: a clear is rare + deliberate, and an idempotent empty-clear broadcast is harmless
---(unlike TL-14's settings, where a redundant click would spuriously rewrite XML + spam clients).
---broadcastEvent defaults sendLocal=false, so the host mutates local state FIRST (the wipe) then
---broadcasts; the loopback is skipped, so the host never re-applies via RmClearLogEvent:run's client branch.
---INTERNAL (server-only invariant); the only sanctioned callers are the two seams named above.
function RmTransactionLog.applyClearAuthoritative()
    RmTransactionBatcher.flushAllBatches(RmTransactionLog.logTransaction, "clear")
    local count = RmTransactionLog.transactions ~= nil and #RmTransactionLog.transactions or 0
    Log:info(string.format("Clearing transaction log: wiping %d transaction(s) across all farms", count))
    RmTransactionLog.clearTransactionsInPlace()
    RmTransactionLog.refreshOpenLog()
    g_server:broadcastEvent(RmClearLogEvent.new())
end

---Server-side request handler - the SINGLE security boundary for REMOTE clears. Only reachable
---server-side (the g_server ~= nil branch of RmClearLogEvent:run). Guard order mirrors the shipped
---siblings handleSettingChangeRequest / onPlayerFarmChanged and is load-bearing: g_server FIRST
---(getIsUserIdMasterUser asserts server-only, so this guard keeps it in-context); then g_currentMission /
---userManager non-nil (survive teardown - a late network event during shutdown is exactly where an
---unguarded boundary nil-crashes); then resolve the user and reject a nil user (unknown / torn-down
---connection) BEFORE user:getId(); then reject a nil userId; then reject (DEBUG + return) unless the sender
---is a MASTER USER via userManager:getIsUserIdMasterUser(userId). NEVER the broken getIsConnectionMasterUser
---stub (unconditional false) and NEVER Farm:isUserFarmManager. A whole-log clear is not farm-scoped, so
---there is no getHasPlayerPermission master short-circuit to lean on the way TL-13's edit does - hence the
---direct userId check. The local authority path (requestClearLog under g_server ~= nil) is the trusted host
---and skips this gate by design.
---@param connection table the requesting client's connection
function RmTransactionLog.handleClearRequest(connection)
    if g_server == nil then return end
    local mission = g_currentMission
    if mission == nil or mission.userManager == nil then return end
    local user = mission.userManager:getUserByConnection(connection)
    if user == nil then
        Log:debug("handleClearRequest: no user for connection; dropping clear")
        return
    end
    local userId = user:getId()
    if userId == nil then
        Log:debug("handleClearRequest: user has no id; dropping clear")
        return
    end
    if not mission.userManager:getIsUserIdMasterUser(userId) then
        Log:debug("handleClearRequest: user %s is not a master user; dropping clear", tostring(userId))
        return
    end
    Log:info(string.format("handleClearRequest: master user %s cleared the transaction log", tostring(userId)))
    RmTransactionLog.applyClearAuthoritative()
end

---UI-entry router for a clear - the ONE seam RmTransactionLogFrame.onYesNoClearLog calls. Splits by
---authority:
---  * Authority (SP / listen-host, g_server ~= nil): the local player already passed the button gate, so
---    apply + broadcast directly via applyClearAuthoritative.
---  * Pure client: send an RmClearLogEvent REQUEST to the server (the security boundary), guarding BOTH
---    g_client and the server connection for teardown. NO optimistic local wipe (differs from TL-13's
---    requestCommentEdit): a whole-log clear is DESTRUCTIVE, so a remote admin waits for the server's
---    echoed broadcast rather than pre-wiping with no rollback path if the server rejects (e.g. a demoted
---    admin's stale button).
function RmTransactionLog.requestClearLog()
    if g_server ~= nil then
        RmTransactionLog.applyClearAuthoritative()
    else
        local serverConnection = g_client and g_client:getServerConnection()
        if serverConnection ~= nil then
            serverConnection:sendEvent(RmClearLogEvent.new())
        end
    end
end

---Shows the transaction log GUI dialog
function RmTransactionLog.showTransactionLog()
    Log:debug("Showing transaction log GUI")
    if g_gui:getIsGuiVisible() then
        return
    end
    g_gui:showDialog("RmTransactionLogFrame")
end

---Gets current calendar date using existing date conversion logic
---@return string dateStr Format: "YYYY-MM-DD"
---@return string monthStr Format: "YYYY-MM"
---@return string yearStr Format: "YYYY"
function RmTransactionLog.getCurrentCalendarDate()
    -- Use existing date conversion logic from logTransaction
    local month = g_currentMission.environment.currentPeriod + 2
    if month > 12 then
        month = month - 12
    end
    local year = g_currentMission.environment.currentYear + RmTransactionLog.START_YEAR - 1
    if month < 3 then
        year = year + 1
    end
    local day = g_currentMission.environment.currentDayInPeriod

    local dateStr = string.format("%04d-%02d-%02d", year, month, day)
    local monthStr = string.format("%04d-%02d", year, month)
    local yearStr = string.format("%04d", year)

    return dateStr, monthStr, yearStr
end

---Stores date information for auto-export tracking
---@param dateStr string current date in "YYYY-MM-DD" format
---@param monthStr string current month in "YYYY-MM" format
---@param yearStr string current year in "YYYY" format
function RmTransactionLog.storeDateInfo(dateStr, monthStr, yearStr)
    RmTransactionLog.previousDate = dateStr
    RmTransactionLog.previousCalendarMonth = monthStr
    RmTransactionLog.previousCalendarYear = yearStr
end

---Initializes auto-export date tracking system
function RmTransactionLog.initializeAutoExportTracking()
    local currentDate, currentMonth, currentYear = RmTransactionLog.getCurrentCalendarDate()
    RmTransactionLog.storeDateInfo(currentDate, currentMonth, currentYear)
    Log:debug("Auto-export date tracking initialized with current date: " .. currentDate)
end

---Handles day change events for auto-export functionality
function RmTransactionLog.onDayChanged(self)
    -- Server-authority guard: auto-export runs on the server; a client no-ops.
    if g_server == nil then return end
    local currentDate, currentMonth, currentYear = RmTransactionLog.getCurrentCalendarDate()
    local autoExportSetting = RmTransactionLog.settings:getValue("autoExportFrequency")

    if autoExportSetting > 0 then -- If any auto-export is enabled
        local yearChanged = currentYear ~= RmTransactionLog.previousCalendarYear
        local monthChanged = currentMonth ~= RmTransactionLog.previousCalendarMonth
        local dayChanged = currentDate ~= RmTransactionLog.previousDate

        if yearChanged and autoExportSetting == 3 then -- Yearly
            RmTransactionLog.performAutoExport("yearly", RmTransactionLog.previousCalendarYear)
        end
        if monthChanged and autoExportSetting == 2 then -- Monthly
            RmTransactionLog.performAutoExport("monthly", RmTransactionLog.previousCalendarMonth)
        end
        if dayChanged and autoExportSetting == 1 then -- Daily
            RmTransactionLog.performAutoExport("daily", RmTransactionLog.previousDate)
        end
    end

    -- Store current date info for next day
    RmTransactionLog.storeDateInfo(currentDate, currentMonth, currentYear)
end

---Filters transactions by date period pattern
---@param transactions table array of transaction objects
---@param periodPattern string date pattern to match against (e.g., "2024-12-09", "2024-12", "2024")
---@return table filteredTransactions array of matching transactions
function RmTransactionLog.filterTransactionsByPeriod(transactions, periodPattern)
    local filteredTransactions = {}

    for _, transaction in ipairs(transactions) do
        if transaction.ingameDateTime then
            local transactionDate = transaction.ingameDateTime
            -- Match based on period pattern (escape dashes for pattern matching)
            if string.find(transactionDate, "^" .. string.gsub(periodPattern, "%-", "%%-")) then
                table.insert(filteredTransactions, transaction)
            end
        end
    end

    Log:debug(string.format("Filtered %d/%d transactions for period: %s",
        #filteredTransactions, #transactions, periodPattern))

    return filteredTransactions
end

---Filters transactions to a single farm. PURE: no module state, returns a NEW array holding the
---SAME row references (identity preserved so a comment edit still resolves the master row by id),
---in the caller's (master, ascending-id) order.
---
---The guard is load-bearing on two counts. (1) The nil guard stops a nil farmId from matching a
---loader-preserved orphan row whose farmId is also nil (nil == nil would otherwise leak that orphan
---into a "no farm" caller's view/export). (2) The `farmId <= 0` guard makes a spectator
---(getFarmId() == 0, FarmManager.SPECTATOR_FARM_ID) resolve to an empty view/export
---UNCONDITIONALLY - even against a corrupted/legacy row carrying farmId 0 - keeping this consistent
---with TL-11's RmTransactionLogSync.buildFarmSnapshot(0) == {}. Real farm ids are >= 1. Orphan /
---non-real-farm rows therefore match no real farm and are intentionally excluded from every
---per-farm view/export - a quarantine, not a bug.
---@param transactions table|nil array of transaction objects (master order)
---@param farmId number|nil the farm to filter to (0 = spectator, nil = no local player)
---@return table filtered a new array of the rows whose farmId == farmId (empty for nil args or a non-real farmId <= 0)
function RmTransactionLog.filterTransactionsByFarm(transactions, farmId)
    if transactions == nil or farmId == nil or farmId <= 0 then
        return {}
    end

    local filtered = {}
    for _, transaction in ipairs(transactions) do
        if transaction.farmId == farmId then
            filtered[#filtered + 1] = transaction
        end
    end

    return filtered
end

---Collects the DISTINCT real farm ids present in a transaction array, ASCENDING. PURE: no module
---state, returns a NEW array. A "real" farm id is a NUMBER that is an INTEGER in
---[1, FarmManager.MAX_NUM_FARMS]. The type guard runs BEFORE any numeric compare so a non-number
---farmId (e.g. a loaded "2") can never RAISE on `<= 0`. This deliberately mirrors the capture guard
---in changeFarmBalance (rejects nil / <= 0 / > MAX_NUM_FARMS) and the filterTransactionsByFarm
---quarantine: nil / spectator (0) / negative / non-integer / out-of-range ids are excluded, so a
---corrupt or legacy row can never spawn a spurious per-farm export or crash the boundary. The ids
---returned are exactly those for which filterTransactionsByFarm(transactions, id) is non-empty --
---so each collected farm is guaranteed >= 1 row when sliced (the auto-export loop relies on this).
---@param transactions table|nil array of transaction objects
---@return table ids a new ascending array of the distinct real farm ids present (empty for nil/empty input)
function RmTransactionLog.collectFarmIds(transactions)
    local ids = {}
    if transactions == nil then
        return ids
    end

    local seen = {}
    for _, transaction in ipairs(transactions) do
        local fid = transaction.farmId
        -- Type guard FIRST: a non-number farmId must not reach `<= 0` (that would raise). Then an
        -- integer + [1, MAX_NUM_FARMS] bound, matching the capture guard.
        if type(fid) == "number" and fid == math.floor(fid)
            and fid >= 1 and fid <= FarmManager.MAX_NUM_FARMS then
            if not seen[fid] then
                seen[fid] = true
                ids[#ids + 1] = fid
            end
        end
    end

    table.sort(ids)
    return ids
end

---Generates auto-export filename suffix based on type and period
---@param exportType string "daily", "monthly", or "yearly"
---@param periodIdentifier string date pattern (e.g., "2024-12-09", "2024-12", "2024")
---@return string suffix for filename
function RmTransactionLog.generateAutoExportSuffix(exportType, periodIdentifier)
    if exportType == "daily" then
        -- periodIdentifier = "2024-12-09" -> suffix = "auto_20241209"
        return "auto_" .. string.gsub(periodIdentifier, "-", "")
    elseif exportType == "monthly" then
        -- periodIdentifier = "2024-12" -> suffix = "auto_202412"
        return "auto_" .. string.gsub(periodIdentifier, "-", "")
    elseif exportType == "yearly" then
        -- periodIdentifier = "2024" -> suffix = "auto_2024"
        return "auto_" .. periodIdentifier
    end
    return "auto_unknown"
end

---Performs auto-export for the specified period -- ONE CSV per farm (TL-16). The server boundary CSV
---is split per farm so no single file mixes two farms' rows (research s12 decision 2; closes G10 on
---the auto-export path, the counterpart to the manual export TL-12 already farm-scoped). Flow: flush
---batches ONCE, filter the master to this PERIOD once, resolve the export directory once, then iterate
---the DISTINCT real farms present in the period rows -- each sliced through the SAME pure
---filterTransactionsByFarm seam and written with a farm-disambiguated suffix. Each per-farm export is
---wrapped in pcall so one bad farm (a false return OR a raise from a malformed row) is logged and the
---remaining farms still export.
---
---Server-authority is unchanged: the g_server guard stays at onDayChanged (TL-8). This function is
---module-INTERNAL (test-visible, no new production caller), so the redundant in-function g_server guard
---is intentionally omitted -- onDayChanged is the sole authority boundary. Farms are derived from the
---ROWS (collectFarmIds), never getFarmId(): a dedicated server has no local farm (G2). Singleplayer is
---behaviourally identical bar the filename gaining a `farm1` token (one farm -> one file; within-file
---row order is unchanged because exportToCSV sorts a shallow copy by (ingameDateTime, id)).
---@param exportType string "daily", "monthly", or "yearly"
---@param periodIdentifier string date pattern for the period to export
function RmTransactionLog.performAutoExport(exportType, periodIdentifier)
    Log:info(string.format("Performing auto-export: %s for period %s", exportType, periodIdentifier))

    -- Flush all pending batches before exporting to ensure we capture all transactions
    RmTransactionBatcher.flushAllBatches(RmTransactionLog.logTransaction, "auto-export")

    -- Filter transactions from the specified period only (once, for all farms)
    local allTransactions = RmTransactionLog.transactions or {}
    local periodRows = RmTransactionLog.filterTransactionsByPeriod(allTransactions, periodIdentifier)

    if #periodRows == 0 then
        Log:info(string.format("No transactions found for %s auto-export period: %s",
            exportType, periodIdentifier))
        return
    end

    -- Distinct real farms present in the period. collectFarmIds quarantines orphan/spectator/malformed
    -- farmIds, so every id here is guaranteed to slice a NON-EMPTY set -- the exporter never sees an
    -- empty set from this path (whose NO_DATA_MESSAGE would otherwise be misread as a write failure).
    local farmIds = RmTransactionLog.collectFarmIds(periodRows)
    if #farmIds == 0 then
        -- The period had rows but none carried a real farmId (all orphan/spectator/malformed).
        -- Distinct wording from the empty-period message so an operator can tell the two apart.
        Log:info(string.format("Auto-export (%s) found no real-farm rows for period: %s",
            exportType, periodIdentifier))
        return
    end

    -- Resolve the export directory ONCE (never per farm).
    local directory = RmTransactionLogExporter.getExportDirectory()
    if not directory then
        Log:error("Auto-export failed: No export directory available")
        return
    end

    local periodSuffix = RmTransactionLog.generateAutoExportSuffix(exportType, periodIdentifier)

    -- One CSV per farm. The `farm{n}` token is LOAD-BEARING: every per-farm file in this boundary shares
    -- the same second-granularity getDate timestamp, so without it the second farm's write would clobber
    -- the first. exportWithAutoFilename / generateFilename / exportToCSV are UNCHANGED (shared with the
    -- manual + v1-migration exports).
    local written = 0
    for _, farmId in ipairs(farmIds) do
        local farmRows = RmTransactionLog.filterTransactionsByFarm(periodRows, farmId)
        local suffix = "farm" .. farmId .. "_" .. periodSuffix
        -- pcall so a raise (e.g. resolveType on a malformed row) does not abort the whole boundary;
        -- successOrErr holds the error string when ok is false, else the exporter's success boolean.
        local ok, successOrErr, message, filename = pcall(
            RmTransactionLogExporter.exportWithAutoFilename, farmRows, directory, suffix)
        if not ok then
            Log:error(string.format("Auto-export (%s) raised for farm %d: %s",
                exportType, farmId, tostring(successOrErr)))
        elseif successOrErr then
            written = written + 1
            Log:info(string.format("Auto-exported %d transactions for farm %d (%s) to: %s",
                #farmRows, farmId, exportType, filename))
        else
            -- exporter returned false (bad directory, write error) -- log and continue to the next farm.
            Log:error(string.format("Auto-export (%s) failed for farm %d: %s",
                exportType, farmId, tostring(message)))
        end
    end

    Log:info(string.format("Auto-export (%s) wrote %d/%d per-farm files", exportType, written, #farmIds))
    if written == 0 then
        -- Every farm failed -- a wiped boundary must not be silent.
        Log:warning(string.format("Auto-export (%s) wrote NO files despite %d farm(s) with data",
            exportType, #farmIds))
    end
end

---Hook function for Farm.changeBalance to capture transactions
---@param self table the farm instance
---@param amount number transaction amount
---@param moneyType table money type with title and statistic properties
function RmTransactionLog.changeFarmBalance(self, amount, moneyType, ...)
    -- Server-authority guard: a joining client no-ops here; SP/host/dedi are always authority.
    if g_server == nil then return end
    -- Consume the pending context ONCE, as the FIRST statement after the guard -- before the trace
    -- logs, the self / amount / farmId guards, and getBalance -- so EVERY authoritative changeBalance
    -- clears the holder (even an early-returning, malformed, or batched one). This is the leak
    -- guarantee: a synchronously NESTED changeBalance (e.g. fired from within getBalance) finds the
    -- holder already cleared, so nothing crosses to a later transaction. Binds the whole 5-field record
    -- (TL-36) and threads ctx.<field> onward -- NOT a positional destructure: the DIRECT path into
    -- logTransaction's record, the batchable path into addToBatch (TL-22; sub-keys + stores them).
    local ctx = RmTransactionLog.consumePendingContext()
    Log:trace("Farm balance changed with parameters:")
    Log:trace(RmLogging.functionParametersToString(self, amount, moneyType, ...))

    -- Parameter validation
    if self == nil then
        Log:warning("changeFarmBalance called with nil farm")
        return
    end
    if amount == nil then
        Log:warning("changeFarmBalance called with nil amount")
        return
    end

    -- Server captures ALL real farms into the master list -- NO getFarmId() filter: that call
    -- returns nil/0 on a dedicated server with no local player and IS gap G2 (nothing captured).
    -- Instead a nil-safe, bounded sanity guard rejects the reserved spectator / guided-tour /
    -- invalid farm ids (FarmManager's reserved constants -- they are positive, so a bare `> 0`
    -- would wrongly admit them), a nil id (mid-construction/deletion), and anything past
    -- FarmManager.MAX_NUM_FARMS. `nil` is checked first because `nil <= 0` would raise. In pure SP
    -- only farm 1 exists, so capture is behaviorally identical to before.
    if self.farmId == nil or self.farmId <= 0 or self.farmId > FarmManager.MAX_NUM_FARMS then
        Log:debug(string.format(
            "changeFarmBalance rejected out-of-range farmId: %s", tostring(self.farmId)))
        return
    end

    -- Log the transaction
    if moneyType == nil then
        -- for some reason moneyType can be nil, so we handle that case
        moneyType = MoneyType.OTHER
        Log:warning("moneyType is nil, using MoneyType.OTHER")
    end

    local currentBalance = self:getBalance()
    Log:trace(string.format("Current farm balance after change: %.2f", currentBalance))
    local currentEquity = self:getEquity()
    Log:trace(string.format("Current farm equity before change: %.2f", currentEquity))

    -- Derive the stable constant name once; batch/log carry the raw snapshot.
    local constant = RmTransactionLog.getMoneyTypeConstant(moneyType.id)

    -- Use batching system for batchable transactions, log others directly
    if RmTransactionBatcher.shouldBatch(moneyType.statistic) then
        -- BATCHABLE path threads the consumed context record into the batch (TL-22/TL-36): addToBatch
        -- takes ONE context record, sub-keys on subjectId+location so distinct subjects/locations never
        -- merge, and stores the 5 fields on the batch so the flushed aggregate carries them. logFunction
        -- (logTransaction) stays the last argument.
        RmTransactionBatcher.addToBatch(amount, self.farmId, moneyType, constant, currentBalance,
            ctx, RmTransactionLog.logTransaction)
    else
        -- DIRECT path threads the consumed context record fields (TL-36) into a logTransaction record
        -- (TL-35). Named fields make positional misalignment impossible, so no explicit `comment`
        -- placeholder is needed -- `comment` is simply omitted and defaults to "" in logTransaction.
        RmTransactionLog.logTransaction({
            amount = amount,
            farmId = self.farmId,
            title = moneyType.title,
            statistic = moneyType.statistic,
            customEnv = moneyType.customEnv,
            constant = constant,
            currentFarmBalance = currentBalance,
            subjectId = ctx.subjectId,
            subjectName = ctx.subjectName,
            subjectKind = ctx.subjectKind,
            locationId = ctx.locationId,
            locationName = ctx.locationName,
        })
    end
end

---Join delivery: on a client finishing its initial sync, send it (TL-14) the current settings -
---GLOBALLY, before the farm gate, so even a spectator's menu shows the truth - then (TL-11) a snapshot
---of ONLY its own farm's history. Appended to FSBaseMission.sendInitialClientState (server-side; the
---base game resolves `farm` via getFarmForUniqueUserId and passes it in). Skips spectator farm 0 for
---the TRANSACTION snapshot only (settings still go out), mirroring
---how the base game skips its per-farm finance-stat send for the spectator farm (@see
---FSBaseMission.sendInitialClientState): a joining spectator's client store was already reset to {}
---by loadFromXMLFile before the client's g_server bail, so there is nothing to clear. The rest
---(mission present, nil / loopback connection) is guarded in sendSnapshotToConnection.
---@param self table the FSBaseMission instance (appended-hook receiver; unused)
---@param connection table the joining client's connection
---@param user table the joining user (base game resolved `farm` from it; unused here)
---@param farm table|nil the user's farm (nil / farmId 0 -> spectator, no snapshot)
function RmTransactionLog.onSendInitialClientState(self, connection, user, farm)
    if g_server == nil then return end
    -- Settings sync (TL-14) is GLOBAL - every joiner incl. a spectator gets current settings, so it
    -- MUST sit AFTER the g_server guard but BEFORE the farm-0 return (order is load-bearing).
    RmTransactionLog.sendSettingsToConnection(connection)
    if farm == nil or farm.farmId == 0 then return end
    RmTransactionLogSync.sendSnapshotToConnection(connection, farm.farmId)
end

---Farm-switch resync (TL-11): on PLAYER_FARM_CHANGED, re-send the switcher's connection a snapshot
---of the NEW farm's history so its client REPLACEs (dropping the old farm's rows). Subscribed on the
---server in loadMap. The message fires on BOTH sides, so guard g_server first. Unlike the join hook
---this does NOT gate farm 0 -- a switch to spectator sends an EMPTY snapshot to CLEAR the old
---farm's rows the store still holds. Defensive lifecycle guards: g_currentMission + userManager (no
---raise during teardown) and player + player.userId. On the SERVER this message is published by
---PlayerSetFarmEvent with a valid Player (userId set, new farmId set BEFORE the publish), so the nil
---guards are cheap defense, not a dropped switch; the nil-player publish is CLIENT-side, ignored by
---the g_server guard. Resolves the connection player.userId -> user -> getConnection();
---sendSnapshotToConnection skips a nil connection / the host loopback.
---Ground truth: @see UserManager.getUserByUserId, @see User.getConnection, @see PlayerSetFarmEvent.
---@param self table RmTransactionLog (message-center target)
---@param player table the Player that switched farms (player.farmId is the NEW farm)
function RmTransactionLog.onPlayerFarmChanged(self, player)
    if g_server == nil then return end
    if g_currentMission == nil or g_currentMission.userManager == nil then return end
    if player == nil or player.userId == nil then return end
    local user = g_currentMission.userManager:getUserByUserId(player.userId)
    local connection = user and user:getConnection()
    RmTransactionLogSync.sendSnapshotToConnection(connection, player.farmId)
end

---Saves all transactions to XML file in savegame directory
function RmTransactionLog.saveToXmlFile(self)
    -- Server-authority guard: only the authority owns the savegame; a client no-ops.
    if g_server == nil then return end
    Log:info("Saving transaction log to XML file...")

    -- Flush all pending batches before saving
    RmTransactionBatcher.flushAllBatches(RmTransactionLog.logTransaction, "save")

    -- Always write the versioned root, even at 0 rows: the file then exists as a v2
    -- stub so a fresh v2 session never re-triggers migration on the next load.
    local savegameFolderPath = g_currentMission.missionInfo.savegameDirectory .. "/"
    local rootKey = "RmTransactionLog"
    local xmlFile = createXMLFile(rootKey, savegameFolderPath .. "tl_transactions.xml", rootKey);
    if xmlFile == nil then
        Log:error("Failed to create XML file for transaction log.")
        return
    end
    setXMLString(xmlFile, rootKey .. "#schemaVersion", tostring(RmTransactionLog.SCHEMA_VERSION))
    -- Rows are written in master insertion order, which is ascending-id order (ids are
    -- allocated monotonically at capture and the master is append-only, never sorted in
    -- place - the GUI and the CSV exporter both sort COPIES). deriveLoadedIds preserves a
    -- persisted id only if it is strictly greater than the running max, so it relies on
    -- this ascending order; do NOT reorder the master before saving.
    local i = 0
    for _, transaction in ipairs(RmTransactionLog.transactions) do
        local transactionKey = string.format("%s.transactions.transaction(%d)", rootKey, i)
        -- Additive `#id`: the row's real id (every in-memory row has a positive id,
        -- assigned at capture or repaired on load), never a `... or 0` fallback.
        setXMLInt(xmlFile, transactionKey .. "#id", transaction.id)
        setXMLString(xmlFile, transactionKey .. "#realDateTime", transaction.realDateTime or "")
        setXMLString(xmlFile, transactionKey .. "#ingameDateTime", transaction.ingameDateTime or "")
        setXMLInt(xmlFile, transactionKey .. "#farmId", transaction.farmId or 0)
        setXMLFloat(xmlFile, transactionKey .. "#amount", transaction.amount)
        setXMLString(xmlFile, transactionKey .. "#title", transaction.title or "")
        setXMLString(xmlFile, transactionKey .. "#statistic", transaction.statistic or "")
        setXMLString(xmlFile, transactionKey .. "#customEnv", transaction.customEnv or "")
        setXMLString(xmlFile, transactionKey .. "#constant", transaction.constant or "")
        setXMLFloat(xmlFile, transactionKey .. "#currentFarmBalance", transaction.currentFarmBalance or 0)
        setXMLString(xmlFile, transactionKey .. "#comment", transaction.comment or "")
        -- Additive enrichment attrs (TL-18/TL-36): nil -> "". No schemaVersion bump (stays 2), same
        -- additive precedent as the TL-7 `#id`. Name-addressed, so order is irrelevant; a pre-enrichment
        -- save simply lacks them and each loads back as nil INDEPENDENTLY.
        setXMLString(xmlFile, transactionKey .. "#subjectId", transaction.subjectId or "")
        setXMLString(xmlFile, transactionKey .. "#subjectName", transaction.subjectName or "")
        setXMLString(xmlFile, transactionKey .. "#subjectKind", transaction.subjectKind or "")
        setXMLString(xmlFile, transactionKey .. "#locationId", transaction.locationId or "")
        setXMLString(xmlFile, transactionKey .. "#locationName", transaction.locationName or "")
        i = i + 1
    end

    saveXMLFile(xmlFile);
    Log:info(string.format("Saved %d transactions to tl_transactions.xml (schemaVersion=%d).",
        i, RmTransactionLog.SCHEMA_VERSION))
    delete(xmlFile);
end

---Assigns a stable id to each SURVIVING loaded row, repairing any invalid persisted
---`#id` in one pass. Pure: reads/writes only the passed `rows` (no module state), so the
---id suite stays no-mutation. A row keeps its persisted id iff it is a number strictly
---greater than the running max (post-id files are written in ascending id order, so valid
---ids survive untouched); absent / non-numeric / 0 / negative / duplicate / out-of-order
---ids all fold into the single `id <= maxId` repair branch and become max+1. A pre-id v2
---file gets 1..N. Rows dropped upstream (missing amount/ingameDateTime) never reach here,
---so their `#id` is not reserved.
---@param rows table array of { id = integer|nil, ... }; each row.id is set in place
---@return number nextId the counter to resume from (max+1; 1 when rows is empty)
function RmTransactionLog.deriveLoadedIds(rows)
    local maxId = 0
    for _, r in ipairs(rows) do
        local id = r.id
        if type(id) ~= "number" or id <= maxId then
            id = maxId + 1
        end
        r.id = id
        maxId = id
    end
    return maxId + 1
end

---Loads transactions from XML file in savegame directory
function RmTransactionLog.loadFromXMLFile()
    -- Start every load from a clean slate: the table + counter outlive g_currentMission
    -- (only the mission is rebuilt between saves), so a second save loaded in one session
    -- must not inherit the prior save's rows or id counter. Each exit path below sets the
    -- counter unconditionally: fresh / no-file / unreadable -> 1, legacy -> migrateV1 sets
    -- 1, v2 -> max+1 over the surviving rows.
    RmTransactionLog.transactions = {}
    RmTransactionLog.nextTransactionId = 1

    -- Server-authority guard: the reset above always runs; a client stops before savegame I/O.
    if g_server == nil then return end

    if not g_currentMission or not g_currentMission.missionInfo.savegameDirectory then
        Log:warning(
            "No current savegameDirectory available. No transactions to load. Ignore this if you are loading a new game.")
        return
    end
    local savegameFolderPath = g_currentMission.missionInfo.savegameDirectory .. "/"
    if not fileExists(savegameFolderPath .. "tl_transactions.xml") then
        Log:warning("No transaction log XML file found at path: %s", savegameFolderPath .. "tl_transactions.xml")
        Log:warning(
            "No transactions to load. Ignore this if it is the first time loading savegame with this mod or you have just cleared the log.")
        return
    end

    local xmlFile = loadXMLFile("RmTransactionLog", savegameFolderPath .. "tl_transactions.xml")
    if xmlFile == nil then
        Log:error("Could not load transaction log XML file: %s", savegameFolderPath .. "tl_transactions.xml")
        return
    end

    local rootKey = "RmTransactionLog"

    -- Detect the schema version BEFORE the record loop. A legacy (v1) file has no
    -- schemaVersion; hand it to the clean-break migration (which sets the counter) and stop.
    local schemaVersionRaw = getXMLString(xmlFile, rootKey .. "#schemaVersion")
    if RmTransactionMigration.isLegacyVersion(schemaVersionRaw) then
        Log:info("Legacy transaction file detected (schemaVersion=%s); starting migration.",
            tostring(schemaVersionRaw))
        local v1Rows = RmTransactionMigration.readV1Rows(xmlFile, rootKey)
        delete(xmlFile)
        RmTransactionMigration.migrateV1(savegameFolderPath, v1Rows)
        return
    end

    -- v2: read every surviving row into a local list (carrying its maybe-#id), derive
    -- stable ids over the survivors in one pass, then commit them to the module table.
    local rows = {}
    local i = 0
    local skipped = 0
    while true do
        local transactionKey = string.format("%s.transactions.transaction(%d)", rootKey, i)
        if not hasXMLProperty(xmlFile, transactionKey) then
            Log:debug("No more transactions found in XML file at index: " .. i)
            break
        end
        i = i + 1

        local amount = getXMLFloat(xmlFile, transactionKey .. "#amount")
        local ingameDateTime = getXMLString(xmlFile, transactionKey .. "#ingameDateTime")
        if amount == nil or ingameDateTime == nil then
            Log:error("Skipping malformed transaction at index %d (missing amount or ingameDateTime)", i - 1)
            skipped = skipped + 1
        else
            local customEnv = getXMLString(xmlFile, transactionKey .. "#customEnv")
            local constant = getXMLString(xmlFile, transactionKey .. "#constant")
            -- Additive enrichment attrs (TL-18/TL-36). getXMLString returns nil for an absent attr, so
            -- use the nil-guarded three-part form; each normalizes INDEPENDENTLY (no cross-field coupling)
            -- and a pre-enrichment v2 save (attrs absent) loads all five as nil.
            local subjectId = getXMLString(xmlFile, transactionKey .. "#subjectId")
            local subjectName = getXMLString(xmlFile, transactionKey .. "#subjectName")
            local subjectKind = getXMLString(xmlFile, transactionKey .. "#subjectKind")
            local locationId = getXMLString(xmlFile, transactionKey .. "#locationId")
            local locationName = getXMLString(xmlFile, transactionKey .. "#locationName")
            table.insert(rows, {
                -- getXMLInt -> integer|nil; deriveLoadedIds repairs nil / invalid below.
                id = getXMLInt(xmlFile, transactionKey .. "#id"),
                realDateTime = getXMLString(xmlFile, transactionKey .. "#realDateTime"),
                ingameDateTime = ingameDateTime,
                farmId = getXMLInt(xmlFile, transactionKey .. "#farmId"),
                amount = amount,
                title = getXMLString(xmlFile, transactionKey .. "#title"),
                statistic = getXMLString(xmlFile, transactionKey .. "#statistic") or "",
                customEnv = (customEnv ~= nil and customEnv ~= "" and customEnv) or nil,
                constant = (constant ~= nil and constant ~= "" and constant) or nil,
                currentFarmBalance = getXMLFloat(xmlFile, transactionKey .. "#currentFarmBalance") or 0,
                comment = getXMLString(xmlFile, transactionKey .. "#comment") or "",
                subjectId = (subjectId ~= nil and subjectId ~= "" and subjectId) or nil,
                subjectName = (subjectName ~= nil and subjectName ~= "" and subjectName) or nil,
                subjectKind = (subjectKind ~= nil and subjectKind ~= "" and subjectKind) or nil,
                locationId = (locationId ~= nil and locationId ~= "" and locationId) or nil,
                locationName = (locationName ~= nil and locationName ~= "" and locationName) or nil,
            })
        end
    end

    delete(xmlFile)

    -- Assign / repair ids over the survivors and resume the counter at max+1.
    RmTransactionLog.nextTransactionId = RmTransactionLog.deriveLoadedIds(rows)
    RmTransactionLog.transactions = rows

    Log:info(string.format(
        "Transaction log loaded from XML file. Loaded %d transactions (%d skipped); nextTransactionId=%d.",
        #rows, skipped, RmTransactionLog.nextTransactionId))
end

function RmTransactionLog.loadMap(self)
    Log:debug("Mod loaded!")

    -- Mod Lua state outlives g_currentMission (only the mission is rebuilt between
    -- savegame loads), so clear the per-load migration guard here. Without this, a
    -- second legacy save loaded in the same session would skip its own migration.
    RmTransactionMigration._migrationDone = false

    local modSettingsDir = g_modSettingsDirectory and (g_modSettingsDirectory .. "/FS25_TransactionLog") or nil
    if modSettingsDir then
        createFolder(modSettingsDir)
    end

    -- Initialize and load settings (settings must be available before UI interactions)
    RmTransactionLog.settings = RmTransactionLogSettings.new()
    RmTransactionLog.settings:readSettings()

    -- Verify settings initialization succeeded
    if not RmTransactionLog.settings then
        Log:error("Critical: Settings initialization failed")
        return
    end

    Log:debug("Settings system initialized successfully")

    -- Initialize auto-export date tracking system
    RmTransactionLog.initializeAutoExportTracking()

    -- Subscribe to day change events for auto-export functionality
    g_messageCenter:subscribe(MessageType.DAY_CHANGED, RmTransactionLog.onDayChanged, RmTransactionLog)

    -- Farm-switch resync (TL-11): re-send a client its NEW farm's snapshot when it switches farms.
    -- The message fires on both server and client; onPlayerFarmChanged guards g_server. Subscribed
    -- here (inside loadMap) because message-center subscriptions are cleared per mission, so they
    -- must re-subscribe each load -- the same reason DAY_CHANGED lives here, not at file scope.
    g_messageCenter:subscribe(MessageType.PLAYER_FARM_CHANGED, RmTransactionLog.onPlayerFarmChanged, RmTransactionLog)

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
    Log:debug("Adding player action events")
    local triggerUp, triggerDown, triggerAlways = false, true, false
    local startActive, callbackState, disableConflictingBindings = true, nil, true
    local success, actionEventId = g_inputBinding:registerActionEvent(
        InputAction.RM_SHOW_TRANSACTION_LOG, RmTransactionLog, RmTransactionLog.showTransactionLog,
        triggerUp, triggerDown, triggerAlways, startActive, callbackState, disableConflictingBindings)
    if not success and controlling ~= "VEHICLE" then
        Log:error("Failed to register action event for RM_SHOW_TRANSACTION_LOG")
        return
    end
    -- Hide the action event text
    g_inputBinding:setActionEventTextVisibility(actionEventId, false)
end

function RmTransactionLog.currentMissionStarted(self)
    Log:debug("Current mission started")

    -- Append the mod's addMoney function to the existing g_currentMission.addMoney function
    -- Not sure this is the right hook, since it also captures money transactions not related to the player
    if g_currentMission.addMoney == nil then
        Log:error("g_currentMission.addMoney is nil, cannot append function.")
        return
    end
    -- hopefully this wil not be needed. Seems all transactions are logged through  farm.changeBalance
    -- g_currentMission.addMoney = Utils.appendedFunction(g_currentMission.addMoney, RmTransactionLog.addMoney)

    -- Register for update events to handle batch processing
    g_currentMission:addUpdateable(RmTransactionLog)
end

-- Update tracking state
RmTransactionLog.updateTimer = 0

function RmTransactionLog.update(self, dt)
    -- Validate dt parameter
    if type(dt) ~= "number" then
        Log:error("Update called with invalid dt parameter: %s (type: %s)", tostring(dt), type(dt))
        return
    end

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

-- SellingStation subject capture (TL-26): install the sold-fillType prepend once, here at FILE scope
-- (NOT in loadMap, which re-runs per mission and would stack duplicate prepends -- the once-per-process
-- class-method-hook rule). This is the mod's first prepend; all prior hooks are appendedFunction.
RmTransactionLog.installSellingStationCaptureHook()

-- Animal buy/sell subject capture (TL-23): install the two animal-trade prepends once, here at FILE scope
-- (same once-per-process rule as the TL-26 installer above -- loadMap would stack duplicate prepends). This
-- is the mod's SECOND prepend site, mirroring the SellingStation installer.
RmTransactionLog.installAnimalTradeCaptureHooks()

-- Shop buy/sell subject capture (TL-24): install the six shop prepends once, here at FILE scope (same
-- once-per-process rule as the TL-26/TL-23 installers above -- loadMap would stack duplicate prepends). The
-- mod's THIRD prepend site-group (three Buy*Data.onBought + three Sell*Event.run); all resolve to
-- subjectKind "storeItem".
RmTransactionLog.installShopSubjectHooks()

-- Production direct-sell subject + location capture (TL-28): install the two ProductionPoint overwrites
-- once, here at FILE scope (same once-per-process rule as the installers above -- loadMap would stack
-- duplicate wraps). The mod's FIRST overwrite site-group (the per-output money credits sit inside a loop,
-- so a prepend cannot tag each row -- see the block above); each target is presence + dependency gated and
-- degrades to a clean skip + WARNING.
RmTransactionLog.installProductionDirectSellHooks()

-- Production running-cost location capture (TL-46): install the claimProductionCosts prepend once, here at
-- FILE scope (same once-per-process rule as the installers above -- loadMap would stack duplicate prepends),
-- beside the TL-28 direct-sell overwrite installer. Arms LOCATION only (no subject) on the ~hourly running-cost
-- charge; a PREPEND fits because claimProductionCosts has a single guarded addMoney with an unused return.
RmTransactionLog.installProductionClaimCostHook()

-- BuyingStation input-purchase subject capture (TL-27): install the addFillLevelToFillableObject capture wrap
-- once, here at FILE scope (same once-per-process rule as the installers above -- loadMap would stack
-- duplicate wraps). A RETURN-PRESERVING Utils.overwrittenFunction wrap (the mod's SECOND overwrittenFunction
-- site, after TL-28) -- NOT a prepend, because the method's return value is load-bearing and must be
-- forwarded (see wrapBuyingStationFill); fuel/seed/fertilizer/water/lime buys at a buying station resolve to subjectKind
-- "fillType", location left nil (out of scope).
RmTransactionLog.installBuyingStationCaptureHook()

-- Join delivery (TL-11): append the snapshot send onto FSBaseMission.sendInitialClientState at FILE
-- scope (NOT in loadMap). A class-method hook must be appended ONCE per process; loadMap re-runs per
-- mission load, so appending there would stack a second copy on every reload. (The saveSavegame
-- append inside loadMap above is a latent duplicate-append across reloads by this same reasoning --
-- pre-existing and out of scope here; do NOT copy that placement for this new append.)
FSBaseMission.sendInitialClientState = Utils.appendedFunction(
    FSBaseMission.sendInitialClientState, RmTransactionLog.onSendInitialClientState)

-- Settings menu integration
local inGameMenu = g_gui.screenControllers[InGameMenu]
local settingsPage = inGameMenu.pageSettings
local settingsLayout = settingsPage.generalSettingsLayout

RmTransactionLogControls = {}
RmTransactionLogControls.name = settingsPage.name

function RmTransactionLogControls.onMenuOptionChanged(self, state, menuOption)
    local id = menuOption.id
    local settingDef = RmTransactionLogSettings.DEFINITIONS[id]
    if not settingDef then
        Log:error("Unknown setting in onMenuOptionChanged: " .. tostring(id))
        return
    end

    local value = settingDef.values[state]

    if value ~= nil then
        Log:debug("SET " .. id .. " = " .. tostring(value))
        -- TL-14: route the change through the server-authoritative seam instead of applying + persisting
        -- inline. On the authority (SP / listen-host) requestSettingChange applies + persists + broadcasts;
        -- on a pure client it sends the request to the server (the security boundary). The settings-nil
        -- guard now lives in requestSettingChange (no client may persist, so no inline writeSettings here).
        RmTransactionLog.requestSettingChange(id, value)
    end
end

function RmTransactionLog.addMenuOption(id)
    local function updateFocusIds(element)
        if not element then
            return
        end
        element.focusId = FocusManager:serveAutoFocusId()
        for _, child in pairs(element.elements) do
            updateFocusIds(child)
        end
    end

    local settingDef = RmTransactionLogSettings.DEFINITIONS[id]
    if not settingDef then
        Log:error("Unknown setting definition for: " .. tostring(id))
        return
    end

    local original = settingsPage.multiVolumeVoiceBox
    local options = settingDef.strings
    local callback = "onMenuOptionChanged"

    local menuOptionBox = original:clone(settingsLayout)
    if not menuOptionBox then
        Log:error("could not create menu option box")
        return
    end
    menuOptionBox.id = id .. "box"

    local menuOption = menuOptionBox.elements[1]
    if not menuOption then
        Log:error("could not create menu option")
        return
    end

    menuOption.id = id
    menuOption.target = RmTransactionLogControls

    menuOption:setCallback("onClickCallback", callback)
    menuOption:setDisabled(false)

    local toolTip = menuOption.elements[1]
    toolTip:setText(g_i18n:getText("tooltip_transactionlog_" .. id))

    local setting = menuOptionBox.elements[2]
    setting:setText(g_i18n:getText("setting_transactionlog_" .. id))

    menuOption:setTexts({ unpack(options) })
    -- Settings may not be initialized yet during UI setup, use default state
    if RmTransactionLog.settings then
        menuOption:setState(RmTransactionLog.settings:getStateIndex(id))
    else
        menuOption:setState(settingDef.default or 1)
    end

    RmTransactionLog.CONTROLS[id] = menuOption

    updateFocusIds(menuOptionBox)
    table.insert(settingsPage.controlsList, menuOptionBox)

    return menuOption
end

-- Create section title
local sectionTitle = nil
for _, elem in ipairs(settingsLayout.elements) do
    if elem.name == "sectionHeader" then
        sectionTitle = elem:clone(settingsLayout)
        break
    end
end
if sectionTitle then
    sectionTitle:setText(g_i18n:getText("menu_TransactionLog_title"))
else
    local title = TextElement.new()
    title:applyProfile("fs25_settingsSectionHeader", true)
    title:setText(g_i18n:getText("menu_TransactionLog_title"))
    title.name = "sectionHeader"
    settingsLayout:addElement(title)
end

sectionTitle.focusId = FocusManager:serveAutoFocusId()
table.insert(settingsPage.controlsList, sectionTitle)
RmTransactionLog.CONTROLS[sectionTitle.name] = sectionTitle

-- Add menu options
for _, id in pairs(RmTransactionLogSettings.MENU_ITEMS) do
    RmTransactionLog.addMenuOption(id)
end
settingsLayout:invalidateLayout()

-- Allow keyboard navigation of menu options
FocusManager.setGui = Utils.appendedFunction(FocusManager.setGui, function(_, gui)
    if gui == "ingameMenuSettings" then
        -- Let the focus manager know about our custom controls now (earlier than this point seems to fail)
        for _, control in pairs(RmTransactionLog.CONTROLS) do
            if not control.focusId or not FocusManager.currentFocusData.idToElementMapping[control.focusId] then
                if not FocusManager:loadElementFromCustomValues(control, nil, nil, false, false) then
                    Log:warning("Could not register control " ..
                        (control.id or control.name or control.focusId) .. " with the focus manager")
                end
            end
        end
        -- Invalidate the layout so the up/down connections are analyzed again by the focus manager
        local settingsPage = g_gui.screenControllers[InGameMenu].pageSettings
        settingsPage.generalSettingsLayout:invalidateLayout()
    end
end)

InGameMenuSettingsFrame.onFrameOpen = Utils.appendedFunction(InGameMenuSettingsFrame.onFrameOpen, function()
    local isAdmin = g_currentMission:getIsServer() or g_currentMission.isMasterUser

    for _, id in pairs(RmTransactionLogSettings.MENU_ITEMS) do
        local menuOption = RmTransactionLog.CONTROLS[id]
        if menuOption then
            -- Settings should be initialized by the time UI is opened during gameplay
            if RmTransactionLog.settings then
                menuOption:setState(RmTransactionLog.settings:getStateIndex(id))
            else
                Log:warning("Settings not initialized when opening settings frame")
                local settingDef = RmTransactionLogSettings.DEFINITIONS[id]
                menuOption:setState(settingDef and settingDef.default or 1)
            end
            menuOption:setDisabled(not isAdmin)
        end
    end
end)

addModEventListener(RmTransactionLog)
