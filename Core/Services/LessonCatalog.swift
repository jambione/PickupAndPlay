import Foundation

struct LessonCatalog {

    static func lessons(for instrument: Instrument) -> [Lesson] {
        switch instrument {
        case .piano: return pianoLessons
        case .guitar: return guitarLessons
        }
    }

    // MARK: - Piano Lessons

    static let pianoLessons: [Lesson] = [
        Lesson(
            title: "Meet the Keys",
            subtitle: "Learn where C, D, E are on the keyboard",
            instrument: .piano,
            skillLevel: .beginner,
            xpReward: 30,
            estimatedMinutes: 5,
            exercises: [
                Exercise(title: "Play Middle C", type: .noteReading,
                         notes: [MusicalNote(pitch: .C, octave: 4, duration: .whole)], tempo: 60),
                Exercise(title: "C–D–E in Order", type: .melody,
                         notes: [
                            MusicalNote(pitch: .C, octave: 4, duration: .quarter, beatPosition: 0),
                            MusicalNote(pitch: .D, octave: 4, duration: .quarter, beatPosition: 1),
                            MusicalNote(pitch: .E, octave: 4, duration: .quarter, beatPosition: 2)
                         ], tempo: 60)
            ],
            isUnlocked: true
        ),
        Lesson(
            title: "Reading the Staff",
            subtitle: "Understand treble clef lines and spaces",
            instrument: .piano,
            skillLevel: .beginner,
            xpReward: 40,
            estimatedMinutes: 8,
            exercises: [
                Exercise(title: "Every Good Boy — E G B D F", type: .noteReading,
                         notes: [
                            MusicalNote(pitch: .E, octave: 4, duration: .quarter, beatPosition: 0),
                            MusicalNote(pitch: .G, octave: 4, duration: .quarter, beatPosition: 1),
                            MusicalNote(pitch: .B, octave: 4, duration: .quarter, beatPosition: 2),
                            MusicalNote(pitch: .D, octave: 5, duration: .quarter, beatPosition: 3)
                         ], tempo: 70)
            ],
            isUnlocked: false
        ),
        Lesson(
            title: "C Major Scale",
            subtitle: "Play your first complete scale",
            instrument: .piano,
            skillLevel: .beginner,
            xpReward: 60,
            estimatedMinutes: 10,
            exercises: [
                Exercise(title: "C Major Ascending", type: .scale,
                         notes: NotePitch.allCases.filter { $0.isNatural }.prefix(8).enumerated().map { i, pitch in
                            MusicalNote(pitch: pitch, octave: i < 7 ? 4 : 5, duration: .quarter, beatPosition: Double(i % 4))
                         }, tempo: 80)
            ],
            isUnlocked: false
        ),
        Lesson(
            title: "Quarter & Half Notes",
            subtitle: "Feel the pulse of music",
            instrument: .piano,
            skillLevel: .beginner,
            xpReward: 50,
            estimatedMinutes: 8,
            exercises: [
                Exercise(title: "Clap the Rhythm", type: .rhythm,
                         notes: [
                            MusicalNote(pitch: .C, octave: 4, duration: .quarter, beatPosition: 0),
                            MusicalNote(pitch: .C, octave: 4, duration: .half, beatPosition: 1),
                            MusicalNote(pitch: .C, octave: 4, duration: .quarter, beatPosition: 3)
                         ], tempo: 70)
            ],
            isUnlocked: false
        ),
        Lesson(
            title: "Simple Melody: Ode to Joy",
            subtitle: "Put it all together with a real song",
            instrument: .piano,
            skillLevel: .beginner,
            xpReward: 80,
            estimatedMinutes: 12,
            exercises: [],
            isUnlocked: false
        ),

        // Early Intermediate
        Lesson(
            title: "Introducing the Bass Clef",
            subtitle: "Read the left hand staff",
            instrument: .piano,
            skillLevel: .earlyIntermediate,
            xpReward: 70,
            estimatedMinutes: 10,
            exercises: [],
            isUnlocked: false
        ),
        Lesson(
            title: "G Major Scale",
            subtitle: "One sharp — F#",
            instrument: .piano,
            skillLevel: .earlyIntermediate,
            xpReward: 70,
            estimatedMinutes: 10,
            exercises: [],
            isUnlocked: false
        ),
        Lesson(
            title: "Basic Hand Coordination",
            subtitle: "Both hands together for the first time",
            instrument: .piano,
            skillLevel: .earlyIntermediate,
            xpReward: 100,
            estimatedMinutes: 15,
            exercises: [],
            isUnlocked: false
        )
    ]

