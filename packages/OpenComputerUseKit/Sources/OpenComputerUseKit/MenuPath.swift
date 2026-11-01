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
        // Menus repeat a title for hidden alternates (Finder lists Compress twice).
        return Set(prefixed.map { candidates[$0] }).count == 1 ? prefixed.first : nil
    }

    static func isEnabled(_ item: AXUIElement) -> Bool {
        boolAttribute(item, kAXEnabledAttribute) != false
    }

    /// Controls inside menu items, such as Finder's tag colours (`Add "Red" label`),
    /// matched by a case-insensitive word in their title or description.
    static func pressableDescendant(matching requested: String, in items: [AXUIElement]) -> AXUIElement? {
        let wanted = normalized(requested)
        var found: [AXUIElement] = []
        func visit(_ element: AXUIElement, depth: Int) {
            let label = [stringAttribute(element, kAXTitleAttribute), stringAttribute(element, kAXDescriptionAttribute)]
                .compactMap { $0 }.joined(separator: " ").lowercased()
            var actions: CFArray?
            AXUIElementCopyActionNames(element, &actions)
            let pressable = (actions as? [String])?.contains(kAXPressAction as String) == true
            let words = label.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            if pressable, !wanted.isEmpty, words.contains(wanted) || label == wanted {
                found.append(element)
            }
            guard depth < 4 else { return }
            for child in elements(element, kAXChildrenAttribute) { visit(child, depth: depth + 1) }
        }
        for item in items { for child in elements(item, kAXChildrenAttribute) { visit(child, depth: 0) } }
        return found.count == 1 ? found[0] : nil
    }

    static func resolve(_ path: [String], appElement: AXUIElement, requireEnabled: Bool = true) throws -> AXUIElement {
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
        if requireEnabled, boolAttribute(node, kAXEnabledAttribute) == false {
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
