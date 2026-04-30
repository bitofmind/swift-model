import Foundation

// MARK: - ModificationKind

/// Describes which kinds of model changes are reported by ``Model/observeModifications(scope:kinds:where:)``.
///
/// Use this as an `OptionSet` to combine kinds:
///
/// ```swift
/// // Only fire for @Tracked property changes — skip environment/preference noise
/// observeModifications(kinds: .properties)
///
/// // Fire for both properties and environment changes
/// observeModifications(kinds: [.properties, .environment])
/// ```
public struct ModificationKind: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Changes to `@Tracked` model properties.
    public static let properties         = ModificationKind(rawValue: 1 << 0)

    /// Changes to context-local environment values (set via `node.environment` or `node.local`).
    public static let environment        = ModificationKind(rawValue: 1 << 1)

    /// Changes to bottom-up preference contributions (set via `node.preference`).
    public static let preferences        = ModificationKind(rawValue: 1 << 2)

    /// Changes to the model's parent relationships (model added to or removed from the hierarchy).
    public static let parentRelationship = ModificationKind(rawValue: 1 << 3)

    /// All modification kinds. This is the default.
    public static let all: ModificationKind = [.properties, .environment, .preferences, .parentRelationship]
}

extension ModificationKind: CustomStringConvertible {
    public var description: String {
        var parts: [String] = []
        if contains(.properties)         { parts.append("properties") }
        if contains(.environment)        { parts.append("environment") }
        if contains(.preferences)        { parts.append("preferences") }
        if contains(.parentRelationship) { parts.append("parentRelationship") }
        switch parts.count {
        case 0: return "none"
        case 1: return ".\(parts[0])"
        default: return "[.\(parts.joined(separator: ", ."))]"
        }
    }
}

// MARK: - OptionSet helpers

extension OptionSet {
    /// Returns `true` if this set and `other` share at least one member.
    func intersects(_ other: Self) -> Bool {
        !intersection(other).isEmpty
    }
}

// MARK: - ModificationScope

/// Describes which levels of the model hierarchy are observed by
/// ``Model/observeModifications(scope:kinds:where:)``.
///
/// `ModificationScope` is an `OptionSet`, so values can be combined:
///
/// ```swift
/// // Default: this model and all descendants
/// observeModifications(scope: [.self, .descendants])
///
/// // Only this model's own property changes (no descendant noise)
/// observeModifications(scope: .self)
///
/// // This model and its direct children, but not grandchildren
/// observeModifications(scope: [.self, .children])
/// ```
///
/// > Note: Unlike ``ModelRelation``, this type does not include `.parent` or `.ancestors` —
/// > those directions are not supported because ``observeModifications()`` only propagates
/// > upward from descendants to ancestors. To observe changes in a parent model, call
/// > `observeModifications()` on the parent directly.
public struct ModificationScope: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// The model itself.
    public static let `self`      = ModificationScope(rawValue: 1 << 0)

    /// The model's direct children only (not grandchildren).
    public static let children    = ModificationScope(rawValue: 1 << 1)

    /// All descendant models (children, grandchildren, …) recursively.
    public static let descendants = ModificationScope(rawValue: 1 << 2)
}
