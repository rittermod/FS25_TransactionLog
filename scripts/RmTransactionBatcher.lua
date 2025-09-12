-- RmTransactionBatcher.lua
-- Transaction batching system for FS25 Transaction Log mod
-- Author: Ritter
-- Description: Handles batching of frequent small transactions to reduce log clutter

RmTransactionBatcher = {}
local RmTransactionBatcher_mt = Class(RmTransactionBatcher)

-- Constants
RmTransactionBatcher.BATCH_DELAY_MS = 5000   -- 5 seconds batch collection window
RmTransactionBatcher.MAX_BATCH_COUNT = 10000 -- Maximum number of transactions in a single batch
RmTransactionBatcher.MAX_ACTIVE_BATCHES = 50 -- Maximum number of active batches, just to be safe

-- Transaction statistics that should be batched (frequent small transactions)
RmTransactionBatcher.BATCHABLE_STATISTICS = {
    -- Add the transactionStatistic values that should be batched
    "constructionCost",   -- Landscaping costs etc
    "harvestIncome",      -- Income from harvesting crops
    "other",              -- Transactions without a specific statistic set
    "purchaseFertilizer", -- Fertilizer purchases
    "purchaseFuel",       -- Fuel purchases
    "purchaseWater",      -- Water purchases
    "soldBales",          -- Bales sold
    "soldMilk",           -- Milk sold
    "soldProducts",       -- Products sold (e.g. eggs, wool)
    "soldWood",           -- Wood sold
    "vehicleRunningCost", -- Running costs for vehicles
    "wagePayment",        -- Wage payments to workers
    "productionCosts",    -- Production costs
}

-- Hash table for lookup performance
RmTransactionBatcher.BATCHABLE_STATISTICS_SET = {}
for _, statistic in ipairs(RmTransactionBatcher.BATCHABLE_STATISTICS) do
    RmTransactionBatcher.BATCHABLE_STATISTICS_SET[statistic] = true
end

-- Batching system state
RmTransactionBatcher.transactionBatches = {} -- Active batches being collected
RmTransactionBatcher.batchTimers = {}        -- Timers for each batch
RmTransactionBatcher.activeBatchCount = 0    -- Counter for active batches

---Creates a new RmTransactionBatcher instance
---@param customMt table|nil optional custom metatable
---@return table the new batcher instance
function RmTransactionBatcher.new(customMt)
    local self = setmetatable({}, customMt or RmTransactionBatcher_mt)
    return self
end

---Checks if a transaction statistic should be batched
---@param transactionStatistic string the transaction statistic to check
---@return boolean true if should be batched, false otherwise
function RmTransactionBatcher.shouldBatch(transactionStatistic)
    return RmTransactionBatcher.BATCHABLE_STATISTICS_SET[transactionStatistic] == true
end

---Creates a batch key for grouping similar transactions
---@param farmId number the farm ID
---@param transactionType string the transaction type
---@param transactionStatistic string the transaction statistic
---@return string the batch key
function RmTransactionBatcher.createBatchKey(farmId, transactionType, transactionStatistic)
    return string.format("%s|%s|%s", farmId, transactionType, transactionStatistic)
end

