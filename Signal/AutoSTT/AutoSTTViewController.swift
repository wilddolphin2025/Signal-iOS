//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// A TTS-rendered voice note, sent through the regular voice-message pipeline.
struct SynthesizedVoiceNoteDraft: VoiceMessageSendableDraft {
    let url: URL

    func prepareForSending() throws -> URL { url }
}

/// Live dictation ("STT chat") or voice-message transcription, with speaker turns, timestamps and TTS.
@available(iOS 26, *)
final class AutoSTTViewController: OWSViewController {
    enum Source {
        case microphone
        /// A decrypted temporary copy; deleted when the sheet closes.
        case file(URL)
    }

    private let source: Source
    private let onInsertText: ((String) -> Void)?
    private let onSendVoiceNote: ((URL) -> Void)?

    private var session: OnDeviceSTTSession?
    private var transcript = STTTranscript()
    private var languageCode = AutoSTTSettings.preferredLanguageCode
    private var isRunning = false
    private var hasStarted = false

    private let statusLabel = UILabel()
    private let textView = UITextView()
    private let buttonRow = UIStackView()

    private static let speakerColors: [UIColor] = [.systemBlue, .systemOrange, .systemGreen, .systemPurple, .systemPink, .systemTeal]

    private var isMicrophone: Bool {
        if case .microphone = source { return true }
        return false
    }

    static func present(
        from presenter: UIViewController,
        source: Source,
        onInsertText: ((String) -> Void)? = nil,
        onSendVoiceNote: ((URL) -> Void)? = nil,
    ) {
        let controller = AutoSTTViewController(source: source, onInsertText: onInsertText, onSendVoiceNote: onSendVoiceNote)
        let navigationController = OWSNavigationController(rootViewController: controller)
        if let sheet = navigationController.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        presenter.present(navigationController, animated: true)
    }

