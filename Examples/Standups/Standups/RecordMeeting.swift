import SwiftModel
import Speech
import SwiftUI
import SwiftUINavigation
import CasePaths

@Model struct RecordMeeting: Sendable {
  var destination: Destination?
  private(set) var secondsElapsed = 0
  private(set) var speakerIndex = 0
  private(set) var standup: Standup
  private(set) var transcript = ""

  let onSave: @Sendable (String) -> Void
  let onDiscard: @Sendable () -> Void

  var durationRemaining: Duration {
    standup.duration - .seconds(secondsElapsed)
  }

  @ModelContainer @CasePathable
  @dynamicMemberLookup
  enum Destination {
    case endMeeting(confirmSave: @Sendable () -> Void, discard: (@Sendable () -> Void)?)
    case speechRecognizerFailed(discard: @Sendable () -> Void)
  }

  func onActivate() {
    node.task {
      let authorization =
      await node.speechClient.authorizationStatus() == .notDetermined
      ? node.speechClient.requestAuthorization()
      : node.speechClient.authorizationStatus()

      node.forEach(node.continuousClock.timer(interval: .seconds(1))) { _ in
        guard destination == nil else { return }

        secondsElapsed += 1

        let secondsPerAttendee = Int(standup.durationPerAttendee.components.seconds)
        if secondsElapsed.isMultiple(of: secondsPerAttendee) {
          if speakerIndex == standup.attendees.count - 1 {
            onSave(transcript)
            throw CancellationError()
          } else {
            speakerIndex += 1
          }
        }
      }.inheritCancellationContext()

      if authorization == .authorized {
        let speechTask = await node.speechClient.startTask(SFSpeechAudioBufferRecognitionRequest())
        do {
          for try await result in speechTask {
            transcript = result.bestTranscription.formattedString
          }
        } catch {
          if !transcript.isEmpty {
            transcript += " ❌"
          }
          destination = .speechRecognizerFailed(discard: onDiscard)
        }
      }
    }
  }

  func endMeetingButtonTapped() {
    destination = .endMeeting(confirmSave: { onSave(transcript) }, discard: onDiscard)
  }

  func nextButtonTapped() {
    guard speakerIndex < standup.attendees.count - 1 else {
      destination = .endMeeting(confirmSave: { onSave(transcript) }, discard: nil)
      return
    }
    speakerIndex += 1
    secondsElapsed =
    speakerIndex * Int(standup.durationPerAttendee.components.seconds)
  }
}

struct RecordMeetingView: View {
  @ObservedModel var model: RecordMeeting

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 16)
        .fill(model.standup.theme.mainColor)

      VStack {
        MeetingHeaderView(
          secondsElapsed: model.secondsElapsed,
          durationRemaining: model.durationRemaining,
          theme: model.standup.theme
        )
        MeetingTimerView(
          standup: model.standup,
          speakerIndex: model.speakerIndex
        )
        MeetingFooterView(
          standup: model.standup,
          nextButtonTapped: {
            model.nextButtonTapped()
          },
          speakerIndex: model.speakerIndex
        )
      }
    }
    .padding()
    .foregroundColor(model.standup.theme.accentColor)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("End meeting") {
          model.endMeetingButtonTapped()
        }
      }
    }
    .navigationBarBackButtonHidden(true)
    .alert(title: { _ in
      Text("End meeting?")
    }, unwrapping: $model.destination.endMeeting) { confirmSave, discard in
      Button("Save and end", action: confirmSave)
      if let discard {
        Button("Discard", role: .destructive, action: discard)
      }
      Button("Resume", role: .cancel) { }
    } message: { _ in
      Text("You are ending the meeting early. What would you like to do?")
    }
    .alert(title: { _ in
      Text("Speech recognition failure")
    }, unwrapping: $model.destination.speechRecognizerFailed) { discard in
      Button("Continue meeting", role: .cancel) { }
      Button("Discard meeting", role: .destructive, action: discard)
    } message: { _ in
      Text(
        """
        The speech recognizer has failed for some reason and so your meeting will no longer be \
        recorded. What do you want to do?
        """
      )
    }
  }
}

