# Brick Souq — server

The listings backend. Everything the app posts now survives being killed, and is
visible from every device pointed at this server.

Zero dependencies: plain Node, SQLite via the built-in `node:sqlite`, HTTP via
`node:http`, Apple token verification via `node:crypto`. There is no `npm install`,
no build step and no account to sign up for.

---

## Run it

```bash
cd server
npm start
```

That is the whole setup. First run creates `data/bricksouq.db`.

To put the development listings in so Browse isn't empty:

```bash
npm run seed
```

Other commands:

| Command | What it does |
|---|---|
| `npm start` | Run the server |
| `npm run dev` | Run it with auto-restart on file changes |
| `npm run seed` | Add the six development listings if the database is empty |
| `npm run reset` | Delete the database and start over |

Requires **Node 22.5 or newer** (`node --version`) — that is when `node:sqlite`
arrived. If yours is older, install a current Node and nothing else changes.

---

## Point the app at it

Nothing to do for the simulator: `HTTPBackend` defaults to `http://localhost:8080`,
and the simulator's localhost is your Mac.

On a **real device** localhost is the phone, which has no server on it. Set the address
of your Mac on the same Wi-Fi:

```
Xcode → Edit Scheme → Run → Arguments → Environment Variables
BRICKSOUQ_SERVER_URL = http://192.168.1.42:8080
```

and add an App Transport Security exception, because iOS blocks plain HTTP to anything
that isn't loopback. In your target's Info settings add `NSAppTransportSecurity` →
`NSAllowsLocalNetworking = YES`. That exception is for development only; in production
you terminate TLS at a real hostname and this stops being an issue.

Check the server is reachable from the phone's browser first (`http://192.168.1.42:8080/v1/health`).
If that fails it is your Mac's firewall, not the app.

---

## What it does

**Listings persist.** Publishing writes a row; browsing reads rows. Sold, deleted,
held and blocked listings are filtered out in SQL, so they never reach the device.

**The server decides who you are.** `sellerID`, `sellerName`, `sellerTrades` and
`createdAt` come from the session, never from the request body. A client that tries to
publish as somebody else gets its own ID written anyway.

**Apple tokens are verified properly.** The signature is checked against Apple's
published keys, then `iss`, `aud`, `exp` and the nonce. This is the thing the app
README calls out: decoding a token and believing it is not verification, because the
payload is plain base64 that anybody can write. `test/apple.test.js` stands up a fake
Apple with a real RSA key and proves a forged token, a swapped key, an `alg:none`
downgrade, another app's token, an expired token and a replayed nonce are all refused.

**Content is screened before publishing, not after.** Guideline 1.2 asks for a method
of *refusing to publish* objectionable content. The app screens too, but the app is a
courtesy — anyone can talk to this API with curl, so the check that counts is here.
Counterfeit signals hold a listing for review; contact details in the description are
refused outright.

**Photos are stored on disk beside the database.** Upload is a raw image body rather
than multipart, which is one line on the Swift side and no parser here. The bytes are
sniffed for a real JPEG/PNG signature — `Content-Type` is whatever the client felt like
claiming, and an upload directory that serves back anything it is given is a real
problem. Filenames are UUIDs, so serving cannot be talked into reading arbitrary files.

Phones downscale to ~1600px and JPEG-compress before uploading, which is why there is no
image library here and why this stays dependency-free. A photo belongs to whoever
uploaded it and can only be attached to one listing; photos picked but never published
are swept after 24 hours, and deleting a listing or an account deletes its photos.

**Photo counts are a rule, not a suggestion.** One minimum, three maximum, and two
minimum for a Built set — one flattering angle of an assembled model hides exactly the
damage a buyer is asking about. The app checks first so a seller finds out early; the
server checks because the app is not a control. The numbers live in `PHOTO_RULES` in
`lib/moderation.js` and are published at `/v1/health`.

**Reports go to a queue a human can actually work.** `POST /v1/reports` writes a row
and logs a line marked `[REPORT]`. Apple expects action within 24 hours.

**Account deletion revokes with Apple.** Set the three `APPLE_*` variables and
`DELETE /v1/account` calls Apple's revoke endpoint as well as deleting the data.
Without them it deletes the data and logs a warning, which is fine while developing
and is a rejection when you submit.

