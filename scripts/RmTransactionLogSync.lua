-- RmTransactionLogSync.lua
-- Purpose: ONE shared row (de)serialization codec for the TransactionLog 2.0 MP event layer.
--          Every network event that carries a transaction row (RmAddTransactionEvent now; the
--          TL-11 join / farm-switch snapshot later) reuses writeRow/readRow, so the wire
--          format lives in exactly ONE place and can never drift between events.
-- Author: Ritter
-- Model:   Serializes the CURRENT post-TL-5 key-based record (11 fields; KEYS, not resolved
--          text). Serializing keys is the point of TL-5's storage model: each client resolves
--          titles in its own language (project-context "2.0-dev sequencing", why-this-order).
--          Money (amount, currentFarmBalance) serializes as Float32 -- the same width the game
--          uses to sync money over the network; values above 2^24 lose sub-unit precision exactly
--          as the game's own money sync does -- correct, not a shortcut.
-- Scope:   TL-9 ships the codec ONLY. The delivery machinery (sendToFarm targeting, the
--          snapshot builder, the farm-change handler) is TL-10/TL-11.
-- Sourced: by RmTransactionLog.lua's chain, which loads on server AND client.

RmTransactionLogSync = {}

--- Serialize a transaction row onto a network stream in the LOCKED wire order (see readRow --
--- the two MUST stay field-for-field identical; a positional stream corrupts silently on a
--- transposition). Nil-safe by design: the loader (@see RmTransactionLog.loadFromXMLFile) keeps
--- rows whose farmId/title/realDateTime are nil -- only amount + ingameDateTime gate its skip --
--- and the TL-11 snapshot will serialize those LOADED rows, so this shared codec must never fault
--- on one. Every string field coerces nil -> ""; farmId coerces nil -> FarmManager.INVALID_FARM_ID
--- (a valid UIntN "no farm" sentinel, = 2^FARM_ID_SEND_NUM_BITS - 1). id/amount/currentFarmBalance
--- are always present on a kept row (id is derived on load, amount gates rejection,
--- currentFarmBalance defaults to 0) so they are written raw -- a non-number here is a real bug
--- the engine (and the test mock) should fault on, not silently paper over.
---@param streamId number engine stream handle
---@param row table a transaction record (the shape built in RmTransactionLog.logTransaction)
function RmTransactionLogSync.writeRow(streamId, row)
    streamWriteInt32(streamId, row.id)                                                       -- 1
    streamWriteUIntN(streamId, row.farmId or FarmManager.INVALID_FARM_ID,
        FarmManager.FARM_ID_SEND_NUM_BITS)                                                   -- 2
    streamWriteString(streamId, row.realDateTime or "")                                      -- 3
    streamWriteString(streamId, row.ingameDateTime or "")                                    -- 4
    streamWriteFloat32(streamId, row.amount)                                                 -- 5
    streamWriteString(streamId, row.title or "")                                             -- 6
    streamWriteString(streamId, row.statistic or "")                                         -- 7
    streamWriteString(streamId, row.customEnv or "")                                         -- 8
    streamWriteString(streamId, row.constant or "")                                          -- 9
    streamWriteFloat32(streamId, row.currentFarmBalance)                                     -- 10
    streamWriteString(streamId, row.comment or "")                                           -- 11
end

--- Deserialize a transaction row from a network stream. Mirrors writeRow's field order EXACTLY.
--- Normalizes "" -> nil ONLY for customEnv/constant, matching the load-side normalization in
--- RmTransactionLog.loadFromXMLFile where "" and nil are equivalent for these two fields (they
--- disambiguate the title/statistic keys and carry no meaning when empty). The other
--- coerced-empty strings read back as "" -- an acceptable degradation for a row that was
--- malformed on the write side.
---@param streamId number engine stream handle
---@return table row the reconstructed transaction record
function RmTransactionLogSync.readRow(streamId)
    local row = {}
    row.id = streamReadInt32(streamId)                                                       -- 1
    row.farmId = streamReadUIntN(streamId, FarmManager.FARM_ID_SEND_NUM_BITS)                -- 2
    row.realDateTime = streamReadString(streamId)                                            -- 3
    row.ingameDateTime = streamReadString(streamId)                                          -- 4
    row.amount = streamReadFloat32(streamId)                                                 -- 5
    row.title = streamReadString(streamId)                                                   -- 6
    row.statistic = streamReadString(streamId)                                               -- 7
    local customEnv = streamReadString(streamId)                                             -- 8
    local constant = streamReadString(streamId)                                              -- 9
    row.customEnv = (customEnv ~= "" and customEnv) or nil
    row.constant = (constant ~= "" and constant) or nil
    row.currentFarmBalance = streamReadFloat32(streamId)                                     -- 10
    row.comment = streamReadString(streamId)                                                 -- 11
    return row
end

-- TL-10/TL-11: sendToFarm targeting, snapshot builder, farm-change handler live here.
