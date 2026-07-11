--[[
    main.lua

    Thin entry point for the TransactionLog mod (modDesc <sourceFile>).
    Sources the mod, then conditionally sources the in-game test runner.

    RmTransactionLog.lua self-sources its siblings (GUI, RmLogging,
    RmTransactionBatcher, RmTransactionLogSettings), so this loader only needs to
    source it - moving that chain out of RmTransactionLog.lua is deferred.

    The test runner is dev-only: the scripts/tests symlink is git-untracked and
    absent from release builds, so the fileExists gate makes one main.lua work in
    both dev and release.

    Author: Ritter
]]

local modDirectory = g_currentModDirectory

-- Load the mod (which cascades to RmLogging, the batcher, settings, and GUI).
source(modDirectory .. "scripts/RmTransactionLog.lua")

-- =============================================================================
-- TESTING (conditional - the tests/ symlink is dev-only, absent in releases)
-- =============================================================================
local testRunnerPath = modDirectory .. "scripts/tests/RmTestRunner.lua"
if fileExists(testRunnerPath) then
    source(testRunnerPath)
end
