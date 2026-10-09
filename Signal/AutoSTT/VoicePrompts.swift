//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Everything the assistant says. Replies are short, name what happened, and end with
/// the one thing the listener can say next, because they can't see the screen.
enum VoicePrompt {
    case ready
    case off
    case wakeAck
    case enrolled
    case fingerprintCleared
    case sayHeySignal
    case hearYouSayHeySignal
    case hearYou(paused: Bool, inCall: Bool)
    case askWho(video: Bool)
    case notFound(String)
    case notFoundAgain
    case didYouMean(String)
    case calling(String, video: Bool)
    case groupCalling(String)
    case choices([String])
    case tooMany(Int, String)
    case canceled
    case cancellingCall
    case incoming(String, video: Bool)
    case noIncoming
    case noCall
    case callEnded
    case callConnected(String)
    case muted(Bool)
    case onHold(Bool)
    case holdUnsupported
    case speaker(Bool)
    case noSpeakerRoute
    case camera(Bool)
    case cameraFlipped
    case joining
    case status(String, [StatusDetail])
    case noMissed
    case missed([String])
    case nothingToRedial
    case blocked(String)
    case cantCall(String)
    case cantCallSelf
    case lookingUpNumber
    case numberNotOnSignal
    case numberLookupFailed
    case sleeping
    case awake
    case help(inCall: Bool)
    case didntCatch
    case timeout
    case nothingToRepeat
    case askNumber
    case confirmNumber(String)
    case askCountry
    case numberInvalid
    case numberSaved(String, String)
    case currentTime(String)
    case currentDate(String)
    case internetAvailable
    case internetUnavailable
    case askSearch
    case searching
    case searchFailed
    case searchNoResult

    enum StatusDetail { case muted, onHold, speaker, camera, ringing }

    func text(_ language: String) -> String {
        switch language {
        case "es": spanish
        case "ru": russian
        default: english
        }
    }

