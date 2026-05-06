import Foundation
import CustomDump
import Dependencies

// MARK: - Public debug API

public extension Model where Self: Sendable {
    // MARK: - debug

    /// Observes this model's entire state tree and prints debug information whenever anything changes.
    ///
    /// The no-closure form observes `self` — all stored properties are tracked as dependencies.
    ///
    /// ```swift
    /// func onActivate() {
    ///     node.debug()                                    // triggers + diff output (default)
    ///     node.debug(.changes(.value))                   // print new value instead of diff
    ///     node.debug(.init(name: "MyModel"))             // custom label
    ///     node.debug(.triggers(.withValue))              // just show which properties changed
    /// }
    /// ```
    ///
    /// To track which specific properties triggered an update in a sub-expression,
    /// use the closure form: `node.debug(.triggers()) { expression }`
    ///
    /// Only active in `DEBUG` builds. Returns a `Cancellable` you can cancel early.
    @discardableResult
    func debug(_ options: DebugOptions = .all) -> Cancellable {
#if DEBUG
        guard let context = enforcedContext() else { return EmptyCancellable() }
        let label = options.name ?? typeDescription
        let printerBox = PrinterBox(options.effectivePrinter)
        let changeFormat = options.changes

        // Snapshot helper: renders the model to a string via customDump, capturing the
        // current live values of all properties including child models. We store rendered
        // strings rather than raw model values because child model structs share the live
        // context reference — comparing them directly would always appear equal.
        // When `.shallow` is active, child models are rendered opaque (just their type name)
        // so that changes deep inside a child don't produce a diff line.
        let isShallow = options.isShallow
        @Sendable func snapshot(_ m: Self) -> String {
            threadLocals.withValue(true, at: \.includeChildrenInMirror) {
                guard isShallow else { return String(customDumping: m) }
                return threadLocals.withValue(0 as Int?, at: \.shallowMirrorDepth) {
                    String(customDumping: m)
                }
            }
        }

        let previous = LockIsolated<String?>(nil)

        // Initialize previous snapshot with the current model value.
        previous.setValue(snapshot(context._modelSeed))

        let cancel = context.onAnyModification { [weak context] source in
            guard !source.isFinished, let context else { return nil }
            // Only react to changes that alter the model struct value.
            // Environment and preference changes are stored outside the struct and
            // never appear in readModel, so they'd produce empty diffs or duplicate value lines.
            guard source.kind.intersects([.properties, .parentRelationship]) else { return nil }
            if let fmt = changeFormat {
                let value = context._modelSeed
                switch fmt {
                case .diff(let style):
                    let prevSnap = previous.value
                    let newSnap = snapshot(value)
                    previous.setValue(newSnap)
                    if let prevSnap, prevSnap != newSnap,
                       let d = snapshotLineDiff(prevSnap, newSnap, style: style) {
                        printerBox.write("\(label) value changed:\n\(d)")
                    }
                case .value:
                    previous.setValue(snapshot(value))
                    let valueDesc = threadLocals.withValue(true, at: \.includeChildrenInMirror) {
                        String(customDumping: value)
                    }
                    printerBox.write("\(label) = \(valueDesc)")
                }
            }
            return nil
        }

        return AnyCancellable(cancellations: context.cancellations, onCancel: cancel)
#else
        return EmptyCancellable()
#endif
    }

    /// Observes specific properties and prints debug information when they change.
    ///
    /// The `access` closure declares which properties to watch — every property read
    /// inside it is tracked as a dependency via `AccessCollector`.
    ///
    /// ```swift
    /// func onActivate() {
    ///     // Print which dependency changed and the new computed value
    ///     node.debug(.all) { (count, filter) }
    ///
    ///     // Watch a memoized result with a custom label
    ///     node.debug(.init(name: "sortedItems")) { sortedItems }
    /// }
    /// ```
    ///
    /// Only active in `DEBUG` builds.
    @discardableResult
    func debug<T: Sendable>(_ options: DebugOptions = .all, _ access: @Sendable @escaping () -> T) -> Cancellable {
#if DEBUG
        guard let context = enforcedContext() else { return EmptyCancellable() }
        let label = options.name ?? typeDescription

        let cancel = debugObserve(
            options: options,
            label: label,
            rootModelID: modelID,
            access: access,
            onUpdate: { _ in }
        ) { wrappedAccess, wrappedOnUpdate in
            let (cancel, _) = update(
                initial: false,
                isSame: nil,
                useWithObservationTracking: false,
                useCoalescing: false
            ) {
                wrappedAccess()
            } onUpdate: { value in wrappedOnUpdate(value) }
            return cancel
        }

        return AnyCancellable(cancellations: context.cancellations, onCancel: cancel)
#else
        return EmptyCancellable()
#endif
    }
}
