-- RmSettingsChangeEvent.lua
-- Purpose: Server-authoritative settings-change event of the TransactionLog 2.0 MP layer (TL-14).
--          Post-TL-12 the MP flag is ON, but a settings change still ran purely on the machine that
--          made it -- on a dedicated server the admin is a CLIENT, so the write never reached the
--          server (where writeSettings/readSettings are server-guarded and where auto-export runs),
--          and it never propagated to other clients' menus, and nothing validated it. This event
--          closes that gap: a UI change routes through RmTransactionLog.requestSettingChange; a pure
--          client sends this REQUEST, the server validates the sender is a MASTER USER, applies +
--          persists server-side, and broadcasts the new value to every client so their menus show the
--          truth. Late joiners get current settings via the appended sendInitialClientState.
-- Author: Ritter
-- Pattern: the same 5-method object-less Event as RmEditCommentEvent / RmAddTransactionEvent --
--          registered with InitEventClass (NOT InitStaticEventClass, which is base-game-internal and
--          raises "attempt to call a string value" in the mod sandbox). Payload is
--          (settingId:String, value:Int32) -- this event carries its OWN small payload, NOT the shared
--          11-field row codec (RmTransactionLogSync.writeRow), so it writes its two fields directly.
--          value is Int32 because all current setting values are integer enum codes (autoExportFrequency
--          = {0,1,2,3}) and setValue gates on exact == membership -- Int32 is drift-proof and removes any
--          float-equality question. A future boolean/string-typed setting must extend this codec.
-- Flow:    run() branches on connection:getIsServer(). This INVERTS the add/snapshot events (which
--          early-return on the authority via `if g_server ~= nil then return end`): a client-origin
--          event (getIsServer() == false, i.e. the connection is a client as seen BY the server)
--          validates + applies + persists + re-broadcasts ON THE SERVER; a server-origin event
--          (getIsServer() == true, the connection is the server as seen by a client) applies ON THE
--          CLIENT. Do NOT copy the add/snapshot `if g_server ~= nil then return end` guard -- this
--          event's server branch is the whole point.

RmSettingsChangeEvent = {}
local RmSettingsChangeEvent_mt = Class(RmSettingsChangeEvent, Event)

-- Register the event class at load time with InitEventClass (see RmAddTransactionEvent's
-- InitEventClass call + the TL-9 change log for why the immediate-assign InitStaticEventClass is
-- NOT callable here).
InitEventClass(RmSettingsChangeEvent, "RmSettingsChangeEvent")

--- Engine deserialization factory. The engine calls emptyNew() then readStream() to rebuild the
--- event on the receiving side, so this MUST exist (mp-missing-empty-new).
---@return table event a bare event bound to the class metatable
function RmSettingsChangeEvent.emptyNew()
    return Event.new(RmSettingsChangeEvent_mt)
end

--- Construct a send-side settings-change request/broadcast. `settingId` is a DEFINITIONS key
--- (e.g. "autoExportFrequency"); `value` is the new enum value, a non-nil integer (the UI guards
--- value ~= nil, RmTransactionLog.onMenuOptionChanged; the join-sync re-sends the stored getValue,
--- always a set number).
---@param settingId string the setting id to change
---@param value number the new enum value (integer)
---@return table event
function RmSettingsChangeEvent.new(settingId, value)
    local self = RmSettingsChangeEvent.emptyNew()
    self.settingId = settingId
    self.value = value
    return self
end

--- Serialize (settingId, value). settingId coerces nil -> "" defensively; value is written raw as an
--- Int32 -- it is always a non-nil integer enum code on a real send, so a non-number here is a genuine
--- bug the engine (and the test's contract-enforcing stream mock) should fault on, not silently paper over.
---@param streamId number engine stream handle
---@param connection table
function RmSettingsChangeEvent:writeStream(streamId, connection)
    streamWriteString(streamId, self.settingId or "")
    streamWriteInt32(streamId, self.value)
end

--- Deserialize (settingId, value), then apply. Engine contract: readStream reconstructs state and
--- applies it, so it ends with self:run(connection) (the standard read-then-apply pattern).
---@param streamId number engine stream handle
---@param connection table
function RmSettingsChangeEvent:readStream(streamId, connection)
    self.settingId = streamReadString(streamId)
    self.value = streamReadInt32(streamId)
    self:run(connection)
end

--- Apply the change. INVERTED relative to the add/snapshot events (branch on the CONNECTION, not on
--- g_server):
---
--- Client-origin (connection:getIsServer() == false) -- a client's REQUEST arriving on the server.
--- Hand to RmTransactionLog.handleSettingChangeRequest, the single security boundary: it re-checks
--- g_server, resolves the sender, requires a MASTER USER, then applies + persists + re-broadcasts.
---
--- Server-origin (connection:getIsServer() == true) -- the server's authoritative broadcast arriving
--- on a pure client. Apply the value locally WITHOUT persisting (persistence is server-only). The
--- broadcast uses sendLocal=false and the join send skips the host loopback, so the host never enters
--- this branch for its own change.
---@param connection table the sending connection (the client on the server; the server on a client)
function RmSettingsChangeEvent:run(connection)
    -- Defensive nil guard (teardown / a crafted event): the engine always supplies a real connection
    -- to readStream -> run, but this is the one boundary method here that derefs it, so match the rest
    -- of the feature's nil-safety posture rather than hard-crash.
    if connection == nil then return end
    if not connection:getIsServer() then
        RmTransactionLog.handleSettingChangeRequest(connection, self.settingId, self.value)
    else
        RmTransactionLog.applySettingFromNetwork(self.settingId, self.value)
    end
end
