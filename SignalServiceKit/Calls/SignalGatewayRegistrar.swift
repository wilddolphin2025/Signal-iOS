//
// Copyright 2026 Wild Dolphin
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import LibSignalClient

/// Registers the RTC test contacts in the local Signal recipient/account tables
/// so Contact Discovery, New Call, and Find-by-Number treat them as registered.
///
/// | Function | Name | Number | Ext |
/// | echo | Echo | +15551111001 | 1001 |
/// | videoecho | Video Echo | +15551111002 | 1002 |
/// | prerecorded | Prerecorded | +15551111003 | 1003 |
/// | recordandplayback | Record and Playback | +15551111004 | 1004 |
public enum SignalGatewayRegistrar {
    @discardableResult
    public static func register(
        _ contact: SignalGatewayContacts.Contact,
        tx: DBWriteTransaction,
    ) -> SignalRecipient? {
        guard let e164 = E164(contact.e164) else {
            owsFailDebug("Invalid gateway E.164 \(contact.e164)")
            return nil
        }
        guard let localIdentifiers = DependenciesBridge.shared.tsAccountManager.localIdentifiers(tx: tx) else {
            return nil
        }

        let recipientMerger = DependenciesBridge.shared.recipientMerger
        let recipientManager = DependenciesBridge.shared.recipientManager
        let recipientDatabaseTable = DependenciesBridge.shared.recipientDatabaseTable
        let profileManager = SSKEnvironment.shared.profileManagerRef

        var recipient: SignalRecipient
        if let merged = recipientMerger.applyMergeFromContactDiscovery(
            localIdentifiers: localIdentifiers,
            phoneNumber: e164,
            pni: contact.pni,
            aci: contact.aci,
            tx: tx,
        ) {
            recipient = merged
        } else if let existing = recipientDatabaseTable.fetchRecipient(phoneNumber: e164.stringValue, transaction: tx) {
            recipient = existing
        } else {
            recipient = failIfThrowsDatabaseError {
                try SignalRecipient.insertRecord(
                    aci: contact.aci,
                    phoneNumber: e164,
                    pni: contact.pni,
                    deviceIds: [.primary],
                    tx: tx,
                )
            }
        }

        recipientManager.markAsRegisteredAndSave(&recipient, shouldUpdateStorageService: false, tx: tx)
        if recipient.phoneNumber?.isDiscoverable != true {
            recipient.phoneNumber?.isDiscoverable = true
            recipientDatabaseTable.updateRecipient(recipient, transaction: tx)
        }
        profileManager.addRecipientToProfileWhitelist(
            &recipient,
            userProfileWriter: .debugging,
            tx: tx,
        )

        let profile = OWSUserProfile.getOrBuildUserProfile(
            for: OWSUserProfile.insertableAddress(serviceId: contact.aci, localIdentifiers: localIdentifiers),
            userProfileWriter: .debugging,
            tx: tx,
        )
        if profile.filteredGivenName != contact.displayName {
            profile.update(
                givenName: .setTo(contact.displayName),
                familyName: .setTo(nil),
                userProfileWriter: .debugging,
                transaction: tx,
            )
        }

        if SignalAccountFinder().signalAccount(for: e164, tx: tx) == nil {
            let account = SignalAccount(
                recipientPhoneNumber: contact.e164,
                recipientServiceId: contact.aci,
                multipleAccountLabelText: contact.shortNumber,
                cnContactId: nil,
                givenName: contact.displayName,
                familyName: "",
                nickname: contact.id,
                fullName: contact.displayName,
                contactAvatarHash: nil,
            )
            account.anyInsert(transaction: tx)
        }

        return recipient
    }

    @discardableResult
    public static func registerAll(tx: DBWriteTransaction) -> [SignalRecipient] {
        SignalGatewayContacts.all.compactMap { register($0, tx: tx) }
    }

    public static func registerAllWhenReady() {
        let databaseStorage = SSKEnvironment.shared.databaseStorageRef
        var registeredCount = 0
        databaseStorage.write { tx in
            registeredCount = registerAll(tx: tx).count
        }
        if registeredCount > 0 {
            NotificationCenter.default.postOnMainThread(
                name: .OWSContactsManagerSignalAccountsDidChange,
                object: nil,
            )
        }
    }
}
