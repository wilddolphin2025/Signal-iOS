//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import AudioToolbox
import AVFoundation
import LibSignalClient
import SignalRingRTC
import SignalServiceKit
import SignalUI
import UIKit

extension Notification.Name {
    static let voiceCommandStatusDidChange = Notification.Name("VoiceCommandStatusDidChange")
}

/// Hands-free calling: listens on-device for spoken commands, talks back, and drives Signal calls.
///
/// Outside calls any recognized command is accepted ("call Mom"); during a call commands must start
/// with the wake word ("Signal, mute") so normal conversation is never acted on. Every action is
/// confirmed aloud and dialing can be cancelled by voice before it starts.
@available(iOS 26, *)
@MainActor
final class VoiceCommandService: NSObject {
    static let shared = VoiceCommandService()

    struct Status: Equatable {
        var isListening = false
        var isSleeping = false
        var heard = ""
        var reply = ""
    }

    private(set) var status = Status() {
        didSet { if status != oldValue { NotificationCenter.default.post(name: .voiceCommandStatusDidChange, object: self) } }
    }

    var isEnabled: Bool { AutoSTTSettings.voiceCommands && AutoSTTSettings.isSupported }

    private var language: String { AutoSTTSettings.preferredLanguageCode }
    private var callService: CallService { AppEnvironment.shared.callService }
    private var currentCall: SignalCall? { callService.callServiceState.currentCall }

    // MARK: Listener

    private enum Mode { case off, idle, inCall }

    private var mode = Mode.off
    private var session: OnDeviceSTTSession?
    private var eventsTask: Task<Void, Never>?
    private var transition: Task<Void, Never>?
    private var listenerStartedAt = Date.distantPast
    /// The call and our listener must not fight over the microphone while a call is being set up.
    private var pausedUntil = Date.distantPast
    private var isStarted = false

    // MARK: Conversation

    private enum Dialog: Equatable {
        case none
        case awaitingName(video: Bool, groupsOnly: Bool, attempts: Int)
        case choosing([VoiceContact], video: Bool)
        case confirming(VoiceContact, video: Bool)
        case countdown(VoiceContact, video: Bool)
        case awaitingNumber(video: Bool, attempts: Int)
        case confirmingNumber(e164: String, video: Bool)
        case awaitingCountry(digits: String, video: Bool)
        case lookingUp(VoiceContact, video: Bool)
        case awaitingSearch
    }

    private var dialog = Dialog.none {
        didSet { if dialog != oldValue { Logger.info("Voice commands dialog: \(dialog)") } }
    }
    private var dialogTimeout: Task<Void, Never>?
    private var countdown: Task<Void, Never>?
    private var lookupTask: Task<Void, Never>?
    private var assistantTask: Task<Void, Never>?
    private var addressedUntil = Date.distantPast
    private var isSleeping = false { didSet { status.isSleeping = isSleeping } }

    // MARK: Speech output

    private let synthesizer = AVSpeechSynthesizer()
    private var lastPrompt = ""
    private var speakingSince: Date?
    private var lastSpeech: (start: Date, end: Date, text: String)?
    private var afterSpeaking: (() -> Void)?
    /// Skip the "Call ended." prompt after a voice cancel, so it doesn't talk over "Cancelling call."
    private var suppressCallEnded = false

    // MARK: Contacts and calls

    private enum Target { case contact(SignalServiceAddress), group(GroupIdentifier) }

    private var matcher = VoiceContactMatcher(contacts: [])
    private var targets: [String: Target] = [:]
    private var directoryLoadedAt = Date.distantPast
    private var announcedCall: ObjectIdentifier?
    private var pendingGroupJoin: (id: GroupIdentifier, video: Bool, until: Date)?
    private var groupHoldRestore: (audioMuted: Bool, videoMuted: Bool)?
    /// Session speaker id of the enrolled voice, so short follow-ups don't need a full print.
    private var ownerSpeaker: Int?
    private var justEnrolled = false
    /// Commands wait for “Hey Signal” once per launch (and after a clear).
    private var unlockedThisLaunch = false
    private var didAskForHeySignalThisLaunch = false
    /// Recognition is ignored while we talk and for a moment after, so our own prompt can't enroll.
    private var ignoreHearingUntil = Date.distantPast
    private var ignoreAfterSpeech: TimeInterval = 0.4
    private let sleepBlock = DeviceSleepBlockObject(blockReason: "Voice commands")
    private var isBlockingSleep = false

    override private init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Public

    /// Registers observers and starts listening if the user turned voice commands on.
    func startIfEnabled() {
        if !isStarted {
            isStarted = true
            callService.callServiceState.addObserver(self, syncStateImmediately: true)
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(appStateChanged), name: UIApplication.didBecomeActiveNotification, object: nil)
            center.addObserver(self, selector: #selector(appStateChanged), name: UIApplication.didEnterBackgroundNotification, object: nil)
            center.addObserver(self, selector: #selector(audioInterrupted(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        }
        refresh()
    }

    func setEnabled(_ enabled: Bool) {
        AutoSTTSettings.voiceCommands = enabled
        isSleeping = false
        dialog = .none
        if enabled {
            unlockedThisLaunch = false
            didAskForHeySignalThisLaunch = false
        }
        startIfEnabled()
        if !enabled {
            VoiceAssistant.shared.reset()
            say(.off)
        }
        NotificationCenter.default.post(name: .voiceCommandStatusDidChange, object: self)
    }

    func toggle() {
        if isEnabled, isSleeping {
            isSleeping = false
            say(.awake)
        } else {
            setEnabled(!isEnabled)
        }
    }

    func settingsDidChange() {
        refresh(force: true)
    }

    func clearVoiceFingerprint() {
        AutoSTTSettings.archiveAndClearVoiceFingerprint()
        ownerSpeaker = nil
        justEnrolled = false
        unlockedThisLaunch = false
        didAskForHeySignalThisLaunch = false
        VoiceAssistant.shared.reset()
        Logger.info("Voice commands fingerprint cleared; archived copy kept on file")
        NotificationCenter.default.post(name: .voiceCommandStatusDidChange, object: self)
        if isEnabled { say(.fingerprintCleared) }
    }

    /// Wait until the microphone is live so the first words of the prompt aren't eaten by the audio session.
    private func askForHeySignalIfNeeded() {
        guard isEnabled, !didAskForHeySignalThisLaunch, currentCall == nil, status.isListening else { return }
        didAskForHeySignalThisLaunch = true
        unlockedThisLaunch = false
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard let self, self.isEnabled, self.currentCall == nil else { return }
            self.say(.sayHeySignal)
        }
    }

    /// Called by the call's audio service when iOS refuses an audio session change. Our in-call
    /// listener keeps the microphone open, which blocks switching away from the call category.
    /// - Returns: Whether the microphone was released, so the change is worth retrying.
    func releaseCallAudio() -> Bool {
        guard mode == .inCall, let session else { return false }
        Logger.info("Voice commands releasing the microphone for a call audio change")
        session.stopAudio()
        mode = .off
        refresh(force: true)
        return true
    }

    // MARK: - Listener lifecycle

    private func desiredMode() -> Mode {
        guard isEnabled, Date() >= pausedUntil else { return .off }
        if let call = currentCall {
            if isIncomingRinging(call) { return mode == .off ? .off : .idle }
            return AutoSTTSettings.voiceDuringCalls && isAudioLive(call) ? .inCall : .off
        }
        if UIApplication.shared.applicationState == .background {
            // Recording can continue in the background but can't start there.
            return AutoSTTSettings.voiceWhenLocked && mode != .off ? .idle : .off
        }
        return .idle
    }

    private func refresh(force: Bool = false) {
        let target = desiredMode()
        updateSleepBlock()
        guard force || target != mode || (target != .off && session == nil) else { return }
        let previous = transition
        transition = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            Logger.info("Voice commands mode \(self.mode) -> \(target), call: \(self.currentCall.map { "\($0.mode)" } ?? "none")")
            await self.stopListening()
            self.mode = target
            if target == .inCall {
                // Let WebRTC finish configuring the call's audio session first.
                try? await Task.sleep(for: .seconds(1))
                guard self.desiredMode() == .inCall else {
                    self.mode = .off
                    self.refresh()
                    return
                }
            }
            if target != .off { await self.startListening(inCall: target == .inCall) }
            self.updateSleepBlock()
        }
    }

