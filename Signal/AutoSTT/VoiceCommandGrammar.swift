//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// What a spoken utterance asks for. Names are left raw; ``VoiceContactMatcher`` resolves them.
enum VoiceIntent: Equatable {
    case call(name: String, video: Bool)
    case groupCall(name: String)
    case callBack
    case missedCalls
    case answer
    case decline
    case whoIsCalling
    case hangUp
    case mute(Bool)
    case hold(Bool)
    case speaker(Bool)
    case camera(Bool)
    case flipCamera
    case join
    case status
    case help
    case repeatLast
    case cancel
    case yes
    case no
    /// 1-based position in a list of choices; `Int.max` means "the last one".
    case choose(Int)
    case sleep
    case wake
    /// "Can you hear me?": people check that the phone is listening before giving a command.
    case presenceCheck
    case saveAs(String)
    /// Anything else: a contact name or refinement while a dialog is open.
    case text(String)
}

struct VoiceUtterance: Equatable {
    /// Started with the wake word ("Hey Signal").
    var isAddressed: Bool
    /// Only the wake word was said; the command follows in the next utterance.
    var isWakeWordOnly: Bool
    var intent: VoiceIntent
}

enum VoiceCommandParser {
    static func parse(_ text: String, languageCode: String) -> VoiceUtterance {
        let lexicon = VoiceLexicon.forLanguage(languageCode)
        var tokens = tokenize(text)
        let isAddressed = lexicon.wakeWords.contains { stripWakeWord($0, from: &tokens) }
        guard !tokens.isEmpty else {
            return VoiceUtterance(isAddressed: isAddressed, isWakeWordOnly: isAddressed, intent: .text(""))
        }
        return VoiceUtterance(isAddressed: isAddressed, isWakeWordOnly: false, intent: intent(for: tokens, lexicon: lexicon))
    }

