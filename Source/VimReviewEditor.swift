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

import Foundation
import NaturalLanguage

/// Vim-style editing of the voice input result being checked: one line of
/// text, with normal, insert, visual and command-line modes.
///
/// Keys are passed as the characters typed, or as "<Esc>", "<BS>", "<CR>",
/// "<Left>", "<Right>" and "<C-r>". Positions count characters (grapheme
/// clusters), and words are found with NLTokenizer, so that Chinese text has
/// words too.
struct VimReviewEditor {
    enum Mode: Equatable {
        case normal
        case insert
        case visual
        case commandLine
    }

    enum Action: Equatable {
        case none
        case commit
        case cancel
    }

    private(set) var characters: [String]
    /// The character under the cursor, or in insert mode, the insertion point.
    private(set) var cursor: Int
    private(set) var mode: Mode = .normal
    private(set) var commandLine = ""
    private var visualAnchor = 0

    // A command being typed, e.g. "2d" waiting for a motion.
    private var count: Int?
    private var operatorKey: String?
    private var operatorCount: Int?
    private var awaiting: String?
    private var typedKeys: [String] = []

    private var lastFind: (key: String, character: String)?
    private var register: [String] = []

    private struct Snapshot {
        var characters: [String]
        var cursor: Int
    }
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []

    /// What `.` repeats: the keys of the last change, and what was typed if
    /// it went on in insert mode.
    private enum Input {
        case key(String)
        case text(String)
        case backspace
        case escape
    }
    private var lastChange: [Input] = []
    private var changeBeingTyped: [Input]?
    private var didChange = false
    private var isRepeating = false

    init(text: String) {
        characters = text.map { String($0) }
        cursor = max(characters.count - 1, 0)
    }

    var text: String {
        characters.joined()
    }

    /// The selected characters in visual mode.
    var visualRange: Range<Int>? {
        guard mode == .visual, !characters.isEmpty else {
            return nil
        }
        return min(visualAnchor, cursor)..<(max(visualAnchor, cursor) + 1)
    }

    /// The command being typed, e.g. "2d" or "f", or the command line.
    var pendingKeys: String {
        if mode == .commandLine {
            return ":" + commandLine
        }
        return typedKeys.joined()
    }

    // MARK: - Keys

    /// Handles a key in normal, visual or command-line mode.
    mutating func handle(key: String) -> Action {
        switch mode {
        case .commandLine:
            return handleCommandLine(key: key)
        case .insert:
            switch key {
            case "<Esc>":
                escape()
            case "<BS>":
                backspace()
            default:
                insert(key)
            }
            return .none
        case .normal, .visual:
            break
        }
        typedKeys.append(key)
        let wasNormal = mode == .normal
        let action = handleCommand(key: key)
        if count == nil && operatorKey == nil && awaiting == nil {
            if didChange && wasNormal && !isRepeating {
                let inputs = typedKeys.map { Input.key($0) }
                if mode == .insert {
                    changeBeingTyped = inputs
                } else {
                    lastChange = inputs
                }
            }
            typedKeys = []
            didChange = false
        }
        return action
    }

    private mutating func resetCommand() {
        count = nil
        operatorKey = nil
        operatorCount = nil
        awaiting = nil
    }

