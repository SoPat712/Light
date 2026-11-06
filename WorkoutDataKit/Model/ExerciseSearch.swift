import Foundation

/// Catalog-independent exercise search. Retain `Prepared` values between keystrokes;
/// only the query and history snapshot need to change.
public enum ExerciseSearch {
    public enum Tier: Int, Comparable, Sendable {
        case exactTitle = 1
        case titleStart
        case contiguousTitle
        case unorderedTitle
        case alias
        case prefix
        case typo

        public static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public struct Prepared<ID: Hashable> {
        public let id: ID
        fileprivate let title: Text
        fileprivate let titles: [Text]
        fileprivate let aliases: [Text]
        fileprivate let alphabeticalTitle: String

        public init(id: ID, title: String, aliases: [String] = [], originalTitle: String? = nil) {
            self.id = id
            let preparedTitle = Text(title)
            self.title = preparedTitle
            // A catalog rename must retain the original name's title tiers,
            // rather than demoting an old exact match to an ordinary alias.
            if let originalTitle = originalTitle, originalTitle != title {
                titles = [preparedTitle, Text(originalTitle)]
            } else {
                titles = [preparedTitle]
            }
            self.aliases = aliases.map(Text.init)
            alphabeticalTitle = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
                .lowercased()
        }
    }

    public struct Query: Sendable {
        fileprivate let text: Text
        public var isEmpty: Bool { text.tokens.isEmpty }

        public init(_ text: String) { self.text = Text(text) }
    }

    public static func tier<ID>(for candidate: Prepared<ID>, matching query: Query) -> Tier? {
        guard !query.isEmpty else { return nil }
        var scratch = Scratch()
        return tier(for: candidate, query: query.text, scratch: &scratch)
    }

    public static func ranked<ID>(
        _ candidates: [Prepared<ID>], matching query: Query, lastPerformedDates: [ID: Date] = [:]
    ) -> [Prepared<ID>] {
        ranked(candidates, prepared: \.self, matching: query, lastPerformedDates: lastPerformedDates)
    }

    /// The key path lets callers filter their own entries without rebuilding searchable text.
    /// Equal tiers sort by recency, title token count, then alphabetical title.
    public static func ranked<Value, ID>(
        _ entries: [Value], prepared: KeyPath<Value, Prepared<ID>>, matching query: Query,
        lastPerformedDates: [ID: Date] = [:]
    ) -> [Value] {
        guard !query.isEmpty else { return entries }
        var scratch = Scratch()
        var matches: [(index: Int, tier: Tier, date: Date?, tokenCount: Int, alphabeticalTitle: String)] = []
        matches.reserveCapacity(entries.count)
        for index in entries.indices {
            let candidate = entries[index][keyPath: prepared]
            if let tier = tier(for: candidate, query: query.text, scratch: &scratch) {
                // A broad prefix can match thousands of entries. Resolve key paths
                // and history once per match, rather than on every sort comparison.
                matches.append((index, tier, lastPerformedDates[candidate.id],
                                candidate.title.tokens.count, candidate.alphabeticalTitle))
            }
        }
        matches.sort { left, right in
            if left.tier != right.tier { return left.tier < right.tier }
            switch (left.date, right.date) {
            case let (a?, b?) where a != b: return a > b
            case (_?, nil): return true
            case (nil, _?): return false
            default: break
            }
            if left.tokenCount != right.tokenCount {
                return left.tokenCount < right.tokenCount
            }
            if left.alphabeticalTitle != right.alphabeticalTitle {
                return left.alphabeticalTitle < right.alphabeticalTitle
            }
            return left.index < right.index
        }
        return matches.map { entries[$0.index] }
    }

    private static let locale = Locale(identifier: "en_US_POSIX")
    private static let abbreviations: [String: [String]] = [
        "db": ["dumbbell"], "bb": ["barbell"], "kb": ["kettlebell"],
        "ohp": ["overhead", "press"], "rdl": ["romanian", "deadlift"]
    ]