    /// Lowercased words without punctuation or diacritics, so tables and speech compare reliably.
    static func tokenize(_ text: String) -> [String] {
        let folded = text.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .folding(options: .diacriticInsensitive, locale: nil)
        let spaced = String(folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " })
        return spaced.split(separator: " ").map(String.init)
    }

    private static func intent(for input: [String], lexicon: VoiceLexicon) -> VoiceIntent {
        var tokens = input
        for phrase in lexicon.politeness { removeAll(phrase, from: &tokens) }
        if tokens.isEmpty { tokens = input }
        if !tokens.isEmpty, tokens.allSatisfy({ lexicon.yesWords.contains($0) }) { return .yes }

        for (phrase, intent) in lexicon.exact where matches(phrase, exactly: tokens) { return intent }
        if let index = ordinal(tokens, lexicon: lexicon) { return .choose(index) }
        for (phrase, intent) in lexicon.priorityPhrases where contains(phrase, in: tokens) { return intent }
        for phrase in lexicon.saveAs {
            var rest = tokens
            if stripPrefix(phrase, from: &rest), !rest.isEmpty { return .saveAs(rest.joined(separator: " ")) }
        }

        for (verbs, kind) in [(lexicon.groupCallVerbs, 2), (lexicon.videoCallVerbs, 1), (lexicon.callVerbs, 0)] {
            for verb in verbs {
                var rest = tokens
                guard stripPrefix(verb, from: &rest) else { continue }
                var video = kind == 1
                for suffix in lexicon.videoSuffixes where stripSuffix(suffix, from: &rest) { video = true }
                let name = cleanName(rest, lexicon: lexicon)
                return kind == 2 ? .groupCall(name: name) : .call(name: name, video: video)
            }
        }

        for (phrase, intent) in lexicon.phrases where contains(phrase, in: tokens) { return intent }

        let isOff = lexicon.offWords.contains { contains($0, in: tokens) }
        if lexicon.earpieceWords.contains(where: { contains($0, in: tokens) }) { return .speaker(false) }
        if lexicon.speakerWords.contains(where: { contains($0, in: tokens) }) { return .speaker(!isOff) }
        if lexicon.cameraWords.contains(where: { contains($0, in: tokens) }) { return .camera(!isOff) }
        if lexicon.microphoneWords.contains(where: { contains($0, in: tokens) }) { return .mute(isOff) }

        return .text(cleanName(tokens, lexicon: lexicon))
    }

    private static func ordinal(_ tokens: [String], lexicon: VoiceLexicon) -> Int? {
        var rest = tokens.filter { !lexicon.ordinalFillers.contains($0) }
        if rest.isEmpty { rest = tokens }
        guard rest.count <= 2 else { return nil }
        if lexicon.lastWords.contains(where: { matches($0, exactly: rest) }) { return .max }
        for (index, words) in lexicon.ordinals.enumerated() where words.contains(where: { matches($0, exactly: rest) }) {
            return index + 1
        }
        return nil
    }

    private static func cleanName(_ tokens: [String], lexicon: VoiceLexicon) -> String {
        var rest = tokens
        while let first = rest.first, lexicon.nameFillers.contains(first) { rest.removeFirst() }
        while let last = rest.last, lexicon.nameTrailers.contains(last) { rest.removeLast() }
        return rest.joined(separator: " ")
    }

    // MARK: Phrase matching. A phrase word ending in "*" matches any word with that prefix.

    private static func words(_ phrase: String) -> [String] { phrase.split(separator: " ").map(String.init) }

    private static func wordMatches(_ pattern: String, _ word: String) -> Bool {
        pattern.hasSuffix("*") ? word.hasPrefix(pattern.dropLast()) : pattern == word
    }

    private static func matches(_ phrase: String, exactly tokens: [String]) -> Bool {
        let pattern = words(phrase)
        return pattern.count == tokens.count && zip(pattern, tokens).allSatisfy(wordMatches)
    }

    private static func range(of phrase: String, in tokens: [String]) -> Range<Int>? {
        let pattern = words(phrase)
        guard !pattern.isEmpty, pattern.count <= tokens.count else { return nil }
        for start in 0...(tokens.count - pattern.count) where zip(pattern, tokens[start...]).allSatisfy(wordMatches) {
            return start..<(start + pattern.count)
        }
        return nil
    }

    private static func contains(_ phrase: String, in tokens: [String]) -> Bool { range(of: phrase, in: tokens) != nil }

    private static func stripPrefix(_ phrase: String, from tokens: inout [String]) -> Bool {
        guard let range = range(of: phrase, in: tokens), range.lowerBound == 0 else { return false }
        tokens.removeSubrange(range)
        return true
    }

    /// The recognizer often adds a word before the wake word ("a signal", "hey, signal"), so allow two.
    private static func stripWakeWord(_ phrase: String, from tokens: inout [String]) -> Bool {
        guard let range = range(of: phrase, in: tokens), range.lowerBound <= 2 else { return false }
        tokens.removeSubrange(0..<range.upperBound)
        return true
    }

    private static func stripSuffix(_ phrase: String, from tokens: inout [String]) -> Bool {
        guard let range = range(of: phrase, in: tokens), range.upperBound == tokens.count, range.lowerBound > 0 else { return false }
        tokens.removeSubrange(range)
        return true
    }

    private static func removeAll(_ phrase: String, from tokens: inout [String]) {
        while let range = range(of: phrase, in: tokens), tokens.count > range.count { tokens.removeSubrange(range) }
    }
}

// MARK: - Vocabulary

/// Per-language command vocabulary. Phrases are written naturally and tokenized at load.
struct VoiceLexicon {
    var wakeWords: [String]
    var politeness: [String]
    var nameFillers: Set<String>
    var nameTrailers: Set<String>
    var yesWords: Set<String>
    /// Whole-utterance matches (yes, no, cancel, single-word controls).
    var exact: [(String, VoiceIntent)]
    /// Checked before call verbs so "call back" or "missed calls" isn't read as calling someone.
    var priorityPhrases: [(String, VoiceIntent)]
    var saveAs: [String]
    var callVerbs: [String]
    var videoCallVerbs: [String]
    var groupCallVerbs: [String]
    var videoSuffixes: [String]
    var phrases: [(String, VoiceIntent)]
    var speakerWords: [String]
    var earpieceWords: [String]
    var cameraWords: [String]
    var microphoneWords: [String]
    var offWords: [String]
    var ordinals: [[String]]
    var lastWords: [String]
    var ordinalFillers: Set<String>

    static func forLanguage(_ code: String) -> VoiceLexicon {
        switch code {
        case "es": spanish
        case "ru": russian
        default: english
        }
    }

