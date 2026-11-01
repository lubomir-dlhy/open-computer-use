import Foundation

/// Text typed from an environment variable the model only names, never sees.
public enum SecretInput {
    public static let argumentKey = "secret_env"
    public static let allowListKey = "OPEN_COMPUTER_USE_SECRET_ENV"
    static let redaction = "•••"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var usedValues: [String] = []

    /// Names a call may reference. Typing an arbitrary variable into a page could
    /// leak it, so only password-like names are allowed unless listed explicitly.
    public static func isAllowed(_ name: String, environment: [String: String]) -> Bool {
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
            return false
        }
        let listed = (environment[allowListKey] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if listed.contains(name) {
            return true
        }
        let upper = name.uppercased()
        return ["PASSWORD", "PASSCODE", "OTP"].contains(where: upper.contains) || upper.hasSuffix("_PIN") || upper == "PIN"
    }

    /// Reads the variable and remembers its value so every later result redacts it.
    static func resolve(_ name: String, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
        guard isAllowed(name, environment: environment) else {
            throw ComputerUseError.invalidArguments(
                "secret_env \(name) is not allowed: use a name containing PASSWORD, PASSCODE, PIN or OTP, or list it in \(allowListKey)"
            )
        }
        guard let value = environment[name], !value.isEmpty else {
            throw ComputerUseError.invalidArguments("secret_env \(name) is not set in the Open Computer Use process")
        }
        lock.withLock {
            if !usedValues.contains(value) {
                usedValues.append(value)
                usedValues.sort { $0.count > $1.count }
            }
        }
        return value
    }

    static func redact(_ text: String) -> String {
        let values = lock.withLock { usedValues }
        return values.reduce(text) { $0.replacingOccurrences(of: $1, with: redaction) }
    }

    static func redact(_ result: ToolCallResult) -> ToolCallResult {
        guard lock.withLock({ !usedValues.isEmpty }) else {
            return result
        }
        let content = result.content.map { item -> ToolResultContentItem in
            guard item.dictionary["type"] as? String == "text", let text = item.dictionary["text"] as? String else {
                return item
            }
            return .text(redact(text))
        }
        return ToolCallResult(content: content, isError: result.isError)
    }

    /// Every `secret_env` name referenced anywhere in a JSON value, e.g. inside batch steps.
    public static func referencedNames(in value: Any) -> Set<String> {
        switch value {
        case let dictionary as [String: Any]:
            var names = Set(dictionary.values.flatMap { referencedNames(in: $0) })
            if let name = dictionary[argumentKey] as? String {
                names.insert(name)
            }
            return names
        case let array as [Any]:
            return Set(array.flatMap { referencedNames(in: $0) })
        default:
            return []
        }
    }

    static func forgetAll() {
        lock.withLock { usedValues.removeAll() }
    }
}
