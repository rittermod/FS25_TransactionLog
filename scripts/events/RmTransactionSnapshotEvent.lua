-- RmTransactionSnapshotEvent.lua
-- Purpose: Join / farm-switch snapshot event of the TransactionLog 2.0 MP layer (TL-11). Carries a
--          WHOLE per-farm transaction history (server -> ONE client) and REPLACES the client's
--          store with it. TL-10's RmAddTransactionEvent delivers only LIVE adds from the moment of
--          capture, so a client that was not connected when a row was logged never receives it
--          (empty log on join) and a farm-switcher keeps the old farm's rows (a cross-farm leak).
--          This event closes both: the server builds a per-farm snapshot (RmTransactionLogSync.
--          buildFarmSnapshot) and sends it on join (appended FSBaseMission.sendInitialClientState)
--          and on mid-session switch (MessageType.PLAYER_FARM_CHANGED).
-- Author: Ritter
-- Pattern: the same 5-method object-less Event as RmAddTransactionEvent -- registered with
--          InitEventClass (NOT InitStaticEventClass, which is base-game-internal and raises
--          "attempt to call a string value" in the mod sandbox), count as Int32, then N rows via
--          the shared RmTransactionLogSync codec, and readStream ending in self:run. Reusing the
--          shared codec keeps the wire format in exactly ONE place across every row-carrying event.

RmTransactionSnapshotEvent = {}
local RmTransactionSnapshotEvent_mt = Class(RmTransactionSnapshotEvent, Event)

-- Register the event class at load time with InitEventClass (see RmAddTransactionEvent's
-- InitEventClass call + the TL-9 change log for why the immediate-assign InitStaticEventClass is
-- NOT callable here).
InitEventClass(RmTransactionSnapshotEvent, "RmTransactionSnapshotEvent")

--- Engine deserialization factory. The engine calls emptyNew() then readStream() to rebuild the
--- event on the receiving side, so this MUST exist (mp-missing-empty-new).
---@return table event a bare event bound to the class metatable
function RmTransactionSnapshotEvent.emptyNew()
    return Event.new(RmTransactionSnapshotEvent_mt)
end

--- Construct a send-side event carrying a whole per-farm snapshot (rows in master/ascending-id
--- order, as RmTransactionLogSync.buildFarmSnapshot returns them). An empty list is valid: it
--- REPLACEs the client store with nothing (a switch-to-spectator clears the old farm's rows).
---@param rows table array of transaction records (the shape built in RmTransactionLog.logTransaction)
---@return table event
function RmTransactionSnapshotEvent.new(rows)
    local self = RmTransactionSnapshotEvent.emptyNew()
    self.rows = rows
    return self
end

--- Serialize the snapshot: an Int32 count, then that many rows via the shared codec (the locked
--- wire order lives in RmTransactionLogSync). readStream mirrors this EXACTLY.
---@param streamId number
---@param connection table
function RmTransactionSnapshotEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, #self.rows)
    for i = 1, #self.rows do
        RmTransactionLogSync.writeRow(streamId, self.rows[i])
    end
end

--- Deserialize the snapshot, then apply. Reads the Int32 count, then exactly that many rows (a
--- count of 0 runs zero readRow calls and still reaches run()). Engine contract: readStream
--- reconstructs state and applies it, so it ends with self:run(connection).
---@param streamId number
---@param connection table
function RmTransactionSnapshotEvent:readStream(streamId, connection)
    local count = streamReadInt32(streamId)
    self.rows = {}
    for i = 1, count do
        self.rows[i] = RmTransactionLogSync.readRow(streamId)
    end
    self:run(connection)
end

--- Client-side apply (TL-11): REPLACE the local master list with the received snapshot. Two
--- load-bearing properties:
---   1. Authority guard FIRST. The host NEVER rebuilds its all-farms master from a snapshot -- a
---      snapshot that reached the host loopback must never wipe it. (g_server ~= nil returns early;
---      the loopback has isServer == false, so this guard -- not a getIsServer check -- is the
---      backstop, mirroring RmAddTransactionEvent:run.)
---   2. REPLACE is done IN PLACE (clear + refill the existing RmTransactionLog.transactions table,
---      NOT reassign), so it keeps the table IDENTITY -- alias-proof for any holder of the TABLE
---      reference (the row tables themselves are the fresh ones readStream just decoded, so no row
---      is shared with anything). It does not depend on the codebase holding no long-lived
---      reference to that table (RmTransactionLog.new captures
---      self.transactions = RmTransactionLog.transactions; uncalled today, but a reassign would
---      silently orphan any future caller). REPLACE (not
---      append) is what makes a farm-switcher DROP the old farm's rows (req-4 invariant: the client
---      store holds ONLY the player's own farm). Idempotent, so no id-dedup is needed.
--- nextTransactionId is untouched -- it is the server-only allocator; clients never allocate ids.
---@param connection table
function RmTransactionSnapshotEvent:run(connection)
    if g_server ~= nil then return end
    local transactions = RmTransactionLog.transactions
    for i = #transactions, 1, -1 do
        transactions[i] = nil
    end
    for i = 1, #self.rows do
        transactions[i] = self.rows[i]
    end
end
