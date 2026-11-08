import Foundation

public enum TerminalText {
    public static func clean(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 || $0 == "\n" }))
    }

    public static func wrap(_ text: String, width: Int) -> [String] {
        guard width > 0 else { return [] }
        return clean(text).components(separatedBy: "\n").flatMap { line -> [String] in
            guard !line.isEmpty else { return [""] }
            var remaining = line[...]
            var result: [String] = []
            while !remaining.isEmpty {
                let end = remaining.index(remaining.startIndex, offsetBy: min(width, remaining.count))
                result.append(String(remaining[..<end]))
                remaining = remaining[end...]
            }
            return result
        }
    }

    public static func assistantText(_ text: String) -> String {
        struct Outcome: Decodable { let text: String }
        if let result = try? JSONDecoder().decode(Outcome.self, from: Data(text.utf8)) { return result.text }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") { return "Writing response…" }
        return text
    }
}
