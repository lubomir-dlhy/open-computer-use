import ApplicationServices
import Foundation

/// Finds a menu bar item by its titles without opening any menu, so it can be
/// pressed while the app stays in the background.
enum MenuPath {
    static func normalized(_ title: String) -> String {
        var text = title.trimmingCharacters(in: .whitespaces).lowercased()
        for suffix in ["…", "..."] where text.hasSuffix(suffix) {
            text = String(text.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    /// Exact title first; otherwise the only title that starts with the request,
    /// e.g. "Compress" for Finder's `Compress "report.pdf"`.
    static func match(_ requested: String, in titles: [String]) -> Int? {
        let wanted = normalized(requested)
        let candidates = titles.map(normalized)
        if let exact = candidates.firstIndex(of: wanted) {
            return exact
        }
        let prefixed = candidates.indices.filter { !wanted.isEmpty && candidates[$0].hasPrefix(wanted) }
        return prefixed.count == 1 ? prefixed[0] : nil
    }

    static func resolve(_ path: [String], appElement: AXUIElement) throws -> AXUIElement {
        guard !path.isEmpty else {
            throw ComputerUseError.invalidArguments("menu_path needs at least one title")
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXMenuBarAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw ComputerUseError.stateUnavailable("The app has no accessible menu bar")
        }
        var node = value as! AXUIElement
        for (depth, title) in path.enumerated() {
            let items = menuItems(under: node, isMenuBar: depth == 0)
            let titles = items.map { stringAttribute($0, kAXTitleAttribute) ?? "" }
            guard let index = match(title, in: titles) else {
                let shown = titles.filter { !$0.isEmpty }.prefix(30).joined(separator: ", ")
                throw ComputerUseError.invalidArguments("menu_path: no unique item \(title.debugDescription) here. Items: \(shown)")
            }
            node = items[index]
        }
        if boolAttribute(node, kAXEnabledAttribute) == false {
            throw ComputerUseError.message("menu item \(path.joined(separator: " > ")) is disabled")
        }
        return node
    }

    private static func menuItems(under node: AXUIElement, isMenuBar: Bool) -> [AXUIElement] {
        let children = elements(node, kAXChildrenAttribute)
        if isMenuBar {
            return children
        }
        return children
            .filter { stringAttribute($0, kAXRoleAttribute) == kAXMenuRole as String }
            .flatMap { elements($0, kAXChildrenAttribute) }
    }

    private static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }
}
