//
// Copyright 2026 Wild Dolphin
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest
@testable import SignalServiceKit

final class SignalGatewayContactsTest: XCTestCase {
    func testCatalogHasStandardFunctions() {
        XCTAssertEqual(
            SignalGatewayContacts.all.map(\.id),
            ["echo", "videoecho", "prerecorded", "recordandplayback"],
        )
        XCTAssertEqual(SignalGatewayContacts.all.map(\.shortNumber), ["1001", "1002", "1003", "1004"])
        XCTAssertEqual(SignalGatewayContacts.all.map(\.e164), [
            "+15551111001",
            "+15551111002",
            "+15551111003",
            "+15551111004",
        ])
        XCTAssertEqual(SignalGatewayContacts.all.map(\.displayName), [
            "Echo",
            "Video Echo",
            "Prerecorded",
            "Record and Playback",
        ])
    }

    func testLookupByE164AndExtension() {
        XCTAssertEqual(SignalGatewayContacts.contact(matchingNumber: "+15551111001")?.id, "echo")
        XCTAssertEqual(SignalGatewayContacts.contact(matchingNumber: "1002")?.id, "videoecho")
        XCTAssertEqual(SignalGatewayContacts.contact(matchingNumber: "15551111003")?.id, "prerecorded")
        XCTAssertNil(SignalGatewayContacts.contact(matchingNumber: "+15550009999"))
    }

    func testSearch() {
        XCTAssertEqual(SignalGatewayContacts.contacts(matchingSearch: "video").map(\.id), ["videoecho"])
        XCTAssertEqual(SignalGatewayContacts.contacts(matchingSearch: "1004").map(\.id), ["recordandplayback"])
        XCTAssertEqual(SignalGatewayContacts.contacts(matchingSearch: "").count, 4)
    }

    func testE164IsStructurallyValid() {
        for contact in SignalGatewayContacts.all {
            XCTAssertNotNil(E164(contact.e164), contact.e164)
        }
    }

    func testStableServiceIds() {
        let acis = Set(SignalGatewayContacts.all.map(\.aci))
        let pnis = Set(SignalGatewayContacts.all.map(\.pni))
        XCTAssertEqual(acis.count, 4)
        XCTAssertEqual(pnis.count, 4)
        XCTAssertEqual(
            SignalGatewayContacts.contact(matching: SignalGatewayContacts.all[0].address)?.id,
            "echo",
        )
        for contact in SignalGatewayContacts.all {
            XCTAssertTrue(SignalGatewayContacts.isGatewayServiceId(contact.aci))
            XCTAssertTrue(SignalGatewayContacts.isGatewayServiceId(contact.pni))
            XCTAssertTrue(SignalGatewayContacts.isGatewayNumber(contact.e164))
        }
    }
}
