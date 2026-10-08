//
// Copyright 2026 Wild Dolphin
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Built-in RTC test contacts hosted at rtc.wilddolphin.us.
///
/// Dialing these numbers from this Signal client opens a WebRTC session against
/// the Signal gateway rather than Signal's 1:1 calling service. Equivalent
/// short numbers (1001–1004) match the gateway PBX extensions.
public enum SignalGatewayContacts {
    public static let host = "rtc.wilddolphin.us"
    public static let httpBaseURL = URL(string: "https://rtc.wilddolphin.us")!

    public struct Contact: Equatable, Sendable {
        public let id: String
        public let displayName: String
        public let shortNumber: String
        public let e164: String
        public let wantsVideo: Bool
        public let summary: String

        public var callURL: URL {
            var components = URLComponents(url: SignalGatewayContacts.httpBaseURL.appendingPathComponent("call/\(id)"), resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "video", value: wantsVideo ? "1" : "0"),
            ]
            return components.url!
        }

        public var address: SignalServiceAddress {
            SignalServiceAddress(phoneNumber: e164)
        }

        func matches(_ query: String) -> Bool {
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !q.isEmpty else { return true }
            let compact = q.filter { $0.isNumber || $0 == "+" }
            return id.lowercased().contains(q)
                || displayName.lowercased().contains(q)
                || summary.lowercased().contains(q)
                || e164.contains(compact.isEmpty ? q : compact)
                || shortNumber.contains(compact.isEmpty ? q : compact)
        }
    }

    public static let all: [Contact] = [
        Contact(
            id: "echo",
            displayName: "Echo",
            shortNumber: "1001",
            e164: "+15551111001",
            wantsVideo: false,
            summary: "Audio loopback. Speak and hear yourself come back.",
        ),
        Contact(
            id: "videoecho",
            displayName: "Video Echo",
            shortNumber: "1002",
            e164: "+15551111002",
            wantsVideo: true,
            summary: "Audio and video loopback. Check camera and microphone.",
        ),
        Contact(
            id: "prerecorded",
            displayName: "Prerecorded",
            shortNumber: "1003",
            e164: "+15551111003",
            wantsVideo: true,
            summary: "Plays a short prerecorded audio/video clip.",
        ),
        Contact(
            id: "recordandplayback",
            displayName: "Record and Playback",
            shortNumber: "1004",
            e164: "+15551111004",
            wantsVideo: true,
            summary: "Records a few seconds of you, then plays it back.",
        ),
    ]

    public static func contact(matching address: SignalServiceAddress) -> Contact? {
        guard let number = address.phoneNumber else { return nil }
        return contact(matchingNumber: number)
    }

    public static func contact(matchingNumber number: String) -> Contact? {
        let compact = number.filter { $0.isNumber || $0 == "+" }
        return all.first { contact in
            contact.e164 == number
                || contact.e164 == compact
                || contact.shortNumber == number
                || contact.shortNumber == compact
                || contact.e164.hasSuffix(compact) && compact.count >= 4
        }
    }

    public static func contacts(matchingSearch query: String) -> [Contact] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return all }
        return all.filter { $0.matches(trimmed) }
    }
}
