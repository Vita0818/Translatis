import XCTest
@testable import IntatisSharedUI
#if canImport(AVFoundation)
import AVFoundation
#endif

final class ComposerVoiceInputTests: XCTestCase {
    func testTranscriptBecomesDraftWhenComposerIsEmpty() {
        XCTAssertEqual(
            ComposerVoiceDraft.appending(
                transcript: "  hello world\n",
                to: ""),
            "hello world")
    }

    func testTranscriptAppendsWithoutReplacingExistingDraft() {
        XCTAssertEqual(
            ComposerVoiceDraft.appending(
                transcript: "second thought",
                to: "first thought"),
            "first thought second thought")
    }

    func testExistingTrailingWhitespaceIsPreserved() {
        XCTAssertEqual(
            ComposerVoiceDraft.appending(
                transcript: "continued",
                to: "draft\n"),
            "draft\ncontinued")
    }

    func testBlankTranscriptLeavesDraftUntouched() {
        XCTAssertEqual(
            ComposerVoiceDraft.appending(
                transcript: " \n ",
                to: "keep me"),
            "keep me")
    }

    #if canImport(AVFoundation)
    func testFlotisWAVRecorderSettingsAre16BitPCMWithoutAACBitrate() {
        let settings = ComposerAudioRecorderSettings.wav(
            sampleRate: 16_000,
            channels: 1)

        XCTAssertEqual(
            settings[AVFormatIDKey] as? Int,
            Int(kAudioFormatLinearPCM))
        XCTAssertEqual(settings[AVSampleRateKey] as? Int, 16_000)
        XCTAssertEqual(settings[AVNumberOfChannelsKey] as? Int, 1)
        XCTAssertEqual(settings[AVLinearPCMBitDepthKey] as? Int, 16)
        XCTAssertNil(settings[AVEncoderBitRateKey])
    }

    func testFlotisM4ARecorderSettingsDoNotForceUnsupportedBitrate() {
        let settings = ComposerAudioRecorderSettings.m4a(
            sampleRate: 16_000,
            channels: 1)

        XCTAssertEqual(
            settings[AVFormatIDKey] as? Int,
            Int(kAudioFormatMPEG4AAC))
        XCTAssertNil(settings[AVEncoderBitRateKey])
    }
    #endif
}
