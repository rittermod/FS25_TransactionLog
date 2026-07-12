-- RmClearLogEvent.lua
-- Purpose: Server-authoritative, master-user-gated WHOLE-LOG clear of the TransactionLog 2.0 MP layer
--          (TL-15). Closes gaps G7/G11: before this, Clear Log wiped only the local table, so under MP
--          a pure client's clear never reached the server master (where every farm's rows live and
--          where auto-export reads), the server's clear never reached other clients, and ANY player
--          (worker / spectator) could wipe the log -- the destructive interim hazard TL-13's Add
--          Comment / Export gate deliberately left open. This event routes the clear through the
--          authority: a UI click goes to RmTransactionLog.requestClearLog; a pure client sends this
--          REQUEST, the server validates the sender is a MASTER USER, wipes the entire master, and
--          broadcasts a payload-less clear GLOBALLY so every client wipes its local view.
-- Author: Ritter
-- Pattern: the same 5-method object-less Event as RmEditCommentEvent / RmAddTransactionEvent --
--          registered with InitEventClass (NOT InitStaticEventClass, which is base-game-internal and
--          raises "attempt to call a string value" in the mod sandbox). This event carries NO payload
--          (whole-log semantics -- decision 1: all farms, no scope flag), so writeStream schedules
--          NOTHING and readStream reads nothing then applies (the read-then-apply contract still holds
--          for a zero-payload event).
-- Flow:    run() branches on authority (g_server), following the SHIPPED RmEditCommentEvent convention
--          (`g_server == nil`), NOT the connection:getIsServer() key RmSettingsChangeEvent chose -- the
--          two admin-mutation events differ only cosmetically here (both handle the host loopback: the
--          global g_server:broadcastEvent skips the loopback, so the host never re-enters run() for its
--          own broadcast). On a PURE CLIENT (g_server == nil) this is the server's authoritative echo:
--          wipe the local view. On the AUTHORITY (g_server ~= nil) this is a client's REQUEST: hand to
--          RmTransactionLog.handleClearRequest (validate master user -> wipe -> re-broadcast).

RmClearLogEvent = {}
local RmClearLogEvent_mt = Class(RmClearLogEvent, Event)

-- Register the event class at load time with InitEventClass (see RmAddTransactionEvent's
-- InitEventClass call + the TL-9 change log for why the immediate-assign InitStaticEventClass is
-- NOT callable here).
InitEventClass(RmClearLogEvent, "RmClearLogEvent")

--- Engine deserialization factory. The engine calls emptyNew() then readStream() to rebuild the
--- event on the receiving side, so this MUST exist (mp-missing-empty-new).
---@return table event a bare event bound to the class metatable
function RmClearLogEvent.emptyNew()
    return Event.new(RmClearLogEvent_mt)
end

--- Construct a send-side clear request/echo. Payload-less by design (whole-log clear, decision 1): a
--- clear crosses every farm, so there is no id, no farm scope, and no value to carry.
---@return table event
function RmClearLogEvent.new()
    return RmClearLogEvent.emptyNew()
end

--- Serialize nothing. The event carries no payload (whole-log semantics), so writeStream schedules
--- ZERO stream primitives. Kept explicit (rather than omitted) so the 5-method contract is visible
--- and a future payload has an obvious home.
---@param streamId number engine stream handle
---@param connection table
function RmClearLogEvent:writeStream(streamId, connection)
    -- No payload.
end

--- Deserialize nothing, then apply. Engine contract: readStream reconstructs state and applies it, so
--- it ends with self:run(connection) (the standard read-then-apply pattern) even with no fields to
--- read back.
---@param streamId number engine stream handle
---@param connection table
function RmClearLogEvent:readStream(streamId, connection)
    self:run(connection)
end

--- Apply the clear. INVERTED relative to the add/snapshot events (which early-return on the authority),
--- following the shipped RmEditCommentEvent convention (branch on g_server, not connection:getIsServer):
---
--- On a PURE CLIENT (g_server == nil): this is the server's authoritative echo. Wipe the local store in
--- place + repaint an open frame; NO re-broadcast. Idempotent -- an already-empty (spectator) store
--- stays empty without raising.
---
--- On the AUTHORITY (g_server ~= nil): this is a client's REQUEST. Hand to RmTransactionLog.handleClearRequest,
--- the single security boundary for remote requests (re-checks g_server, resolves the sender, requires a
--- MASTER USER, then wipes + re-broadcasts). The host itself wiped directly in applyClearAuthoritative and
--- the broadcast skips the loopback, so the host never reaches this branch for its own clear.
---@param connection table the sending connection (the client on the server; nil-ish on the echo)
function RmClearLogEvent:run(connection)
    -- Defensive nil guard (teardown / a crafted event): the engine always supplies a real connection to
    -- readStream -> run, but the authority branch derefs it (handleClearRequest -> getUserByConnection), so
    -- match the feature's nil-safety posture (the sibling RmSettingsChangeEvent:run guards this the same
    -- way) rather than hard-crash. Harmless for the client-echo branch, which never touches the connection.
    if connection == nil then return end
    if g_server == nil then
        -- Pure client: apply the server's authoritative echo, then repaint.
        RmTransactionLog.clearTransactionsInPlace()
        RmTransactionLog.refreshOpenLog()
        return
    end

    -- Authority: a client's REQUEST -- validate (master user) before touching the master.
    RmTransactionLog.handleClearRequest(connection)
end