    private var english: String {
        switch self {
        case .ready: "Voice commands on. Say call and a name. Say help for more."
        case .off: "Voice commands off."
        case .wakeAck: "Yes?"
        case .enrolled: "I'll only take commands from you now. Clear the voice fingerprint in Settings to let someone else."
        case .fingerprintCleared: "Voice fingerprint cleared and kept on file. Please say Hey Signal."
        case .sayHeySignal: "When you are ready, please say Hey Signal."
        case .hearYouSayHeySignal: "I hear you. Please say Hey Signal."
        case .hearYou(paused: true, _): "I hear you, but I'm paused. Say Hey Signal, wake up."
        case .hearYou(_, inCall: true): "I hear you. Start with Signal, for example: Signal, mute."
        case .hearYou: "I hear you. Please ask with a command, like: call and a name."
        case .askWho(let video): video ? "Who should I video call?" : "Who should I call?"
        case .notFound(let name): "I couldn't find \(name). Say the name again, or say cancel."
        case .notFoundAgain: "I still can't find them. Try the full name, or say cancel."
        case .didYouMean(let name): "Did you mean \(name)? Say yes or no."
        case .calling(let name, let video): "\(video ? "Video calling" : "Calling") \(name). Say cancel to stop."
        case .groupCalling(let name): "Starting a group call in \(name). Say cancel to stop."
        case .choices(let names): "I found \(names.count): \(Self.numbered(names, "en")). Which one?"
        case .tooMany(let count, let name): "I found \(count) matches for \(name). Say the full name."
        case .canceled: "Canceled."
        case .cancellingCall: "Cancelling call."
        case .incoming(let name, let video): "Incoming \(video ? "video " : "")call from \(name). Say answer or decline."
        case .noIncoming: "There's no incoming call."
        case .noCall: "You're not on a call."
        case .callEnded: "Call ended."
        case .callConnected(let name): "Connected to \(name)."
        case .muted(let on): on ? "Muted." : "Microphone on."
        case .onHold(let on): on ? "On hold. Say Signal, resume, to continue." : "Resumed."
        case .holdUnsupported: "Group calls can't be held. I muted your microphone and camera instead."
        case .speaker(let on): on ? "Speaker on." : "Speaker off."
        case .noSpeakerRoute: "A headset is connected, so audio stays there."
        case .camera(let on): on ? "Camera on." : "Camera off."
        case .cameraFlipped: "Camera switched."
        case .joining: "Joining."
        case .status(let name, let details): "On a call with \(name)." + details.map { " " + Self.english($0) }.joined()
        case .noMissed: "No missed calls."
        case .missed(let items): "\(items.count) missed: \(items.joined(separator: "; ")). Say call back to return the latest."
        case .nothingToRedial: "There's no recent call to return."
        case .blocked(let name): "\(name) is blocked. Unblock them in Signal first."
        case .cantCall(let name): "I can't call \(name)."
        case .cantCallSelf: "That's your own number. Say a different number, or a contact name."
        case .lookingUpNumber: "Checking if that number is on Signal."
        case .numberNotOnSignal: "That number isn't on Signal. Say another number, or a contact name."
        case .numberLookupFailed: "I couldn't check that number. Check your connection and say the number again."
        case .sleeping: "Okay, I'll stop listening. Say Hey Signal, wake up, when you need me."
        case .awake: "I'm listening."
        case .help(inCall: false): "You can say: call and a name; what time is it; what date; is the internet available; search for something; or stop listening."
        case .help(inCall: true): "Start with Signal, then say: mute, unmute, hold, resume, speaker on or off, camera on or off, switch camera, status, or hang up."
        case .didntCatch: "Sorry, I didn't catch that. Say help to hear what you can say."
        case .timeout: "I'll stop here. Say call and a name when you're ready."
        case .nothingToRepeat: "I haven't said anything yet."
        case .askNumber: "Say the number, starting with plus and the country code, for example plus 1 6 5 0…"
        case .confirmNumber(let spoken): "That's \(spoken). Say yes to call, say the number again to correct it, or say save as and a name."
        case .askCountry: "Which country is that number in? For example, United States, Canada, or Russia."
        case .numberInvalid: "That doesn't look like a working number. Say it again, digit by digit, starting with plus."
        case .numberSaved(let name, let spoken): "Saved \(name) as \(spoken)."
        case .currentTime(let time): "It's \(time)."
        case .currentDate(let date): "Today is \(date)."
        case .internetAvailable: "Yes, the internet is available. You can say search for, then what you want."
        case .internetUnavailable: "No internet right now. I can still tell the time, or place a call."
        case .askSearch: "What should I search for?"
        case .searching: "Looking that up."
        case .searchFailed: "I couldn't reach the internet. Try again when you're online."
        case .searchNoResult: "I couldn't find a short answer for that. Try a simpler search."
        }
    }

    private static func english(_ detail: StatusDetail) -> String {
        switch detail {
        case .muted: "Your microphone is muted."
        case .onHold: "The call is on hold."
        case .speaker: "Speaker is on."
        case .camera: "Your camera is on."
        case .ringing: "Still ringing."
        }
    }

