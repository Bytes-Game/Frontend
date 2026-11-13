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
   it carefully. The usual choice is your web address backwards:
   `com.flexete.app`, since you own flexete.com. The iPhone id is the same
   default (`PRODUCT_BUNDLE_IDENTIFIER` in `ios/Runner.xcodeproj`).
   Several things are tied to the id, so after changing it:
   - Push notifications: register the new id as an app in Firebase and use
     its new `FIREBASE_APP_ID`, or notifications stop.
   - Google sign-in: the Android OAuth client (item 10) is made for the id.
   - Apple sign-in: the iPhone id goes in `APPLE_CLIENT_IDS` (item 6), and
     the Android id in `ANDROID_PACKAGE_NAME` on Render (item 6).
2. **Make the release signing key.** Without it, release builds are signed
   with Flutter's shared debug key, and Google Play refuses those. The steps
   are in the comment at the top of `android/app/build.gradle.kts`: make the
   key once, write `android/key.properties`, keep both safe and out of git.
   Losing the key means the app can never be updated on Play. Its SHA-1
   fingerprint is needed for Google sign-in (item 10).
3. **Version number.** `version:` in `pubspec.yaml` (now `1.0.0+1`). The
   number after `+` must go up for every upload to the stores. The part
   before it is also `appVersion` in `lib/config/constants.dart` (shown in
   About and Settings); a test fails if the two disagree.
4. **The name in the stores.** The app is called Flexete. The stores may
   want a longer listing name, for example "Flexete: Video Battles". The
   name under the icon stays Flexete.

### B. Settings on Render (the server)

5. **Email, for "Forgot password?" and for parents.** Two things need the
   server to send email: the code for a forgotten password, and the link
   a parent gets when somebody under 18 signs up (item 26). Without
   email, nobody under 18 can join at all. Render's free plan blocks the
   ports ordinary email goes out on (25, 465 and 587), so on it Gmail and
   every other SMTP service simply never answer. A phone log on 7 November
   showed exactly that: Gmail set up right, and the reset code failing
   after ten seconds. So:
   - **on the free plan, Resend** (resend.com, free for 100 emails a day).
     It works over the web, which the free plan allows. Add flexete.com
     under Domains, put the records it shows in Cloudflare (flexete.com →
     DNS → Records), and make an API key. On Render set `RESEND_API_KEY`
     and `MAIL_FROM=Flexete <no-reply@flexete.com>`. Resend's records go
     beside the Email Routing ones from item 15; leave those as they are.
   - **or, on a paid Render plan, any SMTP service:** `SMTP_HOST`,
     `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD` and `MAIL_FROM` (a Gmail
     app password works).
   When both are set, Resend is used. Without either, no reset code is
   ever sent, and the app tells people to email support instead. At every
   start the server says how email is set up and whether it can get out:
   Render → the service → Logs, the line starting `email:`.
6. **Google and Apple sign-in, the server's half.**
   - `GOOGLE_CLIENT_IDS`: the Web and iOS OAuth client ids from item 10,
     separated by a comma.
   - `APPLE_CLIENT_IDS`: the iPhone app id and the Apple Services ID from
     item 11, separated by a comma.
   - `ANDROID_PACKAGE_NAME`: the new Android id from item 1 (Apple sign-in
     on Android comes back to the app through it).
   Without them, those buttons say "isn't set up yet".
7. **Deploy the server first.** Before, or together with, the app build
   that needs it. This matters more than it used to: the app now sends
   its sign-in to the live connection in a new way, which only the new
   server understands. A new app talking to the old server still signs in
   and plays videos, but messages, notifications and calls do not arrive
   as they happen. (An older app keeps working with the new server.)
8. **After the store listing exists:** set `APP_DOWNLOAD_URL` to the store
   link, so the shared profile and video web pages show a "Get Flexete"
   button.
