import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// What one `readLine(prompt:)` produced.
enum LineOutcome {
    case text(String)            // a submitted line (may be empty)
    case eof                     // Ctrl-D on empty line, or stdin closed
    case shortcut(LineShortcut)  // a Ctrl chord for the REPL to act on
}

/// Ctrl chords the REPL handles (the editing chords stay inside the editor).
enum LineShortcut { case exit, cycleMode, switchModel, settings }

/// A small UTF-8 / CJK-aware line editor in raw terminal mode — the reason the CLI
/// can finally do whole-character backspace on Chinese, arrow-key navigation, and
/// Ctrl chords (`readLine()` runs in canonical mode, which erases one *byte* at a
/// time and leaks arrow escapes into the buffer). Single-line; falls back to
/// `readLine()` when stdin isn't an interactive TTY (pipes, `selftest`).
final class LineEditor {
    private var history: [String] = []

    func readLine(prompt: String) -> LineOutcome {
        // Non-interactive (pipe / redirect): plain readLine keeps scripts working.
        guard isatty(STDIN_FILENO) == 1 else {
            out(prompt)
            if let line = Swift.readLine() { return .text(line) }
            return .eof
        }
        var orig = termios()
        guard tcgetattr(STDIN_FILENO, &orig) == 0 else {
            out(prompt)
            if let line = Swift.readLine() { return .text(line) }
            return .eof
        }
        var raw = orig
        cfmakeraw(&raw)                         // no echo, no canonical, no ISIG/IXON
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        defer { tcsetattr(STDIN_FILENO, TCSANOW, &orig) }   // always restore cooked mode
        return edit(prompt: prompt)
    }

    // MARK: - Edit loop

    private func edit(prompt: String) -> LineOutcome {
        var buf: [Character] = []
        var cursor = 0                       // index into buf
        var histIndex = history.count        // == count → editing a fresh line
        var stash = ""                       // the fresh line, parked while browsing history

        // In raw mode the terminal's \n→\r\n mapping is off, so a bare LF drops
        // straight down without returning to column 0 — leaving the prompt indented
        // wherever the previous (concurrently-rendered) line left the cursor. Force
        // \r\n so the prompt always lands at column 0.
        out(prompt.replacingOccurrences(of: "\n", with: "\r\n"))
        out("\u{001B}7")                     // DECSC: save cursor right after the prompt
        refresh(buf, cursor)

        while true {
            guard let key = nextKey() else { out("\r\n"); return .eof }
            switch key {
            case .enter:
                out("\r\n")
                let line = String(buf)
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { history.append(line) }
                return .text(line)
            case .ctrlC:
                out("\r\n"); return .shortcut(.exit)
            case .ctrlD:
                if buf.isEmpty { out("\r\n"); return .eof }
                if cursor < buf.count { buf.remove(at: cursor); refresh(buf, cursor) }
            case .cycleMode:   out("\r\n"); return .shortcut(.cycleMode)
            case .switchModel: out("\r\n"); return .shortcut(.switchModel)
            case .settings:    out("\r\n"); return .shortcut(.settings)

            case .char(let c):
                buf.insert(c, at: cursor); cursor += 1; refresh(buf, cursor)
            case .backspace:
                if cursor > 0 { cursor -= 1; buf.remove(at: cursor); refresh(buf, cursor) }
            case .deleteForward:
                if cursor < buf.count { buf.remove(at: cursor); refresh(buf, cursor) }
            case .left:  if cursor > 0 { cursor -= 1; refresh(buf, cursor) }
            case .right: if cursor < buf.count { cursor += 1; refresh(buf, cursor) }
            case .home:  cursor = 0; refresh(buf, cursor)
            case .end:   cursor = buf.count; refresh(buf, cursor)
            case .killToStart:
                if cursor > 0 { buf.removeFirst(cursor); cursor = 0; refresh(buf, cursor) }
            case .killToEnd:
                if cursor < buf.count { buf.removeLast(buf.count - cursor); refresh(buf, cursor) }
            case .killWord:
                var i = cursor
                while i > 0, buf[i - 1] == " " { i -= 1 }
                while i > 0, buf[i - 1] != " " { i -= 1 }
                if i < cursor { buf.removeSubrange(i..<cursor); cursor = i; refresh(buf, cursor) }
            case .up:
                if histIndex > 0 {
                    if histIndex == history.count { stash = String(buf) }
                    histIndex -= 1
                    buf = Array(history[histIndex]); cursor = buf.count; refresh(buf, cursor)
                }
            case .down:
                if histIndex < history.count {
                    histIndex += 1
                    let s = histIndex == history.count ? stash : history[histIndex]
                    buf = Array(s); cursor = buf.count; refresh(buf, cursor)
                }
            case .ignore:
                break
            }
        }
    }

    /// Redraw the buffer in place: back to the saved prompt position, write the
    /// line, clear any leftover, then park the cursor at its logical column.
    private func refresh(_ buf: [Character], _ cursor: Int) {
        out("\u{001B}8")            // DECRC: back to just after the prompt
        out(String(buf))
        out("\u{001B}[0K")          // clear to end of line (handles shrink)
        let trailing = buf[cursor...].reduce(0) { $0 + width($1) }
        if trailing > 0 { out("\u{001B}[\(trailing)D") }
    }