    private func pauseListening(for seconds: Double) async {
        pausedUntil = Date().addingTimeInterval(seconds)
        refresh()
        await transition?.value
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds + 0.1))
            self?.refresh()
        }
    }

    private func startListening(inCall: Bool) async {
        loadDirectoryIfStale()
        var options = OnDeviceSTTSession.Options(languageCode: language, diarize: true, smartFormat: false, attenuate: true, profanityFilter: false)
        ownerSpeaker = nil
        options.contextualStrings = ["Signal"] + matcher.vocabulary()
        let session = OnDeviceSTTSession(options: options)
        self.session = session
        eventsTask = Task { [weak self] in
            for await event in session.events { self?.handle(event, from: session) }
        }
        do {
            try await session.startMicrophone(sharingCallAudio: inCall)
            listenerStartedAt = Date()
            status.isListening = true
            Logger.info("Voice commands listening (\(inCall ? "in call" : "idle"), \(language))")
            VoiceAssistant.shared.prewarm()
            askForHeySignalIfNeeded()
        } catch {
            Logger.warn("Voice commands couldn't start listening: \(error)")
            await stopListening()
            mode = .off
            status.reply = error.localizedDescription
        }
    }

    private func stopListening() async {
        guard let session else { return }
        self.session = nil
        eventsTask?.cancel()
        eventsTask = nil
        await session.cancel()
        status.isListening = false
    }

    private func updateSleepBlock() {
        let shouldBlock = isEnabled && !isSleeping && currentCall == nil && UIApplication.shared.applicationState == .active
        guard shouldBlock != isBlockingSleep, let manager = DependenciesBridge.shared.deviceSleepManager else { return }
        isBlockingSleep = shouldBlock
        if shouldBlock { manager.addBlock(blockObject: sleepBlock) } else { manager.removeBlock(blockObject: sleepBlock) }
    }

    @objc
    private func appStateChanged() {
        refresh()
    }

    @objc
    private func audioInterrupted(_ notification: Notification) {
        guard
            let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            AVAudioSession.InterruptionType(rawValue: raw) == .ended
        else { return }
        refresh(force: true)
    }

    // MARK: - Hearing

    private func handle(_ event: STTEvent, from source: OnDeviceSTTSession) {
        guard source === session else { return }
        switch event {
        case .partial(let segment):
            if !isSleeping, Date() >= ignoreHearingUntil, speakingSince == nil, showsHeard(segment) {
                status.heard = segment.rawText.trimmingCharacters(in: .whitespaces)
            }
        case .final(let segments):
            if Date() < ignoreHearingUntil {
                Logger.info("Voice commands ignored echo of our own speech")
                break
            }
            if let text = acceptedText(segments, from: source), !text.isEmpty { hear(text, segments: segments, from: source) }
            // Sessions keep their transcript; start fresh periodically when nothing is in progress.
            if mode == .idle, dialog == .none, speakingSince == nil, Date().timeIntervalSince(listenerStartedAt) > 600 {
                refresh(force: true)
            }
        case .preparing, .refined, .relabeled, .finished:
            break
        }
    }

    /// Drops our own voice picked up by the microphone, keeping anything the person said after it.
    private func acceptedText(_ segments: [STTSegment], from source: OnDeviceSTTSession) -> String? {
        guard let base = source.startedAt, let first = segments.first, let last = segments.last else { return nil }
        let start = base.addingTimeInterval(first.start), end = base.addingTimeInterval(last.end)
        let text = segments.map(\.rawText).joined(separator: " ")
        if let since = speakingSince, end > since { return stripEcho(text, prompt: lastPrompt, promptEnded: false) }
        if let speech = lastSpeech, start < speech.end.addingTimeInterval(0.6), end > speech.start {
            return stripEcho(text, prompt: speech.text, promptEnded: end > speech.end)
        }
        return text
    }

    private func stripEcho(_ text: String, prompt: String, promptEnded: Bool) -> String {
        // After we ask for “Hey Signal”, the user’s reply is those same words — not our echo.
        if promptEnded {
            let parsed = VoiceCommandParser.parse(text, languageCode: language)
            if parsed.isAddressed || parsed.isWakeWordOnly { return text }
        }
        let heard = VoiceCommandParser.tokenize(text), said = VoiceCommandParser.tokenize(prompt)
        guard let first = heard.first, var p = said.firstIndex(of: first) else { return text }
        var consumed = 0
        while consumed < heard.count, p < said.count, heard[consumed] == said[p] {
            consumed += 1
            p += 1
        }
        // An echo of a prompt that already finished must run to the prompt's last word.
        let isEcho = consumed > 1 || p == said.count
        guard isEcho, !promptEnded || p == said.count || consumed < heard.count else { return text }
        return heard.dropFirst(consumed).joined(separator: " ")
    }

    private func showsHeard(_ segment: STTSegment) -> Bool {
        guard AutoSTTSettings.hasVoiceFingerprint else { return true }
        if let ownerSpeaker, let speaker = segment.speaker { return speaker == ownerSpeaker }
        return true
    }

    /// First “Hey Signal” saves that voice. Later speech is acted on only if it matches.
    private func admit(_ segments: [STTSegment], from source: OnDeviceSTTSession, addressed: Bool, allowWithoutUnlock: Bool = false) -> Bool {
        if !unlockedThisLaunch, !addressed, !allowWithoutUnlock {
            Logger.info("Voice commands waiting for Hey Signal")
            return false
        }

        let start = segments.first?.start ?? 0
        let end = segments.last?.end ?? start
        let embedding = source.voiceEmbedding(from: start, to: end)
        let speaker = majoritySpeaker(segments)

        // A short “Hey Signal” print does not compare to later phrases (scores were 0.05–0.29).
        // After unlock, the session speaker label is the lock; the file is updated from longer speech.
        if unlockedThisLaunch, let ownerSpeaker, let speaker, speaker == ownerSpeaker {
            refineFingerprint(segments, from: source)
            return true
        }

        if let stored = AutoSTTSettings.voiceFingerprint {
            if let embedding {
                let score = Self.cosine(stored, embedding)
                Logger.info("Voice commands voice score \(String(format: "%.2f", score)) speaker=\(speaker.map(String.init) ?? "-")")
                guard score >= 0.55 else { return false }
                ownerSpeaker = speaker
                unlockedThisLaunch = true
                refineFingerprint(segments, from: source)
                return true
            }
            if addressed {
                unlockedThisLaunch = true
                ownerSpeaker = speaker ?? ownerSpeaker
                return true
            }
            Logger.info("Voice commands no print for enrolled owner, dropping")
            return false
        }

        guard addressed || allowWithoutUnlock else { return false }
        if addressed, let embedding {
            AutoSTTSettings.voiceFingerprint = embedding
            justEnrolled = true
            Logger.info("Voice commands enrolled speaker \(speaker.map(String.init) ?? "?")")
            NotificationCenter.default.post(name: .voiceCommandStatusDidChange, object: self)
        } else if addressed {
            Logger.info("Voice commands unlocked without a print yet; will enroll on the next phrase")
        }
        ownerSpeaker = speaker ?? ownerSpeaker
        if addressed { unlockedThisLaunch = true }
        return true
    }

    private func refineFingerprint(_ segments: [STTSegment], from source: OnDeviceSTTSession) {
        let start = segments.first?.start ?? 0
        let end = segments.last?.end ?? start
        guard end - start >= 0.8, let embedding = source.voiceEmbedding(from: start, to: end) else { return }
        if let stored = AutoSTTSettings.voiceFingerprint {
            AutoSTTSettings.voiceFingerprint = zip(stored, embedding).map { 0.7 * $0 + 0.3 * $1 }
        } else {
            AutoSTTSettings.voiceFingerprint = embedding
        }
    }

    private func majoritySpeaker(_ segments: [STTSegment]) -> Int? {
        Dictionary(grouping: segments.compactMap(\.speaker), by: { $0 }).max { $0.value.count < $1.value.count }?.key
    }

    private static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let dot = zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
        let na = sqrt(a.reduce(0) { $0 + $1 * $1 }), nb = sqrt(b.reduce(0) { $0 + $1 * $1 })
        return dot / max(na * nb, 1e-6)
    }

    private func hear(_ text: String, segments: [STTSegment], from source: OnDeviceSTTSession) {
        let utterance = VoiceCommandParser.parse(text, languageCode: language)
        let addressed = utterance.isAddressed || Date() < addressedUntil
        Logger.info("Voice commands heard \"\(text)\" -> \(utterance.intent) addressed=\(addressed) dialog=\(dialog)")
        let ringing = currentCall.map(isIncomingRinging) ?? false
        let inCall = currentCall != nil && !ringing
        if utterance.intent == .presenceCheck, !inCall || addressed {
            status.heard = text.trimmingCharacters(in: .whitespaces)
            if !unlockedThisLaunch {
                addressedUntil = Date().addingTimeInterval(10)
                say(.hearYouSayHeySignal)
                return
            }
            if let ownerSpeaker, let speaker = majoritySpeaker(segments), speaker != ownerSpeaker {
                Logger.info("Voice commands presence check from speaker \(speaker), owner is \(ownerSpeaker)")
                return
            }
            refineFingerprint(segments, from: source)
            addressedUntil = Date().addingTimeInterval(10)
            say(.hearYou(paused: isSleeping, inCall: inCall))
            return
        }

        guard admit(segments, from: source, addressed: addressed || utterance.isAddressed) else {
            Logger.info("Voice commands ignored (locked or other speaker)")
            return
        }

        if utterance.isWakeWordOnly {
            addressedUntil = Date().addingTimeInterval(8)
            if isSleeping {
                isSleeping = false
                say(.awake)
            } else if justEnrolled {
                justEnrolled = false
                say(.enrolled)
            } else {
                say(.wakeAck)
            }
            return
        }
        if isSleeping {
            guard addressed else { return }
            isSleeping = false
            if utterance.intent == .wake {
                say(.awake)
                return
            }
        }

        let inDialog = dialog != .none
        // Nobody is on the line yet while an outgoing call rings, so "cancel" can't be conversation.
        let isStopWhileRingingOut = currentCall.map(isOutgoingRinging) == true && [.cancel, .hangUp, .no].contains(utterance.intent)
        let needsWakeWord = (inCall && !isStopWhileRingingOut) || (AutoSTTSettings.voiceRequiresWakeWord && !inDialog && !ringing)
        guard addressed || !needsWakeWord else { return }
        let assistantReady = VoiceAssistant.shared.isAvailable
        if !assistantReady, case .text = utterance.intent, !inDialog, !addressed { return }

        addressedUntil = .distantPast
        status.heard = text.trimmingCharacters(in: .whitespaces)
        dialogTimeout?.cancel()
        if isUrgentStop(utterance) || isDirectWorldQuestion(utterance.intent) {
            if inDialog, handleDialog(utterance.intent) { return }
            handleCommand(utterance.intent, addressed: addressed)
            return
        }
        interpretWithAssistant(text, addressed: addressed, fallback: utterance)
    }

    /// Cancel / hang up / answer must not wait on the language model.
    private func isUrgentStop(_ utterance: VoiceUtterance) -> Bool {
        switch utterance.intent {
        case .cancel, .hangUp:
            return true
        case .no:
            if currentCall.map(isOutgoingRinging) == true { return true }
            switch dialog {
            case .countdown, .lookingUp: return true
            default: return false
            }
        case .answer, .decline:
            return currentCall.map(isIncomingRinging) ?? false
        default:
            return false
        }
    }

    /// Time, date, internet, and search are answered from the clock/network, not the language model.
    private func isDirectWorldQuestion(_ intent: VoiceIntent) -> Bool {
        switch intent {
        case .tellTime, .tellDate, .checkInternet, .search: return true
        default: return false
        }
    }

    private func shouldPreferWorldFallback(_ turn: VoiceAssistant.Turn, fallback: VoiceIntent) -> Bool {
        guard isDirectWorldQuestion(fallback) else { return false }
        switch turn.action {
        case .ignore, .none, .help: return true
        default: return false
        }
    }

    private func worldQuestion(in text: String) -> VoiceIntent? {
        let tokens = Set(VoiceCommandParser.tokenize(text))
        if !tokens.isDisjoint(with: ["internet", "online", "conexion", "сеть"]) { return .checkInternet }
        if tokens.contains("search") || tokens.contains("google") || tokens.contains("busca") || tokens.contains("найди") || tokens.contains("поищи") {
            let parsed = VoiceCommandParser.parse(text, languageCode: language)
            if case .search(let query) = parsed.intent { return .search(query) }
            return .search(tokens.subtracting(["search", "for", "google", "look", "up", "busca", "buscar", "найди", "найти", "поищи", "поиск"]).joined(separator: " "))
        }
        if !tokens.isDisjoint(with: ["time", "hora", "час", "времени"]) { return .tellTime }
        if !tokens.isDisjoint(with: ["date", "today", "fecha", "число", "дата"]) { return .tellDate }
        if tokens.contains("day"), tokens.contains("it") || tokens.contains("today") { return .tellDate }
        return nil
    }

    private var dialogSummary: String {
        switch dialog {
        case .none: "none"
        case .awaitingName(let video, let groupsOnly, _):
            groupsOnly ? "asking which group to call" : video ? "asking who to video call" : "asking who to call"
        case .choosing(let list, _): "offering choices: \(list.map(\.name).joined(separator: ", "))"
        case .confirming(let contact, _): "confirming contact \(contact.name)"
        case .countdown(let contact, _): "about to call \(contact.name); user can cancel"
        case .awaitingNumber: "asking for a phone number"
        case .confirmingNumber(let e164, _): "confirming number \(e164)"
        case .awaitingCountry: "asking which country the number is in"
        case .lookingUp(let contact, _): "looking up \(contact.name) on Signal"
        case .awaitingSearch: "asking what to search for"
        }
    }

    private func interpretWithAssistant(_ text: String, addressed: Bool, fallback: VoiceUtterance) {
        guard VoiceAssistant.shared.isAvailable else {
            if dialog != .none, handleDialog(fallback.intent) { return }
            handleCommand(fallback.intent, addressed: addressed)
            return
        }
        loadDirectoryIfStale()
        let context = VoiceAssistant.Context(
            language: language,
            dialog: dialogSummary,
            inCall: currentCall != nil && !(currentCall.map(isIncomingRinging) ?? false),
            incomingRing: currentCall.map(isIncomingRinging) ?? false,
            outgoingRing: currentCall.map(isOutgoingRinging) ?? false,
            lastPrompt: lastPrompt,
            contacts: matcher.contacts.prefix(40).map(\.name),
            addressed: addressed,
        )
        assistantTask?.cancel()
        assistantTask = Task { [weak self] in
            guard let self else { return }
            let turn = await VoiceAssistant.shared.interpret(heard: text, context: context)
            guard !Task.isCancelled else { return }
            if let turn {
                if self.shouldPreferWorldFallback(turn, fallback: fallback.intent) {
                    self.handleCommand(fallback.intent, addressed: addressed)
                } else {
                    self.applyAssistant(turn, addressed: addressed, fallback: fallback)
                }
            } else if self.dialog != .none, self.handleDialog(fallback.intent) {
                return
            } else {
                self.handleCommand(fallback.intent, addressed: addressed)
            }
        }
    }

    private func applyAssistant(_ turn: VoiceAssistant.Turn, addressed: Bool, fallback: VoiceUtterance) {
        Logger.info("Voice assistant action=\(turn.action) name=\(turn.name) number=\(turn.number)")
        switch turn.action {
        case .ignore:
            if isDirectWorldQuestion(fallback.intent) {
                handleCommand(fallback.intent, addressed: addressed)
            }
            return
        case .none, .help:
            if isDirectWorldQuestion(fallback.intent) {
                handleCommand(fallback.intent, addressed: addressed)
                return
            }
            if let rescued = worldQuestion(in: status.heard) {
                handleCommand(rescued, addressed: addressed)
                return
            }
            if turn.action == .help, !turn.say.isEmpty {
                speak(turn.say)
            } else if turn.action == .none, !turn.say.isEmpty {
                speak(turn.say)
            } else if turn.action == .help {
                say(.help(inCall: currentCall != nil))
            } else if addressed {
                say(.didntCatch)
            }
        case .call:
            applyCall(name: turn.name, video: false, groupsOnly: false, spoken: turn.say)
        case .videoCall:
            applyCall(name: turn.name, video: true, groupsOnly: false, spoken: turn.say)
        case .groupCall:
            applyCall(name: turn.name, video: true, groupsOnly: true, spoken: turn.say)
        case .callNumber:
            let spokenNumber = turn.number.isEmpty ? turn.name : turn.number
            if spokenNumber.isEmpty {
                dialog = .awaitingNumber(video: false, attempts: 0)
                speak(orCanned: turn.say, .askNumber)
            } else {
                handleNumber(spokenNumber, video: false, attempts: 0)
            }
        case .yes:
            if handleDialog(.yes) { return }
            speak(orCanned: turn.say, .didntCatch)
        case .no:
            if handleDialog(.no) { return }
            speak(orCanned: turn.say, .didntCatch)
        case .cancel:
            if dialog != .none { abortOutgoingDial() } else { hangUp() }
        case .hangUp:
            hangUp()
        case .answer:
            answer()
        case .decline:
            decline()
        case .mute:
            guard let call = currentCall else { return say(.noCall) }
            callService.updateIsLocalAudioMuted(isLocalAudioMuted: turn.on)
            callService.callUIAdapter.setIsMuted(call: call, isMuted: turn.on)
            speak(orCanned: turn.say, .muted(turn.on))
        case .hold:
            guard let call = currentCall else { return say(.noCall) }
            setHeld(turn.on, call: call)
        case .speaker:
            guard let call = currentCall else { return say(.noCall) }
            setSpeaker(turn.on, call: call)
        case .camera:
            guard let call = currentCall else { return say(.noCall) }
            setCamera(turn.on, call: call)
        case .flipCamera:
            guard let call = currentCall else { return say(.noCall) }
            flipCamera(call: call)
        case .callBack:
            callBack()
        case .missed:
            announceMissedCalls()
        case .status:
            guard let call = currentCall else { return say(.noCall) }
            if turn.say.isEmpty { announceStatus(call) } else { speak(turn.say) }
        case .join:
            joinGroupCall()
        case .sleep:
            cancelDialog()
            speak(orCanned: turn.say, .sleeping)
            isSleeping = true
        case .wake:
            isSleeping = false
            speak(orCanned: turn.say, .awake)
        case .saveAs:
            if case .confirmingNumber(let e164, let video) = dialog, !turn.name.isEmpty {
                saveNumber(e164, as: turn.name, video: video)
            } else {
                speak(orCanned: turn.say, .askNumber)
            }
        case .repeatLast:
            lastPrompt.isEmpty ? say(.nothingToRepeat) : speak(lastPrompt)
        case .tellTime:
            say(.currentTime(VoiceWorldInfo.spokenTime(language: language)))
        case .tellDate:
            say(.currentDate(VoiceWorldInfo.spokenDate(language: language)))
        case .checkInternet:
            say(VoiceWorldInfo.isOnline ? .internetAvailable : .internetUnavailable)
        case .search:
            startSearch(turn.name)
        }
        _ = addressed
        _ = fallback
    }

    private func applyCall(name: String, video: Bool, groupsOnly: Bool, spoken: String) {
        if name.isEmpty {
            dialog = .awaitingName(video: video, groupsOnly: groupsOnly, attempts: 0)
            speak(orCanned: spoken, .askWho(video: video))
            return
        }
        if VoiceSpokenNumber.looksLikeNumber(name, languageCode: language) {
            handleNumber(name, video: video, attempts: 0)
            return
        }
        switch matchContact(name, groupsOnly: groupsOnly) {
        case .one(let contact, let confident):
            if confident {
                startCountdown(contact, video: video, spoken: spoken)
            } else {
                dialog = .confirming(contact, video: video)
                speak(orCanned: spoken, .didYouMean(contact.name))
            }
        case .several(let list):
            dialog = .choosing(list, video: video)
            speak(orCanned: spoken, list.count <= 4 ? .choices(list.map(\.name)) : .tooMany(list.count, name))
        case .none(let suggestion):
            if let suggestion {
                dialog = .confirming(suggestion, video: video)
                speak(orCanned: spoken, .didYouMean(suggestion.name))
            } else {
                dialog = .awaitingName(video: video, groupsOnly: groupsOnly, attempts: 1)
                speak(orCanned: spoken, .notFound(name))
            }
        }
    }

    private func speak(orCanned spoken: String, _ prompt: VoicePrompt) {
        if spoken.isEmpty { say(prompt) } else { speak(spoken) }
    }

    private func startSearch(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            dialog = .awaitingSearch
            say(.askSearch)
            return
        }
        cancelDialog()
        guard VoiceWorldInfo.isOnline else {
            say(.internetUnavailable)
            return
        }
        say(.searching)
        assistantTask?.cancel()
        assistantTask = Task { [weak self] in
            guard let self else { return }
            let result = await VoiceWorldInfo.search(q)
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let answer):
                self.speak(answer)
            case .failure(.offline):
                self.say(.internetUnavailable)
            case .failure(.failed):
                self.say(.searchFailed)
            case .failure(.noResult):
                self.say(.searchNoResult)
            }
        }
    }

    /// Returns false when the reply wasn't about the open question, so it runs as a normal command.
    private func handleDialog(_ intent: VoiceIntent) -> Bool {
        switch (dialog, intent) {
        case (_, .repeatLast), (_, .help), (_, .sleep):
            return false
        case (.confirming(let contact, let video), .call(let name, _)) where name.isEmpty:
            dial(contact, video: video)
            say(contact.isGroup ? .groupCalling(contact.name) : .calling(contact.name, video: video))
        case (.countdown, .call), (.countdown, .groupCall), (.lookingUp, .call), (.lookingUp, .groupCall), (.lookingUp, .yes):
            break
        case (.confirmingNumber(let e164, let video), .call(let name, _)) where name.isEmpty:
            startCountdown(numberContact(e164), video: video)
        case (.confirmingNumber(_, let video), .call(let spoken, _)) where !spoken.isEmpty:
            handleNumber(spoken, video: video, attempts: 1)
        case (.awaitingNumber(let video, let attempts), .call(let spoken, _)) where !spoken.isEmpty:
            handleNumber(spoken, video: video, attempts: attempts)
        case (.awaitingCountry(let digits, let video), .call(let spoken, _)):
            applyCountry(spoken, digits: digits, video: video)
        case (_, .call), (_, .groupCall):
            cancelDialog()
            return false
        case (.countdown, .cancel), (.countdown, .no), (.countdown, .hangUp),
             (.lookingUp, .cancel), (.lookingUp, .no), (.lookingUp, .hangUp):
            abortOutgoingDial()
        case (_, .cancel):
            cancelDialog()
            say(.canceled)
        case (.countdown(let contact, let video), .yes):
            dial(contact, video: video)
        case (.countdown, _), (.lookingUp, _):
            break
        case (.confirming(let contact, let video), .yes):
            dial(contact, video: video)
            say(contact.isGroup ? .groupCalling(contact.name) : .calling(contact.name, video: video))
        case (.confirming(_, let video), .no):
            dialog = .awaitingName(video: video, groupsOnly: false, attempts: 1)
            say(.askWho(video: video))
        case (.confirming(_, let video), .text(let name)) where !name.isEmpty:
            resolve(name, video: video, groupsOnly: false, attempts: 1)
        case (.choosing(let list, let video), .choose(let index)) where list.count <= 4:
            guard let contact = index == .max ? list.last : list[safe: index - 1] else {
                say(.choices(list.map(\.name)))
                return true
            }
            startCountdown(contact, video: video)
        case (.choosing(let list, let video), .text(let name)) where !name.isEmpty:
            resolve(name, video: video, groupsOnly: false, attempts: 1, within: list)
        case (.choosing(let list, _), .no):
            say(list.count <= 4 ? .choices(list.map(\.name)) : .canceled)
            if list.count > 4 { cancelDialog() }
        case (.awaitingName(let video, let groupsOnly, let attempts), .text(let name)) where !name.isEmpty:
            if VoiceSpokenNumber.looksLikeNumber(name, languageCode: language) {
                handleNumber(name, video: video, attempts: attempts)
            } else {
                resolve(name, video: video, groupsOnly: groupsOnly, attempts: attempts)
            }
        case (.awaitingName, .no):
            cancelDialog()
            say(.canceled)
        case (.confirmingNumber(let e164, let video), .yes):
            startCountdown(numberContact(e164), video: video)
        case (.confirmingNumber(_, let video), .no):
            dialog = .awaitingNumber(video: video, attempts: 1)
            say(.askNumber)
        case (.confirmingNumber(let e164, let video), .saveAs(let name)) where !name.isEmpty:
            saveNumber(e164, as: name, video: video)
        case (.confirmingNumber(_, let video), .text(let spoken)) where !spoken.isEmpty:
            handleNumber(spoken, video: video, attempts: 1)
        case (.awaitingNumber(let video, let attempts), .text(let spoken)) where !spoken.isEmpty:
            handleNumber(spoken, video: video, attempts: attempts)
        case (.awaitingNumber, .no):
            cancelDialog()
            say(.canceled)
        case (.awaitingCountry(let digits, let video), .text(let spoken)):
            applyCountry(spoken, digits: digits, video: video)
        case (.awaitingSearch, .search(let query)) where !query.isEmpty:
            startSearch(query)
        case (.awaitingSearch, .text(let query)) where !query.isEmpty:
            startSearch(query)
        case (.awaitingSearch, .no):
            cancelDialog()
            say(.canceled)
        default:
            return false
        }
        return true
    }

    private func handleCommand(_ intent: VoiceIntent, addressed: Bool) {
        switch intent {
        case .call(let name, let video):
            if ["number", "a number", "the number", "numero", "un numero", "номер"].contains(name) {
                dialog = .awaitingNumber(video: video, attempts: 0)
                say(.askNumber)
            } else if name.isEmpty {
                dialog = .awaitingName(video: video, groupsOnly: false, attempts: 0)
                say(.askWho(video: video))
            } else if VoiceSpokenNumber.looksLikeNumber(name, languageCode: language) {
                handleNumber(name, video: video, attempts: 0)
            } else {
                resolve(name, video: video, groupsOnly: false, attempts: 0)
            }
        case .groupCall(let name):
            if name.isEmpty {
                dialog = .awaitingName(video: true, groupsOnly: true, attempts: 0)
                say(.askWho(video: false))
            } else {
                resolve(name, video: true, groupsOnly: true, attempts: 0)
            }
        case .callBack: callBack()
        case .missedCalls: announceMissedCalls()
        case .answer: answer()
        case .decline: decline()
        case .whoIsCalling:
            if let call = currentCall, isIncomingRinging(call) { announceIncoming(call) } else { say(.noIncoming) }
        case .hangUp: hangUp()
        case .mute(let muted): withCall { self.setMuted(muted, call: $0) }
        case .hold(let held): withCall { self.setHeld(held, call: $0) }
        case .speaker(let on): withCall { self.setSpeaker(on, call: $0) }
        case .camera(let on): withCall { self.setCamera(on, call: $0) }
        case .flipCamera: withCall { self.flipCamera(call: $0) }
        case .join: withCall { _ in self.joinGroupCall() }
        case .status: withCall { self.announceStatus($0) }
        case .help: say(.help(inCall: currentCall != nil))
        case .repeatLast: lastPrompt.isEmpty ? say(.nothingToRepeat) : speak(lastPrompt)
        case .cancel:
            if currentCall != nil { hangUp() } else if addressed { say(.canceled) }
        case .sleep:
            cancelDialog()
            say(.sleeping)
            isSleeping = true
        case .wake: say(.awake)
        case .presenceCheck: say(.hearYou(paused: false, inCall: currentCall != nil))
        case .text(let name):
            if addressed, VoiceSpokenNumber.looksLikeNumber(name, languageCode: language) {
                handleNumber(name, video: false, attempts: 0)
                return
            }
            // "Hey Signal, Mom" most likely means "call Mom".
            if addressed, !name.isEmpty, case .one(let contact, _) = matchContact(name, groupsOnly: false) {
                dialog = .confirming(contact, video: false)
                say(.didYouMean(contact.name))
            } else if addressed {
                say(.didntCatch)
            }
        case .saveAs:
            say(.askNumber)
        case .tellTime:
            say(.currentTime(VoiceWorldInfo.spokenTime(language: language)))
        case .tellDate:
            say(.currentDate(VoiceWorldInfo.spokenDate(language: language)))
        case .checkInternet:
            say(VoiceWorldInfo.isOnline ? .internetAvailable : .internetUnavailable)
        case .search(let query):
            startSearch(query)
        case .yes, .no, .choose:
            if addressed { say(.didntCatch) }
        }
    }

    // MARK: - Finding people

    private func matchContact(_ name: String, groupsOnly: Bool, within pool: [VoiceContact]? = nil) -> VoiceContactMatcher.Result {
        loadDirectoryIfStale()
        return matcher.match(name, within: pool, groupsOnly: groupsOnly, languageCode: language)
    }

    private func resolve(_ name: String, video: Bool, groupsOnly: Bool, attempts: Int, within pool: [VoiceContact]? = nil) {
        switch matchContact(name, groupsOnly: groupsOnly, within: pool) {
        case .one(let contact, let confident):
            if confident {
                startCountdown(contact, video: video)
            } else {
                dialog = .confirming(contact, video: video)
                say(.didYouMean(contact.name))
            }
        case .several(let list):
            dialog = .choosing(list, video: video)
            say(list.count <= 4 ? .choices(list.map(\.name)) : .tooMany(list.count, name))
        case .none(let suggestion):
            if let pool, pool.count <= 4 {
                say(.choices(pool.map(\.name)))
            } else if let suggestion {
                dialog = .confirming(suggestion, video: video)
                say(.didYouMean(suggestion.name))
            } else if attempts >= 2 {
                cancelDialog()
                say(.notFoundAgain)
            } else if VoiceSpokenNumber.looksLikeNumber(name, languageCode: language) {
                handleNumber(name, video: video, attempts: attempts)
            } else {
                dialog = .awaitingName(video: video, groupsOnly: groupsOnly, attempts: attempts + 1)
                say(attempts == 0 ? .notFound(name) : .notFoundAgain)
            }
        }
    }

    private func handleNumber(_ spoken: String, video: Bool, attempts: Int) {
        guard let parsed = VoiceSpokenNumber.parse(spoken, languageCode: language) else {
            dialog = .awaitingNumber(video: video, attempts: attempts + 1)
            say(attempts >= 2 ? .numberInvalid : .askNumber)
            return
        }
        let util = SSKEnvironment.shared.phoneNumberUtilRef
        let local = DependenciesBridge.shared.tsAccountManager.localIdentifiersWithMaybeSneakyTransaction?.phoneNumber
        if parsed.plus, let number = util.parsePhoneNumber(userSpecifiedText: "+" + parsed.digits) ?? util.parseE164("+" + parsed.digits) {
            confirmOrDial(number.e164, video: video)
            return
        }
        let candidates = util.parsePhoneNumbers(userSpecifiedText: parsed.digits, localPhoneNumber: local)
        if let first = candidates.first {
            confirmOrDial(first.e164, video: video)
            return
        }
        dialog = .awaitingCountry(digits: parsed.digits, video: video)
        say(.askCountry)
    }

    private func applyCountry(_ spoken: String, digits: String, video: Bool) {
        let util = SSKEnvironment.shared.phoneNumberUtilRef
        if let parsed = VoiceSpokenNumber.parse(spoken, languageCode: language), parsed.plus,
           let number = util.parseE164("+" + parsed.digits) ?? util.parsePhoneNumber(userSpecifiedText: "+" + parsed.digits) {
            confirmOrDial(number.e164, video: video)
            return
        }
        guard let region = VoiceSpokenNumber.countryRegion(from: spoken, languageCode: language),
              let number = util.parsePhoneNumber(countryCode: region, nationalNumber: digits) else {
            say(.askCountry)
            return
        }
        confirmOrDial(number.e164, video: video)
    }

    private func isOwnNumber(_ e164: String) -> Bool {
        if SignalServiceAddress(phoneNumber: e164).isLocalAddress { return true }
        return DependenciesBridge.shared.tsAccountManager.localIdentifiersWithMaybeSneakyTransaction?.phoneNumber == e164
    }

    private func confirmOrDial(_ e164: String, video: Bool) {
        if isOwnNumber(e164) {
            dialog = .awaitingNumber(video: video, attempts: 1)
            say(.cantCallSelf)
            return
        }
        if let existing = contactForPhone(e164) {
            startCountdown(existing, video: video)
            return
        }
        dialog = .confirmingNumber(e164: e164, video: video)
        say(.confirmNumber(VoiceSpokenNumber.spoken(e164, languageCode: language)))
    }

    private func saveNumber(_ e164: String, as name: String, video: Bool) {
        var names = AutoSTTSettings.numberNicknames
        names[e164] = name.localizedCapitalized
        AutoSTTSettings.numberNicknames = names
        directoryLoadedAt = .distantPast
        say(.numberSaved(name.localizedCapitalized, VoiceSpokenNumber.spoken(e164, languageCode: language))) { [weak self] in
            self?.startCountdown(self?.numberContact(e164) ?? VoiceContact(id: "p:" + e164, name: name, isGroup: false, recency: 0), video: video)
        }
    }

    private func contactForPhone(_ e164: String) -> VoiceContact? {
        loadDirectoryIfStale()
        if let nick = AutoSTTSettings.numberNicknames[e164] { return numberContact(e164, name: nick) }
        for (id, target) in targets {
            if case .contact(let address) = target, address.phoneNumber == e164 || address.e164?.stringValue == e164 {
                return matcher.contacts.first { $0.id == id }
            }
        }
        return nil
    }

    private func numberContact(_ e164: String, name: String? = nil) -> VoiceContact {
        let id = "p:" + e164
        let display = name ?? AutoSTTSettings.numberNicknames[e164] ?? e164
        targets[id] = .contact(SignalServiceAddress(phoneNumber: e164))
        return VoiceContact(id: id, name: display, isGroup: false, recency: 0)
    }

    private func loadDirectoryIfStale() {
        guard Date().timeIntervalSince(directoryLoadedAt) > 300 else { return }
        directoryLoadedAt = Date()
        var contacts = [VoiceContact]()
        var targets = [String: Target]()
        SSKEnvironment.shared.databaseStorageRef.read { tx in
            let contactManager = SSKEnvironment.shared.contactManagerRef
            var rank = 0
            func addContact(_ address: SignalServiceAddress, recency: Int) {
                guard !address.isLocalAddress, let key = address.serviceIdString ?? address.phoneNumber else { return }
                let id = "c:" + key
                guard targets[id] == nil else { return }
                let name = contactManager.displayName(for: address, tx: tx).resolvedValue()
                guard !name.isEmpty else { return }
                contacts.append(VoiceContact(id: id, name: name, isGroup: false, recency: recency))
                targets[id] = .contact(address)
            }
            for isArchived in [false, true] {
                ThreadFinder().enumerateVisibleThreads(isArchived: isArchived, transaction: tx) { thread in
                    rank += 1
                    if let thread = thread as? TSContactThread {
                        addContact(thread.contactAddress, recency: rank)
                    } else if let thread = thread as? TSGroupThread, let groupId = try? thread.groupIdentifier {
                        let id = "g:" + thread.uniqueId
                        contacts.append(VoiceContact(id: id, name: thread.groupNameOrDefault, isGroup: true, recency: rank))
                        targets[id] = .group(groupId)
                    }
                }
            }
            SignalAccount.anyEnumerate(transaction: tx) { account, _ in
                addContact(account.recipientAddress, recency: 100_000)
            }
            for (e164, nick) in AutoSTTSettings.numberNicknames {
                let id = "p:" + e164
                guard targets[id] == nil else { continue }
                contacts.append(VoiceContact(id: id, name: nick, isGroup: false, recency: 50_000))
                targets[id] = .contact(SignalServiceAddress(phoneNumber: e164))
            }
        }
        matcher = VoiceContactMatcher(contacts: contacts)
        self.targets = targets
        Logger.info("Voice commands directory: \(contacts.count) names")
    }

    private func contact(for thread: TSThread, tx: DBReadTransaction) -> VoiceContact? {
        if let thread = thread as? TSContactThread, let key = thread.contactAddress.serviceIdString ?? thread.contactAddress.phoneNumber {
            let id = "c:" + key
            targets[id] = .contact(thread.contactAddress)
            return VoiceContact(id: id, name: SSKEnvironment.shared.contactManagerRef.displayName(for: thread.contactAddress, tx: tx).resolvedValue(), isGroup: false, recency: 0)
        }
        if let thread = thread as? TSGroupThread, let groupId = try? thread.groupIdentifier {
            let id = "g:" + thread.uniqueId
            targets[id] = .group(groupId)
            return VoiceContact(id: id, name: thread.groupNameOrDefault, isGroup: true, recency: 0)
        }
        return nil
    }

    // MARK: - Dialing

    private func spokenName(_ contact: VoiceContact) -> String {
        contact.name.hasPrefix("+") ? VoiceSpokenNumber.spoken(contact.name, languageCode: language) : contact.name
    }

    private func startCountdown(_ contact: VoiceContact, video: Bool, spoken: String? = nil) {
        if !contact.isGroup, let target = targets[contact.id], case .contact(let address) = target, address.isLocalAddress || isOwnNumber(address.phoneNumber ?? contact.name) {
            cancelDialog()
            say(.cantCallSelf)
            return
        }
        if !contact.isGroup, let target = targets[contact.id], case .contact(let address) = target, address.serviceId == nil {
            resolveRegisteredAddress(contact, video: video)
            return
        }
        beginCountdown(contact, video: video, spoken: spoken)
    }

    /// CDS lookup so we never start a 1:1 call with only a phone number (no ACI/PNI).
    private func resolveRegisteredAddress(_ contact: VoiceContact, video: Bool) {
        guard case .contact(let address) = targets[contact.id], let e164 = address.phoneNumber ?? E164(contact.name)?.stringValue else {
            cancelDialog()
            say(.cantCall(spokenName(contact)))
            return
        }
        if let known = registeredAddress(for: e164) {
            if known.isLocalAddress {
                cancelDialog()
                say(.cantCallSelf)
                return
            }
            targets[contact.id] = .contact(known)
            beginCountdown(contact, video: video)
            return
        }
        dialog = .lookingUp(contact, video: video)
        say(.lookingUpNumber)
        lookupTask?.cancel()
        lookupTask = Task { [weak self] in
            guard let self else { return }
            do {
                let recipients = try await SSKEnvironment.shared.contactDiscoveryManagerRef.lookUp(
                    phoneNumbers: [e164],
                    mode: .oneOffUserRequest,
                )
                guard !Task.isCancelled, case .lookingUp(let pending, let video) = self.dialog, pending == contact else { return }
                guard let recipient = recipients.first, recipient.isRegistered, recipient.address.serviceId != nil else {
                    self.dialog = .awaitingNumber(video: video, attempts: 1)
                    self.say(.numberNotOnSignal)
                    return
                }
                if recipient.address.isLocalAddress {
                    self.cancelDialog()
                    self.say(.cantCallSelf)
                    return
                }
                self.targets[contact.id] = .contact(recipient.address)
                self.beginCountdown(contact, video: video)
            } catch {
                guard !Task.isCancelled, case .lookingUp(let pending, let video) = self.dialog, pending == contact else { return }
                self.dialog = .awaitingNumber(video: video, attempts: 1)
                self.say(.numberLookupFailed)
            }
        }
    }

    private func registeredAddress(for e164: String) -> SignalServiceAddress? {
        SSKEnvironment.shared.databaseStorageRef.read { tx in
            let recipient = DependenciesBridge.shared.recipientDatabaseTable.fetchRecipient(phoneNumber: e164, transaction: tx)
            guard let recipient, recipient.isRegistered, recipient.address.serviceId != nil else { return nil }
            return recipient.address
        }
    }

    private func beginCountdown(_ contact: VoiceContact, video: Bool, spoken: String? = nil) {
        dialog = .countdown(contact, video: video)
        let line = spoken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let afterSpeak: () -> Void = { [weak self] in
            self?.countdown = Task { [weak self] in
                // Time for "cancel" after the prompt, including the recognizer's finalization delay.
                try? await Task.sleep(for: .seconds(2.5))
                guard let self, !Task.isCancelled, case .countdown(let pending, let video) = self.dialog, pending == contact else { return }
                self.dial(pending, video: video)
            }
        }
        if line.isEmpty {
            say(contact.isGroup ? .groupCalling(contact.name) : .calling(spokenName(contact), video: video), then: afterSpeak)
        } else {
            speak(line, then: afterSpeak)
        }
    }

    private func cancelDialog() {
        countdown?.cancel()
        lookupTask?.cancel()
        assistantTask?.cancel()
        dialogTimeout?.cancel()
        dialog = .none
    }

    private func dial(_ contact: VoiceContact, video: Bool) {
        cancelDialog()
        guard let target = targets[contact.id], let presenter = CurrentAppContext().frontmostViewController() else {
            say(.cantCall(contact.name))
            return
        }
        Task {
            await pauseListening(for: 5)
            let context = CallStarter.Context(
                blockingManager: SSKEnvironment.shared.blockingManagerRef,
                databaseStorage: SSKEnvironment.shared.databaseStorageRef,
                callService: callService,
            )
            let starter: CallStarter
            switch target {
            case .contact(let address):
                if address.isLocalAddress || isOwnNumber(address.phoneNumber ?? "") {
                    say(.cantCallSelf)
                    return
                }
                guard address.serviceId != nil else {
                    say(.numberNotOnSignal)
                    return
                }
                let thread = TSContactThread.getOrCreateThread(contactAddress: address)
                if thread.isNoteToSelf || !thread.canCall {
                    say(thread.isNoteToSelf ? .cantCallSelf : .cantCall(spokenName(contact)))
                    return
                }
                starter = CallStarter(contactThread: thread, withVideo: video, context: context)
            case .group(let groupId):
                pendingGroupJoin = (groupId, video, Date().addingTimeInterval(15))
                starter = CallStarter(groupId: groupId, context: context)
            }
            switch starter.startCall(from: presenter) {
            case .callStarted: break
            case .promptedToUnblock: say(.blocked(contact.name))
            case .callNotStarted: say(.cantCall(contact.name))
            }
        }
    }

    private func callBack() {
        var latest: VoiceContact?
        SSKEnvironment.shared.databaseStorageRef.read { tx in
            guard let cursor = DependenciesBridge.shared.callRecordQuerier.fetchCursor(ordering: .descending, tx: tx) else { return }
            while latest == nil, let record = (try? cursor.next()) ?? nil {
                guard case .thread(let rowId) = record.conversationId,
                      let thread = DependenciesBridge.shared.threadStore.fetchThread(rowId: rowId, tx: tx) else { continue }
                latest = contact(for: thread, tx: tx)
            }
        }
        guard let latest else { return say(.nothingToRedial) }
        startCountdown(latest, video: false)
    }

    private func announceMissedCalls() {
        var records = [CallRecord]()
        var items = [String]()
        SSKEnvironment.shared.databaseStorageRef.read { tx in
            for status in CallRecord.CallStatus.missedCalls {
                guard let cursor = DependenciesBridge.shared.callRecordQuerier.fetchCursor(callStatus: status, ordering: .descending, tx: tx) else { continue }
                while records.count < 12, let record = (try? cursor.next()) ?? nil { records.append(record) }
            }
            records.sort { $0.callBeganTimestamp > $1.callBeganTimestamp }
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = Locale(identifier: language)
            formatter.unitsStyle = .full
            for record in records.prefix(3) {
                guard case .thread(let rowId) = record.conversationId,
                      let thread = DependenciesBridge.shared.threadStore.fetchThread(rowId: rowId, tx: tx),
                      let contact = contact(for: thread, tx: tx) else { continue }
                let date = Date(millisecondsSince1970: record.callBeganTimestamp)
                items.append("\(contact.name), \(formatter.localizedString(for: date, relativeTo: Date()))")
            }
        }
        say(items.isEmpty ? .noMissed : .missed(items))
    }

    // MARK: - Call control

    private func withCall(_ action: (SignalCall) -> Void) {
        guard let call = currentCall else { return say(.noCall) }
        action(call)
    }

    private func isIncomingRinging(_ call: SignalCall) -> Bool {
        switch call.mode {
        case .individual(let individual):
            return individual.direction == .incoming && [.localRinging_Anticipatory, .localRinging_ReadyToAnswer].contains(individual.state)
        case .groupThread(let group):
            if case .incomingRing = group.groupCallRingState { return !group.hasJoinedOrIsWaitingForAdminApproval }
            return false
        case .callLink:
            return false
        }
    }

    private func isOutgoingRinging(_ call: SignalCall) -> Bool {
        guard case .individual(let individual) = call.mode else { return false }
        return individual.direction == .outgoing && [.dialing, .remoteRinging].contains(individual.state)
    }

    /// Whether WebRTC owns the audio session, so our listener has to share it.
    private func isAudioLive(_ call: SignalCall) -> Bool {
        switch call.mode {
        case .individual(let individual):
            return [.dialing, .remoteRinging, .answering, .accepting, .connected, .reconnecting].contains(individual.state)
        case .groupThread(let group as GroupCall), .callLink(let group as GroupCall):
            return group.joinState != .notJoined
        }
    }

    private func name(of call: SignalCall) -> String {
        SSKEnvironment.shared.databaseStorageRef.read { tx in
            switch call.mode {
            case .individual(let individual):
                return SSKEnvironment.shared.contactManagerRef.displayName(for: individual.remoteAddress, tx: tx).resolvedValue()
            case .groupThread(let group):
                let groupName = TSGroupThread.fetchThread(forGroupId: group.groupId, tx: tx)?.groupNameOrDefault ?? ""
                guard let caller = call.caller else { return groupName }
                return "\(SSKEnvironment.shared.contactManagerRef.displayName(for: caller, tx: tx).resolvedValue()), \(groupName)"
            case .callLink:
                return ""
            }
        }
    }

    private func announceIncoming(_ call: SignalCall) {
        var video = false
        if case .individual(let individual) = call.mode { video = individual.offerMediaType == .video }
        say(.incoming(name(of: call), video: video))
    }

    private func answer() {
        guard let call = currentCall, isIncomingRinging(call) else { return say(.noIncoming) }
        Task {
            await pauseListening(for: 3)
            callService.callUIAdapter.answerCall(call)
        }
    }

    private func decline() {
        guard let call = currentCall else { return say(.noIncoming) }
        _ = releaseCallAudio()
        callService.callUIAdapter.localHangupCall(call)
    }

    private func abortOutgoingDial() {
        cancelDialog()
        say(.cancellingCall, immediately: true)
    }

    private func hangUp() {
        if case .countdown = dialog {
            abortOutgoingDial()
            return
        }
        if case .lookingUp = dialog {
            abortOutgoingDial()
            return
        }
        guard currentCall != nil else { return say(.noCall) }
        suppressCallEnded = true
        say(.cancellingCall, immediately: true) { [weak self] in
            guard let self else { return }
            _ = self.releaseCallAudio()
            if let call = self.currentCall {
                self.callService.callUIAdapter.localHangupCall(call)
            }
        }
    }

    private func setMuted(_ muted: Bool, call: SignalCall) {
        callService.updateIsLocalAudioMuted(isLocalAudioMuted: muted)
        callService.callUIAdapter.setIsMuted(call: call, isMuted: muted)
        say(.muted(muted))
    }

    private func setHeld(_ held: Bool, call: SignalCall) {
        switch call.mode {
        case .individual(let individual):
            guard individual.isOnHold != held else { return say(.onHold(held)) }
            callService.individualCallService.setIsOnHold(call: call, isOnHold: held)
            say(.onHold(held))
        case .groupThread, .callLink:
            if held {
                groupHoldRestore = (call.isOutgoingAudioMuted, call.isOutgoingVideoMuted)
                callService.updateIsLocalAudioMuted(isLocalAudioMuted: true)
                callService.updateIsLocalVideoMuted(isLocalVideoMuted: true)
                say(.holdUnsupported)
            } else {
                let restore = groupHoldRestore ?? (false, call.isOutgoingVideoMuted)
                groupHoldRestore = nil
                callService.updateIsLocalAudioMuted(isLocalAudioMuted: restore.audioMuted)
                callService.updateIsLocalVideoMuted(isLocalVideoMuted: restore.videoMuted)
                say(.onHold(false))
            }
        }
    }

    private func setSpeaker(_ on: Bool, call: SignalCall) {
        guard !callService.audioService.hasExternalInputs else { return say(.noSpeakerRoute) }
        callService.audioService.requestSpeakerphone(call: call, isEnabled: on)
        say(.speaker(on))
    }

    private func setCamera(_ on: Bool, call: SignalCall) {
        callService.updateIsLocalVideoMuted(isLocalVideoMuted: !on)
        say(.camera(on))
    }

    private func flipCamera(call: SignalCall) {
        let isFront = call.videoCaptureController.isUsingFrontCamera ?? true
        callService.updateCameraSource(call: call, isUsingFrontCamera: !isFront)
        say(.cameraFlipped)
    }

    private func joinGroupCall() {
        guard let controller = groupCallViewController() else { return say(.noCall) }
        say(.joining)
        controller.didPressJoin()
    }

    private func groupCallViewController() -> GroupCallViewController? {
        var queue = [AppEnvironment.shared.windowManagerRef.callViewWindow.rootViewController].compactMap { $0 }
        while !queue.isEmpty {
            let controller = queue.removeFirst()
            if let match = controller as? GroupCallViewController { return match }
            queue += controller.children
            if let presented = controller.presentedViewController { queue.append(presented) }
        }
        return nil
    }

    private func announceStatus(_ call: SignalCall) {
        var details = [VoicePrompt.StatusDetail]()
        if isOutgoingRinging(call) { details.append(.ringing) }
        if call.isOutgoingAudioMuted { details.append(.muted) }
        if case .individual(let individual) = call.mode, individual.isOnHold { details.append(.onHold) }
        if callService.audioService.isSpeakerEnabled { details.append(.speaker) }
        if !call.isOutgoingVideoMuted { details.append(.camera) }
        say(.status(name(of: call), details))
    }

    // MARK: - Speaking

    private func say(_ prompt: VoicePrompt, immediately: Bool = false, then completion: (() -> Void)? = nil) {
        speak(prompt.text(language), immediately: immediately, then: completion)
    }

    private func speak(_ text: String, immediately: Bool = false, then completion: (() -> Void)? = nil) {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        Logger.info("Voice commands say: \(text)")
        lastPrompt = text
        status.reply = text
        ignoreAfterSpeech = 0.35
        ignoreHearingUntil = .distantFuture
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = OnDeviceTTS.bestVoice(for: language, allowPersonalVoice: false)
        utterance.prefersAssistiveTechnologySettings = true
        utterance.preUtteranceDelay = immediately ? 0 : 0.45
        speakingSince = Date()
        afterSpeaking = completion
        synthesizer.speak(utterance)
    }

    private func didFinishSpeaking() {
        if let since = speakingSince { lastSpeech = (since, Date(), lastPrompt) }
        speakingSince = nil
        ignoreHearingUntil = Date().addingTimeInterval(ignoreAfterSpeech)
        let completion = afterSpeaking
        afterSpeaking = nil
        completion?()
        switch dialog {
        case .awaitingName, .choosing, .confirming, .awaitingNumber, .confirmingNumber, .awaitingCountry, .awaitingSearch:
            AudioServicesPlaySystemSound(1113)
            dialogTimeout?.cancel()
            dialogTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(12))
                guard let self, !Task.isCancelled, self.dialog != .none, self.speakingSince == nil else { return }
                self.cancelDialog()
                self.say(.timeout)
            }
        case .none, .countdown, .lookingUp:
            break
        }
    }
}