9. **Keep the server awake.** Render's free plan puts the server to sleep
   after about 15 minutes with nobody using it. The next person to open the
   app then waits 30 to 60 seconds while it wakes, and the feed can fail to
   load at all: a phone log on 2 November showed exactly that. The GitHub
   job meant to keep it awake (`keepalive.yml` in the server repo) asks for
   every 10 minutes but runs only every few hours, because GitHub drops most
   scheduled runs. Pick one:
   - free: an UptimeRobot monitor (type HTTP(s), address
     `https://gobackend-9nd8.onrender.com/health`, every 5 minutes). Render's
     free hours cover one server awake all month;
   - or a paid Render plan, which never sleeps ($7 a month, about ₹660:
     item 29). Then delete `keepalive.yml` and the monitor.
9a. **Check the database is not on a 30-day clock.** Render → the
    database (it is listed apart from the server). If its plan says
    "Free": Render switches a free database off 30 days after it was
    made, and 14 days after that deletes it with everything in it. A free
    one has no backups either. Before real people join, change its plan
    to the smallest paid one ($6 a month, about ₹565): the data stays. If
    the database is with somebody else (Neon, Supabase), read their free
    limits the same way. Read on Render's own page on 13 November 2026.
9b. **A sign-in for the store reviewers.** The App Store and Play
    reviewers need a sign-in to look around. Make them a normal account,
    with its own password, through the app's own sign-up, and give it an
    adult's date of birth so no parent is asked. There are no demo
    accounts any more: the first start of the new server deletes the old
    ones (`player1` and the rest) and everything they posted, and there is
    no "wipe everything" button and no `TEST_SERVER` setting. If
    `TEST_SERVER` is still set on Render, delete it; it does nothing.
9c. **Optional: `PUBLIC_BASE_URL`.** The address put in the links that are
    emailed to parents. On Render nothing needs setting: Render tells the
    server its own address. Once flexete.com points at the server (item
    18), set `PUBLIC_BASE_URL=https://flexete.com` so those links use it.
9d. **If the server ever leaves Render.** On Render nothing needs
    setting. On another host, read `TRUST_CF_CONNECTING_IP` in the
    server's README first. The limits on sign-in guesses, new accounts
    and emails to parents count per caller's address, and how the server
    learns that address differs from host to host. Set wrong, anybody can
    dodge those limits.

### C. Google and Apple accounts

10. **Google Cloud** (the same project as Firebase) → APIs & Services:
    - the OAuth consent screen: app name Flexete, the support email, the
      logo, and flexete.com as the app's home page;
    - three OAuth client ids: **Web** (goes to `GOOGLE_SERVER_CLIENT_ID` in
      the build and `GOOGLE_CLIENT_IDS` on Render), **Android** (the new app
      id, and the SHA-1 of the release key from item 2, plus Google Play's
      app-signing key SHA-1 once Play signs the app), and **iOS** (the new
      iPhone id; goes to `GOOGLE_IOS_CLIENT_ID` and `GOOGLE_CLIENT_IDS`).
    - Put the iOS client id, reversed (`com.googleusercontent.apps.<the
      part before .apps.googleusercontent.com>`), in
      `GOOGLE_REVERSED_CLIENT_ID` in `ios/Flutter/Release.xcconfig` and
      `Debug.xcconfig`.
11. **Apple Developer** (needs the paid account):
    - turn on "Sign in with Apple" for the iPhone app id. The app already
      asks for it (`ios/Runner/Runner.entitlements`), so an iPhone build
      will not sign until this is on;
    - for Apple sign-in on Android: make a **Services ID**, switch on Sign
      in with Apple for it, add the server's domain and the return address
      `https://<the server>/auth/apple/callback`. The Services ID goes to
      `APPLE_SERVICE_ID` in the build and `APPLE_CLIENT_IDS` on Render.
    - The App Store requires Sign in with Apple on iPhone when Google
      sign-in is offered, so iPhone builds with Google need Apple too.
12. **iPhone push notifications.** The project's half is done: the app
    asks for them and can be woken by one. Three steps are left, in three
    accounts:
    - Firebase: add an iOS app to the same project, with the iPhone app
      id from item 1. It gives two values for the build (item 13):
      `FIREBASE_IOS_APP_ID` and `FIREBASE_IOS_API_KEY`.
    - Apple Developer: switch on Push Notifications for the app id, and
      make an APNs key (Keys → +, tick Apple Push Notifications service).
    - Firebase again: upload that key (Project settings → Cloud Messaging
      → Apple app configuration), with its Key ID and your Team ID.
    Nothing in the project needs changing for the App Store: Xcode
    switches notifications from "development" to the live setting itself
    when it archives the app with automatic signing.
    Without all three steps, iPhones get no notifications.
