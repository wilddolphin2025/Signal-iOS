# Voice QA scenarios (STT → on-device AI → TTS)

Use this as a live script on the phone. Apple Intelligence must be on so AFM 3 is available.
The chat-list banner should show **Heard** and **Reply** for every step. After each scenario, mark pass / fail and note what was heard if it failed.

Setup once: enroll with **Hey Signal**, confirm **Can you hear me?** gets a reply, keep one real contact (for example Taras) and one unused number that is on Signal.

## How to score a step

| Column | Meaning |
|---|---|
| You say | Speak this, including the messy variants |
| STT | Banner heard line is close enough (paraphrase OK) |
| AI | Action is right even if the wording differs |
| TTS | Phone speaks a short, useful reply before or instead of acting |

Cancel, hang up, answer, and decline are allowed to skip the model so they stay instant.

---

## 1. Wake, lock, presence

| # | You say | Pass if |
|---|---|---|
| 1.1 | (launch the app, wait) | Phone says “When you are ready, please say Hey Signal.” |
| 1.2 | “Hey Signal.” | Enroll line the first time, or “Yes?” later. Commands from this voice work. |
| 1.3 | “Can you hear me?” / “Are you there?” / “Hello?” | “I hear you…” without placing a call. |
| 1.4 | Someone else says “Hey Signal, call Taras.” | Ignored (other voice). |
| 1.5 | You, after them: “Can you hear me now?” | Answers you. |
| 1.6 | Settings → Clear Voice Fingerprint, then “Hey Signal.” | Re-enrolls. Previous file kept. |

## 2. Natural calling (the old menu must not be required)

| # | You say | Pass if |
|---|---|---|
| 2.1 | “Call Taras.” | Countdown for that contact, then dial unless you cancel. |
| 2.2 | “Can you get Taras on the phone?” | Same contact, no “I didn’t catch that.” |
| 2.3 | “I need to talk to Taras.” | Same. |
| 2.4 | “Ring Taras for me please.” | Same. |
| 2.5 | “Put me through to Taras.” | Same. |
| 2.6 | “Hey Signal, Taras.” | Confirms or starts calling Taras. |
| 2.7 | “Call.” | Asks who. Then say only the name. |
| 2.8 | Misheard name, e.g. “Call Terrace.” | Asks “Did you mean Taras?” or similar. “Yes” / “Yeah go ahead” starts the call. “No” asks again. |
| 2.9 | “Video call Taras.” / “Can we FaceTime Taras on Signal?” | Video countdown. |
| 2.10 | “Call back.” / “Redial the last person.” | Starts the latest call. |

## 3. Numbers

| # | You say | Pass if |
|---|---|---|
| 3.1 | “Dial plus one, nine five four…” (a Signal user’s number) | Reads digits back. “Yes” / “Call” / “Do it” looks the number up, then countdown. |
| 3.2 | Same number after “That’s your own number…” | Must not be your account. If it is, it refuses. |
| 3.3 | Your own number | “That’s your own number…” No crash. |
| 3.4 | A number not on Signal | “That number isn’t on Signal…” No crash. |
| 3.5 | “Call a number.” then speak digits without “plus” | Asks country if needed; “United States” completes it. |
| 3.6 | Confirm, then “Save as Anna.” | Saves nickname, then countdown under that name. |
| 3.7 | “Yes. Yes.” on confirm | Treated as yes, not as a new name. |

## 4. Cancel (must be immediate)

| # | You say | Pass if |
|---|---|---|
| 4.1 | During “Calling… say cancel to stop”: “Cancel.” | Immediately “Cancelling call.” Does not dial. No crash. |
| 4.2 | Same moment: “Stop.” / “Never mind.” | Same. |
| 4.3 | While outgoing ring: “Cancel.” / “Signal, hang up.” | “Cancelling call,” then the call drops. No “Call ended” after it. No crash. |
| 4.4 | After “Checking if that number is on Signal”: “Cancel.” | Stops the lookup. |

## 5. In a live call

