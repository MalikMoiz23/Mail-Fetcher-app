# Important Mail

Android app that reads a Gmail inbox over IMAP, scores every message against an
on-device rule engine, and notifies about interviews, offers and assessments —
while suppressing rejections.

Built for one problem: important hiring mail getting buried in a high-volume
inbox.

---

## Stack and why

| Decision | Choice | Reason |
| --- | --- | --- |
| Mail access | Gmail IMAP + App Password (`enough_mail`) | `gmail.readonly` is a *restricted* OAuth scope. A published OAuth app needs a paid Google security assessment; an App Password needs nothing but your own account. |
| Classification | On-device weighted rules | Free, offline, instant, no API key, auditable. Every verdict lists the rules that fired. |
| Background | WorkManager periodic poll | No server, no cloud bill. Android's floor is 15 minutes. |
| Platform | Android only | iOS has no guaranteed periodic background execution and would force a server + FCM. |

Credentials live in the Android Keystore (`flutter_secure_storage`). Nothing
leaves the device except the IMAP connection to `imap.gmail.com:993`.

---

## Setup

### 1. Generate a Gmail App Password

1. Enable **2-Step Verification** on the Google account. App Passwords do not
   exist without it.
2. Go to <https://myaccount.google.com/apppasswords>.
3. Name it anything, create it, copy the 16-character code.

That code is not your Google password. It grants mail access only and is
revocable from the same page. Spaces in it are ignored by the app.

If login fails with the password confirmed correct, check that a Workspace
administrator has not disabled IMAP for the account.

### 2. Install

```powershell
flutter pub get
flutter run                      # debug, device attached
flutter build apk --release      # installable APK
```

Output: `build/app/outputs/flutter-apk/app-release.apk`.

The release build is signed with the debug key (Flutter template default).
Replace `signingConfig` in [android/app/build.gradle.kts](android/app/build.gradle.kts)
before distributing it anywhere.

### 3. Exempt from battery optimisation — not optional

Xiaomi, Samsung, Oppo and Vivo builds kill background work aggressively. Without
an exemption the 15-minute poll can be delayed by hours or skipped entirely.

**Settings → Exempt from battery optimisation** opens the system list. Set this
app to *Not optimised* / *No restrictions*.

---

## How classification works

Score = sum of every phrase that matches. **Subject matches count double** —
senders put the point of the mail in the subject line.

But **score alone never decides**. A purely additive score lets weak signals
conspire: `"Your application to Acme"` from `greenhouse.io` mentioning
`position` scores 16 while containing no interview and no offer. So groups are
tiered by how much authority they carry.

| Group | Weight | Tier | Examples |
| --- | --- | --- | --- |
| Offer | 10 | **Can notify** | `offer letter`, `excited to offer`, `pleased to extend` |
| Interview | 10 | **Can notify** | `interview invitation`, `interview is scheduled`, `ai interview`, `one way interview`, `you have been shortlisted`, `hirevue` |
| Assessment | 10 | **Can notify** | `coding challenge`, `take home assignment`, `hackerrank` |
| Interview platform domain | 10 | **Can notify** | `hirevue.com`, `willo.video`, `micro1.ai`, `karat.io` |
| Scheduling / ambiguous | 4 | Review only | `interview with`, `your availability`, `calendly.com`, `next steps` |
| Recruiter / acknowledgements | 3 | Score only | `your application`, `thank you for applying`, `job opportunity` |
| Job context | 1 | Score only | `hiring`, `resume`, `salary`, `position` |
| Hiring platform domain | 3 | Score only | `greenhouse.io`, `lever.co`, `rozee.pk` |

### The three verdicts

**Flagged** — listed *and* notified. Requires either:

- one **Can notify** phrase, or
- two separate **Review only** phrases *plus* job wording somewhere in the mail,

and a total score of at least the **notify threshold** (default 10).

**Needs review** — listed under its own chip, never notified. Weaker evidence
than the above but score ≥ **review threshold** (default 4). This tier exists so
a vaguely worded real invitation is never silently dropped.

**Ignored** — everything else, including all recruiter acknowledgements. Visible
only via the *Show everything* switch.

### Two-signal promotion

One ambiguous signal is noise; two independent ones in a mail that is
demonstrably about employment is a pattern.

- `"Interview with Acme Corp"` + a Calendly link + `position` → **flagged**
  (two ambiguous signals, plus job wording)
- `"Please confirm your availability"` + a Calendly link, no job wording →
  **needs review** (the dentist case)
- `"Read our interview with the CEO"` in a newsletter → **needs review**
  (one ambiguous signal only)

### Deliberate omissions

`interview` on its own is **not** a phrase — it appears in newsletters, podcasts
and rejection mail. Constructions naming an actual event are listed instead.
Likewise bare `assessment` is only Review-tier, because "risk assessment" and
"self assessment" are common in unrelated mail.

