//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Accelerate
import AVFoundation
import NaturalLanguage
import SignalServiceKit
import SignalUI
import Speech

// MARK: - Settings

enum AutoSTTLanguage: String, CaseIterable {
    case automatic, en, es, ru

    var displayName: String {
        switch self {
        case .automatic:
            return OWSLocalizedString("AUTO_STT_LANGUAGE_AUTOMATIC", comment: "AutoSTT language option: detect the spoken language automatically.")
        default:
            return Locale.current.localizedString(forLanguageCode: rawValue)?.localizedCapitalized ?? rawValue
        }
    }
}

/// Device-local preferences for on-device speech. Never synced: audio and transcripts stay on this iPhone.
enum AutoSTTSettings {
    private static let defaults = UserDefaults.standard

    private static func flag(_ name: String, default value: Bool) -> Bool {
        defaults.object(forKey: "AutoSTT.\(name)") as? Bool ?? value
    }

    private static func set(_ name: String, _ value: Any) {
        defaults.set(value, forKey: "AutoSTT.\(name)")
    }

    static var isEnabled: Bool { get { flag("enabled", default: false) } set { set("enabled", newValue) } }
    static var diarization: Bool { get { flag("diarization", default: true) } set { set("diarization", newValue) } }
    static var smartFormat: Bool { get { flag("smartFormat", default: true) } set { set("smartFormat", newValue) } }
    static var noiseAttenuation: Bool { get { flag("noiseAttenuation", default: true) } set { set("noiseAttenuation", newValue) } }
    static var profanityFilter: Bool { get { flag("profanityFilter", default: false) } set { set("profanityFilter", newValue) } }
    static var voiceCommands: Bool { get { flag("voiceCommands", default: false) } set { set("voiceCommands", newValue) } }
    static var voiceDuringCalls: Bool { get { flag("voiceDuringCalls", default: true) } set { set("voiceDuringCalls", newValue) } }
    static var voiceWhenLocked: Bool { get { flag("voiceWhenLocked", default: true) } set { set("voiceWhenLocked", newValue) } }
    static var voiceRequiresWakeWord: Bool { get { flag("voiceRequiresWakeWord", default: false) } set { set("voiceRequiresWakeWord", newValue) } }

    private static let fingerprintByteCount = 12 * MemoryLayout<Float>.size

    /// Active voice print. Also mirrored to UserDefaults; the file is the durable copy.
    static var voiceFingerprint: [Float]? {
        get {
            if let file = readFingerprint(named: "voice-fingerprint.bin") { return file }
            guard let data = defaults.data(forKey: "AutoSTT.voiceFingerprint"), data.count == fingerprintByteCount else { return nil }
            let vector = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            writeFingerprint(vector, named: "voice-fingerprint.bin")
            return vector
        }
        set {
            writeFingerprint(newValue, named: "voice-fingerprint.bin")
            if let value = newValue {
                defaults.set(value.withUnsafeBufferPointer { Data(buffer: $0) }, forKey: "AutoSTT.voiceFingerprint")
                defaults.set(Date().timeIntervalSince1970, forKey: "AutoSTT.voiceFingerprintAt")
            } else {
                defaults.removeObject(forKey: "AutoSTT.voiceFingerprint")
                defaults.removeObject(forKey: "AutoSTT.voiceFingerprintAt")
            }
        }
    }

    /// Last cleared print. Settings clear never deletes this file.
    static var archivedVoiceFingerprint: [Float]? {
        get { readFingerprint(named: "voice-fingerprint.cleared.bin") }
        set { writeFingerprint(newValue, named: "voice-fingerprint.cleared.bin") }
    }

    static var hasVoiceFingerprint: Bool { voiceFingerprint != nil }

    /// Spoken nicknames for numbers that are not in the contact book. e164 → name, device-local.
    static var numberNicknames: [String: String] {
        get { defaults.dictionary(forKey: "AutoSTT.numberNames") as? [String: String] ?? [:] }
        set { set("numberNames", newValue) }
    }
    static var hasArchivedVoiceFingerprint: Bool { archivedVoiceFingerprint != nil }

    /// Drops the active lock so a new voice can enroll. The previous print stays on file.
    static func archiveAndClearVoiceFingerprint() {
        if let active = voiceFingerprint { archivedVoiceFingerprint = active }
        voiceFingerprint = nil
    }

