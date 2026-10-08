import Foundation

extension Bridges {
    /// Which function a line belongs to. graphify only records where a
    /// function starts, so its end is found here: the brace that closes its
    /// body (JS/TS, skipping strings and comments) or the first line indented
    /// no deeper than its `def` (Python). The innermost span wins, so a call
    /// inside a nested callback belongs to the callback's named owner, and a
    /// line after a function's end no longer counts as inside it.
    struct Spans {
        private var byFile: [String: [(start: Int, end: Int, id: String)]] = [:]

        init(functions: [String: [(line: Int, id: String)]], texts: [String: String]) {
            for (file, fns) in functions {
                guard let text = texts[file] else { continue }
                let lines = text.components(separatedBy: "\n")
                let python = file.hasSuffix(".py")
                var spans: [(Int, Int, String)] = []
                for f in fns {
                    let end = python ? Self.pythonEnd(lines, start: f.line) : Self.braceEnd(lines, start: f.line)
                    spans.append((f.line, max(f.line, end), f.id))
                }
                byFile[file] = spans
            }
        }

        /// Innermost function containing `line`, else nil (top-level code).
        func owner(_ file: String, _ line: Int) -> String? {
            var best: (Int, Int, String)?
            for s in byFile[file] ?? [] where s.start <= line && line <= s.end {
                if best == nil || (s.end - s.start) < (best!.1 - best!.0) { best = s }
            }
            return best?.2
        }

        /// 1-based line of the brace closing the first `{` at or after
        /// `start` (within a few lines: a signature can wrap). No brace (an
        /// expression-bodied arrow) → the start line itself.
        static func braceEnd(_ lines: [String], start: Int) -> Int {
            var depth = 0, opened = false, parens = 0
            // Braces before the body that aren't the body: destructured
            // parameters (inside parens) and object types after `:`.
            var typeBraces = 0
            var lastSig: Character = " "
            var inBlockComment = false
            var quote: Character?
            var i = start - 1
            while i < lines.count {
                if !opened && i > start + 60 { return start }
                var prev: Character = " "
                var lineComment = false
                for ch in lines[i] {
                    if lineComment { break }
                    if inBlockComment {
                        if prev == "*" && ch == "/" { inBlockComment = false; prev = " "; continue }
                        prev = ch
                        continue
                    }
                    if let q = quote {
                        if ch == q && prev != "\\" { quote = nil }
                        prev = (prev == "\\" && ch == "\\") ? " " : ch
                        continue
                    }
                    // `=> expr` (no braces): the body is that expression; it
                    // ends where the code dedents back to the declaration.
                    if !opened && parens == 0 && prev == "=" && ch == ">",
                       let arrow = Self.arrow(in: lines[i]), !Self.braceFollows(lines, line: i, after: arrow) {
                        return Self.indentEnd(lines, start: start)
                    }
                    switch ch {
                    case "\"", "'", "`": quote = ch
                    case "/" where prev == "/": lineComment = true
                    case "*" where prev == "/": inBlockComment = true
                    case "(": parens += 1
                    case ")": parens -= 1
                    case "{" where !opened && (typeBraces > 0 || "(:|&,<=".contains(lastSig)):
                        typeBraces += 1
                    case "}" where !opened && typeBraces > 0:
                        typeBraces -= 1
                    case "{": depth += 1; opened = true
                    case "}":
                        depth -= 1
                        if opened && depth == 0 { return i + 1 }
                    default: break
                    }
                    if !ch.isWhitespace { lastSig = ch }
                    prev = ch
                }
                // A template literal may span lines; plain quotes can't.
                if quote != "`" { quote = nil }
                i += 1
            }
            return opened ? lines.count : start
        }

        /// End of the last `=>` outside parentheses on this line.
        static func arrow(in line: String) -> String.Index? {
            var parens = 0
            var found: String.Index?
            var idx = line.startIndex
            var prev: Character = " "
            while idx < line.endIndex {
                let ch = line[idx]
                if ch == "(" { parens += 1 } else if ch == ")" { parens -= 1 }
                if prev == "=" && ch == ">" && parens <= 0 { found = line.index(after: idx) }
                prev = ch
                idx = line.index(after: idx)
            }
            return found
        }

        /// Is the next non-blank character after `=>` an opening brace?
        static func braceFollows(_ lines: [String], line: Int, after: String.Index) -> Bool {
            var rest = lines[line][after...].drop { $0 == " " || $0 == "\t" }
            var i = line
            while rest.isEmpty && i + 1 < lines.count {
                i += 1
                rest = lines[i].drop { $0 == " " || $0 == "\t" }[...]
            }
            return rest.first == "{"
        }

        /// Until the next non-blank line indented no deeper than `start`
        /// (lines that only close brackets belong to the expression).
        static func indentEnd(_ lines: [String], start: Int) -> Int {
            guard start - 1 < lines.count else { return start }
            let indent = lines[start - 1].prefix { $0 == " " || $0 == "\t" }.count
            var last = start
            var i = start
            while i < lines.count {
                let l = lines[i]
                let trimmed = l.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    let ind = l.prefix { $0 == " " || $0 == "\t" }.count
                    let closer = trimmed.first.map { ")]}".contains($0) } ?? false
                    if ind <= indent && !closer { break }
                    last = i + 1
                }
                i += 1
            }
            return last
        }

        /// Last line of a Python `def` body: until a non-blank line indented
        /// no deeper than the `def` (decorators above it don't matter).
        static func pythonEnd(_ lines: [String], start: Int) -> Int {
            guard start - 1 < lines.count else { return start }
            let indent = lines[start - 1].prefix { $0 == " " || $0 == "\t" }.count
            var last = start
            var i = start
            while i < lines.count {
                let l = lines[i]
                let trimmed = l.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                    let ind = l.prefix { $0 == " " || $0 == "\t" }.count
                    if ind <= indent { break }
                    last = i + 1
                }
                i += 1
            }
            return last
        }
    }
}
