import Testing
import Foundation
import os
@testable import SwiftModel

/// Benchmarks comparing eager vs lazy child context creation for large arrays.
///
/// Run with the `.benchmark` tag to get timing results.
/// Collection elements (e.g. `[Post]`) are eager by default — their `Context<M>` is created
/// immediately. Use `withModelOptions(.lazyChildContexts)` to benchmark the lazy (deferred) path.
@Suite(.serialized, .tags(.benchmark))
struct LazyContextBenchmarks {

    @Model struct Post {
        var title: String
        var message: String
    }

    @Model struct Feed {
        var posts: [Post]
    }

    // MARK: - Instruments profiling loops (100 iterations × 2000 posts)
    //
    // To profile in Instruments:
    //   1. Product → Profile (⌘I) or run via xctrace:
    //      xcrun xctrace record --template 'Time Profiler' --output profile.trace \
    //        --launch -- xctest \
    //        -XCTest "LazyContextBenchmarks/profileEagerAnchor_loop" \
    //        .build/arm64-apple-macosx/release/swift-modelPackageTests.xctest
    //   2. Open profile.trace in Instruments
    //   3. In the Points of Interest track, look for "EagerAnchor" / "LazyAnchor" intervals
    //   4. Select the interval and use "Inspect Head" to filter the CPU profiler to just that region
    //
    // The os_signpost intervals are emitted to subsystem "com.swiftmodel.benchmark",
    // category "LazyContext" — use that filter in Instruments' Signpost instrument.

    @Test func profileEagerAnchor_loop() {
        let signposter = OSSignposter(subsystem: "com.swiftmodel.benchmark", category: "LazyContext")
        let id = signposter.makeSignpostID()
        let state = signposter.beginInterval("EagerAnchor", id: id, "\(100) iterations × 2000 posts")
        let start = ContinuousClock.now
        for _ in 0..<100 {
            _ = makeFeed(count: 2000).withAnchor()
        }
        let duration = ContinuousClock.now - start
        signposter.endInterval("EagerAnchor", state)
        print("📊 Profile loop eager (100×2000): \(durationMs(duration))ms total (\(durationMs(duration / 100)) ms/iter)")
    }

    @Test func profileLazyAnchor_loop() {
        let signposter = OSSignposter(subsystem: "com.swiftmodel.benchmark", category: "LazyContext")
        let id = signposter.makeSignpostID()
        let state = signposter.beginInterval("LazyAnchor", id: id, "\(100) iterations × 2000 posts")
        let start = ContinuousClock.now
        for _ in 0..<100 {
            _ = withModelOptions(.lazyChildContexts) { makeFeed(count: 2000).withAnchor() }
        }
        let duration = ContinuousClock.now - start
        signposter.endInterval("LazyAnchor", state)
        print("📊 Profile loop lazy (100×2000): \(durationMs(duration))ms total (\(durationMs(duration / 100)) ms/iter)")
    }

    // MARK: - Anchor time: 100 posts

    @Test func benchmarkEagerAnchor_100() {
        let feed = makeFeed(count: 100)
        let start = ContinuousClock.now
        let anchored = feed.withAnchor()
        let duration = ContinuousClock.now - start
        print("📊 Eager anchor (100 posts): \(durationMs(duration))ms [\(anchored.posts.count) posts]")
    }

    @Test func benchmarkLazyAnchor_100() {
        let feed = makeFeed(count: 100)
        let start = ContinuousClock.now
        let anchored = withModelOptions(.lazyChildContexts) { feed.withAnchor() }
        let duration = ContinuousClock.now - start
        print("📊 Lazy anchor (100 posts): \(durationMs(duration))ms [\(anchored.posts.count) posts]")
    }

    @Test func benchmarkEagerAnchorViewport_100() {
        let anchored = makeFeed(count: 100).withAnchor()
        let start = ContinuousClock.now
        measureViewport(feed: anchored, count: 20)
        let duration = ContinuousClock.now - start
        print("📊 Eager viewport (100 total, 20 read): \(durationMs(duration))ms")
    }

    @Test func benchmarkLazyAnchorViewport_100() {
        let anchored = withModelOptions(.lazyChildContexts) { makeFeed(count: 100).withAnchor() }
        let start = ContinuousClock.now
        measureViewport(feed: anchored, count: 20)
        let duration = ContinuousClock.now - start
        print("📊 Lazy viewport (100 total, 20 read): \(durationMs(duration))ms")
    }

    // MARK: - Anchor time: 500 posts

    @Test func benchmarkEagerAnchor_500() {
        let feed = makeFeed(count: 500)
        let start = ContinuousClock.now
        let anchored = feed.withAnchor()
        let duration = ContinuousClock.now - start
        print("📊 Eager anchor (500 posts): \(durationMs(duration))ms [\(anchored.posts.count) posts]")
    }