struct MeetingHeaderView: View {
  let secondsElapsed: Int
  let durationRemaining: Duration
  let theme: Theme

  var body: some View {
    VStack {
      ProgressView(value: progress)
        .progressViewStyle(MeetingProgressViewStyle(theme: theme))
      HStack {
        VStack(alignment: .leading) {
          Text("Time Elapsed")
            .font(.caption)
          Label(
            Duration.seconds(secondsElapsed).formatted(.units()),
            systemImage: "hourglass.bottomhalf.fill"
          )
        }
        Spacer()
        VStack(alignment: .trailing) {
          Text("Time Remaining")
            .font(.caption)
          Label(durationRemaining.formatted(.units()), systemImage: "hourglass.tophalf.fill")
            .font(.body.monospacedDigit())
            .labelStyle(.trailingIcon)
        }
      }
    }
    .padding([.top, .horizontal])
  }

  private var totalDuration: Duration {
    .seconds(secondsElapsed) + durationRemaining
  }

  private var progress: Double {
    guard totalDuration > .seconds(0) else { return 0 }
    return Double(secondsElapsed) / Double(totalDuration.components.seconds)
  }
}

struct MeetingProgressViewStyle: ProgressViewStyle {
  var theme: Theme

  func makeBody(configuration: Configuration) -> some View {
    ZStack {
      RoundedRectangle(cornerRadius: 10)
        .fill(theme.accentColor)
        .frame(height: 20)

      ProgressView(configuration)
        .tint(theme.mainColor)
        .frame(height: 12)
        .padding(.horizontal)
    }
  }
}

struct MeetingTimerView: View {
  let standup: Standup
  let speakerIndex: Int

  var body: some View {
    Circle()
      .strokeBorder(lineWidth: 24)
      .overlay {
        VStack {
          Group {
            if speakerIndex < standup.attendees.count {
              Text(standup.attendees[speakerIndex].name)
            } else {
              Text("Someone")
            }
          }
          .font(.title)
          Text("is speaking")
          Image(systemName: "mic.fill")
            .font(.largeTitle)
            .padding(.top)
        }
        .foregroundStyle(standup.theme.accentColor)
      }
      .overlay {
        ForEach(Array(standup.attendees.enumerated()), id: \.element.id) { index, attendee in
          if index < speakerIndex + 1 {
            SpeakerArc(totalSpeakers: standup.attendees.count, speakerIndex: index)
              .rotation(Angle(degrees: -90))
              .stroke(standup.theme.mainColor, lineWidth: 12)
          }
        }
      }
      .padding(.horizontal)
  }
}

struct SpeakerArc: Shape {
  let totalSpeakers: Int
  let speakerIndex: Int

  func path(in rect: CGRect) -> Path {
    let diameter = min(rect.size.width, rect.size.height) - 24
    let radius = diameter / 2
    let center = CGPoint(x: rect.midX, y: rect.midY)
    return Path { path in
      path.addArc(
        center: center,
        radius: radius,
        startAngle: startAngle,
        endAngle: endAngle,
        clockwise: false
      )
    }
  }

  private var degreesPerSpeaker: Double {
    360 / Double(totalSpeakers)
  }
  private var startAngle: Angle {
    Angle(degrees: degreesPerSpeaker * Double(speakerIndex) + 1)
  }
  private var endAngle: Angle {
    Angle(degrees: startAngle.degrees + degreesPerSpeaker - 1)
  }
}

struct MeetingFooterView: View {
  let standup: Standup
  var nextButtonTapped: () -> Void
  let speakerIndex: Int

  var body: some View {
    VStack {
      HStack {
        if speakerIndex < standup.attendees.count - 1 {
          Text("Speaker \(speakerIndex + 1) of \(standup.attendees.count)")
        } else {
          Text("No more speakers.")
        }
        Spacer()
        Button(action: nextButtonTapped) {
          Image(systemName: "forward.fill")
        }
      }
    }
    .padding([.bottom, .horizontal])
  }
}

struct RecordMeeting_Previews: PreviewProvider {
  static var previews: some View {
    NavigationStack {
      RecordMeetingView(model: RecordMeeting(standup: .mock, onSave: { _ in }, onDiscard: {}).withAnchor())
    }
  }
}