    private static func stem(_ word: String) -> String {
        guard word.count > 3, !word.hasSuffix("ss") else { return word }
        switch word {
        case "flyes", "flies": return "fly"
        case "presses": return "press"
        case "lunges": return "lunge"
        case "raises": return "raise"
        default:
            if ["sses", "shes", "ches", "xes", "zes"].contains(where: word.hasSuffix) {
                return String(word.dropLast(2))
            }
            return word.hasSuffix("s") ? String(word.dropLast()) : word
        }
    }

    fileprivate struct Token: Sendable {
        let value: String
        let characters: [Character]
        /// Only ASCII tokens use the byte index; Unicode retains String matching semantics.
        let firstASCIIByte: UInt8?
        init(_ value: String) {
            self.value = value
            characters = Array(value)
            let bytes = value.utf8
            firstASCIIByte = bytes.allSatisfy { $0 < 128 } ? bytes.first : nil
        }
    }

    fileprivate struct Text: Sendable {
        let normalized: String
        let tokens: [Token]
        /// joins[start][length - 1] contains that adjacent span. Precomputed so
        /// split/joined forms and typo checks do not allocate strings while matching.
        let joins: [[Token]]
        /// Unique adjacent spans, indexed once for single-token queries. Their first
        /// starting position preserves title-start versus contiguous-title priority.
        let spans: [Token]
        let spanStarts: [String: Int]
        let spanIndicesByFirstByte: [UInt8: [Int]]
        let nonASCIISpanIndices: [Int]
        let spanIndicesByLength: [Int: [Int]]

        init(_ text: String) {
            let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
                .lowercased()
            let spaced = String(folded.unicodeScalars.map {
                CharacterSet.alphanumerics.contains($0) ? Character(String($0)) : Character(" ")
            })
            let words = spaced.split(whereSeparator: \.isWhitespace).flatMap { word -> [String] in
                let word = String(word)
                return abbreviations[word] ?? [word]
            }.map(stem)
            normalized = words.joined(separator: " ")
            tokens = words.map(Token.init)
            let joins = words.indices.map { start in
                var joined = ""
                return words[start...].map { word in
                    joined += word
                    // Also handles "pull ups" versus "pullups".
                    return Token(stem(joined))
                }
            }
            self.joins = joins
            var spans: [Token] = []
            var starts: [String: Int] = [:]
            var byFirstByte: [UInt8: [Int]] = [:]
            var nonASCII: [Int] = []
            var byLength: [Int: [Int]] = [:]
            for start in joins.indices {
                for span in joins[start] where starts[span.value] == nil {
                    let index = spans.count
                    spans.append(span)
                    starts[span.value] = start
                    if let first = span.firstASCIIByte {
                        byFirstByte[first, default: []].append(index)
                    } else {
                        nonASCII.append(index)
                    }
                    byLength[span.characters.count, default: []].append(index)
                }
            }
            self.spans = spans
            spanStarts = starts
            spanIndicesByFirstByte = byFirstByte
            nonASCIISpanIndices = nonASCII
            spanIndicesByLength = byLength
        }
    }

    private struct Scratch {
        var usedTokens: [Bool] = []
        var distances: [Int] = []
        var lastRow: [Character: Int] = [:]
    }

    private enum MatchKind: Int { case exact, prefix, typo }

    private static func tier<ID>(for candidate: Prepared<ID>, query: Text, scratch: inout Scratch) -> Tier? {
        let titles = candidate.titles
        if titles.contains(where: { $0.normalized == query.normalized }) { return .exactTitle }
        if query.tokens.count == 1 {
            return singleTokenTier(for: candidate, query: query.joins[0][0], scratch: &scratch)
        }
        if titles.contains(where: { ordered(query, in: $0, queryStart: 0, titleStart: 0) }) { return .titleStart }
        for title in titles {
            for start in title.tokens.indices.dropFirst() {
                if ordered(query, in: title, queryStart: 0, titleStart: start) { return .contiguousTitle }
            }
        }
        for title in titles {
            if unordered(query, in: title, allowing: .exact, scratch: &scratch) { return .unorderedTitle }
        }
        for alias in candidate.aliases {
            if unordered(query, in: alias, allowing: .exact, scratch: &scratch) { return .alias }
        }
        for title in titles {
            if unordered(query, in: title, allowing: .prefix, scratch: &scratch) { return .prefix }
        }
        for alias in candidate.aliases {
            if unordered(query, in: alias, allowing: .prefix, scratch: &scratch) { return .prefix }
        }
        for title in titles {
            if unordered(query, in: title, allowing: .typo, scratch: &scratch) { return .typo }
        }
        for alias in candidate.aliases {
            if unordered(query, in: alias, allowing: .typo, scratch: &scratch) { return .typo }
        }
        return nil
    }

