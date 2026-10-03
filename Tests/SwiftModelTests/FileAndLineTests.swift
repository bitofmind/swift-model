import Testing
@testable import SwiftModel

/// `FileAndLine` compares and hashes without building strings; it must still treat
/// two values as equal exactly when file, path, line and column agree.
struct FileAndLineTests {
    private func here(fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column) -> FileAndLine {
        FileAndLine(fileID: fileID, filePath: filePath, line: line, column: column)
    }

    @Test func sameCallSiteIsEqualWithEqualHash() {
        var values: [FileAndLine] = []
        for _ in 0..<2 { values.append(here()) }
        #expect(values[0] == values[1])
        #expect(values[0].hashValue == values[1].hashValue)
    }

    @Test func differentLineOrColumnIsNotEqual() {
        let a = here(), b = here()
        let c = here(line: 1, column: 1)
        #expect(a != b)
        #expect(a != c)
    }

    @Test func sameTextInDifferentStorageIsEqual() {
        // Same characters, separate literals: equal whether or not the compiler shares
        // their storage.
        let a = FileAndLine(fileID: "Module/File.swift", filePath: "/src/Module/File.swift", line: 3, column: 4)
        let b = FileAndLine(fileID: "Module/File.swift", filePath: "/src/Module/File.swift", line: 3, column: 4)
        let c = FileAndLine(fileID: "Module/Filf.swift", filePath: "/src/Module/File.swift", line: 3, column: 4)
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
        #expect(a != c)
        #expect(Set([a, b, c]).count == 2)
    }
}
