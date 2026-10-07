# AutoSTT: on-device speech for Signal

Dictation, voice-message transcription and read-aloud in English, Spanish and Russian.
Everything runs on the iPhone (Apple Speech, Foundation Models, AVSpeechSynthesizer); no external APIs.
After a one-time model download it works offline.

Requires iOS 26+. The language-model polish needs an Apple Intelligence iPhone (15 Pro or newer).

## Files

| File | Contents |
|---|---|
| `OnDeviceSTT.swift` | Settings, transcript model (segments, words, turns), audio conditioning, speaker diarization |
| `OnDeviceSTTSession.swift` | Recognition session (mic or file), model install with fallback, language detection |
| `OnDeviceSpeechIntelligence.swift` | Rule-based smart formatting, Apple language-model polish, text-to-speech |
| `AutoSTTViewController.swift` | Dictate / Transcript sheet |
| `VoiceCommandGrammar.swift` | Hands-free command vocabulary (en/es/ru) and parser |
| `VoicePrompts.swift` | Everything the assistant says back, per language |
| `VoiceContactMatcher.swift` | Spoken-name search: phonetic Latin keys, Russian case endings, fuzzy match |
| `VoiceCommandService.swift` | Listener lifecycle, dialogs, call control, echo suppression, announcements |
| `VoiceCommandBanner.swift` | Chat list mic button and "heard / replied" banner |

## Build and install on an iPhone

1. In Xcode, open **Settings → Accounts** and sign in with the Apple ID of team `PPZTNTHDFC` (paid membership).
2. Connect the iPhone, then build, install and launch:

```bash
cd ~/Public/Signal-iOS
xcodebuild -workspace Signal.xcworkspace -scheme Signal -configuration Debug \
  -destination 'id=00008130-0011305E34D8001C' -allowProvisioningUpdates \
  -derivedDataPath build/DeviceDD build
xcrun devicectl device install app --device 00008130-0011305E34D8001C \
  build/DeviceDD/Build/Products/Debug-iphoneos/Signal.app
xcrun devicectl device process launch --terminate-existing \
  --device 00008130-0011305E34D8001C us.wilddolphin.signal
```

List connected devices with `xcrun devicectl list devices`.

## Set up on the phone

1. Register with your phone number. This is a separate app (`us.wilddolphin.signal`) from App Store Signal.
2. Turn on Apple Intelligence: **iOS Settings → Apple Intelligence & Siri**.
3. In Signal, open **Settings → Chats → On-Device Speech** and turn on **AutoSTT**.
4. Leave **Spoken Language** on **Automatic**, and keep **Speaker Labels**, **Smart Formatting** and **Noise Attenuation** on.
5. Tap **Download Speech Models for Offline Use** and wait for "Ready for offline use: English, Spanish, Russian".
6. Check the footer. On iOS 27 it should end with "Formatting model: AFM 3 Core Advanced" (or "AFM 3 Core"); on iOS 26 it shows "Apple Foundation Model (iOS 26)".

## Test

**Dictation (live mic)**
1. In any chat (Note to Self is easiest), tap **+**, then **Dictate**.
2. Speak. Gray text is the live partial result; it becomes formatted text as each phrase is finalized.
3. Tap **Stop**, then **Insert** (into the message box), **Speak** (read aloud) or **Send Voice** (send as a voice message).

**Voice-message transcription (speaker labels)**
1. Record or receive a voice message.
2. Long-press it and tap **Transcribe**.
3. Check the timestamps and the "Speaker 1 / Speaker 2" labels. **Copy** and **Speak** are available.

**Things to try**
- **Offline:** turn on Airplane Mode and repeat both tests.
- **Formatting:** say "twenty five percent", "john at gmail dot com" or "three pm".
- **Languages:** speak Spanish or Russian with the language set to Automatic.
- **Noise:** dictate with music or a TV playing.
- **Diarization:** record two people taking turns, at least 2–3 seconds of speech each.

## Hands-free calling (voice commands)

Turn on with the **mic button** at the top of the chat list, or **Settings → Chats → Voice Commands → Hands-Free Calling**.
The banner at the bottom of the chat list shows what was heard and the reply; tap it to wake or resume.

