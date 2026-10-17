import AVFoundation
import XCTest
@testable import UndertoneApp

final class AudioRecorderTests: XCTestCase {
    /// With no input device, or mid-switch, the input reports 0 Hz or 0
    /// channels. Tapping that format raises an exception that ends the app.
    func testRejectsInputWithNoSampleRateOrNoChannels() {
        XCTAssertFalse(AudioRecorder.isUsableInput(sampleRate: 0, channels: 1))
        XCTAssertFalse(AudioRecorder.isUsableInput(sampleRate: 48_000, channels: 0))
        XCTAssertFalse(AudioRecorder.isUsableInput(sampleRate: 0, channels: 0))
        XCTAssertTrue(AudioRecorder.isUsableInput(sampleRate: 24_000, channels: 1))
    }

    /// AirPods switching to their headset profile mid-recording: 24 kHz mono
    /// buffers go into a file opened at 48 kHz stereo. The converter keeps
    /// its state between buffers, so the output length tracks the rate ratio.
    func testConvertsReplacementMicrophoneToFileFormatAcrossBuffers() throws {
        let input = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        let output = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let converter = try XCTUnwrap(InputConverter(from: input, to: output))
        var inputFrames = 0
        var outputFrames = 0
        var rightPeak: Float = 0
        for index in 0..<20 {
            let buffer = try sine(format: input, frames: 512, startFrame: index * 512)
            inputFrames += 512
            guard let converted = try converter.convert(buffer) else { continue }
            XCTAssertEqual(converted.format, output)
            outputFrames += Int(converted.frameLength)
            rightPeak = max(rightPeak, peak(converted, channel: 1))
        }
        XCTAssertEqual(Double(outputFrames), Double(inputFrames) * 2, accuracy: 256)
        XCTAssertGreaterThan(rightPeak, 0.1)
    }

    /// A stereo microphone into a mono file: the right channel is mixed in,
    /// not dropped.
    func testMixesExtraChannelsDownInsteadOfDroppingThem() throws {
        let input = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let output = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let converter = try XCTUnwrap(InputConverter(from: input, to: output))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 1024))
        buffer.frameLength = 1024
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for index in 0..<1024 {
            channels[0][index] = 0
            channels[1][index] = 0.5
        }
        let converted = try XCTUnwrap(converter.convert(buffer))
        XCTAssertEqual(converted.frameLength, 1024)
        XCTAssertGreaterThan(peak(converted, channel: 0), 0.1)
    }

    func testEmptyBufferConvertsToNothing() throws {
        let input = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let output = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let converter = try XCTUnwrap(InputConverter(from: input, to: output))
        let empty = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 64))
        XCTAssertNil(try converter.convert(empty))
    }

    private func sine(format: AVAudioFormat, frames: Int, startFrame: Int) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0..<Int(format.channelCount) {
            for index in 0..<frames {
                let time = Double(startFrame + index) / format.sampleRate
                channels[channel][index] = Float(0.5 * sin(2 * Double.pi * 440 * time))
            }
        }
        return buffer
    }

    private func peak(_ buffer: AVAudioPCMBuffer, channel: Int) -> Float {
        guard let data = buffer.floatChannelData?[channel] else { return 0 }
        var result: Float = 0
        for index in 0..<Int(buffer.frameLength) { result = max(result, abs(data[index])) }
        return result
    }
}
