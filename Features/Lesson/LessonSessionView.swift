import SwiftUI

// MARK: - Lesson Session View

struct LessonSessionView: View {
    let lesson: Lesson
    @EnvironmentObject var userProgress: UserProgressStore
    @Environment(\.dismiss) var dismiss
    @StateObject private var session = LessonSessionViewModel()

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemBackground).ignoresSafeArea()

                switch session.phase {
                case .intro:
                    IntroPhaseView(lesson: lesson) {
                        session.startSession(lesson: lesson)
                    }

                case .exercise(let exercise):
                    ExercisePhaseView(
                        exercise: exercise,
                        session: session,
                        lessonTitle: lesson.title
                    )

                case .complete:
                    CompletionPhaseView(
                        lesson: lesson,
                        score: session.score,
                        accuracy: session.accuracy
                    ) {
                        userProgress.awardXP(lesson.xpReward, for: lesson.id)
                        dismiss()
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Exit") { dismiss() }
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

// MARK: - Session View Model

class LessonSessionViewModel: ObservableObject {
    @Published var phase: SessionPhase = .intro
    @Published var currentExerciseIndex = 0
    @Published var score = 0
    @Published var correctNotes = 0
    @Published var totalNotes = 0
    @Published var currentNoteIndex = 0
    @Published var lastFeedback: NoteFeedback = .none

    private var exercises: [Exercise] = []
    @StateObject var pitchService = PitchDetectionService()

    enum SessionPhase {
        case intro
        case exercise(Exercise)
        case complete
    }

    enum NoteFeedback {
        case none, correct, incorrect, listening
    }

    var accuracy: Double {
        guard totalNotes > 0 else { return 0 }
        return Double(correctNotes) / Double(totalNotes)
    }

    func startSession(lesson: Lesson) {
        exercises = lesson.exercises
        if exercises.isEmpty {
            // Placeholder for lessons not yet built out
            phase = .complete
        } else {
            currentExerciseIndex = 0
            currentNoteIndex = 0
            phase = .exercise(exercises[0])
        }
    }

    func advanceNote(correct: Bool) {
        totalNotes += 1
        if correct {
            correctNotes += 1
            score += 10
            lastFeedback = .correct
        } else {
            lastFeedback = .incorrect
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            let exercise = self.exercises[self.currentExerciseIndex]
            self.currentNoteIndex += 1
            if self.currentNoteIndex >= exercise.notes.count {
                self.advanceExercise()
            } else {
                self.lastFeedback = .none
            }
        }
    }

    private func advanceExercise() {
        currentExerciseIndex += 1
        currentNoteIndex = 0
        lastFeedback = .none
        if currentExerciseIndex >= exercises.count {
            phase = .complete
        } else {
            phase = .exercise(exercises[currentExerciseIndex])
        }
    }
}

// MARK: - Intro Phase

private struct IntroPhaseView: View {
    let lesson: Lesson
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: Spacing.xl) {
            Spacer()
            Image(systemName: "music.note")
                .font(.system(size: 60, weight: .light))
                .foregroundColor(.indigo)

            VStack(spacing: Spacing.sm) {
                Text(lesson.title)
                    .font(MuseFont.display(28))
                Text(lesson.subtitle)
                    .font(MuseFont.body())
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: Spacing.sm) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "mic.fill")
                        .foregroundColor(.indigo)
                    Text("Make sure your microphone is enabled so MuseLearn can hear you play.")
                        .font(MuseFont.body(14))
                        .foregroundColor(.secondary)
                }
                .padding(Spacing.md)
                .background(Color.indigo.opacity(0.06))
                .cornerRadius(Radius.md)
                .padding(.horizontal, Spacing.xl)
            }

            Spacer()

            MusePrimaryButton("Start Playing", icon: "play.fill", action: onStart)
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.xl)
        }
    }
}

// MARK: - Exercise Phase

private struct ExercisePhaseView: View {
    let exercise: Exercise
    @ObservedObject var session: LessonSessionViewModel
    let lessonTitle: String

    var body: some View {
        VStack(spacing: 0) {

            // Top bar
            HStack {
                VStack(alignment: .leading) {
                    Text(lessonTitle)
                        .font(MuseFont.caption())
                        .foregroundColor(.secondary)
                    Text(exercise.title)
                        .font(MuseFont.headline())
                }
                Spacer()
                Text("Score: \(session.score)")
                    .font(MuseFont.headline())
                    .foregroundColor(.indigo)
            }
            .padding(Spacing.md)

            Divider()

            // Sheet music area
            SheetMusicView(
                exercise: exercise,
                currentNoteIndex: session.currentNoteIndex,
                feedback: session.lastFeedback
            )
            .frame(maxWidth: .infinity)
            .frame(height: 220)
            .padding(Spacing.md)

            Divider()

            // Microphone feedback
            MicFeedbackView(session: session, exercise: exercise)
                .padding(Spacing.lg)

            Spacer()
        }
    }
}

