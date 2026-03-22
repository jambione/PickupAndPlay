import Foundation
import Combine

class UserProgressStore: ObservableObject {

    // MARK: - Published Properties

    @Published var totalXP: Int = 0
    @Published var currentStreak: Int = 0
    @Published var longestStreak: Int = 0
    @Published var lastPracticeDate: Date? = nil
    @Published var completedLessonIDs: Set<UUID> = []
    @Published var achievements: [Achievement] = Achievement.allAchievements
    @Published var selectedInstrument: Instrument = .piano
    @Published var dailyXPGoal: Int = 100
    @Published var todayXP: Int = 0

    // MARK: - Computed Properties

    var currentLevel: Int {
        max(1, totalXP / 100)
    }

    var xpToNextLevel: Int {
        100 - (totalXP % 100)
    }

    var levelProgress: Double {
        Double(totalXP % 100) / 100.0
    }

    var currentSkillLevel: SkillLevel {
        switch totalXP {
        case 0..<500: return .beginner
        case 500..<1500: return .earlyIntermediate
        default: return .intermediate
        }
    }

    var dailyGoalProgress: Double {
        min(1.0, Double(todayXP) / Double(dailyXPGoal))
    }

    var streakIsActiveToday: Bool {
        guard let last = lastPracticeDate else { return false }
        return Calendar.current.isDateInToday(last)
    }

    // MARK: - Init

    init() {
        loadProgress()
        checkStreakValidity()
    }

    // MARK: - Actions

    func awardXP(_ amount: Int, for lessonID: UUID? = nil) {
        totalXP += amount
        todayXP += amount

        if let id = lessonID {
            completedLessonIDs.insert(id)
        }

        updateStreak()
        checkAchievements()
        saveProgress()
    }

    func markPracticed() {
        let today = Calendar.current.startOfDay(for: Date())
        if let last = lastPracticeDate {
            let lastDay = Calendar.current.startOfDay(for: last)
            let diff = Calendar.current.dateComponents([.day], from: lastDay, to: today).day ?? 0
            if diff == 1 {
                currentStreak += 1
            } else if diff > 1 {
                currentStreak = 1
            }
            // diff == 0 means already practiced today, no change
        } else {
            currentStreak = 1
        }
        longestStreak = max(longestStreak, currentStreak)
        lastPracticeDate = Date()
        saveProgress()
    }

    func isLessonCompleted(_ lessonID: UUID) -> Bool {
        completedLessonIDs.contains(lessonID)
    }

    // MARK: - Private

    private func updateStreak() {
        guard let last = lastPracticeDate else {
            currentStreak = 1
            lastPracticeDate = Date()
            return
        }
        if !Calendar.current.isDateInToday(last) {
            markPracticed()
        }
    }

    private func checkStreakValidity() {
        guard let last = lastPracticeDate else { return }
        let daysSince = Calendar.current.dateComponents([.day], from: last, to: Date()).day ?? 0
        if daysSince > 1 {
            currentStreak = 0
        }
    }

    private func checkAchievements() {
        for i in achievements.indices {
            guard !achievements[i].isUnlocked else { continue }
            let unlock: Bool
            switch achievements[i].requirement {
            case .lessonsCompleted(let count):
                unlock = completedLessonIDs.count >= count
            case .xpEarned(let amount):
                unlock = totalXP >= amount
            case .streakDays(let count):
                unlock = currentStreak >= count
            case .perfectLesson:
                unlock = false // handled separately during lesson completion
            case .instrumentMastery:
                unlock = false // future logic
            }
            if unlock {
                achievements[i].isUnlocked = true
                achievements[i].unlockedDate = Date()
            }
        }
    }

    // MARK: - Persistence

    private let progressKey = "userProgress_v1"

    private func saveProgress() {
        let data: [String: Any] = [
            "totalXP": totalXP,
            "currentStreak": currentStreak,
            "longestStreak": longestStreak,
            "todayXP": todayXP,
            "lastPracticeDate": lastPracticeDate?.timeIntervalSince1970 ?? 0,
            "completedLessonIDs": completedLessonIDs.map { $0.uuidString },
            "selectedInstrument": selectedInstrument.rawValue
        ]
        UserDefaults.standard.set(data, forKey: progressKey)
    }

    private func loadProgress() {
        guard let data = UserDefaults.standard.dictionary(forKey: progressKey) else { return }
        totalXP = data["totalXP"] as? Int ?? 0
        currentStreak = data["currentStreak"] as? Int ?? 0
        longestStreak = data["longestStreak"] as? Int ?? 0
        todayXP = data["todayXP"] as? Int ?? 0
        if let ts = data["lastPracticeDate"] as? Double, ts > 0 {
            lastPracticeDate = Date(timeIntervalSince1970: ts)
        }
        if let ids = data["completedLessonIDs"] as? [String] {
            completedLessonIDs = Set(ids.compactMap { UUID(uuidString: $0) })
        }
        if let inst = data["selectedInstrument"] as? String,
           let instrument = Instrument(rawValue: inst) {
            selectedInstrument = instrument
        }
    }
}
