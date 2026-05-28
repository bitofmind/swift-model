#if canImport(SwiftUI)
import SwiftUI

// MARK: - `\.swiftModelDebugActive` environment value
//
// On iOS 17+ `@ObservedModel.update()` normally skips installing `ViewAccess`
// when SwiftUI's `ObservationRegistrar` is driving invalidation — that's a
// performance win but breaks debug *attribution*: reads from a descendant
// view (e.g. inside a nested `@ObservedModel`) can be observed by an
// ancestor's `ViewAccess` via the value's stamped-access propagation chain,
// so a `$model.debug(...)` attached on the ancestor fires for reads that
// actually came from the descendant.
//
// When this environment value is `true`, `@ObservedModel.update()` (and
// `ModelScope.body`) install `ViewAccess` unconditionally on the descendant
// side too. The descendant's own `ViewAccess` re-stamps the model, so the
// registrar registers the descendant's reads on the descendant's access —
// the ancestor's debug observer never sees them.
//
// Default: `false`. Active only in `DEBUG` (the property wrapper conditional
// reads it only in DEBUG paths).

struct SwiftModelDebugActiveKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

public extension EnvironmentValues {
    /// When `true`, `@ObservedModel` and `ModelScope` install `ViewAccess`
    /// even on iOS 17+ where they would normally let the
    /// `ObservationRegistrar` drive invalidation alone. Set by
    /// ``SwiftUI/View/swiftModelDebugScope()`` and `ModelScope(debug:)`.
    var swiftModelDebugActive: Bool {
        get { self[SwiftModelDebugActiveKey.self] }
        set { self[SwiftModelDebugActiveKey.self] = newValue }
    }
}

public extension View {
    /// Marks this subtree as having debug observation active. Every
    /// descendant `@ObservedModel` and `ModelScope` will install its own
    /// `ViewAccess` on iOS 17+ (instead of letting the `ObservationRegistrar`
    /// drive invalidation alone). The descendant's own access re-stamps the
    /// model so reads register on the right view, restoring debug-attribution
    /// scoping that matches the iOS 16 path.
    ///
    /// Apply once at or above any view that calls `$model.debug(...)`. For
    /// app-wide coverage during a debug session, apply at the root.
    ///
    /// ```swift
    /// EditorView()
    ///     .swiftModelDebugScope()
    /// ```
    ///
    /// In release builds the modifier is a no-op (it sets a SwiftUI env value
    /// that nothing in release-mode reads).
    func swiftModelDebugScope() -> some View {
        environment(\.swiftModelDebugActive, true)
    }
}
#endif
