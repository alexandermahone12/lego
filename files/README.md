# Brick Souq — iOS

SwiftUI marketplace for secondhand LEGO® in Qatar. Sign in with Apple, listings with
condition and completeness grading, WhatsApp handoff for contact. No in-app payments.

**Status: listings are real.** There is a server in `server/` — listings persist, are
shared across devices, and Apple identity tokens are verified server-side. Start it with
`npm start` from `server/` and run the app; there is nothing else to configure for the
simulator.

**Still not submittable.** See "Before you submit" below. The backend is done; the
catalog and the App Store paperwork are not.

---

## Getting it running

1. Xcode 15+, iOS 17 deployment target.
2. **File → New → Project → iOS → App.** Product name `BrickSouq`, interface SwiftUI,
   language Swift. This generates the `.xcodeproj` — I can't create one from here, it's a
   binary-ish format Xcode owns.
3. Delete the generated `ContentView.swift` and `BrickSouqApp.swift`.
4. Drag the `BrickSouq/` folder from this bundle into the project navigator.
   Check **Copy items if needed** and **Create groups**.
5. **Target → Signing & Capabilities → + Capability → Sign in with Apple.**
   This is what makes `BrickSouq.entitlements` take effect. Without it the button
   renders but the authorization always fails.
6. Merge the keys from `App/Info-additions.plist` into your target's Info.plist.
7. Build and run. Sign in with Apple works on a real device; on the simulator you need
   to be signed into an Apple Account in Settings first.

---

## Architecture

```
App/          entry point, entitlements, Info.plist keys
server/       the listings backend — Node, SQLite, no dependencies
Design/       colour and type tokens, StudMeter, shared chrome
Models/       Listing, User, Condition, BrickSet, Report + catalog and dev data
Services/     AuthManager (Sign in with Apple), BackendClient (protocol + mock),
              HTTPBackend (the real client)
Moderation/   content filter, report sheet, EULA gate, block list
Photos/       picker, on-device downscaling, gallery and carousel
Views/        Browse, Detail, Sell, Wanted, Profile
```

Everything server-side sits behind the `Backend` protocol in `BackendClient.swift`.
`HTTPBackend` talks to the server in `server/`; `MockBackend` keeps data in memory for
working on the UI with nothing running. Switching between them is one line in
`BackendClient.shared` and no view code changes — which was the point of the protocol.

---

## What's real vs. stubbed

| Working now | Stubbed |
|---|---|
| Sign in with Apple, nonce, Keychain, credential-state check on launch | A CDN in front of photos — they're served straight off the disk |
| Apple token verification against Apple's public keys, server-side | Push notifications for wanted-list matches (the matching query exists, APNs doesn't) |
| Persistence — listings survive app kill and are shared across devices | TLS — the dev server speaks plain HTTP |
| Photo upload, downscaled on device, 1–3 per listing (2 for built sets) | |
| Browse, search ranking, theme and condition filters, run in SQL | The human who works the moderation queue |
| Sell flow with catalog lookup and price suggestion | The profanity word lists, which ship empty |
| WhatsApp deep link with prefilled message | The other ~20,000 sets |
| Report, block, EULA gate, content filter enforced on the server | |
| Moderation queue with approve / remove / resolve | |
| Account deletion, including Apple token revocation | |
| 31-set catalog | |

---

## Before you submit

### 1. A backend — done, see `server/`

This was the biggest job and it is built. `server/README.md` has the detail; briefly:

- ✅ Apple identity tokens verified **server-side** against Apple's public keys, with
  the nonce checked. Verifying on-device is not verification — anyone can forge a token
  and sign in as anyone.
- ✅ Listings table with indexes on theme, type, condition and `createdAt`.
- ✅ A moderation queue with approve / remove / resolve.
- ✅ Account deletion that also calls Apple's **token revocation endpoint** — set the
  three `APPLE_*` variables in `server/.env` to switch it on. Deleting your own database
  row is not enough and reviewers check.
- ✅ Photo upload. Phones downscale to ~1600px before sending, so full-resolution
  photos never touch your bandwidth bill or the scroll performance, and the server needs
  no image library. Photos live on the same volume as the database.
