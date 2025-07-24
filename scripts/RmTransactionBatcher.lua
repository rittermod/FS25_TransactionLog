-- Transaction Batcher Module
-- Handles batching of frequent small transactions to reduce log clutter

RmTransactionBatcher = {}
local RmTransactionBatcher_mt = Class(RmTransactionBatcher)

-- Constants
RmTransactionBatcher.BATCH_DELAY_MS = 5000   -- 5 seconds batch collection window
RmTransactionBatcher.MAX_BATCH_COUNT = 500   -- Maximum number of transactions in a single batch
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

function RmTransactionBatcher.new(customMt)
    local self = setmetatable({}, customMt or RmTransactionBatcher_mt)
    return self
end

-- Helper function to check if a transaction statistic should be batched
function RmTransactionBatcher.shouldBatch(transactionStatistic)
    return RmTransactionBatcher.BATCHABLE_STATISTICS_SET[transactionStatistic] == true
end

-- Create a batch key for grouping similar transactions
function RmTransactionBatcher.createBatchKey(farmId, transactionType, transactionStatistic)
    return string.format("%s|%s|%s", farmId, transactionType, transactionStatistic)
end

-- Add transaction to batch (assumes caller has already checked shouldBatch)
function RmTransactionBatcher.addToBatch(amount, farmId, moneyTypeTitle, moneyTypeStatistic, currentFarmBalance,
                                         logFunction)
    local batchKey = RmTransactionBatcher.createBatchKey(farmId, moneyTypeTitle, moneyTypeStatistic)
    RmUtils.logDebug("Adding to batch: " .. batchKey .. " amount: " .. tostring(amount))

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
        RmUtils.logDebug("Batch reached maximum size, flushing immediately: " .. batchKey)
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

-- Flush a batch to create the final transaction
function RmTransactionBatcher.flushBatch(batchKey, logFunction)
    local batch = RmTransactionBatcher.transactionBatches[batchKey]
    if not batch then
        return
    end

    RmUtils.logDebug("Flushing batch: " ..
    batchKey .. " with " .. batch.count .. " transactions, total: " .. tostring(batch.totalAmount))

    -- Create aggregated transaction with batch info in comment
    local batchComment = ""
    if batch.count > 1 then
        batchComment = "Combined " .. batch.count .. " transactions"
    end

    -- Log the batched transaction with original title, batch info in comment
    logFunction(batch.totalAmount, batch.farmId, batch.moneyTypeTitle, batch.moneyTypeStatistic, batch.lastBalance,
        batchComment)

    -- Clean up
    RmTransactionBatcher.batchTimers[batchKey] = nil
    RmTransactionBatcher.transactionBatches[batchKey] = nil
    RmTransactionBatcher.activeBatchCount = RmTransactionBatcher.activeBatchCount - 1
end

-- Check for expired batches and flush them
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