    private static var fingerprintDirectory: URL {
        let url = URL(fileURLWithPath: OWSFileSystem.appSharedDataDirectoryPath(), isDirectory: true).appendingPathComponent("AutoSTT", isDirectory: true)
        OWSFileSystem.ensureDirectoryExists(url.path)
        return url
    }

    private static func readFingerprint(named name: String) -> [Float]? {
        guard let data = try? Data(contentsOf: fingerprintDirectory.appendingPathComponent(name)), data.count == fingerprintByteCount else { return nil }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    private static func writeFingerprint(_ value: [Float]?, named name: String) {
        let url = fingerprintDirectory.appendingPathComponent(name)
        if let value {
            let data = value.withUnsafeBufferPointer { Data(buffer: $0) }
            try? data.write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static var language: AutoSTTLanguage {
        get { defaults.string(forKey: "AutoSTT.language").flatMap(AutoSTTLanguage.init(rawValue:)) ?? .automatic }
        set { set("language", newValue.rawValue) }
    }

    static var isSupported: Bool {
        if #available(iOS 26, *) { return true }
        return false
    }

    static var isActive: Bool { isEnabled && isSupported }

    static let supportedLanguageCodes = ["en", "es", "ru"]

    /// Languages whose SpeechTranscriber model couldn't be installed on this device; they use DictationTranscriber.
    static var dictationOnlyLanguages: Set<String> {
        get { Set(defaults.stringArray(forKey: "AutoSTT.dictationOnly") ?? []) }
        set { set("dictationOnly", Array(newValue).sorted()) }
    }

    /// The explicit choice, or the user's first preferred language that we support.
    static var preferredLanguageCode: String {
        if language != .automatic { return language.rawValue }
        for identifier in Locale.preferredLanguages {
            let code = String(identifier.prefix(2))
            if supportedLanguageCodes.contains(code) { return code }
        }
        return "en"
    }
}

// MARK: - Transcript model

struct STTWord: Hashable, Sendable {
    /// Token exactly as emitted by the recognizer, including leading whitespace.
    var token: String
    var start: Double
    var end: Double
    var confidence: Double
    var speaker: Int?

    var text: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }
}

struct STTSegment: Identifiable, Hashable, Sendable {
    var id: Int
    /// Recognizer utterance; a partial shares it with the finals that replace it.
    var utterance: Int
    var speaker: Int?
    var start: Double
    var end: Double
    var rawText: String
    var text: String
    var words: [STTWord]
    var isFinal: Bool

    var confidence: Double {
        words.isEmpty ? 0 : words.reduce(0) { $0 + $1.confidence } / Double(words.count)
    }
}

struct STTTurn: Hashable, Sendable {
    var speaker: Int?
    var start: Double
    var end: Double
    var text: String
}

enum STTEvent: Sendable {
    case preparing(languageCode: String, isDownloading: Bool)
    /// Volatile hypothesis for the not-yet-finalized audio; superseded by the next partial or by a final.
    case partial(STTSegment)
    /// Finalized speaker turns for one utterance, already rule-formatted.
    case final([STTSegment])
    /// Language-model smart-formatted replacement for a previously emitted final segment (same `id`).
    case refined(STTSegment)
    /// The session's final segments after offline speaker re-clustering; replaces finals by utterance
    /// since turns may be re-split.
    case relabeled([STTSegment])
    case finished
}

struct STTTranscript: Sendable {
    private(set) var finals: [STTSegment] = []
    private(set) var partial: STTSegment?

    mutating func apply(_ event: STTEvent) {
        switch event {
        case .partial(let segment):
            partial = segment
        case .final(let segments):
            finals.append(contentsOf: segments)
            if let partial, let end = segments.last?.end, partial.start < end { self.partial = nil }
        case .refined(let segment):
            if let index = finals.lastIndex(where: { $0.id == segment.id }) { finals[index] = segment }
        case .relabeled(let segments):
            let utterances = Set(segments.map(\.utterance))
            finals.removeAll { utterances.contains($0.utterance) }
            finals.append(contentsOf: segments)
            finals.sort { $0.start < $1.start }
        case .finished:
            partial = nil
        case .preparing:
            break
        }
    }

    /// Finalized segments overlapping `[start, end)`.
    func finalized(from start: Double, to end: Double) -> [STTSegment] {
        finals.filter { $0.end > start && $0.start < end }
    }

    /// The final text that replaced `partial`, even after the partial itself has been discarded.
    /// Volatile results carry no word timings (their range runs to the end of buffered audio),
    /// so they are matched by utterance and the partial's start, not by time overlap.
    func finalized(for partial: STTSegment) -> [STTSegment] {
        let matches = finals.filter { $0.utterance == partial.utterance }
        return matches.isEmpty ? finalized(from: partial.start, to: partial.start + 0.01) : matches
    }

    var speakerCount: Int { Set(finals.compactMap(\.speaker)).count }

    var turns: [STTTurn] {
        var result: [STTTurn] = []
        for segment in finals where !segment.text.isEmpty {
            if var last = result.last, last.speaker == segment.speaker, segment.start - last.end < 2 {
                last.text += " " + segment.text
                last.end = segment.end
                result[result.count - 1] = last
            } else {
                result.append(STTTurn(speaker: segment.speaker, start: segment.start, end: segment.end, text: segment.text))
            }
        }
        return result
    }

    func text(includeSpeakers: Bool) -> String {
        turns.map { turn in
            guard includeSpeakers, let speaker = turn.speaker else { return turn.text }
            return "\(STTTranscript.speakerName(speaker)): \(turn.text)"
        }.joined(separator: "\n")
    }

    static func speakerName(_ speaker: Int) -> String {
        String(format: OWSLocalizedString("AUTO_STT_SPEAKER_FORMAT", comment: "Speaker label in a transcript. Embeds {{speaker number}}."), speaker + 1)
    }
}

enum STTError: LocalizedError {
    case unsupportedLanguage(String)
    case microphoneDenied
    case audioUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedLanguage(let code):
            return String(format: OWSLocalizedString("AUTO_STT_ERROR_UNSUPPORTED_LANGUAGE", comment: "Error when a language isn't supported on this device. Embeds {{language}}."), AutoSTTLanguage(rawValue: code)?.displayName ?? code)
        case .microphoneDenied:
            return OWSLocalizedString("AUTO_STT_ERROR_MICROPHONE", comment: "Error when microphone permission is denied for dictation.")
        case .audioUnavailable:
            return OWSLocalizedString("AUTO_STT_ERROR_AUDIO", comment: "Error when audio input can't be started for dictation.")
        }
    }
}

