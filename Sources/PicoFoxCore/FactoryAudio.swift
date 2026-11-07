// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Benjamin Faershtein

import Foundation

/// The original 28.8-second PicoFox factory recording, with corrected WAV length fields.
public enum FactoryAudio {
    public static func wavData() throws -> Data {
        guard let url = Bundle.module.url(forResource: "factory-audio", withExtension: "wav") else {
            throw PicoFoxError.invalid("The bundled PicoFox factory recording is missing.")
        }
        return try Data(contentsOf: url)
    }
}