    private mutating func handleCommand(key: String) -> Action {
        if let awaited = awaiting {
            awaiting = nil
            switch awaited {
            case "r":
                replaceCharacters(with: key, count: count ?? 1)
                resetCommand()
            case "g":
                if key == "g" {
                    motion("gg", character: nil)
                } else {
                    resetCommand()
                }
            default:
                // f, F, t, T
                guard key.count == 1 else {
                    resetCommand()
                    return .none
                }
                lastFind = (awaited, key)
                motion(awaited, character: key)
            }
            return .none
        }

        if let digit = Int(key), key.count == 1, digit > 0 || count != nil {
            count = (count ?? 0) * 10 + digit
            return .none
        }

        switch key {
        case "<Esc>":
            if mode == .visual && operatorKey == nil && awaiting == nil {
                mode = .normal
            }
            resetCommand()
        case "h", "l", "<Left>", "<Right>", " ", "w", "b", "e", "W", "B", "E", "0", "^", "$",
            "|", "G", ";", ",":
            motion(key, character: nil)
        case "f", "F", "t", "T", "r", "g":
            awaiting = key
        case "d", "c", "y":
            if mode == .visual {
                applyOperator(key, to: visualRange!)
                resetCommand()
            } else if operatorKey == key {
                // dd, cc, yy: the whole line.
                applyOperator(key, to: 0..<characters.count)
                resetCommand()
            } else {
                operatorKey = key
                operatorCount = count
                count = nil
            }
        case "x" where mode == .visual, "s" where mode == .visual:
            applyOperator(key == "x" ? "d" : "c", to: visualRange!)
            resetCommand()
        case "x":
            operatorKey = "d"
            motion("l", character: nil)
        case "X":
            operatorKey = "d"
            motion("h", character: nil)
        case "s":
            operatorKey = "c"
            motion("l", character: nil)
        case "S":
            applyOperator("c", to: 0..<characters.count)
            resetCommand()
        case "D":
            operatorKey = "d"
            motion("$", character: nil)
        case "C":
            operatorKey = "c"
            motion("$", character: nil)
        case "~":
            toggleCase(count: count ?? 1)
            resetCommand()
        case "i", "a", "I", "A":
            guard mode == .normal, operatorKey == nil else {
                resetCommand()
                return .none
            }
            recordUndo()
            switch key {
            case "a":
                cursor = min(cursor + 1, characters.count)
            case "I":
                cursor = firstNonBlank
            case "A":
                cursor = characters.count
            default:
                break
            }
            startInsert()
            resetCommand()
        case "<BS>":
            // Starts typing, deleting the character before the cursor.
            guard mode == .normal else {
                resetCommand()
                return .none
            }
            recordUndo()
            startInsert()
            deleteBeforeCursor()
            resetCommand()
        case "v":
            if mode == .visual {
                mode = .normal
            } else if !characters.isEmpty {
                mode = .visual
                visualAnchor = cursor
            }
            resetCommand()
        case "o" where mode == .visual:
            swap(&visualAnchor, &cursor)
            resetCommand()
        case "p", "P":
            paste(after: key == "p", count: count ?? 1)
            resetCommand()
        case "u":
            undo()
            resetCommand()
        case "<C-r>":
            redo()
            resetCommand()
        case ".":
            let repeatCount = count
            resetCommand()
            repeatLastChange(count: repeatCount)
        case ":":
            resetCommand()
            mode = .commandLine
            commandLine = ""
        default:
            resetCommand()
        }
        return .none
    }

    private mutating func handleCommandLine(key: String) -> Action {
        switch key {
        case "<Esc>":
            mode = .normal
        case "<BS>":
            if commandLine.isEmpty {
                mode = .normal
            } else {
                commandLine.removeLast()
            }
        case "<CR>":
            mode = .normal
            let command = commandLine.trimmingCharacters(in: .whitespaces)
            commandLine = ""
            switch command {
            case "w", "wq", "x", "w!", "wq!":
                return .commit
            case "q", "q!":
                return .cancel
            default:
                if let line = Int(command) {
                    // Like a line number: goes to that character.
                    cursor = clampedNormal(line - 1)
                }
            }
        default:
            if key.count == 1 {
                commandLine += key
            }
        }
        return .none
    }

    // MARK: - Insert Mode

    private mutating func startInsert() {
        mode = .insert
        didChange = true
    }

    /// Inserts typed text in insert mode.
    mutating func insert(_ text: String) {
        guard mode == .insert, !text.isEmpty else {
            return
        }
        let typed = text.map { String($0) }
        characters.insert(contentsOf: typed, at: cursor)
        cursor += typed.count
        changeBeingTyped?.append(.text(text))
    }

    /// Deletes the character before the cursor in insert mode.
    mutating func backspace() {
        guard mode == .insert else {
            return
        }
        deleteBeforeCursor()
        changeBeingTyped?.append(.backspace)
    }

    private mutating func deleteBeforeCursor() {
        guard cursor > 0 else {
            return
        }
        characters.remove(at: cursor - 1)
        cursor -= 1
    }

    /// Moves the insertion point; what is typed after it is not repeated with
    /// `.`.
    mutating func moveInInsert(by offset: Int) {
        guard mode == .insert else {
            return
        }
        cursor = min(max(cursor + offset, 0), characters.count)
        changeBeingTyped = nil
    }

    /// Ends insert mode.
    mutating func escape() {
        guard mode == .insert else {
            return
        }
        mode = .normal
        cursor = clampedNormal(cursor - 1)
        if var change = changeBeingTyped {
            change.append(.escape)
            lastChange = change
        }
        changeBeingTyped = nil
    }

    // MARK: - Motions

    /// Moves the cursor, or with an operator typed, applies it up to where the
    /// motion goes.
    private mutating func motion(_ key: String, character: String?) {
        let total = (count ?? 1) * (operatorCount ?? 1)
        var motionKey = key
        if operatorKey == "c" && (key == "w" || key == "W"), cursor < characters.count,
            !isBlank(characters[cursor])
        {
            // cw changes to the end of the word, as in Vim.
            motionKey = key == "w" ? "e" : "E"
        }
        guard let (target, inclusive) = self.target(of: motionKey, count: total, character: character)
        else {
            resetCommand()
            return
        }
        if let op = operatorKey {
            let lower = min(cursor, target)
            var upper = max(cursor, target)
            if inclusive {
                upper = min(upper + 1, characters.count)
            }
            if lower < upper {
                applyOperator(op, to: lower..<upper)
            }
        } else {
            cursor = clampedNormal(target)
        }
        resetCommand()
    }

