-- RmTransactionLogExporter.lua
-- CSV export functionality for FS25 Transaction Log mod
-- Author: Ritter
-- Description: Handles CSV export operations for transaction data

RmTransactionLogExporter = {}
local RmTransactionLogExporter_mt = Class(RmTransactionLogExporter)

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
---@return boolean success true if export succeeded
---@return string message success/error message
function RmTransactionLogExporter.exportToCSV(transactions, filename, directory)
    -- Parameter validation
    if not transactions or type(transactions) ~= "table" then
        local msg = "Invalid transactions parameter for CSV export"
        RmUtils.logError(msg)
        return false, msg
    end

    if not filename or filename == "" then
        local msg = "Invalid filename for CSV export"
        RmUtils.logError(msg)
        return false, msg
    end

    if not directory or directory == "" then
        local msg = "Invalid directory for CSV export"
        RmUtils.logError(msg)
        return false, msg
    end

    -- Check if we have transactions to export
    if #transactions == 0 then
        local msg = "No transactions to export"
        RmUtils.logInfo(msg)
        return false, msg
    end

    -- Sort transactions by in-game time, oldest first (chronological order for CSV)
    table.sort(transactions, function(a, b)
        return (a.ingameDateTime or "") < (b.ingameDateTime or "")
    end)

    -- Build full file path
    local csvFilePath = directory .. filename

    -- Create CSV content
    local csvContent = {}

    -- Add CSV header
    table.insert(csvContent, "Real DateTime,In-game DateTime,Farm ID,Type,Income/Expenditure,Amount,Balance,Comment")

    -- Add transaction rows
    for _, transaction in ipairs(transactions) do
        local realDateTime = RmTransactionLogExporter.escapeCSVField(transaction.realDateTime or "")
        local ingameDateTime = RmTransactionLogExporter.escapeCSVField(transaction.ingameDateTime or "")
        local farmId = transaction.farmId or 0
        local transactionType = RmTransactionLogExporter.escapeCSVField(transaction.transactionType or "")
        local incomeExpenditure = RmTransactionLogExporter.escapeCSVField(transaction.transactionStatistic or "")
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
        RmUtils.logInfo(msg)
        return true, msg
    else
        local msg = string.format("Failed to create CSV file: %s", csvFilePath)
        RmUtils.logError(msg)
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
---@return boolean success true if export succeeded
---@return string message success/error message
---@return string filename the generated filename (only if successful)
function RmTransactionLogExporter.exportWithAutoFilename(transactions, directory, suffix)
    local filename = RmTransactionLogExporter.generateFilename(nil, suffix)
    local success, message = RmTransactionLogExporter.exportToCSV(transactions, filename, directory)

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

    RmUtils.logWarning("No mod settings directory available for export")
    return nil
end

---Convenience function to export all current transactions
---@param suffix string optional suffix for the filename
---@return boolean success true if export succeeded
---@return string message success/error message
---@return string filename the generated filename (only if successful)
function RmTransactionLogExporter.exportCurrentTransactions(suffix)
    local directory = RmTransactionLogExporter.getExportDirectory()
    if not directory then
        local msg = "No export directory available"
        return false, msg, nil
    end

    -- Get transactions from the main module
    local transactions = RmTransactionLog and RmTransactionLog.transactions or {}

    return RmTransactionLogExporter.exportWithAutoFilename(transactions, directory, suffix)
end
