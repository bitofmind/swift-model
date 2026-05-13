[← Back to README](../README.md)

## Debugging State Changes

SwiftModel keeps track of all model state changes and can print diffs, trigger lists, and value snapshots to help you understand what's happening at runtime.

Enable debug output for the lifetime of a model by adding a modifier before anchoring:

```swift
AppModel().withDebug().withAnchor()   // triggers (name format) + changes (diff) — the default
```

Pass a `DebugOptions` value to configure exactly what gets printed. Use the static factory methods for common cases:

```swift
// Print only a diff of the whole model tree (no trigger lines)
AppModel().withDebug(.changes()).withAnchor()

// Print only which properties triggered updates (no diff)
AppModel().withDebug(.triggers()).withAnchor()

// Use a custom label and output stream (triggers + changes still on by default)
AppModel().withDebug(.init(name: "App", printer: myStream)).withAnchor()
```

The trigger format can be `.name` (default), `.withValue(maxLines:maxDepth:)` (old → new), or `.withDiff(_:)` (structured diff — useful when the trigger value is itself a model):

```swift
// Triggers show "AppModel.filter: \"a\" → \"b\""; changes diff also printed
AppModel().withDebug(.init(triggers: .withValue)).withAnchor()

// Triggers-only with full structured diff of each changed dependency
AppModel().withDebug(.triggers(.withDiff)).withAnchor()
```

`.withValue` and `.value` accept `(maxLines: Int = 20, maxDepth: Int = 4)` to bound otherwise-unbounded `customDump` output. The defaults — 20 lines, depth 4 — keep production logs readable when the property happens to be a large value type (e.g. a 50-segment `Timeline` struct that would otherwise emit hundreds of lines per trigger). Pass `Int.max` to either field to opt out of that knob. `maxDepth` is forwarded to `customDump`'s own depth bound — that's the only knob that actually saves CPU on deeply-nested types; line truncation is post-walk and purely cosmetic. For huge values, prefer `.withDiff(.compact)` (structurally trims to the changed region) over widening `maxLines` on `.withValue`.

```swift
// Cap each side of the old → new line at 50 rendered lines.
AppModel().withDebug(.triggers(.withValue(maxLines: 50))).withAnchor()

// Bound the customDump walk at depth 3 (cheaper than maxLines for deep types).
AppModel().withDebug(.triggers(.withValue(maxLines: .max, maxDepth: 3))).withAnchor()
```

Diffs default to `.compact` style (only the changed lines and their structural ancestors). Pass a `DiffStyle` to change this:

```swift
// Show every unchanged sibling as "… (N unchanged)"
model.node.debug(.changes(.diff(.collapsed)))

// Show the full before/after context
model.node.debug(.changes(.diff(.full)))
```

To debug a specific expression or enable debug output only temporarily on a live model, use `debug()` on the model directly — it returns a `Cancellable` you can cancel when done:

```swift
// Watch only a specific sub-expression (triggers + changes)
model.node.debug() { model.filter }

// Enable temporarily
let cancel = model.node.debug()
// ... do work ...
cancel.cancel()
```

For `memoize`, `Observed`, and `observeModifications()`, the `debug:` parameter is `DebugOptions?` — omit it (or pass `nil`) to disable debug output, or pass a `DebugOptions` value to enable it:

```swift
// Print the new value (no diff) whenever a memoized result changes
node.memoize(debug: .init(changes: .value)) { items.sorted() }

// Print which dependency triggered an Observed update (old → new value)
node.forEach(Observed(debug: .triggers(.withValue)) { model.count }) { value in ... }

// Print a line for each observeModifications() emission, showing the trigger source
node.forEach(observeModifications(debug: .triggers())) { _ in autosave() }
```

> Debug output is only active in `DEBUG` builds.

**Targeted debug in practice** — the [TodoList](../Examples/TodoList) example uses `Observed(debug:)` inside `onActivate()` to trace only `items.count` and `completedCount`, avoiding noise from unrelated property changes (e.g., `newItemTitle` keystrokes). The same example also ships a commented-out `@ObservedModel(debug:)` on `TodoItemRow` showing the view-side equivalent — uncomment it to log which property of each row invalidated that row's body. The [Search](../Examples/Search) example demonstrates `withDebug()` at the app level alongside `cancelPrevious: true` on `forEach` to show cancel-in-flight behaviour. `observeModifications(debug: .triggers())` is useful for diagnosing unexpected autosave or dirty-tracking triggers.

## Debugging View Re-renders with `$model.debug(…)`

When a SwiftUI view re-renders unexpectedly, the question is usually "which property of the observed model caused this?". Call `$model.debug(_:)` from inside `body` to log exactly that — one line per property mutation that invalidates the view, naming the model and key path that fired:

```swift
struct EditorMidBar: View {
    @ObservedModel var editor: EditorModel

    var body: some View {
        $editor.debug()
        return HStack { /* … */ }
    }
}
```

Each time SwiftUI's invalidation chain fires for this view, you'll see:

```
EditorModel at EditorMidBar.swift:42 ← EditorModel.layerMode
EditorModel at EditorMidBar.swift:42 ← EditorModel.selectedTrackID
```

