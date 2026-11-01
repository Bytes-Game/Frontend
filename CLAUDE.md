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
be done by then. Do not bring it up before they ask. Keep it up to date:
anything new that needs the owner (an account, a key, a setting) goes here
the day it is added.

### A. The app's identity

1. **Change the Android app id.** It is still the template's
   `com.example.devf` (`android/app/build.gradle.kts`, `applicationId` and
   `namespace`). Google Play refuses any app whose id starts with
   `com.example`, and the id can never change after the first upload, so pick
   it carefully (for example `com.<yourname>.flex`). The iPhone id is the same
   default (`PRODUCT_BUNDLE_IDENTIFIER` in `ios/Runner.xcodeproj`).
   Several things are tied to the id, so after changing it:
   - Push notifications: register the new id as an app in Firebase and use
     its new `FIREBASE_APP_ID`, or notifications stop.
   - Google sign-in: the Android OAuth client (item 9) is made for the id.
   - Apple sign-in: the iPhone id goes in `APPLE_CLIENT_IDS` (item 6), and
     the Android id in `ANDROID_PACKAGE_NAME` on Render (item 6).
2. **Make the release signing key.** Without it, release builds are signed
   with Flutter's shared debug key, and Google Play refuses those. The steps
   are in the comment at the top of `android/app/build.gradle.kts`: make the
   key once, write `android/key.properties`, keep both safe and out of git.
   Losing the key means the app can never be updated on Play. Its SHA-1
   fingerprint is needed for Google sign-in (item 9).
3. **Version number.** `version:` in `pubspec.yaml` (now `1.0.0+1`). The
   number after `+` must go up for every upload to the stores. The part
   before it is also `appVersion` in `lib/config/constants.dart` (shown in
   About and Settings); a test fails if the two disagree.
4. **The name in the stores.** Other apps are called Flex. The stores may
   want a longer listing name, for example "Flex: Video Battles". The name
   under the icon can stay Flex.

### B. Settings on Render (the server)

5. **Email, for "Forgot password?".** Set `SMTP_HOST`, `SMTP_PORT`,
   `SMTP_USERNAME`, `SMTP_PASSWORD` and `MAIL_FROM` (any email service:
   Brevo, Resend, a Gmail app password). Without them no reset code is ever
   sent, and the app tells people to email support instead.
6. **Google and Apple sign-in, the server's half.**
   - `GOOGLE_CLIENT_IDS`: the Web and iOS OAuth client ids from item 9,
     separated by a comma.
   - `APPLE_CLIENT_IDS`: the iPhone app id and the Apple Services ID from
     item 10, separated by a comma.
   - `ANDROID_PACKAGE_NAME`: the new Android id from item 1 (Apple sign-in
     on Android comes back to the app through it).
   Without them, those buttons say "isn't set up yet".
7. **Deploy the server first.** Before, or together with, the app build
   that needs it.
8. **After the store listing exists:** set `APP_DOWNLOAD_URL` to the store
   link, so the shared profile and video web pages show a "Get Flex" button.

### C. Google and Apple accounts

9. **Google Cloud** (the same project as Firebase) → APIs & Services:
   - the OAuth consent screen: app name Flex, the support email, the logo;
   - three OAuth client ids: **Web** (goes to `GOOGLE_SERVER_CLIENT_ID` in
     the build and `GOOGLE_CLIENT_IDS` on Render), **Android** (the new app
     id, and the SHA-1 of the release key from item 2, plus Google Play's
     app-signing key SHA-1 once Play signs the app), and **iOS** (the new
     iPhone id; goes to `GOOGLE_IOS_CLIENT_ID` and `GOOGLE_CLIENT_IDS`).
   - Put the iOS client id, reversed (`com.googleusercontent.apps.<the
     part before .apps.googleusercontent.com>`), in
     `GOOGLE_REVERSED_CLIENT_ID` in `ios/Flutter/Release.xcconfig` and
     `Debug.xcconfig`.
10. **Apple Developer** (needs the paid account):
    - turn on "Sign in with Apple" for the iPhone app id. The app already
      asks for it (`ios/Runner/Runner.entitlements`), so an iPhone build
      will not sign until this is on;
    - for Apple sign-in on Android: make a **Services ID**, switch on Sign
      in with Apple for it, add the server's domain and the return address
      `https://<the server>/auth/apple/callback`. The Services ID goes to
      `APPLE_SERVICE_ID` in the build and `APPLE_CLIENT_IDS` on Render.
    - The App Store requires Sign in with Apple on iPhone when Google
      sign-in is offered, so iPhone builds with Google need Apple too.
11. **iPhone push notifications.** In Xcode, Signing & Capabilities: add
    Push Notifications (the app has no permission for them yet), and upload
    an APNs key to Firebase (Project settings → Cloud Messaging). Without
    both, iPhones get no notifications.

### D. Build settings

12. **Build with the real settings.** The release build needs these passed
    as `--dart-define`s:
    - `FIREBASE_API_KEY`, `FIREBASE_APP_ID`, `FIREBASE_IOS_APP_ID`,
      `FIREBASE_PROJECT_ID`, `FIREBASE_SENDER_ID` (or push notifications are
      off);
    - `SENTRY_DSN` (or crash reports go nowhere);
    - `GOOGLE_SERVER_CLIENT_ID`, and on iPhone `GOOGLE_IOS_CLIENT_ID` (or no
      Google button);
    - `APPLE_SIGN_IN=true` on iPhone, and `APPLE_SERVICE_ID` on Android (or
      no Apple button).
    `API_BASE_URL` and `WS_BASE_URL` default to the Render server.
13. **Optional, once there is a website:** build with
    `--dart-define=SHARE_BASE_URL=https://<the site>` so shared links and QR
    codes use it instead of the Render address.

### E. Emails and pages the stores ask for

14. **Help and privacy emails.** The Help Center, the Terms, the Privacy
    Policy, the two-step code screen and "Forgot password?" (when email
    can't be sent) give support@devf.app and privacy@devf.app. They live in
    one place each: `supportEmail` and `privacyEmail` in
    `lib/config/constants.dart`, and `supportEmail` in the server's
    `mailer.go`. Make sure that domain is owned and those inboxes work, or
    change the addresses in both.
15. **The privacy policy at a web address.** Both stores ask for a link to
    it, and the policy is only inside the app today. Publish it on a website,
    or ask for it to be served by the server.
16. **A web address for deleting an account.** Google Play asks for a page
    where people can ask to delete their account without the app. The app
    can delete accounts already; the page does not exist yet. Ask for one,
    or give the support email with the steps.

Not on this list on purpose: the admin password. The owner has said they
will change it themselves and does not want reminding.
