-- RmTransactionMigration.lua
-- Clean-break v1 -> v2 migration for FS25 Transaction Log mod
-- Author: Ritter
-- Description: Detects a legacy (v1) transaction file, exports/backs up its rows
--              OUTSIDE the savegame folder, resets to a fresh v2 log, and warns the
--              player. There is NO v1->v2 record migration: v1 stored eagerly-resolved
--              text, v2 stores keys, so the old records cannot become v2 records.
--              All side effects run synchronously at load; only the warning dialog
--              defers (the GUI is not ready to host a dialog mid-load).

RmTransactionMigration = {}
local Log = RmLogging.getLogger("TransactionLog")

-- Constants
RmTransactionMigration.DIALOG_DELAY_MS = 100 -- Defer the warning until the GUI settles after load

-- Per-session re-entrancy guard: the destructive path must run at most once per load.
RmTransactionMigration._migrationDone = false

-- ============================================================
-- Pure logic (unit-tested via tlTest)
-- ============================================================

---Classifies a file's raw schemaVersion attribute as legacy (v1) or not.
---A legacy file has no numeric schemaVersion >= 2: nil, "", "abc" and "1" are all v1.
---@param schemaVersionRaw string|nil the raw `RmTransactionLog#schemaVersion` attribute
---@return boolean isLegacy true when the file must be migrated
function RmTransactionMigration.isLegacyVersion(schemaVersionRaw)
    local version = tonumber(schemaVersionRaw)
    return version == nil or version < 2
end

---Selects the migration outcome from the row count and the export/backup results.
---@param rowCount number number of v1 rows read
---@param csvExported boolean CSV export succeeded
---@param rawBackedUp boolean raw XML backup succeeded
---@return string outcome one of "empty" | "export" | "backup" | "nobackup"
function RmTransactionMigration.chooseOutcome(rowCount, csvExported, rawBackedUp)
    if rowCount == 0 then
        return "empty"
    end
    if csvExported then
        return "export"
    end
    if rawBackedUp then
        return "backup"
    end
    return "nobackup"
end

-- ============================================================
-- File I/O helpers (manual-tested via the in-game walkthrough)
-- ============================================================

