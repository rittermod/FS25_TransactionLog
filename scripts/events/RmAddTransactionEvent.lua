-- RmAddTransactionEvent.lua
-- Purpose: First concrete network event of the TransactionLog 2.0 MP layer. Carries ONE
--          transaction row (server -> client) and applies it to the client's master list.
--          TL-9 shipped the 5-method Event shell + serialization; TL-10 wired it up -- the server
--          fires it from logTransaction and run() appends the received row on the client.
-- Author: Ritter
-- Pattern: a standard object-less money event -- registered with InitEventClass, amount as Float32,
--          farmId as UIntN, and readStream ending in self:run. Serialization delegates to the shared
--          RmTransactionLogSync codec so every row-carrying event shares one wire format.

RmAddTransactionEvent = {}
local RmAddTransactionEvent_mt = Class(RmAddTransactionEvent, Event)

-- Register the event class at load time with InitEventClass. The immediate-assign variant
-- (InitStaticEventClass) is base-game-internal and is NOT exposed as a callable to the mod script
-- sandbox -- calling it at load raises "attempt to call a string value" and aborts the file -- so
-- mods register with InitEventClass, which records the class now and has its eventId assigned when
-- the server is created. This is the pattern every shipping event mod uses.
InitEventClass(RmAddTransactionEvent, "RmAddTransactionEvent")

--- Engine deserialization factory. The engine calls emptyNew() then readStream() to rebuild the
--- event on the receiving side, so this MUST exist (mp-missing-empty-new).
---@return table event a bare event bound to the class metatable
function RmAddTransactionEvent.emptyNew()
    return Event.new(RmAddTransactionEvent_mt)
end

--- Construct a send-side event carrying one transaction row.
---@param row table a transaction record (the shape built in RmTransactionLog.logTransaction)
---@return table event
function RmAddTransactionEvent.new(row)
    local self = RmAddTransactionEvent.emptyNew()
    self.row = row
    return self
end

--- Serialize the row onto the stream via the shared codec (the locked wire order lives there).
---@param streamId number
---@param connection table
function RmAddTransactionEvent:writeStream(streamId, connection)
    RmTransactionLogSync.writeRow(streamId, self.row)
end

--- Deserialize the row, then apply. Engine contract: readStream reconstructs state and applies
--- it, so it ends with self:run(connection) (the standard event read-then-apply pattern).
---@param streamId number
---@param connection table
function RmAddTransactionEvent:readStream(streamId, connection)
    self.row = RmTransactionLogSync.readRow(streamId)
    self:run(connection)
end

--- Client-side apply (TL-10): append the received row to the local master list -- the same
--- module-level RmTransactionLog.transactions the GUI/exporter read. Guarded to a non-authority
--- (g_server ~= nil returns early) as defense-in-depth: the host already holds the row in its
--- master list, so it must never re-append its own broadcast. A PLAIN append -- NO id-dedup and
--- NO live-GUI refresh: with no snapshot yet, a client's store is filled purely by ordered live
--- adds, so append is correct and complete for the live path. The live/snapshot duplicate-id
--- race is TL-11; the open-dialog live refresh is TL-11/TL-12 (an incoming row shows on dialog
--- reopen). On a client that table is never reassigned (load/migration are server-guarded), so
--- the append cannot orphan.
---@param connection table
function RmAddTransactionEvent:run(connection)
    if g_server ~= nil then return end
    table.insert(RmTransactionLog.transactions, self.row)
end