12b. **The iPhone app has not been built or run in this work.** That
     needs a Mac, and there was none: everything for iPhone here was
     written without trying it. Expect a round of fixes at the first
     build. Check these first, and send the log if one fails: a video
     plays (the app plays videos through a small server of its own on
     the phone, which iPhones only allow because `Info.plist` says so);
     a notification arrives; Google and Apple sign-in come back to the
     app.

### D. Build settings

13. **Build with the real settings.** The release build needs these passed
    as `--dart-define`s:
    - `FIREBASE_API_KEY`, `FIREBASE_APP_ID`, `FIREBASE_PROJECT_ID`,
      `FIREBASE_SENDER_ID`, and on iPhone `FIREBASE_IOS_APP_ID` and
      `FIREBASE_IOS_API_KEY` (or push notifications are off);
    - `SENTRY_DSN` (or crash reports go nowhere);
    - `GOOGLE_SERVER_CLIENT_ID`, and on iPhone `GOOGLE_IOS_CLIENT_ID` (or no
      Google button);
    - `APPLE_SIGN_IN=true` on iPhone, and `APPLE_SERVICE_ID` on Android (or
      no Apple button).
    `API_BASE_URL` and `WS_BASE_URL` default to the Render server.
14. **Optional, once flexete.com shows the shared pages (item 18):** build
    with `--dart-define=SHARE_BASE_URL=https://flexete.com` so shared links
    and QR codes use it instead of the Render address. Or ask for it to
    become the default.

### E. Emails and pages the stores ask for

15. **Make the help, privacy and complaints inboxes work.** The Help
    Center, the Terms, the Privacy Policy, the report sheet, the two-step
    code screen and "Forgot password?" (when email can't be sent) give
    support@flexete.com, privacy@flexete.com and grievance@flexete.com.
    Nothing receives mail there until you turn it on. In Cloudflare:
    flexete.com → Email → Email Routing → add `support`, `privacy` and
    `grievance`, and forward all three to your own inbox (free, about five
    minutes; Cloudflare adds the records it needs). The addresses live in
    one place each: `supportEmail`, `privacyEmail` and `grievanceEmail` in
    `lib/config/constants.dart`, and `supportEmail` in the server's
    `mailer.go`.
16. **The web pages the stores ask for: done, on the server.** No sign-in
    needed: `/privacy`, `/terms`, `/community-guidelines`,
    `/delete-account` and `/child-safety`, at the server's address (today
    `https://gobackend-9nd8.onrender.com/privacy`; `https://flexete.com/
    privacy` once item 18 is done). Put those links in the store forms.
    The words are the app's own: change them in `lib/pages/legal_texts.dart`,
    then in the server repo run
    `python3 tools/legal_from_app.py ../Frontend/lib/pages/legal_texts.dart`
    and commit `legal/texts.json`, so the web pages say the same.
17. **Name the Grievance Officer.** India's IT Rules (2021) ask an app
    where people post to publish the name of a Grievance Officer and how
    to reach them. The documents give grievance@flexete.com and say "our
    Grievance Officer"; the name is empty. Put it in `grievanceOfficer` in
    `lib/config/constants.dart`, then run the tool in item 16 so the web
    pages say it too. It can be you.

### F. Your web address, flexete.com (on Cloudflare)

Leave auto-renew on for the domain: if it lapses, the help inboxes, the
shared links and everything below stop working.

