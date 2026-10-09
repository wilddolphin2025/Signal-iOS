//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import FoundationModels
import SignalServiceKit

/// On-device conversational interpreter: STT text in, a spoken reply plus a Signal action out.
/// Uses Apple's embedded language model only (no Private Cloud Compute).
@available(iOS 26, *)
@MainActor
final class VoiceAssistant {
    static let shared = VoiceAssistant()

    struct Context {
        var language: String
        var dialog: String
        var inCall: Bool
        var incomingRing: Bool
        var outgoingRing: Bool
        var lastPrompt: String
        var contacts: [String]
        var addressed: Bool
    }

    struct Turn {
        var say: String
        var action: Action
        var name: String
        var number: String
        var on: Bool
    }

    enum Action: String {
        case ignore
        case none
        case help
        case call
        case videoCall
        case groupCall
        case callNumber
        case yes
        case no
        case cancel
        case hangUp
        case answer
        case decline
        case mute
        case hold
        case speaker
        case camera
        case flipCamera
        case callBack
        case missed
        case status
        case join
        case sleep
        case wake
        case saveAs
        case repeatLast
        case tellTime
        case tellDate
        case checkInternet
        case search
    }

    var isAvailable: Bool { OnDeviceLanguageModel.model.isAvailable }

    private var session: LanguageModelSession?
    private var turnsInSession = 0

    func prewarm() {
        guard isAvailable else { return }
        ensureSession().prewarm()
    }

    func reset() {
        session = nil
        turnsInSession = 0
    }

    func interpret(heard: String, context: Context) async -> Turn? {
        guard isAvailable else { return nil }
        if turnsInSession >= 24 { reset() }
        let session = ensureSession()
        let prompt = Self.userPrompt(heard: heard, context: context)
        do {
            let response = try await session.respond(
                to: prompt,
                options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 180),
            )
            turnsInSession += 1
            let raw = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            Logger.info("Voice assistant raw: \(raw)")
            return Self.parse(raw)
        } catch is CancellationError {
            return nil
        } catch {
            Logger.warn("Voice assistant failed: \(error)")
            return nil
        }
    }

    private func ensureSession() -> LanguageModelSession {
        if let session { return session }
        let created = LanguageModelSession(model: OnDeviceLanguageModel.model, instructions: Self.instructions)
        session = created
        return created
    }

    // MARK: - Prompt

    private static let instructions = """
        You are Signal's hands-free voice assistant on this iPhone. You run entirely on the device.
        You are in conversational mode: understand natural speech, paraphrases, fragments, and \
        follow-ups. Do not require exact menu phrases. The user may be hands-free and cannot see the screen.

        You receive what speech-to-text heard, plus a short situation. Reply with ONE JSON object only. \
        No markdown, no extra keys, no commentary.

        Schema:
        {"say":"string","action":"string","name":"string","number":"string","on":false}

        "say" is what the phone speaks next. Keep it to one or two short sentences. End with what they \
        can say next when you need a decision. Empty only when action is ignore.

        "action" is exactly one of:
        ignore, none, help, call, videoCall, groupCall, callNumber, yes, no, cancel, hangUp, \
        answer, decline, mute, hold, speaker, camera, flipCamera, callBack, missed, status, join, \
        sleep, wake, saveAs, repeatLast, tellTime, tellDate, checkInternet, search

        "name" is a contact, group, or nickname when relevant, else "".
        "number" is digits or a spoken number when they are dialing a number, else "".
        "on" is true/false for mute, hold, speaker, and camera (true = turn that on / mute / hold).

        When to use each action:
        - ignore: TV, chatter, or anything that is not a request to Signal. say must be "".
        - none: answer a question or continue the conversation without changing call state.
        - help: they asked what they can say. Explain in plain speech for the current situation.
        - call / videoCall / groupCall: they want to place that kind of call. Put the person or group in name.
        - callNumber: they spoke a phone number. Put digits in number (include country code if they said plus).
        - yes / no: they confirmed or rejected the open question (yes, yeah, do it, that's the one, no, wrong).
        - cancel / hangUp: stop a pending dial or end a live call.
        - answer / decline: incoming ring only.
        - mute/hold/speaker/camera: set "on" appropriately. flipCamera switches the camera. join joins a group lobby.
        - callBack: redial the latest call. missed: read missed calls. status: say who they are on a call with.
        - sleep: stop listening until they wake you. wake: start listening again.
        - saveAs: they want to store the current number under name.
        - repeatLast: they asked you to repeat what you just said.
        - tellTime: they asked the current time. Leave say empty; the phone reads the clock.
        - tellDate: they asked the date or day. Leave say empty; the phone reads the calendar.
        - checkInternet: they asked if they are online. Leave say empty.
        - search: they want a short web lookup. Put the query in name. If they only said search, leave name empty.

        Rules:
        - If the situation is "none" and the speech is not a clear request, use ignore.
        - If they already have an open question, treat short replies as answers to that question.
        - Never invent a contact that is not in the contact list unless they spoke a phone number.
        - If several contacts could match, ask which one; action none.
        - Do not claim a call already connected; the app places the call after you return call/videoCall/callNumber.
        - During a call, ignore ordinary conversation unless they are clearly talking to Signal.
        - If they said Hey Signal and nothing else, greet briefly; action none.
        - Match language to the user (English, Spanish, or Russian).
        - Be brief. No lists of more than four names.
        - Questions about the time, date, or whether the internet is up are requests, not chatter.
        """

    private static func userPrompt(heard: String, context: Context) -> String {
        var lines = [
            "language: \(context.language)",
            "situation: \(context.dialog)",
            "in_call: \(context.inCall)",
            "incoming_ring: \(context.incomingRing)",
            "outgoing_ring: \(context.outgoingRing)",
            "addressed_signal: \(context.addressed)",
            "you_last_said: \(context.lastPrompt.isEmpty ? "(nothing)" : context.lastPrompt)",
            "internet: \(VoiceWorldInfo.isOnline ? "available" : "unavailable")",
        ]
        if context.contacts.isEmpty {
            lines.append("contacts: (none loaded)")
        } else {
            lines.append("contacts: \(context.contacts.joined(separator: "; "))")
        }
        lines.append("heard: \(heard)")
        return lines.joined(separator: "\n")
    }

    // MARK: - Parse

    static func parse(_ raw: String) -> Turn? {
        guard let data = jsonObject(in: raw),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if raw.isEmpty { return Turn(say: "", action: .ignore, name: "", number: "", on: false) }
            return Turn(say: raw, action: .none, name: "", number: "", on: false)
        }
        let say = string(object["say"])
        let rawAction = string(object["action"])
        let action = action(from: rawAction)
        let name = string(object["name"])
        let number = string(object["number"])
        var on = bool(object["on"])
        let key = rawAction.lowercased()
        if key.contains("unmute") { on = false }
        else if key == "mute", object["on"] == nil { on = true }
        if key.contains("resume") || key.contains("unhold") { on = false }
        else if key == "hold" || key == "pause", object["on"] == nil { on = true }
        if key.contains("off") { on = false }
        else if key.hasSuffix("on"), object["on"] == nil { on = true }
        if action == .ignore { return Turn(say: "", action: .ignore, name: "", number: "", on: false) }
        return Turn(say: say, action: action, name: name, number: number, on: on)
    }

    private static func jsonObject(in raw: String) -> Data? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"), start <= end {
            return String(trimmed[start...end]).data(using: .utf8)
        }
        return trimmed.data(using: .utf8)
    }

    private static func string(_ value: Any?) -> String {
        switch value {
        case let text as String: return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case let number as NSNumber: return number.stringValue
        default: return ""
        }
    }

    private static func bool(_ value: Any?) -> Bool {
        switch value {
        case let flag as Bool: return flag
        case let text as String:
            return ["true", "yes", "on", "1"].contains(text.lowercased())
        case let number as NSNumber: return number.boolValue
        default: return false
        }
    }

    private static func action(from raw: String) -> Action {
        let key = raw.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
        switch key {
        case "ignore", "noop", "chatter": return .ignore
        case "", "none", "talk", "reply": return .none
        case "help": return .help
        case "call", "dial", "phone": return .call
        case "videocall", "video": return .videoCall
        case "groupcall", "group": return .groupCall
        case "callnumber", "dialnumber", "number": return .callNumber
        case "yes", "confirm": return .yes
        case "no": return .no
        case "cancel", "abort": return .cancel
        case "hangup", "endcall", "end": return .hangUp
        case "answer", "accept": return .answer
        case "decline", "reject": return .decline
        case "mute": return .mute
        case "unmute": return .mute
        case "hold", "pause": return .hold
        case "resume", "unhold": return .hold
        case "speaker", "speakeron", "speakeroff": return .speaker
        case "camera", "cameraon", "cameraoff": return .camera
        case "flipcamera", "switchcamera": return .flipCamera
        case "callback", "redial": return .callBack
        case "missed", "missedcalls": return .missed
        case "status": return .status
        case "join": return .join
        case "sleep": return .sleep
        case "wake": return .wake
        case "saveas", "save": return .saveAs
        case "repeatlast", "repeat": return .repeatLast
        case "telltime", "time", "whattime": return .tellTime
        case "telldate", "date", "whatdate", "whatday": return .tellDate
        case "checkinternet", "internet", "online": return .checkInternet
        case "search", "lookup", "google": return .search
        default: return .none
        }
    }
}

