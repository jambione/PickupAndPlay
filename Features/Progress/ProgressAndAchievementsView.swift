import SwiftUI

// MARK: - Progress View

struct ProgressView: View {
    @EnvironmentObject var userProgress: UserProgressStore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.lg) {

                    // Level + XP
                    MuseCard {
                        VStack(spacing: Spacing.md) {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text("Level \(userProgress.currentLevel)")
                                        .font(MuseFont.display(32))
                                    Text(userProgress.currentSkillLevel.rawValue)
                                        .font(MuseFont.body())
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                ZStack {
                                    Circle()
                                        .stroke(Color.indigo.opacity(0.2), lineWidth: 5)
                                        .frame(width: 70, height: 70)
                                    Circle()
                                        .trim(from: 0, to: userProgress.levelProgress)
                                        .stroke(Color.indigo,
                                                style: StrokeStyle(lineWidth: 5, lineCap: .round))
                                        .rotationEffect(.degrees(-90))
                                        .frame(width: 70, height: 70)
                                        .animation(.spring(), value: userProgress.levelProgress)
                                    Text("\(Int(userProgress.levelProgress * 100))%")
                                        .font(MuseFont.caption(12))
                                        .foregroundColor(.indigo)
                                }
                            }

                            HStack {
                                Text("\(userProgress.totalXP) XP total")
                                    .font(MuseFont.headline())
                                Spacer()
                                Text("\(userProgress.xpToNextLevel) XP to Level \(userProgress.currentLevel + 1)")
                                    .font(MuseFont.caption())
                                    .foregroundColor(.secondary)
                            }

                            ProgressBarView(value: userProgress.levelProgress)
                        }
                        .padding(Spacing.md)
                    }
                    .padding(.horizontal, Spacing.md)

                    // Stats grid
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                              spacing: Spacing.md) {
                        StatTile(icon: "flame.fill", color: .orange,
                                 label: "Current Streak",
                                 value: "\(userProgress.currentStreak) days")
                        StatTile(icon: "trophy.fill", color: .yellow,
                                 label: "Longest Streak",
                                 value: "\(userProgress.longestStreak) days")
                        StatTile(icon: "checkmark.circle.fill", color: .green,
                                 label: "Lessons Done",
                                 value: "\(userProgress.completedLessonIDs.count)")
                        StatTile(icon: "bolt.fill", color: .indigo,
                                 label: "Today's XP",
                                 value: "\(userProgress.todayXP)")
                    }
                    .padding(.horizontal, Spacing.md)

                    // Per-instrument progress
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Text("Instrument Progress")
                            .font(MuseFont.headline())
                            .padding(.horizontal, Spacing.md)

                        ForEach(Instrument.allCases) { instrument in
                            InstrumentProgressCard(instrument: instrument)
                        }
                    }

                    Spacer(minLength: Spacing.xl)
                }
                .padding(.top, Spacing.md)
            }
            .navigationTitle("Your Progress")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
        }
    }
}

private struct ProgressBarView: View {
    let value: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.indigo.opacity(0.1))
                    .frame(height: 8)
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(colors: [.indigo, .purple],
                                        startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * value, height: 8)
            }
        }
        .frame(height: 8)
    }
}

private struct StatTile: View {
    let icon: String
    let color: Color
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(color)
            Text(value)
                .font(MuseFont.title(22))
            Text(label)
                .font(MuseFont.caption(12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(Spacing.md)
        .background(Color(UIColor.systemBackground))
        .cornerRadius(Radius.lg)
        .shadow(color: .black.opacity(0.05), radius: 5)
    }
}

private struct InstrumentProgressCard: View {
    @EnvironmentObject var userProgress: UserProgressStore
    let instrument: Instrument

    private var lessons: [Lesson] { LessonCatalog.lessons(for: instrument) }
    private var completedCount: Int {
        lessons.filter { userProgress.isLessonCompleted($0.id) }.count
    }
    private var progress: Double {
        guard !lessons.isEmpty else { return 0 }
        return Double(completedCount) / Double(lessons.count)
    }

