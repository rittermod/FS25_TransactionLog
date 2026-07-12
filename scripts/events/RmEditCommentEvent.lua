-- RmEditCommentEvent.lua
-- Purpose: The first REQUEST event of the TransactionLog 2.0 MP layer (TL-13). A farm manager's
--          client edits a transaction comment and asks the server to authorize + persist it. Unlike
--          the add / snapshot events (server -> client, applied client-side), this INVERTS the flow:
--          client -> server (validate + apply + re-broadcast) -> that farm's clients (apply). The
--          server is the security boundary; the GUI button gate is only UX.
-- Author: Ritter
-- Pattern: the same 5-method object-less Event as RmAddTransactionEvent -- registered with
--          InitEventClass (NOT InitStaticEventClass, which is base-game-internal and raises "attempt
--          to call a string value" in the mod sandbox). Payload is (id:Int32, comment:String) -- a
--          by-id edit, NOT the shared 11-field row codec (this event carries no row), so it writes
--          its two fields directly instead of delegating to RmTransactionLogSync.writeRow.
-- Flow:    run() branches on authority (g_server). This is the OPPOSITE of the add/snapshot events'
--          `if g_server ~= nil then return end` guard -- here the SERVER does the work and a pure
--          client only applies the server's echo. See run() for the full validation chain.

RmEditCommentEvent = {}
local RmEditCommentEvent_mt = Class(RmEditCommentEvent, Event)
local Log = RmLogging.getLogger("TransactionLog")

-- Register the event class at load time with InitEventClass (see RmAddTransactionEvent's
-- InitEventClass call + the TL-9 change log for why the immediate-assign InitStaticEventClass is
-- NOT callable here).
InitEventClass(RmEditCommentEvent, "RmEditCommentEvent")

--- Engine deserialization factory. The engine calls emptyNew() then readStream() to rebuild the
--- event on the receiving side, so this MUST exist (mp-missing-empty-new).
---@return table event a bare event bound to the class metatable
function RmEditCommentEvent.emptyNew()
    return Event.new(RmEditCommentEvent_mt)
end

--- Construct a send-side edit request/echo. `id` is a stable, positive Int32 row id (allocated by
--- the server in logTransaction); `comment` is expected pre-normalized by the caller (clamped, "" for
--- nil) -- the server re-clamps on receipt regardless, so a mis-sized value never persists.
---@param id number the stable transaction id of the row to edit
---@param comment string the new comment (caller normalizes; server re-clamps)
---@return table event
function RmEditCommentEvent.new(id, comment)
    local self = RmEditCommentEvent.emptyNew()
    self.id = id
    self.comment = comment
    return self
end

--- Serialize (id, comment). id is written raw as an Int32 -- it is always a positive row id on a
--- real send, so a non-number here is a genuine bug the engine (and the test's contract-enforcing
--- stream mock) should fault on, not silently paper over. comment coerces nil -> "" defensively.
---@param streamId number engine stream handle
---@param connection table
function RmEditCommentEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.id)
    streamWriteString(streamId, self.comment or "")
end

--- Deserialize (id, comment), then apply. Engine contract: readStream reconstructs state and applies
--- it, so it ends with self:run(connection) (the standard read-then-apply pattern).
---@param streamId number engine stream handle
---@param connection table
function RmEditCommentEvent:readStream(streamId, connection)
    self.id = streamReadInt32(streamId)
    self.comment = streamReadString(streamId)
    self:run(connection)
end