---Reads legacy (v1) rows from an open XML handle using the v1 attribute names
---(transactionType/transactionStatistic hold already-resolved TEXT, not keys).
---@param xmlFile number open XML file handle
---@param rootKey string root key ("RmTransactionLog")
---@return table rows array of v1-shaped transaction records
function RmTransactionMigration.readV1Rows(xmlFile, rootKey)
    local rows = {}
    local i = 0
    while true do
        local transactionKey = string.format("%s.transactions.transaction(%d)", rootKey, i)
        if not hasXMLProperty(xmlFile, transactionKey) then
            break
        end
        table.insert(rows, {
            realDateTime = getXMLString(xmlFile, transactionKey .. "#realDateTime"),
            ingameDateTime = getXMLString(xmlFile, transactionKey .. "#ingameDateTime"),
            farmId = getXMLInt(xmlFile, transactionKey .. "#farmId"),
            amount = getXMLFloat(xmlFile, transactionKey .. "#amount"),
            transactionType = getXMLString(xmlFile, transactionKey .. "#transactionType") or "",
            transactionStatistic = getXMLString(xmlFile, transactionKey .. "#transactionStatistic") or "",
            currentFarmBalance = getXMLFloat(xmlFile, transactionKey .. "#currentFarmBalance") or 0,
            comment = getXMLString(xmlFile, transactionKey .. "#comment") or "",
        })
        i = i + 1
    end
    Log:debug("Read %d legacy (v1) rows for migration", #rows)
    return rows
end

---Builds a collision-safe backup path in the mod settings folder for the raw v1 file.
---@param directory string mod settings directory (trailing slash)
---@return string path a path that does not yet exist on disk
local function uniqueBackupPath(directory)
    local savegameIndex = 0
    if g_currentMission and g_currentMission.missionInfo and g_currentMission.missionInfo.savegameIndex then
        savegameIndex = g_currentMission.missionInfo.savegameIndex
    end
    local timestamp = getDate("%Y%m%d_%H%M%S")
    local base = string.format("tl_transactions_v1_backup_sg%02d_%s", savegameIndex, timestamp)
    local path = directory .. base .. ".xml"
    local counter = 1
    while fileExists(path) do
        path = string.format("%s%s_%d.xml", directory, base, counter)
        counter = counter + 1
    end
    return path
end

---Copies the raw v1 file byte-for-byte into the mod settings folder as a fallback
---when CSV export is unavailable. Binary, length-verified, never raises.
---@param savegameFolderPath string savegame folder (trailing slash)
---@return boolean success true when a verified backup was written
---@return string|nil filename the backup filename (for the dialog) or nil on failure
function RmTransactionMigration.backupRawV1(savegameFolderPath)
    local directory = RmTransactionLogExporter.getExportDirectory()
    if not directory then
        Log:warning("No mod settings directory available for raw v1 backup")
        return false, nil
    end

    local sourcePath = savegameFolderPath .. "tl_transactions.xml"
    local destinationPath = uniqueBackupPath(directory)

    local ok, err = pcall(function()
        local source = io.open(sourcePath, "rb")
        if not source then
            error("cannot open source file")
        end
        local data = source:read("*a")
        source:close()

        local destination = io.open(destinationPath, "wb")
        if not destination then
            error("cannot open destination file")
        end
        destination:write(data)
        destination:close()

        -- Verify the written copy is byte-length-identical to the source.
        local verify = io.open(destinationPath, "rb")
        local written = verify and verify:read("*a") or ""
        if verify then
            verify:close()
        end
        if #written ~= #data then
            error(string.format("size mismatch (source %d bytes, backup %d bytes)", #data, #written))
        end
    end)

    if ok then
        local filename = string.gsub(destinationPath, ".*/", "")
        Log:warning("v1 CSV export failed; wrote raw backup to %s", destinationPath)
        return true, filename
    end
    Log:error("v1 raw backup failed: %s", tostring(err))
    return false, nil
end

---Writes a fresh v2 stub (versioned root, 0 rows) over the savegame's transaction
---file to neutralize a migrated v1 file so it never re-migrates.
---@param savegameFolderPath string savegame folder (trailing slash)
---@return boolean success
function RmTransactionMigration.writeV2Stub(savegameFolderPath)
    local rootKey = "RmTransactionLog"
    local path = savegameFolderPath .. "tl_transactions.xml"
    local xmlFile = createXMLFile(rootKey, path, rootKey)
    if xmlFile == nil then
        Log:error("Failed to write v2 stub file at %s", path)
        return false
    end
    setXMLString(xmlFile, rootKey .. "#schemaVersion", tostring(RmTransactionLog.SCHEMA_VERSION))
    saveXMLFile(xmlFile)
    delete(xmlFile)
    Log:info("Wrote fresh v2 stub tl_transactions.xml")
    return true
end

---Shows the destructive-migration warning, deferred until the GUI is ready. The
---mission/GUI are re-checked INSIDE the callback (either can tear down during the
---delay); when absent the warning is skipped and logged rather than crashing.
---@param outcome string "export" | "backup" | "nobackup"
---@param csvFilename string|nil CSV filename (export outcome)
---@param backupFilename string|nil backup filename (backup outcome)
function RmTransactionMigration.showMigrationDialog(outcome, csvFilename, backupFilename)
    local title = g_i18n:getText("ui_transaction_log_migration_title")
    local message
    if outcome == "export" then
        message = string.format(g_i18n:getText("ui_transaction_log_migration_message"), tostring(csvFilename))
    elseif outcome == "backup" then
        message = string.format(g_i18n:getText("ui_transaction_log_migration_message_failed"), tostring(backupFilename))
    else
        message = g_i18n:getText("ui_transaction_log_migration_message_failed_nobackup")
    end
    local body = title .. "\n\n" .. message

    Timer.createOneshot(RmTransactionMigration.DIALOG_DELAY_MS, function()
        if g_currentMission == nil or g_gui == nil then
            Log:warning("Migration warning dialog skipped: GUI/mission unavailable at show time")
            return
        end
        -- InfoDialog.show silently no-ops when its shared INSTANCE is not registered.
        -- The migration already completed and logged its outcome synchronously, so log
        -- the missed warning too rather than letting a destructive change pass unnoticed.
        if InfoDialog.INSTANCE == nil then
            Log:warning("Migration warning dialog skipped: InfoDialog not registered at show time")
            return
        end
        local ok, err = pcall(InfoDialog.show, body, nil, nil, DialogElement.TYPE_WARNING)
        if not ok then
            Log:warning("Migration warning dialog failed to show: %s", tostring(err))
        end
    end)
end

-- ============================================================
-- Orchestration
-- ============================================================

---Runs the clean-break migration for a detected v1 file: export (or back up) the
---old rows outside the savegame, reset to a fresh v2 log, neutralize the v1 file
---when data was preserved, and warn the player. Never blocks load or crashes.
---@param savegameFolderPath string savegame folder (trailing slash)
---@param v1Rows table v1-shaped rows read from the legacy file
function RmTransactionMigration.migrateV1(savegameFolderPath, v1Rows)
    if RmTransactionMigration._migrationDone then
        Log:trace("migrateV1 re-entry ignored (already migrated this session)")
        return
    end
    RmTransactionMigration._migrationDone = true

    v1Rows = v1Rows or {}
    local rowCount = #v1Rows
    Log:info("Migrating legacy transaction log: %d v1 row(s)", rowCount)

    local csvExported, csvFilename = false, nil
    local rawBackedUp, backupFilename = false, nil

    if rowCount > 0 then
        -- Load the v1 rows so the exporter can dump them, bypassing key resolution
        -- (v1 values are already display text, not keys).
        RmTransactionLog.transactions = {}
        for _, row in ipairs(v1Rows) do
            table.insert(RmTransactionLog.transactions, row)
        end

        csvExported, _, csvFilename = RmTransactionLogExporter.exportCurrentTransactions("v1_export", true)
        if not csvExported then
            rawBackedUp, backupFilename = RmTransactionMigration.backupRawV1(savegameFolderPath)
        end
    end

    local outcome = RmTransactionMigration.chooseOutcome(rowCount, csvExported, rawBackedUp)
    Log:info("Migration outcome: %s (rows=%d, csv=%s, backup=%s)",
        outcome, rowCount, tostring(csvExported), tostring(rawBackedUp))

    -- Reset to a fresh, empty v2 in-memory log.
    RmTransactionLog.transactions = {}

    -- Write the v2 stub only when data was preserved (export/backup) or there was
    -- nothing to preserve (empty). On the nobackup path leave the v1 file INTACT so
    -- the player can copy it before the next save overwrites it.
    if outcome ~= "nobackup" then
        if not RmTransactionMigration.writeV2Stub(savegameFolderPath) then
            Log:warning("Failed to write the v2 stub over tl_transactions.xml; the legacy file "
                .. "remains and will re-migrate (and re-export) on the next load.")
        end
    end

    -- Warn the player whenever there were rows (export/backup/nobackup). An empty v1
    -- file is a silent fresh start.
    if outcome ~= "empty" then
        RmTransactionMigration.showMigrationDialog(outcome, csvFilename, backupFilename)
    end
end
