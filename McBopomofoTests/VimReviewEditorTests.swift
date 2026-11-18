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

import XCTest

@testable import McBopomofo

final class VimReviewEditorTests: XCTestCase {
    /// Types keys; "<...>" is one key, other characters one key each.
    @discardableResult
    private func type(_ keys: String, into editor: inout VimReviewEditor) -> VimReviewEditor.Action {
        var action = VimReviewEditor.Action.none
        var remaining = Substring(keys)
        while let first = remaining.first {
            var key = String(first)
            if first == "<", let end = remaining.firstIndex(of: ">") {
                key = String(remaining[...end])
            }
            remaining = remaining.dropFirst(key.count)
            if editor.mode == .insert && !key.hasPrefix("<") {
                editor.insert(key)
            } else {
                action = editor.handle(key: key)
            }
        }
        return action
    }

    func testStartsAtTheEnd() {
        let editor = VimReviewEditor(text: "abc")
        XCTAssertEqual(editor.mode, .normal)
        XCTAssertEqual(editor.cursor, 2)
    }

    func testMovesWithCounts() {
        var editor = VimReviewEditor(text: "abcdefghij")
        type("0", into: &editor)
        XCTAssertEqual(editor.cursor, 0)
        type("3l", into: &editor)
        XCTAssertEqual(editor.cursor, 3)
        type("10l", into: &editor)
        XCTAssertEqual(editor.cursor, 9)
        type("2h", into: &editor)
        XCTAssertEqual(editor.cursor, 7)
        type("4|", into: &editor)
        XCTAssertEqual(editor.cursor, 3)
        type("$", into: &editor)
        XCTAssertEqual(editor.cursor, 9)
    }

    func testDeletesWithCount() {
        var editor = VimReviewEditor(text: "abcdefghij")
        type("0", into: &editor)
        type("3x", into: &editor)
        XCTAssertEqual(editor.text, "defghij")
        type("10x", into: &editor)
        XCTAssertEqual(editor.text, "")
    }

    func testChineseWords() {
        var editor = VimReviewEditor(text: "今天天氣很不錯")
        type("0w", into: &editor)
        XCTAssertEqual(editor.cursor, 2)
        type("e", into: &editor)
        XCTAssertEqual(editor.cursor, 3)
        type("b", into: &editor)
        XCTAssertEqual(editor.cursor, 2)
        type("dw", into: &editor)
        XCTAssertEqual(editor.text, "今天很不錯")
    }

    func testChangeWord() {
        var editor = VimReviewEditor(text: "hello world")
        type("0cwbye<Esc>", into: &editor)
        XCTAssertEqual(editor.text, "bye world")
        XCTAssertEqual(editor.mode, .normal)
        XCTAssertEqual(editor.cursor, 2)
    }

    func testFindAndRepeat() {
        var editor = VimReviewEditor(text: "a,b,c,d")
        type("0f,", into: &editor)
        XCTAssertEqual(editor.cursor, 1)
        type(";", into: &editor)
        XCTAssertEqual(editor.cursor, 3)
        type(",", into: &editor)
        XCTAssertEqual(editor.cursor, 1)
        type("$F,", into: &editor)
        XCTAssertEqual(editor.cursor, 5)
        type("0t,", into: &editor)
        XCTAssertEqual(editor.cursor, 0)
        type(";", into: &editor)
        XCTAssertEqual(editor.cursor, 2)
        type("0dt,", into: &editor)
        XCTAssertEqual(editor.text, ",b,c,d")
    }

    func testFindsFullWidthPunctuation() {
        var editor = VimReviewEditor(text: "你好，今天。")
        type("0f,", into: &editor)
        XCTAssertEqual(editor.cursor, 2)
        type("f.", into: &editor)
        XCTAssertEqual(editor.cursor, 5)
    }

    func testDotRepeatsChanges() {
        var editor = VimReviewEditor(text: "abcdef")
        type("0x..", into: &editor)
        XCTAssertEqual(editor.text, "def")
        editor = VimReviewEditor(text: "a b c")
        type("0rX", into: &editor)
        type("w.w.", into: &editor)
        XCTAssertEqual(editor.text, "X X X")
        editor = VimReviewEditor(text: "abc")
        type("0iZ<Esc>l.", into: &editor)
        XCTAssertEqual(editor.text, "ZZabc")
        editor = VimReviewEditor(text: "abcdefgh")
        type("0x3.", into: &editor)
        XCTAssertEqual(editor.text, "efgh")
    }

    func testBackspaceStartsTyping() {
        var editor = VimReviewEditor(text: "abc")
        type("<BS>", into: &editor)
        XCTAssertEqual(editor.mode, .insert)
        XCTAssertEqual(editor.text, "ac")
        type("x<Esc>", into: &editor)
        XCTAssertEqual(editor.text, "axc")
    }

    func testUndoAndRedo() {
        var editor = VimReviewEditor(text: "abc")
        type("0xx", into: &editor)
        XCTAssertEqual(editor.text, "c")
        type("u", into: &editor)
        XCTAssertEqual(editor.text, "bc")
        type("u", into: &editor)
        XCTAssertEqual(editor.text, "abc")
        type("<C-r>", into: &editor)
        XCTAssertEqual(editor.text, "bc")
        type("Ahello<Esc>u", into: &editor)
        XCTAssertEqual(editor.text, "bc")
    }

    func testVisual() {
        var editor = VimReviewEditor(text: "abcdef")
        type("0lvll", into: &editor)
        XCTAssertEqual(editor.visualRange, 1..<4)
        type("d", into: &editor)
        XCTAssertEqual(editor.text, "aef")
        XCTAssertEqual(editor.mode, .normal)
    }

    func testYankAndPaste() {
        var editor = VimReviewEditor(text: "abc")
        type("0ylp", into: &editor)
        XCTAssertEqual(editor.text, "aabc")
        type("$xP", into: &editor)
        XCTAssertEqual(editor.text, "aacb")
    }

    func testCommandLine() {
        var editor = VimReviewEditor(text: "abc")
        XCTAssertEqual(type(":w<CR>", into: &editor), .commit)
        XCTAssertEqual(type(":q<CR>", into: &editor), .cancel)
        XCTAssertEqual(type(":wq<CR>", into: &editor), .commit)
        type(":2<CR>", into: &editor)
        XCTAssertEqual(editor.cursor, 1)
        type(":abc<Esc>", into: &editor)
        XCTAssertEqual(editor.mode, .normal)
        XCTAssertEqual(type(":x<BS><BS>", into: &editor), .none)
        XCTAssertEqual(editor.mode, .normal)
    }

    func testEscapeDoesNothingInNormalMode() {
        var editor = VimReviewEditor(text: "abc")
        type("2d<Esc>", into: &editor)
        XCTAssertEqual(editor.text, "abc")
        XCTAssertEqual(editor.pendingKeys, "")
        XCTAssertEqual(editor.mode, .normal)
    }

    func testReplaceRangeForCandidate() {
        var editor = VimReviewEditor(text: "今天天器很好")
        editor.replace(2..<4, with: "天氣")
        XCTAssertEqual(editor.text, "今天天氣很好")
        type("u", into: &editor)
        XCTAssertEqual(editor.text, "今天天器很好")
    }
}
