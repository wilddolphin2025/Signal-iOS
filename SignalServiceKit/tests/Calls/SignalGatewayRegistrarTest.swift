//
// Copyright 2026 Wild Dolphin
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient
import XCTest

@testable import SignalServiceKit

final class SignalGatewayRegistrarTest: SSKBaseTest {
    private lazy var localIdentifiers = LocalIdentifiers.forUnitTests

    override func setUp() {
        super.setUp()
        SSKEnvironment.shared.databaseStorageRef.write { tx in
            (DependenciesBridge.shared.registrationStateChangeManager as! RegistrationStateChangeManagerImpl).registerForTests(
                localIdentifiers: localIdentifiers,
                tx: tx,
            )
        }
    }

    func testRegistersCatalogInSignalRecipientTables() {
        write { tx in
            let recipients = SignalGatewayRegistrar.registerAll(tx: tx)
            XCTAssertEqual(recipients.count, 4)

            for contact in SignalGatewayContacts.all {
                let e164 = E164(contact.e164)!
                let recipient = DependenciesBridge.shared.recipientDatabaseTable.fetchRecipient(
                    phoneNumber: contact.e164,
                    transaction: tx,
                )
                XCTAssertNotNil(recipient, contact.e164)
                XCTAssertTrue(recipient?.isRegistered == true, contact.e164)
                XCTAssertEqual(recipient?.aci, contact.aci)
                XCTAssertEqual(recipient?.pni, contact.pni)
                XCTAssertEqual(recipient?.phoneNumber?.stringValue, contact.e164)
                XCTAssertEqual(recipient?.phoneNumber?.isDiscoverable, true)

                let account = SignalAccountFinder().signalAccount(for: e164, tx: tx)
                XCTAssertEqual(account?.givenName, contact.displayName, contact.id)
                XCTAssertEqual(account?.recipientServiceId, contact.aci)
                XCTAssertEqual(account?.nickname, contact.id)
                XCTAssertEqual(account?.multipleAccountLabelText, contact.shortNumber)
            }
        }
    }

    func testReregisterKeepsNumbersRegistered() {
        write { tx in
            _ = SignalGatewayRegistrar.registerAll(tx: tx)
            let again = SignalGatewayRegistrar.registerAll(tx: tx)
            XCTAssertEqual(again.count, 4)
            XCTAssertTrue(again.allSatisfy(\.isRegistered))
        }
    }
}