Start with Signal unless noted.

| # | You say | Pass if |
|---|---|---|
| 5.1 | Ordinary chat without “Signal” | Ignored. |
| 5.2 | “Signal, mute.” / “Signal, kill the mic.” | Muted. Other side cannot hear you. |
| 5.3 | “Signal, unmute.” / “Signal, I need the microphone back.” | Mic on. |
| 5.4 | “Signal, speaker on.” then “Signal, earpiece.” | Route changes. Headset stays on the headset. |
| 5.5 | “Signal, hold.” then “Signal, resume.” | 1:1 hold works. Group call mutes instead and says so. |
| 5.6 | “Signal, what’s going on?” / “Signal, status.” | Who you’re with, mute/hold/speaker. |
| 5.7 | “Signal, hang up.” / “Signal, I’m done.” | “Cancelling call,” then hang up. |
| 5.8 | Incoming ring: “Answer.” / “Decline.” / “Who’s calling?” | Works without Hey Signal. |

## 6. Time, date, internet, search

| # | You say | Pass if |
|---|---|---|
| 6.1 | “What time is it now?” / “What’s the time?” | Speaks the current clock time. Not a guessed time. |
| 6.2 | “What date?” / “What’s today?” / “What day is it?” | Speaks today’s weekday and date. |
| 6.3 | “Is the internet available?” / “Am I online?” | Yes + “say search for…”, or “No internet…” if offline. |
| 6.4 | After “yes”: “Search for the capital of France.” | Short spoken answer (Paris). |
| 6.5 | “Look up the tallest mountain.” | Short spoken answer. |
| 6.6 | “Search.” then “weather in Miami” | Asks what to search, then answers. |
| 6.7 | Airplane Mode, then “Search for cats.” | “No internet…” No crash. |
| 6.8 | Airplane Mode, “What time is it?” | Still speaks the time. |

## 7. Conversation and chatter

| # | You say | Pass if |
|---|---|---|
| 7.1 | TV or side talk: “How’s it going?” “Thank you.” “See you later.” | Silence. No call. |
| 7.2 | “Hey Signal.” then nothing | “Yes?” then waits. |
| 7.3 | “Hey Signal, what can you do?” / “Help.” | Short spoken help for the current situation, not a frozen menu. |
| 7.4 | “Repeat what you just said.” / “Say that again.” | Plays the last reply. |
| 7.5 | “Stop listening.” then “Call Taras.” | Sleeps. Command ignored until “Hey Signal, wake up.” |
| 7.6 | Follow-up: “Call someone.” → it asks who → “Taras.” | Uses the open question. |
| 7.7 | Two contacts with similar names | Offers a short choice. “The second one” / “the last one” works. |

## 8. Languages and messy STT

| # | You say | Pass if |
|---|---|---|
| 7.1 | “Позвони Тарасу.” | Same contact as “Call Taras.” |
| 7.2 | “Llama a Taras.” | Same. |
| 7.3 | Fast, mumbled “hey signal call taras” in one breath | Calls Taras. |
| 7.4 | “Call Taras” with a cough or “um” in the middle | Still calls Taras. |
| 7.5 | Room noise / driving | Either acts correctly or asks a short clarification. Never crashes. |

## 9. Failure and recovery

| # | You say / do | Pass if |
|---|---|---|
| 8.1 | Airplane Mode, then call a new number | “I couldn’t check that number…” No crash. |
| 8.2 | Turn Apple Intelligence off, then “Can you get Taras on the phone?” | Grammar fallback still places the call, or a clear spoken error. |
| 8.3 | Lock the screen (if “when locked” is on) | Still hears Hey Signal and cancel. |
| 8.4 | Start a call, cancel, immediately call again | Second call works. No leftover “Call ended.” / no crash. |

## Suggested 10-minute pass

Do 1.1–1.3, 2.2, 4.1, 6.1, 6.3, 6.4, 7.1. That covers enroll, paraphrase, cancel, time, internet, search, and chatter ignore.