Interview platforms are matched on the **sender domain**, not on body text,
because the product names are unsafe as phrases: `willo` is inside `willow`,
`karat` inside `karate`.

### Rejection veto

Any rejection phrase suppresses the mail — unless an *Offer* phrase also
matched, because offer mails routinely recap the process ("we interviewed other
candidates but would like to offer you the role").

Every rejection phrase is deliberately multi-word. A single word like
"unfortunately" also appears in reschedule mails and would suppress a real
interview.

### Tuning

Everything above is editable in **Settings → Detection rules**, including each
group's tier via its **Authority** dropdown. Each edit immediately rescores the
cached mail, so the effect is visible without waiting for the next poll.

- **Missing mail you wanted?** Check the *Needs review* chip first — it usually
  landed there. Add its exact wording to the Interview or Offer group to have it
  notified in future.
- **Too much noise?** Raise the notify threshold, or add the sender under
  **Muted senders** (LinkedIn/Indeed job-alert digests are the usual culprits).
- **Want recruiter outreach back?** Set the Recruiter group's Authority to
  *Can notify*.

Manually marking a message pins the decision — later rule changes leave it
alone.

---

## Layout

```
lib/
  models/
    mail_item.dart          MailItem + MailCategory, DB row mapping, Gmail deep link
    rule_set.dart           Rule groups, weights, and the shipped defaults
  services/
    classifier.dart         The scoring engine. Pure Dart, fully unit-tested.
    imap_service.dart       enough_mail wrapper: connect, fetch newest N, HTML strip
    credentials_store.dart  App Password in the Android Keystore
    settings_store.dart     SharedPreferences; reloads on every read (two isolates)
    mail_database.dart      sqflite cache, notified/archived flags, pruning
    notification_service.dart  Channel setup + posting; works in either isolate
    sync_service.dart       fetch -> classify -> store -> notify. Isolate-agnostic.
    background.dart         WorkManager entry point and scheduling
  state/app_state.dart      ChangeNotifier the UI listens to
  ui/                       login, list, detail (with the audit trail), settings, rules editor
test/
  classifier_test.dart      Notify/review/ignore tiers, two-signal promotion, vetoes, serialisation
  mail_item_test.dart       DB round trip, notification-id range, deep-link building
```

`sync_service.dart` touches no Flutter widgets. That is what lets the identical
code path run for both pull-to-refresh and the background poll.

---

## Known limitations

These are properties of the chosen design, not bugs.

- **Notification delay is up to ~15–30 minutes.** Android's WorkManager floor is
  15 minutes and it batches jobs across apps. Real-time delivery requires the
  Gmail Pub/Sub → FCM path, which needs a Google Cloud project with billing, a
  backend, and OAuth instead of an App Password.
- **OEM battery managers can still skip runs** even with the exemption set.
- **Large messages are fetched as headers only** (128 KB limit) to keep mobile
  data down, so only their subject is scored.
- **INBOX only.** Mail that a Gmail filter has already routed to a label and out
  of the inbox is not seen.
- **Rules are keyword-based**, so unusual or non-English phrasing can slip
  through. Add the wording under Settings → Detection rules when it does.
- **The engine is tuned for precision, so some genuine mail will land in *Needs
  review* rather than notifying.** An invitation phrased purely as "Can you send
  me some times to chat?" has no decisive wording and no second signal. Check
  that chip periodically — it is the deliberate safety net, not a bug. Nothing
  is ever silently discarded: the *Show everything* switch reveals even ignored
  mail and rejections.
- **Recruiter mail and application acknowledgements are ignored by default**,
  per the configured behaviour. Flip the Recruiter group's Authority to *Can
  notify* to change that.
- Foreground syncs mark mail as notified without buzzing — you are already
  looking at the list.

---

## Commands

```powershell
flutter analyze              # must report: No issues found
flutter test                 # 63 tests
flutter run
flutter build apk --release
```

### Verifying the background path

**Settings → Run a background sync now** queues a real WorkManager job, so it
exercises the same code that runs when the app is closed — not a foreground
shortcut. Android still decides when it runs.

**Settings → Send a test notification** checks only that notifications are
permitted and the channel exists.

```powershell
adb logcat -s WM-WorkerWrapper flutter    # watch the worker actually fire
```

---

## Pinned dependency

`flutter_secure_storage` is pinned to exactly `10.0.0`. Version `11.0.0` sets
android `compileSdk = 37`, which AGP 8.11.1 (bundled with Flutter 3.38.5) cannot
resolve — the Android SDK installs that platform as `android-37.0` while AGP
looks for `android-37`, and the build fails with `Failed to find target with
hash string 'android-37'`. The Dart API of both versions is identical. Unpin once
the bundled AGP understands versioned platform directories.