The default label combines the wrapped model's type name with the call-site `#fileID:#line`. Pass a `DebugOptions` value to override:

```swift
// Custom view-side label (preferred — easier to spot in logs):
$editor.debug(.init(name: "EditorMidBar"))

// With old → new rendered via customDump:
$editor.debug(.triggers(.withValue))

// With a structural −/+ diff per trigger — useful when the property is itself a model:
$editor.debug(.triggers(.withDiff))

// Route to Instruments signposts (see "Routing Output to Signposts" below):
$editor.debug(.init(name: "EditorMidBar", printer: signposts))
```

`triggers`, `name`, `printer`, `accessObserver`, and `captureAccessStack` from `DebugOptions` are honoured; `changes` is ignored — model-tree diffs are already covered by `node.debug(.changes)` on the model itself.

Trigger lines propagate through child models — if your view reads `editor.canvas.scale`, the log line names `CanvasModel.scale`, not `EditorModel`. The label on the left of the arrow is the view-side label so multiple views observing the same model are distinguishable.

### Lifetime and placement

`$model.debug(…)` attaches debug emission for the current body window. The per-render debug state is cleared at the start of each render — body re-attaches via the same line. Removing the line (or commenting it out) disables further emission on the next render with no stale state hanging around. There is no "set once at init" form; this matches the natural lifetime of a SwiftUI view body and avoids the `init` boilerplate that an init-side parameter would require for models without default values.

Ordering within `body` doesn't matter. `$model.debug(…)` can be the first line in `body`, between reads, or at the end — the framework captures the pre-mutation snapshot eagerly during the body's reads so a later `attach` still produces correct `old → new` lines on the first subsequent mutation.

**Sticky-lazy install on iOS 17+** — on the `ObservationRegistrar` path (iOS 17 / macOS 14 and later), SwiftUI's `withObservationTracking` already handles view invalidation, so `@ObservedModel` skips installing its own `ViewAccess` until you actually need debug emission. The first time `$model.debug(…)` runs in a body, a sticky flag is set on the underlying `@StateObject` and a priming render is scheduled — from then on the access is installed every render for the `@StateObject`'s lifetime, even if you later remove the `$model.debug(…)` line. Rebuilding the view (Cmd-R) resets the flag. In practice this means: zero cost when debug is not in use, one extra "priming" render on first activation, then normal emission. On the iOS 16 / macOS 13 `AccessCollector` path the access is always installed and the sticky flag is irrelevant.

> Like the rest of the debug API, `$model.debug(…)`'s body is gated on `#if DEBUG` — in release builds the call compiles to nothing, so it's safe to leave in place when shipping (no `#if DEBUG` wrapping required at the call site). In release the wrapper preserves its zero-cost early-return on the registrar path; the entire `attachDebug` call site is empty.

## Scoping Debug to a Sub-View with `ModelScope(debug:)`

