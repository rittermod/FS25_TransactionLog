--[[
    main.lua

    Load orchestrator for the TransactionLog mod (the single modDesc <sourceFile>).
    main.lua OWNS the explicit source order for every module, then conditionally
    sources the in-game test runner.

    RmLogging is sourced FIRST: every module that calls RmLogging.getLogger at load
    (RmTransactionLog, RmTransactionLogSettings, both GUI files, the batcher, the
    exporter, the migration, the comment-edit event) aborts if the shared RmLogging
    global is still nil when it is sourced. On a cold start where no sibling Ritter
    mod has populated that global first, sourcing RmLogging ahead of everything else
    is what keeps the GUI (and the rest) defined.

    Two real load-time ordering constraints thread the rest of the chain:
      (a) RmTransactionLogSettings before RmTransactionLog - RmTransactionLog's
          top-level body iterates RmTransactionLogSettings.MENU_ITEMS at load.
      (b) RmTransactionLog before gui/RmTransactionLogFrame - the frame reads
          RmTransactionLog.MAX_COMMENT_LENGTH at load.
    Everything after the frame references its siblings only inside method bodies
    (runtime), so its relative order is free; it is kept in dependency order purely
    for reviewability. The MP event/sync files load UNCONDITIONALLY on both server
    and client (there is no multiplayer flag gate here), with the shared sync codec
    sourced before the events that delegate their row (de)serialization to it.

    The test runner is dev-only: the scripts/tests symlink is git-untracked and
    absent from release builds, so the fileExists gate makes one main.lua work in
    both dev and release. (rmlib/RmLogging.lua, by contrast, is a git-tracked real
    file that ships in releases, so sourcing it here is always safe.)

    Author: Ritter
]]

local modDirectory = g_currentModDirectory

-- RmLogging FIRST - every module below logs at load and aborts on a nil RmLogging.
source(modDirectory .. "scripts/rmlib/RmLogging.lua")

-- Settings before RmTransactionLog (constraint a); RmTransactionLog before the frame (constraint b).
source(modDirectory .. "scripts/RmTransactionLogSettings.lua")
source(modDirectory .. "scripts/RmTransactionLog.lua")
source(modDirectory .. "scripts/gui/RmTransactionLogFrame.lua")
source(modDirectory .. "scripts/gui/RmCommentInputDialog.lua")

-- Remaining modules (sibling references live in method bodies, so order is free below).
source(modDirectory .. "scripts/RmTransactionBatcher.lua")
source(modDirectory .. "scripts/RmTransactionLogExporter.lua")
source(modDirectory .. "scripts/RmTransactionMigration.lua")

-- MP event layer (2.0): loads on server AND client, unconditionally (no flag gate).
-- Sync codec FIRST so each event can delegate its row (de)serialization to it.
source(modDirectory .. "scripts/RmTransactionLogSync.lua")
source(modDirectory .. "scripts/events/RmAddTransactionEvent.lua")
source(modDirectory .. "scripts/events/RmTransactionSnapshotEvent.lua")
source(modDirectory .. "scripts/events/RmEditCommentEvent.lua")
source(modDirectory .. "scripts/events/RmSettingsChangeEvent.lua")
source(modDirectory .. "scripts/events/RmClearLogEvent.lua")

-- =============================================================================
-- TESTING (conditional - the tests/ symlink is dev-only, absent in releases)
-- =============================================================================
local testRunnerPath = modDirectory .. "scripts/tests/RmTestRunner.lua"
if fileExists(testRunnerPath) then
    source(testRunnerPath)
end