// MARK: - Audio front end

/// High-pass + noise-floor-tracking downward expander + slow AGC, applied in place to 16 kHz mono float audio.
final class STTAudioConditioner {
    private let frameLength = 160
    private let highPassAlpha: Float = 0.9695 // ~80 Hz at 16 kHz
    private var previousInput: Float = 0
    private var previousOutput: Float = 0
    private var noiseFloor: Float = 1e-3
    private var agcGain: Float = 1
    private var gateGain: Float = 1
    private var appliedGain: Float = 1

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        for i in 0..<count {
            let x = samples[i]
            let y = highPassAlpha * (previousOutput + x - previousInput)
            previousInput = x
            previousOutput = y
            samples[i] = y
        }

        var offset = 0
        while offset < count {
            let length = min(frameLength, count - offset)
            var rms: Float = 0
            vDSP_rmsqv(samples + offset, 1, &rms, vDSP_Length(length))

            noiseFloor = rms < noiseFloor ? 0.7 * noiseFloor + 0.3 * rms : min(noiseFloor * 1.0015, 0.05)
            noiseFloor = max(noiseFloor, 1e-5)
            let isSpeech = rms > noiseFloor * 3

            if isSpeech {
                let target = min(max(0.1 / max(rms, 1e-5), 0.5), 6)
                agcGain += (target - agcGain) * (target < agcGain ? 0.3 : 0.03)
            }
            gateGain += ((isSpeech ? 1 : 0.25) - gateGain) * (isSpeech ? 0.5 : 0.08)

            var start = appliedGain
            let end = agcGain * gateGain
            var step = (end - start) / Float(length)
            vDSP_vrampmul(samples + offset, 1, &start, &step, samples + offset, 1, vDSP_Length(length))
            appliedGain = end
            offset += length
        }