    private func normalized() -> VoiceLexicon {
        func n(_ phrase: String) -> String {
            phrase.split(separator: " ").flatMap { word in
                var parts = VoiceCommandParser.tokenize(String(word))
                if word.hasSuffix("*"), !parts.isEmpty { parts[parts.count - 1] += "*" }
                return parts
            }.joined(separator: " ")
        }
        func list(_ phrases: [String]) -> [String] { phrases.map(n).sorted { $0.count > $1.count } }
        func pairs(_ pairs: [(String, VoiceIntent)]) -> [(String, VoiceIntent)] { pairs.map { (n($0.0), $0.1) } }
        var copy = self
        copy.wakeWords = list(wakeWords)
        copy.politeness = list(politeness)
        copy.nameFillers = Set(nameFillers.map(n))
        copy.nameTrailers = Set(nameTrailers.map(n))
        copy.yesWords = Set(yesWords.map(n))
        copy.exact = pairs(exact)
        copy.priorityPhrases = pairs(priorityPhrases)
        copy.saveAs = list(saveAs)
        copy.callVerbs = list(callVerbs)
        copy.videoCallVerbs = list(videoCallVerbs)
        copy.groupCallVerbs = list(groupCallVerbs)
        copy.videoSuffixes = list(videoSuffixes)
        copy.phrases = pairs(phrases)
        copy.speakerWords = list(speakerWords)
        copy.earpieceWords = list(earpieceWords)
        copy.cameraWords = list(cameraWords)
        copy.microphoneWords = list(microphoneWords)
        copy.offWords = list(offWords)
        copy.ordinals = ordinals.map { $0.map(n) }
        copy.lastWords = list(lastWords)
        copy.ordinalFillers = Set(ordinalFillers.map(n))
        return copy
    }

    private static func each(_ phrases: [String], _ intent: VoiceIntent) -> [(String, VoiceIntent)] { phrases.map { ($0, intent) } }

