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
| Offer letter | 10 | **Can notify** | `offer letter`, `offer of employment`, `appointment letter`, `pleased to extend`, `your joining date` |
| Interview invitation | 10 | **Can notify** | `interview invitation`, `interview is scheduled`, `ai interview`, `one way interview`, `you have been shortlisted`, `hirevue` |
| Assessment or test | 10 | **Can notify** | `coding challenge`, `take home assignment`, `hackerrank` |
| Interview platform domain | 10 | **Can notify** | `hirevue.com`, `willo.video`, `micro1.ai`, `karat.io` |
| Ambiguous interview wording | 4 | Review only | `interview with`, `interview for`, `interview process`, `interviewer` |
| Scheduling wording | 4 | Review only | `your availability`, `calendly.com`, `next steps`, `quick call` |
| Recruiter outreach | 3 | **Recruiter list only** | `job opportunity`, `we are hiring`, `your application`, `thank you for applying` |
| Addressed to you | 2 | Score only | `your candidacy`, `you applied`, `we received your` |
| Job context | 1 | Score only | `hiring`, `resume`, `salary`, `position` |
| Job alerts and marketing | — | **Blocks notifications** | `job alert`, `jobs for you`, `apply now`, `webinar`, `off your first` |
| Hiring platform domain | 3 | Score only | `greenhouse.io`, `lever.co`, `rozee.pk` |

### The four verdicts

**Flagged** — listed *and* notified. Requires **decisive** wording, which means
one of:

- one **Can notify** phrase;
- mail from a video or AI interview platform, which is an interview task by
  definition; or
- ambiguous interview wording backed by *both* scheduling wording and job
  wording — `"Interview with Acme"` plus a Calendly link plus `position`;

plus a total score of at least the **notify threshold** (default 10), and no
veto (below).

**Needs review** — listed under its own chip, never notified. Suggestive but not
decisive, and score ≥ **review threshold** (default 4). This tier exists so a
vaguely worded real invitation is never silently dropped.

**Recruiter** — listed under its own chip, never notified, *whatever it scores*.
Cold outreach, "job opportunity" mail, application acknowledgements and job
digests. This is the tier that fixes the app's original failure mode: a
recruiter mail stacking `next steps` + `invite you to` + `job opportunity` used
to reach the notify threshold with no interview and no offer in it. A mail in
this class is now structurally incapable of notifying — no combination of
phrases can promote it.

**Ignored** — everything else. Visible only via *Show everything*.

### The three vetoes

1. **Rejection wording** suppresses the mail, unless an *Offer* phrase also
   matched.
2. **Job-alert and marketing wording** blocks the notification unless the
   decisive phrase is in the **subject line**, or the sender is an interview
   platform. Job boards paste whole job descriptions into their digests, so
   `technical interview` and `offer of employment` turn up in the body of mail
   addressed to nobody in particular.
3. **Recruiter wording with nothing decisive of its own** can only ever be
   filed under *Recruiter*.

Worked examples:

| Mail | Verdict |
| --- | --- |
| `"Interview invitation — Backend Engineer"` | **Flagged**, notified |
| `"Offer letter"` in the body of a mail titled `"Acme"` | **Flagged**, notified |
| `"Interview with Acme Corp"` + Calendly link + `position` | **Flagged**, notified |
| `"Exciting job opportunity at Acme — next steps, let me know your availability"` | **Recruiter**, never notified |
| `"Jobs for you: 12 new roles"` quoting `technical interview` in the body | **Recruiter**, never notified |
| `"Read our interview with the CEO"` in a newsletter | **Needs review** |
| `"Please confirm your availability"` + Calendly, no job wording | **Needs review** (the dentist case) |
| `"Special offer — 20% off your next purchase"` | **Ignored** |

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

- **Missing mail you wanted?** Check the *Needs review* and *Recruiter* chips
  first — it usually landed in one of them. Add its exact wording to the
  Interview or Offer group to have it notified in future, then use **Settings →
  Re-scan the inbox**.
- **Too much noise?** Raise the notify threshold, or add the sender under
  **Muted senders** (LinkedIn/Indeed job-alert digests are the usual culprits).
- **Want recruiter outreach to notify?** Set the Recruiter group's Authority to
  *Can notify*.

Manually marking a message pins the decision — later rule changes leave it
alone. Pinned rows show a 📌 in the list.

---

## How fetching works

