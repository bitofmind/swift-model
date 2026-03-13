# SignUpFlowUsingDependency

The same multi-step sign-up flow as [SignUpFlow](../SignUpFlow), but shared state is distributed via `@ModelDependency` rather than constructor injection. This makes for a direct comparison of two valid architectural patterns.

This is a refactoring of a [sample app](https://github.com/pointfreeco/episode-code-samples/blob/main/0270-shared-state-pt3/swift-composable-architecture/Examples/CaseStudies/SwiftUICaseStudies/SignUpFlow.swift) from [Point-Free](https://www.pointfree.co)'s [The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture).

## The key difference: `@ModelDependency`

In `SignUpFlow`, shared state is threaded explicitly through each model's initialiser:

```swift
// SignUpFlow — explicit passing
path.append(.personalInfo(PersonalInfoFeature(signUpData: signUpData)))
```

Here, `SignUpData` conforms to `DependencyKey` and is injected at the anchor site:

```swift
// SignUpFlowUsingDependency — implicit via dependency
path.append(.personalInfo(PersonalInfoFeature()))  // no signUpData argument
```

Each step model declares the dependency instead of accepting it as a parameter:

```swift
@Model
struct BasicsFeature {
    @ModelDependency var signUpData: SignUpData  // resolved from the model hierarchy
}
```

The dependency is installed when the root model is anchored:

```swift
SignUpFeature().withAnchor {
    $0[SignUpData.self] = SignUpData()
}
```

## Trade-offs

| | Constructor injection (SignUpFlow) | `@ModelDependency` (this app) |
|---|---|---|
| **Explicitness** | Visible at the call site | Implicit — reader must know about the dependency |
| **Initialiser complexity** | Grows with the number of shared values | Stays simple |
| **Testability** | Pass a test value directly | Override via `withDependencies` at anchor time |
| **Decoupling** | Parent must know child's constructor | Parent creates child without configuration |

Both approaches produce the same runtime behaviour. The right choice depends on team preference and how many values need sharing.

## Context — environment propagation for edit mode

This app uses the same `ContextKeys.isEditing` pattern as `SignUpFlow`. When the user taps "Edit" from the summary screen, `SummaryFeature` sets `isEditing = true` on its own context node. Because the key uses `.environment` propagation, the value flows down to `PersonalInfoFeature` or `TopicsFeature` inside `destination` automatically — no constructor parameter and no dependency needed:

```swift
func editPersonalInfoButtonTapped() {
    node.context.isEditing = true
    destination = .personalInfo(PersonalInfoFeature())  // no extra args
}

// PersonalInfoFeature — reads from context; no dependency or constructor param
var isEditing: Bool { node.context.isEditing }
```

## App structure

The model hierarchy is identical to `SignUpFlow`:

| Model | Screen | Responsibility |
|-------|--------|---------------|
| `SignUpFeature` | Root | Navigation path |
| `BasicsFeature` | Step 1 | Email + password fields |
| `PersonalInfoFeature` | Step 2 | Name fields; reads `isEditing` from context |
| `TopicsFeature` | Step 3 | Topic selection with validation; reads `isEditing` from context |
| `SummaryFeature` | Step 4 | Review all data; sets `isEditing` context, pushes edit destinations |
| `SignUpData` | — | Shared dependency (email, name, topics) |