        var low: Float = -1
        var high: Float = 1
        vDSP_vclip(samples, 1, &low, &high, samples, 1, vDSP_Length(count))
    }
}

/// Converts arbitrary input into the 16 kHz working format (conditioning + diarization) and the analyzer's format.
@available(iOS 26, *)
final class STTAudioFrontEnd: @unchecked Sendable {
    static let workingFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    private let analyzerFormat: AVAudioFormat
    private let conditioner: STTAudioConditioner?
    private let diarizer: STTSpeakerDiarizer?
    private let sink: AsyncStream<AnalyzerInput>.Continuation
    private var toWorking: AVAudioConverter?
    private var toAnalyzer: AVAudioConverter?
    private let maxFrames: AVAudioFramePosition?
    private(set) var processedFrames: AVAudioFramePosition = 0

    init(analyzerFormat: AVAudioFormat, attenuate: Bool, diarizer: STTSpeakerDiarizer?, maxSeconds: Double?, sink: AsyncStream<AnalyzerInput>.Continuation) {
        self.analyzerFormat = analyzerFormat
        self.conditioner = attenuate ? STTAudioConditioner() : nil
        self.diarizer = diarizer
        self.sink = sink
        self.maxFrames = maxSeconds.map { AVAudioFramePosition($0 * Self.workingFormat.sampleRate) }
    }

    var isFull: Bool { maxFrames.map { processedFrames >= $0 } ?? false }

    func process(_ buffer: AVAudioPCMBuffer) {
        guard !isFull, let working = Self.convert(buffer, to: Self.workingFormat, using: &toWorking) else { return }
        processedFrames += AVAudioFramePosition(working.frameLength)
        conditioner?.process(working)
        diarizer?.append(working)
        guard let output = Self.convert(working, to: analyzerFormat, using: &toAnalyzer) else { return }
        sink.yield(AnalyzerInput(buffer: output))
    }

    func finish() { sink.finish() }

    private static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat, using converter: inout AVAudioConverter?) -> AVAudioPCMBuffer? {
        if buffer.format == format {
            guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength) else { return nil }
            copy.frameLength = buffer.frameLength
            let bytes = Int(buffer.frameLength) * Int(format.streamDescription.pointee.mBytesPerFrame)
            for (source, destination) in zip(UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList), UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)) {
                if let s = source.mData, let d = destination.mData { memcpy(d, s, min(bytes, Int(source.mDataByteSize))) }
            }
            return copy
        }
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converter?.primeMethod = .none
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        return status != .error && output.frameLength > 0 ? output : nil
    }
}

// MARK: - Speaker diarization

/// Lightweight on-device diarization: 12 MFCCs per 25 ms frame, mean+std over 1.5 s windows (0.75 s hop),
/// average-linkage clustering over the recording so far, then a Fisher-ratio check that only keeps
/// clusters that are clearly different voices. New windows inherit the current speaker until re-clustered.
final class STTSpeakerDiarizer: @unchecked Sendable {
    private struct Window {
        var start: Double
        var end: Double
        var stats: [Float]
        var speaker: Int
    }

    private static let sampleRate: Double = 16_000
    private static let frameSize = 400, hop = 160, fftSize = 512, bins = 256, melBands = 24, cepstra = 12
    private static let framesPerWindow = 150, framesPerHop = 75, minSpeechFrames = 75
    private static let mergeThreshold: Float = 0.2, separationThreshold: Float = 3.5, minSpeakerWindows = 4

    private let maxSpeakers: Int
    private let lock = NSLock()
    private let dftSetup: vDSP_DFT_Setup
    private let hamming: [Float]
    private let melWeights: [Float]
    private let dctWeights: [Float]

    private var pending: [Float] = []
    private var frameIndex = 0
    private var frames: [(mfcc: [Float], energyDB: Float)] = []
    private var windowStartFrame = 0
    private var noiseFloorDB: Float = -60
    private var windows: [Window] = []
    /// Recent speech frames with session time, so a short wake word can still make a voice print.
    private var speechLog: [(time: Double, mfcc: [Float])] = []
    private var runningMean = [Float](repeating: 0, count: 2 * STTSpeakerDiarizer.cepstra)
    private var runningM2 = [Float](repeating: 0, count: 2 * STTSpeakerDiarizer.cepstra)
    private var statsCount = 0

