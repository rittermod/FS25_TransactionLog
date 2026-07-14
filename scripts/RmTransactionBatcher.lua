-- RmTransactionBatcher.lua
-- Transaction batching system for FS25 Transaction Log mod
-- Author: Ritter
-- Description: Handles batching of frequent small transactions to reduce log clutter

RmTransactionBatcher = {}
local RmTransactionBatcher_mt = Class(RmTransactionBatcher)
local Log = RmLogging.getLogger("TransactionLog")

-- Constants
RmTransactionBatcher.BATCH_DELAY_MS = 5000   -- 5 seconds batch collection window
RmTransactionBatcher.MAX_BATCH_COUNT = 10000 -- Maximum number of transactions in a single batch
-- Raised 50 -> 512 in TL-22. Regression prevented: once capture (TL-26..28) attaches subject/location,
-- createBatchKey sub-keys on them, so the live batch count multiplies (farms x category x subject x
-- location). At 50 that multiplied count trips this cap and force-flushes an IN-PROGRESS batch, splitting
-- a logical 5s group into under-aggregated partials. 512 is HEADROOM sized to the realistic bound (live
-- tuples in a 5s window <= FarmManager.MAX_NUM_FARMS x concurrently-active enrichable
-- category-subject-location tuples; human/AI pacing keeps this in the low hundreds), NOT a hard guarantee.
-- Combined with addToBatch's self-eviction guard (the incoming key is never the eviction victim),
-- fragmentation is unreachable in realistic play; residual arbitrary-eviction fragmentation is an
-- accepted, documented risk only if live cardinality ever exceeds 512.
RmTransactionBatcher.MAX_ACTIVE_BATCHES = 512

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
    "purchaseSeeds",      -- Seed purchases
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