    /// Where a motion goes from the cursor, and whether the character there
    /// is included in an operator's range.
    private func target(of key: String, count: Int, character: String?) -> (Int, Bool)? {
        let last = max(characters.count - 1, 0)
        switch key {
        case "h", "<Left>":
            return (max(cursor - count, 0), false)
        case "l", "<Right>", " ":
            // An operator may reach past the last character.
            return (min(cursor + count, operatorKey != nil ? characters.count : last), false)
        case "0":
            return (0, false)
        case "^":
            return (firstNonBlank, false)
        case "$":
            return (last, true)
        case "|":
            return (min(count - 1, last), false)
        case "G":
            return (self.count.map { min($0 - 1, last) } ?? last, true)
        case "gg":
            return (self.count.map { min($0 - 1, last) } ?? 0, true)
        case "w", "W":
            var position = cursor
            for _ in 0..<count {
                position = nextWordStart(after: position) ?? characters.count
            }
            return (position, false)
        case "e", "E":
            var position = cursor
            for _ in 0..<count {
                guard let end = nextWordEnd(after: position) else {
                    break
                }
                position = end
            }
            return (position, true)
        case "b", "B":
            var position = cursor
            for _ in 0..<count {
                position = previousWordStart(before: position) ?? 0
            }
            return (position, false)
        case "f", "t", "F", "T":
            guard let character = character,
                let found = find(key, character, count: count, from: cursor)
            else {
                return nil
            }
            return (found, key == "f" || key == "t")
        case ";", ",":
            guard let (findKey, character) = lastFind else {
                return nil
            }
            let reversed = ["f": "F", "F": "f", "t": "T", "T": "t"]
            let direction = key == ";" ? findKey : reversed[findKey]!
            guard let found = find(direction, character, count: count, from: cursor, repeating: true)
            else {
                return nil
            }
            return (found, direction == "f" || direction == "t")
        default:
            return nil
        }
    }

    private func find(
        _ key: String, _ character: String, count: Int, from start: Int, repeating: Bool = false
    ) -> Int? {
        let forward = key == "f" || key == "t"
        let before = key == "t" || key == "T"
        var position = start
        for index in 0..<count {
            // Repeating t or T from just before the character would find it
            // again; skip it.
            let skip = before && (repeating || index > 0) ? 1 : 0
            var candidate = forward ? position + 1 + skip : position - 1 - skip
            var found: Int?
            while candidate >= 0 && candidate < characters.count {
                if Self.matches(characters[candidate], character) {
                    found = candidate
                    break
                }
                candidate += forward ? 1 : -1
            }
            guard let match = found else {
                return nil
            }
            position = before ? (forward ? match - 1 : match + 1) : match
        }
        return position
    }

    /// Full-width punctuation as typed with the keyboard, so that f, finds
    /// "，".
    private static let fullWidth: [String: String] = [
        ",": "，", ".": "。", ";": "；", ":": "：", "?": "？", "!": "！", "(": "（",
        ")": "）", "[": "「", "]": "」", "\\": "、",
    ]

    private static func matches(_ character: String, _ typed: String) -> Bool {
        character == typed || fullWidth[typed] == character
    }

    // MARK: - Words

    /// Words as ranges of characters: what NLTokenizer finds, and each other
    /// character that is not blank (e.g. punctuation).
    private var words: [Range<Int>] {
        let string = text
        var covered = [Bool](repeating: false, count: characters.count)
        var result: [Range<Int>] = []
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = string
        tokenizer.enumerateTokens(in: string.startIndex..<string.endIndex) { range, _ in
            let lower = string.distance(from: string.startIndex, to: range.lowerBound)
            let upper = string.distance(from: string.startIndex, to: range.upperBound)
            if lower < upper && upper <= characters.count {
                result.append(lower..<upper)
                for index in lower..<upper {
                    covered[index] = true
                }
            }
            return true
        }
        for (index, character) in characters.enumerated()
        where !covered[index] && !isBlank(character) {
            result.append(index..<(index + 1))
        }
        return result.sorted { $0.lowerBound < $1.lowerBound }
    }

    private func nextWordStart(after position: Int) -> Int? {
        words.first { $0.lowerBound > position }?.lowerBound
    }

    private func nextWordEnd(after position: Int) -> Int? {
        words.first { $0.upperBound - 1 > position }.map { $0.upperBound - 1 }
    }

