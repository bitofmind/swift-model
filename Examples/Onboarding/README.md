# Onboarding — Sign-Up Wizard

A three-step account creation wizard that demonstrates NavigationStack path navigation,
event-driven coordination, and async validation in SwiftModel.

## What this example shows

| Pattern | Where |
|---|---|
| `NavigationStack` path navigation | `SignUpModel.path` — credentials is the always-present root; profile and review steps are pushed/popped via `path: [Step]` |
| `@ModelContainer enum Step` | `SignUpModel.Step` — the path element type; `@ModelContainer` synthesises `Hashable`, `Equatable`, `Identifiable`, and the `visit(with:)` traversal |
| Preserved state on back navigation | `credentialsModel` lives outside the path and is never replaced, so entered data survives forward-and-back trips |
| `node.send` / `node.event(fromType:)` | Each step model sends an event on success; `SignUpModel.onActivate()` listens with `node.forEach(node.event(fromType:))` and pushes the next step |
| `cancelPrevious: true` for async validation | `ProfileStepModel.onActivate()` — cancels the in-flight username availability check whenever the user types, so only the last check completes |
| `node.local` | `CredentialsStepModel` — `node.local.hasAttemptedSubmit` stores transient validation state not part of the model's persistent data |
| `node.task` with `catch:` | `ReviewStepModel.submitTapped()` — async account creation with inline error handling |
| `@ModelDependency` | `SignUpClient` is injected into all step models; swapped out in tests and previews |
| Deep links | `SignUpModel.handleURL(_:)` handles `signup://step/profile` and `signup://step/review` by setting `path` directly |

## Project structure

```
OnboardingApp.swift        — App entry point
ValidationClient.swift     — SignUpClient @ModelDependency (email validation, username availability, account creation)
OnboardingFeature.swift    — All models and views
```

## The sign-up flow

```
CredentialsStepModel  ──push──▶  ProfileStepModel  ──push──▶  ReviewStepModel  ──▶  complete
  (root, always live)              (in path[0])                  (in path[1])
         ◀──────── NavigationStack back button pops path (data preserved) ────────▶
```

`credentialsModel` is a stored property of `SignUpModel` — it stays alive for the entire sign-up. Only the navigated-to steps live in `path`. Tapping the system Back button pops `path` through the binding; the credentials model is untouched, so any entered email/password is still there when the user returns.

## Key code patterns

### NavigationStack path navigation

```swift
@Model struct SignUpModel: Sendable {
    var credentialsModel = CredentialsStepModel()   // always the root
    var path: [Step] = []                           // empty = on credentials screen

    @ModelContainer
    enum Step: Hashable, Identifiable, Sendable {
        case profile(ProfileStepModel)
        case review(ReviewStepModel)
    }
}
```

```swift
NavigationStack(path: $model.path) {
    CredentialsStepView(model: model.credentialsModel)
        .navigationDestination(for: SignUpModel.Step.self) { step in
            switch step {
            case .profile(let m): ProfileStepView(model: m)
            case .review(let m):  ReviewStepView(model: m)
            }
        }
}
```

`$model.path` is a `Binding<[Step]>` provided by `@ObservedModel`. When the system Back button fires, NavigationStack writes the trimmed array back through the binding. SwiftModel detects the removed element and deactivates the old child model — cancelling any in-flight tasks automatically.

### Event-driven path advancement

```swift
// Child sends an event upward:
node.send(.continued(email: email, password: password))

// Parent listens in onActivate() and pushes the next step:
node.forEach(node.event(fromType: CredentialsStepModel.self)) { event, _ in
    if case .continued(let e, let p) = event {
        email = e; password = p
        path.append(.profile(ProfileStepModel()))
    }
}
```

Each step model just describes *what happened*. `SignUpModel` decides *what to do next* — here, push to the path. This keeps child models decoupled from the navigation mechanism.

### Back navigation preserves data

```swift
// In tests — simulate the NavigationStack back button:
model.path.removeLast()

// The credentials model is unaffected — no re-entry needed:
#expect(model.credentialsModel.email == "user@example.com")
```

### Deep links set the path directly

```swift
func handleURL(_ url: URL) {
    guard url.scheme == "signup", url.host == "step" else { return }
    switch url.lastPathComponent {
    case "profile":
        path = [.profile(ProfileStepModel())]
    case "review":
        path = [.profile(ProfileStepModel()), .review(ReviewStepModel(...))]
    default:
        path = []
    }
}
```

## Tests

```
OnboardingTests/OnboardingTests.swift
```

| Test | What it checks |
|---|---|
| `initialState` | Model starts with an empty path |
| `validCredentialsAdvancesToProfile` | Valid credentials push `.profile` onto the path |
| `validProfileAdvancesToReview` | Valid username pushes `.review` onto the path |
| `fullSignUpFlow` | Complete 3-step flow ends with `isComplete = true` |
| `backFromProfilePreservesCredentials` | Popping path leaves credentials data intact |
| `backFromReviewReturnsToProfile` | Popping twice returns to profile step |
| `deepLinkJumpsToProfileStep` | `signup://step/profile` sets path to `[.profile(...)]` |
| `deepLinkPreservesExistingEmail` | Deep link does not wipe previously entered email |
| `startOverResetsFlow` | `startOver()` clears path and resets all fields |
| `sendsEventOnValidCredentials` | `TestProbe` confirms the event is sent |
| `invalidEmailBlocksContinuation` | `TestProbe` confirms no event on validation failure |
| `passwordMismatchBlocksContinuation` | Mismatched passwords block the event |
| `liveValidationAfterFirstSubmit` | After first submit, editing a field re-validates automatically |
| `usernameAvailabilityCheck` | Taken username shows error; available username clears it |
| `shortUsernameShowsInlineError` | Sub-3-char username shows inline error without a network call |
| `sendsEventOnValidUsername` | `TestProbe` confirms `ProfileStepModel` sends the event |