// MARK: - Microphone Feedback

private struct MicFeedbackView: View {
    @ObservedObject var session: LessonSessionViewModel
    let exercise: Exercise
    @StateObject private var pitchService = PitchDetectionService()

    private var currentNote: MusicalNote? {
        guard session.currentNoteIndex < exercise.notes.count else { return nil }
        return exercise.notes[session.currentNoteIndex]
    }

    var body: some View {
        VStack(spacing: Spacing.md) {
            if let note = currentNote {
                Text("Play this note:")
                    .font(MuseFont.caption())
                    .foregroundColor(.secondary)
                Text(note.displayName)
                    .font(MuseFont.display(48))
                    .foregroundColor(feedbackColor)
                    .animation(.spring(), value: session.lastFeedback)

                // Mic listening indicator
                HStack(spacing: Spacing.sm) {
                    Circle()
                        .fill(pitchService.isListening ? Color.red : Color.gray.opacity(0.4))
                        .frame(width: 10, height: 10)
                        .scaleEffect(pitchService.isListening ? 1.2 : 1.0)
                        .animation(.easeInOut(duration: 0.8).repeatForever(), value: pitchService.isListening)
                    Text(pitchService.isListening ? "Listening..." : "Tap to start mic")
                        .font(MuseFont.caption())
                        .foregroundColor(.secondary)
                }

                // Detected note
                if let result = pitchService.currentResult, let detectedNote = result.detectedNote {
                    Text("Detected: \(detectedNote.rawValue)\(result.detectedOctave ?? 0)")
                        .font(MuseFont.caption())
                        .foregroundColor(result.isAccurate ? .green : .orange)
                }

                // Manual tap fallback (for testing without instrument)
                HStack(spacing: Spacing.md) {
                    Button {
                        session.advanceNote(correct: false)
                    } label: {
                        Label("Skip", systemImage: "forward.fill")
                            .font(MuseFont.caption())
                            .padding(8)
                            .background(Color(.systemGray5))
                            .cornerRadius(Radius.sm)
                    }
                    .buttonStyle(.plain)

                    Button {
                        session.advanceNote(correct: true)
                    } label: {
                        Label("Got it!", systemImage: "checkmark")
                            .font(MuseFont.caption())
                            .foregroundColor(.white)
                            .padding(8)
                            .background(Color.green)
                            .cornerRadius(Radius.sm)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, Spacing.sm)

            } else {
                Text("Great work on this exercise!")
                    .font(MuseFont.headline())
                    .foregroundColor(.green)
            }
        }
        .onAppear {
            if let note = currentNote {
                pitchService.startListening(expecting: note)
            }
        }
        .onDisappear {
            pitchService.stopListening()
        }
        .onChange(of: session.currentNoteIndex) { _ in
            if let note = currentNote {
                pitchService.startListening(expecting: note)
            } else {
                pitchService.stopListening()
            }
        }
        .onChange(of: pitchService.currentResult?.isAccurate) { isAccurate in
            if isAccurate == true {
                session.advanceNote(correct: true)
            }
        }
    }

    private var feedbackColor: Color {
        switch session.lastFeedback {
        case .correct: return .green
        case .incorrect: return .red
        case .listening, .none: return .primary
        }
    }
}

// MARK: - Completion Phase

private struct CompletionPhaseView: View {
    let lesson: Lesson
    let score: Int
    let accuracy: Double
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: Spacing.xl) {
            Spacer()

            // Trophy
            Image(systemName: accuracy > 0.8 ? "trophy.fill" : "star.fill")
                .font(.system(size: 72, weight: .light))
                .foregroundColor(accuracy > 0.8 ? .yellow : .indigo)

            Text("Lesson Complete!")
                .font(MuseFont.display())

            // Score cards
            HStack(spacing: Spacing.md) {
                ResultCard(label: "Score", value: "\(score)", color: .indigo)
                ResultCard(label: "Accuracy", value: "\(Int(accuracy * 100))%",
                           color: accuracy > 0.8 ? .green : .orange)
                ResultCard(label: "XP Earned", value: "+\(lesson.xpReward)", color: .orange)
            }
            .padding(.horizontal, Spacing.xl)

            Spacer()

            MusePrimaryButton("Continue", icon: "arrow.right", action: onDone)
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.xl)
        }
    }
}

private struct ResultCard: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(MuseFont.title(22))
                .foregroundColor(color)
            Text(label)
                .font(MuseFont.caption(12))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.md)
        .background(color.opacity(0.08))
        .cornerRadius(Radius.md)
    }
}