- ⚠️ **TLS and a real host.** The dev server speaks plain HTTP, which is fine on your
  Wi-Fi and unacceptable in public.

### 2. The real set catalog

The bundled 31 sets are for development. Search is worthless without the full catalog —
someone looks for "ninjago dragon", finds nothing, decides the app is broken.

**Rebrickable's API** is the practical choice: complete set data with images, free tier,
terms that permit this. BrickLink's catalog is richer but owned by the LEGO Group — read
their terms before building on it.

Ship a pre-built SQLite file in the bundle so search is instant and works offline, then
refresh monthly from your server. Do not call a third-party API on every keystroke.

### 3. Guideline 1.2 — user-generated content

**This is the most common rejection for apps like yours, and people usually hit it after
building everything else.** Apple requires all of:

- ✅ EULA with an explicit zero-tolerance clause, accepted before posting → `TermsGate`
- ✅ Filtering that **refuses to publish** objectionable content → `ContentFilter`
- ✅ Report control on every listing → `ReportSheet`
- ✅ Block control on every user → `BlockList`
- ✅ Published contact info reachable in-app → Profile screen
- ⚠️ **Action on reports within 24 hours** — a human commitment, not code. Decide who
  does this before you launch. Reports land in `GET /v1/admin/queue` and log a line
  marked `[REPORT]`; someone has to be watching it.

The filter's word lists are empty stubs in both places. Populate the one in
`server/lib/moderation.js` — that is the one that is enforced, since anyone can talk to
the API with curl — and **include Arabic terms**. An English-only filter on a Qatar app
is not a filter. Keeping the list on the server is what lets you update it without
shipping a build.

In your App Review notes, tell the reviewer exactly where each control is
("Report: open any listing, scroll to the bottom"). Reviewers reject when they can't find
the controls, not only when they're missing.

### 4. Trademark — the one that could sink the name

**You cannot use "LEGO" in your app name, subtitle, keywords, icon, or screenshots.**
The LEGO Group enforces this actively, and Guideline 4.1 prohibits using another
developer's brand in metadata without permission.

What's fine: "Brick Souq" as the name, and *factual* references in the description like
"a marketplace for secondhand LEGO® sets" with the ® and an attribution line. What gets
you rejected or a legal letter: "LEGO Marketplace Qatar" as the title, or LEGO in your
keyword field.

Put this in the description footer:
> LEGO® is a trademark of the LEGO Group, which does not sponsor, authorise or endorse this app.

Consider having a Qatari lawyer glance at this before launch. It's an hour of their time
against the risk of rebranding after you've built an audience.

### 5. The rest of the checklist

- **Apple Developer Program** — USD 99/year. Individual enrolment is fast; organisation
  enrolment needs a D-U-N-S number and takes weeks. Start this now, not at submission.
- **Privacy policy and terms** hosted at real URLs. The links in `SignInView` and
  `ProfileView` are placeholders and will fail review as-is.
- **App Privacy nutrition labels** in App Store Connect. You collect email, name, phone,
  and user content — declare all four.
- **Age rating questionnaire.** UGC apps need age-restriction handling under 1.2.1.
- **Demo account credentials** in the review notes. Reviewers must be able to see
  listings without going through Apple Sign-In friction.
- **No in-app purchase needed.** Physical goods sold off-platform are exempt from IAP
  under 3.1.1 — worth saying so in your review notes so nobody wonders.
- **Qatar business registration.** Not needed to *publish* a free app, but the moment you
  charge for anything, you'll need a commercial registration through MOCI.

---

## Realistic timeline

Solo developer who already knows Swift, working evenings: **4–8 weeks** to a submittable
build now that the backend exists. Most of what is left is the catalog, photo upload and
the App Store paperwork, not the UI. Add 1–3 weeks for review rounds — first submissions for UGC marketplaces are rejected more often than not, and
that's normal rather than a sign of trouble.

If you don't write Swift, this codebase is still useful: it's a precise brief for a
contractor, and precise briefs are what stop a QAR 30,000 project becoming a QAR 80,000 one.

---

LEGO® is a trademark of the LEGO Group, which does not sponsor, authorise or endorse
this project.