--- Apply the edit. INVERTED relative to the add/snapshot events:
---
--- On a PURE CLIENT (g_server == nil): this is the server's authoritative echo. Apply the clamped
--- comment to the local row by id and repaint an open frame. Idempotent / last-writer-wins; a no-op
--- when the id is absent (cleared / not yet delivered).
---
--- On the AUTHORITY (g_server ~= nil): this is a client's REQUEST -- validate, then apply +
--- re-broadcast. The validation order is load-bearing:
---   1. Resolve the sender's farm FIRST (connection -> user -> farm). Reject a nil user or a
---      spectator / invalid farm BEFORE the equality + permission checks, else a nil senderFarmId
---      would slip through `senderFarmId == row.farmId` as `nil == nil`.
---   2. Find the target row by id; reject an unknown id and a row whose own farmId is out of range.
---   3. Require row.farmId == senderFarmId (defense-in-depth against a future refactor dropping the
---      farmId arg below) AND getHasPlayerPermission("farmManager", connection, row.farmId), the
---      verified engine check that enforces same-farm + manager role in one call. A remote worker's
---      connection is non-local/non-server and the master-user check returns false for it, so no
---      short-circuit fires -- the worker is correctly rejected. Cross-farm admin editing is
---      unsupported by design.
---   4. Apply the CLAMPED comment to the master by id; if it still matched, re-broadcast the clamped
---      value to that farm's members via sendToFarm (which skips the host loopback, so the authority
---      never re-applies its own broadcast). Skip the broadcast if the row vanished between validate
---      and apply.
--- Every rejection is a quiet DEBUG drop (a crafted/edge event is not an error); no rollback is sent.
---@param connection table the sending connection (the client on the server; nil-ish on the echo)
function RmEditCommentEvent:run(connection)
    if g_server == nil then
        -- Pure client: apply the server's authoritative (clamped) echo, then repaint.
        RmTransactionLog.applyCommentById(self.id, self.comment)
        RmTransactionLog.refreshOpenLog()
        return
    end

    -- Authority: validate a client's request before touching the master.
    local mission = g_currentMission
    if mission == nil or mission.userManager == nil or g_farmManager == nil then
        return
    end

    -- 1. Resolve the sender's farm first, so a nil user / spectator / invalid farm is rejected
    --    before the equality + permission checks.
    local user = mission.userManager:getUserByConnection(connection)
    if user == nil then
        Log:debug("RmEditCommentEvent: no user for connection; dropping edit")
        return
    end
    local senderFarm = g_farmManager:getFarmByUserId(user:getId())
    local senderFarmId = senderFarm ~= nil and senderFarm.farmId or nil
    if senderFarmId == nil or senderFarmId <= 0 then
        Log:debug("RmEditCommentEvent: sender resolves to no / spectator farm; dropping edit")
        return
    end

    -- 2. Find the target row; reject an unknown id or an out-of-range row farmId.
    local row = RmTransactionLog.findRowById(self.id)
    if row == nil then
        Log:debug("RmEditCommentEvent: unknown id %s; dropping edit", tostring(self.id))
        return
    end
    if row.farmId == nil or row.farmId <= 0 or row.farmId > FarmManager.MAX_NUM_FARMS then
        Log:debug("RmEditCommentEvent: row id %s has out-of-range farmId %s; dropping edit",
            tostring(self.id), tostring(row.farmId))
        return
    end

    -- 3. Same-farm + manager role. The explicit compare is defense-in-depth; the permission call is
    --    the real authority check.
    if row.farmId ~= senderFarmId then
        Log:debug("RmEditCommentEvent: sender farm %s != row farm %s; dropping edit",
            tostring(senderFarmId), tostring(row.farmId))
        return
    end
    if not mission:getHasPlayerPermission("farmManager", connection, row.farmId) then
        Log:debug("RmEditCommentEvent: connection lacks farmManager on farm %s; dropping edit",
            tostring(row.farmId))
        return
    end

    -- 4. Validated: apply the clamped comment to the master and re-broadcast the clamped value.
    local clamped = RmTransactionLog.clampComment(self.comment)
    if RmTransactionLog.applyCommentById(self.id, clamped) then
        Log:debug("RmEditCommentEvent: farm %s row id %s comment updated by user %s; re-broadcasting",
            tostring(row.farmId), tostring(self.id), tostring(user:getId()))
        RmTransactionLog.refreshOpenLog()
        RmTransactionLogSync.sendToFarm(row.farmId, RmEditCommentEvent.new(self.id, clamped))
    end
end
