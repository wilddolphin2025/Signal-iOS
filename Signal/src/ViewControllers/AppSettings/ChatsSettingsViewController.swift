//
// Copyright 2021 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import IntentsUI
import SignalServiceKit
import SignalUI

class ChatsSettingsViewController: OWSTableViewController2 {

    override func viewDidLoad() {
        super.viewDidLoad()

        title = OWSLocalizedString("SETTINGS_CHATS", comment: "Title for the 'chats' link in settings.")

        updateTableContents()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateTableContents),
            name: .syncManagerConfigurationSyncDidComplete,
            object: nil,
        )
    }

    private var languageModelStatusTask: Task<Void, Never>?

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard #available(iOS 26, *) else { return }
        // The language model downloads in the background; refresh the AutoSTT footer when its status changes.
        languageModelStatusTask = Task { [weak self] in
            var status = OnDeviceLanguageModel.statusText
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard OnDeviceLanguageModel.statusText != status else { continue }
                status = OnDeviceLanguageModel.statusText
                self?.updateTableContents()
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        languageModelStatusTask?.cancel()
    }

    @objc
    private func updateTableContents() {
        let contents = OWSTableContents()

        let linkPreviewSection = OWSTableSection()
        linkPreviewSection.footerTitle = OWSLocalizedString(
            "SETTINGS_LINK_PREVIEWS_FOOTER",
            comment: "Footer for setting for enabling & disabling link previews.",
        )
        linkPreviewSection.add(.switch(
            withText: OWSLocalizedString(
                "SETTINGS_LINK_PREVIEWS",
                comment: "Setting for enabling & disabling link previews.",
            ),
            isOn: {
                SSKEnvironment.shared.databaseStorageRef.read { DependenciesBridge.shared.linkPreviewSettingStore.areLinkPreviewsEnabled(tx: $0) }
            },
            actionBlock: { [weak self] uiSwitch in
                self?.didToggleLinkPreviewsEnabled(uiSwitch)
            },
        ))
        contents.add(linkPreviewSection)

        let sharingSuggestionsSection = OWSTableSection()
        sharingSuggestionsSection.footerTitle = OWSLocalizedString(
            "SETTINGS_SHARING_SUGGESTIONS_NOTIFICATIONS_FOOTER",
            comment: "Footer for setting for enabling & disabling contact and notification sharing with iOS.",
        )

        sharingSuggestionsSection.add(.switch(
            withText: OWSLocalizedString(
                "SETTINGS_SHARING_SUGGESTIONS",
                comment: "Setting for enabling & disabling iOS contact sharing.",
            ),
            isOn: {
                SSKEnvironment.shared.databaseStorageRef.read { SSKPreferences.areIntentDonationsEnabled(transaction: $0) }
            },
            actionBlock: { [weak self] uiSwitch in
                self?.didToggleSharingSuggestionsEnabled(uiSwitch)
            },
        ))
        contents.add(sharingSuggestionsSection)

        let contactSection = OWSTableSection()
        contactSection.footerTitle = OWSLocalizedString(
            "SETTINGS_APPEARANCE_AVATAR_FOOTER",
            comment: "Footer for avatar section in appearance settings",
        )
        contactSection.add(.switch(
            withText: OWSLocalizedString(
                "SETTINGS_APPEARANCE_AVATAR_PREFERENCE_LABEL",
                comment: "Title for switch to toggle preference between contact and profile avatars",
            ),
            isOn: {
                SSKEnvironment.shared.databaseStorageRef.read { SSKPreferences.preferContactAvatars(transaction: $0) }
            },
            actionBlock: { [weak self] uiSwitch in
                self?.didToggleAvatarPreference(uiSwitch)
            },
        ))
        contents.add(contactSection)

        let keepMutedChatsArchived = OWSTableSection()
        keepMutedChatsArchived.add(.switch(
            withText: OWSLocalizedString("SETTINGS_KEEP_MUTED_ARCHIVED_LABEL", comment: "When a chat is archived and receives a new message, it is unarchived. Turning this switch on disables this feature if the chat in question is also muted. This string is a brief label for a switch paired with a longer description underneath, in the Chats settings."),
            isOn: {
                SSKEnvironment.shared.databaseStorageRef.read { SSKPreferences.shouldKeepMutedChatsArchived(transaction: $0) }
            },
            actionBlock: { [weak self] uiSwitch in
                self?.didToggleShouldKeepMutedChatsArchivedSwitch(uiSwitch)
            },
        ))
        keepMutedChatsArchived.footerTitle = OWSLocalizedString(
            "SETTINGS_KEEP_MUTED_ARCHIVED_DESCRIPTION",
            comment: "When a chat is archived and receives a new message, it is unarchived. Turning this switch on disables this feature if the chat in question is also muted. This string is a thorough description paired with a labeled switch above, in the Chats settings.",
        )
        contents.add(keepMutedChatsArchived)

        if #available(iOS 26, *) {
            contents.add(autoSTTSection())
            contents.add(voiceCommandsSection())
        }

        let clearHistorySection = OWSTableSection()
        clearHistorySection.add(.item(
            name: OWSLocalizedString("SETTINGS_CLEAR_HISTORY", comment: ""),
            textColor: .Signal.red,
            accessibilityIdentifier: UIView.accessibilityIdentifier(in: self, name: "clear_chat_history"),
            actionBlock: { [weak self] in
                self?.didTapClearHistory()
            },
        ))
        contents.add(clearHistorySection)

        self.contents = contents
    }

    private func didToggleLinkPreviewsEnabled(_ sender: UISwitch) {
        Logger.info("toggled to: \(sender.isOn)")
        let db = DependenciesBridge.shared.db
        db.write { tx in
            let linkPreviewSettingManager = DependenciesBridge.shared.linkPreviewSettingManager
            linkPreviewSettingManager.setAreLinkPreviewsEnabled(sender.isOn, shouldSendSyncMessage: true, tx: tx)
        }
    }

    private func didToggleSharingSuggestionsEnabled(_ sender: UISwitch) {
        Logger.info("toggled to: \(sender.isOn)")

        if sender.isOn {
            SSKEnvironment.shared.databaseStorageRef.write { transaction in
                SSKPreferences.setAreIntentDonationsEnabled(true, transaction: transaction)
            }
        } else {
            INInteraction.deleteAll { error in
                if let error {
                    owsFailDebug("Failed to disable sharing suggestions \(error)")
                    sender.setOn(true, animated: true)
                    OWSActionSheets.showActionSheet(title: OWSLocalizedString(
                        "SHARING_SUGGESTIONS_DISABLE_ERROR",
                        comment: "Title of alert indicating sharing suggestions failed to deactivate",
                    ))
                } else {
                    SSKEnvironment.shared.databaseStorageRef.write { transaction in
                        SSKPreferences.setAreIntentDonationsEnabled(false, transaction: transaction)
                    }
                }
            }
        }
    }

    private func didToggleAvatarPreference(_ sender: UISwitch) {
        Logger.info("toggled to: \(sender.isOn)")
        let currentValue = SSKEnvironment.shared.databaseStorageRef.read { SSKPreferences.preferContactAvatars(transaction: $0) }
        guard currentValue != sender.isOn else { return }

        SSKEnvironment.shared.databaseStorageRef.write { SSKPreferences.setPreferContactAvatars(sender.isOn, transaction: $0) }
    }

    private func didToggleShouldKeepMutedChatsArchivedSwitch(_ sender: UISwitch) {
        Logger.info("toggled to \(sender.isOn)")
        let currentValue = SSKEnvironment.shared.databaseStorageRef.read { SSKPreferences.shouldKeepMutedChatsArchived(transaction: $0) }
        guard currentValue != sender.isOn else { return }

        SSKEnvironment.shared.databaseStorageRef.write { SSKPreferences.setShouldKeepMutedChatsArchived(sender.isOn, transaction: $0) }

        SSKEnvironment.shared.storageServiceManagerRef.recordPendingLocalAccountUpdates()
    }

    // MARK: - AutoSTT

    @available(iOS 26, *)
    private func autoSTTSection() -> OWSTableSection {
        let section = OWSTableSection()
        section.headerTitle = OWSLocalizedString("AUTO_STT_SETTINGS_HEADER", comment: "Header for on-device speech-to-text settings.")
        section.footerTitle = String(
            format: OWSLocalizedString("AUTO_STT_SETTINGS_FOOTER", comment: "Footer explaining on-device speech settings. Embeds {{language model status}}."),
            OnDeviceLanguageModel.statusText,
        )

        func toggle(_ text: String, _ isOn: @escaping () -> Bool, _ set: @escaping (Bool) -> Void) -> OWSTableItem {
            .switch(withText: text, isOn: isOn, actionBlock: { set($0.isOn) })
        }

        section.add(.switch(
            withText: OWSLocalizedString("AUTO_STT_SETTINGS_ENABLE", comment: "Switch enabling AutoSTT: on-device dictation, voice message transcription and text-to-speech."),
            isOn: { AutoSTTSettings.isEnabled },
            actionBlock: { [weak self] uiSwitch in
                AutoSTTSettings.isEnabled = uiSwitch.isOn
                self?.updateTableContents()
            },
        ))
        guard AutoSTTSettings.isEnabled else { return section }

        section.add(.disclosureItem(
            withText: OWSLocalizedString("AUTO_STT_SETTINGS_LANGUAGE", comment: "Setting for the spoken language used by AutoSTT."),
            accessoryText: AutoSTTSettings.language.displayName,
            actionBlock: { [weak self] in self?.showAutoSTTLanguagePicker() },
        ))
        section.add(toggle(
            OWSLocalizedString("AUTO_STT_SETTINGS_DIARIZATION", comment: "Switch for labeling different speakers in transcripts."),
            { AutoSTTSettings.diarization },
            { AutoSTTSettings.diarization = $0 },
        ))
        section.add(toggle(
            OWSLocalizedString("AUTO_STT_SETTINGS_SMART_FORMAT", comment: "Switch for smart formatting of transcripts with the on-device language model."),
            { AutoSTTSettings.smartFormat },
            { AutoSTTSettings.smartFormat = $0 },
        ))
        section.add(toggle(
            OWSLocalizedString("AUTO_STT_SETTINGS_NOISE", comment: "Switch for background noise attenuation during transcription."),
            { AutoSTTSettings.noiseAttenuation },
            { AutoSTTSettings.noiseAttenuation = $0 },
        ))
        section.add(toggle(
            OWSLocalizedString("AUTO_STT_SETTINGS_PROFANITY", comment: "Switch for masking profanity in transcripts."),
            { AutoSTTSettings.profanityFilter },
            { AutoSTTSettings.profanityFilter = $0 },
        ))
        section.add(.actionItem(
            withText: OWSLocalizedString("AUTO_STT_SETTINGS_DOWNLOAD", comment: "Button that downloads on-device speech models for offline use."),
            actionBlock: { [weak self] in self?.downloadAutoSTTModels() },
        ))
        return section
    }

    @available(iOS 26, *)
    private func voiceCommandsSection() -> OWSTableSection {
        let section = OWSTableSection()
        section.headerTitle = OWSLocalizedString("VOICE_COMMANDS_SETTINGS_HEADER", comment: "Header for hands-free voice command settings.")
        section.footerTitle = OWSLocalizedString("VOICE_COMMANDS_SETTINGS_FOOTER", comment: "Footer explaining how hands-free voice commands work.")

        func toggle(_ text: String, _ isOn: @escaping () -> Bool, _ set: @escaping (Bool) -> Void) -> OWSTableItem {
            .switch(withText: text, isOn: isOn, actionBlock: { uiSwitch in
                set(uiSwitch.isOn)
                VoiceCommandService.shared.settingsDidChange()
            })
        }

        section.add(.switch(
            withText: OWSLocalizedString("VOICE_COMMANDS_SETTINGS_ENABLE", comment: "Switch enabling hands-free voice commands for calling."),
            isOn: { AutoSTTSettings.voiceCommands },
            actionBlock: { [weak self] uiSwitch in
                VoiceCommandService.shared.setEnabled(uiSwitch.isOn)
                self?.updateTableContents()
            },
        ))
        guard AutoSTTSettings.voiceCommands else { return section }

        section.add(toggle(
            OWSLocalizedString("VOICE_COMMANDS_SETTINGS_DURING_CALLS", comment: "Switch for listening for voice commands during calls."),
            { AutoSTTSettings.voiceDuringCalls },
            { AutoSTTSettings.voiceDuringCalls = $0 },
        ))
        section.add(toggle(
            OWSLocalizedString("VOICE_COMMANDS_SETTINGS_WHEN_LOCKED", comment: "Switch for continuing to listen for voice commands when the screen locks."),
            { AutoSTTSettings.voiceWhenLocked },
            { AutoSTTSettings.voiceWhenLocked = $0 },
        ))
        section.add(toggle(
            OWSLocalizedString("VOICE_COMMANDS_SETTINGS_WAKE_WORD", comment: "Switch requiring the wake word 'Hey Signal' before every voice command."),
            { AutoSTTSettings.voiceRequiresWakeWord },
            { AutoSTTSettings.voiceRequiresWakeWord = $0 },
        ))
        let fingerprintStatus: String
        if AutoSTTSettings.hasVoiceFingerprint {
            fingerprintStatus = OWSLocalizedString("VOICE_COMMANDS_SETTINGS_FINGERPRINT_SAVED", comment: "Shows that a voice fingerprint is saved and locking commands.")
        } else if AutoSTTSettings.hasArchivedVoiceFingerprint {
            fingerprintStatus = OWSLocalizedString("VOICE_COMMANDS_SETTINGS_FINGERPRINT_ARCHIVED", comment: "Shows that the voice fingerprint was cleared but the file was kept.")
        } else {
            fingerprintStatus = OWSLocalizedString("VOICE_COMMANDS_SETTINGS_FINGERPRINT_NONE", comment: "Shows that no voice fingerprint has been saved yet.")
        }
        section.add(.disclosureItem(
            withText: OWSLocalizedString("VOICE_COMMANDS_SETTINGS_CLEAR_FINGERPRINT", comment: "Button that clears the active voice fingerprint so someone else can take over."),
            accessoryText: fingerprintStatus,
            actionBlock: { [weak self] in self?.clearVoiceFingerprint() },
        ))
        return section
    }

    @available(iOS 26, *)
    private func clearVoiceFingerprint() {
        let sheet = ActionSheetController(
            title: OWSLocalizedString("VOICE_COMMANDS_SETTINGS_CLEAR_FINGERPRINT", comment: "Button that clears the active voice fingerprint so someone else can take over."),
            message: OWSLocalizedString("VOICE_COMMANDS_SETTINGS_CLEAR_FINGERPRINT_MESSAGE", comment: "Explains that clearing the voice fingerprint keeps a copy on file."),
        )
        sheet.addAction(ActionSheetAction(
            title: OWSLocalizedString("VOICE_COMMANDS_SETTINGS_CLEAR_FINGERPRINT_CONFIRM", comment: "Confirms clearing the active voice fingerprint."),
            style: .destructive,
        ) { [weak self] _ in
            VoiceCommandService.shared.clearVoiceFingerprint()
            self?.updateTableContents()
        })
        sheet.addAction(.cancel)
        present(sheet, animated: true)
    }

    private func showAutoSTTLanguagePicker() {
        let sheet = ActionSheetController(title: OWSLocalizedString("AUTO_STT_SETTINGS_LANGUAGE", comment: "Setting for the spoken language used by AutoSTT."))
        for language in AutoSTTLanguage.allCases {
            sheet.addAction(ActionSheetAction(title: language.displayName, style: .default) { [weak self] _ in
                AutoSTTSettings.language = language
                if #available(iOS 26, *) { VoiceCommandService.shared.settingsDidChange() }
                self?.updateTableContents()
            })
        }
        sheet.addAction(.cancel)
        present(sheet, animated: true)
    }

    @available(iOS 26, *)
    private func downloadAutoSTTModels() {
        ModalActivityIndicatorViewController.present(fromViewController: self, canCancel: false, asyncBlock: { modal in
            let (ready, unavailable) = await OnDeviceSTTSession.installOfflineAssets()
            func names(_ codes: [String]) -> String {
                codes.compactMap { AutoSTTLanguage(rawValue: $0)?.displayName }.joined(separator: ", ")
            }
            var lines: [String] = []
            if !ready.isEmpty {
                lines.append(String(format: OWSLocalizedString("AUTO_STT_DOWNLOAD_DONE", comment: "Shown after speech models download. Embeds {{comma-separated languages}}."), names(ready)))
            }
            if !unavailable.isEmpty {
                lines.append(String(format: OWSLocalizedString("AUTO_STT_DOWNLOAD_UNAVAILABLE", comment: "Shown when some speech models couldn't be downloaded. Embeds {{comma-separated languages}}."), names(unavailable)))
            }
            modal.dismiss { OWSActionSheets.showActionSheet(title: lines.joined(separator: "\n")) }
        })
    }

    // MARK: -

    private func didTapClearHistory() {
        let primaryConfirmDeletionTitle = OWSLocalizedString(
            "SETTINGS_DELETE_HISTORYLOG_CONFIRMATION",
            comment: "Alert message before user confirms clearing history",
        )
        let secondaryConfirmDeletionTitle = OWSLocalizedString(
            "SETTINGS_DELETE_HISTORYLOG_CONFIRMATION_SECONDARY_TITLE",
            comment: "Secondary alert title before user confirms clearing history",
        )
        let secondaryConfirmDeletionMessage = OWSLocalizedString(
            "SETTINGS_DELETE_HISTORYLOG_CONFIRMATION_SECONDARY_MESSAGE",
            comment: "Secondary alert message before user confirms clearing history",
        )
        let confirmDeletionButtonTitle = OWSLocalizedString(
            "SETTINGS_DELETE_HISTORYLOG_CONFIRMATION_BUTTON",
            comment: "Confirmation text for button which deletes all message, calling, attachments, etc.",
        )

        // Show two layers of confirmation here – this is a maximally
        // destructive action.
        OWSActionSheets.showConfirmationAlert(
            title: primaryConfirmDeletionTitle,
            proceedTitle: confirmDeletionButtonTitle,
            proceedStyle: .destructive,
        ) { [weak self] _ in
            OWSActionSheets.showConfirmationAlert(
                title: secondaryConfirmDeletionTitle,
                message: secondaryConfirmDeletionMessage,
                proceedTitle: confirmDeletionButtonTitle,
                proceedStyle: .destructive,
            ) { [weak self] _ in
                self?.clearHistoryBehindSpinner()
            }
        }
    }

    private func clearHistoryBehindSpinner() {
        let threadDeletionManager = DependenciesBridge.shared.threadDeletionManager

        ModalActivityIndicatorViewController.present(
            fromViewController: self,
            title: CommonStrings.deletingModal,
            canCancel: false,
            presentationDelay: 0.5,
            backgroundBlockQueueQos: .userInitiated,
            backgroundBlock: { modal in
                self.clearHistoryWithSneakyTransaction(
                    threadDeletionManager: threadDeletionManager,
                )

                DispatchQueue.main.async {
                    modal.dismiss()
                }
            },
        )
    }

    private func clearHistoryWithSneakyTransaction(
        threadDeletionManager: any ThreadDeletionManager,
    ) {
        Logger.info("")
        let db = DependenciesBridge.shared.db
        let tsAccountManager = DependenciesBridge.shared.tsAccountManager

        db.write { tx in
            let localIdentifiers = tsAccountManager.localIdentifiers(tx: tx).owsFailUnwrap("never registered")

            threadDeletionManager.deleteThreads(
                TSThread.anyFetchAll(transaction: tx),
                sendDeleteForMeSyncMessage: true,
                updateStorageService: true,
                localIdentifiers: localIdentifiers,
                tx: tx,
            )

            // Need to instantiate these to remove them, since `StoryMessage`
            // has an `anyDidRemove` hook.
            for storyMessage in StoryMessage.anyFetchAll(transaction: tx) {
                storyMessage.anyRemove(transaction: tx)
            }
        }

        AttachmentStream.deleteAllAttachmentFiles()
    }
}