`ModelScope` already exists as a way to confine SwiftUI observation to a sub-expression (so only the scope's contents re-render, not the surrounding view). The `debug:` initialiser variant additionally attaches a `DebugOptions` value for the scope's lifetime — any property reads inside the `content` closure that later invalidate this scope are logged under the scope's label:

```swift
struct EditorView: View {
    @ObservedModel var editor: EditorModel

    var body: some View {
        VStack {
            EditorTopBar(editor: editor)

            ModelScope(debug: .init(name: "EditorView.toolbar")) {
                EditorMidBar(editor: editor)
            }

            EditorBottomBar(editor: editor)
        }
    }
}
```

Now mutations that re-render *just* the mid-bar produce trigger lines tagged `"EditorView.toolbar ← …"`, while reads happening elsewhere in `body` still log under `EditorView`'s `$editor.debug(...)` label (if any). This is a natural way to split a noisy view's observation surface into smaller, independently-debuggable regions without restructuring the rest of the tree.

The default label is `"ModelScope at file:line"` (call-site `#fileID:#line`); pass `.init(name:)` to override. Compiled out in release: the `debug` parameter is `nil` by default and the install path is `#if DEBUG`-gated, so `ModelScope { … }` (no-debug) and `ModelScope(debug: nil) { … }` are identical at runtime.

## Locating the Reader with `captureAccessStack`

The trigger / change formats describe *which property was mutated*. The natural follow-up is: *which view body or expression caused the dependency to be registered in the first place?* That's what `captureAccessStack:` on `DebugOptions` is for. Pass a frame count and the framework captures the body's call stack at access time, then symbolicates and appends it onto the trigger line *only when that path actually fires*:

```swift
var body: some View {
    $editor.debug(.init(triggers: .name, captureAccessStack: 15))
    return content
}
```

Now a render that invalidates `EditorModel.layerMode` produces:

```
EditorView at EditorMidBar.swift:42 ← EditorModel.layerMode
  read from:
    0  MyApp …EditorView.body + …
    1  SwiftUICore …ViewModifier.body + …
    2  …
```

The leading SwiftModel-internal frames (`ViewAccess.willAccess`, `Context._modelSeed`, the `@dynamicMember` subscript, etc.) are trimmed so the first visible frame is the user-code line that performed the read. Deeper SwiftModel frames are preserved when they're sandwiched between user code — e.g. when `body` reads a memoized property and the produce closure inside it makes the underlying read, both user frames and the SwiftModel-internal memoize frame between them are kept.

…and reads that never trigger stay silent. For a complex view that touches dozens of properties on first render, this drops the on-screen noise to *N* stacks where *N* is the number of properties that actually re-rendered the view — usually a handful, often just one.

Composes with any `TriggerFormat` — the stack suffix appends to whatever the trigger line says:

```swift
// `.withValue` + stack — full forensic record per real re-render:
$editor.debug(.init(triggers: .withValue, captureAccessStack: 20))

// `.withDiff` + stack — same, for a model-typed dependency:
$editor.debug(.init(triggers: .withDiff, captureAccessStack: 20))

// Scope it to a sub-view to narrow the hunt:
ModelScope(debug: .init(name: "EditorView.toolbar", captureAccessStack: 15)) {
    EditorMidBar(editor: editor)
}
```

Costs in DEBUG only: at access time, one `Thread.callStackReturnAddresses` call (tens of µs for a typical 15-frame depth) plus per-path storage of the raw addresses. At trigger time, one `backtrace_symbols` call per fired path. Free when `captureAccessStack` is `nil`. No effect outside `DEBUG` builds.

> Honoured by every debug entry point that has a `willAccess` hook to capture from: `$model.debug(_:)` (`@ObservedModel`), `ModelScope(debug:)`, `Observed(debug:)`, `memoize(debug:)`, and `node.debug(_:_:)` (the closure form). Ignored on `node.debug(_:)` (no-closure form) and `observeModifications(debug:)`, which observe mutations rather than reads. For memoize and Observed the stack typically points inside the `produce` / observe closure — useful when a closure delegates to helper functions and you want to know which helper read the property that fired.

### `accessObserver` — the lower-level alternative

For cases that don't map to "stitch onto a trigger line" — custom telemetry on access patterns, LLDB breakpoint trapping at the moment of read, recording the full access set of a view independent of which properties later fire — `DebugOptions` also exposes `accessObserver: (any AccessObserver)?`. The framework fires `observeAccess(modelType:path:)` on every read outside its internal locks; the observer decides what to do.

```swift
// Drop into LLDB at the first read of any property — `bt` to see the live reader:
$editor.debug(.init(name: "EditorView",
                    accessObserver: .firstAccessBreakpoint()))

// Custom action — record-only, no symbolication cost:
$editor.debug(.init(name: "EditorView",
                    accessObserver: .firstAccess { type, path in
    if path == "value" && type.contains("ReadCache") {
        print("[REDRAW] \(type).\(path)")
    }
}))
```

`FirstAccessObserver` deduplicates by `(modelType, path)` and fires its action up to `limit` times per key (default `1`). Supported on `$model.debug(_:)`, `ModelScope(debug:)`, `Observed(debug:)`, `memoize(debug:)`, and `node.debug(_:_:)` (closure form). Silently ignored on entry points that observe mutations rather than reads.

For the common "show me where this property was read from" question, `captureAccessStack:` is the better-targeted tool — it inherits the trigger line's labelling and emits only for paths that actually fire. Reach for `accessObserver` when you want to act on access independent of whether the property later triggers.

## Routing Output to Signposts (Instruments)

Every debug entry point — `withDebug`, `model.node.debug()`, `Observed(debug:)`, `memoize(debug:)`, `observeModifications(debug:)`, and `@ObservedModel(debug:)` — accepts a `printer: (any TextOutputStream & Sendable)?` field on `DebugOptions`. To route output to Instruments' signpost log instead of stdout, write a small `TextOutputStream` adapter:

```swift
import os.signpost

struct SignpostStream: TextOutputStream, Sendable {
    let log: OSLog
    let name: StaticString

    init(subsystem: String, category: String, name: StaticString = "model") {
        self.log = OSLog(subsystem: subsystem, category: category)
        self.name = name
    }

    func write(_ string: String) {
        os_signpost(.event, log: log, name: name, "%{public}s", string)
    }
}
```

Then pass an instance via `printer:` to any debug hook:

```swift
let signposts = SignpostStream(subsystem: "com.example.app", category: "model")

// View-side invalidations as signposts:
@ObservedModel(debug: .init(name: "EditorMidBar", printer: signposts)) var editor: EditorModel

// Memoize recomputes:
node.memoize(debug: .init(name: "sorted", printer: signposts)) { items.sorted() }

// Anchored-tree changes:
AppModel().withDebug(.init(name: "App", printer: signposts)).withAnchor()
```

Each debug line becomes a *point event* on the Instruments timeline. The `%{public}s` format string is important — without `public`, signpost arguments are redacted in non-development logs. The same shim works equally well for `OSLog` `Logger` output, a JSON-lines file, or any other custom sink: anything that conforms to `TextOutputStream & Sendable` plugs in unchanged.

> This is a *point-event* shim. The current `TextOutputStream` printer interface doesn't model begin/end intervals, so signposts produced this way appear as one-shot markers on the timeline rather than spans with measurable durations.