---

## Endpoints

Everything is under `/v1`. Authenticate with `Authorization: Bearer <accessToken>`.

| | | |
|---|---|---|
| `GET` | `/health` | Liveness, and which optional features are on |
| `POST` | `/auth/apple` | Exchange an Apple identity token for a session |
| `POST` | `/auth/dev` | Development sign-in, no Apple round trip (see below) |
| `POST` | `/auth/refresh` | New session from a refresh token |
| `POST` | `/auth/signout` | Drop this session |
| `GET` | `/me` | The signed-in user |
| `PATCH` | `/me` | Update display name or WhatsApp number |
| `DELETE` | `/account` | Delete the account and revoke with Apple |
| `GET` | `/listings` | Browse. `?theme=&type=&condition=&query=&limit=&offset=` |
| `GET` | `/listings/mine` | Your own, including sold and held |
| `GET` | `/listings/:id` | One listing |
| `POST` | `/listings` | Publish (1–3 photos, 2 minimum when Built) |
| `POST` | `/photos` | Upload one JPEG or PNG as a raw body |
| `GET` | `/photos/:file` | Serve a stored photo |
| `POST` | `/listings/:id/sold` | Mark sold |
| `DELETE` | `/listings/:id` | Delete |
| `GET` `POST` | `/wanted` | Wanted list |
| `DELETE` | `/wanted/:id` | Remove an entry |
| `POST` | `/reports` | Report a listing |
| `GET` `POST` | `/blocks` | Blocked users |
| `DELETE` | `/blocks/:id` | Unblock |
| `GET` | `/admin/queue` | Open reports and held listings |
| `POST` | `/admin/listings/:id/approve` | Publish a held listing |
| `POST` | `/admin/listings/:id/remove` | Take a listing down |
| `POST` | `/admin/reports/:id/resolve` | Close a report |

The `/admin` routes authenticate with `ADMIN_TOKEN`, not a user session, and return
404 until you set one.

```bash
curl -H "Authorization: Bearer $ADMIN_TOKEN" http://localhost:8080/v1/admin/queue
```

### Development sign-in

`POST /auth/dev` hands out a session without going through Apple, so the simulator
works and so the app's `RootView.skipSignIn` path has a real server to talk to.
`HTTPBackend` calls it automatically when there is no token, inside `#if DEBUG`.

It is refused whenever `NODE_ENV=production`, and the Swift side compiles out of a
release build, so it cannot be left switched on by accident. Set `NODE_ENV=production`
before you deploy anywhere regardless.

---

## Tests

```bash
node test/apple.test.js          # token verification, no server needed
npm start &                      # then, against the running server:
ADMIN_TOKEN=test-admin-token node test/api.test.js
node test/photos.test.js
```

`api.test.js` covers 76 cases: the happy paths, and the rules — ownership, blocking,
validation, moderation, what an unauthenticated caller can reach, and what a client
cannot lie about.

---

## Before this is production

What is deliberately not here, in the order it will bite you:

1. **Push notifications.** `watchersFor()` already computes exactly who wanted a set
   the moment it is listed, and logs them. Wiring that to APNs is the remaining work.
2. **TLS.** Put this behind a reverse proxy or a host that terminates TLS. Do not ship
   an app that talks HTTP to a public address.
3. **Backups.** The database *and* `uploads/`, together — one without the other leaves
   listings pointing at images that no longer exist. See `DEPLOY.md`.
4. **A CDN in front of photos, eventually.** They are served straight off the disk with
   a one-year immutable cache header, which is fine until it isn't. Photos are the only
   thing here that gets big.
5. **Postgres, eventually.** SQLite is genuinely fine for a Qatar-sized marketplace on
   one box — do not migrate out of anxiety. Migrate when you need more than one server,
   and note the queries in `lib/repository.js` are ordinary SQL that will mostly port
   as-is.
6. **A real profanity list, including Arabic.** `lib/moderation.js` ships with the list
   empty, exactly as the app does. An English-only filter on a Qatar app is not a
   filter. Keep it here, not in the app bundle, so you can update it without shipping
   a build.
