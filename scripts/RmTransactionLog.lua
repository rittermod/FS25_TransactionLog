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
-- persist an oversized comment. Defined BEFORE the source() chain below so the frame, sourced
-- there, can read it at load time.
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

---Creates a new RmTransactionLog instance
---@param customMt table|nil optional custom metatable
---@return table the new transaction log instance
function RmTransactionLog.new(customMt)
    local self = setmetatable({}, customMt or RmTransactionLog_mt)
    self.transactions = RmTransactionLog.transactions -- Reference to shared transaction table
    return self
end

RmTransactionLog.dir = g_currentModDirectory
source(RmTransactionLog.dir .. "scripts/gui/RmTransactionLogFrame.lua")
source(RmTransactionLog.dir .. "scripts/gui/RmCommentInputDialog.lua")
source(RmTransactionLog.dir .. "scripts/rmlib/RmLogging.lua")
source(RmTransactionLog.dir .. "scripts/RmTransactionBatcher.lua")
source(RmTransactionLog.dir .. "scripts/RmTransactionLogSettings.lua")
source(RmTransactionLog.dir .. "scripts/RmTransactionLogExporter.lua")
source(RmTransactionLog.dir .. "scripts/RmTransactionMigration.lua")
-- MP event layer (2.0; under construction). Sourced under the still-off multiplayer flag so
-- both files are present on server AND client when the flag flips at TL-12
-- (mp-event-not-sourced-on-client). Sync codec FIRST so the event can delegate to it.
source(RmTransactionLog.dir .. "scripts/RmTransactionLogSync.lua")
source(RmTransactionLog.dir .. "scripts/events/RmAddTransactionEvent.lua")
source(RmTransactionLog.dir .. "scripts/events/RmTransactionSnapshotEvent.lua")
source(RmTransactionLog.dir .. "scripts/events/RmEditCommentEvent.lua")
source(RmTransactionLog.dir .. "scripts/events/RmSettingsChangeEvent.lua")

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

---Logs a single transaction to the transaction log.
---Stores the money-type snapshot RAW (i18n keys + identity), never resolved text -
---display resolution happens in the GUI/exporter, keeping the log language-agnostic.
---@param amount number transaction amount (signed: negative = expense)
---@param farmId number the farm ID that performed the transaction
---@param title string|nil money-type title i18n key (moneyType.title, e.g. "finance_other")
---@param statistic string|nil money-type statistic key (moneyType.statistic, e.g. "other")
---@param customEnv string|nil owning mod env for the title key, best-effort (nil for base)
---@param constant string|nil derived MoneyType constant name (e.g. "VEHICLE_REPAIR")
---@param currentFarmBalance number current farm balance after transaction
---@param comment string|nil optional comment for the transaction
function RmTransactionLog.logTransaction(amount, farmId, title, statistic, customEnv, constant, currentFarmBalance,
                                         comment)
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
        Log:debug("logTransaction called with amount 0, ignoring transaction")
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
    -- Empty customEnv/constant normalize to nil (never concat/getText onto nil).
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
    }

    table.insert(RmTransactionLog.transactions, transaction)
    Log:info(string.format(
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

---Performs auto-export for specified period
---@param exportType string "daily", "monthly", or "yearly"
---@param periodIdentifier string date pattern for the period to export
function RmTransactionLog.performAutoExport(exportType, periodIdentifier)
    Log:info(string.format("Performing auto-export: %s for period %s", exportType, periodIdentifier))

    -- Flush all pending batches before exporting to ensure we capture all transactions
    RmTransactionBatcher.flushAllBatches(RmTransactionLog.logTransaction)

    -- Filter transactions from the specified period only
    local allTransactions = RmTransactionLog.transactions or {}
    local filteredTransactions = RmTransactionLog.filterTransactionsByPeriod(allTransactions, periodIdentifier)

    if #filteredTransactions == 0 then
        Log:info(string.format("No transactions found for %s auto-export period: %s",
            exportType, periodIdentifier))
        return
    end

    -- Generate auto-export filename based on type
    local suffix = RmTransactionLog.generateAutoExportSuffix(exportType, periodIdentifier)
    local directory = RmTransactionLogExporter.getExportDirectory()

    if not directory then
        Log:error("Auto-export failed: No export directory available")
        return
    end

    -- Perform export
    local success, message, filename = RmTransactionLogExporter.exportWithAutoFilename(
        filteredTransactions, directory, suffix)

    if success then
        Log:info(string.format("Auto-exported %d transactions (%s) to: %s",
            #filteredTransactions, exportType, filename))
    else
        Log:error(string.format("Auto-export (%s) failed: %s", exportType, message))
    end
end

---Hook function for Farm.changeBalance to capture transactions
---@param self table the farm instance
---@param amount number transaction amount
---@param moneyType table money type with title and statistic properties
function RmTransactionLog.changeFarmBalance(self, amount, moneyType, ...)
    -- Server-authority guard: a joining client no-ops here; SP/host/dedi are always authority.
    if g_server == nil then return end
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
    Log:debug(string.format("Current farm balance after change: %.2f", currentBalance))
    local currentEquity = self:getEquity()
    Log:debug(string.format("Current farm equity before change: %.2f", currentEquity))

    -- Derive the stable constant name once; batch/log carry the raw snapshot.
    local constant = RmTransactionLog.getMoneyTypeConstant(moneyType.id)

    -- Use batching system for batchable transactions, log others directly
    if RmTransactionBatcher.shouldBatch(moneyType.statistic) then
        RmTransactionBatcher.addToBatch(amount, self.farmId, moneyType, constant, currentBalance,
            RmTransactionLog.logTransaction)
    else
        RmTransactionLog.logTransaction(amount, self.farmId, moneyType.title, moneyType.statistic,
            moneyType.customEnv, constant, currentBalance)
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
    RmTransactionBatcher.flushAllBatches(RmTransactionLog.logTransaction)

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
