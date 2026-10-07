//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// Chat list panel showing what voice commands heard and what they answered. Tap to pause or resume.
@available(iOS 26, *)
final class VoiceCommandBanner: UIView {
    private let icon = UIImageView()
    private let heardLabel = UILabel()
    private let replyLabel = UILabel()
    private let onEnabledChange: () -> Void
    private var wasEnabled: Bool?

    init(onEnabledChange: @escaping () -> Void) {
        self.onEnabledChange = onEnabledChange
        super.init(frame: .zero)

        let background = UIVisualEffectView(effect: UIGlassEffect())
        background.layer.cornerRadius = 20
        background.clipsToBounds = true
        addSubview(background)
        background.autoPinEdgesToSuperviewEdges()

        icon.contentMode = .scaleAspectFit
        icon.autoSetDimensions(to: CGSize(square: 24))
        heardLabel.font = .dynamicTypeSubheadline.semibold()
        heardLabel.textColor = .Signal.label
        heardLabel.numberOfLines = 2
        replyLabel.font = .dynamicTypeFootnote
        replyLabel.textColor = .Signal.secondaryLabel
        replyLabel.numberOfLines = 3

        let text = UIStackView(arrangedSubviews: [heardLabel, replyLabel])
        text.axis = .vertical
        text.spacing = 2
        let row = UIStackView(arrangedSubviews: [icon, text])
        row.spacing = 12
        row.alignment = .center
        background.contentView.addSubview(row)
        row.autoPinEdgesToSuperviewEdges(with: UIEdgeInsets(hMargin: 16, vMargin: 12))

        isAccessibilityElement = true
        accessibilityTraits = .button
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(didTap)))
        NotificationCenter.default.addObserver(self, selector: #selector(update), name: .voiceCommandStatusDidChange, object: nil)
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc
    private func didTap() {
        VoiceCommandService.shared.toggle()
    }

    @objc
    private func update() {
        let service = VoiceCommandService.shared
        let status = service.status
        isHidden = !service.isEnabled
        if wasEnabled != service.isEnabled {
            wasEnabled = service.isEnabled
            onEnabledChange()
        }
        let symbol = status.isSleeping ? "moon.zzz.fill" : status.isListening ? "waveform" : "mic.slash"
        icon.image = UIImage(systemName: symbol)
        icon.tintColor = status.isListening && !status.isSleeping ? .Signal.accent : .Signal.secondaryLabel
        if status.isListening, !status.isSleeping {
            icon.addSymbolEffect(.variableColor.iterative, options: .repeating)
        } else {
            icon.removeAllSymbolEffects()
        }
        heardLabel.text = status.heard.isEmpty
            ? OWSLocalizedString("VOICE_COMMANDS_BANNER_HINT", comment: "Shown on the chat list while voice commands listen and nothing was heard yet.")
            : "“\(status.heard)”"
        replyLabel.text = status.reply
        replyLabel.isHidden = status.reply.isEmpty
        accessibilityLabel = [heardLabel.text, status.reply].compactMap { $0 }.joined(separator: ". ")
        accessibilityHint = OWSLocalizedString("VOICE_COMMANDS_BANNER_A11Y_HINT", comment: "Accessibility hint for the voice commands banner on the chat list.")
    }
}

@available(iOS 26, *)
extension ChatListViewController {
    func installVoiceCommandBanner(onEnabledChange: @escaping () -> Void) {
        let banner = VoiceCommandBanner(onEnabledChange: onEnabledChange)
        view.addSubview(banner)
        banner.autoPinEdge(toSuperviewSafeArea: .leading, withInset: 12)
        banner.autoPinEdge(toSuperviewSafeArea: .trailing, withInset: 12)
        banner.autoPinEdge(toSuperviewSafeArea: .bottom, withInset: 8)
        VoiceCommandService.shared.startIfEnabled()
    }

    func voiceCommandBarButton() -> UIBarButtonItem? {
        let service = VoiceCommandService.shared
        let item = UIBarButtonItem.button(icon: .buttonMicrophone, isProminent: service.isEnabled) {
            VoiceCommandService.shared.setEnabled(!VoiceCommandService.shared.isEnabled)
        }
        item.accessibilityLabel = service.isEnabled
            ? OWSLocalizedString("VOICE_COMMANDS_BUTTON_TURN_OFF", comment: "Accessibility label for the chat list button that turns voice commands off.")
            : OWSLocalizedString("VOICE_COMMANDS_BUTTON_TURN_ON", comment: "Accessibility label for the chat list button that turns voice commands on.")
        return item
    }
}
