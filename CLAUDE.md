# Working with this repo

## How to talk to me

**Always explain in easy, plain language.** This is the most important rule here
and it applies to every single answer, not just the ones that look complicated.

- No jargon. If a technical term is unavoidable, say what it means in the same
  breath, in normal words.
- Short sentences. Short paragraphs.
- Lead with the plain-English answer. The code details come after, and only if
  they are actually needed.
- Explain things the way you would to a smart person who does not already know
  this codebase.
- Do not hide behind class names, method names, and log lines. Say what is
  actually happening and why the user would notice it.

Bad: "The `pauseAllExcept` future never resolves because the platform channel
reply is dropped when the codec is reclaimed."

Good: "The app waits for the old video to stop before starting the new one.
Sometimes the old video never reports back that it stopped, so the app waits
forever and the new video never starts."

Same rule for commit messages, PR descriptions, and code comments: plain and
direct.

## When I send you a log

**Read the whole thing. All of it.**

Not the lines you expect to matter. Not a grep for the words you already have
a theory about. The whole file, and a count of what is actually in it.

This is not a style preference, it is the difference between finding the bug
and not finding it. A real example from this repo:

A log was 43,000 lines. The app's own diagnostic summary was 13 of them. Those
13 lines were read, for several rounds, and produced several fixes that each
made sense and none of which fixed the problem — because the cause was in the
other 42,987 lines, which nobody had counted.

What those lines said, once counted:

    57 video decoders    2,661 frames rendered    0 frames dropped

A decoder only drops frames when it cannot keep up. Zero dropped means it was
never behind — it was always WAITING for video that had not arrived. Every fix
so far had been about which file to download. None of them could have helped.

So, before forming any theory:

- Count what kinds of lines are in the file, and how many of each. The biggest
  group is often not the one you were looking at.
- Read the error lines, even the ones from Android or the decoder that look
  like noise. Three thousand of them is not noise.
- Look for the numbers that CONTRADICT the theory, not the ones that fit it.

And never answer "I cannot find it" or "I have no fix I can defend". If the
evidence is not in the log, add a log line and say what the next run should
show. Silent failure paths are bugs in their own right — `catch (_) { return; }`
hid a whole page failing for two rounds of diagnosis.

## Before you say something works

Two rules, both learned the expensive way in this repo.

### Cut the wire and run the tests

The most common bug here, hit five times now, is **a thing that works that
nothing calls**. A decoder probe with no caller. A measured budget worked out
at startup and never passed on. A link meter nothing fed. A stand-down counter
nothing wired up. Columns on a table nothing ever wrote to.

Every one of them had tests. Every one passed. Because each test called the far
end **by hand**, so it never went through the missing wire.

So before claiming something works: **delete the call and run the tests.** If
nothing goes red, the test is not testing what you think it is.

This is not optional polish. It is the only check that catches this, and it
takes a minute.

### A test that matches its own comment checks nothing

Two tests here searched the source for the words in the comment explaining a
trap, not for the code that avoids it. They passed against code with the trap
wide open.

If a test reads the source, strip the comment lines first.

And watch for the reverse shape: a widget test that asserts something renders
**nothing** will still pass if you break it so it renders nothing **forever**.
When every test checks for absence, one of them has to check for presence.

## Before release: what the owner still has to do

**When the owner says they are about to release, give them this list,** in
plain words, and check each item against the code first — some may already
be done by then. Do not bring it up before they ask.

1. **Change the Android app id.** It is still the template's
   `com.example.devf` (`android/app/build.gradle.kts`, `applicationId` and
   `namespace`). Google Play refuses any app whose id starts with
   `com.example`, and the id can never change after the first upload, so pick
   it carefully (for example `com.<yourname>.devf`). The iPhone id is the same
   default (`PRODUCT_BUNDLE_IDENTIFIER` in `ios/Runner.xcodeproj`).
   - Push notifications are tied to the id: register the new id as an app in
     Firebase and use its new `FIREBASE_APP_ID`, or notifications stop.
2. **Make the release signing key.** Without it, release builds are signed
   with Flutter's shared debug key, and Google Play refuses those. The steps
   are in the comment at the top of `android/app/build.gradle.kts`: make the
   key once, write `android/key.properties`, keep both safe and out of git.
   Losing the key means the app can never be updated on Play.
3. **Help and privacy emails.** The Help Center, the Terms, the Privacy
   Policy and "Forgot password?" (when email can't be sent) give
   support@devf.app and privacy@devf.app. They live in one place each:
   `supportEmail` and `privacyEmail` in `lib/config/constants.dart`, and
   `supportEmail` in the server's `mailer.go`. Make sure that domain is
   owned and those inboxes work, or change the addresses in both.
   - **Email for "Forgot password?"**: set `SMTP_HOST`, `SMTP_PORT`,
     `SMTP_USERNAME`, `SMTP_PASSWORD` and `MAIL_FROM` on Render (any email
     service: Brevo, Resend, a Gmail app password). Without them the reset
     code is never sent, and the app tells people to email support
     instead.
4. **Build with the real settings.** The release build needs these passed as
   `--dart-define`s: `FIREBASE_API_KEY`, `FIREBASE_APP_ID`,
   `FIREBASE_IOS_APP_ID`, `FIREBASE_PROJECT_ID`, `FIREBASE_SENDER_ID` (or push
   notifications are off), and `SENTRY_DSN` (or crash reports go nowhere).
   `API_BASE_URL` and `WS_BASE_URL` default to the Render server.
5. **Version number.** `version:` in `pubspec.yaml` (now `1.0.0+1`). The
   number after `+` must go up for every upload to the stores. The part
   before it is also `appVersion` in `lib/config/constants.dart` (shown in
   About and Settings); a test fails if the two disagree.
6. **Put the server live first.** Deploy the server before, or together
   with, the app build that needs it.
7. **After the store listing exists:** set `APP_DOWNLOAD_URL` on Render to
   the store link, so the shared profile and video web pages show a
   "Get devf" button.
8. **Optional, once there is a website:** build with
   `--dart-define=SHARE_BASE_URL=https://<the site>` so shared links and QR
   codes use it instead of the Render address.

Not on this list on purpose: the admin password. The owner has said they
will change it themselves and does not want reminding.
