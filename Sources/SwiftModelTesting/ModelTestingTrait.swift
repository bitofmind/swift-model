// All testing APIs (ModelTestingTrait, expect, require, withExhaustivity, withModelTesting,
// .modelTesting) now live in the SwiftModel module behind #if canImport(Testing) && compiler(>=6).
//
// This module re-exports SwiftModel so existing `import SwiftModelTesting` statements
// continue to work without any changes.
@_exported import SwiftModel
