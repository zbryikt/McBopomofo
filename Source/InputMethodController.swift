// Copyright (c) 2022 and onwards The McBopomofo Authors.
//
// Permission is hereby granted, free of charge, to any person
// obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use,
// copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following
// conditions:
//
// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
// OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
// HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
// WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
// OTHER DEALINGS IN THE SOFTWARE.

import CandidateUI
import Carbon
import Cocoa
import InputMethodKit
import InputSourceHelper
import NotifierUI
import OpenCCBridge
import SystemCharacterInfo
import TooltipUI

extension Bool {
    fileprivate var state: NSControl.StateValue {
        self ? .on : .off
    }
}

private let kMinKeyLabelSize: CGFloat = 10

internal var gCurrentCandidateController: CandidateController?

extension CandidateController {
    static let horizontal = HorizontalCandidateController()
    static let vertical = VerticalCandidateController()
}

@objc(McBopomofoInputMethodController)
class McBopomofoInputMethodController: IMKInputController {

    private static let tooltipController = TooltipController()

    // MARK: -

    var currentClient: Any?
    var keyHandler: KeyHandler = KeyHandler()
    var state: InputState = InputState.Empty()

    // Share the stored issues, so a set of issues is shown as notification only once.
    static var latestUserFileIssues: [String] = []

    // The controller of the currently focused client, which receives voice input results.
    private static weak var activeController: McBopomofoInputMethodController?
    // The controller where the ongoing voice input started and is previewed.
    private static weak var voiceInputController: McBopomofoInputMethodController?
    // Whether the left Option key is pressed with no other key since.
    private var isLeftOptionTapPending = false
    // The mode toggle key pressed with no other key since, and when.
    private var modeToggleTap: (keyCode: Int, time: Date)?
    // Whether keys type English, switched by tapping the mode toggle key. Shared
    // by all apps, like Caps Lock.
    private static var isEnglishMode = false