---Creates a batch key for grouping transactions of the same money type - and, once capture lands
---(TL-26..28), the same subject (WHAT) and location (WHERE) - per farm.
---Keyed on the money type's runtime id (unique per type, unlike the shared
---title/statistic), so VEHICLE_RUNNING_COSTS and VEHICLE_REPAIR batch separately.
---The id is session-only (registration-order-dependent) - fine for an ephemeral batch.
---
---Enrichment sub-keying (TL-22): the subject and location segments are appended UNIFORMLY (no
---per-category exception) so distinct subjects/locations captured within one 5s window never MERGE
---into one ambiguous batch. The encoding is collision-safe because a segment can carry free text
---(locationName):
---  1. NORMALIZE each value so "" and nil produce the SAME segment (`(v ~= nil and v ~= "") and
---     tostring(v) or ""`), matching logTransaction's row-level normalization - else a "" field would
---     split a batch that persists identically to a nil one.
---  2. The location segment is id-DOMINANT: locationId when present, else locationName, else nil. A
---     saved placeable's stable locationId IS its identity; locationName only disambiguates a
---     runtime-placed placeable whose locationId is nil. createBatchKey still RECEIVES both (the
---     batch/row carry both for display) - only the KEY collapses to the id-dominant choice.
---  3. Every segment is LENGTH-PREFIXED (`#s:s`) so an embedded "|"/":" or a literal "nil" cannot
---     alias two distinct contexts into one key.
---An unenriched capture (all three nil) keys equivalently to the pre-TL-22 form: one batch per
---farm+money-type (the key string gains normalized-empty segments, but the GROUPING is unchanged).
---@param farmId number the farm ID
---@param moneyTypeId number|nil the money type's runtime id
---@param subjectId string|nil enrichment WHAT: stable fillType/animal name key (nil until TL-26..28)
---@param locationId string|nil enrichment WHERE: placeable uniqueId (nil for a not-yet-saved placeable)
---@param locationName string|nil enrichment WHERE: placeable display-name snapshot
---@return string the batch key
function RmTransactionBatcher.createBatchKey(farmId, moneyTypeId, subjectId, locationId, locationName)
    -- Length-prefixed, normalized segment: "" and nil both collapse to "0:"; the length prefix means no
    -- value (an embedded "|"/":", or the literal "nil") can alias a different context into the same key.
    local function seg(v)
        v = (v ~= nil and v ~= "") and tostring(v) or ""
        return string.format("%d:%s", #v, v)
    end
    -- id-dominant location: the stable id wins; the name only identifies a nil-id (runtime) placeable.
    local loc = (locationId ~= nil and locationId ~= "" and tostring(locationId))
             or (locationName ~= nil and locationName ~= "" and tostring(locationName))
             or nil
    return seg(farmId) .. seg(moneyTypeId) .. seg(subjectId) .. seg(loc)
end

---Adds a transaction to the appropriate batch for later processing. Subject/location context (TL-22)
---is threaded from changeFarmBalance's consumed pending-context locals and BOTH keys the batch (via
---createBatchKey) AND is stored on the batch struct - so every member of a batch shares one
---subject/location and the flushed aggregate describes them faithfully. The three enrichment params sit
---BEFORE logFunction (which stays last). In normal play all three are nil (no capture hook yet -
---TL-26..28), so the key degrades to the pre-TL-22 farm+money-type grouping and batching is unchanged.
---@param amount number transaction amount
---@param farmId number farm ID
---@param moneyType table money type (carries id/title/statistic/customEnv)
---@param constant string|nil derived MoneyType constant name
---@param currentFarmBalance number current farm balance
---@param subjectId string|nil enrichment WHAT: stable fillType/animal name key (nil until TL-26..28)
---@param locationId string|nil enrichment WHERE: placeable uniqueId (nil for a not-yet-saved placeable)
---@param locationName string|nil enrichment WHERE: placeable display-name snapshot
---@param logFunction function function to call when batch is flushed (kept LAST)
function RmTransactionBatcher.addToBatch(amount, farmId, moneyType, constant, currentFarmBalance,
                                         subjectId, locationId, locationName, logFunction)
    -- Normalize each enrichment value ("" -> nil) ONCE, up front, so the KEY, the stored batch struct,
    -- and the flushed record all agree with logTransaction's row-level (x ~= "" and x) or nil contract.
    -- Without this the struct would keep a raw "" that createBatchKey already treated as "no value", and
    -- flushBatch would forward "" to a collector-style logFunction while the direct path yields nil.
    subjectId = (subjectId ~= nil and subjectId ~= "") and subjectId or nil
    locationId = (locationId ~= nil and locationId ~= "") and locationId or nil
    locationName = (locationName ~= nil and locationName ~= "") and locationName or nil

    local batchKey = RmTransactionBatcher.createBatchKey(farmId, moneyType.id, subjectId,
        locationId, locationName)
    Log:debug(string.format("Adding to batch: %s amount: %s", batchKey, tostring(amount)))

    -- Look up the existing batch FIRST, so the cap-eviction below can only ever target an OTHER batch.
    local batch = RmTransactionBatcher.transactionBatches[batchKey]

    if not batch then
        -- A NEW batch is about to be created. Enforce the active-batch cap ONLY here (after the lookup
        -- returned nil), so the incoming key - not yet in the table - can never be its own eviction
        -- victim. The pre-TL-22 check preceded the lookup, so next() could flush the very batch being
        -- accumulated. Eviction still flushes an arbitrary next() victim; the victim ORDER is unchanged.
        if RmTransactionBatcher.activeBatchCount >= RmTransactionBatcher.MAX_ACTIVE_BATCHES then
            Log:warning("Maximum active batches reached, flushing oldest batch")
            local oldestKey = next(RmTransactionBatcher.transactionBatches)
            if oldestKey then
                RmTransactionBatcher.flushBatch(oldestKey, logFunction)
            end
        end

        batch = {
            totalAmount = 0,
            count = 0,
            farmId = farmId,
            title = moneyType.title,
            statistic = moneyType.statistic,
            customEnv = moneyType.customEnv,
            constant = constant,
            subjectId = subjectId,
            locationId = locationId,
            locationName = locationName,
            lastBalance = currentFarmBalance,
            firstTimestamp = getDate("%Y-%m-%dT%H:%M:%S%z")
        }
        RmTransactionBatcher.transactionBatches[batchKey] = batch
        RmTransactionBatcher.activeBatchCount = RmTransactionBatcher.activeBatchCount + 1
    end

    -- Check if batch is getting too large - flush immediately if so
    if batch.count >= RmTransactionBatcher.MAX_BATCH_COUNT then
        Log:debug(string.format("Batch reached maximum size, flushing immediately: %s", batchKey))
        RmTransactionBatcher.flushBatch(batchKey, logFunction)
        -- Start a new batch for this transaction. This reseed MUST also carry subject/location: they key
        -- the batch, so omitting them here would silently drop enrichment on an oversized (>MAX_BATCH_COUNT)
        -- batch's continuation.
        batch = {
            totalAmount = amount,
            count = 1,
            farmId = farmId,
            title = moneyType.title,
            statistic = moneyType.statistic,
            customEnv = moneyType.customEnv,
            constant = constant,
            subjectId = subjectId,
            locationId = locationId,
            locationName = locationName,
            lastBalance = currentFarmBalance,
            firstTimestamp = getDate("%Y-%m-%dT%H:%M:%S%z")
        }
        RmTransactionBatcher.transactionBatches[batchKey] = batch
        RmTransactionBatcher.activeBatchCount = RmTransactionBatcher.activeBatchCount + 1
    else
        -- Accumulate transaction data. Subject/location are set once at init (like title/statistic) and
        -- never re-derived on accumulate - every member shares the key, so they already match.
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
---@param logFunction function receives ONE record table (RmTransactionLog.logTransaction; TL-35), keys mirror the stored row
function RmTransactionBatcher.flushBatch(batchKey, logFunction)
    local batch = RmTransactionBatcher.transactionBatches[batchKey]
    if not batch then
        return
    end

    Log:debug(string.format(
        "Flushing batch: %s with %d transactions, total: %s",
        batchKey, batch.count, tostring(batch.totalAmount)))

    -- Create aggregated transaction with batch info in comment
    local batchComment = ""
    if batch.count > 1 then
        batchComment = string.format("Combined %d transactions", batch.count)
    end

    -- Log the batched transaction with the captured snapshot, batch info in comment. TL-35: pass a
    -- record table (named fields), NOT positional args. Note the key renames (totalAmount -> amount,
    -- lastBalance -> currentFarmBalance). TL-22: the batch now carries subject/location context (keyed
    -- and stored once at addToBatch), so forward it here; logTransaction's (x ~= "" and x) or nil
    -- normalization handles the three exactly as on the direct path (all nil in normal play until
    -- capture lands, TL-26..28).
    logFunction({
        amount = batch.totalAmount,
        farmId = batch.farmId,
        title = batch.title,
        statistic = batch.statistic,
        customEnv = batch.customEnv,
        constant = batch.constant,
        currentFarmBalance = batch.lastBalance,
        comment = batchComment,
        subjectId = batch.subjectId,
        locationId = batch.locationId,
        locationName = batch.locationName,
    })

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
---@param context string|nil short label for WHY the drain runs ("save" / "auto-export" / "clear"); drives
---  the log line only, since flushAllBatches drains before all three call sites. Defaults to "flush".
function RmTransactionBatcher.flushAllBatches(logFunction, context)
    local batchesToFlush = {}

    -- Collect all active batch keys
    for batchKey, _ in pairs(RmTransactionBatcher.transactionBatches) do
        table.insert(batchesToFlush, batchKey)
    end

    Log:debug(string.format("Flushing all %d active batches before %s", #batchesToFlush, context or "flush"))

    -- Flush all batches
    for _, batchKey in ipairs(batchesToFlush) do
        RmTransactionBatcher.flushBatch(batchKey, logFunction)
    end
end
