CommentInputDialog = {}

local commentInputDialog_mt = Class(CommentInputDialog, YesNoDialog)
local function commentInputDialog_callback() end
local modDirectory = g_currentModDirectory

function CommentInputDialog.register()
    logTrace("CommentInputDialog.register()")
    local dialog = CommentInputDialog.new()
    g_gui:loadGui(modDirectory .. "gui/CommentInputDialog.xml", "CommentInputDialog", dialog)
    CommentInputDialog.INSTANCE = dialog
    dialog.textElement.maxCharacters = 200
end

function CommentInputDialog.show(callback, target, text, prompt, maxCharacters, args)
    logTrace("CommentInputDialog.show()")
    if CommentInputDialog.INSTANCE ~= nil then
        local dialog = CommentInputDialog.INSTANCE
        dialog:setText(text)
        dialog:setCallback(callback, target, text, prompt, maxCharacters, args)
        g_gui:showDialog("CommentInputDialog")
    end
end

function CommentInputDialog.new(target, customMt)
    logTrace("CommentInputDialog.new()")
    local dialog = YesNoDialog.new(target, customMt or commentInputDialog_mt)
    dialog.onTextEntered = commentInputDialog_callback
    dialog.callbackArgs = nil
    dialog.extraInputDisableTime = 0
    local dismiss = GS_IS_CONSOLE_VERSION
    if dismiss then dismiss = imeIsSupported() end
    dialog.doHide = dismiss
    dialog.disableOpenSound = true
    return dialog
end

function CommentInputDialog.createFromExistingGui(gui, _)
    logTrace("CommentInputDialog.createFromExistingGui()")
    CommentInputDialog.register()
    local callback = gui.onTextEntered
    local target = gui.target
    local text = gui.defaultText
    local prompt = gui.dialogPrompt
    local maxCharacters = gui.maxCharacters
    local args = gui.callbackArgs
    CommentInputDialog.show(callback, target, text, prompt, maxCharacters, args)
end

function CommentInputDialog:onOpen()
    logTrace("CommentInputDialog:onOpen()")
    CommentInputDialog:superClass().onOpen(self)
    self.extraInputDisableTime = getPlatformId() == PlatformId.SWITCH and 0 or 100
    FocusManager:setFocus(self.textElement)
    self.textElement.blockTime = 0
    self.textElement:onFocusActivate()
    self:updateButtonVisibility()
end

function CommentInputDialog:onClose()
    logTrace("CommentInputDialog:onClose()")
    CommentInputDialog:superClass().onClose(self)
    if not GS_IS_CONSOLE_VERSION then self.textElement:setForcePressed(false) end
    self:updateButtonVisibility()
end

function CommentInputDialog:setText(text)
    logTrace("CommentInputDialog:setText()")
    CommentInputDialog:superClass().setText(self, text)
    self.inputText = text
end

function CommentInputDialog:setCallback(callback, target, text, prompt, maxCharacters, args)
    logTrace("CommentInputDialog:setCallback()")
    self.onTextEntered = callback or commentInputDialog_callback
    self.target = target
    self.callbackArgs = args
    self.textElement:setText(text or "")
    self.textElement.maxCharacters = maxCharacters or self.textElement.maxCharacters
    
    if prompt ~= nil then self.dialogTextElement:setText(prompt) end
    
    self.dialogPrompt = prompt
    self.maxCharacters = maxCharacters
end

function CommentInputDialog:sendCallback(clickOk)
    logTrace("CommentInputDialog:sendCallback()")
    local text = self.textElement.text
    self:close()
    
    if self.target == nil then
        self.onTextEntered(text, clickOk, self.callbackArgs)
    else
        self.onTextEntered(self.target, text, clickOk, self.callbackArgs)
    end
end

function CommentInputDialog:onEnterPressed(_, dismiss)
    logTrace("CommentInputDialog:onEnterPressed()")
    return dismiss and true or self:onClickOk()
end

function CommentInputDialog:onEscPressed(_)
    logTrace("CommentInputDialog:onEscPressed()")
    return self:onClickBack()
end

function CommentInputDialog:onClickBack(_, _)
    logTrace("CommentInputDialog:onClickBack()")
    if self:isInputDisabled() then return true end
    
    self:sendCallback(false)
    return false
end

function CommentInputDialog:onClickOk()
    logTrace("CommentInputDialog:onClickOk()")
    if self:isInputDisabled() then return true end
    
    self:sendCallback(true)
    self:updateButtonVisibility()
    return false
end

function CommentInputDialog:updateButtonVisibility()
    logTrace("CommentInputDialog:updateButtonVisibility()")
    if self.yesButton ~= nil then self.yesButton:setVisible(not self.textElement.imeActive) end
    if self.noButton ~= nil then self.noButton:setVisible(not self.textElement.imeActive) end
end

function CommentInputDialog:update(dT)
    logTrace("CommentInputDialog:update()")
    CommentInputDialog:superClass().update(self, dT)
    
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

function CommentInputDialog:isInputDisabled()
    logTrace("CommentInputDialog:isInputDisabled()")
    local disabled
    
    if self.extraInputDisableTime > 0 then
        disabled = not self.doHide
    else
        disabled = false
    end
    
    return disabled
end

function CommentInputDialog:disableInputForDuration(_)
    logTrace("CommentInputDialog:disableInputForDuration()")
end

function CommentInputDialog:getIsVisible()
    logTrace("CommentInputDialog:getIsVisible()")
    if self.doHide then return false end
    
    return CommentInputDialog:superClass().getIsVisible(self)
end