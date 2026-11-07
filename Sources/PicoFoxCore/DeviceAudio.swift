// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Benjamin Faershtein

import Foundation

extension WaveAudio {
    /// Reads device audio, including the known factory WAV with stale length fields.
    /// General WAV imports should continue to use the strict `decode` method.
    public static func decodePicoFox(_ data: Data) throws -> WaveAudio {
        do {
            return try decode(data)
        } catch {
            let strictError = error
            // Restrict recovery to the proven factory file size. An arbitrary shorter file can
            // indicate a broken FAT chain, even if its remaining bytes contain whole PCM frames.
            guard data.count == 288_044 else {
                throw strictError
            }
            var bytes = [UInt8](data)
            func matches(_ offset: Int, _ text: String) -> Bool {
                bytes[offset..<(offset + text.utf8.count)].elementsEqual(text.utf8)
            }
            func u16(_ offset: Int) -> UInt32 {
                UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            }
            func u32(_ offset: Int) -> UInt32 {
                u16(offset) | u16(offset + 2) << 16
            }
            let declaredPayload = UInt64(u32(40))
            let actualPayload = UInt64(data.count - 44)
            // Firmware reuses a 300,000-byte data header for its 288,000-byte factory payload.
            // Accept only its exact fixed PCM layout; never infer a format or scan truncated chunks.
            guard matches(0, "RIFF"), matches(8, "WAVE"), matches(12, "fmt "), matches(36, "data"),
                  u32(16) == 16, u16(20) == 1, u16(22) == 1,
                  u32(24) == 5000, u32(28) == 10000, u16(32) == 2, u16(34) == 16,
                  declaredPayload == 300_000, actualPayload == 288_000,
                  UInt64(u32(4)) == declaredPayload + 36 else {
                throw strictError
            }
            func set32(_ offset: Int, _ value: UInt32) {
                for index in 0..<4 { bytes[offset + index] = UInt8((value >> (index * 8)) & 255) }
            }
            // Repair a local copy only. The source Data and the device file are never changed.
            set32(4, UInt32(data.count - 8))
            set32(40, UInt32(data.count - 44))
            return try decode(Data(bytes))
        }
    }
}
