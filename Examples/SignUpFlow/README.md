# SignUpFlow

A multi-step sign-up form that guides the user through Basics → Personal Info → Topics → Summary, with the ability to jump back and edit any step from the summary screen. Demonstrates enum-based navigation, shared state, and environment context propagation.


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

### Environment — propagation for edit mode

When the user taps "Edit" from the summary screen, `SummaryFeature` sets `isEditing = true` on its own environment. This value flows down to all descendants automatically — including the `PersonalInfoFeature` or `TopicsFeature` inside `destination` — without any constructor parameter:

```swift
extension EnvironmentKeys {
    var isEditing: EnvironmentStorage<Bool> {
        .init(defaultValue: false)
    }
}

// SummaryFeature — sets on its own node; descendants inherit via environment
func editPersonalInfoButtonTapped() {
    node.environment.isEditing = true
    destination = .personalInfo(PersonalInfoFeature(signUpData: signUpData))
}

// PersonalInfoFeature — reads from environment; no constructor param needed
var isEditing: Bool { node.environment.isEditing }
```

Steps in the normal forward flow (children of `SignUpFeature`, not `SummaryFeature`) inherit `false` — the default — so no changes are needed there.

## App structure

| Model | Screen | Responsibility |
|-------|--------|---------------|
| `SignUpFeature` | Root | Navigation path, shared `SignUpData` |
| `BasicsFeature` | Step 1 | Email + password fields |
| `PersonalInfoFeature` | Step 2 | Name fields; reads `isEditing` from environment |
| `TopicsFeature` | Step 3 | Topic selection with validation; reads `isEditing` from environment |
| `SummaryFeature` | Step 4 | Review all data; sets `isEditing` environment, pushes edit destinations |
| `SignUpData` | — | Shared mutable state (email, name, topics) |

See also [SignUpFlowUsingDependency](../SignUpFlowUsingDependency) for the same app using `@ModelDependency` instead of constructor injection for `SignUpData`.