The naive design — read the newest *N* messages every run and discard the ones
already stored — downloads tens of full messages every 15 minutes to discover,
almost always, that nothing has changed. At the default poll that is thousands
of redundant full-message downloads a day.

IMAP UIDs only ever increase within a mailbox, so the highest UID already
stored is a valid cursor. The app stores it alongside the mailbox's
`UIDVALIDITY`, because a UID means nothing across two incarnations of a
mailbox.

| Situation | Cost of the pass |
| --- | --- |
| `UIDNEXT` proves nothing arrived | one `SELECT`, no `FETCH` at all |
| New mail | `UID FETCH <cursor+1>:*` — only the new messages |
| First sync, or `UIDVALIDITY` changed | the newest *N* messages (Settings → *Messages read on a first sync*) |
| Cache empty but a cursor stored (schema rebuild) | treated as a first sync, so the list is never left blank |

Two details that matter:

- **`n:*` still returns the last message** even when its UID is below `n`, so
  the range is enforced again on the client.
- **The cursor moves only after the rows are committed.** A crash between the
  two would otherwise skip that mail permanently.

A backlog larger than 60 messages is worked through oldest-first over
consecutive runs, so a phone that was offline for a week never has to do it all
inside one 10-minute WorkManager slot.

### Large messages are no longer scored on the subject alone

HTML recruiting mail with an image signature routinely exceeds the initial
download limit, and mail fetched as envelope-only has no body for the rules to
read. That silently reduced real interview invitations to subject-line
scoring — and a subject like `"Acme Corp"` scores nothing.

Messages that arrive without text now get a second round trip that fetches
their **non-attachment parts only**, so a 20 MB mail with a PDF attached costs
a few kilobytes of text. That pass is capped at 15 messages per sync so a
mailbox full of newsletters cannot stall a background run.

---

## Layout

```
lib/
  models/
    mail_item.dart          MailItem, verdicts, categories, DB row mapping, Gmail deep link
    rule_set.dart           Rule groups, tiers, weights, and the shipped defaults
  services/
    classifier.dart         The scoring engine. Pure Dart, fully unit-tested.
    imap_service.dart       enough_mail wrapper: incremental UID fetch, body backfill, HTML strip
    credentials_store.dart  App Password in the Android Keystore
    settings_store.dart     SharedPreferences + the UID cursor; reloads on every read
    mail_database.dart      sqflite cache, notified/archived flags, search, pruning
    notification_service.dart  Two channels, tap routing; works in either isolate
    sync_service.dart       fetch -> classify -> store -> notify. Isolate-agnostic.
    background.dart         WorkManager entry point and scheduling
  state/app_state.dart      ChangeNotifier the UI listens to
  ui/
    theme.dart              Both themes, built from one seed
    category_style.dart     Per-category colour and icon, with a dark-mode tone
    home_screen.dart        Search, filter chips, date-grouped list, swipe actions
    mail_detail_screen.dart One message plus the audit trail
    login_screen.dart       App Password sign-in
    settings_screen.dart    Account, notifications, sync, detection, danger zone
    rules_editor_screen.dart  Every phrase list and tier, editable
test/
  classifier_test.dart      Verdict tiers, promotion, all three vetoes, serialisation
  html_strip_test.dart      HTML-only mail survives the strip step
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
- **A message whose text-part backfill fails stays subject-only.** The detail
  screen says so explicitly rather than showing an empty body.
- **INBOX only.** Mail that a Gmail filter has already routed to a label and out
  of the inbox — or into Spam — is not seen.
- **Rules are keyword-based**, so unusual or non-English phrasing can slip
  through. Add the wording under Settings → Detection rules when it does.
- **The engine is tuned for precision, so some genuine mail will land in *Needs
  review* rather than notifying.** An invitation phrased purely as "Can you send
  me some times to chat?" has no decisive wording and no second signal. Check
  that chip periodically — it is the deliberate safety net, not a bug. Nothing
  is ever silently discarded: the *Show everything* switch reveals even ignored
  mail and rejections.
- **Recruiter mail and application acknowledgements never notify.** They are
  listed under the *Recruiter* chip. Flip that group's Authority to *Can notify*
  if you want them to buzz.
- Foreground syncs mark mail as notified without buzzing — you are already
  looking at the list.

---

## Commands

```powershell
flutter analyze              # must report: No issues found
flutter test                 # 77 tests
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
