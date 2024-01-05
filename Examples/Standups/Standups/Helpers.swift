import SwiftUI
import IdentifiedCollections
import SwiftModel

//public extension Binding {
//  subscript<Val, Subject>(dynamicMember keyPath: WritableKeyPath<Val, Subject>) -> Binding<Subject?> where Value == Val? {
//    Binding<Subject?> {
//      wrappedValue?[keyPath: keyPath]
//    } set: { value in
//      if let value {
//        wrappedValue?[keyPath: keyPath] = value
//      } else {
//        wrappedValue = nil
//      }
//    }
//  }
//
//  subscript<Val, Subject>(dynamicMember keyPath: WritableKeyPath<Val, Subject?>) -> Binding<Subject?> where Value == Val? {
//    Binding<Subject?> {
//      wrappedValue?[keyPath: keyPath]
//    } set: { value in
//      if let value {
//        wrappedValue?[keyPath: keyPath] = value
//      } else {
//        wrappedValue = nil
//      }
//    }
//  }
//}