/// Clock, reachability, and a short public search for spoken answers.
@available(iOS 26, *)
enum VoiceWorldInfo {
    static var isOnline: Bool { SSKEnvironment.shared.reachabilityManagerRef.isReachable }

    static func spokenTime(language: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale(language)
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: Date())
    }

    static func spokenDate(language: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale(language)
        formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMMYYYY")
        return formatter.string(from: Date())
    }

    static func search(_ query: String) async -> Result<String, SearchError> {
        guard isOnline else { return .failure(.offline) }
        var components = URLComponents(string: "https://api.duckduckgo.com/")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "no_html", value: "1"),
            URLQueryItem(name: "skip_disambig", value: "1"),
        ]
        guard let url = components?.url else { return .failure(.failed) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("Signal-iOS-VoiceAssistant", forHTTPHeaderField: "User-Agent")
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure(.noResult)
            }
            if let answer = spokenResult(in: object) { return .success(answer) }
            return .failure(.noResult)
        } catch {
            Logger.warn("Voice search failed: \(error)")
            return .failure(.failed)
        }
    }

    enum SearchError: Error { case offline, failed, noResult }

    private static func locale(_ language: String) -> Locale {
        Locale(identifier: language == "es" ? "es" : language == "ru" ? "ru" : "en")
    }

    private static func spokenResult(in object: [String: Any]) -> String? {
        let fields = ["Answer", "AbstractText", "Abstract"]
        for key in fields {
            if let text = object[key] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return clip(text)
            }
        }
        if let topics = object["RelatedTopics"] as? [[String: Any]] {
            for topic in topics {
                if let text = topic["Text"] as? String, !text.isEmpty { return clip(text) }
            }
        }
        return nil
    }

    private static func clip(_ text: String) -> String {
        let cleaned = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > 280 else { return cleaned }
        let limit = cleaned.index(cleaned.startIndex, offsetBy: 280)
        if let stop = cleaned[..<limit].lastIndex(of: ".") { return String(cleaned[...stop]) }
        return String(cleaned[..<limit]) + "."
    }
}