    static let english = VoiceLexicon(
        wakeWords: ["hey signal", "hi signal", "ok signal", "okay signal", "signal"],
        politeness: ["please", "can you", "could you", "would you", "will you", "i want to", "i'd like to", "i would like to", "i need to", "let's", "go ahead and", "now"],
        nameFillers: ["to", "my", "the", "a", "an", "with"],
        nameTrailers: ["back", "now", "please", "again"],
        yesWords: ["yes", "yeah", "yep", "yup"],
        exact: each(["yes", "yeah", "yep", "yup", "correct", "right", "sure", "ok", "okay", "do it", "go ahead", "that one", "that's right", "yes please", "please do"], .yes)
            + each(["no", "nope", "wrong", "not that one", "no thanks", "neither"], .no)
            + each(["cancel", "never mind", "nevermind", "stop", "forget it", "abort", "cancel that", "nothing"], .cancel)
            + each(["back", "i'm back"], .hold(false))
            + each(["hold", "pause"], .hold(true))
            + each(["mute"], .mute(true))
            + each(["unmute"], .mute(false))
            + each(["listen"], .wake)
            + each(["goodbye", "sleep", "bye"], .sleep)
            + each(["hello", "hi", "hey", "testing", "test", "mic check", "hello hello", "you there", "anyone there"], .presenceCheck),
        priorityPhrases: each(["hear me", "you hear me", "hearing me", "can you hear", "are you listening", "you listening", "listening to me",
                               "are you there", "is anyone there", "anybody there", "are you awake", "you awake", "are you on", "is this working", "testing", "mic check"], .presenceCheck)
            + each(["missed call*", "who called", "who has called", "who's called", "recent calls", "call history", "call log", "any calls"], .missedCalls)
            + each(["call back", "call them back", "call him back", "call her back", "redial", "call again", "call the last number", "call the last person", "return the call", "return call", "call the last one"], .callBack)
            + each(["hang up", "hangup", "hang it up", "end call", "end the call", "end this call", "stop the call", "stop call", "leave the call", "leave call", "drop the call", "disconnect"], .hangUp)
            + each(["don't answer", "do not answer", "decline", "reject", "ignore", "dismiss", "not now", "send to voicemail"], .decline)
            + each(["stop listening", "go to sleep", "be quiet", "pause listening"], .sleep)
            + each(["wake up", "start listening", "i need you"], .wake)
            + each(["repeat what you just said", "repeat what you said", "repeat what you just told me", "repeat that",
                    "say what you just said", "say it again", "say that one more time", "what did you just say",
                    "could you repeat that", "can you repeat that", "would you repeat that"], .repeatLast),
        saveAs: ["save as", "save it as", "save that as", "add as", "add it as", "name it", "call it"],
        callVerbs: ["call", "dial", "phone", "ring", "call up", "get me", "connect me to", "connect me with", "voice call", "audio call", "make a call to", "place a call to", "start a call with", "talk to", "speak to"],
        videoCallVerbs: ["video call", "videocall", "facetime", "face time", "video chat with", "video chat", "start a video call with", "make a video call to"],
        groupCallVerbs: ["group call", "call the group", "call group", "start a group call with", "start a group call", "join the group call with"],
        videoSuffixes: ["on video", "with video", "by video", "video call", "with camera"],
        phrases: each(["answer", "accept", "pick up", "take the call", "take it", "answer it"], .answer)
            + each(["who's calling", "who is calling", "who is it", "who's that", "who is that", "who's on the line", "who is on the line"], .whoIsCalling)
            + each(["status", "who am i talking to", "who am i speaking to", "who's on the call", "who is on the call", "call status", "am i muted"], .status)
            + each(["unhold", "un hold", "off hold", "take off hold", "take the call off hold", "resume", "unpause", "continue"], .hold(false))
            + each(["put on hold", "put the call on hold", "put it on hold", "on hold", "hold the call", "pause the call", "pause call"], .hold(true))
            + each(["join", "join the call", "join call", "start the call", "start call", "let me in"], .join)
            + each(["unmute", "un mute", "unmute me"], .mute(false))
            + each(["mute me", "mute the call", "mute", "silence"], .mute(true))
            + each(["switch camera", "flip camera", "switch the camera", "flip the camera", "rear camera", "back camera", "front camera", "selfie camera", "other camera", "turn the camera around"], .flipCamera)
            + each(["help", "what can i say", "what can you do", "commands", "options"], .help)
            + each(["repeat", "say again", "say that again", "come again", "pardon", "what did you say", "one more time"], .repeatLast),
        speakerWords: ["speaker", "speakerphone", "speaker phone", "loudspeaker", "loud speaker", "hands free"],
        earpieceWords: ["earpiece", "handset", "phone mode", "private mode"],
        cameraWords: ["camera", "video"],
        microphoneWords: ["microphone", "mic"],
        offWords: ["off", "disable", "stop", "hide", "deactivate", "close"],
        ordinals: [
            ["one", "first", "1", "1st"], ["two", "second", "2", "2nd"],
            ["three", "third", "3", "3rd"], ["four", "fourth", "4", "4th"],
        ],
        lastWords: ["last", "last one", "the last"],
        ordinalFillers: ["the", "number", "option", "contact", "one"],
    ).normalized()

