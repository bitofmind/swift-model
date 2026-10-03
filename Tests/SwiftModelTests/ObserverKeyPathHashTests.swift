import Testing
import ConcurrencyExtras
@testable import SwiftModel

/// The registrar keeps the key paths it tracks in one dictionary per tree, so the key
/// paths SwiftModel registers must hash apart. A key path hashes only the first argument
/// of a multi-argument subscript, so the `_StateObserver` subscripts take one argument;
/// with two, every model reading the same environment key shared one hash.
struct ObserverKeyPathHashTests {
    @Test func propertyPathsHashApartAcrossPropertiesAndContexts() {
        guard #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) else { return }
        let paths: [AnyKeyPath] = (0..<20).flatMap { context in
            (0..<10).map { prop in
                \_StateObserver<Int>[property: _ObserverPropertyKey(contextID: UInt(0x6000_0000 + context * 0x200), propID: UInt(prop))]
            }
        }
        #expect(Set(paths.map(\.hashValue)).count == paths.count)
    }

    @Test func storagePathsHashApartAcrossModels() {
        guard #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) else { return }
        let key = AnyHashableSendable("mode")
        let paths: [AnyKeyPath] = (0..<200).flatMap { _ in
            let modelID = ModelID.generate()
            return [
                \_StateObserver<Int>[environmentKey: _ObserverStorageKey(key: key, modelID: modelID)],
                \_StateObserver<Int>[preferenceKey: _ObserverStorageKey(key: key, modelID: modelID)],
                \_StateObserver<Int>[memoizeKey: _ObserverStorageKey(key: key, modelID: modelID)],
                \_StateObserver<Int>[parentsOf: modelID],
            ] as [AnyKeyPath]
        }
        #expect(Set(paths.map(\.hashValue)).count == paths.count)
    }
}