// MARK: - Observers

@available(iOS 26, *)
extension VoiceCommandService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.didFinishSpeaking() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            // A newer prompt interrupted this one; only its own timing is kept.
            if !self.synthesizer.isSpeaking { self.didFinishSpeaking() }
        }
    }
}

@available(iOS 26, *)
extension VoiceCommandService: CallServiceStateObserver {
    func didUpdateCall(from oldValue: SignalCall?, to newValue: SignalCall?) {
        if let newValue {
            switch newValue.mode {
            case .individual(let individual):
                individual.addObserverAndSyncState(self)
            case .groupThread(let group as GroupCall), .callLink(let group as GroupCall):
                group.addObserver(self, syncStateImmediately: true)
                autoJoinIfRequested(newValue)
            }
        } else if oldValue != nil, isEnabled {
            announcedCall = nil
            groupHoldRestore = nil
            if suppressCallEnded {
                suppressCallEnded = false
            } else {
                say(.callEnded)
            }
        }
        refresh()
    }

    private func autoJoinIfRequested(_ call: SignalCall) {
        guard let pending = pendingGroupJoin, Date() < pending.until, case .groupThread(let group) = call.mode, group.groupId == pending.id else { return }
        pendingGroupJoin = nil
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, let controller = self.groupCallViewController() else { return }
            controller.didPressJoin()
            if !pending.video { self.callService.updateIsLocalVideoMuted(isLocalVideoMuted: true) }
        }
    }
}

@available(iOS 26, *)
extension VoiceCommandService: IndividualCallObserver {
    func individualCallStateDidChange(_ call: IndividualCall, state: CallState) {
        if let current = currentCall, case .individual(let individual) = current.mode, individual === call,
           isIncomingRinging(current), announcedCall != ObjectIdentifier(call), isEnabled, !isSleeping {
            announcedCall = ObjectIdentifier(call)
            announceIncoming(current)
        }
        refresh()
    }
}

@available(iOS 26, *)
extension VoiceCommandService: GroupCallObserver {
    func groupCallLocalDeviceStateChanged(_ call: GroupCall) {
        refresh()
    }
}