On every launch Signal says **“Please say Hey Signal.”** The first voice that answers is saved as a fingerprint (`AutoSTT/voice-fingerprint.bin` in the app container). Later commands are accepted only from that voice. **Settings → Voice Commands → Clear Voice Fingerprint** drops the active lock so someone else can enroll; the previous print is copied to `voice-fingerprint.cleared.bin` and is not deleted. If that same person says Hey Signal again, the saved file is restored.

Design rules (for someone who can speak and listen but not touch the phone):
- Every action is answered aloud, and every reply ends with what to say next.
- Dialing starts after a short spoken countdown ("Calling Anna. Say cancel to stop."), so a misheard name never rings anyone.
- Outside calls no wake word is needed; unrecognized speech is ignored silently (no nagging at TV or conversation).
- During a call every command needs **"Signal, …"**, so normal conversation is never acted on.
- An incoming call is announced with the caller's name, and "answer" / "decline" work without the wake word.
- If nothing is said for 12 seconds during a question, it gives up politely.

| Say | Does |
|---|---|
| "Call Anna", "Dial Mom", "Phone John Smith" | Finds the contact, counts down, calls |
| "Call plus 1 6 5 0 4 5 0 8 0 2 5", "Dial a number" | Reads the number back, asks country if needed, then yes / say it again / save as a name |
| "Video call Alex", "Call Masha on video" | Video call |
| "Group call Family", "Call the group Work" | Opens the group call and joins it |
| "Call" (no name) | "Who should I call?" then say the name |
| "Call back", "Redial" | Calls the most recent call |
| "Missed calls", "Who called?" | Reads the last 3 missed calls with times |
| "Answer" / "Decline", "Who's calling?" | Incoming calls |
| "Signal, hang up" / "end the call" | Ends the call (or cancels a pending dial) |
| "Signal, mute" / "unmute" / "microphone off" | Microphone |
| "Signal, hold" / "pause" / "resume" | Hold (1:1); in group calls mutes mic and camera instead |
| "Signal, speaker on/off", "earpiece" | Audio route (headsets keep the audio) |
| "Signal, camera on/off", "switch camera" | Video |
| "Signal, join" | Join a group call lobby |
| "Signal, status" | "On a call with Anna. Your microphone is muted." |
| "Can you hear me?", "Are you there?", "Hello?" | "I hear you. Please ask with a command, like: call and a name." Answered even while paused; during a call only after "Signal, …" |
| "Hey Signal" (alone) | First time: saves your voice. Later: “Yes?”, then the next sentence counts as a command |
| "Repeat what you just said", "Say that again" | Plays back Signal's last spoken reply |
| "Help", "Cancel" | |
| "Stop listening" / "Hey Signal, wake up" | Sleep and wake |

**Finding a contact.** One clear match: countdown and call. Unsure match: "Did you mean Anna Lee? Say yes or no."
2–4 matches: "I found 3: one, John Smith; two, John Appleseed; three, Johnny Cash. Which one?" Answer "the second one", "the last one" or a last name ("Appleseed").
More than 4: "Say the full name." Not found: "I couldn't find Bob. Say the name again, or say cancel."
Names match across scripts and cases ("Masha" = "Маша" = "Маше", "Ивану" = "Иван"), and spelled letters ("J O H N") work.

