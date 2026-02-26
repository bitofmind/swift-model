# Testing Guide

## Test Organization

Tests are organized using Swift Testing tags to separate different types of tests:

### Tags

- **`.benchmark`** - Performance/benchmark tests that measure execution time and resource usage
- **`.flaky`** - Tests that may occasionally fail due to timing issues

## Running Tests

### Using swift test (regex filtering)

Run non-benchmark tests:
```bash
swift test --skip "benchmark"
```

Run only benchmark tests:
```bash
swift test --filter "benchmark"
```

Run all tests:
```bash
swift test
```

### Using Xcode

In Xcode, benchmarks are tagged and serialized:

1. **Test Navigator (⌘6)** - View all tests
2. **Filter by name** - Type "benchmark" to show only benchmarks
3. **Run specific tests** - Click the diamond icon next to a test
4. **Test Plans** - Configure which tags to include/exclude (recommended)

#### Creating a Test Plan for Benchmarks

1. Product → Scheme → Edit Scheme
2. Select Test action
3. Click "Convert to use Test Plans" (if not already using one)
4. Create a new test plan for benchmarks
5. Use test plan configurations to filter by tags

## Benchmark Tests

All benchmark tests are marked with `.tags(.benchmark)` and `.serialized`:

- **Serialized execution**: Benchmarks run one at a time to avoid interference
- **Performance measurements**: These tests print timing and performance metrics  
- **Can be filtered**: Use `--skip "benchmark"` to exclude from regular runs

### Benchmark Test Files
- `MemoizePerformanceTests.swift` - 8 memoization performance benchmarks
- `CoalescingTests.swift` - 6 update coalescing benchmarks

### When to run benchmarks
- Before/after performance optimizations
- To verify performance regressions
- For performance profiling and analysis
- **Not** during rapid development (they're slower)

## Example Workflows

### Regular development (fast)
```bash
swift test --skip "benchmark"
```

### Performance tuning
```bash
swift test --filter "benchmark"
```

### Full test suite
```bash
swift test
```

### In Xcode
- **⌘U** - Run all tests in current scheme
- **⌃⌥⌘U** - Run tests again  
- Click test diamond in gutter to run individual tests
- Use Test Navigator filter to find specific tests

## Test Statistics

As of this writing:
- **Total tests**: 212
- **Benchmark tests**: 14 (marked with `.benchmark` tag)
- **Expected failures**: 5 (lifetime tests)
- **Regular validation tests**: ~193

## Adding New Tests

When adding benchmark tests:
```swift
@Test(.tags(.benchmark), .serialized)
func benchmarkMyFeature() async throws {
    // Your benchmark code
    // Print performance metrics
}
```

When adding flaky/timing-sensitive tests:
```swift
@Test(.tags(.flaky))
func testTimingSensitiveFeature() async throws {
    // Your test code
}
```

## Tag Benefits

✅ **Organized** - Clear separation between validation and performance tests  
✅ **Filterable** - Skip slow benchmarks during development  
✅ **Serialized** - Benchmarks run one-at-a-time for accurate measurements  
✅ **Documented** - Tags make test purpose explicit
