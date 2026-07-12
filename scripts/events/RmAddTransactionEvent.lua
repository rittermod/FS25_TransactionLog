-- RmAddTransactionEvent.lua
-- Purpose: First concrete network event of the TransactionLog 2.0 MP layer. Carries ONE
--          transaction row (server -> client) and, in TL-10/TL-11, applies it to the client's
--          master list. TL-9 ships the 5-method Event shell + serialization ONLY; run() is a
--          documented stub because the event is not fired anywhere yet.
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

--- STUB for TL-9. The event is not fired anywhere yet (capture wiring is TL-10), so run() is an
--- intentional no-op. The client-apply body -- append to the master list under an id-collision
--- policy, then refresh an open GUI -- plus targeted server->farm delivery (sendToFarm) land in
--- TL-10/TL-11, where the master list and the live-plus-snapshot duplicate-id race actually
--- exist. Shipping a stub means nothing untested ships.
---@param connection table
function RmAddTransactionEvent:run(connection)
    -- Intentionally empty until TL-10/TL-11 (see above).
end