    // MARK: - Guitar Lessons

    static let guitarLessons: [Lesson] = [
        Lesson(
            title: "Parts of the Guitar",
            subtitle: "Neck, frets, strings — the basics",
            instrument: .guitar,
            skillLevel: .beginner,
            xpReward: 20,
            estimatedMinutes: 5,
            exercises: [],
            isUnlocked: true
        ),
        Lesson(
            title: "Open Strings",
            subtitle: "E A D G B e — tune and play",
            instrument: .guitar,
            skillLevel: .beginner,
            xpReward: 30,
            estimatedMinutes: 7,
            exercises: [
                Exercise(title: "Play Low E String", type: .noteReading,
                         notes: [MusicalNote(pitch: .E, octave: 2, duration: .whole)], tempo: 60),
                Exercise(title: "All Open Strings", type: .melody,
                         notes: [
                            MusicalNote(pitch: .E, octave: 2, duration: .quarter, beatPosition: 0),
                            MusicalNote(pitch: .A, octave: 2, duration: .quarter, beatPosition: 1),
                            MusicalNote(pitch: .D, octave: 3, duration: .quarter, beatPosition: 2),
                            MusicalNote(pitch: .G, octave: 3, duration: .quarter, beatPosition: 3)
                         ], tempo: 60)
            ],
            isUnlocked: true
        ),
        Lesson(
            title: "Reading Guitar Tab",
            subtitle: "Understand the 6-line tablature system",
            instrument: .guitar,
            skillLevel: .beginner,
            xpReward: 40,
            estimatedMinutes: 8,
            exercises: [],
            isUnlocked: false
        ),
        Lesson(
            title: "First Notes: E F G",
            subtitle: "Play notes on the first two frets",
            instrument: .guitar,
            skillLevel: .beginner,
            xpReward: 50,
            estimatedMinutes: 10,
            exercises: [],
            isUnlocked: false
        ),
        Lesson(
            title: "E Minor Scale",
            subtitle: "The most natural scale on guitar",
            instrument: .guitar,
            skillLevel: .beginner,
            xpReward: 60,
            estimatedMinutes: 10,
            exercises: [],
            isUnlocked: false
        ),

        // Early Intermediate
        Lesson(
            title: "Em and Am Chords",
            subtitle: "Your first two chords",
            instrument: .guitar,
            skillLevel: .earlyIntermediate,
            xpReward: 70,
            estimatedMinutes: 12,
            exercises: [],
            isUnlocked: false
        ),
        Lesson(
            title: "Chord Transitions",
            subtitle: "Smoothly switch between Em and Am",
            instrument: .guitar,
            skillLevel: .earlyIntermediate,
            xpReward: 80,
            estimatedMinutes: 12,
            exercises: [],
            isUnlocked: false
        )
    ]
}

// MARK: - Achievements catalog

extension Achievement {
    static let allAchievements: [Achievement] = [
        Achievement(
            title: "First Note",
            description: "Complete your very first lesson",
            iconName: "music.note",
            xpReward: 20,
            requirement: .lessonsCompleted(count: 1)
        ),
        Achievement(
            title: "On a Roll",
            description: "Complete 5 lessons",
            iconName: "star.fill",
            xpReward: 50,
            requirement: .lessonsCompleted(count: 5)
        ),
        Achievement(
            title: "Century Club",
            description: "Earn 100 XP",
            iconName: "bolt.fill",
            xpReward: 30,
            requirement: .xpEarned(amount: 100)
        ),
        Achievement(
            title: "Dedicated",
            description: "Practice 3 days in a row",
            iconName: "flame.fill",
            xpReward: 40,
            requirement: .streakDays(count: 3)
        ),
        Achievement(
            title: "Week Warrior",
            description: "Maintain a 7-day streak",
            iconName: "calendar",
            xpReward: 100,
            requirement: .streakDays(count: 7)
        ),
        Achievement(
            title: "Perfectionist",
            description: "Complete a lesson with 100% accuracy",
            iconName: "checkmark.seal.fill",
            xpReward: 75,
            requirement: .perfectLesson
        ),
        Achievement(
            title: "Rising Star",
            description: "Earn 500 XP total",
            iconName: "star.circle.fill",
            xpReward: 100,
            requirement: .xpEarned(amount: 500)
        )
    ]
}
