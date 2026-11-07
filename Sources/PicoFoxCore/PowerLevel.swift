// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Benjamin Faershtein

import Foundation

/// Nominal r3 output from the published 65 mW maximum and approximate 0.25 dB steps.
/// Actual RF power requires measurement/calibration and can vary with frequency and hardware.
public enum PowerLevel {
    public static let referenceMilliwatts = 65.0
    public static func milliwatts(attenuation: Int) -> Double {
        referenceMilliwatts * pow(10, -Double(min(127, max(0, attenuation))) * 0.25 / 10)
    }
    /// The slider increases power from left to right while firmware stores increasing attenuation.
    public static func attenuation(sliderStep: Double) -> Int {
        guard sliderStep.isFinite else { return 127 }
        return 127 - Int(min(127, max(0, sliderStep)).rounded())
    }
}