    @Test func benchmarkLazyAnchor_500() {
        let feed = makeFeed(count: 500)
        let start = ContinuousClock.now
        let anchored = withModelOptions(.lazyChildContexts) { feed.withAnchor() }
        let duration = ContinuousClock.now - start
        print("📊 Lazy anchor (500 posts): \(durationMs(duration))ms [\(anchored.posts.count) posts]")
    }

    @Test func benchmarkEagerAnchorViewport_500() {
        let anchored = makeFeed(count: 500).withAnchor()
        let start = ContinuousClock.now
        measureViewport(feed: anchored, count: 20)
        let duration = ContinuousClock.now - start
        print("📊 Eager viewport (500 total, 20 read): \(durationMs(duration))ms")
    }

    @Test func benchmarkLazyAnchorViewport_500() {
        let anchored = withModelOptions(.lazyChildContexts) { makeFeed(count: 500).withAnchor() }
        let start = ContinuousClock.now
        measureViewport(feed: anchored, count: 20)
        let duration = ContinuousClock.now - start
        print("📊 Lazy viewport (500 total, 20 read): \(durationMs(duration))ms")
    }

    // MARK: - Anchor time: 2000 posts

    @Test func benchmarkEagerAnchor_2000() {
        let feed = makeFeed(count: 2000)
        let start = ContinuousClock.now
        let anchored = feed.withAnchor()
        let duration = ContinuousClock.now - start
        print("📊 Eager anchor (2000 posts): \(durationMs(duration))ms [\(anchored.posts.count) posts]")
    }

    @Test func benchmarkLazyAnchor_2000() {
        let feed = makeFeed(count: 2000)
        let start = ContinuousClock.now
        let anchored = withModelOptions(.lazyChildContexts) { feed.withAnchor() }
        let duration = ContinuousClock.now - start
        print("📊 Lazy anchor (2000 posts): \(durationMs(duration))ms [\(anchored.posts.count) posts]")
    }

    @Test func benchmarkEagerAnchorViewport_2000() {
        let anchored = makeFeed(count: 2000).withAnchor()
        let start = ContinuousClock.now
        measureViewport(feed: anchored, count: 20)
        let duration = ContinuousClock.now - start
        print("📊 Eager viewport (2000 total, 20 read): \(durationMs(duration))ms")
    }

    @Test func benchmarkLazyAnchorViewport_2000() {
        let anchored = withModelOptions(.lazyChildContexts) { makeFeed(count: 2000).withAnchor() }
        let start = ContinuousClock.now
        measureViewport(feed: anchored, count: 20)
        let duration = ContinuousClock.now - start
        print("📊 Lazy viewport (2000 total, 20 read): \(durationMs(duration))ms")
    }

    // MARK: - Full materialization: all 2000 contexts created lazily vs eagerly

    /// Eager baseline: anchor 2000 posts (all contexts created upfront) + write to all 2000.
    @Test func profileEagerAnchorFullWrite_loop() {
        let start = ContinuousClock.now
        for _ in 0..<100 {
            let anchored = makeFeed(count: 2000).withAnchor()
            for i in anchored.posts.indices {
                anchored.posts[i].title = "Updated"
            }
        }
        let duration = ContinuousClock.now - start
        print("📊 Profile eager full-write (100×2000): \(durationMs(duration))ms total (\(durationMs(duration / 100)) ms/iter)")
    }

    /// Lazy: anchor 2000 posts (no contexts yet) + write to all 2000 (materializes all on first write).
    @Test func profileLazyAnchorFullWrite_loop() {
        let start = ContinuousClock.now
        for _ in 0..<100 {
            let anchored = withModelOptions(.lazyChildContexts) { makeFeed(count: 2000).withAnchor() }
            for i in anchored.posts.indices {
                anchored.posts[i].title = "Updated"
            }
        }
        let duration = ContinuousClock.now - start
        print("📊 Profile lazy full-write (100×2000): \(durationMs(duration))ms total (\(durationMs(duration / 100)) ms/iter)")
    }
}

// MARK: - Helpers

private func makeFeed(count: Int) -> LazyContextBenchmarks.Feed {
    let posts = (0..<count).map { LazyContextBenchmarks.Post(title: "Title \($0)", message: "Message \($0)") }
    return LazyContextBenchmarks.Feed(posts: posts)
}

/// Iterates the first `count` posts and reads their title — simulates SwiftUI viewport rendering.
private func measureViewport(feed: LazyContextBenchmarks.Feed, count: Int) {
    var read = 0
    for post in feed.posts {
        if read >= count { break }
        _ = post.title
        read += 1
    }
}

private func durationMs(_ duration: Duration) -> String {
    let ns = duration.components.seconds * 1_000_000_000 + Int64(duration.components.attoseconds / 1_000_000_000)
    return String(format: "%.3f", Double(ns) / 1_000_000)
}