    // MARK: - IMKInputController methods

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
        keyHandler.delegate = self
    }

    override func menu() -> NSMenu! {
        let menu = NSMenu(title: "Input Method Menu")

        let chineseConversionItem = menu.addItem(
            withTitle: NSLocalizedString("Convert to Simplified Chinese", comment: ""),
            action: #selector(toggleChineseConverter(_:)), keyEquivalent: "g")
        chineseConversionItem.keyEquivalentModifierMask = [.command, .control]
        chineseConversionItem.state = Preferences.chineseConversionEnabled.state

        let halfWidthPunctuationItem = menu.addItem(
            withTitle: NSLocalizedString("Use Half-Width Punctuations", comment: ""),
            action: #selector(toggleHalfWidthPunctuation(_:)), keyEquivalent: "h")
        halfWidthPunctuationItem.keyEquivalentModifierMask = [.command, .control]
        halfWidthPunctuationItem.state = Preferences.halfWidthPunctuationEnabled.state
        let associatedPhrasesItem = menu.addItem(
            withTitle: NSLocalizedString("Associated Phrases", comment: ""),
            action: #selector(toggleAssociatedPhrasesEnabled(_:)), keyEquivalent: "")
        associatedPhrasesItem.state = Preferences.associatedPhrasesEnabled.state

        let inputMode = keyHandler.inputMode

        // Only Bopomofo mode supports Bopomofo Font Annotation. If support is
        // on, ensure that the user has a way to disable it. Otherwise, only
        // show the item when it is set to show in the input menu.
        if inputMode == .bopomofo
            && (Preferences.showBopomofoFontAnnotationSupportItemInInputMenu
                || Preferences.bopomofoFontAnnotationSupportEnabled)
        {
            let bopomofoFontAnnotationSupportItem = menu.addItem(
                withTitle: NSLocalizedString("Bopomofo Font Annotation Support", comment: ""),
                action: #selector(toggleBopomofoFontAnnotationSupport(_:)), keyEquivalent: "")
            bopomofoFontAnnotationSupportItem.state =
                Preferences.bopomofoFontAnnotationSupportEnabled.state
        }

        let optionKeyPressed = NSEvent.modifierFlags.contains(.option)
        if inputMode == .bopomofo && optionKeyPressed {
            let phaseReplacementItem = menu.addItem(
                withTitle: NSLocalizedString("Use Phrase Replacement", comment: ""),
                action: #selector(togglePhraseReplacement(_:)), keyEquivalent: "")
            phaseReplacementItem.state = Preferences.phraseReplacementEnabled.state
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            withTitle: NSLocalizedString("User Phrases", comment: ""), action: nil,
            keyEquivalent: "")

        if inputMode == .plainBopomofo {
            if Preferences.enableUserPhrasesInPlainBopomofo {
                menu.addItem(
                    withTitle: NSLocalizedString("Edit User Phrases", comment: ""),
                    action: #selector(openUserPhrasesPlainBopomofo(_:)), keyEquivalent: "")
            }
            menu.addItem(
                withTitle: NSLocalizedString("Edit Excluded Phrases", comment: ""),
                action: #selector(openExcludedPhrasesPlainBopomofo(_:)), keyEquivalent: "")
        } else {
            menu.addItem(
                withTitle: NSLocalizedString("Edit User Phrases", comment: ""),
                action: #selector(openUserPhrases(_:)), keyEquivalent: "")
            menu.addItem(
                withTitle: NSLocalizedString("Edit Excluded Phrases", comment: ""),
                action: #selector(openExcludedPhrasesMcBopomofo(_:)), keyEquivalent: "")
            if optionKeyPressed {
                menu.addItem(
                    withTitle: NSLocalizedString("Edit Phrase Replacement Table", comment: ""),
                    action: #selector(openPhraseReplacementMcBopomofo(_:)), keyEquivalent: "")
            }
        }

        menu.addItem(
            withTitle: NSLocalizedString("Reload User Phrases", comment: ""),
            action: #selector(reloadUserPhrases(_:)), keyEquivalent: "")

        if !McBopomofoInputMethodController.latestUserFileIssues.isEmpty {
            // Setting menuItem.image does not work in input method menus even on macOS 26,
            // so we just use the alert emoji in the menu item title.
            let menuItem = NSMenuItem(
                title: NSLocalizedString("Show Issues in User Files ⚠️", comment: ""),
                action: #selector(showUserFileIssues(_:)), keyEquivalent: "")
            menu.addItem(menuItem)
        }

        menu.addItem(NSMenuItem.separator())

        menu.addItem(
            withTitle: NSLocalizedString("McBopomofo Preferences", comment: ""),
            action: #selector(showPreferences(_:)), keyEquivalent: "")
        menu.addItem(
            withTitle: NSLocalizedString("Check for Updates…", comment: ""),
            action: #selector(checkForUpdate(_:)), keyEquivalent: "")
        menu.addItem(
            withTitle: NSLocalizedString("About McBopomofo…", comment: ""),
            action: #selector(showAbout(_:)), keyEquivalent: "")
        return menu
    }

    // MARK: - IMKStateSetting protocol methods

    override func activateServer(_ client: Any!) {
        UserDefaults.standard.synchronize()

        // Override the keyboard layout. Use US if not set.
        (client as? IMKTextInput)?.overrideKeyboard(
            withKeyboardNamed: Preferences.basisKeyboardLayout)
        // reset the state
        currentClient = client
        McBopomofoInputMethodController.activeController = self

        keyHandler.clear()
        keyHandler.syncWithPreferences()

        (NSApp.delegate as? AppDelegate)?.checkForUpdate()

        // Give the client a moment to report where its cursor is.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.showModeTip()
        }
    }

    override func deactivateServer(_ client: Any!) {
        if McBopomofoInputMethodController.modeBadgeOwner === self {
            ModeBadge.shared.hide()
            McBopomofoInputMethodController.modeBadgeOwner = nil
        }
        // The voice input preview lives in this client's marked text.
        if McBopomofoInputMethodController.voiceInputController === self {
            let voiceInput = VoiceInputController.shared
            if voiceInput.phase == .reviewing {
                voiceInput.commitReview()
            } else {
                voiceInput.cancel()
            }
        }
        currentClient = nil
        if McBopomofoInputMethodController.activeController === self {
            McBopomofoInputMethodController.activeController = nil
        }
        keyHandler.clear()
        self.handle(state: .Deactivated(), client: client)
    }

    override func setValue(_ value: Any!, forTag tag: Int, client: Any!) {
        let newInputMode = InputMode(rawValue: value as? String ?? InputMode.bopomofo.rawValue)
        LanguageModelManager.loadDataModel(newInputMode)
        // Restore the client layout even when the internal input mode is unchanged.
        (client as? IMKTextInput)?.overrideKeyboard(
            withKeyboardNamed: Preferences.basisKeyboardLayout)
        if keyHandler.inputMode != newInputMode {
            UserDefaults.standard.synchronize()
            // Remember to override the keyboard layout again -- treat this as an activate event.
            keyHandler.clear()
            keyHandler.inputMode = newInputMode
            self.handle(state: .Empty(), client: client)
        }

        // Since setValue is called after activateServer, show user file issues here, if any.
        checkUserFileIssues()
    }

    // MARK: - IMKServerInput protocol methods

    override func commitComposition(_ client: Any!) {
        keyHandler.handleForceCommit(stateCallback: { newState in
            self.handle(state: newState, client: client)
        })
    }

    override func recognizedEvents(_ sender: Any!) -> Int {
        let events: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown]
        return Int(events.rawValue)
    }

    override func handle(_ maybeEvent: NSEvent!, client: Any!) -> Bool {
        // nil may be passed, applefeedback://FB11472618
        guard let event = maybeEvent else {
            commitComposition(client)
            return false
        }
        if Preferences.modeTipPersistent {
            // After the app has handled the key and moved its cursor.
            DispatchQueue.main.async { [weak self] in
                self?.updateModeBadge()
            }
        }

        // Any other key in between makes it a key combination, not a tap,
        // including keys voice input takes (e.g. Cmd + right Option).
        if event.type == .keyDown || event.type == .leftMouseDown
            || (event.type == .flagsChanged
                && Self.modeToggleKeys[Int(event.keyCode)] == nil)
        {
            modeToggleTap = nil
        }
        if Preferences.voiceInputEnabled && handleVoiceInput(event: event, client: client) {
            if event.type == .keyDown {
                refreshVoiceInputPlaceholder()
            }
            return true
        }
        // Mouse events are recognized only for correcting voice input (see
        // mouseDown(onCharacterIndex:)); the key handler takes key events.
        if event.type == .leftMouseDown {
            return false
        }

        if event.type == .flagsChanged {
            handleModeToggleKey(event: event, client: client)
        }

        if event.type == .flagsChanged {
            if Preferences.switchInputSourceUponCommandKeyPressEnabled,
               (event.keyCode == UInt16(kVK_Command) || event.keyCode == UInt16(kVK_RightCommand)),
               event.modifierFlags.contains(.command) {
                keyHandler.clear()
                handle(state: InputState.SwitchingInputSource(sourceID: Preferences.switchInputSourceUponCommandKeyPressInputSourceID), client: client)
                return false
            }

            if state is InputState.Empty {
                return false
            }
            // Handle key up events during active input state.
            //
            // This prevents double-space from affecting the current input.
            // While macOS may normally insert a period on double space, this
            // should be suppressed when there is an active composing buffer or
            // candidate window.
            return true
        }

        if event.type == .flagsChanged {
            let functionKeyKeyboardLayoutID = Preferences.functionKeyboardLayout
            let basisKeyboardLayoutID = Preferences.basisKeyboardLayout

            if functionKeyKeyboardLayoutID == basisKeyboardLayoutID {
                return false
            }

            let includeShift = Preferences.functionKeyKeyboardLayoutOverrideIncludeShiftKey
            let notShift = NSEvent.ModifierFlags(rawValue: ~(NSEvent.ModifierFlags.shift.rawValue))
            if event.modifierFlags.contains(notShift)
                || (event.modifierFlags.contains(.shift) && includeShift)
            {
                (client as? IMKTextInput)?.overrideKeyboard(
                    withKeyboardNamed: functionKeyKeyboardLayoutID)
                return false
            }
            (client as? IMKTextInput)?.overrideKeyboard(withKeyboardNamed: basisKeyboardLayoutID)
            return false
        }

        var textFrame = NSRect.zero
        let attributes: [AnyHashable: Any]? = (client as? IMKTextInput)?.attributes(
            forCharacterIndex: 0, lineHeightRectangle: &textFrame)
        let useVerticalMode =
            (attributes?["IMKTextOrientation"] as? NSNumber)?.intValue == 0 || false
        // Unless Caps Lock switches to English, it only matters in English mode.
        let switchesWithCapsLock = Preferences.capsLockSwitchesToEnglish
        let input = KeyHandlerInput(
            event: event, isVerticalMode: useVerticalMode,
            ignoresCapsLock: !switchesWithCapsLock && !Self.isEnglishMode)
        input.isEnglishMode = Self.isEnglishMode && !switchesWithCapsLock

        let result = keyHandler.handle(input: input, state: state) { newState in
            self.handle(state: newState, client: client)
        } errorCallback: {
            if Preferences.beepUponInputError {
                NSSound.beep()
            }
        }
        // Keys the key handler passes on (e.g. Space with nothing composed)
        // would reach the app; during a toggle-mode recording they join the
        // voice input instead.
        if !result && isTypingIntoVoiceInput {
            if let characters = event.characters, !characters.isEmpty,
                event.modifierFlags.intersection([.command, .control]).isEmpty,
                characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
            {
                VoiceInputController.shared.insert(typedText: characters)
            }
            refreshVoiceInputPlaceholder()
            return true
        }
        return result
    }

    // MARK: - Chinese / English Mode

    /// Switches between Chinese and English when the mode toggle key is
    /// tapped: pressed and released with no other key in between.
    private func handleModeToggleKey(event: NSEvent, client: Any!) {
        let keyCode = Int(event.keyCode)
        if Preferences.capsLockSwitchesToEnglish {
            if keyCode == kVK_CapsLock {
                showModeTip()
            }
            return
        }
        guard let flag = Self.modeToggleKeys[keyCode] else {
            return
        }
        // IMK strips the device-dependent bits, so a press is told from a
        // release by the flag (which stays on while another such key is held).
        guard let tap = modeToggleTap, tap.keyCode == keyCode else {
            // Pressing a second toggle key cancels the tap.
            modeToggleTap =
                event.modifierFlags.contains(flag) && modeToggleTap == nil
                ? (keyCode, Date()) : nil
            return
        }
        modeToggleTap = nil
        // Held longer: likely a key combination the app was not told of, such
        // as Cmd + Tab or Cmd + click.
        guard Date().timeIntervalSince(tap.time) < Self.modeToggleTapDuration else {
            return
        }
        if VoiceInputController.shared.phase != .idle {
            // Typing during voice input has its own language.
            VoiceInputController.shared.toggleTypingLanguage()
            return
        }
        // Finish what is being composed before switching.
        commitComposition(client)
        Self.isEnglishMode.toggle()
        showModeTip()
    }

    private static let modeToggleTapDuration: TimeInterval = 0.15

    /// The mode toggle keys by key code, with the modifier flag each sets.
    private static var modeToggleKeys: [Int: NSEvent.ModifierFlags] {
        let keys: [String: (code: Int, flag: NSEvent.ModifierFlags)] = [
            "leftOption": (kVK_Option, .option),
            "leftCommand": (kVK_Command, .command),
            "rightCommand": (kVK_RightCommand, .command),
            "rightShift": (kVK_RightShift, .shift),
        ]
        var result: [Int: NSEvent.ModifierFlags] = [:]
        for name in Preferences.modeToggleKey.split(separator: ",") {
            if let key = keys[name.trimmingCharacters(in: .whitespaces)] {
                result[key.code] = key.flag
            }
        }
        return result
    }

    /// Whether keys type English, either switched with the mode toggle key or,
    /// as in McBopomofo, with Caps Lock on.
    private var typesEnglish: Bool {
        Preferences.capsLockSwitchesToEnglish
            ? NSEvent.modifierFlags.contains(.capsLock) : Self.isEnglishMode
    }

    // MARK: - Mode Tip

    private static let modeTip = TooltipController()
    private static var modeTipGeneration = 0

    /// Briefly shows next to the cursor whether keys type Chinese or English.
    private func showModeTip() {
        if Preferences.modeTipPersistent {
            McBopomofoInputMethodController.modeBadgeOwner = self
            updateModeBadge()
            return
        }
        guard Preferences.modeTipEnabled, currentClient != nil,
            McBopomofoInputMethodController.activeController === self,
            let client = currentClient as? IMKTextInput
        else {
            return
        }
        var lineHeightRect = NSMakeRect(0, 0, 16, 16)
        client.attributes(forCharacterIndex: 0, lineHeightRectangle: &lineHeightRect)
        guard lineHeightRect.origin != .zero else {
            return
        }
        let tip = typesEnglish ? "EN" : "中"
        Self.modeTipGeneration += 1
        let generation = Self.modeTipGeneration
        Self.modeTip.show(tooltip: tip, at: lineHeightRect.origin)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if generation == Self.modeTipGeneration {
                Self.modeTip.hide()
            }
        }
    }

    /// The controller whose cursor the persistent mode badge follows.
    private static weak var modeBadgeOwner: McBopomofoInputMethodController?

    /// Moves the persistent mode badge to the cursor, and shows the mode.
    private func updateModeBadge() {
        guard Preferences.modeTipPersistent,
            McBopomofoInputMethodController.modeBadgeOwner === self,
            let client = currentClient as? IMKTextInput
        else {
            return
        }
        var lineHeightRect = NSMakeRect(0, 0, 16, 16)
        var index = 0
        if let state = state as? InputState.NotEmpty {
            index = Int(state.cursorIndex)
        }
        client.attributes(forCharacterIndex: index, lineHeightRectangle: &lineHeightRect)
        guard lineHeightRect.origin != .zero else {
            ModeBadge.shared.hide()
            return
        }
        ModeBadge.shared.show(english: typesEnglish, above: lineHeightRect) { [weak self] in
            // Polled: the input method is not told when the cursor moves
            // with the mouse.
            self?.updateModeBadge()
        }
    }

    // MARK: - Menu Items

    @objc override func showPreferences(_ sender: Any?) {
        super.showPreferences(sender)
    }

    @objc func toggleChineseConverter(_ sender: Any?) {
        let enabled = Preferences.toggleChineseConversionEnabled()
        NotifierController.notify(
            message: enabled
                ? NSLocalizedString("Chinese Conversion On", comment: "")
                : NSLocalizedString("Chinese Conversion Off", comment: ""))
        if let currentClient = currentClient {
            keyHandler.clear()
            self.handle(state: InputState.Empty(), client: currentClient)
        }
    }

    @objc func toggleHalfWidthPunctuation(_ sender: Any?) {
        let enabled = Preferences.toggleHalfWidthPunctuationEnabled()
        NotifierController.notify(
            message: enabled
                ? NSLocalizedString("Half-Width Punctuation On", comment: "")
                : NSLocalizedString("Half-Width Punctuation Off", comment: ""))
        if let currentClient = currentClient {
            keyHandler.clear()
            self.handle(state: InputState.Empty(), client: currentClient)
        }
    }

    @objc func toggleAssociatedPhrasesEnabled(_ sender: Any?) {
        _ = Preferences.toggleAssociatedPhrasesEnabled()
    }

    @objc func toggleBopomofoFontAnnotationSupport(_ sender: Any?) {
        let enabled = Preferences.toggleBopomofoFontAnnotationSupportEnabled()
        NotifierController.notify(
            message: enabled
                ? NSLocalizedString("Bopomofo Font Annotation Support On", comment: "")
                : NSLocalizedString("Bopomofo Font Annotation Support Off", comment: ""))
    }

    @objc func togglePhraseReplacement(_ sender: Any?) {
        let enabled = Preferences.togglePhraseReplacementEnabled()
        LanguageModelManager.phraseReplacementEnabled = enabled
    }

    @objc func checkForUpdate(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.checkForUpdate(forced: true)
    }

    @objc func openUserPhrases(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.openUserPhrases(sender)
    }

    @objc func openUserPhrasesPlainBopomofo(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.openUserPhrasesPlainBopomofo(sender)
    }

    @objc func openExcludedPhrasesPlainBopomofo(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.openExcludedPhrasesPlainBopomofo(sender)
    }

    @objc func openExcludedPhrasesMcBopomofo(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.openExcludedPhrasesMcBopomofo(sender)
    }

    @objc func openPhraseReplacementMcBopomofo(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.openPhraseReplacementMcBopomofo(sender)
    }

    @objc func reloadUserPhrases(_ sender: Any?) {
        LanguageModelManager.loadUserPhrases(
            enableForPlainBopomofo: Preferences.enableUserPhrasesInPlainBopomofo)
        LanguageModelManager.loadUserPhraseReplacement()

        // Empty the issues so that if there are still the same issues, a
        // notification will be shown.
        McBopomofoInputMethodController.latestUserFileIssues = []
        checkUserFileIssues()
    }

    @objc func showUserFileIssues(_ sender: Any?) {
        let header = NSLocalizedString(
            "Issues were found in the following user phrase files:", comment: "")
        let report =
            header + "\n\n"
            + McBopomofoInputMethodController.latestUserFileIssues.joined(separator: "\n")
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let now = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss.SSS"
        let dateString = formatter.string(from: now)
        let fileName = "UserFileIssues-\(dateString).txt"
        let fileURL = tempDir.appendingPathComponent(fileName)
        do {
            try report.write(to: fileURL, atomically: true, encoding: .utf8)
            NSWorkspace.shared.open(fileURL)
        } catch {
            NSLog("Failed to write report to temporary file: \(error)")
            return
        }
    }

    @objc func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

}

// MARK: - Voice Input

extension McBopomofoInputMethodController {

    /// Handles voice input. Holding the right Option key records, releasing
    /// it transcribes; with Command held when pressing it, recording toggles
    /// on and stops on the next press. While toggled on, typed text joins the
    /// voice input, and tapping the left Option key switches typing between
    /// Bopomofo and English. Returns true if the event is consumed.
    private func handleVoiceInput(event: NSEvent, client: Any!) -> Bool {
        let voiceInput = VoiceInputController.shared
        let isEmpty = state is InputState.Empty || state is InputState.EmptyIgnoringPreviousState

        if event.type == .flagsChanged {
            // IMK strips the device-dependent bits (e.g. NX_DEVICERALTKEYMASK)
            // from modifierFlags, so infer press/release from the key code and
            // the Option flag.
            let isDown = event.modifierFlags.contains(.option)
            switch Int(event.keyCode) {
            case kVK_RightOption:
                switch voiceInput.phase {
                case .idle:
                    guard isDown, isEmpty, let client = client as? IMKTextInput else {
                        return false
                    }
                    McBopomofoInputMethodController.voiceInputController = self
                    voiceInput.start(
                        client: client,
                        toggleMode: event.modifierFlags.contains(.command),
                        typesEnglish: typesEnglish,
                        preview: { [weak self] text in
                            self?.previewVoiceInput(text)
                        },
                        completion: { text in
                            McBopomofoInputMethodController.commitVoiceInput(text)
                        })
                    refreshVoiceInputPlaceholder()
                case .recording:
                    if !voiceInput.isToggleMode || isDown {
                        finishVoiceRecording(client: client)
                    }
                case .reviewing:
                    if isDown && isEmpty {
                        voiceInput.openSelectionCandidates()
                        refreshVoiceInputPlaceholder()
                    }
                case .processing:
                    break
                }
                return true
            case kVK_Option where isTypingIntoVoiceInput:
                // A tap of the left Option key: pressed and released with no
                // other key in between.
                if isDown {
                    isLeftOptionTapPending = true
                } else if isLeftOptionTapPending {
                    isLeftOptionTapPending = false
                    if isEmpty {
                        voiceInput.toggleTypingLanguage()
                    }
                }
                return true
            default:
                return false
            }
        }

        guard event.type == .keyDown && voiceInput.phase != .idle else {
            return false
        }
        isLeftOptionTapPending = false
        let keyCode = Int(event.keyCode)
        let isEnter = keyCode == kVK_Return || keyCode == kVK_ANSI_KeypadEnter

        if voiceInput.phase == .reviewing {
            // While composing, keys go to the key handler as usual; committed
            // text is inserted into the result.
            return isEmpty ? handleVoiceInputReview(keyCode: keyCode, event: event) : false
        }
        if voiceInput.phase == .processing {
            // Enter commits the preview as is; Esc cancels; other keys are
            // ignored.
            if keyCode == kVK_Escape {
                voiceInput.cancel()
            } else if isEnter {
                voiceInput.commitPreview()
            }
            return true
        }

        // Recording. While composing, keys go to the key handler as usual.
        if !isEmpty {
            return false
        }
        switch keyCode {
        case kVK_Escape:
            voiceInput.cancel()
            return true
        case kVK_UpArrow:
            voiceInput.adjustPolishLevel(by: 1)
            return true
        case kVK_DownArrow:
            voiceInput.adjustPolishLevel(by: -1)
            return true
        default:
            break
        }
        if !voiceInput.isToggleMode {
            // Right Option is being used as a modifier (e.g. Option + key),
            // not for talking.
            voiceInput.cancel()
            return false
        }
        if isEnter {
            finishVoiceRecording(client: client)
            return true
        }
        if keyCode == kVK_Delete {
            voiceInput.deleteBackward()
            return true
        }
        if !event.modifierFlags.intersection([.command, .control]).isEmpty {
            return true
        }
        if voiceInput.isTypingEnglish {
            if let characters = event.characters, !characters.isEmpty,
                characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
            {
                voiceInput.insert(typedText: characters)
            }
            return true
        }
        // Bopomofo: the key handler composes, and committed text joins the
        // voice input.
        return false
    }

    /// Handles keys while checking the result. Returns false for keys that
    /// commit the result and then go on to the key handler.
    private func handleVoiceInputReview(keyCode: Int, event: NSEvent) -> Bool {
        let voiceInput = VoiceInputController.shared
        if !voiceInput.candidates.isEmpty {
            if let digit = Int(event.charactersIgnoringModifiers ?? ""), (1...9).contains(digit) {
                voiceInput.chooseCandidate(at: digit - 1)
                return true
            }
            if keyCode == kVK_Escape {
                voiceInput.closeCandidates()
                return true
            }
        }
        switch keyCode {
        case kVK_Return, kVK_ANSI_KeypadEnter:
            voiceInput.commitReview()
        case kVK_Escape:
            voiceInput.cancel()
        case kVK_LeftArrow, kVK_RightArrow:
            let toRight = keyCode == kVK_RightArrow
            if event.modifierFlags.contains(.shift) {
                voiceInput.adjustSelectionLength(by: toRight ? 1 : -1)
            } else if event.modifierFlags.contains(.command) {
                voiceInput.shiftSelection(by: toRight ? 1 : -1)
            } else {
                voiceInput.moveSelection(toRight: toRight)
            }
        case kVK_DownArrow:
            voiceInput.narrowSelection()
        case kVK_Space:
            voiceInput.insert(typedText: " ")
        case kVK_ANSI_Z where !event.modifierFlags.intersection([.command, .control]).isEmpty:
            if event.modifierFlags.contains(.shift) {
                voiceInput.redoReview()
            } else {
                voiceInput.undoReview()
            }
        case kVK_UpArrow:
            voiceInput.widenSelection()
        case kVK_Delete:
            voiceInput.deleteBackwardInReview()
        case kVK_ForwardDelete:
            voiceInput.deleteForwardInReview()
        default:
            if !event.modifierFlags.intersection([.command, .control]).isEmpty {
                return true
            }
            if voiceInput.isTypingEnglish {
                if let characters = event.characters, !characters.isEmpty,
                    characters.unicodeScalars.allSatisfy({
                        !CharacterSet.controlCharacters.contains($0)
                    })
                {
                    voiceInput.insert(typedText: characters)
                }
                return true
            }
            // Bopomofo: the key handler composes, and committed text is
            // inserted into the result.
            return false
        }
        return true
    }

    /// Clicking a character of the result being checked opens its candidates.
    override func mouseDown(
        onCharacterIndex index: Int, coordinate point: NSPoint, withModifier flags: Int,
        continueTracking keepTracking: UnsafeMutablePointer<ObjCBool>!, client sender: Any!
    ) -> Bool {
        let voiceInput = VoiceInputController.shared
        NSLog("McBopomofo voice input: mouse down on character %d", index)
        guard McBopomofoInputMethodController.voiceInputController === self,
            voiceInput.phase == .reviewing
        else {
            return false
        }
        voiceInput.openCandidates(at: index)
        return true
    }

    /// Finishes a recording, first adding what is being composed.
    private func finishVoiceRecording(client: Any!) {
        if isTypingIntoVoiceInput && state is InputState.NotEmpty {
            commitComposition(client)
        }
        VoiceInputController.shared.finishRecording()
    }

    /// Whether keys are being typed into a toggle-mode recording.
    private var isTypingIntoVoiceInput: Bool {
        let voiceInput = VoiceInputController.shared
        return McBopomofoInputMethodController.voiceInputController === self
            && ((voiceInput.phase == .recording && voiceInput.isToggleMode)
                || voiceInput.phase == .reviewing)
    }

    /// The voice input shown before the composing buffer while typing during
    /// a toggle-mode recording.
    private var voiceInputPrefix: String {
        voiceInputSurroundings.before
    }

    /// The voice input shown around the composing buffer.
    private var voiceInputSurroundings: (before: String, after: String) {
        let voiceInput = VoiceInputController.shared
        // With the floating panel, marked text holds only what is composed.
        guard isTypingIntoVoiceInput, !voiceInput.usesPanel else {
            return ("", "")
        }
        if voiceInput.phase == .reviewing {
            return voiceInput.reviewSurroundings
        }
        return (voiceInput.previewText, "")
    }

    /// Marked text standing in for voice input shown in the floating panel.
    ///
    /// Some apps (e.g. iTerm2) handle a key themselves when the input method
    /// neither inserts nor marks text for it, so keys taken by voice input
    /// must leave marked text behind.
    private static let voiceInputPlaceholder = "🎙"

    /// Puts the placeholder in place of empty marked text while voice input
    /// is shown in the panel.
    private func refreshVoiceInputPlaceholder() {
        let voiceInput = VoiceInputController.shared
        guard voiceInput.usesPanel, voiceInput.phase != .idle,
            McBopomofoInputMethodController.voiceInputController === self,
            state is InputState.Empty || state is InputState.EmptyIgnoringPreviousState,
            let client = currentClient as? IMKTextInput
        else {
            return
        }
        client.setMarkedText(
            Self.voiceInputPlaceholder, selectionRange: NSMakeRange(2, 0),
            replacementRange: NSMakeRange(NSNotFound, NSNotFound))
    }

    /// Sets the composing buffer as marked text, after the voice input in
    /// progress if any.
    fileprivate func setComposingMarkedText(
        _ string: Any, selectionRange: NSRange, client: IMKTextInput
    ) {
        let (prefix, suffix) = voiceInputSurroundings
        if VoiceInputController.shared.usesPanel && isTypingIntoVoiceInput
            && ((string as? String)?.isEmpty ?? false)
        {
            // Nothing composed: keep the placeholder rather than no marked text.
            refreshVoiceInputPlaceholder()
            return
        }
        guard !prefix.isEmpty || !suffix.isEmpty else {
            client.setMarkedText(
                string, selectionRange: selectionRange,
                replacementRange: NSMakeRange(NSNotFound, NSNotFound))
            return
        }
        let text = NSMutableAttributedString(
            string: prefix,
            attributes: [
                .underlineStyle: NSUnderlineStyle.single.rawValue, .markedClauseSegment: 0,
            ])
        if let attributed = string as? NSAttributedString {
            text.append(attributed)
        } else if let plain = string as? String {
            text.append(
                NSAttributedString(
                    string: plain,
                    attributes: [
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                        .markedClauseSegment: 1,
                    ]))
        }
        text.append(
            NSAttributedString(
                string: suffix,
                attributes: [
                    .underlineStyle: NSUnderlineStyle.single.rawValue, .markedClauseSegment: 2,
                ]))
        let offset = (prefix as NSString).length
        client.setMarkedText(
            text,
            selectionRange: NSMakeRange(selectionRange.location + offset, selectionRange.length),
            replacementRange: NSMakeRange(NSNotFound, NSNotFound))
    }

    /// Shows the voice input in progress as marked text.
    private func previewVoiceInput(_ preview: VoiceInputController.Preview) {
        guard McBopomofoInputMethodController.voiceInputController === self,
            let client = currentClient as? IMKTextInput,
            state is InputState.Empty || state is InputState.EmptyIgnoringPreviousState
        else {
            // While composing, the preview is refreshed with the composing
            // buffer.
            return
        }
        let text = NSMutableAttributedString(
            string: preview.text,
            attributes: [
                .underlineStyle: NSUnderlineStyle.single.rawValue, .markedClauseSegment: 0,
            ])
        if let highlight = preview.highlight,
            NSMaxRange(highlight) <= (preview.text as NSString).length
        {
            text.addAttributes(
                [.underlineStyle: NSUnderlineStyle.thick.rawValue, .markedClauseSegment: 1],
                range: highlight)
            let after = NSMaxRange(highlight)
            text.addAttribute(
                .markedClauseSegment, value: 2,
                range: NSRange(location: after, length: text.length - after))
        }
        client.setMarkedText(
            text, selectionRange: NSMakeRange(preview.cursor, 0),
            replacementRange: NSMakeRange(NSNotFound, NSNotFound))
    }

    /// Commits voice input to the focused client, or copies it to the
    /// pasteboard if McBopomofo is no longer active or is composing.
    private static func commitVoiceInput(_ text: String) {
        if let controller = activeController, let client = controller.currentClient,
            controller.state is InputState.Empty
                || controller.state is InputState.EmptyIgnoringPreviousState
        {
            controller.commit(text: text, client: client)
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        NotifierController.notify(
            message: NSLocalizedString("Voice input copied to the clipboard", comment: ""))
    }
}

// MARK: - State Handling

extension McBopomofoInputMethodController {

    func handle(state newState: InputState, client: Any?) {
        let previous = state
        state = newState

        switch newState {
        case let newState as InputState.Deactivated:
            handle(state: newState, previous: previous, client: client)
            state = .Empty()
        case let newState as InputState.SwitchingInputSource:
            handle(state: newState, previous: previous, client: client)
            state = .Empty()
            if !InputSourceHelper.selectInputSource(withID: newState.sourceID) {
                NSLog("Unable to switch to input source: %@", newState.sourceID)
            }
        case let newState as InputState.Empty:
            handle(state: newState, previous: previous, client: client)
        case let newState as InputState.EmptyIgnoringPreviousState:
            handle(state: newState, previous: previous, client: client)
        case let newState as InputState.Committing:
            handle(state: newState, previous: previous, client: client)
        case let newState as InputState.Inputting:
            handle(state: newState, previous: previous, client: client)
        case let newState as InputState.Marking:
            handle(state: newState, previous: previous, client: client)
        case let newState as InputState.ChoosingCandidate:
            handle(state: newState, previous: previous, client: client)
        case let newState as InputState.AssociatedPhrases:
            handle(state: newState, previous: previous, client: client)
        case let newState as InputState.AssociatedPhrasesPlain:
            handle(state: newState, previous: previous, client: client)
        case let newState as InputState.SelectingFeature:
            handle(state: newState, previous: previous, client: client)
        case let newState as InputState.SelectingDateMacro:
            handle(state: newState, previous: previous, client: client)
        case let newState as InputState.Number:
            handle(state: newState, previous: previous, client: client)
        case let newState as InputState.IcuTransform:
            handle(state: newState, previous: previous, client: client)
        case let newState as InputState.Big5:
            handle(state: newState, previous: previous, client: client)
        case let newState as InputState.SelectingDictionary:
            handle(state: newState, previous: previous, client: client)
        case let newState as InputState.ShowingCharInfo:
            handle(state: newState, previous: previous, client: client)
        case let newState as InputState.CustomMenu:
            handle(state: newState, previous: previous, client: client)
        default:
            break
        }
    }

    private func commit(text: String, client: Any!) {

        func convertToSimplifiedChineseIfRequired(_ text: String) -> String {
            if !Preferences.chineseConversionEnabled {
                return text
            }
            if Preferences.chineseConversionStyle == .model {
                return text
            }
            return OpenCCBridge.shared.convertToSimplified(text) ?? ""
        }

        let buffer = convertToSimplifiedChineseIfRequired(text)
        if buffer.isEmpty {
            return
        }
        // Text typed during a toggle-mode recording joins the voice input.
        if isTypingIntoVoiceInput {
            VoiceInputController.shared.insert(typedText: buffer)
            return
        }
        (client as? IMKTextInput)?.insertText(
            buffer, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
    }

    private func handle(state: InputState.Deactivated, previous: InputState, client: Any?) {
        currentClient = nil

        gCurrentCandidateController?.delegate = nil
        gCurrentCandidateController?.visible = false
        hideTooltip()

        guard let client = client as? IMKTextInput else {
            return
        }

        switch previous {
        case let previous as InputState.NotEmpty:
            commit(text: previous.composingBuffer, client: client)
        case is InputState.Big5,
            is InputState.Number,
            is InputState.IcuTransform:
            client.setMarkedText(
                "", selectionRange: NSMakeRange(0, 0), replacementRange: NSMakeRange(0, 0))
        default:
            break
        }

        // Unlike the Empty state handler, we don't call client.setMarkedText() here:
        // there's no point calling setMarkedText() with an empty string as the session
        // is being deactivated anyway, and we have found issues with how certains app
        // could not handle setMarkedText() at this point (see GitHub issue #346).
    }

    private func handle(state: InputState.Empty, previous: InputState, client: Any?) {
        gCurrentCandidateController?.visible = false
        hideTooltip()

        guard let client = client as? IMKTextInput else {
            return
        }

        if let previous = previous as? InputState.NotEmpty {
            commit(text: previous.composingBuffer, client: client)
        }
        setComposingMarkedText(
            "", selectionRange: NSMakeRange(0, 0), client: client)
    }

    private func handle(
        state: InputState.EmptyIgnoringPreviousState, previous: InputState, client: Any!
    ) {
        gCurrentCandidateController?.visible = false
        hideTooltip()

        guard let client = client as? IMKTextInput else {
            return
        }

        setComposingMarkedText(
            "", selectionRange: NSMakeRange(0, 0), client: client)
    }

    private func handle(state: InputState.Committing, previous: InputState, client: Any?) {
        gCurrentCandidateController?.visible = false
        hideTooltip()

        guard let client = client as? IMKTextInput else {
            return
        }

        let poppedText = state.poppedText
        if !poppedText.isEmpty {
            commit(text: poppedText, client: client)
        }
        setComposingMarkedText(
            "", selectionRange: NSMakeRange(0, 0), client: client)
    }

    private func handle(state: InputState.Inputting, previous: InputState, client: Any?) {
        gCurrentCandidateController?.visible = false
        hideTooltip()

        guard let client = client as? IMKTextInput else {
            return
        }

        // the selection range is where the cursor is, with the length being 0 and replacement range NSNotFound,
        // i.e. the client app needs to take care of where to put this composing buffer
        setComposingMarkedText(
            state.attributedString, selectionRange: NSMakeRange(Int(state.cursorIndex), 0), client: client)
        if !state.tooltip.isEmpty {
            show(
                tooltip: state.tooltip, composingBuffer: state.composingBuffer,
                cursorIndex: state.cursorIndex, client: client)
        }
    }

    private func handle(state: InputState.Marking, previous: InputState, client: Any?) {
        gCurrentCandidateController?.visible = false
        guard let client = client as? IMKTextInput else {
            hideTooltip()
            return
        }

        // the selection range is where the cursor is, with the length being 0 and replacement range NSNotFound,
        // i.e. the client app needs to take care of where to put this composing buffer
        setComposingMarkedText(
            state.attributedString, selectionRange: NSMakeRange(Int(state.cursorIndex), 0), client: client)

        if state.tooltip.isEmpty {
            hideTooltip()
        } else {
            show(
                tooltip: state.tooltip, composingBuffer: state.composingBuffer,
                cursorIndex: state.markerIndex, client: client)
        }
    }

    private func handle(state: InputState.ChoosingCandidate, previous: InputState, client: Any?) {
        hideTooltip()
        guard let client = client as? IMKTextInput else {
            gCurrentCandidateController?.visible = false
            return
        }

        // the selection range is where the cursor is, with the length being 0 and replacement range NSNotFound,
        // i.e. the client app needs to take care of where to put this composing buffer
        setComposingMarkedText(
            state.attributedString, selectionRange: NSMakeRange(Int(state.cursorIndex), 0), client: client)
        show(candidateWindowWith: state, client: client)
    }

    private func handle(state: InputState.AssociatedPhrases, previous: InputState, client: Any?) {
        hideTooltip()
        guard let client = client as? IMKTextInput else {
            gCurrentCandidateController?.visible = false
            return
        }

        let previousState = state.previousState
        // the selection range is where the cursor is, with the length being 0 and replacement range NSNotFound,
        // i.e. the client app needs to take care of where to put this composing buffer
        switch previousState {
        case let previousState as InputState.ChoosingCandidate:
            setComposingMarkedText(
                previousState.attributedString, selectionRange: NSMakeRange(Int(previousState.cursorIndex), 0), client: client)
        case let previousState as InputState.Inputting:
            setComposingMarkedText(
                previousState.attributedString, selectionRange: NSMakeRange(Int(previousState.cursorIndex), 0), client: client)
        default:
            break
        }
        show(candidateWindowWith: state, client: client)
    }

    private func handle(
        state: InputState.AssociatedPhrasesPlain, previous: InputState, client: Any?
    ) {
        hideTooltip()
        guard let client = client as? IMKTextInput else {
            gCurrentCandidateController?.visible = false
            return
        }
        setComposingMarkedText(
            "", selectionRange: NSMakeRange(0, 0), client: client)
        show(candidateWindowWith: state, client: client)
    }

    private func handle(state: InputState.SelectingFeature, previous: InputState, client: Any?) {
        handleStateWithSimpleCandidateWindow(state: state, previous: previous, client: client)
    }

    private func handle(state: InputState.SelectingDateMacro, previous: InputState, client: Any?) {
        handleStateWithSimpleCandidateWindow(state: state, previous: previous, client: client)
    }

    private func handleSpecialInputWithCandidateWindow(state: InputState, composingBuffer: String, candidateCount: Int, client: Any?) {
        gCurrentCandidateController?.visible = false
        hideTooltip()

        guard let client = client as? IMKTextInput else {
            return
        }

        setComposingMarkedText(
            composingBuffer, selectionRange: NSMakeRange(
                (composingBuffer as NSString).length,
                0
            ), client: client)
        if candidateCount > 0 {
            show(candidateWindowWith: state, client: client)
        }
    }


    private func handle(state: InputState.Number, previous: InputState, client: Any?) {
        handleSpecialInputWithCandidateWindow(state: state, composingBuffer: state.composingBuffer, candidateCount: state.candidateCount, client: client)
    }

    private func handle(state: InputState.IcuTransform, previous: InputState, client: Any?) {
        handleSpecialInputWithCandidateWindow(state: state, composingBuffer: state.composingBuffer, candidateCount: state.candidateCount, client: client)
    }

    private func handle(state: InputState.Big5, previous: InputState, client: Any?) {
        handleStateForCustomInput(
            composingBuffer: state.composingBuffer, previous: previous, client: client)
    }

    private func handle(state: InputState.SelectingDictionary, previous: InputState, client: Any?) {
        hideTooltip()
        guard let client = client as? IMKTextInput else {
            gCurrentCandidateController?.visible = false
            return
        }
        let previousState = state.previousState
        // the selection range is where the cursor is, with the length being 0 and replacement range NSNotFound,
        // i.e. the client app needs to take care of where to put this composing buffer

        switch previousState {
        case let previousState as InputState.ChoosingCandidate:
            setComposingMarkedText(
                previousState.attributedString, selectionRange: NSMakeRange(Int(previousState.cursorIndex), 0), client: client)
        case let previousState as InputState.Marking:
            setComposingMarkedText(
                previousState.attributedString, selectionRange: NSMakeRange(Int(previousState.cursorIndex), 0), client: client)
        default:
            break
        }
        show(candidateWindowWith: state, client: client)
    }

    private func handle(state: InputState.ShowingCharInfo, previous: InputState, client: Any?) {

        hideTooltip()
        guard let client = client as? IMKTextInput else {
            gCurrentCandidateController?.visible = false
            return
        }
        let previousState = state.previousState.previousState
        // the selection range is where the cursor is, with the length being 0 and replacement range NSNotFound,
        // i.e. the client app needs to take care of where to put this composing buffer
        switch previousState {
        case let previousState as InputState.ChoosingCandidate:
            setComposingMarkedText(
                previousState.attributedString, selectionRange: NSMakeRange(Int(previousState.cursorIndex), 0), client: client)
        case let previousState as InputState.Marking:
            setComposingMarkedText(
                previousState.attributedString, selectionRange: NSMakeRange(Int(previousState.cursorIndex), 0), client: client)
        default:
            break
        }
        show(candidateWindowWith: state, client: client)
    }

    private func handle(state: InputState.CustomMenu, previous: InputState, client: Any?) {
        hideTooltip()
        guard let client = client as? IMKTextInput else {
            gCurrentCandidateController?.visible = false
            return
        }
        show(candidateWindowWith: state, client: client)
    }
}

// MARK: -

extension McBopomofoInputMethodController {
    private func handleStateForCustomInput(
        composingBuffer: String, previous: InputState, client: Any?
    ) {
        gCurrentCandidateController?.visible = false
        hideTooltip()

        guard let client = client as? IMKTextInput else {
            return
        }

        if let previous = previous as? InputState.NotEmpty {
            commit(text: previous.composingBuffer, client: client)
        }
        setComposingMarkedText(
            composingBuffer, selectionRange: NSMakeRange(composingBuffer.utf16.count, 0), client: client)
    }

    private func handleStateWithSimpleCandidateWindow(
        state: InputState, previous: InputState, client: Any?
    ) {
        gCurrentCandidateController?.visible = false
        hideTooltip()

        guard let client = client as? IMKTextInput else {
            return
        }

        if let previous = previous as? InputState.NotEmpty {
            commit(text: previous.composingBuffer, client: client)
        }
        // the selection range is where the cursor is, with the length being 0 and replacement range NSNotFound,
        // i.e. the client app needs to take care of where to put this composing buffer
        setComposingMarkedText(
            "", selectionRange: NSMakeRange(0, 0), client: client)
        show(candidateWindowWith: state, client: client)
    }

    private func show(candidateWindowWith state: InputState, client: Any!) {
        let useVerticalMode: Bool = {
            var useVerticalMode = false
            var candidates: [InputState.Candidate] = []
            switch state {
            case let state as InputState.ChoosingCandidate:
                useVerticalMode = state.useVerticalMode
                candidates = state.candidates
            case let state as InputState.AssociatedPhrasesPlain:
                useVerticalMode = state.useVerticalMode
                candidates = state.candidates
            case let state as InputState.AssociatedPhrases:
                useVerticalMode = state.useVerticalMode
                candidates = state.candidates
            case is InputState.SelectingFeature,
                is InputState.SelectingDateMacro,
                is InputState.SelectingDictionary,
                is InputState.ShowingCharInfo,
                is InputState.Number,
                is InputState.IcuTransform:
                return true
            default:
                break
            }

            if useVerticalMode == true {
                return true
            }
            candidates.sort {
                return $0.displayText.count > $1.displayText.count
            }
            // If there is a candidate which is too long, we use the vertical
            // candidate list window automatically.
            if candidates.first?.displayText.count ?? 0 > 8 {
                return true
            }
            return false
        }()

        gCurrentCandidateController?.delegate = nil
        gCurrentCandidateController?.visible = false

        if useVerticalMode {
            gCurrentCandidateController = .vertical
        } else if Preferences.useHorizontalCandidateList {
            gCurrentCandidateController = .horizontal
        } else {
            gCurrentCandidateController = .vertical
        }

        gCurrentCandidateController?.tooltip =
            switch state {
            case let state as InputState.SelectingDictionary:
                String(format: NSLocalizedString("Look up %@", comment: ""), state.selectedPhrase)
            case let state as InputState.AssociatedPhrases:
                String(format: NSLocalizedString("%@…", comment: ""), state.prefixValue)
            case let state as InputState.CustomMenu:
                state.title
            default:
                ""
            }

        // set the attributes for the candidate panel (which uses NSAttributedString)
        let textSize = Preferences.candidateListTextSize
        let keyLabelSize = max(textSize / 2, kMinKeyLabelSize)

        func font(name: String?, size: CGFloat) -> NSFont {
            if let name = name {
                return NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size)
            }
            return NSFont.systemFont(ofSize: size)
        }

        gCurrentCandidateController?.keyLabelFont = font(
            name: Preferences.candidateKeyLabelFontName, size: keyLabelSize)
        gCurrentCandidateController?.candidateFont = font(
            name: Preferences.candidateTextFontName, size: textSize)

        let candidateKeys = Preferences.candidateKeys
        let keyLabels =
            candidateKeys.count >= 4
            ? Array(candidateKeys) : Array(Preferences.defaultCandidateKeys)

        let keyLabelFormat: (String)->String = switch state {
        case let state as InputState.AssociatedPhrases where state.autoTriggered:
            { _ in "⇧ ⏎" }
        case is InputState.AssociatedPhrasesPlain,
            is InputState.Number,
            is InputState.IcuTransform:
            { "⇧ " + $0 }
        default:
            { $0 }
        }
        gCurrentCandidateController?.keyLabels = keyLabels.map {
            CandidateKeyLabel(key: String($0), displayedText: keyLabelFormat(String($0)))
        }

        gCurrentCandidateController?.delegate = self
        gCurrentCandidateController?.reloadData()
        currentClient = client

        var lineHeightRect = NSMakeRect(0.0, 0.0, 16.0, 16.0)
        var cursor: Int = 0

        if let state = state as? InputState.NotEmpty {
            cursor = Int(state.cursorIndex)
            if cursor == state.composingBuffer.count && cursor != 0 {
                cursor -= 1
            }
        }
        cursor += (voiceInputPrefix as NSString).length

        while lineHeightRect.origin.x == 0 && lineHeightRect.origin.y == 0 && cursor >= 0 {
            (client as? IMKTextInput)?.attributes(
                forCharacterIndex: cursor, lineHeightRectangle: &lineHeightRect)
            cursor -= 1
        }

        if useVerticalMode {
            gCurrentCandidateController?.set(
                windowTopLeftPoint: NSMakePoint(
                    lineHeightRect.origin.x + lineHeightRect.size.width + 4.0,
                    lineHeightRect.origin.y - 4.0),
                bottomOutOfScreenAdjustmentHeight: lineHeightRect.size.height + 4.0)
        } else {
            gCurrentCandidateController?.set(
                windowTopLeftPoint: NSMakePoint(
                    lineHeightRect.origin.x, lineHeightRect.origin.y - 4.0),
                bottomOutOfScreenAdjustmentHeight: lineHeightRect.size.height + 4.0)
        }

        gCurrentCandidateController?.visible = true
    }

    private func show(tooltip: String, composingBuffer: String, cursorIndex: UInt, client: Any!) {
        var lineHeightRect = NSMakeRect(0.0, 0.0, 16.0, 16.0)
        var cursor: Int = Int(cursorIndex)
        if cursor == composingBuffer.count && cursor != 0 {
            cursor -= 1
        }
        cursor += (voiceInputPrefix as NSString).length

        var isVerticalMode = false
        while lineHeightRect.origin.x == 0 && lineHeightRect.origin.y == 0 && cursor >= 0 {
            let attributes: [AnyHashable: Any]? = (client as? IMKTextInput)?.attributes(
                forCharacterIndex: cursor, lineHeightRectangle: &lineHeightRect)
            let useVerticalMode =
                (attributes?["IMKTextOrientation"] as? NSNumber)?.intValue == 0 || false
            isVerticalMode = isVerticalMode || useVerticalMode
            cursor -= 1
        }

        // Make sure that tooltip hovers next to the vertical text.
        if isVerticalMode && lineHeightRect.size.height > 0 {
            lineHeightRect.origin.x += (lineHeightRect.size.width + 1.0)
        }

        McBopomofoInputMethodController.tooltipController.show(
            tooltip: tooltip, at: lineHeightRect.origin)
    }

    private func hideTooltip() {
        McBopomofoInputMethodController.tooltipController.hide()
    }

    private func checkUserFileIssues() {
        let issues: [String] = keyHandler.collectUserFileIssues()

        // McBopomofoLM caps the maximum number of issues collected, and so
        // we'll just do this O(n) comparison since n is small.
        if McBopomofoInputMethodController.latestUserFileIssues != issues {
            McBopomofoInputMethodController.latestUserFileIssues = issues

            if !McBopomofoInputMethodController.latestUserFileIssues.isEmpty {
                NotifierController.notify(
                    message: NSLocalizedString(
                        "Check McBopomofo menu for user file issues", comment: ""), stay: true)
            }
        }
    }
}

// MARK: - Mode Badge

/// A small label kept above the cursor, showing whether keys type Chinese
/// or English, with a dot next to it for Caps Lock.
private final class ModeBadge {
    static let shared = ModeBadge()

    private var window: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private let labelView = NSView()
    private let capsLockDot = NSView()
    private var timer: Timer?
    private let labelSize = NSSize(width: 22, height: 16)
    private let dotDiameter: CGFloat = 6
    private let dotSpacing: CGFloat = 3
    private var size: NSSize {
        NSSize(width: labelSize.width + dotSpacing + dotDiameter, height: labelSize.height)
    }

    private func makeWindow() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(Int(kCGPopUpMenuWindowLevel) + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        let view = NSView(frame: NSRect(origin: .zero, size: size))
        labelView.frame = NSRect(origin: .zero, size: labelSize)
        labelView.wantsLayer = true
        labelView.layer?.cornerRadius = 4
        label.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        label.alignment = .center
        label.textColor = .white
        label.frame = NSRect(x: 0, y: 1, width: labelSize.width, height: labelSize.height - 2)
        labelView.addSubview(label)
        view.addSubview(labelView)
        capsLockDot.frame = NSRect(
            x: labelSize.width + dotSpacing, y: (labelSize.height - dotDiameter) / 2,
            width: dotDiameter, height: dotDiameter)
        capsLockDot.wantsLayer = true
        capsLockDot.layer?.cornerRadius = dotDiameter / 2
        view.addSubview(capsLockDot)
        panel.contentView = view
        return panel
    }

    /// Shows the badge above the cursor line (macOS shows its own indicators
    /// below it), and calls `poll` periodically while shown to follow the
    /// cursor.
    func show(english: Bool, above line: NSRect, poll: @escaping () -> Void) {
        let panel = window ?? makeWindow()
        window = panel
        label.stringValue = english ? "EN" : "中"
        labelView.layer?.backgroundColor = (english
            ? NSColor.systemGray : NSColor(srgbRed: 0.78, green: 0.52, blue: 0.12, alpha: 1))
            .withAlphaComponent(0.85).cgColor
        let capsLock = NSEvent.modifierFlags.contains(.capsLock)
        capsLockDot.layer?.backgroundColor =
            (capsLock ? NSColor.systemGreen : NSColor.systemGray.withAlphaComponent(0.6)).cgColor
        panel.setFrameOrigin(NSPoint(x: line.minX - 2, y: line.maxY + 2))
        panel.orderFront(nil)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { _ in poll() }
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        window?.orderOut(nil)
    }
}
