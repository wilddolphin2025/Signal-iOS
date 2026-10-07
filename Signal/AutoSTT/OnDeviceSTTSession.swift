//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import AVFoundation
import NaturalLanguage
import SignalServiceKit
import SignalUI
import Speech

/// One transcription pass over the microphone or an audio file, fully on device.
///
/// Emits volatile partials, finalized speaker turns with word timestamps/confidence, then
/// language-model refinements and an offline diarization relabel once the audio ends.
@available(iOS 26, *)
@MainActor
final class OnDeviceSTTSession {
    struct Options: Sendable {
        var languageCode: String
        var diarize: Bool
        var smartFormat: Bool
        var attenuate: Bool
        var profanityFilter: Bool
        /// Added to every timestamp so consecutive sessions share one timeline.
        var timeOffset: Double = 0
        /// Stops reading input after this much audio; used for language probing.
        var maxSeconds: Double?
        /// Words the recognizer should expect, such as contact names.
        var contextualStrings: [String] = []

        static func current(languageCode: String? = nil, timeOffset: Double = 0) -> Options {
            Options(
                languageCode: languageCode ?? AutoSTTSettings.preferredLanguageCode,
                diarize: AutoSTTSettings.diarization,
                smartFormat: AutoSTTSettings.smartFormat,
                attenuate: AutoSTTSettings.noiseAttenuation,
                profanityFilter: AutoSTTSettings.profanityFilter,
                timeOffset: timeOffset,
            )
        }
    }

    private struct RawResult: Sendable {
        var text: AttributedString
        var range: CMTimeRange
        var isFinal: Bool
    }

    private enum Module {
        case speech(SpeechTranscriber)
        case dictation(DictationTranscriber)

        var module: any SpeechModule {
            switch self {
            case .speech(let module): module
            case .dictation(let module): module
            }
        }

        func results() -> AsyncThrowingStream<RawResult, Error> {
            switch self {
            case .speech(let module): bridge(module.results) { RawResult(text: $0.text, range: $0.range, isFinal: $0.isFinal) }
            case .dictation(let module): bridge(module.results) { RawResult(text: $0.text, range: $0.range, isFinal: $0.isFinal) }
            }
        }

        private func bridge<S: AsyncSequence & Sendable>(_ sequence: S, _ transform: @escaping @Sendable (S.Element) -> RawResult) -> AsyncThrowingStream<RawResult, Error> where S.Element: Sendable {
            AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        for try await element in sequence { continuation.yield(transform(element)) }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    private static var nextSegmentID = 0
    private static var currentUtterance = 0

    let events: AsyncStream<STTEvent>
    private let emitter: AsyncStream<STTEvent>.Continuation
    private let options: Options
    private var transcript = STTTranscript()
    private var analyzer: SpeechAnalyzer?
    private var frontEnd: STTAudioFrontEnd?
    private var diarizer: STTSpeakerDiarizer?
    private var resultsTask: Task<Void, Never>?
    private var refineTask: Task<Void, Never>?
    private var refineQueue: AsyncStream<[STTSegment]>.Continuation?
    private var audioEngine: AVAudioEngine?
    private var audioActivity: AudioActivity?
    private var isFinished = false
    private(set) var locale: Locale?
    /// Wall-clock time of audio position zero, for mapping segment times to dates.
    private(set) var startedAt: Date?

    init(options: Options) {
        self.options = options
        (events, emitter) = AsyncStream.makeStream(of: STTEvent.self)
    }

    // MARK: Sources

    /// - Parameter sharingCallAudio: Listen inside an active call's audio session. The call owns the
    ///   session and the only voice-processing unit, so neither is touched.
    func startMicrophone(sharingCallAudio: Bool = false) async throws {
        guard await AVAudioApplication.requestRecordPermission() else { throw STTError.microphoneDenied }
        if !sharingCallAudio {
            let activity = AudioActivity(audioDescription: "AutoSTT dictation", behavior: .recordAudio)
            guard SUIEnvironment.shared.audioSessionRef.startAudioActivity(activity) else { throw STTError.audioUnavailable }
            audioActivity = activity
        }

        try await prepare(live: true)

        let engine = AVAudioEngine()
        let input = engine.inputNode
        if options.attenuate, !sharingCallAudio {
            // Apple's voice-processing I/O: echo cancellation, noise suppression and AGC in hardware-tuned DSP.
            try? input.setVoiceProcessingEnabled(true)
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: true, duckingLevel: .min)
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw STTError.audioUnavailable }
        let frontEnd = self.frontEnd
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            frontEnd?.process(buffer)
        }
        audioEngine = engine
        engine.prepare()
        try engine.start()
        startedAt = Date()
    }