    static let spanish = VoiceLexicon(
        wakeWords: ["oye signal", "hola signal", "ok signal", "okey signal", "oye señal", "hola señal", "signal", "señal"],
        politeness: ["por favor", "puedes", "podrías", "quiero", "quisiera", "me gustaría", "necesito", "ahora"],
        nameFillers: ["a", "al", "con", "mi", "la", "el"],
        nameTrailers: ["ahora", "otra", "vez", "de", "nuevo"],
        yesWords: ["si", "claro", "vale", "dale"],
        exact: each(["sí", "si", "claro", "correcto", "vale", "dale", "de acuerdo", "ok", "okey", "esa", "ese", "exacto", "hazlo", "sí por favor"], .yes)
            + each(["no", "no gracias", "incorrecto", "esa no", "ese no", "ninguno", "ninguna"], .no)
            + each(["cancela*", "cancelar", "olvídalo", "déjalo", "para", "detente", "alto", "nada"], .cancel)
            + each(["espera", "pausa"], .hold(true))
            + each(["sigue", "ya volví"], .hold(false))
            + each(["silencio"], .mute(true))
            + each(["escucha"], .wake)
            + each(["adiós", "a dormir"], .sleep)
            + each(["hola", "aló", "prueba", "probando", "hola hola"], .presenceCheck),
        priorityPhrases: each(["me oyes", "me escuchas", "me oís", "me oye", "me escucha", "estás ahí", "está ahí", "hay alguien",
                               "estás escuchando", "me estás escuchando", "estás despierto", "esto funciona"], .presenceCheck)
            + each(["llamadas perdidas", "llamada perdida", "quién llamó", "quién me llamó", "quién ha llamado", "historial de llamadas", "llamadas recientes"], .missedCalls)
            + each(["devuelve la llamada", "devolver la llamada", "vuelve a llamar", "volver a llamar", "rellama*", "remarca*", "llama de nuevo", "llama otra vez", "marca de nuevo"], .callBack)
            + each(["cuelga*", "colgar", "termina* la llamada", "finaliza* la llamada", "corta* la llamada", "sal de la llamada", "salir de la llamada"], .hangUp)
            + each(["no contestes", "no respondas", "rechaza*", "ignora*", "declina*", "ahora no"], .decline)
            + each(["deja de escuchar", "duérme*"], .sleep)
            + each(["despierta*", "empieza a escuchar"], .wake)
            + each(["repite lo que acabas de decir", "repite lo que dijiste", "repite eso", "vuelve a decirlo",
                    "qué acabas de decir", "puedes repetir", "repítelo"], .repeatLast),
        saveAs: ["guarda como", "guardar como", "guárdalo como", "añade como", "nómbralo"],
        callVerbs: ["llama*", "marca*", "telefonea*", "contacta*", "comunícame con", "ponme con", "haz una llamada a", "llamada a", "llamada con", "habla con"],
        videoCallVerbs: ["videollama*", "video llamada*", "llamada de video", "llamada por video", "haz una videollamada a", "haz una videollamada con"],
        groupCallVerbs: ["llamada grupal", "llamada grupal con", "llama al grupo", "llamada de grupo", "llamada al grupo"],
        videoSuffixes: ["por video", "con video", "en video", "por videollamada", "con cámara"],
        phrases: each(["contesta*", "responde*", "atiende*", "acepta*", "toma la llamada", "descuelga*"], .answer)
            + each(["quién llama", "quién es", "quién me está llamando"], .whoIsCalling)
            + each(["estado", "con quién hablo", "con quién estoy hablando", "estoy silenciado"], .status)
            + each(["reanuda*", "quita* la espera", "sal de la espera", "continúa*", "quitar pausa"], .hold(false))
            + each(["en espera", "pon* en espera", "pausa*"], .hold(true))
            + each(["únete", "unirme", "unirse", "entra*", "empieza* la llamada", "inicia* la llamada"], .join)
            + each(["quita* el silencio", "activa* el sonido", "reactiva* el micrófono"], .mute(false))
            + each(["silencia*", "mutea*"], .mute(true))
            + each(["cambia* la cámara", "cambiar cámara", "gira* la cámara", "cámara trasera", "cámara frontal", "otra cámara"], .flipCamera)
            + each(["ayuda", "qué puedo decir", "qué puedes hacer", "comandos", "opciones"], .help)
            + each(["repite*", "otra vez", "qué dijiste", "cómo dijiste", "perdón", "una vez más"], .repeatLast),
        speakerWords: ["altavoz", "manos libres", "parlante", "bocina"],
        earpieceWords: ["auricular", "modo privado"],
        cameraWords: ["cámara", "video"],
        microphoneWords: ["micrófono", "micro"],
        offWords: ["apaga*", "desactiva*", "quita*", "cierra*", "oculta*", "sin", "apagar", "desactivar"],
        ordinals: [
            ["uno", "una", "primero", "primera", "1"], ["dos", "segundo", "segunda", "2"],
            ["tres", "tercero", "tercera", "3"], ["cuatro", "cuarto", "cuarta", "4"],
        ],
        lastWords: ["último", "última"],
        ordinalFillers: ["el", "la", "número", "opción"],
    ).normalized()