    private var spanish: String {
        switch self {
        case .ready: "Comandos de voz activados. Di llama y un nombre. Di ayuda para más."
        case .off: "Comandos de voz desactivados."
        case .wakeAck: "¿Sí?"
        case .enrolled: "A partir de ahora solo te haré caso a ti. Borra la huella de voz en Ajustes para que pueda otra persona."
        case .fingerprintCleared: "Huella de voz borrada y guardada en el archivo. Por favor di Oye Signal."
        case .sayHeySignal: "Cuando quieras, por favor di Oye Signal."
        case .hearYouSayHeySignal: "Te oigo. Por favor di Oye Signal."
        case .hearYou(paused: true, _): "Te oigo, pero estoy en pausa. Di Oye Signal, despierta."
        case .hearYou(_, inCall: true): "Te oigo. Empieza con Signal, por ejemplo: Signal, silencia."
        case .hearYou: "Te oigo. Pídeme algo con un comando, por ejemplo: llama y un nombre."
        case .askWho(let video): video ? "¿A quién hago la videollamada?" : "¿A quién llamo?"
        case .notFound(let name): "No encontré a \(name). Repite el nombre o di cancelar."
        case .notFoundAgain: "Sigo sin encontrarlo. Di el nombre completo o di cancelar."
        case .didYouMean(let name): "¿Te refieres a \(name)? Di sí o no."
        case .calling(let name, let video): "\(video ? "Videollamada a" : "Llamando a") \(name). Di cancelar para detener."
        case .groupCalling(let name): "Iniciando llamada grupal en \(name). Di cancelar para detener."
        case .choices(let names): "Encontré \(names.count): \(Self.numbered(names, "es")). ¿Cuál?"
        case .tooMany(let count, let name): "Hay \(count) coincidencias para \(name). Di el nombre completo."
        case .canceled: "Cancelado."
        case .cancellingCall: "Cancelando la llamada."
        case .incoming(let name, let video): "\(video ? "Videollamada" : "Llamada") entrante de \(name). Di contesta o rechaza."
        case .noIncoming: "No hay ninguna llamada entrante."
        case .noCall: "No estás en una llamada."
        case .callEnded: "Llamada finalizada."
        case .callConnected(let name): "Conectado con \(name)."
        case .muted(let on): on ? "Micrófono silenciado." : "Micrófono activado."
        case .onHold(let on): on ? "En espera. Di Signal, reanuda, para continuar." : "Llamada reanudada."
        case .holdUnsupported: "Las llamadas grupales no se pueden poner en espera. Silencié tu micrófono y cámara."
        case .speaker(let on): on ? "Altavoz activado." : "Altavoz desactivado."
        case .noSpeakerRoute: "Hay auriculares conectados, el audio sigue ahí."
        case .camera(let on): on ? "Cámara activada." : "Cámara desactivada."
        case .cameraFlipped: "Cámara cambiada."
        case .joining: "Uniéndome."
        case .status(let name, let details): "En llamada con \(name)." + details.map { " " + Self.spanish($0) }.joined()
        case .noMissed: "No hay llamadas perdidas."
        case .missed(let items): "\(items.count) perdidas: \(items.joined(separator: "; ")). Di devuelve la llamada para llamar a la última."
        case .nothingToRedial: "No hay ninguna llamada reciente para devolver."
        case .blocked(let name): "\(name) está bloqueado. Desbloquéalo primero en Signal."
        case .cantCall(let name): "No puedo llamar a \(name)."
        case .cantCallSelf: "Ese es tu propio número. Di otro número o un nombre."
        case .lookingUpNumber: "Comprobando si ese número está en Signal."
        case .numberNotOnSignal: "Ese número no está en Signal. Di otro número o un nombre."
        case .numberLookupFailed: "No pude comprobar ese número. Revisa la conexión y dilo otra vez."
        case .sleeping: "De acuerdo, dejo de escuchar. Di Oye Signal, despierta, cuando me necesites."
        case .awake: "Te escucho."
        case .help(inCall: false): "Puedes decir: llama y un nombre; qué hora es; qué fecha es; hay internet; busca y lo que quieras; o deja de escuchar."
        case .help(inCall: true): "Empieza con Signal y di: silencia, activa el micrófono, espera, reanuda, altavoz, cámara, cambia la cámara, estado o cuelga."
        case .didntCatch: "Perdona, no te entendí. Di ayuda para saber qué puedes decir."
        case .timeout: "Lo dejo aquí. Di llama y un nombre cuando quieras."
        case .nothingToRepeat: "Todavía no he dicho nada."
        case .askNumber: "Di el número, empezando por más y el código de país, por ejemplo más 1 6 5 0…"
        case .confirmNumber(let spoken): "Es \(spoken). Di sí para llamar, repite el número para corregirlo, o di guarda como y un nombre."
        case .askCountry: "¿De qué país es ese número? Por ejemplo, Estados Unidos, Canadá o Rusia."
        case .numberInvalid: "Ese número no parece válido. Dilo otra vez, dígito a dígito, empezando por más."
        case .numberSaved(let name, let spoken): "Guardé \(name) como \(spoken)."
        case .currentTime(let time): "Son las \(time)."
        case .currentDate(let date): "Hoy es \(date)."
        case .internetAvailable: "Sí, hay internet. Di busca y lo que quieras."
        case .internetUnavailable: "No hay internet ahora. Puedo decirte la hora o hacer una llamada."
        case .askSearch: "¿Qué busco?"
        case .searching: "Lo busco."
        case .searchFailed: "No pude conectar. Inténtalo cuando haya internet."
        case .searchNoResult: "No encontré una respuesta corta. Prueba una búsqueda más simple."
        }
    }

