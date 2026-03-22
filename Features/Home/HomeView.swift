import SwiftUI

// MARK: - Main Tab View

struct MainTabView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var userProgress: UserProgressStore

    var body: some View {
        TabView {
            HomeView()
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }

            LessonListView()
                .tabItem {
                    Label("Lessons", systemImage: "book.fill")
                }

            ProgressView()
                .tabItem {
                    Label("Progress", systemImage: "chart.bar.fill")
                }

            AchievementsView()
                .tabItem {
                    Label("Awards", systemImage: "star.fill")
                }
        }
        .accentColor(.indigo)
    }
}

// MARK: - Home View

struct HomeView: View {
    @EnvironmentObject var userProgress: UserProgressStore
    @EnvironmentObject var appState: AppState

    private var nextLesson: Lesson? {
        let lessons = LessonCatalog.lessons(for: userProgress.selectedInstrument)
        return lessons.first { $0.isUnlocked && !userProgress.isLessonCompleted($0.id) }
            ?? lessons.first { $0.isUnlocked }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.lg) {

                    // Header
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Good \(timeOfDayGreeting)! 👋")
                                .font(MuseFont.caption())
                                .foregroundColor(.secondary)
                            Text("Keep the streak going")
                                .font(MuseFont.title())
                        }
                        Spacer()
                        StreakBadge(streak: userProgress.currentStreak)
                    }
                    .padding(.horizontal, Spacing.md)

                    // XP Progress Card
                    XPProgressCard()

                    // Daily Goal Card
                    DailyGoalCard()

                    // Continue Learning
                    if let lesson = nextLesson {
                        VStack(alignment: .leading, spacing: Spacing.sm) {
                            Text("Continue Learning")
                                .font(MuseFont.headline())
                                .padding(.horizontal, Spacing.md)
                            NavigationLink(destination: LessonDetailView(lesson: lesson)) {
                                ContinueLessonCard(lesson: lesson)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Quick instrument switch
                    InstrumentSwitchBar()

                    Spacer(minLength: Spacing.xl)
                }
                .padding(.top, Spacing.md)
            }
            .navigationTitle("MuseLearn")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
        }
    }

    private var timeOfDayGreeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "morning"
        case 12..<17: return "afternoon"
        default: return "evening"
        }
    }
}

// MARK: - XP Progress Card

private struct XPProgressCard: View {
    @EnvironmentObject var userProgress: UserProgressStore

    var body: some View {
        MuseCard {
            VStack(spacing: Spacing.md) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Level \(userProgress.currentLevel)")
                            .font(MuseFont.title())
                        Text(userProgress.currentSkillLevel.rawValue)
                            .font(MuseFont.caption())
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(userProgress.totalXP) XP")
                            .font(MuseFont.headline())
                            .foregroundColor(.indigo)
                        Text("\(userProgress.xpToNextLevel) to next level")
                            .font(MuseFont.caption(12))
                            .foregroundColor(.secondary)
                    }
                }

                // Progress bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.indigo.opacity(0.1))
                            .frame(height: 8)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(
                                LinearGradient(colors: [.indigo, .purple],
                                               startPoint: .leading, endPoint: .trailing)
                            )
                            .frame(width: geo.size.width * userProgress.levelProgress, height: 8)
                            .animation(.spring(), value: userProgress.levelProgress)
                    }
                }
                .frame(height: 8)
            }
            .padding(Spacing.md)
        }
        .padding(.horizontal, Spacing.md)
    }
}

// MARK: - Daily Goal Card

private struct DailyGoalCard: View {
    @EnvironmentObject var userProgress: UserProgressStore

    var body: some View {
        MuseCard {
            HStack(spacing: Spacing.md) {
                ZStack {
                    Circle()
                        .stroke(Color.orange.opacity(0.2), lineWidth: 4)
                        .frame(width: 52, height: 52)
                    Circle()
                        .trim(from: 0, to: userProgress.dailyGoalProgress)
                        .stroke(Color.orange, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 52, height: 52)
                        .animation(.spring(), value: userProgress.dailyGoalProgress)
                    Image(systemName: "bolt.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 16, weight: .bold))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Daily Goal")
                        .font(MuseFont.headline())
                    Text("\(userProgress.todayXP) / \(userProgress.dailyXPGoal) XP earned today")
                        .font(MuseFont.body(14))
                        .foregroundColor(.secondary)
                }
                Spacer()

                if userProgress.dailyGoalProgress >= 1.0 {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 24))
                }
            }
            .padding(Spacing.md)
        }
        .padding(.horizontal, Spacing.md)
    }
}

// MARK: - Continue Lesson Card

private struct ContinueLessonCard: View {
    let lesson: Lesson

    var body: some View {
        MuseCard {
            HStack(spacing: Spacing.md) {
                RoundedRectangle(cornerRadius: Radius.md)
                    .fill(Color.indigo.opacity(0.1))
                    .frame(width: 60, height: 60)
                    .overlay(
                        Image(systemName: lesson.instrument.icon)
                            .font(.system(size: 26, weight: .medium))
                            .foregroundColor(.indigo)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(lesson.title)
                        .font(MuseFont.headline())
                        .foregroundColor(.primary)
                    Text(lesson.subtitle)
                        .font(MuseFont.body(14))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    HStack(spacing: Spacing.sm) {
                        XPBadge(amount: lesson.xpReward)
                        Text("~\(lesson.estimatedMinutes) min")
                            .font(MuseFont.caption(12))
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
            }
            .padding(Spacing.md)
        }
        .padding(.horizontal, Spacing.md)
    }
}

// MARK: - Instrument Switch Bar

private struct InstrumentSwitchBar: View {
    @EnvironmentObject var userProgress: UserProgressStore

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Instruments")
                .font(MuseFont.headline())
                .padding(.horizontal, Spacing.md)

            HStack(spacing: Spacing.sm) {
                ForEach(Instrument.allCases) { instrument in
                    Button {
                        userProgress.selectedInstrument = instrument
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: instrument.icon)
                            Text(instrument.rawValue)
                                .font(MuseFont.caption())
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 14)
                        .background(
                            userProgress.selectedInstrument == instrument
                            ? Color.indigo
                            : Color(.systemGray6)
                        )
                        .foregroundColor(
                            userProgress.selectedInstrument == instrument ? .white : .primary
                        )
                        .cornerRadius(Radius.full)
                    }
                    .buttonStyle(.plain)
                    .animation(.spring(response: 0.3), value: userProgress.selectedInstrument)
                }
            }
            .padding(.horizontal, Spacing.md)
        }
    }
}