    /// One query token can consume any one title span, so no assignment/backtracking
    /// is necessary. An exact title span already covers unordered-title matching.
    private static func singleTokenTier<ID>(
        for candidate: Prepared<ID>, query: Token, scratch: inout Scratch
    ) -> Tier? {
        if candidate.titles.contains(where: { $0.spanStarts[query.value] == 0 }) { return .titleStart }
        if candidate.titles.contains(where: { $0.spanStarts[query.value] != nil }) { return .contiguousTitle }
        if candidate.aliases.contains(where: { $0.spanStarts[query.value] != nil }) { return .alias }
        for title in candidate.titles {
            if hasPrefix(query, in: title) { return .prefix }
        }
        for alias in candidate.aliases {
            if hasPrefix(query, in: alias) { return .prefix }
        }
        // The threshold applies after normalization/abbreviation expansion: e.g.
        // "db" becomes "dumbbell" and still qualifies for typo matching.
        guard query.characters.count >= 4 else { return nil }
        for title in candidate.titles {
            if hasTypo(query, in: title, scratch: &scratch) { return .typo }
        }
        for alias in candidate.aliases {
            if hasTypo(query, in: alias, scratch: &scratch) { return .typo }
        }
        return nil
    }

    private static func hasPrefix(_ query: Token, in text: Text) -> Bool {
        guard let first = query.firstASCIIByte else {
            return text.spans.contains { $0.value.hasPrefix(query.value) }
        }
        for index in text.spanIndicesByFirstByte[first] ?? [] {
            if text.spans[index].value.hasPrefix(query.value) { return true }
        }
        for index in text.nonASCIISpanIndices {
            if text.spans[index].value.hasPrefix(query.value) { return true }
        }
        return false
    }

    private static func hasTypo(_ query: Token, in text: Text, scratch: inout Scratch) -> Bool {
        let count = query.characters.count
        let limit = count >= 8 ? 2 : 1
        for length in (count - limit)...(count + limit) {
            for index in text.spanIndicesByLength[length] ?? [] {
                if withinTypoDistance(query.characters, text.spans[index].characters, limit: limit, scratch: &scratch) {
                    return true
                }
            }
        }
        return false
    }

    /// Exact contiguous matching, consuming adjacent spans on either side. At least one
    /// side must be a single token, as in "pullup" ↔ "pull up", or both spans the same
    /// length, so a short plural still meets its singular: "pull ups" ↔ "pull up".
    private static func ordered(_ query: Text, in title: Text, queryStart: Int, titleStart: Int) -> Bool {
        if queryStart == query.tokens.count { return true }
        guard titleStart < title.tokens.count else { return false }
        if let queryFirst = query.tokens[queryStart].firstASCIIByte,
           let titleFirst = title.tokens[titleStart].firstASCIIByte, queryFirst != titleFirst { return false }
        for (qOffset, q) in query.joins[queryStart].enumerated() {
            for (tOffset, t) in title.joins[titleStart].enumerated() {
                if qOffset > 0 && tOffset > 0 && qOffset != tOffset { continue }
                if q.value == t.value,
                   ordered(query, in: title, queryStart: queryStart + qOffset + 1, titleStart: titleStart + tOffset + 1) {
                    return true
                }
            }
        }
        return false
    }

    private static func unordered(_ query: Text, in title: Text, allowing kind: MatchKind, scratch: inout Scratch) -> Bool {
        guard !title.tokens.isEmpty else { return false }
        // Exact/prefix spans must start with the same byte. Typo matching can
        // change it, and Unicode spans deliberately bypass this prefilter.
        if kind != .typo, let first = query.tokens[0].firstASCIIByte,
           title.spanIndicesByFirstByte[first] == nil, title.nonASCIISpanIndices.isEmpty { return false }
        if scratch.usedTokens.count < title.tokens.count {
            scratch.usedTokens = Array(repeating: false, count: title.tokens.count)
        } else {
            for index in title.tokens.indices { scratch.usedTokens[index] = false }
        }
        return unordered(query, in: title, queryStart: 0, allowing: kind, scratch: &scratch)
    }