    private static func spanish(_ detail: StatusDetail) -> String {
        switch detail {
        case .muted: "Tu micrófono está silenciado."
        case .onHold: "La llamada está en espera."
        case .speaker: "El altavoz está activado."
        case .camera: "Tu cámara está activada."
        case .ringing: "Sigue sonando."
        }
    }

    private var russian: String {
        switch self {
        case .ready: "Голосовые команды включены. Скажите: позвони и имя. Скажите помощь, чтобы узнать больше."
        case .off: "Голосовые команды выключены."
        case .wakeAck: "Да?"
        case .enrolled: "Теперь принимаю команды только от вас. Чтобы передать управление, удалите голосовой отпечаток в настройках."
        case .fingerprintCleared: "Голосовой отпечаток снят и сохранён в файле. Пожалуйста, скажите Эй Сигнал."
        case .sayHeySignal: "Когда будете готовы, пожалуйста, скажите Эй Сигнал."
        case .hearYouSayHeySignal: "Слышу вас. Пожалуйста, скажите Эй Сигнал."
        case .hearYou(paused: true, _): "Слышу вас, но я на паузе. Скажите Эй Сигнал, проснись."
        case .hearYou(_, inCall: true): "Слышу вас. Начните со слова Сигнал, например: Сигнал, выключи микрофон."
        case .hearYou: "Слышу вас. Скажите команду, например: позвони и имя."
        case .askWho(let video): video ? "Кому сделать видеозвонок?" : "Кому позвонить?"
        case .notFound(let name): "Не удалось найти \(name). Повторите имя или скажите отмена."
        case .notFoundAgain: "Всё ещё не найдено. Назовите полное имя или скажите отмена."
        case .didYouMean(let name): "Вы имели в виду \(name)? Скажите да или нет."
        case .calling(let name, let video): "\(video ? "Видеозвонок" : "Звоню"): \(name). Скажите отмена, чтобы остановить."
        case .groupCalling(let name): "Групповой звонок в \(name). Скажите отмена, чтобы остановить."
        case .choices(let names): "Найдено вариантов: \(names.count). \(Self.numbered(names, "ru")). Какой?"
        case .tooMany(let count, let name): "Совпадений для \(name): \(count). Назовите полное имя."
        case .canceled: "Отменено."
        case .cancellingCall: "Отменяю звонок."
        case .incoming(let name, let video): "\(video ? "Входящий видеозвонок" : "Входящий звонок") от \(name). Скажите ответь или отклони."
        case .noIncoming: "Входящего звонка нет."
        case .noCall: "Сейчас нет звонка."
        case .callEnded: "Звонок завершён."
        case .callConnected(let name): "Соединено: \(name)."
        case .muted(let on): on ? "Микрофон выключен." : "Микрофон включён."
        case .onHold(let on): on ? "Звонок на удержании. Скажите Сигнал, продолжи." : "Звонок продолжен."
        case .holdUnsupported: "Групповой звонок нельзя поставить на удержание. Микрофон и камера выключены."
        case .speaker(let on): on ? "Громкая связь включена." : "Громкая связь выключена."
        case .noSpeakerRoute: "Подключена гарнитура, звук остаётся в ней."
        case .camera(let on): on ? "Камера включена." : "Камера выключена."
        case .cameraFlipped: "Камера переключена."
        case .joining: "Подключаюсь."
        case .status(let name, let details): "Разговор: \(name)." + details.map { " " + Self.russian($0) }.joined()
        case .noMissed: "Пропущенных звонков нет."
        case .missed(let items): "Пропущенных: \(items.count). \(items.joined(separator: "; ")). Скажите перезвони, чтобы ответить на последний."
        case .nothingToRedial: "Нет недавних звонков."
        case .blocked(let name): "\(name): контакт заблокирован. Сначала разблокируйте его в Signal."
        case .cantCall(let name): "Невозможно позвонить: \(name)."
        case .cantCallSelf: "Это ваш собственный номер. Назовите другой номер или имя."
        case .lookingUpNumber: "Проверяю, есть ли этот номер в Signal."
        case .numberNotOnSignal: "Этого номера нет в Signal. Назовите другой номер или имя."
        case .numberLookupFailed: "Не удалось проверить номер. Проверьте связь и повторите номер."
        case .sleeping: "Хорошо, больше не слушаю. Скажите Эй Сигнал, проснись, когда понадоблюсь."
        case .awake: "Слушаю."
        case .help(inCall: false): "Можно сказать: позвони и имя; который час; какая дата; есть интернет; найди и запрос; или перестань слушать."
        case .help(inCall: true): "Скажите Сигнал и команду: выключи микрофон, включи микрофон, удержание, продолжи, громкая связь, камера, переключи камеру, статус или заверши."
        case .didntCatch: "Не удалось разобрать. Скажите помощь, чтобы узнать команды."
        case .timeout: "Пока остановлюсь. Скажите позвони и имя, когда будете готовы."
        case .nothingToRepeat: "Пока нечего повторить."
        case .askNumber: "Назовите номер, начиная с плюс и кода страны, например плюс 1 6 5 0…"
        case .confirmNumber(let spoken): "Это \(spoken). Скажите да, чтобы позвонить, повторите номер, чтобы исправить, или скажите сохрани как и имя."
        case .askCountry: "Какая страна у этого номера? Например, США, Канада или Россия."
        case .numberInvalid: "Похоже, номер неверный. Повторите по цифрам, начиная с плюс."
        case .numberSaved(let name, let spoken): "Сохранено: \(name), \(spoken)."
        case .currentTime(let time): "Сейчас \(time)."
        case .currentDate(let date): "Сегодня \(date)."
        case .internetAvailable: "Интернет есть. Скажите найди и что искать."
        case .internetUnavailable: "Интернета нет. Могу сказать время или позвонить."
        case .askSearch: "Что найти?"
        case .searching: "Ищу."
        case .searchFailed: "Нет связи. Повторите, когда появится интернет."
        case .searchNoResult: "Короткого ответа нет. Сформулируйте запрос проще."
        }
    }

    private static func russian(_ detail: StatusDetail) -> String {
        switch detail {
        case .muted: "Ваш микрофон выключен."
        case .onHold: "Звонок на удержании."
        case .speaker: "Громкая связь включена."
        case .camera: "Камера включена."
        case .ringing: "Идёт вызов."
        }
    }

    private static func numbered(_ names: [String], _ language: String) -> String {
        let words: [String] = switch language {
        case "es": ["uno", "dos", "tres", "cuatro"]
        case "ru": ["один", "два", "три", "четыре"]
        default: ["one", "two", "three", "four"]
        }
        return names.prefix(words.count).enumerated().map { "\(words[$0.offset]), \($0.element)" }.joined(separator: "; ")
    }
}
