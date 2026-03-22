import SwiftUI

// MARK: - Lesson List View

struct LessonListView: View {
    @EnvironmentObject var userProgress: UserProgressStore

    private var lessons: [Lesson] {
        LessonCatalog.lessons(for: userProgress.selectedInstrument)
    }

    private var groupedLessons: [(SkillLevel, [Lesson])] {
        let levels: [SkillLevel] = [.beginner, .earlyIntermediate, .intermediate]
        return levels.compactMap { level in
            let filtered = lessons.filter { $0.skillLevel == level }
            return filtered.isEmpty ? nil : (level, filtered)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.xl) {
                    ForEach(groupedLessons, id: \.0) { level, levelLessons in
                        LessonSection(level: level, lessons: levelLessons)
                    }
                }
                .padding(.vertical, Spacing.md)
            }
            .navigationTitle("Lessons")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Picker("Instrument", selection: Binding(
                        get: { userProgress.selectedInstrument },
                        set: { userProgress.selectedInstrument = $0 }
                    )) {
                        ForEach(Instrument.allCases) { instrument in
                            Text(instrument.rawValue).tag(instrument)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }
            }
        }
    }
}

// MARK: - Lesson Section

private struct LessonSection: View {
    let level: SkillLevel
    let lessons: [Lesson]
    @EnvironmentObject var userProgress: UserProgressStore

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                Text(level.rawValue)
                    .font(MuseFont.title(20))
                Spacer()
                Text("\(completedCount)/\(lessons.count)")
                    .font(MuseFont.caption())
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, Spacing.md)

            ForEach(lessons) { lesson in
                LessonRow(lesson: lesson)
            }
        }
    }

    private var completedCount: Int {
        lessons.filter { userProgress.isLessonCompleted($0.id) }.count
    }
}

// MARK: - Lesson Row

private struct LessonRow: View {
    let lesson: Lesson
    @EnvironmentObject var userProgress: UserProgressStore

    private var isCompleted: Bool { userProgress.isLessonCompleted(lesson.id) }
    private var isLocked: Bool { !lesson.isUnlocked }

    var body: some View {
        NavigationLink(destination: LessonDetailView(lesson: lesson)) {
            HStack(spacing: Spacing.md) {

                // Status icon
                ZStack {
                    Circle()
                        .fill(statusColor.opacity(0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: statusIcon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(statusColor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(lesson.title)
                        .font(MuseFont.headline())
                        .foregroundColor(isLocked ? .secondary : .primary)
                    Text(lesson.subtitle)
                        .font(MuseFont.body(14))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    HStack(spacing: Spacing.sm) {
                        DifficultyDots(level: lesson.skillLevel)
                        Text("·")
                            .foregroundColor(.secondary)
                        Text("\(lesson.estimatedMinutes) min")
                            .font(MuseFont.caption(12))
                            .foregroundColor(.secondary)
                        XPBadge(amount: lesson.xpReward)
                    }
                }
                Spacer()
                if !isLocked {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 12)
            .background(Color(.systemBackground))
        }
        .disabled(isLocked)
        .buttonStyle(.plain)
        .overlay(
            Rectangle()
                .fill(Color(.separator).opacity(0.5))
                .frame(height: 0.5),
            alignment: .bottom
        )
    }

    private var statusIcon: String {
        if isCompleted { return "checkmark" }
        if isLocked { return "lock.fill" }
        return "play.fill"
    }

    private var statusColor: Color {
        if isCompleted { return .green }
        if isLocked { return .gray }
        return .indigo
    }
}

// MARK: - Lesson Detail View

struct LessonDetailView: View {
    let lesson: Lesson
    @EnvironmentObject var userProgress: UserProgressStore
    @State private var showLesson = false

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.xl) {

                // Hero
                VStack(spacing: Spacing.md) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(colors: [.indigo.opacity(0.15), .purple.opacity(0.1)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                            .frame(width: 100, height: 100)
                        Image(systemName: lesson.instrument.icon)
                            .font(.system(size: 44, weight: .light))
                            .foregroundColor(.indigo)
                    }

                    Text(lesson.title)
                        .font(MuseFont.display(28))
                        .multilineTextAlignment(.center)

                    Text(lesson.subtitle)
                        .font(MuseFont.body())
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, Spacing.lg)

                // Stats row
                HStack(spacing: 0) {
                    StatCell(icon: "bolt.fill", color: .orange,
                             label: "XP Reward", value: "+\(lesson.xpReward)")
                    Divider().frame(height: 40)
                    StatCell(icon: "clock.fill", color: .blue,
                             label: "Est. Time", value: "\(lesson.estimatedMinutes)m")
                    Divider().frame(height: 40)
                    StatCell(icon: "music.note", color: .indigo,
                             label: "Exercises", value: "\(lesson.exercises.count)")
                }
                .padding(.horizontal, Spacing.md)
                .background(Color(.systemBackground))
                .cornerRadius(Radius.lg)
                .shadow(color: .black.opacity(0.05), radius: 6)
                .padding(.horizontal, Spacing.md)

                // Exercises list
                if !lesson.exercises.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Text("What You'll Practice")
                            .font(MuseFont.headline())
                            .padding(.horizontal, Spacing.md)

                        ForEach(lesson.exercises.indices, id: \.self) { i in
                            HStack(spacing: Spacing.md) {
                                Text("\(i + 1)")
                                    .font(MuseFont.mono())
                                    .foregroundColor(.white)
                                    .frame(width: 28, height: 28)
                                    .background(Color.indigo)
                                    .cornerRadius(Radius.full)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(lesson.exercises[i].title)
                                        .font(MuseFont.headline(15))
                                    Text(lesson.exercises[i].type.rawValue)
                                        .font(MuseFont.caption())
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Text("\(lesson.exercises[i].tempo) BPM")
                                    .font(MuseFont.caption(12))
                                    .foregroundColor(.secondary)
                            }
                            .padding(Spacing.md)
                            .background(Color(.systemBackground))
                            .cornerRadius(Radius.md)
                            .shadow(color: .black.opacity(0.04), radius: 4)
                            .padding(.horizontal, Spacing.md)
                        }
                    }
                }

                // Start button
                MusePrimaryButton(
                    userProgress.isLessonCompleted(lesson.id) ? "Practice Again" : "Start Lesson",
                    icon: "play.fill"
                ) {
                    showLesson = true
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.xl)
            }
        }
        .navigationTitle(lesson.instrument.rawValue)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .fullScreenCover(isPresented: $showLesson) {
            LessonSessionView(lesson: lesson)
        }
    }
}

// MARK: - Stat Cell

private struct StatCell: View {
    let icon: String
    let color: Color
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.system(size: 16, weight: .semibold))
            Text(value)
                .font(MuseFont.headline())
            Text(label)
                .font(MuseFont.caption(11))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.md)
    }
}