    func transcribe(fileURL: URL) async throws {
        let file = try AVAudioFile(forReading: fileURL)
        try await prepare(live: false)
        guard let frontEnd else { return }
        try await Task.detached(priority: .userInitiated) {
            let chunk: AVAudioFrameCount = 8192
            while file.framePosition < file.length, !frontEnd.isFull {
                try Task.checkCancellation()
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { break }
                try file.read(into: buffer, frameCount: chunk)
                guard buffer.frameLength > 0 else { break }
                frontEnd.process(buffer)
            }
        }.value
        await finishAnalysis()
    }

    func stop() async {
        stopAudio()
        await finishAnalysis()
    }

    /// Voice print for audio in `[start, end]` on the session timeline.
    func voiceEmbedding(from start: Double, to end: Double) -> [Float]? {
        diarizer?.embedding(from: start - options.timeOffset, to: end - options.timeOffset)
    }

    func cancel() async {
        stopAudio()
        guard !isFinished else { return }
        isFinished = true
        frontEnd?.finish()
        await analyzer?.cancelAndFinishNow()
        resultsTask?.cancel()
        refineTask?.cancel()
        emitter.finish()
    }

    // MARK: Pipeline

    private func prepare(live: Bool) async throws {
        emitter.yield(.preparing(languageCode: options.languageCode, isDownloading: false))
        let module = try await makeInstalledModule(live: live)

        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module.module]) ?? STTAudioFrontEnd.workingFormat
        let analyzer = SpeechAnalyzer(modules: [module.module], options: .init(priority: .userInitiated, modelRetention: .lingering))
        if !options.contextualStrings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = options.contextualStrings
            try? await analyzer.setContext(context)
        }
        try await analyzer.prepareToAnalyze(in: format)

        let (inputs, sink) = AsyncStream.makeStream(of: AnalyzerInput.self)
        diarizer = options.diarize ? STTSpeakerDiarizer() : nil
        frontEnd = STTAudioFrontEnd(analyzerFormat: format, attenuate: options.attenuate, diarizer: diarizer, maxSeconds: options.maxSeconds, sink: sink)

        if options.smartFormat {
            OnDeviceLanguageModel.prewarm()
            let (queue, continuation) = AsyncStream.makeStream(of: [STTSegment].self)
            refineQueue = continuation
            let languageCode = options.languageCode
            refineTask = Task { [weak self] in
                for await segments in queue {
                    for var segment in segments {
                        guard let formatted = await OnDeviceLanguageModel.smartFormat(segment.text, languageCode: languageCode), formatted != segment.text else { continue }
                        segment.text = formatted
                        self?.publish(.refined(segment))
                    }
                }
            }
        }

        let results = module.results()
        resultsTask = Task { [weak self] in
            do {
                for try await result in results { self?.handle(result) }
            } catch {
                Logger.warn("AutoSTT results ended: \(error)")
            }
        }
        try await analyzer.start(inputSequence: inputs)
        self.analyzer = analyzer
    }

    /// Picks a recognizer with its model installed. Falls back to DictationTranscriber, and remembers
    /// that, when the SpeechTranscriber model for the language can't be installed on this device.
    private func makeInstalledModule(live: Bool) async throws -> Module {
        let module = try await makeModule(live: live)
        do {
            try await installAssets(for: module)
            return module
        } catch {
            guard case .speech = module else { throw error }
            Logger.warn("AutoSTT \(options.languageCode) SpeechTranscriber assets unavailable, using dictation: \(error)")
            AutoSTTSettings.dictationOnlyLanguages.insert(options.languageCode)
            let fallback = try await makeModule(live: live)
            try await installAssets(for: fallback)
            return fallback
        }
    }

    /// Reserves the module's locale (apps hold a limited number) and downloads its model if needed.
    private func installAssets(for module: Module) async throws {
        if let locale {
            _ = try? await AssetInventory.reserve(locale: locale)
        }
        guard await AssetInventory.status(forModules: [module.module]) != .installed else { return }
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module.module]) else { return }
        emitter.yield(.preparing(languageCode: options.languageCode, isDownloading: true))
        try await request.downloadAndInstall()
    }

    private func makeModule(live: Bool) async throws -> Module {
        let candidates = Self.localeCandidates(options.languageCode)
        if SpeechTranscriber.isAvailable, !AutoSTTSettings.dictationOnlyLanguages.contains(options.languageCode) {
            for candidate in candidates {
                guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: candidate) else { continue }
                self.locale = locale
                return .speech(SpeechTranscriber(
                    locale: locale,
                    transcriptionOptions: options.profanityFilter ? [.etiquetteReplacements] : [],
                    reportingOptions: live ? [.volatileResults, .fastResults] : [.volatileResults],
                    attributeOptions: [.audioTimeRange, .transcriptionConfidence],
                ))
            }
        }
        // DictationTranscriber covers more locales and older hardware.
        for candidate in candidates {
            guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: candidate) else { continue }
            self.locale = locale
            return .dictation(DictationTranscriber(
                locale: locale,
                contentHints: [],
                transcriptionOptions: options.profanityFilter ? [.punctuation, .etiquetteReplacements] : [.punctuation],
                reportingOptions: [.volatileResults, .frequentFinalization],
                attributeOptions: [.audioTimeRange, .transcriptionConfidence],
            ))
        }
        throw STTError.unsupportedLanguage(options.languageCode)
    }

    private func handle(_ result: RawResult) {
        if result.isFinal {
            // ~3 minutes of windows re-cluster in a few milliseconds; longer sessions relabel at the end.
            diarizer?.recluster(maxWindows: 240)
        }
        let words = smoothedSpeakers(words(in: result))
        guard !words.isEmpty else { return }
        if result.isFinal {
            let segments = turnGroups(words).map { makeSegment($0, isFinal: true) }
            Self.currentUtterance += 1
            publish(.final(segments))
            refineQueue?.yield(segments)
            if transcript.finals.count > segments.count { relabelFinals(onlyIfChanged: true) }
        } else {
            var partial = makeSegment(words, isFinal: false)
            partial.speaker = words.last?.speaker
            publish(.partial(partial))
        }
    }

    /// Splits words into speaker turns. Speaker labels are noisy and lag word boundaries, so each
    /// sentence or pause-delimited phrase takes its majority speaker before phrases merge into turns.
    private func turnGroups(_ words: [STTWord]) -> [[STTWord]] {
        var phrases: [[STTWord]] = []
        for word in words {
            if let last = phrases.last?.last, word.start - last.end < 0.3, !".?!…".contains(last.text.last ?? " ") {
                phrases[phrases.count - 1].append(word)
            } else {
                phrases.append([word])
            }
        }
        var groups: [[STTWord]] = []
        for phrase in phrases {
            let speaker = Self.majoritySpeaker(phrase)
            let labeled = phrase.map { word in
                var word = word
                word.speaker = speaker
                return word
            }
            if let last = groups.last?.last, last.speaker == speaker, labeled[0].start - last.end < 1.5 {
                groups[groups.count - 1] += labeled
            } else {
                groups.append(labeled)
            }
        }
        return groups
    }

    private static func majoritySpeaker(_ words: [STTWord]) -> Int? {
        Dictionary(grouping: words.compactMap(\.speaker), by: { $0 }).max { $0.value.count < $1.value.count }?.key
    }

    private func makeSegment(_ words: [STTWord], isFinal: Bool, utterance: Int? = nil) -> STTSegment {
        let raw = words.map(\.token).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        var id = -1
        if isFinal {
            Self.nextSegmentID += 1
            id = Self.nextSegmentID
        }
        return STTSegment(
            id: id,
            utterance: utterance ?? Self.currentUtterance,
            speaker: Self.majoritySpeaker(words),
            start: words.first?.start ?? 0,
            end: words.last?.end ?? 0,
            rawText: raw,
            text: SmartFormatter.quick(raw, languageCode: options.languageCode, isFinal: isFinal),
            words: words,
            isFinal: isFinal,
        )
    }

    /// Splits the recognizer's attributed text into timed tokens. Untimed runs (spaces, punctuation)
    /// are folded into the neighboring word so the original spacing survives.
    private func words(in result: RawResult) -> [STTWord] {
        let offset = options.timeOffset
        var words: [STTWord] = []
        var carry = ""
        for run in result.text.runs {
            let token = String(result.text[run.range].characters)
            guard let range = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] else {
                if words.isEmpty || token.first?.isWhitespace == true { carry += token } else { words[words.count - 1].token += token }
                continue
            }
            let start = range.start.seconds, end = CMTimeRangeGetEnd(range).seconds
            words.append(STTWord(
                token: carry + token,
                start: start + offset,
                end: end + offset,
                confidence: run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self] ?? 1,
                speaker: diarizer?.speaker(at: (start + end) / 2),
            ))
            carry = ""
        }
        if !carry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if words.isEmpty {
                words.append(STTWord(token: carry, start: result.range.start.seconds + offset, end: CMTimeRangeGetEnd(result.range).seconds + offset, confidence: 1, speaker: nil))
            } else {
                words[words.count - 1].token += carry
            }
        }
        return words
    }

    /// Absorbs speaker flips shorter than ~1 s into the surrounding turn.
    private func smoothedSpeakers(_ words: [STTWord]) -> [STTWord] {
        var words = words
        var start = 0
        while start < words.count {
            var end = start
            while end + 1 < words.count, words[end + 1].speaker == words[start].speaker { end += 1 }
            if start > 0, words[end].end - words[start].start < 1 {
                for i in start...end { words[i].speaker = words[start - 1].speaker }
            }
            start = end + 1
        }
        return words
    }

    private func publish(_ event: STTEvent) {
        transcript.apply(event)
        emitter.yield(event)
    }

    /// Releases the microphone immediately; recognition of already-captured audio may still finish.
    func stopAudio() {
        if let audioEngine {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
            self.audioEngine = nil
        }
        if let audioActivity {
            SUIEnvironment.shared.audioSessionRef.endAudioActivity(audioActivity)
            self.audioActivity = nil
        }
    }

    private func finishAnalysis() async {
        guard !isFinished else { return }
        isFinished = true
        frontEnd?.finish()
        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            Logger.warn("AutoSTT finalize failed: \(error)")
        }
        await resultsTask?.value
        refineQueue?.finish()
        await refineTask?.value
        if let diarizer {
            diarizer.recluster()
            relabelFinals(onlyIfChanged: false)
        }
        publish(.finished)
        emitter.finish()
    }

    /// Re-applies the diarizer's current labels to every final segment, re-splitting turns where needed.
    private func relabelFinals(onlyIfChanged: Bool) {
        guard let diarizer else { return }
        let offset = options.timeOffset
        var labels: [Int: Int] = [:]
        let relabeled = transcript.finals.flatMap { segment -> [STTSegment] in
            let words = smoothedSpeakers(segment.words.map { word in
                var word = word
                word.speaker = diarizer.speaker(at: (word.start + word.end) / 2 - offset).map { speaker in
                    if let label = labels[speaker] { return label }
                    labels[speaker] = labels.count
                    return labels.count - 1
                }
                return word
            })
            let groups = turnGroups(words)
            guard groups.count > 1 else {
                var segment = segment
                segment.words = groups.first ?? words
                segment.speaker = Self.majoritySpeaker(segment.words)
                return [segment]
            }
            return groups.map { makeSegment($0, isFinal: true, utterance: segment.utterance) }
        }
        if onlyIfChanged, relabeled.map(\.speaker) == transcript.finals.map(\.speaker) { return }
        publish(.relabeled(relabeled))
    }

    // MARK: Languages and assets

    static func localeCandidates(_ code: String) -> [Locale] {
        let fallbackRegion = ["en": "US", "es": "ES", "ru": "RU"][code]
        let regions = [Locale.current.region?.identifier, fallbackRegion].compactMap { $0 }
        return regions.map { Locale(identifier: "\(code)-\($0)") } + [Locale(identifier: code)]
    }

    /// Picks the spoken language of a recording by probing its first seconds with each installed model
    /// and scoring mean word confidence, weighted by text-level language agreement.
    static func detectLanguage(fileURL: URL) async -> String {
        let fallback = AutoSTTSettings.preferredLanguageCode
        var installed = Set(await SpeechTranscriber.installedLocales.compactMap { $0.language.languageCode?.identifier })
        installed.formUnion(await DictationTranscriber.installedLocales.compactMap { $0.language.languageCode?.identifier })
        let candidates = AutoSTTSettings.supportedLanguageCodes.filter(installed.contains)
        guard candidates.count > 1 else { return candidates.first ?? fallback }

        var best = (code: fallback, score: -1.0)
        for code in candidates {
            var options = Options.current(languageCode: code)
            options.diarize = false
            options.smartFormat = false
            options.maxSeconds = 8
            let probe = OnDeviceSTTSession(options: options)
            guard (try? await probe.transcribe(fileURL: fileURL)) != nil else { continue }
            let words = probe.transcript.finals.flatMap(\.words)
            guard !words.isEmpty else { continue }
            let confidence = words.reduce(0) { $0 + $1.confidence } / Double(words.count)
            let recognizer = NLLanguageRecognizer()
            recognizer.languageConstraints = [.english, .spanish, .russian]
            recognizer.processString(probe.transcript.finals.map(\.rawText).joined(separator: " "))
            let agreement = recognizer.languageHypotheses(withMaximum: 3)[NLLanguage(rawValue: code)] ?? 0
            let score = confidence * (0.5 + 0.5 * agreement)
            if score > best.score { best = (code, score) }
        }
        return best.code
    }

    /// Downloads the speech models for every supported language so transcription works offline.
    /// Each language is attempted independently; one unavailable model doesn't block the others.
    static func installOfflineAssets() async -> (ready: [String], unavailable: [String]) {
        var ready: [String] = [], unavailable: [String] = []
        for code in AutoSTTSettings.supportedLanguageCodes {
            do {
                _ = try await OnDeviceSTTSession(options: .current(languageCode: code)).makeInstalledModule(live: true)
                ready.append(code)
            } catch {
                Logger.warn("AutoSTT \(code) model unavailable: \(error)")
                unavailable.append(code)
            }
        }
        return (ready, unavailable)
    }
}
