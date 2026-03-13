# SignUpFlow

A multi-step sign-up form that guides the user through Basics → Personal Info → Topics → Summary, with the ability to jump back and edit any step from the summary screen. Demonstrates enum-based navigation, shared state, and environment context propagation.

This is a refactoring of a [sample app](https://github.com/pointfreeco/episode-code-samples/blob/main/0270-shared-state-pt3/swift-composable-architecture/Examples/CaseStudies/SwiftUICaseStudies/SignUpFlow.swift) from [Point-Free](https://www.pointfree.co)'s [The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture).

## What it demonstrates

### Enum-based navigation with `@ModelContainer`

The navigation path is an array of enum cases, each holding its destination's model:

```swift
@Model @ModelContainer struct SignUpFeature {
    var path: [Path] = []

    @CasePathable enum Path: Identifiable {
        case basics(BasicsFeature)
        case personalInfo(PersonalInfoFeature)
        case topics(TopicsFeature)
        case summary(SummaryFeature)
    }
}
```

`@ModelContainer` and `@CasePathable` make the array work directly with `NavigationStack`.

### Shared state via constructor injection

All steps share the same `SignUpData` instance, passed through each model's initialiser:

```swift
func basicsNextTapped() {
    path.append(.personalInfo(PersonalInfoFeature(signUpData: signUpData)))
}
```

Because `SignUpData` is a `@Model`, all steps share identity — a change on one screen is immediately visible on all others, with no synchronisation.

### Context — environment propagation for edit mode

When the user taps "Edit" from the summary screen, `SummaryFeature` sets `isEditing = true` on its *own* context node. Because the key uses `.environment` propagation, this value flows down to all descendants automatically — including the `PersonalInfoFeature` or `TopicsFeature` inside `destination` — without any constructor parameter:

```swift
extension ContextKeys {
    var isEditing: ContextStorage<Bool> {
        .init(defaultValue: false, propagation: .environment)
    }
}

// SummaryFeature — sets on its own node; descendants inherit via environment
func editPersonalInfoButtonTapped() {
    node.context.isEditing = true
    destination = .personalInfo(PersonalInfoFeature(signUpData: signUpData))
}

// PersonalInfoFeature — reads from context; no constructor param needed
var isEditing: Bool { node.context.isEditing }
```

Steps in the normal forward flow (children of `SignUpFeature`, not `SummaryFeature`) inherit `false` — the default — so no changes are needed there.

## App structure

| Model | Screen | Responsibility |
|-------|--------|---------------|
| `SignUpFeature` | Root | Navigation path, shared `SignUpData` |
| `BasicsFeature` | Step 1 | Email + password fields |
| `PersonalInfoFeature` | Step 2 | Name fields; reads `isEditing` from context |
| `TopicsFeature` | Step 3 | Topic selection with validation; reads `isEditing` from context |
| `SummaryFeature` | Step 4 | Review all data; sets `isEditing` context, pushes edit destinations |
| `SignUpData` | — | Shared mutable state (email, name, topics) |

See also [SignUpFlowUsingDependency](../SignUpFlowUsingDependency) for the same app using `@ModelDependency` instead of constructor injection for `SignUpData`.