    private func previousWordStart(before position: Int) -> Int? {
        words.last { $0.lowerBound < position }?.lowerBound
    }

    private func isBlank(_ character: String) -> Bool {
        character.allSatisfy { $0.isWhitespace }
    }

    private var firstNonBlank: Int {
        characters.firstIndex { !isBlank($0) } ?? 0
    }

    private func clampedNormal(_ position: Int) -> Int {
        min(max(position, 0), max(characters.count - 1, 0))
    }

    // MARK: - Changes

    private mutating func applyOperator(_ op: String, to range: Range<Int>) {
        if mode == .visual {
            mode = .normal
        }
        guard !range.isEmpty || op == "c" else {
            return
        }
        if !range.isEmpty {
            register = Array(characters[range])
        }
        switch op {
        case "y":
            cursor = range.lowerBound
        case "c":
            recordUndo()
            characters.removeSubrange(range)
            cursor = range.lowerBound
            startInsert()
        default:
            recordUndo()
            characters.removeSubrange(range)
            cursor = clampedNormal(range.lowerBound)
            didChange = true
        }
    }

    private mutating func replaceCharacters(with character: String, count: Int) {
        if mode == .visual, let range = visualRange {
            recordUndo()
            for index in range {
                characters[index] = character
            }
            mode = .normal
            cursor = range.lowerBound
            didChange = true
            return
        }
        guard character.count == 1, cursor + count <= characters.count else {
            return
        }
        recordUndo()
        for index in cursor..<(cursor + count) {
            characters[index] = character
        }
        cursor += count - 1
        didChange = true
    }

    private mutating func toggleCase(count: Int) {
        let range: Range<Int>
        let wasVisual = visualRange != nil
        if let selected = visualRange {
            range = selected
            mode = .normal
        } else {
            range = cursor..<min(cursor + count, characters.count)
        }
        guard !range.isEmpty else {
            return
        }
        recordUndo()
        for index in range {
            let character = characters[index]
            characters[index] =
                character == character.uppercased() ? character.lowercased() : character.uppercased()
        }
        cursor = clampedNormal(wasVisual ? range.lowerBound : range.upperBound)
        didChange = true
    }

    private mutating func paste(after: Bool, count: Int) {
        guard !register.isEmpty else {
            return
        }
        recordUndo()
        let position = after && !characters.isEmpty ? cursor + 1 : cursor
        let pasted = Array([[String]](repeating: register, count: count).joined())
        characters.insert(contentsOf: pasted, at: position)
        cursor = position + pasted.count - 1
        didChange = true
    }

    /// Replaces characters, e.g. with a candidate chosen, as one change to
    /// undo.
    mutating func replace(_ range: Range<Int>, with text: String) {
        guard range.lowerBound >= 0, range.upperBound <= characters.count else {
            return
        }
        recordUndo()
        let replacement = text.map { String($0) }
        characters.replaceSubrange(range, with: replacement)
        cursor =
            mode == .insert
            ? range.lowerBound + replacement.count
            : clampedNormal(range.lowerBound + replacement.count - 1)
        if mode == .visual {
            mode = .normal
        }
    }

    private mutating func repeatLastChange(count: Int?) {
        guard !lastChange.isEmpty, mode == .normal else {
            return
        }
        var inputs = lastChange
        if let count = count {
            // Replaces the count typed with the change (a leading 0 is a
            // motion, not a count).
            if case .key(let first) = inputs.first, first != "0" {
                while case .key(let key) = inputs.first, Int(key) != nil {
                    inputs.removeFirst()
                }
            }
            inputs.insert(contentsOf: String(count).map { Input.key(String($0)) }, at: 0)
        }
        isRepeating = true
        defer { isRepeating = false }
        for input in inputs {
            switch input {
            case .key(let key):
                _ = handle(key: key)
            case .text(let text):
                insert(text)
            case .backspace:
                backspace()
            case .escape:
                escape()
            }
        }
    }

    // MARK: - Undo

    private mutating func recordUndo() {
        undoStack.append(Snapshot(characters: characters, cursor: cursor))
        redoStack.removeAll()
    }

    mutating func undo() {
        guard let snapshot = undoStack.popLast() else {
            return
        }
        redoStack.append(Snapshot(characters: characters, cursor: cursor))
        characters = snapshot.characters
        cursor = clampedNormal(snapshot.cursor)
        mode = .normal
    }

    mutating func redo() {
        guard let snapshot = redoStack.popLast() else {
            return
        }
        undoStack.append(Snapshot(characters: characters, cursor: cursor))
        characters = snapshot.characters
        cursor = clampedNormal(snapshot.cursor)
        mode = .normal
    }
}
