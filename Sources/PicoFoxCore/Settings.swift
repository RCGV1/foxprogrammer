// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Benjamin Faershtein

import Foundation

public struct PicoFoxSettings: Codable, Equatable, Sendable {
    public var callsign = ""
    public var ituZone = 2
    public var frequencyMHz = 146.565
    public var dutyCycle = 100
    public var attenuation = 0
    public var morseWPM = 15
    public var farnsworthWPM = 15
    public var toneHz = 600
    public var toneVolume = 70
    public init() {}

    /// The frequency range accepted by the PicoFox firmware for the selected ITU zone.
    public var frequencyRangeMHz: ClosedRange<Double> {
        144.020...(ituZone == 1 ? 145.980 : 147.980)
    }

    public var frequencyIssue: String? {
        guard frequencyMHz.isFinite, frequencyRangeMHz.contains(frequencyMHz) else {
            return "Frequency must be 144.020–\(String(format: "%.3f", frequencyRangeMHz.upperBound)) MHz."
        }
        return nil
    }

    public var issues: [String] {
        var result: [String] = []
        if callsign.isEmpty || callsign.utf8.count > 11 || !callsign.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) }) {
            result.append("Use 1–11 uppercase letters or digits for the callsign.")
        }
        if !(1...3).contains(ituZone) { result.append("ITU zone must be 1, 2, or 3.") }
        if let frequencyIssue { result.append(frequencyIssue) }
        if !(0...100).contains(dutyCycle) { result.append("Duty cycle must be 0–100%.") }
        if !(0...127).contains(attenuation) { result.append("Attenuation must be 0–127.") }
        if !(1...30).contains(morseWPM) { result.append("Morse speed must be 1–30 WPM.") }
        if !(morseWPM...max(morseWPM, 255)).contains(farnsworthWPM) { result.append("Spacing must be between the Morse speed and 255 WPM.") }
        if !(100...2000).contains(toneHz) { result.append("Tone must be 100–2000 Hz.") }
        if !(1...100).contains(toneVolume) { result.append("Tone volume must be 1–100%.") }
        return result
    }

    public var values: [(String, String)] {
        [("CALLSIGN", callsign), ("ITU_ZONE", "\(ituZone)"),
         ("FREQ_MHZ", String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), frequencyMHz)),
         ("DUTY_CYCLE", "\(dutyCycle)"), ("ATTENUATION", "\(attenuation)"),
         ("MORSE_WPM", "\(morseWPM)"), ("MORSE_FARNSWORTH_WPM", "\(farnsworthWPM)"),
         ("MORSE_TONE", "\(toneHz)"), ("MORSE_TONE_VOL", "\(toneVolume)")]
    }
}

public enum PicoFoxError: LocalizedError, Equatable {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let message): message } }
}

/// Retains unrecognized lines and comments while replacing known keys once.
public struct SettingsDocument: Sendable {
    public var settings: PicoFoxSettings
    public var original: String
    public init(text: String = "") throws {
        original = text
        settings = PicoFoxSettings()
        for line in text.components(separatedBy: .newlines) {
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespaces)
            let value = pair[1].trimmingCharacters(in: .whitespaces)
            func integer() throws -> Int {
                guard let n = Int(value) else { throw PicoFoxError.invalid("\(key) is not an integer. Correct this field in settings.txt before opening it.") }
                return n
            }
            switch key {
            case "CALLSIGN": settings.callsign = value
            case "ITU_ZONE": settings.ituZone = try integer()
            case "FREQ_MHZ":
                guard let n = Double(value), n.isFinite else { throw PicoFoxError.invalid("FREQ_MHZ is not a finite number.") }
                settings.frequencyMHz = n
            case "DUTY_CYCLE": settings.dutyCycle = try integer()
            case "ATTENUATION": settings.attenuation = try integer()
            case "MORSE_WPM": settings.morseWPM = try integer()
            case "MORSE_FARNSWORTH_WPM": settings.farnsworthWPM = try integer()
            case "MORSE_TONE": settings.toneHz = try integer()
            case "MORSE_TONE_VOL": settings.toneVolume = try integer()
            default: break
            }
        }
    }
    public func encoded() throws -> Data {
        guard settings.issues.isEmpty else { throw PicoFoxError.invalid(settings.issues.joined(separator: "\n")) }
        let values = Dictionary(uniqueKeysWithValues: settings.values)
        var seen = Set<String>()
        var lines: [String] = []
        for line in original.components(separatedBy: .newlines) {
            let key = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            if let value = values[key] {
                if seen.insert(key).inserted { lines.append("\(key)=\(value)") }
            } else { lines.append(line) }
        }
        while lines.last == "" { lines.removeLast() }
        for (key, value) in settings.values where !seen.contains(key) { lines.append("\(key)=\(value)") }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }
}
