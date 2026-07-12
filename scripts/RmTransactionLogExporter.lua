-- RmTransactionLogExporter.lua
-- CSV export functionality for FS25 Transaction Log mod
-- Author: Ritter
-- Description: Handles CSV export operations for transaction data

RmTransactionLogExporter = {}
local RmTransactionLogExporter_mt = Class(RmTransactionLogExporter)
local Log = RmLogging.getLogger("TransactionLog")

-- Message exportToCSV returns for an empty transaction set. Named so callers can distinguish an
-- empty-result "nothing to export" from a genuine failure (bad directory, file write error) without
-- matching a bare string. Must stay equal to exportToCSV's empty-set message.
RmTransactionLogExporter.NO_DATA_MESSAGE = "No transactions to export"

---Creates a new RmTransactionLogExporter instance
---@return table the new exporter instance
function RmTransactionLogExporter.new()
    local self = setmetatable({}, RmTransactionLogExporter_mt)
    return self
end

---Escapes a field for CSV format
---@param field any the field to escape
---@return string the escaped field
function RmTransactionLogExporter.escapeCSVField(field)
    if field == nil then
        return ""
    end
    local str = tostring(field)
    -- Escape quotes by doubling them
    str = string.gsub(str, '"', '""')
    -- Wrap in quotes if field contains special characters
    if string.find(str, '[,"\n\r]') then
        str = '"' .. str .. '"'
    end
    return str
end

