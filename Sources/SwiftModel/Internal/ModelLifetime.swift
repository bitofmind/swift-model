enum ModelLifetime: Comparable {
    case initial
    case anchored
    case active
    case destructed
    case frozenCopy
}

extension ModelLifetime {
    var isDestructedOrFrozenCopy: Bool {
        self == .destructed || self == .frozenCopy
    }
}

/// Appended to an "unanchored" report about a model that was in a tree once: it was
/// removed (or is being torn down), so it was most likely reached from work that
/// outlived it. That report usually lands in whichever test runs next, so it says
/// where to look. Empty for a model that was never anchored.
func unanchoredHint(wasEverAnchored: Bool) -> String {
    wasEverAnchored
        ? " (it was already removed: work that outlives a model, such as onTeardown(), must capture what it needs instead of using its node)"
        : ""
}

/// How an issue names a model: its type in backticks. A report can be recorded far
/// from its cause (teardown work and tasks that outlive a model report into
/// whatever test runs next), so the type is often the only lead.
func modelTypeName(_ type: Any.Type) -> String {
    "`\(String(describing: type))`"
}