    var body: some View {
        MuseCard {
            HStack(spacing: Spacing.md) {
                Image(systemName: instrument.icon)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(.indigo)
                    .frame(width: 44, height: 44)
                    .background(Color.indigo.opacity(0.1))
                    .cornerRadius(Radius.md)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(instrument.rawValue)
                            .font(MuseFont.headline())
                        Spacer()
                        Text("\(completedCount)/\(lessons.count) lessons")
                            .font(MuseFont.caption(12))
                            .foregroundColor(.secondary)
                    }
                    ProgressBarView(value: progress)
                }
            }
            .padding(Spacing.md)
        }
        .padding(.horizontal, Spacing.md)
    }
}

// MARK: - Achievements View

struct AchievementsView: View {
    @EnvironmentObject var userProgress: UserProgressStore

    private var unlockedAchievements: [Achievement] {
        userProgress.achievements.filter { $0.isUnlocked }
    }
    private var lockedAchievements: [Achievement] {
        userProgress.achievements.filter { !$0.isUnlocked }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.lg) {

                    // Summary
                    HStack(spacing: Spacing.lg) {
                        VStack(spacing: 4) {
                            Text("\(unlockedAchievements.count)")
                                .font(MuseFont.display(32))
                                .foregroundColor(.indigo)
                            Text("Unlocked")
                                .font(MuseFont.caption())
                                .foregroundColor(.secondary)
                        }
                        Divider().frame(height: 48)
                        VStack(spacing: 4) {
                            Text("\(userProgress.achievements.count)")
                                .font(MuseFont.display(32))
                            Text("Total")
                                .font(MuseFont.caption())
                                .foregroundColor(.secondary)
                        }
                        Divider().frame(height: 48)
                        VStack(spacing: 4) {
                            Text("\(unlockedAchievements.map(\.xpReward).reduce(0, +))")
                                .font(MuseFont.display(32))
                                .foregroundColor(.orange)
                            Text("XP Earned")
                                .font(MuseFont.caption())
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(Spacing.md)
                    .background(Color(UIColor.systemBackground))
                    .cornerRadius(Radius.lg)
                    .shadow(color: .black.opacity(0.05), radius: 5)
                    .padding(.horizontal, Spacing.md)

                    // Unlocked
                    if !unlockedAchievements.isEmpty {
                        AchievementSection(title: "Unlocked 🏆", achievements: unlockedAchievements)
                    }

                    // Locked
                    if !lockedAchievements.isEmpty {
                        AchievementSection(title: "Coming Up", achievements: lockedAchievements)
                    }

                    Spacer(minLength: Spacing.xl)
                }
                .padding(.top, Spacing.md)
            }
            .navigationTitle("Achievements")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
        }
    }
}

private struct AchievementSection: View {
    let title: String
    let achievements: [Achievement]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(title)
                .font(MuseFont.headline())
                .padding(.horizontal, Spacing.md)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                      spacing: Spacing.md) {
                ForEach(achievements) { achievement in
                    AchievementCard(achievement: achievement)
                }
            }
            .padding(.horizontal, Spacing.md)
        }
    }
}

private struct AchievementCard: View {
    let achievement: Achievement

    var body: some View {
        VStack(spacing: Spacing.sm) {
            ZStack {
                Circle()
                    .fill(achievement.isUnlocked ? Color.indigo.opacity(0.1) : Color.gray.opacity(0.08))
                    .frame(width: 56, height: 56)
                Image(systemName: achievement.iconName)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(achievement.isUnlocked ? .indigo : .gray.opacity(0.5))
            }

            Text(achievement.title)
                .font(MuseFont.headline(14))
                .multilineTextAlignment(.center)
                .foregroundColor(achievement.isUnlocked ? .primary : .secondary)

            Text(achievement.description)
                .font(MuseFont.caption(11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)

            XPBadge(amount: achievement.xpReward)
                .opacity(achievement.isUnlocked ? 1 : 0.4)

            if let date = achievement.unlockedDate {
                Text(date, style: .date)
                    .font(MuseFont.caption(10))
                    .foregroundColor(.secondary)
            }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Radius.lg)
                .fill(Color(UIColor.systemBackground))
                .shadow(color: achievement.isUnlocked ? .indigo.opacity(0.1) : .black.opacity(0.04),
                        radius: 6)
        )
    }
}