18. **Point flexete.com at the server.** Optional, but worth doing before
    launch: the app then stops depending on Render's own address, so moving
    hosts later needs no app update, and shared links look like yours.
    - In Render: the service → Settings → Custom Domains → add
      `flexete.com` (and `api.flexete.com` if you want a separate address
      for the app). Render shows the target to point each one at.
    - In Cloudflare: flexete.com → DNS → Records → add a CNAME for each
      name, pointing at that target, with the proxy switched off ("DNS
      only", the grey cloud) so Render can make its security certificate.
    - Then ask for the app's server address and shared links to switch to
      it (items 14, 16, 17).
19. **Videos from your own address.** Optional, but it speeds videos up.
    The videos live in Cloudflare R2. If `R2_PUBLIC_BASE_URL` on Render is
    empty or a `pub-….r2.dev` address, they are served from R2's test
    address, which Cloudflare slows down and does not cache.
    - In Cloudflare: R2 → the bucket → Settings → Custom Domains → connect
      `media.flexete.com`.
    - On Render: set `R2_PUBLIC_BASE_URL=https://media.flexete.com`. The
      server hands it to the video workers with every job. If the GitHub
      secret of the same name is set (hls-worker), make it match or delete
      it.
    - New videos then load from Cloudflare's cache near each viewer. Old
      videos keep their old address, which still works; moving them over
      needs a small server change, so ask. Checked on 12 November: the
      live server still hands out the `pub-….r2.dev` address, so no video
      is cached yet. Do this before launch and every video ever posted is
      on the fast address from the start.

### G. Running it once people use it

20. **Read the reports.** People can now report videos, accounts and
    comments (More ⋯ → Report; press and hold a comment). Each waits on
    `https://<the server>/admin/reports`, behind the admin sign-in, oldest
    first, with anything urgent (a child at risk, nudity, pretending to be
    someone, self-harm, violence) on top. Each has: "Nothing wrong",
    "Remove", "Suspend" and "Remove + suspend"; a suspended account is
    signed out, cannot sign in, and is hidden everywhere until you press
    "Unsuspend" in the list below. India's rules: answer a complaint within
    24 hours, settle it within 15 days, and take down nudity or
    impersonation within 24 hours of the person's complaint. Child sexual
    abuse material must also be reported to the police or
    cybercrime.gov.in. Look every day.
21. **The Play Console forms.** They are answered by hand, in the Play
    Console, and must match what the app does:
    - Data safety: the app collects name, username, email, birth date,
      photos and videos people post, what they watch and like, messages,
      the phone's push-notification address, and crash reports (Sentry,
      without personal details). Nothing is sold; nothing is used for ads.
      Account deletion link: `/delete-account` (item 16).
    - Child safety standards: link `/child-safety` (item 16), contact
      support@flexete.com.
    - Content rating questionnaire: people share videos and talk to each
      other; content is moderated and can be reported.
    - Target audience: 13 and over. The Terms say 13+, 16+ in Australia,
      Brazil, Indonesia and Malaysia, and a parent's permission under 18.
    - Countries: choose where the app is offered (Play Console →
      Production → Countries/regions). Start with India only (item 27).
    - Photo and video permissions: the app reads the phone's photos and
      videos to pick one to post (its own gallery screen), so it needs the
      declaration for READ_MEDIA_IMAGES / READ_MEDIA_VIDEO.
    - App access: the reviewers' sign-in from item 9b.
    - Data safety, added on 12 November: the app also uses the country
      the phone is in (approximate location: country only), and for
      people under 18 keeps a parent's email, name and year of birth.
    App Store Connect asks the same in App Privacy, and for an age rating.
22. **Make both GitHub repositories private.** Both are public today:
    anyone can read the server's code and the app's. No password or
    private key is in either (checked, history included: the server's keys
    live only on Render), but there is no reason to show the code. GitHub → each repository →
    Settings → General → Danger Zone → Change visibility. GitHub Actions
    keeps working; the free plan gives private repositories 2,000 minutes
    a month, which the video worker can use up — so either move the worker
    to its own machine (item 23) or watch the minutes.
23. **Optional: the video worker always on.** Today it runs as a GitHub
    job, started when a video is posted and every 30 minutes, which spends
    a minute or two setting up each time. `cmd/hls-worker/Dockerfile` in
    the server repo is the same worker as a container that never stops:
    put it on a machine with at least 8 GB of memory and 4 cores (the two
    AI models need it), with the settings listed at the top of that file.
    Then switch off the GitHub job's schedule.
24. **Ask a lawyer about keeping deleted accounts.** India's IT Rules also
    say an app must keep a deleted account's registration details for 180
    days. Flexete deletes everything 30 days after the person asks. The
    privacy policy says some records may be kept where the law requires;
    whether to keep them, and how, is a legal decision.
