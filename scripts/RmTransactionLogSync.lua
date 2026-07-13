-- RmTransactionLogSync.lua
-- Purpose: ONE shared row (de)serialization codec for the TransactionLog 2.0 MP event layer.
--          Every network event that carries a transaction row (RmAddTransactionEvent now; the
--          TL-11 join / farm-switch snapshot later) reuses writeRow/readRow, so the wire
--          format lives in exactly ONE place and can never drift between events.
-- Author: Ritter
-- Model:   Serializes the CURRENT post-TL-5 key-based record (14 fields). Serializing keys is the
--          point of TL-5's storage model: each client resolves titles in its own language
--          (project-context "2.0-dev sequencing", why-this-order). The TL-18 enrichment trio
--          (subjectId / locationId / locationName) is APPENDED at the tail (positions 12-14),
--          keeping the locked 11-field prefix byte-stable; subjectId/locationId are stable keys,
--          locationName is a display-name snapshot (text) -- all three ride the wire as Strings.
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
    streamWriteString(streamId, row.subjectId or "")                                         -- 12
    streamWriteString(streamId, row.locationId or "")                                        -- 13
    streamWriteString(streamId, row.locationName or "")                                      -- 14
end

--- Deserialize a transaction row from a network stream. Mirrors writeRow's field order EXACTLY.
--- Normalizes "" -> nil for customEnv/constant AND the TL-18 enrichment trio (subjectId /
--- locationId / locationName), matching the load-side normalization in
--- RmTransactionLog.loadFromXMLFile where "" and nil are equivalent for these fields (each
--- normalizes independently, no cross-field coupling). The other coerced-empty strings read back
--- as "" -- an acceptable degradation for a row that was malformed on the write side.
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
    local subjectId = streamReadString(streamId)                                             -- 12
    local locationId = streamReadString(streamId)                                            -- 13
    local locationName = streamReadString(streamId)                                          -- 14
    row.subjectId = (subjectId ~= "" and subjectId) or nil
    row.locationId = (locationId ~= "" and locationId) or nil
    row.locationName = (locationName ~= "" and locationName) or nil
    return row
end

--- Deliver an event to ONLY the given farm's remote clients (TL-10 targeted delivery). Guards,
--- then delegates to the base-game native g_currentMission:broadcastEventToFarm(event, farmId):
--- it builds the farm's connection list and calls broadcastEvent with sendLocal defaulting FALSE,
--- so the host loopback (NetworkNode.LOCAL_STREAM_ID) is skipped and the host never double-applies
--- its own already-captured row. A hand-rolled `not connection:getIsServer()` loop would WRONGLY
--- include the host loopback (its isServer == false) and double-apply -- so we delegate to the
--- native primitive instead; farm isolation + host-skip are the engine's contract (verified
--- in-game, not by unit test). No-op on a non-authority (g_server nil), a missing mission
--- (teardown), or a non-positive farmId. In singleplayer it still RUNS (the host is the
--- authority) but broadcastEventToFarm finds an empty client list, so it delivers nothing -- a
--- behavioral no-op, no SP-visible effect.
--- Ground truth: @see FSBaseMission.broadcastEventToFarm (builds the per-farm connection list,
--- calls Server.broadcastEvent with sendLocal omitted -> false) and @see Server.broadcastEvent
--- (its send loop skips the NetworkNode.LOCAL_STREAM_ID loopback when sendLocal is false).
---@param farmId number the owning farm id (already validated at the logTransaction boundary)
---@param event table an RmAddTransactionEvent carrying the row to deliver
function RmTransactionLogSync.sendToFarm(farmId, event)
    if g_server == nil or g_currentMission == nil then return end
    if farmId == nil or farmId <= 0 then return end
    g_currentMission:broadcastEventToFarm(event, farmId)
end

--- Build a per-farm snapshot: the master list (RmTransactionLog.transactions) filtered to ONE
--- farm, in master (ascending-id) insertion order. PURE -- reads only the module master + arg,
--- mutates nothing (returns a fresh list holding the SAME row tables). Bounded guard FIRST, mirror
--- of the TL-10 capture bound (@see RmTransactionLog.changeFarmBalance): a nil / <=0 /
--- >MAX_NUM_FARMS farmId returns {} cleanly -- so spectator 0, INVALID_FARM_ID 15 (the quit path),
--- GUIDED_TOUR 14, and nil each yield an EMPTY snapshot with no `nil <= 0` raise. Orphan rows the
--- loader kept with a nil/invalid farmId (@see RmTransactionLog.loadFromXMLFile) match no real farm
--- and are intentionally excluded from every client snapshot -- they remain in the host master.
--- Ground truth: @see FarmManager.MAX_NUM_FARMS / FarmManager.SPECTATOR_FARM_ID.
---@param farmId number the owning farm id
---@return table rows that farm's records in id order (a fresh list; {} when none / out-of-range)
function RmTransactionLogSync.buildFarmSnapshot(farmId)
    if farmId == nil or farmId <= 0 or farmId > FarmManager.MAX_NUM_FARMS then
        return {}
    end
    local rows = {}
    for _, row in ipairs(RmTransactionLog.transactions) do
        if row.farmId == farmId then
            rows[#rows + 1] = row
        end
    end
    return rows
end

--- Send ONE connection a snapshot of one farm's history. Guards FIRST -- authority (g_server),
--- live mission, a non-nil connection, and a NON-loopback connection -- so a rejected connection
--- does NO wasted build; only then build + send. `connection:sendEvent` to one resolved connection
--- is the base-game single-target idiom (@see FinanceStatsEvent, sent per-connection inside
--- FSBaseMission.sendInitialClientState), NOT the per-farm broadcastEventToFarm (which cannot
--- target a single joiner/switcher). The getIsLocal skip earns its keep on the SWITCH path (the
--- host's own player resolves to the loopback, whose isServer == false -- so getIsLocal, not
--- getIsServer, is the correct skip); on JOIN it is belt-and-suspenders (the join-finished path
--- only ever delivers a remote, non-local connection). The RmTransactionSnapshotEvent:run authority
--- guard is the load-bearing backstop regardless. buildFarmSnapshot clamps an out-of-range farmId
--- to {}, so a switch-to-spectator (farmId 0) sends an EMPTY snapshot that clears the client store.
---@param connection table the target client connection (already resolved by the caller)
---@param farmId number the farm whose history to snapshot (0 / out-of-range -> an EMPTY snapshot)
function RmTransactionLogSync.sendSnapshotToConnection(connection, farmId)
    if g_server == nil or g_currentMission == nil then return end
    if connection == nil or connection:getIsLocal() then return end
    connection:sendEvent(RmTransactionSnapshotEvent.new(RmTransactionLogSync.buildFarmSnapshot(farmId)))
end
