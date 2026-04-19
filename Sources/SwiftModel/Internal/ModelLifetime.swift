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
