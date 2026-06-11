# Performance

Understand what a tracked property read costs, when it matters, and how to make
bulk reads cheap with `withUntrackedModelReads`.

## Overview

Every read of a `@Model` property on an anchored model pays for fine-grained
observation: an `ObservationRegistrar.access` call (so SwiftUI knows what to
invalidate), dependency bookkeeping for any active access (view tracking,
`ModelTester`, `Observed`), a lock-protected state read, and access stamping of
returned child models. This is what makes observation *fine-grained* — but it
means a tracked read costs on the order of a microsecond even in Release builds,
two to three orders of magnitude more than a raw struct field read.

For ordinary UI code this is irrelevant: a view body reads a handful of
properties. It starts to matter when reads scale with data size — an O(N)
traversal over many live models on a hot path:

- hit-testing or snapping against N items on every pointer move,
- validation/repair passes over a whole document,
- building derived values element by element each frame.

At N in the low hundreds, per-read overhead alone can reach milliseconds per
pass — independent of the work the pass actually does.

### The cost is real in Release builds

A large share of the per-read cost is Swift-runtime and framework work that is
compiled with optimizations *regardless of your app's build configuration*:
key-path projection, `ObservationRegistrar` internals, lock primitives, and
unspecialized generic dispatch across the module boundary. Building your app
with `-O` therefore does **not** make tracked reads cheap; it mostly speeds up
your own code around them.

### Measuring: beware the -Onone factor

The inverse caveat applies when profiling: numbers gathered in Debug (`-Onone`)
builds overstate model-read costs and your own value-level compute by roughly
10–30x. CPU-time instrumentation removes machine-load noise but *not* `-Onone`
inflation — cross-check in Release before optimizing based on ratios measured in
Debug.

To measure on your machine, this package ships two benchmark surfaces:

```sh
# Release-mode absolute numbers (read path, scans, activation, writes…):
swift run -c release SwiftModelBenchmarks

# Ratio-asserting micro-benchmarks (Debug, includes @testable-only scenarios):
swift test --filter SwiftModelBenchmarkTests.ReadPathBenchmarks
```

## Bulk reads with withUntrackedModelReads

When a scan doesn't want a dependency on every visited property, wrap it in
``withUntrackedModelReads(_:)``:

```swift
let hit = withUntrackedModelReads {
    timeline.segments.first { $0.timeSpan.contains(playhead) }
}
```

Reads inside the scope skip all observation work — no registrar access, no
dependency registration, no child access stamping — and reduce to a
lock-protected raw state read. Reads stay thread-safe against concurrent
writers; only the observation machinery is bypassed.

The trade-off: nothing inside the scope registers a dependency, so a SwiftUI
body (or `Observed` stream or test expectation) evaluating the scope will not
re-run when the scanned properties change. Callers own their invalidation —
typically by also depending on the scanned state through a tracked read outside
the scope, or by recomputing on an explicit trigger.

Setting up a `node.memoize` or `Observed { }` *inside* an untracked scope is
safe: the framework's own dependency collection clears the scope around its
evaluations, so memoized properties never go silently stale.

### When to reach for it

- **Do** use it for read-only O(N) traversals on hot paths whose results are
  consumed immediately (hit-testing, snapping, measurement passes).
- **Don't** use it inside a view body for the properties that should drive that
  body's invalidation.
- **Prefer extracting plain values** rather than model values out of the scope:
  models returned from untracked reads carry no access stamping, so tracked
  reads on them later fall back to task-local access resolution.

## Other levers

- **Memoize derived values.** `node.memoize` caches a computed value and
  recomputes only when its tracked dependencies change — often the better fix
  when the same scan result is read repeatedly.
- **Batch writes with transactions.** `node.transaction { }` coalesces
  notifications for multiple writes.
- **Snapshot for repeated scans.** If the same pass runs many times between
  mutations, extracting a plain-value snapshot once (inside one untracked scope)
  and scanning the snapshot is cheaper still — a raw value scan pays no locks at
  all.
