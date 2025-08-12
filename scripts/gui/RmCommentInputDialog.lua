-- RmCommentInputDialog.lua
-- Comment input dialog for FS25 Transaction Log mod
-- Author: Ritter
-- Description: Dialog for adding/editing transaction comments

RmCommentInputDialog = {}
local RmCommentInputDialog_mt = Class(RmCommentInputDialog, YesNoDialog)
local function commentInputDialogCallback() end

---Registers the comment input dialog with the GUI system
function RmCommentInputDialog.register()
    RmUtils.logTrace("RmCommentInputDialog.register()")
    local dialog = RmCommentInputDialog.new()
    g_gui:loadGui(RmTransactionLog.dir .. "gui/RmCommentInputDialog.xml", "RmCommentInputDialog", dialog)
    RmCommentInputDialog.INSTANCE = dialog
    dialog.textElement.maxCharacters = 200
end

---Shows the comment input dialog
---@param callback function callback function to call when dialog is closed
---@param target table|nil target object for callback
---@param text string|nil initial text
---@param prompt string|nil dialog prompt text
---@param maxCharacters number|nil maximum character limit
---@param args any|nil additional arguments for callback
function RmCommentInputDialog.show(callback, target, text, prompt, maxCharacters, args)
    RmUtils.logTrace("RmCommentInputDialog.show()")
    if RmCommentInputDialog.INSTANCE ~= nil then
        local dialog = RmCommentInputDialog.INSTANCE
        dialog:setText(text)
        dialog:setCallback(callback, target, text, prompt, maxCharacters, args)
        g_gui:showDialog("RmCommentInputDialog")
    end
end

---Creates a new RmCommentInputDialog instance
---@param target table|nil the target object
---@param customMt table|nil optional custom metatable
---@return RmCommentInputDialog the new dialog instance
function RmCommentInputDialog.new(target, customMt)
    RmUtils.logTrace("RmCommentInputDialog.new()")
    local dialog = YesNoDialog.new(target, customMt or RmCommentInputDialog_mt)
    dialog.onTextEntered = commentInputDialogCallback
    dialog.callbackArgs = nil
    dialog.extraInputDisableTime = 0
    local dismiss = GS_IS_CONSOLE_VERSION
    if dismiss then dismiss = imeIsSupported() end
    dialog.doHide = dismiss
    dialog.disableOpenSound = true
    return dialog
end

---Creates dialog from existing GUI configuration
---@param gui table existing GUI configuration
---@param _ any unused parameter
function RmCommentInputDialog.createFromExistingGui(gui, _)
    RmUtils.logTrace("RmCommentInputDialog.createFromExistingGui()")
    RmCommentInputDialog.register()
    local callback = gui.onTextEntered
    local target = gui.target
    local text = gui.defaultText
    local prompt = gui.dialogPrompt
    local maxCharacters = gui.maxCharacters
    local args = gui.callbackArgs
    RmCommentInputDialog.show(callback, target, text, prompt, maxCharacters, args)
end

function RmCommentInputDialog:onOpen()
    RmUtils.logTrace("RmCommentInputDialog:onOpen()")
    RmCommentInputDialog:superClass().onOpen(self)
    self.extraInputDisableTime = getPlatformId() == PlatformId.SWITCH and 0 or 100
    FocusManager:setFocus(self.textElement)
    self.textElement.blockTime = 0
    self.textElement:onFocusActivate()
    self:updateButtonVisibility()
end

function RmCommentInputDialog:onClose()
    RmUtils.logTrace("RmCommentInputDialog:onClose()")
    RmCommentInputDialog:superClass().onClose(self)
    if not GS_IS_CONSOLE_VERSION then self.textElement:setForcePressed(false) end
    self:updateButtonVisibility()
end

function RmCommentInputDialog:setText(text)
    RmCommentInputDialog:superClass().setText(self, text)
    self.inputText = text
end

function RmCommentInputDialog:setCallback(callback, target, text, prompt, maxCharacters, args)
    self.onTextEntered = callback or commentInputDialogCallback
    self.target = target
    self.callbackArgs = args
    self.textElement:setText(text or "")
    self.textElement.maxCharacters = maxCharacters or self.textElement.maxCharacters

    if prompt ~= nil then self.dialogTextElement:setText(prompt) end

    self.dialogPrompt = prompt
    self.maxCharacters = maxCharacters
end

function RmCommentInputDialog:sendCallback(clickOk)
    local text = self.textElement.text
    self:close()

    if self.target == nil then
        self.onTextEntered(text, clickOk, self.callbackArgs)
    else
        self.onTextEntered(self.target, text, clickOk, self.callbackArgs)
    end
end

function RmCommentInputDialog:onEnterPressed(_, dismiss)
    return dismiss and true or self:onClickOk()
end

function RmCommentInputDialog:onEscPressed(_)
    return self:onClickBack()
end

function RmCommentInputDialog:onClickBack(_, _)
    if self:isInputDisabled() then return true end

    self:sendCallback(false)
    return false
end

function RmCommentInputDialog:onClickOk()
    if self:isInputDisabled() then return true end

    self:sendCallback(true)
    self:updateButtonVisibility()
    return false
end

function RmCommentInputDialog:updateButtonVisibility()
    if self.yesButton ~= nil then self.yesButton:setVisible(not self.textElement.imeActive) end
    if self.noButton ~= nil then self.noButton:setVisible(not self.textElement.imeActive) end
end

function RmCommentInputDialog:update(dT)
    RmCommentInputDialog:superClass().update(self, dT)

    if self.reactivateNextFrame then
        self.textElement.blockTime = 0
        self.textElement:onFocusActivate()
        self.reactivateNextFrame = false
        self:updateButtonVisibility()
    end
    if self.extraInputDisableTime > 0 then
        self.extraInputDisableTime = self.extraInputDisableTime - dT
    end
end

function RmCommentInputDialog:isInputDisabled()
    local disabled

    if self.extraInputDisableTime > 0 then
        disabled = not self.doHide
    else
        disabled = false
    end

    return disabled
end

function RmCommentInputDialog:disableInputForDuration(_)
end

function RmCommentInputDialog:getIsVisible()
    if self.doHide then return false end

    return RmCommentInputDialog:superClass().getIsVisible(self)
end
