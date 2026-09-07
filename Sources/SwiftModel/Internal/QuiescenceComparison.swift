import Foundation

// MARK: - Dual-run instrumentation for semantic quiescence
//
// Step 2 of `Docs/test-quiescence-redesign.md` §10: compute the SEMANTIC
// quiescence answer (`AnyContext.semanticQuiescence`) alongside the existing
// scheduler-observing answer on every check inside `_driveToStableFixpoint`,
// and record every disagreement. **The existing answer still decides every
// verdict** — nothing here feeds back into a wait. The point is to build the
// disagreement inventory over a whole suite run before anything depends on the
// new rule.
//
// Enable the per-disagreement log with `SWIFT_MODEL_QUIESCENCE_TRACE=1`; it is
// written to /tmp/swift-model-quiescence-trace.log (same pattern as the GTS
// trace), with a summary appended at process exit. The in-memory tally is
// always maintained — it is two integers behind a lock, only touched on a
// drive check, and it is what the unit tests assert against.

/// One disagreement direction.
enum _QuiescenceDisagreement: String, Sendable {
    /// Existing (executor/queue) answer said quiescent; semantic said work is
    /// still running. The interesting direction: the old answer would let a
    /// wait conclude while a registered unit is still running.
    case oldQuiescentNewNot
    /// Semantic answer said quiescent; existing answer said busy. Usually
    /// executor/queue churn that owns no registered work unit.
    case newQuiescentOldNot
}

struct _QuiescenceTally: Sendable, Equatable {
    var checks = 0
    var agreements = 0
    var oldQuiescentNewNot = 0
    var newQuiescentOldNot = 0
}

enum _QuiescenceComparison {
    /// The name of the test whose scope we are in, set by `ModelTestingTrait`.
    @TaskLocal static var testTag: String?

    static let isTracing: Bool = ProcessInfo.processInfo.environment["SWIFT_MODEL_QUIESCENCE_TRACE"] == "1"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _tally = _QuiescenceTally()
    /// Per-test disagreement counts, for the exit summary.
    nonisolated(unsafe) private static var _byTest: [String: (old: Int, new: Int, checks: Int)] = [:]

    static var tally: _QuiescenceTally { lock.withLock { _tally } }

    static func resetTally() {
        lock.withLock {
            _tally = _QuiescenceTally()
            _byTest = [:]
        }
    }

    /// Records one check. `runningUnits` and `existingBusyReason` are only
    /// evaluated when a disagreement is being traced.
    static func record(
        existingIsQuiescent: Bool,
        semanticIsQuiescent: Bool,
        runningUnits: @autoclosure () -> [(modelName: String, name: String, fileAndLine: FileAndLine)],
        existingBusyReason: @autoclosure () -> String = ""
    ) {
        let tag = testTag ?? "<no test>"
        let disagreement: _QuiescenceDisagreement?
        switch (existingIsQuiescent, semanticIsQuiescent) {
        case (true, false): disagreement = .oldQuiescentNewNot
        case (false, true): disagreement = .newQuiescentOldNot
        default: disagreement = nil
        }

        lock.withLock {
            _tally.checks += 1
            var entry = _byTest[tag] ?? (old: 0, new: 0, checks: 0)
            entry.checks += 1
            switch disagreement {
            case .none: _tally.agreements += 1
            case .oldQuiescentNewNot: _tally.oldQuiescentNewNot += 1; entry.old += 1
            case .newQuiescentOldNot: _tally.newQuiescentOldNot += 1; entry.new += 1
            }
            _byTest[tag] = entry
        }

        guard isTracing, let disagreement else { return }
        var line = "test=\"\(tag)\" \(disagreement.rawValue) existing=\(existingIsQuiescent ? "quiescent" : "busy") semantic=\(semanticIsQuiescent ? "quiescent" : "busy")"
        switch disagreement {
        case .oldQuiescentNewNot:
            let units = runningUnits()
            if units.isEmpty {
                line += " running=[queue]"   // no registered unit; a call queue was busy
            } else {
                // Cap the list: a wide hierarchy can have dozens of identical
                // units and the interesting information is the call site.
                let described = units.map { unit -> String in
                    let site = unit.fileAndLine.description
                    // `taskName` defaults to "function @ file:line" — don't repeat the site.
                    return unit.name.hasSuffix(site) ? "\(unit.modelName).\(unit.name)" : "\(unit.modelName).\(unit.name) @ \(site)"
                }
                var shown = Array(Set(described)).sorted().prefix(5).joined(separator: ", ")
                if units.count > 5 { shown += ", +\(units.count - 5) more" }
                line += " running=[\(shown)] count=\(units.count)"
            }
        case .newQuiescentOldNot:
            line += " existingBusy=[\(existingBusyReason())]"
        }
        _quiescenceTrace(line)
    }

    static func summaryLines() -> [String] {
        let (tally, byTest) = lock.withLock { (_tally, _byTest) }
        var lines: [String] = []
        lines.append("=== SEMANTIC QUIESCENCE DISAGREEMENT SUMMARY ===")
        lines.append("checks=\(tally.checks) agree=\(tally.agreements) oldQuiescentNewNot=\(tally.oldQuiescentNewNot) newQuiescentOldNot=\(tally.newQuiescentOldNot)")
        let interesting = byTest.filter { $0.value.old > 0 || $0.value.new > 0 }
            .sorted { ($0.value.old + $0.value.new) > ($1.value.old + $1.value.new) }
        for (test, counts) in interesting {
            lines.append("  \(test): checks=\(counts.checks) oldQuiescentNewNot=\(counts.old) newQuiescentOldNot=\(counts.new)")
        }
        return lines
    }
}

// MARK: - Trace file

private let _quiescenceTraceFile: FileHandle? = {
    guard _QuiescenceComparison.isTracing else { return nil }
    let path = "/tmp/swift-model-quiescence-trace.log"
    try? FileManager.default.removeItem(atPath: path)
    _ = FileManager.default.createFile(atPath: path, contents: nil)
    let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path))
    // The exit summary is a convenience over the per-check lines (which carry
    // the same information). `atexit` is not part of the WASI surface this
    // library is compile-checked against, and the trace is a macOS/Linux
    // developer tool, so it is simply skipped there.
    #if !os(WASI)
    atexit(_quiescenceDumpSummaryAtExit)
    #endif
    return handle
}()

private let _quiescenceTraceLock = NSLock()

func _quiescenceTrace(_ msg: @autoclosure () -> String) {
    guard _QuiescenceComparison.isTracing, let fh = _quiescenceTraceFile else { return }
    let line = msg() + "\n"
    _quiescenceTraceLock.withLock {
        try? fh.write(contentsOf: Data(line.utf8))
    }
}

/// `atexit` handler — must capture nothing (`@convention(c)`).
#if !os(WASI)
private func _quiescenceDumpSummaryAtExit() {
    guard let fh = _quiescenceTraceFile else { return }
    let text = _QuiescenceComparison.summaryLines().joined(separator: "\n") + "\n"
    _quiescenceTraceLock.withLock {
        try? fh.write(contentsOf: Data(text.utf8))
    }
}
#endif
