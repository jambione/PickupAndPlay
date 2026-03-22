import Foundation
import SwiftUI

// MARK: - Instrument

enum Instrument: String, CaseIterable, Codable, Identifiable {
    case piano = "Piano"
    case guitar = "Guitar"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .piano: return "pianokeys"
        case .guitar: return "guitars"
        }
    }

    var description: String {
        switch self {
        case .piano: return "Learn to read sheet music and play melodies on piano"
        case .guitar: return "Master chords, scales, and melodies on guitar"
        }
    }
}

// MARK: - Skill Level

enum SkillLevel: String, CaseIterable, Codable {
    case beginner = "Beginner"
    case earlyIntermediate = "Early Intermediate"
    case intermediate = "Intermediate"

    var xpRequired: Int {
        switch self {
        case .beginner: return 0
        case .earlyIntermediate: return 500
        case .intermediate: return 1500
        }
    }
}

// MARK: - Lesson

struct Lesson: Identifiable, Codable {
    let id: UUID
    let title: String
    let subtitle: String
    let instrument: Instrument
    let skillLevel: SkillLevel
    let xpReward: Int
    let estimatedMinutes: Int
    let exercises: [Exercise]
    var isUnlocked: Bool
    var isCompleted: Bool

    init(
        id: UUID = UUID(),
        title: String,
        subtitle: String,
        instrument: Instrument,
        skillLevel: SkillLevel,
        xpReward: Int = 50,
        estimatedMinutes: Int = 10,
        exercises: [Exercise] = [],
        isUnlocked: Bool = false,
        isCompleted: Bool = false
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.instrument = instrument
        self.skillLevel = skillLevel
        self.xpReward = xpReward
        self.estimatedMinutes = estimatedMinutes
        self.exercises = exercises
        self.isUnlocked = isUnlocked
        self.isCompleted = isCompleted
    }
}

// MARK: - Exercise

struct Exercise: Identifiable, Codable {
    let id: UUID
    let title: String
    let type: ExerciseType
    let notes: [MusicalNote]
    let tempo: Int // BPM
    let timeSignature: TimeSignature

    enum ExerciseType: String, Codable {
        case noteReading = "Note Reading"
        case rhythm = "Rhythm"
        case melody = "Melody"
        case scale = "Scale"
    }

    init(
        id: UUID = UUID(),
        title: String,
        type: ExerciseType,
        notes: [MusicalNote] = [],
        tempo: Int = 80,
        timeSignature: TimeSignature = .fourFour
    ) {
        self.id = id
        self.title = title
        self.type = type
        self.notes = notes
        self.tempo = tempo
        self.timeSignature = timeSignature
    }
}

// MARK: - Musical Note

struct MusicalNote: Identifiable, Codable {
    let id: UUID
    let pitch: NotePitch
    let octave: Int
    let duration: NoteDuration
    let beatPosition: Double // position within the measure (0.0 = beat 1)

    var frequency: Double {
        // A4 = 440 Hz, calculate relative frequency
        let semitones = Double(pitch.semitoneOffset) + Double((octave - 4) * 12)
        return 440.0 * pow(2.0, semitones / 12.0)
    }

    var displayName: String {
        "\(pitch.rawValue)\(octave)"
    }

    init(
        id: UUID = UUID(),
        pitch: NotePitch,
        octave: Int = 4,
        duration: NoteDuration = .quarter,
        beatPosition: Double = 0.0
    ) {
        self.id = id
        self.pitch = pitch
        self.octave = octave
        self.duration = duration
        self.beatPosition = beatPosition
    }
}

enum NotePitch: String, Codable, CaseIterable {
    case C, CSharp = "C#", D, DSharp = "D#", E, F, FSharp = "F#", G, GSharp = "G#", A, ASharp = "A#", B

    var semitoneOffset: Int {
        switch self {
        case .C: return -9
        case .CSharp: return -8
        case .D: return -7
        case .DSharp: return -6
        case .E: return -5
        case .F: return -4
        case .FSharp: return -3
        case .G: return -2
        case .GSharp: return -1
        case .A: return 0
        case .ASharp: return 1
        case .B: return 2
        }
    }

    var isNatural: Bool {
        !rawValue.contains("#")
    }
}

enum NoteDuration: String, Codable {
    case whole = "whole"
    case half = "half"
    case quarter = "quarter"
    case eighth = "eighth"
    case sixteenth = "sixteenth"

    var beats: Double {
        switch self {
        case .whole: return 4.0
        case .half: return 2.0
        case .quarter: return 1.0
        case .eighth: return 0.5
        case .sixteenth: return 0.25
        }
    }
}

enum TimeSignature: String, Codable {
    case fourFour = "4/4"
    case threeFour = "3/4"
    case twoFour = "2/4"
    case sixEight = "6/8"

    var beatsPerMeasure: Int {
        switch self {
        case .fourFour: return 4
        case .threeFour: return 3
        case .twoFour: return 2
        case .sixEight: return 6
        }
    }
}

// MARK: - Achievement

struct Achievement: Identifiable, Codable {
    let id: UUID
    let title: String
    let description: String
    let iconName: String
    let xpReward: Int
    let requirement: AchievementRequirement
    var isUnlocked: Bool
    var unlockedDate: Date?

    enum AchievementRequirement: Codable {
        case lessonsCompleted(count: Int)
        case xpEarned(amount: Int)
        case streakDays(count: Int)
        case perfectLesson
        case instrumentMastery(instrument: Instrument)
    }

    init(
        id: UUID = UUID(),
        title: String,
        description: String,
        iconName: String,
        xpReward: Int,
        requirement: AchievementRequirement,
        isUnlocked: Bool = false,
        unlockedDate: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.iconName = iconName
        self.xpReward = xpReward
        self.requirement = requirement
        self.isUnlocked = isUnlocked
        self.unlockedDate = unlockedDate
    }
}

// MARK: - Pitch Detection Result

struct PitchDetectionResult {
    let detectedFrequency: Double
    let detectedNote: NotePitch?
    let detectedOctave: Int?
    let confidence: Double // 0.0 to 1.0
    let isAccurate: Bool   // matches expected note within tolerance
}
