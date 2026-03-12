# Standups

A full-featured standup meeting manager: create and edit standups, record live meetings with a timer and speech-to-text transcript, and review past meeting records. This is the most comprehensive example in the suite, covering nearly every SwiftModel feature.

This is a refactoring of Apple's [Scrumdinger](https://developer.apple.com/tutorials/app-dev-training/getting-started-with-scrumdinger) sample app, which [Point-Free](https://www.pointfree.co) also adapted in both [plain vanilla SwiftUI](https://github.com/pointfreeco/syncups) and [The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture/blob/main/Examples/SyncUps).

## What it demonstrates

### Complex navigation with events

Navigation state is a combination of a `NavigationStack` path and optional sheet/alert destinations, all driven by models:

```
AppFeature
  └── StandupsList          (root list)
        ├── StandupDetail   (pushed onto navigation stack)
        │     └── RecordMeeting (pushed further)
        └── StandupForm     (sheet for add/edit)
```

Child models communicate results back to parents using `node.send()` / `node.forEach(node.event(...))` rather than callbacks or shared references, keeping each feature independently testable.

### Async effects: timers and speech recognition

The `RecordMeeting` model drives a countdown timer and captures a live speech transcript simultaneously:

```swift
func onActivate() {
    node.task {
        // Timer tick every second
        for await _ in node.continuousClock.timer(interval: .seconds(1)) {
            timerFired()
        }
    }
    node.task {
        // Stream speech recognition results
        for await result in try await node.speechClient.startTask(request) {
            transcript = result.bestTranscription.formattedString
        }
    }
}
```

Both tasks run concurrently and are automatically cancelled when the model is deactivated.

### Persistence with debouncing

The standups list is saved to disk whenever it changes, but writes are debounced to avoid hammering the file system on rapid edits:

```swift
node.forEach(Observed(initial: false) { standups }) { standups in
    try await node.continuousClock.sleep(for: .seconds(1))  // debounce
    try await node.dataManager.save(JSONEncoder().encode(standups), to: .standups)
}
```

Data is loaded on `onActivate`, with a graceful error path that offers mock data if loading fails.

### Dependency injection for testing

`SpeechClient`, `DataManager`, and `ContinuousClock` are all injected via the [Dependencies](https://github.com/pointfreeco/swift-dependencies) library. Tests replace them with controlled fakes, making it possible to test timer-driven and speech-driven behaviour deterministically.

### Reusable form model

`StandupForm` is used for both creating new standups and editing existing ones. The same model and view handle both modes — only the initialisation differs.

## App structure

| Model | Responsibility |
|-------|---------------|
| `AppFeature` | Root: navigation path, delegates list |
| `StandupsList` | List of standups, load/save, add/edit destinations |
| `StandupDetail` | Standup details, past meetings, start recording |
| `RecordMeeting` | Active session: timer, speaker rotation, speech transcript |
| `StandupForm` | Reusable create/edit form with attendee management |
| `Standup` | Core data model (title, attendees, theme, meetings) |
| `Meeting` | Past meeting record with transcript |
| `Attendee` | Team member in a standup |