    private static func unordered(
        _ query: Text, in title: Text, queryStart: Int, allowing kind: MatchKind, scratch: inout Scratch
    ) -> Bool {
        if queryStart == query.tokens.count { return true }
        for (qOffset, q) in query.joins[queryStart].enumerated() {
            for start in title.tokens.indices where !scratch.usedTokens[start] {
                for (tOffset, t) in title.joins[start].enumerated() {
                    if scratch.usedTokens[start + tOffset] { break }
                    if qOffset > 0 && tOffset > 0 && qOffset != tOffset { continue }
                    guard tokenMatches(q, t, allowing: kind,
                                       isLast: queryStart + qOffset == query.tokens.count - 1, scratch: &scratch) else { continue }
                    for index in start...(start + tOffset) { scratch.usedTokens[index] = true }
                    if unordered(query, in: title, queryStart: queryStart + qOffset + 1, allowing: kind, scratch: &scratch) {
                        return true
                    }
                    for index in start...(start + tOffset) { scratch.usedTokens[index] = false }
                }
            }
        }
        return false
    }

    private static func tokenMatches(_ query: Token, _ title: Token, allowing kind: MatchKind,
                                     isLast: Bool, scratch: inout Scratch) -> Bool {
        if query.value == title.value { return true }
        guard kind != .exact else { return false }
        let canSharePrefix = query.firstASCIIByte == nil || title.firstASCIIByte == nil
            || query.firstASCIIByte == title.firstASCIIByte
        if (isLast || query.characters.count >= 3), canSharePrefix, title.value.hasPrefix(query.value) { return true }
        guard kind == .typo, query.characters.count >= 4 else { return false }
        let limit = query.characters.count >= 8 ? 2 : 1
        guard abs(query.characters.count - title.characters.count) <= limit else { return false }
        return withinTypoDistance(query.characters, title.characters, limit: limit, scratch: &scratch)
    }

    /// Unrestricted Damerau–Levenshtein, including adjacent transpositions. The
    /// matrix and character lookup reuse storage across all candidates in a rank.
    private static func withinTypoDistance(_ lhs: [Character], _ rhs: [Character], limit: Int, scratch: inout Scratch) -> Bool {
        let width = rhs.count + 2
        let size = (lhs.count + 2) * width
        if scratch.distances.count < size {
            scratch.distances.append(contentsOf: repeatElement(0, count: size - scratch.distances.count))
        }
        scratch.lastRow.removeAll(keepingCapacity: true)
        let infinity = lhs.count + rhs.count
        scratch.distances[0] = infinity
        for i in 0...lhs.count {
            scratch.distances[(i + 1) * width] = infinity
            scratch.distances[(i + 1) * width + 1] = i
        }
        for j in 0...rhs.count {
            scratch.distances[j + 1] = infinity
            scratch.distances[width + j + 1] = j
        }
        for i in 1...lhs.count {
            var lastMatch = 0
            for j in 1...rhs.count {
                let previousRow = scratch.lastRow[rhs[j - 1]] ?? 0
                let previousColumn = lastMatch
                let cost = lhs[i - 1] == rhs[j - 1] ? 0 : 1
                if cost == 0 { lastMatch = j }
                let substitution = scratch.distances[i * width + j] + cost
                let insertion = scratch.distances[(i + 1) * width + j] + 1
                let deletion = scratch.distances[i * width + j + 1] + 1
                let transposition = scratch.distances[previousRow * width + previousColumn]
                    + (i - previousRow - 1) + 1 + (j - previousColumn - 1)
                scratch.distances[(i + 1) * width + j + 1] = min(min(substitution, insertion), min(deletion, transposition))
            }
            scratch.lastRow[lhs[i - 1]] = i
        }
        return scratch.distances[(lhs.count + 1) * width + rhs.count + 1] <= limit
    }
}

// Prepared text is immutable; background searches only receive IDs and value
// snapshots, never an ExerciseStore or managed objects.
extension ExerciseSearch.Prepared: Sendable where ID: Sendable {}