25. **Restrict the Firebase key.** The app carries a Firebase key
    (`lib/services/push_service.dart`) for push notifications. Every app's
    is readable inside the app, so it is not a secret, but without limits
    anyone can use it against your Firebase project's allowance. Google
    Cloud → APIs & Services → Credentials → that key → Application
    restrictions: Android apps, the app id from item 1 and the release
    key's SHA-1 (item 2); API restrictions: only the Firebase APIs the app
    uses (Firebase Cloud Messaging and Firebase Installations). Do the
    same for the iPhone key with the iPhone id.

26. **Parents' permission: what is built, and what is not.** Somebody
    under 18 gets no account until a parent or guardian opens an emailed
    link and agrees; the parent can close the account at any time with a
    second link. This proves that an adult with their own email address
    said yes. It does not check an identity document. India's new data
    protection rules, expected to apply from about May 2027, ask for a
    stronger check for under-18s (for example through DigiLocker), and
    also forbid tracking what under-18s do, which may cover choosing
    videos from what they watch. Both are legal decisions: ask a lawyer
    before May 2027. The simple safe choices then are to make Flexete 18+
    in India, or to pay for an identity check and switch off the
    personal feed for under-18s. Either can be built when asked.
27. **Launch in India first.** Each country has its own rules for apps
    where people post, and they change often. The code holds everybody to
    one strict rule (13 to join, 16 in Australia, Brazil, Indonesia and
    Malaysia, a parent under 18), and the documents have a part for each
    region. That is care, not a lawyer's sign-off. Europe and the United
    Kingdom also expect a company outside them to name a representative
    there, which costs money. So offer the app in India only at first
    (item 21), and ask before opening another country: its age rule goes
    in the server's `age_rules.go` and in the documents the same day.
28. **Check the country is seen.** After the server is deployed, open
    `https://<the server>/signup/rules` in a browser. It should show your
    country and `"source":"network"`. If it shows `"source":"device"` or
    no country, the host is not passing the country on: say so, and it
    will be looked at.

### H. What it costs each month

The owner's limit is ₹2,000 a month for everything. The prices below
were read on each company's own page on 13 November 2026, at ₹94 to the
dollar. Read them again before relying on them: they change.

29. **The plan that fits.**
    - Render, the server, smallest paid plan: $7 (about ₹660). It never
      sleeps (item 9), and it may send email the ordinary way (item 5).
    - Render, the database, smallest paid plan: $6 (about ₹565). No
      30-day clock (item 9a).
    - Free at this size: Cloudflare R2 for the videos (the first 10 GB;
      after that about ₹1.40 for each GB kept for a month; people
      watching costs nothing, however many), Cloudflare for the web
      address and the three inboxes, Resend for email (100 a day),
      Firebase for notifications, Sentry for crash reports, and GitHub
      for the video worker while the repositories are public (item 22).
    - Together about ₹1,225 a month, plus what the bank adds for paying
      in dollars. The rest is room for videos past 10 GB.
    - Render's free allowance for data sent by the server is 5 GB a
      month, then $0.15 for each GB. Videos do not count: they come from
      Cloudflare.
    - Once only: the Google Play developer account, $25 (about ₹2,350).
      Once a year: the web address, about $10 (₹950).
    - Not in the plan: the Apple developer account, $99 a year (about
      ₹9,300, or ₹775 a month). With the two Render plans that is the
      whole ₹2,000 and leaves nothing for videos. Android first.
30. **A spending alert, so a flood of uploads is noticed.** Videos go
    from the phone straight to Cloudflare. Each person is limited in how
    many uploads they can start, but the server does not yet limit how
    big one upload is: that needs a change which could not be tried
    against the real storage, and getting it wrong would stop every
    upload. So somebody set on it could fill the storage and run up the
    bill. Until that limit is built, have Cloudflare tell you: Manage
    Account → Billing → Billable Usage → Create budget alert, at $1. An
    email then comes the day the month's bill passes it, which is about
    70 GB past the free 10. If it comes and you did not expect it, say
    so: the account is suspended from the admin page and its files
    removed. Ask for the size limit to be built once the release is out.

Not on this list on purpose: the admin password. The owner has said they
will change it themselves and does not want reminding.