Spanish and Russian work the same way ("Llama a Juan", "Oye Signal, cuelga", "Позвони Маше", "Сигнал, громкая связь"). The command language is the AutoSTT **Spoken Language** (Automatic = the iPhone's first supported language).

**Test**
1. Turn it on and wait for "Voice commands on…".
2. Say "Call" and a contact name, then say "cancel" during the countdown. Expected reply: "Canceled."
3. Say "Call" and the name again and let it dial. While it rings, say "Signal, status", then "Signal, speaker on".
4. Once connected, say "Signal, mute" and confirm the other side stops hearing you. Then say "Signal, hang up".
5. Have someone call you and say "Answer".
6. Lock the screen and say "Hey Signal, missed calls".
7. In the Xcode console, filter on `Voice commands` to see each parsed command.

## Diagnostics: crash reports and logs

With the iPhone connected (USB or same Wi-Fi as a paired Mac), run:

```bash
~/Public/Signal-iOS/Signal/AutoSTT/collect-logs.sh
```

- **Output:** `~/Desktop/SignalLogs/<timestamp>/`, opened in Finder when done.
  - `crashes/`: every `Signal-*.ips` crash report on the phone.
  - `logs/`: Signal's own log files, from the app container's `Library/Caches/Logs`.
  - `summary.txt`: the latest crash (exception and crashed-thread stack), followed by the last 80 lines about voice commands, AutoSTT, call audio and errors.
- **Voice command log lines:**
  - `Voice commands heard "<text>" -> <command> addressed=<wake word?> dialog=<state>`
  - `Voice commands say: <reply>`
  - `Voice commands mode idle -> inCall`
  - `Voice commands dialog: …`
- **Heard text is written to the log file on the phone.** It only leaves the phone when you run the script.
- **On the phone itself,** iOS keeps crash reports in **iOS Settings → Privacy & Security → Analytics & Improvements → Analytics Data** (entries starting with `Signal-`).
- **Avoid Signal's built-in "Submit Debug Log"** for this build. It uploads to Signal's servers.
- **Debug builds stop on `owsFailDebug` assertions** (`EXC_BREAKPOINT` in the summary). Release builds only log them. A crash with `owsFailDebug` near the top of the stack is a debug-only assertion. The line just above it in the log says what failed.

## Gotchas

**Models and languages**
- **iOS limits how many speech-model languages an app can reserve.** If Apple's newer SpeechTranscriber model can't be installed for a language (this happened with Russian: "asset unavailable … Not Installing"), the app falls back to DictationTranscriber, iOS's keyboard-dictation recognizer. It remembers this per language in `AutoSTT.dictationOnly`. The fallback is slightly less accurate and formatted.
- **If a language is still "Not available"**, free up storage, use Wi-Fi, and add that language's keyboard with **Enable Dictation** on (**iOS Settings → General → Keyboard → Keyboards**). Then download again.
- **Auto-detection only considers installed languages.** If only English is installed, Spanish audio is transcribed as (wrong) English. Download all models first.
- **To retry the newer recognizer** for a language after a fallback, delete and reinstall the app, or clear `AutoSTT.dictationOnly` in UserDefaults.

**Apple Intelligence**
- **"Apple Intelligence off — rule-based formatting"** means Apple Intelligence is disabled. Speech-to-text still works; only the language-model polish is skipped.
- **If the Apple Intelligence switch is grayed out,** the iPhone and Siri language must match a supported language, and the region must allow it.
- **"Language model downloading"**: normal after a major iOS update, when iOS fetches the new AFM 3 models (several GB) in the background. Keep the phone unlocked on Wi-Fi and charging, with enough free storage. Progress shows in **iOS Settings → Apple Intelligence & Siri**. While Chats settings is open, the footer re-checks every 5 seconds.
- **AFM 3 needs iOS 27.** On iOS 26 the footer reads "Apple Foundation Model (iOS 26)": that is the previous on-device model, and the API that names the variant doesn't exist yet. Update to iOS 27 to get AFM 3 (Core 3 or Core Advanced 3).
- **iOS picks the model** (Core 3 or Core Advanced 3) for each device; the app can't force it.
- **The polish step can only fix punctuation, casing and digits.** Any output that adds a word, or drops more than one in ten, is discarded, because in testing the model sometimes rewrote meaning ("Can you email me" became "I cannot send").

**Speaker labels (diarization)**
- **Apple's SDK has no speaker separation.** This app uses its own lightweight method: MFCC voice features plus clustering. It was tuned on clean synthetic voices, so expect lower accuracy on noisy calls.
- **Live labels start as one speaker.** After each finalized phrase, the app re-clusters everything heard so far and fixes earlier labels. A new speaker appears only after ~3–4 s of clearly different voice. Final labels are recomputed once more when the audio ends.
- **Each clustering run is logged** as `AutoSTT diarization: N windows, K speaker(s), last merged separation X`. The separation threshold is 3.5; use these logs to tune `separationThreshold` and `minSpeakerWindows` in `STTSpeakerDiarizer`.
- **A speaker with under ~2–3 seconds of speech in total** is merged into the closest speaker.
- **Speaker numbers restart in every dictation session or transcript.**

**Voice commands**
- **Listening during calls is the riskiest part.** The call (WebRTC) owns the audio session and the only echo canceller. The in-call listener therefore shares the session, without its own voice processing and without an audio activity. If call audio breaks or gets choppy, turn off **Listen During Calls**; the incoming-call announcement and "answer" still work.
- **The in-call listener must let go of the microphone when a call ends.** Otherwise iOS refuses Signal's switch back to normal audio, and Debug builds crash (fixed Oct 7). It now releases the microphone before any voice hang-up. If iOS refuses the switch anyway, for example when the other person hangs up, Signal's call audio code asks the listener to release the microphone and retries (`CallAudioService.setAudioSession`).
- **While an outgoing call is still ringing, "cancel" and "hang up" work without "Signal, …".** Nobody is on the line yet.
- **The wake word can have up to two words before it.** The recognizer often hears "A signal…" or "Okay, so Signal…".
- **The listener pauses for a few seconds while a call is being set up or answered** so the two don't fight over the microphone. It resumes inside the call about 1 second after audio is live.
- **The assistant can hear itself.** Speech recognized while it is talking is matched against the prompt it was saying, and the echoed words are dropped. A "cancel" said right after "…Say cancel to stop" still counts.
- **Listening can continue with the screen locked** (the app has the `audio` background mode), but iOS can't *start* the microphone in the background. Turn it on while the app is open. The orange mic dot shows while it listens.
- **The screen stays awake** while voice commands are on, the app is open and you're not on a call.
- **A changed safety number still needs a tap.** Signal shows a confirmation sheet before calling someone whose safety number changed; voice can't confirm it.
- **Contact names come from your chats and Signal contacts.** The list refreshes every 5 minutes and the 300 most recent names are given to the recognizer as hints. Note to Self isn't callable.
- **The parser runs on a Mac.** Copy `VoiceCommandGrammar.swift`, `VoiceContactMatcher.swift` and `VoicePrompts.swift` (no Signal dependencies) and call `VoiceCommandParser.parse` and `VoiceContactMatcher.match` from a `main.swift`.

**Signing and build**
- **The bundle ID prefix is `us.wilddolphin`** (`SIGNAL_BUNDLEID_PREFIX`), and every target uses team `PPZTNTHDFC`.
- **Development entitlements drop three capabilities** your team can't provision: Apple Pay (`merchant.org.signalfoundation` belongs to Signal), carrier-constrained networking (Apple has to grant it) and Wi-Fi Aware. Donations via Apple Pay won't work in this build. The App Store entitlement files are untouched.
- **"No Accounts" during the build** means Xcode has no Apple ID signed in (step 1 of "Build and install").
- **Reinstalling over the app keeps your registration;** deleting the app erases it.
- **The Debug build may connect to Signal's staging servers,** so registration can behave differently from the App Store app.
- **Commit the signing changes separately** from the feature (`chore: local device signing` and `feat: on-device AutoSTT`).

**Testing on a Mac**
- **The speech engine also runs on macOS 27.** Copy the three `OnDevice*.swift` files, remove the `SignalServiceKit`/`SignalUI` imports, add small stand-ins for `Logger`, `OWSLocalizedString`, `AudioActivity` and similar, and build with `swiftc -parse-as-library -target arm64-apple-macos27.0`.
- **Test-clip voices:** generate test speech with `say -v Fred|Samantha|Daniel|"Eddy (Spanish (Mexico))"|Paulina|Milena -o x.aiff "…"`. Voices that aren't installed (for example "Flo") make `say` hang.
- **Close the output file when writing WAVs** with `AVAudioFile`. Otherwise the header records a length of 0 and nothing gets transcribed.
- **zsh doesn't word-split `$var`.** Use `${=var}` when a variable holds several arguments.

**Cursor**
- **Use local Cursor chats for this project.** Cloud agents are not used.
- **If you ever need a My Machines worker,** the command is `~/.local/bin/cursor-agent worker --worker-dir ~/Public/Signal-iOS --name signal-ios-mac start`. The `worker` subcommand is required, and its options must come before `start`.