    static let russian = VoiceLexicon(
        wakeWords: ["эй сигнал", "окей сигнал", "ок сигнал", "хей сигнал", "сигнал", "signal"],
        politeness: ["пожалуйста", "можешь", "мне нужно", "мне надо", "я хочу", "хочу", "надо", "сейчас"],
        nameFillers: ["мою", "моей", "моему", "мой", "моя", "моего", "с", "со", "к", "для"],
        nameTrailers: ["сейчас", "еще", "раз", "снова"],
        yesWords: ["да", "давай", "ага", "угу"],
        exact: each(["да", "давай", "верно", "конечно", "ага", "угу", "правильно", "точно", "хорошо", "ок", "окей", "этот", "эту", "да пожалуйста"], .yes)
            + each(["нет", "не", "неправильно", "не тот", "не та", "никого", "ни один"], .no)
            + each(["отмена", "отмени*", "стоп", "хватит", "не надо", "забудь", "прекрати"], .cancel)
            + each(["пауза", "удержание"], .hold(true))
            + each(["продолжи*"], .hold(false))
            + each(["слушай"], .wake)
            + each(["пока", "спи", "засыпай", "отдыхай"], .sleep)
            + each(["алло", "ало", "привет", "проверка", "ау", "алло алло"], .presenceCheck),
        priorityPhrases: each(["слышишь", "слышите", "меня слышно", "ты меня слышишь", "ты здесь", "ты тут", "вы здесь",
                               "ты слушаешь", "есть кто", "ты не спишь", "это работает"], .presenceCheck)
            + each(["пропущенн*", "кто звонил", "кто мне звонил", "история звонков", "последние звонки", "недавние звонки"], .missedCalls)
            + each(["перезвон*", "набер* еще раз", "набер* снова", "повтори* звонок", "позвони еще раз", "позвони снова", "верни* звонок"], .callBack)
            + each(["положи* трубку", "повесь* трубку", "заверш* звонок", "заверш* вызов", "заверш*", "законч* звонок", "законч*", "отбой", "прекрат* звонок", "выйди из звонка", "выйти из звонка"], .hangUp)
            + each(["отклон*", "не отвечай", "сбрось*", "сбросить", "игнорир*", "не сейчас"], .decline)
            + each(["перестань слушать", "хватит слушать"], .sleep)
            + each(["проснись", "начни слушать"], .wake)
            + each(["повтори что ты только что сказал", "повтори что ты только что сказала", "повтори что ты сказал",
                    "повтори что ты сказала", "повтори что только что сказал", "что ты только что сказал",
                    "что ты только что сказала", "повтори это"], .repeatLast),
        saveAs: ["сохрани как", "сохранить как", "назови", "добавь как"],
        callVerbs: ["позвон*", "набер*", "набрать", "вызов*", "звони*", "соедини* с", "соедини*", "свяжи* с", "свяжи*", "звонок"],
        videoCallVerbs: ["видеозвон*", "видео звонок", "видеовызов*"],
        groupCallVerbs: ["групповой звонок", "позвон* в группу", "звонок в группу"],
        videoSuffixes: ["по видео", "с видео", "по видеосвязи", "с камерой"],
        phrases: each(["ответь*", "ответить", "прими*", "принять", "возьми* трубку", "взять трубку"], .answer)
            + each(["кто звонит", "кто это", "кто там"], .whoIsCalling)
            + each(["статус", "состояние", "с кем я говорю", "с кем я разговариваю"], .status)
            + each(["сним* с удержания", "возобнов*", "продолж*", "сними паузу"], .hold(false))
            + each(["на удержание", "поставь на удержание", "удерживай", "поставь на паузу"], .hold(true))
            + each(["присоедин*", "войти", "войди", "зайди", "зайти", "начни* звонок", "начать звонок"], .join)
            + each(["без звука", "заглуши*"], .mute(true))
            + each(["переключи* камеру", "смени* камеру", "задн* камер*", "фронтальн* камер*", "другую камеру", "разверни* камеру"], .flipCamera)
            + each(["помощь", "помоги*", "что можно сказать", "что ты умеешь", "команды"], .help)
            + each(["повтори", "повтори еще раз", "еще раз", "что ты сказал", "что ты сказала", "не понял", "не поняла"], .repeatLast),
        speakerWords: ["громк* связ*", "громкую", "громкая", "динамик*", "спикер"],
        earpieceWords: ["через трубку", "в трубку", "разговорн* динамик*"],
        cameraWords: ["камер*", "видео"],
        microphoneWords: ["микрофон*", "звук"],
        offWords: ["выключи*", "выключить", "выкл", "отключи*", "отключить", "убери*", "скрой*", "останови*"],
        ordinals: [
            ["один", "одна", "первый", "первая", "первого", "первую", "первое", "1"],
            ["два", "две", "второй", "вторая", "второго", "вторую", "2"],
            ["три", "третий", "третья", "третьего", "третью", "3"],
            ["четыре", "четвертый", "четвертая", "четвертого", "четвертую", "4"],
        ],
        lastWords: ["последний", "последняя", "последнего", "последнюю"],
        ordinalFillers: ["номер", "вариант"],
    ).normalized()
}
