-- RmTransactionLog.lua
-- Main transaction logging system for FS25 Transaction Log mod
-- Author: Ritter
-- Description: Tracks and logs financial transactions in Farming Simulator 25

RmTransactionLog = {}
local RmTransactionLog_mt = Class(RmTransactionLog)

-- Constants
RmTransactionLog.START_YEAR = 2025      -- Start year for the transaction log (Year 1 = 2025)
RmTransactionLog.UPDATE_INTERVAL = 1000 -- Check batches every 1 second (1000ms)

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

    if self.farmId ~= g_currentMission:getFarmId() then
        Log:debug(string.format(
            "changeFarmBalance called with farmId: %s, but current farmId is: %s",
            tostring(self.farmId), tostring(g_currentMission:getFarmId())))
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
        -- Settings are initialized in loadMap() and should be available during UI interactions
        if RmTransactionLog.settings then
            if RmTransactionLog.settings:setValue(id, value) then
                RmTransactionLog.settings:writeSettings()
            else
                Log:error("Failed to set setting " .. id .. ", not saving settings")
            end
        else
            Log:error("Settings not initialized, cannot save setting: " .. id)
        end
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
