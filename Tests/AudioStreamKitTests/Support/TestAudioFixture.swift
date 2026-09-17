//
//  TestAudioFixture.swift
//  AudioStreamKitTests
//

import Foundation

/// Generates a minimal, valid PCM WAV file in memory — real enough for `AVPlayerItem` to
/// actually decode and report a `.readyToPlay`/duration, without checking a binary fixture
/// into the repo. Test-only.
enum TestAudioFixture {

    /// `duration` seconds of silence, mono 16-bit PCM at `sampleRate` Hz.
    static func wav(duration: TimeInterval = 2, sampleRate: UInt32 = 8000) -> Data {
        let bitsPerSample: UInt16 = 16
        let channels: UInt16 = 1
        let sampleCount = Int(duration * Double(sampleRate))
        let dataSize = UInt32(sampleCount * Int(channels) * Int(bitsPerSample / 8))
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)

        var data = Data()
        data.append(ascii: "RIFF")
        data.appendLittleEndian(UInt32(36) + dataSize)
        data.append(ascii: "WAVE")

        data.append(ascii: "fmt ")
        data.appendLittleEndian(UInt32(16)) // subchunk1 size (PCM)
        data.appendLittleEndian(UInt16(1))  // audio format: PCM
        data.appendLittleEndian(channels)
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(bitsPerSample)

        data.append(ascii: "data")
        data.appendLittleEndian(dataSize)
        data.append(Data(repeating: 0, count: Int(dataSize))) // silence

        return data
    }
}

private extension Data {
    mutating func append(ascii string: String) {
        append(Data(string.utf8))
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        append(contentsOf: Swift.withUnsafeBytes(of: value.littleEndian, Array.init))
    }

    mutating func appendLittleEndian(_ value: UInt16) {
        append(contentsOf: Swift.withUnsafeBytes(of: value.littleEndian, Array.init))
    }
}
