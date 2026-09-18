import Foundation

struct AXContextReader {
    static let maximumContextUnits = 2_000
    static let maximumHarvestTerms = 100
    static let maximumHarvestTokenScalars = 64

    static func context(for target: TargetSnapshot, maximumUnits: Int = maximumContextUnits) -> AppContext {
        guard maximumUnits > 0 else { return AppContext() }
        guard let value = target.value, let range = target.selectedRange else {
            let units = Array((target.selectedText ?? "").utf16)
            let end = min(maximumUnits, units.count)
            var boundedEnd = end
            if boundedEnd > 0, boundedEnd < units.count,
               units[boundedEnd - 1] >= 0xD800, units[boundedEnd - 1] <= 0xDBFF {
                boundedEnd -= 1
            }
            return AppContext(before: "", after: "",
                              selected: String(decoding: units[..<boundedEnd], as: UTF16.self))
        }
        let units = Array(value.utf16)
        let start = max(0, min(range.location, units.count))
        let end = max(start, min(range.location + range.length, units.count))
        let beforeStart = max(0, start - maximumUnits)
        let afterEnd = min(units.count, end + maximumUnits)
        func slice(_ lower: Int, _ upper: Int) -> String {
            var lo = lower, hi = upper
            if lo < hi, units[lo] >= 0xDC00 && units[lo] <= 0xDFFF { lo += 1 }
            if hi > lo, units[hi - 1] >= 0xD800 && units[hi - 1] <= 0xDBFF { hi -= 1 }
            return String(decoding: units[lo..<hi], as: UTF16.self)
        }
        return AppContext(
            before: slice(beforeStart, start),
            after: slice(end, afterEnd),
            selected: slice(start, min(end, start + maximumUnits))
        )
    }

    static func properNouns(in value: String, maximumTerms: Int = maximumHarvestTerms) -> [String] {
        guard maximumTerms > 0 else { return [] }
        let common = Set(["I", "The", "A", "An", "And", "But", "Can", "Could", "Do", "Does", "For", "From", "Hey", "How", "Is", "It", "Let", "Me", "My", "Okay", "Please", "So", "Tell", "That", "This", "To", "We", "What", "When", "Where", "Why", "You"])
        var found: [String] = []
        var seen = Set<String>()
        for token in value.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "-" }) {
            let word = String(token).trimmingCharacters(in: CharacterSet(charactersIn: "'-"))
            guard word.unicodeScalars.count <= maximumHarvestTokenScalars,
                  let first = word.first, first.isUppercase, word.count > 1, !common.contains(word) else { continue }
            let key = word.lowercased()
            guard seen.insert(key).inserted else { continue }
            found.append(word)
            if found.count == maximumTerms { break }
        }
        return found
    }

    static func harvestedTerms(for target: TargetSnapshot) -> [String] {
        guard let value = target.value else { return [] }
        return properNouns(in: value)
    }
}