---Exports transactions to CSV format
---@param transactions table array of transaction objects
---@param filename string filename for the CSV file (without path)
---@param directory string directory path where to save the file
---@param rawV1 boolean|nil true to write legacy (v1) records verbatim, bypassing the
---       key resolver (v1 already holds display text); false/nil resolves v2 keys
---@return boolean success true if export succeeded
---@return string message success/error message
function RmTransactionLogExporter.exportToCSV(transactions, filename, directory, rawV1)
    -- Parameter validation
    if not transactions or type(transactions) ~= "table" then
        local msg = "Invalid transactions parameter for CSV export"
        Log:error(msg)
        return false, msg
    end

    if not filename or filename == "" then
        local msg = "Invalid filename for CSV export"
        Log:error(msg)
        return false, msg
    end

    if not directory or directory == "" then
        local msg = "Invalid directory for CSV export"
        Log:error(msg)
        return false, msg
    end

    -- Check if we have transactions to export
    if #transactions == 0 then
        local msg = "No transactions to export"
        Log:info(msg)
        return false, msg
    end

    -- Sort a SHALLOW COPY, never the passed array: callers hand in the live
    -- RmTransactionLog.transactions master, and sorting it in place would scramble the
    -- insertion (= ascending-id) order that the save/load id round-trip relies on.
    -- Oldest first (chronological CSV), with id as the tie-breaker so equal-minute rows
    -- export in stable capture order rather than an arbitrary same-minute order.
    -- v1 migration rows carry no id, so the tie-breaker is a harmless no-op for them.
    local sorted = {}
    for i, transaction in ipairs(transactions) do
        sorted[i] = transaction
    end
    table.sort(sorted, function(a, b)
        local ad, bd = a.ingameDateTime or "", b.ingameDateTime or ""
        if ad ~= bd then
            return ad < bd
        end
        return (a.id or 0) < (b.id or 0)
    end)

    -- Build full file path
    local csvFilePath = directory .. filename

    -- Create CSV content
    local csvContent = {}

    -- Add CSV header
    table.insert(csvContent, "Real DateTime,In-game DateTime,Farm ID,Type,Income/Expenditure,Amount,Balance,Comment")

    -- Add transaction rows (iterate the sorted copy, not the caller's array)
    for _, transaction in ipairs(sorted) do
        local realDateTime = RmTransactionLogExporter.escapeCSVField(transaction.realDateTime or "")
        local ingameDateTime = RmTransactionLogExporter.escapeCSVField(transaction.ingameDateTime or "")
        local farmId = transaction.farmId or 0
        -- v2 rows store keys (resolve on export); v1 migration rows store display text.
        local typeText, categoryText
        if rawV1 then
            typeText = transaction.transactionType or ""
            categoryText = transaction.transactionStatistic or ""
        else
            typeText = RmTransactionLog.resolveType(transaction.title, transaction.customEnv, transaction.constant)
            categoryText = RmTransactionLog.resolveStatistic(transaction.statistic)
        end
        local transactionType = RmTransactionLogExporter.escapeCSVField(typeText)
        local incomeExpenditure = RmTransactionLogExporter.escapeCSVField(categoryText)
        local amount = transaction.amount or 0
        local balance = transaction.currentFarmBalance or 0
        local comment = RmTransactionLogExporter.escapeCSVField(transaction.comment or "")

        local csvRow = string.format("%s,%s,%s,%s,%s,%.2f,%.2f,%s",
            realDateTime, ingameDateTime, farmId, transactionType, incomeExpenditure, amount, balance, comment)
        table.insert(csvContent, csvRow)
    end

    -- Write CSV file
    local csvText = table.concat(csvContent, "\n")
    local file = io.open(csvFilePath, "w")
    if file then
        file:write(csvText)
        file:close()
        local msg = string.format("Exported %d transactions to: %s", #transactions, csvFilePath)
        Log:info(msg)
        return true, msg
    else
        local msg = string.format("Failed to create CSV file: %s", csvFilePath)
        Log:error(msg)
        return false, msg
    end
end

---Creates a timestamp-based filename for CSV export
---@param prefix string optional prefix for the filename
---@param suffix string optional suffix for the filename
---@return string the generated filename
function RmTransactionLogExporter.generateFilename(prefix, suffix)
    local timestamp = getDate("%Y%m%d_%H%M%S")
    local savegameIndex = 0

    if g_currentMission and g_currentMission.missionInfo and g_currentMission.missionInfo.savegameIndex then
        savegameIndex = g_currentMission.missionInfo.savegameIndex
    end

    local filenameParts = {}

    if prefix and prefix ~= "" then
        table.insert(filenameParts, prefix)
    else
        table.insert(filenameParts, "tl_transactions")
    end

    table.insert(filenameParts, string.format("sg%02d", savegameIndex))
    table.insert(filenameParts, timestamp)

    if suffix and suffix ~= "" then
        table.insert(filenameParts, suffix)
    end

    return table.concat(filenameParts, "_") .. ".csv"
end

---Exports transactions with automatic filename generation
---@param transactions table array of transaction objects
---@param directory string directory path where to save the file
---@param suffix string optional suffix for the filename
---@param rawV1 boolean|nil true to bypass the key resolver for legacy (v1) records
---@return boolean success true if export succeeded
---@return string message success/error message
---@return string filename the generated filename (only if successful)
function RmTransactionLogExporter.exportWithAutoFilename(transactions, directory, suffix, rawV1)
    local filename = RmTransactionLogExporter.generateFilename(nil, suffix)
    local success, message = RmTransactionLogExporter.exportToCSV(transactions, filename, directory, rawV1)

    if success then
        return true, message, filename
    else
        return false, message, nil
    end
end

---Gets the appropriate export directory
---@return string|nil directory path or nil if not available
function RmTransactionLogExporter.getExportDirectory()
    if g_modSettingsDirectory then
        local directory = g_modSettingsDirectory .. "/FS25_TransactionLog/"

        -- Ensure directory exists before returning it
        if createFolder then
            createFolder(directory)
        end

        return directory
    end

    Log:warning("No mod settings directory available for export")
    return nil
end

---Convenience function to export all current transactions
---@param suffix string optional suffix for the filename
---@param rawV1 boolean|nil true to bypass the key resolver for legacy (v1) records
---@return boolean success true if export succeeded
---@return string message success/error message
---@return string filename the generated filename (only if successful)
function RmTransactionLogExporter.exportCurrentTransactions(suffix, rawV1)
    local directory = RmTransactionLogExporter.getExportDirectory()
    if not directory then
        local msg = "No export directory available"
        return false, msg, nil
    end

    -- Get transactions from the main module
    local transactions = RmTransactionLog and RmTransactionLog.transactions or {}

    return RmTransactionLogExporter.exportWithAutoFilename(transactions, directory, suffix, rawV1)
end

---Exports ONLY the current farm's transactions (the manual GUI export), filtered through the shared
---per-farm helper from the LIVE mission farm. This is deliberate defence-in-depth: it re-derives the
---farm from g_currentMission:getFarmId() rather than the display, so the export stays farm-correct
---even if the dialog is stale or closed. In SP getFarmId() is 1 and only farm 1 exists (a no-op
---filter); a spectator (0) or dedicated server (nil) yields an empty set, which flows through
---exportWithAutoFilename to the NO_DATA_MESSAGE result the caller maps to the "no data" dialog.
---@param suffix string optional suffix for the filename
---@return boolean success true if export succeeded
---@return string message success/error message (NO_DATA_MESSAGE when the farm has no rows)
---@return string|nil filename the generated filename (only if successful)
---@return number exportedCount rows actually handed to the exporter (the live-farm set size)
function RmTransactionLogExporter.exportCurrentFarmTransactions(suffix)
    local directory = RmTransactionLogExporter.getExportDirectory()
    if not directory then
        local msg = "No export directory available"
        return false, msg, nil, 0
    end

    local farmId = g_currentMission ~= nil and g_currentMission:getFarmId() or nil
    local master = RmTransactionLog and RmTransactionLog.transactions or {}
    local mine = RmTransactionLog.filterTransactionsByFarm(master, farmId)

    -- Pass the (possibly empty) filtered set through the SAME auto-filename path as the whole-log
    -- export, so the filename scheme is unchanged and an empty set returns NO_DATA_MESSAGE. Return
    -- the filtered count as a 4th value so the caller can report an HONEST count (the rows actually
    -- written from the live farm), not a possibly-stale display count.
    local success, message, filename = RmTransactionLogExporter.exportWithAutoFilename(mine, directory, suffix, false)
    return success, message, filename, #mine
end
