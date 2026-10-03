import AppKit
import ApplicationServices

/// A logical editor identity. AX element objects can be discarded during an edit.
/// These values stay in memory and are never included in diagnostics.
struct CorrectionFieldAnchor {
    let window: AXUIElement
    let role: String
    let identifier: String?
    let frame: CGRect?
    var placeholder: String? = nil
    var description: String? = nil
    var windowTitle: String? = nil

    func hasSameContext(as other: CorrectionFieldAnchor) -> Bool {
        CFEqual(window, other.window) && role == other.role
            && placeholder == other.placeholder && description == other.description
            && windowTitle == other.windowTitle
    }

    func matches(_ other: CorrectionFieldAnchor) -> Bool {
        hasSameContext(as: other) && hasSameLocation(as: other)
    }

    func hasSameLocation(as other: CorrectionFieldAnchor) -> Bool {
        guard CFEqual(window, other.window) else { return false }
        let hasIdentifier = identifier?.isEmpty == false
        let otherHasIdentifier = other.identifier?.isEmpty == false
        guard hasIdentifier == otherHasIdentifier,
              !hasIdentifier || identifier == other.identifier else { return false }
        guard let frame, let next = other.frame else { return hasIdentifier }
        guard
              frame.width > 0, frame.height > 0, next.width > 0, next.height > 0,
              [frame.minX, frame.minY, frame.width, frame.height,
               next.minX, next.minY, next.width, next.height].allSatisfy({ $0.isFinite }) else { return false }
        // A growing composer can keep either its top or bottom edge fixed.
        return abs(frame.minX - next.minX) <= 1 && abs(frame.width - next.width) <= 1
            && (abs(frame.minY - next.minY) <= 1 || abs(frame.maxY - next.maxY) <= 1)
    }
}

struct CorrectionFieldObservation {
    let target: TargetSnapshot
    let anchor: CorrectionFieldAnchor?
}

protocol CorrectionFieldReading: AnyObject {
    @MainActor func correctionAnchor(for target: TargetSnapshot) -> CorrectionFieldAnchor?
    @MainActor func correctionReferenceIsRetired(_ target: TargetSnapshot) -> Bool
    /// nil means the original app or its focused readable field is unavailable.
    @MainActor func correctionObservation(in appBundleID: String) -> CorrectionFieldObservation?
}

extension InsertionController: CorrectionFieldReading {
    @MainActor func correctionAnchor(for target: TargetSnapshot) -> CorrectionFieldAnchor? {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == target.bundleID,
              let element = target.element else { return nil }
        return Self.readCorrectionAnchor(element)
    }

    @MainActor func correctionReferenceIsRetired(_ target: TargetSnapshot) -> Bool {
        guard let element = target.element else { return false }
        _ = AXUIElementSetMessagingTimeout(element, 0.25)
        var role: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .invalidUIElement
    }

    @MainActor func correctionObservation(in appBundleID: String) -> CorrectionFieldObservation? {
        guard let observed = correctionSnapshot(in: appBundleID), let element = observed.element else { return nil }
        return CorrectionFieldObservation(target: observed, anchor: Self.readCorrectionAnchor(element))
    }

    private static func readCorrectionAnchor(_ element: AXUIElement) -> CorrectionFieldAnchor? {
        _ = AXUIElementSetMessagingTimeout(element, 0.25)
        func attribute(_ name: CFString, from source: AXUIElement) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(source, name, &value) == .success else { return nil }
            return value
        }
        func axElement(_ value: CFTypeRef?) -> AXUIElement? {
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
        guard let role = attribute(kAXRoleAttribute as CFString, from: element) as? String,
              role == kAXTextAreaRole || role == kAXTextFieldRole else { return nil }
        var window = axElement(attribute(kAXWindowAttribute as CFString, from: element))
        if window == nil {
            var ancestor: AXUIElement? = element
            for _ in 0..<8 {
                guard let current = ancestor else { break }
                _ = AXUIElementSetMessagingTimeout(current, 0.25)
                if attribute(kAXRoleAttribute as CFString, from: current) as? String == kAXWindowRole {
                    window = current
                    break
                }
                ancestor = axElement(attribute(kAXParentAttribute as CFString, from: current))
            }
        }
        guard let window else { return nil }
        let identifier = attribute(kAXIdentifierAttribute as CFString, from: element) as? String
        var frame: CGRect?
        if let position = attribute(kAXPositionAttribute as CFString, from: element),
           let size = attribute(kAXSizeAttribute as CFString, from: element),
           CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() {
            let axPosition = position as! AXValue
            let axSize = size as! AXValue
            var point = CGPoint.zero
            var dimensions = CGSize.zero
            if AXValueGetType(axPosition) == .cgPoint, AXValueGetType(axSize) == .cgSize,
               AXValueGetValue(axPosition, .cgPoint, &point), AXValueGetValue(axSize, .cgSize, &dimensions) {
                frame = CGRect(origin: point, size: dimensions)
            }
        }
        guard identifier?.isEmpty == false || frame != nil else { return nil }
        _ = AXUIElementSetMessagingTimeout(window, 0.25)
        return CorrectionFieldAnchor(window: window, role: role, identifier: identifier, frame: frame,
                                     placeholder: attribute(kAXPlaceholderValueAttribute as CFString, from: element) as? String,
                                     description: attribute(kAXDescriptionAttribute as CFString, from: element) as? String,
                                     windowTitle: attribute(kAXTitleAttribute as CFString, from: window) as? String)
    }
}