    // MARK: - Key decoding

    private enum Key {
        case char(Character)
        case enter, backspace, deleteForward
        case left, right, up, down, home, end
        case ctrlC, ctrlD, killToStart, killToEnd, killWord
        case cycleMode, switchModel, settings
        case ignore
    }

    private func nextByte() -> UInt8? {
        var b: UInt8 = 0
        return read(STDIN_FILENO, &b, 1) == 1 ? b : nil
    }

    private func nextKey() -> Key? {
        guard let b0 = nextByte() else { return nil }
        switch b0 {
        case 0x0d, 0x0a: return .enter
        case 0x7f, 0x08: return .backspace      // DEL / Ctrl-H
        case 0x03: return .ctrlC                // exit
        case 0x04: return .ctrlD
        case 0x01: return .cycleMode            // Ctrl-A → switch mode
        case 0x0c: return .switchModel          // Ctrl-L → switch model
        case 0x13: return .settings             // Ctrl-S → settings
        case 0x05: return .end                  // Ctrl-E
        case 0x02: return .left                 // Ctrl-B
        case 0x06: return .right                // Ctrl-F
        case 0x15: return .killToStart          // Ctrl-U
        case 0x0b: return .killToEnd            // Ctrl-K
        case 0x17: return .killWord             // Ctrl-W
        case 0x1b: return readEscape()          // ESC [ … / ESC O …
        case 0x00...0x1f: return .ignore        // other control bytes
        default:   return readUTF8(b0)
        }
    }

    /// Parse a CSI/SS3 escape: `ESC [ <params> <final>` or `ESC O <final>`.
    private func readEscape() -> Key {
        guard let intro = nextByte(), intro == 0x5b || intro == 0x4f else { return .ignore }
        var params: [UInt8] = []
        var final: UInt8 = 0
        while let b = nextByte() {
            if b >= 0x40 && b <= 0x7e { final = b; break }   // final byte
            params.append(b)
        }
        switch final {
        case 0x41: return .up
        case 0x42: return .down
        case 0x43: return .right
        case 0x44: return .left
        case 0x48: return .home
        case 0x46: return .end
        case 0x7e:                                            // ESC [ n ~
            switch String(decoding: params, as: UTF8.self) {
            case "1", "7": return .home
            case "4", "8": return .end
            case "3":      return .deleteForward
            default:       return .ignore
            }
        default: return .ignore
        }
    }

    /// Assemble a full UTF-8 scalar from its lead byte so multi-byte (CJK) input
    /// becomes a single `Character` — the key to whole-character editing.
    private func readUTF8(_ lead: UInt8) -> Key {
        // Single-byte ASCII (0xxxxxxx): letters, digits, space, punctuation — the
        // common case. Without this branch every printable ASCII key falls through
        // to `.ignore` and nothing registers (CJK still works: its lead byte ≥ 0xC0).
        if lead & 0x80 == 0 { return .char(Character(UnicodeScalar(lead))) }
        let need: Int
        if lead & 0xE0 == 0xC0 { need = 1 }
        else if lead & 0xF0 == 0xE0 { need = 2 }
        else if lead & 0xF8 == 0xF0 { need = 3 }
        else { return .ignore }
        var bytes = [lead]
        for _ in 0..<need {
            guard let b = nextByte() else { break }
            bytes.append(b)
        }
        let s = String(decoding: bytes, as: UTF8.self)
        guard let c = s.first, c != "\u{FFFD}" else { return .ignore }
        return .char(c)
    }

    /// Terminal display columns for a character: 2 for East-Asian-wide / most
    /// emoji, 1 otherwise. Approximate but enough for in-line cursor math.
    private func width(_ c: Character) -> Int {
        guard let s = c.unicodeScalars.first else { return 1 }
        let v = s.value
        if (0x1100...0x115F).contains(v)        // Hangul Jamo
            || (0x2E80...0x303E).contains(v)    // CJK radicals … punctuation
            || (0x3041...0x33FF).contains(v)    // kana, CJK symbols
            || (0x3400...0x4DBF).contains(v)    // CJK ext A
            || (0x4E00...0x9FFF).contains(v)    // CJK unified
            || (0xA000...0xA4CF).contains(v)    // Yi
            || (0xAC00...0xD7A3).contains(v)    // Hangul syllables
            || (0xF900...0xFAFF).contains(v)    // CJK compatibility
            || (0xFE30...0xFE4F).contains(v)    // CJK compatibility forms
            || (0xFF00...0xFF60).contains(v)    // fullwidth forms
            || (0xFFE0...0xFFE6).contains(v)
            || (0x1F300...0x1FAFF).contains(v)  // emoji & pictographs
            || (0x20000...0x3FFFD).contains(v)  // CJK ext B+
        { return 2 }
        return 1
    }
}
