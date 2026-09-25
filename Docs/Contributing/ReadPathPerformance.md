# Read-path performance

Contributor notes. Read before touching model property accessors, `Context` read/write paths, observation registration or `withUntrackedModelReads`.

A tracked `@Model` property read on an anchored model costs ~0.5–1 μs even in
Release — registrar access, observer-KP resolution, context lock, key-path
projection, all across non-inlined module boundaries. This is the scaling
constant for any O(N) traversal in client apps. Key facts:

- **`withUntrackedModelReads { }`** (public) skips all observation work for
  reads inside the scope but keeps the context lock (memory-safe vs concurrent
  writers). `threadLocals.untrackedReads` is the flag; the gates live in the
  `_ModelSourceBox` read subscripts, `willAccessSyntheticPath`, and
  `ModelContext.willAccess`. `update()` in `ObservationTracking.swift` clears
  the flag around `access()` so memoize/`Observed` dependency collection never
  inherits a caller's untracked scope. Don't add new read paths without
  considering this flag.
- **Index-keyed hot paths.** The macro-generated accessors pass the property's
  tracked *index* (an `Int` literal, `_State._trackedPropertyKeyPaths[index]` is its
  key path) plus `get`/`set` projection closures to the `_ModelSourceBox` read/write
  subscripts; the key path itself is an `@autoclosure` that only key-path-keyed
  consumers evaluate (`TestAccess`, undo, the gap shadow, the pre-anchor construction
  frame). `Context` keys its per-context tables by that index — the registrar identity
  tokens (`_observerTokens`, guarded by the `Reference` lock, created on first use; a
  tracked read fetches its token in the same `Reference`-lock window that loads the
  context and **registers with the registrar BEFORE the locked value read** — see the
  invariant at `Context.trackedRead`; it bounds the inherent `withObservationTracking`
  install-after-body window, it cannot close it, so there is no unit test for it), the
  `onModify` callbacks on tracked properties (`propertyModifyCallbacks`) and the
  `observeModifications` exclusions — and maps key path ↔ index once at registration
  (`trackedIndex(of:)` / `trackedPath(_:)`, a per-context cache of the computed static).
  Synthetic paths (environment, preferences, memoize sentinels, parents) stay
  key-path keyed in `modifyCallbacks`. Tuple (parameter-pack) properties keep the
  key-path form of the write (Swift 6.3 SILGen cannot lower the closure form for a pack)
  but pass the index through. Don't reintroduce a process-global cache keyed by
  key-path object: eight cores retaining one object is the 8-thread cliff this removed.
- **Benchmarks**: `swift run -c release SwiftModelBenchmarks` (sections 2/2b/2c/2d;
  run the binary with `DYLD_FRAMEWORK_PATH=$(xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks`
  if launching directly) and `swift test --filter SwiftModelBenchmarkTests.ReadPathBenchmarks`
  (ratio assertions). Profile in Release: Debug (`-Onone`) numbers overstate
  read + value-compute costs ~10–30x.