    private init(source: Source, onInsertText: ((String) -> Void)?, onSendVoiceNote: ((URL) -> Void)?) {
        self.source = source
        self.onInsertText = onInsertText
        self.onSendVoiceNote = onSendVoiceNote
        super.init()
    }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .Signal.background
        title = isMicrophone
            ? OWSLocalizedString("AUTO_STT_DICTATE_TITLE", comment: "Title of the on-device dictation sheet.")
            : OWSLocalizedString("AUTO_STT_TRANSCRIPT_TITLE", comment: "Title of the voice message transcript sheet.")
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })

        statusLabel.font = .dynamicTypeFootnote
        statusLabel.textColor = .Signal.secondaryLabel
        statusLabel.numberOfLines = 0

        textView.isEditable = false
        textView.backgroundColor = .clear
        textView.font = .dynamicTypeBody
        textView.adjustsFontForContentSizeCategory = true

        buttonRow.axis = .horizontal
        buttonRow.distribution = .fillEqually
        buttonRow.spacing = 8

        let stack = UIStackView(arrangedSubviews: [statusLabel, textView, buttonRow])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -12),
        ])
        render()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasStarted else { return }
        hasStarted = true
        start()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard navigationController?.isBeingDismissed ?? isBeingDismissed else { return }
        AppEnvironment.shared.speechManagerRef.stop()
        let session = self.session
        Task { await session?.cancel() }
        if case .file(let url) = source {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Transcription

    private func start() {
        isRunning = true
        render()
        Task { [weak self] in
            guard let self else { return }
            if case .file(let url) = source, AutoSTTSettings.language == .automatic {
                statusLabel.text = OWSLocalizedString("AUTO_STT_STATUS_DETECTING", comment: "Shown while detecting the spoken language of a voice message.")
                languageCode = await OnDeviceSTTSession.detectLanguage(fileURL: url)
            }
            let session = OnDeviceSTTSession(options: .current(languageCode: languageCode, timeOffset: transcript.finals.last?.end ?? 0))
            self.session = session
            let events = Task { [weak self] in
                for await event in session.events { self?.apply(event) }
            }
            do {
                switch source {
                case .microphone: try await session.startMicrophone()
                case .file(let url): try await session.transcribe(fileURL: url)
                }
            } catch {
                Logger.warn("AutoSTT failed: \(error)")
                await session.cancel()
                statusLabel.text = error.localizedDescription
            }
            await events.value
            isRunning = false
            render()
        }
    }

    private func stopListening() {
        let session = self.session
        Task { await session?.stop() }
    }

    private func apply(_ event: STTEvent) {
        transcript.apply(event)
        render()
    }

    // MARK: Rendering

    private var showsSpeakers: Bool { AutoSTTSettings.diarization && transcript.speakerCount > 1 }

    private var currentText: String {
        let finals = transcript.text(includeSpeakers: showsSpeakers)
        guard let partial = transcript.partial?.text, !partial.isEmpty else { return finals }
        return finals.isEmpty ? partial : finals + "\n" + partial
    }

    private func render() {
        guard isViewLoaded else { return }
        let output = NSMutableAttributedString()
        for turn in transcript.turns {
            if showsSpeakers || !isMicrophone {
                let speaker = showsSpeakers ? turn.speaker.map { STTTranscript.speakerName($0) + " · " } ?? "" : ""
                output.append(NSAttributedString(string: speaker + Self.timestamp(turn.start) + "\n", attributes: [
                    .font: UIFont.dynamicTypeFootnote.semibold(),
                    .foregroundColor: turn.speaker.map { Self.speakerColors[$0 % Self.speakerColors.count] } ?? UIColor.Signal.secondaryLabel,
                ]))
            }
            output.append(NSAttributedString(string: turn.text + "\n\n", attributes: [.font: UIFont.dynamicTypeBody, .foregroundColor: UIColor.Signal.label]))
        }
        if let partial = transcript.partial {
            output.append(NSAttributedString(string: partial.text, attributes: [.font: UIFont.dynamicTypeBody, .foregroundColor: UIColor.Signal.secondaryLabel]))
        }
        textView.attributedText = output
        textView.scrollRangeToVisible(NSRange(location: output.length, length: 0))
        if isRunning || transcript.finals.isEmpty == false { statusLabel.text = statusText }
        updateButtons()
    }

    private var statusText: String {
        var parts = [
            isRunning
                ? (isMicrophone ? OWSLocalizedString("AUTO_STT_STATUS_LISTENING", comment: "Shown while on-device dictation is listening.") : OWSLocalizedString("AUTO_STT_STATUS_TRANSCRIBING", comment: "Shown while a voice message is being transcribed."))
                : OWSLocalizedString("AUTO_STT_STATUS_DONE", comment: "Shown when transcription has finished."),
            AutoSTTLanguage(rawValue: languageCode)?.displayName ?? languageCode,
            OWSLocalizedString("AUTO_STT_STATUS_ON_DEVICE", comment: "Indicates speech processing happens only on this iPhone."),
        ]
        if AutoSTTSettings.smartFormat { parts.append(OnDeviceLanguageModel.statusText) }
        return parts.joined(separator: " · ")
    }

    private func updateButtons() {
        buttonRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let hasText = !currentText.isEmpty
        if isMicrophone {
            buttonRow.addArrangedSubview(isRunning
                ? button(OWSLocalizedString("AUTO_STT_STOP", comment: "Stops on-device dictation."), "stop.circle.fill", filled: true) { [weak self] in self?.stopListening() }
                : button(OWSLocalizedString("AUTO_STT_LISTEN", comment: "Starts on-device dictation."), "mic.fill", filled: true) { [weak self] in self?.start() })
        }
        buttonRow.addArrangedSubview(button(OWSLocalizedString("AUTO_STT_SPEAK", comment: "Reads the transcript aloud with on-device text-to-speech."), "speaker.wave.2.fill", enabled: hasText) { [weak self] in
            guard let self else { return }
            let speech = AppEnvironment.shared.speechManagerRef
            speech.isSpeaking ? speech.stop() : OnDeviceTTS.speak(currentText)
        })
        if isMicrophone {
            buttonRow.addArrangedSubview(button(OWSLocalizedString("AUTO_STT_SEND_VOICE", comment: "Converts the transcript to speech and sends it as a voice message."), "waveform", enabled: hasText && !isRunning) { [weak self] in
                self?.sendAsVoiceNote()
            })
            buttonRow.addArrangedSubview(button(OWSLocalizedString("AUTO_STT_INSERT", comment: "Inserts the transcript into the message composer."), "text.insert", enabled: hasText) { [weak self] in
                guard let self else { return }
                let text = transcript.text(includeSpeakers: false)
                dismiss(animated: true) { [onInsertText] in onInsertText?(text) }
            })
        } else {
            buttonRow.addArrangedSubview(button(CommonStrings.copyButton, "doc.on.doc", enabled: hasText) { [weak self] in
                guard let self else { return }
                UIPasteboard.general.string = currentText
                presentToast(text: OWSLocalizedString("AUTO_STT_COPIED", comment: "Toast after copying a transcript."))
            })
        }
    }

    private func sendAsVoiceNote() {
        let text = transcript.text(includeSpeakers: false)
        ModalActivityIndicatorViewController.present(fromViewController: self, canCancel: false, asyncBlock: { [weak self] modal in
            do {
                let url = try await OnDeviceTTS.renderVoiceNote(text)
                modal.dismiss {
                    self?.dismiss(animated: true) { [onSendVoiceNote = self?.onSendVoiceNote] in onSendVoiceNote?(url) }
                }
            } catch {
                Logger.warn("AutoSTT voice note failed: \(error)")
                modal.dismiss { OWSActionSheets.showErrorAlert(message: error.localizedDescription) }
            }
        })
    }

    private func button(_ title: String, _ symbol: String, filled: Bool = false, enabled: Bool = true, action: @escaping () -> Void) -> UIButton {
        var configuration: UIButton.Configuration = filled ? .filled() : .tinted()
        configuration.image = UIImage(systemName: symbol)
        configuration.title = title
        configuration.imagePlacement = .top
        configuration.imagePadding = 4
        configuration.cornerStyle = .large
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var attributes = $0
            attributes.font = UIFont.dynamicTypeCaption1
            return attributes
        }
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
        button.isEnabled = enabled
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        return button
    }

    private static func timestamp(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