    init(maxSpeakers: Int = 6) {
        self.maxSpeakers = maxSpeakers
        dftSetup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(Self.fftSize), .FORWARD)!
        hamming = (0..<Self.frameSize).map { 0.54 - 0.46 * cos(2 * .pi * Float($0) / Float(Self.frameSize - 1)) }

        func mel(_ hz: Float) -> Float { 2595 * log10(1 + hz / 700) }
        func hz(_ mel: Float) -> Float { 700 * (pow(10, mel / 2595) - 1) }
        let (low, high) = (mel(100), mel(7600))
        let edges = (0...Self.melBands + 1).map { hz(low + (high - low) * Float($0) / Float(Self.melBands + 1)) }
        let binHz = Float(Self.sampleRate) / Float(Self.fftSize)
        var weights = [Float](repeating: 0, count: Self.melBands * Self.bins)
        for band in 0..<Self.melBands {
            for bin in 0..<Self.bins {
                let f = Float(bin) * binHz
                let rise = (f - edges[band]) / (edges[band + 1] - edges[band])
                let fall = (edges[band + 2] - f) / (edges[band + 2] - edges[band + 1])
                weights[band * Self.bins + bin] = max(0, min(rise, fall))
            }
        }
        melWeights = weights
        dctWeights = (1...Self.cepstra).flatMap { i in
            (0..<Self.melBands).map { j in cos(Float.pi * Float(i) * (Float(j) + 0.5) / Float(Self.melBands)) }
        }
    }

    deinit { vDSP_DFT_DestroySetup(dftSetup) }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0] else { return }
        lock.lock()
        defer { lock.unlock() }
        pending.append(contentsOf: UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
        var consumed = 0
        while pending.count - consumed >= Self.frameSize {
            pending.withUnsafeBufferPointer { analyzeFrame(UnsafeBufferPointer(rebasing: $0[consumed..<consumed + Self.frameSize])) }
            consumed += Self.hop
        }
        pending.removeFirst(consumed)
    }

    /// Mean of the 12 MFCCs over speech in `[start, end]`. Needs ~0.3 s of speech.
    func embedding(from start: Double, to end: Double) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        let paddedStart = start - 0.15, paddedEnd = end + 0.15
        let speech = speechLog.filter { $0.time >= paddedStart && $0.time <= paddedEnd }.map(\.mfcc)
        guard speech.count >= 20 else { return nil }
        let count = Float(speech.count)
        return (0..<Self.cepstra).map { c in speech.reduce(0) { $0 + $1[c] } / count }
    }

    /// Speaker label for an instant, from the nearest analyzed window with speech.
    func speaker(at time: Double) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return windows
            .filter { $0.speaker >= 0 }
            .min { abs(($0.start + $0.end) / 2 - time) < abs(($1.start + $1.end) / 2 - time) }?
            .speaker
    }

    /// Re-clusters every window so far with session-wide normalization. Works on a snapshot so audio
    /// analysis isn't blocked; recordings longer than `maxWindows` keep their previous labels.
    func recluster(maxWindows: Int = 800) {
        lock.lock()
        let indices = windows.indices.filter { !windows[$0].stats.isEmpty }
        let stats = indices.map { windows[$0].stats }
        let vectors = stats.map(normalized)
        lock.unlock()
        guard vectors.count >= 2, vectors.count <= maxWindows else { return }

        let n = vectors.count, d = vectors[0].count
        var similarity = [Float](repeating: 0, count: n * n)
        let flat = vectors.flatMap { $0 }
        vDSP_mmul(flat, 1, transpose(flat, rows: n, columns: d), 1, &similarity, 1, vDSP_Length(n), vDSP_Length(n), vDSP_Length(d))

        var cluster = Array(0..<n)
        var sizes = [Int](repeating: 1, count: n)
        var active = Set(0..<n)
        while active.count > 1 {
            var best: (a: Int, b: Int, value: Float) = (-1, -1, -.infinity)
            for a in active {
                for b in active where b > a && similarity[a * n + b] > best.value {
                    best = (a, b, similarity[a * n + b])
                }
            }
            guard best.value >= Self.mergeThreshold || active.count > maxSpeakers else { break }
            let (a, b) = (best.a, best.b)
            for c in active where c != a && c != b {
                let merged = (Float(sizes[a]) * similarity[a * n + c] + Float(sizes[b]) * similarity[b * n + c]) / Float(sizes[a] + sizes[b])
                similarity[a * n + c] = merged
                similarity[c * n + a] = merged
            }
            sizes[a] += sizes[b]
            active.remove(b)
            for i in 0..<n where cluster[i] == b { cluster[i] = a }
        }

        // Session normalization inflates a lone voice's own variation, so clusters whose raw cepstral
        // means sit within their window-to-window spread are one speaker. Clusters with too little
        // speech to characterize a voice join their closest neighbor.
        var groups = Dictionary(grouping: 0..<n, by: { cluster[$0] }).mapValues { $0.map { stats[$0] } }
        let prior = Self.moments(stats).variance
        var lastMerge: Float = 0
        while groups.count > 1 {
            let keys = Array(groups.keys)
            var closest: (a: Int, b: Int, score: Float) = (-1, -1, .infinity)
            var closestToSmall = closest
            let smallest = keys.min { groups[$0]!.count < groups[$1]!.count }!
            for i in keys.indices {
                for j in keys.indices where j > i {
                    let score = Self.separation(groups[keys[i]]!, groups[keys[j]]!, prior: prior)
                    if score < closest.score { closest = (keys[i], keys[j], score) }
                    if smallest == keys[i] || smallest == keys[j], score < closestToSmall.score { closestToSmall = (keys[i], keys[j], score) }
                }
            }
            if closest.score >= Self.separationThreshold {
                guard groups[smallest]!.count < Self.minSpeakerWindows else { break }
                closest = closestToSmall
            }
            lastMerge = closest.score
            groups[closest.a]! += groups.removeValue(forKey: closest.b)!
            for i in 0..<n where cluster[i] == closest.b { cluster[i] = closest.a }
        }
        Logger.info("AutoSTT diarization: \(n) windows, \(groups.count) speaker(s), last merged separation \(lastMerge)")

        lock.lock()
        defer { lock.unlock() }
        var labels: [Int: Int] = [:]
        for (position, windowIndex) in indices.enumerated() {
            let id = cluster[position]
            let label = labels[id] ?? labels.count
            labels[id] = label
            windows[windowIndex].speaker = label
        }
        if let last = indices.last {
            for i in windows.indices where i > last && windows[i].speaker >= 0 { windows[i].speaker = windows[last].speaker }
        }
        for i in windows.indices.dropFirst().dropLast() where windows[i - 1].speaker == windows[i + 1].speaker && windows[i - 1].speaker >= 0 {
            windows[i].speaker = windows[i - 1].speaker
        }
    }

    private var evens = [Float](repeating: 0, count: STTSpeakerDiarizer.bins)
    private var odds = [Float](repeating: 0, count: STTSpeakerDiarizer.bins)
    private var real = [Float](repeating: 0, count: STTSpeakerDiarizer.bins)
    private var imaginary = [Float](repeating: 0, count: STTSpeakerDiarizer.bins)
    private var power = [Float](repeating: 0, count: STTSpeakerDiarizer.bins)
    private var mel = [Float](repeating: 0, count: STTSpeakerDiarizer.melBands)

    private func analyzeFrame(_ frame: UnsafeBufferPointer<Float>) {
        var energy: Float = 0
        var previous = frame[0]
        for i in 0..<Self.fftSize {
            var x: Float = 0
            if i < Self.frameSize {
                x = (frame[i] - 0.97 * previous) * hamming[i]
                previous = frame[i]
                energy += x * x
            }
            if i % 2 == 0 { evens[i / 2] = x } else { odds[i / 2] = x }
        }
        let energyDB = 10 * log10(max(energy / Float(Self.frameSize), 1e-12))

        vDSP_DFT_Execute(dftSetup, evens, odds, &real, &imaginary)
        imaginary[0] = 0 // Packed Nyquist term; not part of bin 0's power.
        real.withUnsafeMutableBufferPointer { re in
            imaginary.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(Self.bins))
            }
        }

        vDSP_mmul(melWeights, 1, power, 1, &mel, 1, vDSP_Length(Self.melBands), 1, vDSP_Length(Self.bins))
        let logMel = mel.map { log(max($0, 1e-10)) }
        var mfcc = [Float](repeating: 0, count: Self.cepstra)
        vDSP_mmul(dctWeights, 1, logMel, 1, &mfcc, 1, vDSP_Length(Self.cepstra), 1, vDSP_Length(Self.melBands))

        noiseFloorDB = energyDB < noiseFloorDB ? 0.7 * noiseFloorDB + 0.3 * energyDB : noiseFloorDB + 0.01
        frames.append((mfcc, energyDB))
        let time = Double((frameIndex) * Self.hop) / Self.sampleRate
        if energyDB > noiseFloorDB + 8 {
            speechLog.append((time, mfcc))
            if speechLog.count > 2_000 { speechLog.removeFirst(speechLog.count - 1_500) }
        }
        frameIndex += 1
        if frames.count >= Self.framesPerWindow { closeWindow() }
    }

    private func closeWindow() {
        let speech = frames.filter { $0.energyDB > noiseFloorDB + 8 }.map(\.mfcc)
        let start = Double(windowStartFrame * Self.hop) / Self.sampleRate
        let end = start + Double(Self.framesPerWindow * Self.hop) / Self.sampleRate
        var window = Window(start: start, end: end, stats: [], speaker: -1)
        if speech.count >= Self.minSpeechFrames {
            let count = Float(speech.count)
            let mean = (0..<Self.cepstra).map { c in speech.reduce(0) { $0 + $1[c] } / count }
            let std = (0..<Self.cepstra).map { c in sqrt(speech.reduce(0) { $0 + pow($1[c] - mean[c], 2) } / count) }
            window.stats = mean + std
            updateRunningStats(window.stats)
            window.speaker = windows.last { $0.speaker >= 0 }?.speaker ?? 0
        }
        windows.append(window)
        frames.removeFirst(Self.framesPerHop)
        windowStartFrame += Self.framesPerHop
    }

    private func updateRunningStats(_ stats: [Float]) {
        statsCount += 1
        for i in stats.indices {
            let delta = stats[i] - runningMean[i]
            runningMean[i] += delta / Float(statsCount)
            runningM2[i] += delta * (stats[i] - runningMean[i])
        }
    }

    private func normalized(_ stats: [Float]) -> [Float] {
        let z = stats.indices.map { i -> Float in
            let variance = statsCount > 1 ? runningM2[i] / Float(statsCount - 1) : 1
            return (stats[i] - runningMean[i]) / max(sqrt(variance), 1e-3)
        }
        let norm = max(sqrt(z.reduce(0) { $0 + $1 * $1 }), 1e-6)
        return z.map { $0 / norm }
    }

    /// Per-cepstrum mean and variance of the windows' cepstral means.
    private static func moments(_ windows: [[Float]]) -> (mean: [Float], variance: [Float]) {
        let count = Float(windows.count)
        let mean = (0..<cepstra).map { c in windows.reduce(0) { $0 + $1[c] } / count }
        let variance = (0..<cepstra).map { c in windows.reduce(0) { $0 + pow($1[c] - mean[c], 2) } / count }
        return (mean, variance)
    }

    /// Mean Fisher ratio between two clusters. Variances of small clusters shrink toward the
    /// session-wide `prior`, since a few windows can't estimate a speaker's spread.
    private static func separation(_ a: [[Float]], _ b: [[Float]], prior: [Float]) -> Float {
        let (x, y) = (moments(a), moments(b))
        let shrinkage: Float = 4
        func shrunk(_ variance: Float, _ count: Int, _ c: Int) -> Float {
            (Float(count) * variance + shrinkage * prior[c]) / (Float(count) + shrinkage)
        }
        return (0..<cepstra).reduce(0) { total, c in
            let pooled = (shrunk(x.variance[c], a.count, c) + shrunk(y.variance[c], b.count, c)) / 2
            return total + pow(x.mean[c] - y.mean[c], 2) / max(pooled, 1e-3)
        } / Float(cepstra)
    }

    private func transpose(_ matrix: [Float], rows: Int, columns: Int) -> [Float] {
        var result = [Float](repeating: 0, count: matrix.count)
        vDSP_mtrans(matrix, 1, &result, 1, vDSP_Length(columns), vDSP_Length(rows))
        return result
    }
}