---Adds a transaction to the appropriate batch for later processing
---@param amount number transaction amount
---@param farmId number farm ID
---@param moneyTypeTitle string transaction type title
---@param moneyTypeStatistic string transaction statistic type
---@param currentFarmBalance number current farm balance
---@param logFunction function function to call when batch is flushed
function RmTransactionBatcher.addToBatch(amount, farmId, moneyTypeTitle, moneyTypeStatistic,
                                         currentFarmBalance, logFunction)
    local batchKey = RmTransactionBatcher.createBatchKey(farmId, moneyTypeTitle, moneyTypeStatistic)
    RmUtils.logDebug(string.format("Adding to batch: %s amount: %s", batchKey, tostring(amount)))

    -- Check if we have too many active batches - flush oldest if needed
    if RmTransactionBatcher.activeBatchCount >= RmTransactionBatcher.MAX_ACTIVE_BATCHES then
        RmUtils.logWarning("Maximum active batches reached, flushing oldest batch")
        local oldestKey = next(RmTransactionBatcher.transactionBatches)
        if oldestKey then
            RmTransactionBatcher.flushBatch(oldestKey, logFunction)
        end
    end

    -- Initialize or update batch
    local batch = RmTransactionBatcher.transactionBatches[batchKey]
    if not batch then
        batch = {
            totalAmount = 0,
            count = 0,
            farmId = farmId,
            moneyTypeTitle = moneyTypeTitle,
            moneyTypeStatistic = moneyTypeStatistic,
            lastBalance = currentFarmBalance,
            firstTimestamp = getDate("%Y-%m-%dT%H:%M:%S%z")
        }
        RmTransactionBatcher.transactionBatches[batchKey] = batch
        RmTransactionBatcher.activeBatchCount = RmTransactionBatcher.activeBatchCount + 1
    end

    -- Check if batch is getting too large - flush immediately if so
    if batch.count >= RmTransactionBatcher.MAX_BATCH_COUNT then
        RmUtils.logDebug(string.format("Batch reached maximum size, flushing immediately: %s", batchKey))
        RmTransactionBatcher.flushBatch(batchKey, logFunction)
        -- Start a new batch for this transaction
        batch = {
            totalAmount = amount,
            count = 1,
            farmId = farmId,
            moneyTypeTitle = moneyTypeTitle,
            moneyTypeStatistic = moneyTypeStatistic,
            lastBalance = currentFarmBalance,
            firstTimestamp = getDate("%Y-%m-%dT%H:%M:%S%z")
        }
        RmTransactionBatcher.transactionBatches[batchKey] = batch
        RmTransactionBatcher.activeBatchCount = RmTransactionBatcher.activeBatchCount + 1
    else
        -- Accumulate transaction data
        batch.totalAmount = batch.totalAmount + amount
        batch.count = batch.count + 1
        batch.lastBalance = currentFarmBalance
    end

    -- Cancel existing timer if any
    if RmTransactionBatcher.batchTimers[batchKey] then
        RmTransactionBatcher.batchTimers[batchKey] = nil
    end

    -- Start new timer to flush this batch after delay (using game time)
    local flushTime = g_currentMission.time + RmTransactionBatcher.BATCH_DELAY_MS
    RmTransactionBatcher.batchTimers[batchKey] = flushTime
end

---Flushes a specific batch, creating the final aggregated transaction
---@param batchKey string the batch key to flush
---@param logFunction function function to call with the aggregated transaction
function RmTransactionBatcher.flushBatch(batchKey, logFunction)
    local batch = RmTransactionBatcher.transactionBatches[batchKey]
    if not batch then
        return
    end

    RmUtils.logDebug(string.format(
        "Flushing batch: %s with %d transactions, total: %s",
        batchKey, batch.count, tostring(batch.totalAmount)))

    -- Create aggregated transaction with batch info in comment
    local batchComment = ""
    if batch.count > 1 then
        batchComment = string.format("Combined %d transactions", batch.count)
    end

    -- Log the batched transaction with original title, batch info in comment
    logFunction(batch.totalAmount, batch.farmId, batch.moneyTypeTitle,
        batch.moneyTypeStatistic, batch.lastBalance, batchComment)

    -- Clean up
    RmTransactionBatcher.batchTimers[batchKey] = nil
    RmTransactionBatcher.transactionBatches[batchKey] = nil
    RmTransactionBatcher.activeBatchCount = RmTransactionBatcher.activeBatchCount - 1
end

---Checks for expired batches and flushes them
---@param logFunction function function to call when batches are flushed
function RmTransactionBatcher.updateBatches(logFunction)
    if not g_currentMission then
        return
    end

    local currentTime = g_currentMission.time
    local batchesToFlush = {}

    -- Find expired batches
    for batchKey, flushTime in pairs(RmTransactionBatcher.batchTimers) do
        if currentTime >= flushTime then
            table.insert(batchesToFlush, batchKey)
        end
    end

    -- Flush expired batches
    for _, batchKey in ipairs(batchesToFlush) do
        RmTransactionBatcher.flushBatch(batchKey, logFunction)
    end
end

---Flushes all active batches immediately
---@param logFunction function function to call when batches are flushed
function RmTransactionBatcher.flushAllBatches(logFunction)
    local batchesToFlush = {}

    -- Collect all active batch keys
    for batchKey, _ in pairs(RmTransactionBatcher.transactionBatches) do
        table.insert(batchesToFlush, batchKey)
    end

    RmUtils.logDebug(string.format("Flushing all %d active batches before save", #batchesToFlush))

    -- Flush all batches
    for _, batchKey in ipairs(batchesToFlush) do
        RmTransactionBatcher.flushBatch(batchKey, logFunction)
    end
end
