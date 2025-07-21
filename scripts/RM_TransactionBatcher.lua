-- Transaction Batcher Module
-- Handles batching of frequent small transactions to reduce log clutter

RM_TransactionBatcher = {}
local RM_TransactionBatcher_mt = Class(RM_TransactionBatcher)

-- Constants
RM_TransactionBatcher.BATCH_DELAY_MS = 5000  -- 5 seconds batch collection window
RM_TransactionBatcher.MAX_BATCH_COUNT = 500  -- Maximum number of transactions in a single batch
RM_TransactionBatcher.MAX_ACTIVE_BATCHES = 50  -- Maximum number of active batches

-- Transaction statistics that should be batched (frequent small transactions)
RM_TransactionBatcher.BATCHABLE_STATISTICS = {
    -- Add the transactionStatistic values that should be batched
    "constructionCost",           -- Landscaping costs etc
    "soldBales",                  -- Bales sold
    "other",                      -- Transactions without a specific statistic set 
    "purchaseFuel",               -- Fuel purchases
}

-- Hash table for lookup performance
RM_TransactionBatcher.BATCHABLE_STATISTICS_SET = {}
for _, statistic in ipairs(RM_TransactionBatcher.BATCHABLE_STATISTICS) do
    RM_TransactionBatcher.BATCHABLE_STATISTICS_SET[statistic] = true
end

-- Batching system state
RM_TransactionBatcher.transactionBatches = {}  -- Active batches being collected
RM_TransactionBatcher.batchTimers = {}         -- Timers for each batch
RM_TransactionBatcher.activeBatchCount = 0     -- Counter for active batches

function RM_TransactionBatcher.new(customMt)
    local self = setmetatable({}, customMt or RM_TransactionBatcher_mt)
    return self
end

-- Helper function to check if a transaction statistic should be batched
function RM_TransactionBatcher.shouldBatch(transactionStatistic)
    return RM_TransactionBatcher.BATCHABLE_STATISTICS_SET[transactionStatistic] == true
end

-- Create a batch key for grouping similar transactions
function RM_TransactionBatcher.createBatchKey(farmId, transactionType, transactionStatistic)
    return string.format("%s|%s|%s", farmId, transactionType, transactionStatistic)
end

-- Add transaction to batch (assumes caller has already checked shouldBatch)
function RM_TransactionBatcher.addToBatch(amount, farmId, moneyTypeTitle, moneyTypeStatistic, currentFarmBalance, logFunction)
    
    local batchKey = RM_TransactionBatcher.createBatchKey(farmId, moneyTypeTitle, moneyTypeStatistic)
    RmUtils.logDebug("Adding to batch: " .. batchKey .. " amount: " .. tostring(amount))
    
    -- Check if we have too many active batches - flush oldest if needed
    if RM_TransactionBatcher.activeBatchCount >= RM_TransactionBatcher.MAX_ACTIVE_BATCHES then
        RmUtils.logWarning("Maximum active batches reached, flushing oldest batch")
        local oldestKey = next(RM_TransactionBatcher.transactionBatches)
        if oldestKey then
            RM_TransactionBatcher.flushBatch(oldestKey, logFunction)
        end
    end
    
    -- Initialize or update batch
    local batch = RM_TransactionBatcher.transactionBatches[batchKey]
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
        RM_TransactionBatcher.transactionBatches[batchKey] = batch
        RM_TransactionBatcher.activeBatchCount = RM_TransactionBatcher.activeBatchCount + 1
    end
    
    -- Check if batch is getting too large - flush immediately if so
    if batch.count >= RM_TransactionBatcher.MAX_BATCH_COUNT then
        RmUtils.logDebug("Batch reached maximum size, flushing immediately: " .. batchKey)
        RM_TransactionBatcher.flushBatch(batchKey, logFunction)
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
        RM_TransactionBatcher.transactionBatches[batchKey] = batch
        RM_TransactionBatcher.activeBatchCount = RM_TransactionBatcher.activeBatchCount + 1
    else
        -- Accumulate transaction data
        batch.totalAmount = batch.totalAmount + amount
        batch.count = batch.count + 1
        batch.lastBalance = currentFarmBalance
    end
    
    -- Cancel existing timer if any
    if RM_TransactionBatcher.batchTimers[batchKey] then
        RM_TransactionBatcher.batchTimers[batchKey] = nil
    end
    
    -- Start new timer to flush this batch after delay (using game time)
    local flushTime = g_currentMission.time + RM_TransactionBatcher.BATCH_DELAY_MS
    RM_TransactionBatcher.batchTimers[batchKey] = flushTime
end

-- Flush a batch to create the final transaction
function RM_TransactionBatcher.flushBatch(batchKey, logFunction)
    local batch = RM_TransactionBatcher.transactionBatches[batchKey]
    if not batch then
        return
    end
    
    RmUtils.logDebug("Flushing batch: " .. batchKey .. " with " .. batch.count .. " transactions, total: " .. tostring(batch.totalAmount))
    
    -- Create aggregated transaction with batch info in comment
    local batchComment = ""
    if batch.count > 1 then
        batchComment = "Combined " .. batch.count .. " transactions"
    end
    
    -- Log the batched transaction with original title, batch info in comment
    logFunction(batch.totalAmount, batch.farmId, batch.moneyTypeTitle, batch.moneyTypeStatistic, batch.lastBalance, batchComment)
    
    -- Clean up
    RM_TransactionBatcher.batchTimers[batchKey] = nil
    RM_TransactionBatcher.transactionBatches[batchKey] = nil
    RM_TransactionBatcher.activeBatchCount = RM_TransactionBatcher.activeBatchCount - 1
end

-- Check for expired batches and flush them
function RM_TransactionBatcher.updateBatches(logFunction)
    if not g_currentMission then
        return
    end
    
    local currentTime = g_currentMission.time
    local batchesToFlush = {}
    
    -- Find expired batches
    for batchKey, flushTime in pairs(RM_TransactionBatcher.batchTimers) do
        if currentTime >= flushTime then
            table.insert(batchesToFlush, batchKey)
        end
    end
    
    -- Flush expired batches
    for _, batchKey in ipairs(batchesToFlush) do
        RM_TransactionBatcher.flushBatch(batchKey, logFunction)
    end
end