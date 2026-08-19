# Putting this server online

Right now the server runs on your Mac, which means it exists only while your laptop is
open. This is how it gets a real address.

Budget **about USD 5/month**. There is no meaningful free tier for this, because the
database is a file and free tiers do not give you a disk to keep it on.

---

## The one thing that will bite you

The database is a single file, and photos are files next to it. Most hosts wipe the
container's filesystem on every redeploy. If you do not attach a **persistent volume**
and point `DATABASE_PATH` at it, every listing and every photo your users posted
disappears the next time you push code, and there is no warning when it happens.

Every step below that mentions `/data` is there for this reason.

Photos deliberately live on that same volume — `/data/uploads` — so there is exactly one
thing to mount and one thing to back up. Object storage is the eventual answer, but it
is another account, another set of keys and another way to be misconfigured.

**Sizing:** photos are downscaled on the phone to roughly 200–400KB, and a listing has
at most three. Call it 1MB per listing. A 5GB volume holds around 5,000 listings with
room to spare; you will know long before you get there.

---

## Step 1 — Put the code on GitHub

Hosts deploy from a repository. This folder is not one yet.

```bash
cd /Users/abdullahdiaa/Desktop/lego
git init
git add .
git commit -m "Brick Souq: app and server"
```

Then make an empty **private** repo at github.com/new — do not let it add a README —
and push:

```bash
git remote add origin https://github.com/YOUR-USERNAME/bricksouq.git
git branch -M main
git push -u origin main
```

`server/.gitignore` already keeps the database, `.env` and your Apple `.p8` key out of
the repo. Check that `git status` does not list them before you push.

---

## Step 2 — Deploy on Railway

[railway.app](https://railway.app) → sign in with GitHub → **New Project** →
**Deploy from GitHub repo** → pick your repo.

Then, in the service that appears:

1. **Settings → Root Directory:** `server`
   Without this it tries to build the iOS app.
2. **Settings → Networking → Generate Domain.**
   You get something like `bricksouq-production.up.railway.app`, with HTTPS already
   working. Note it down.
3. **Variables → add these:**

   | Name | Value |
   |---|---|
   | `NODE_ENV` | `production` |
   | `DATABASE_PATH` | `/data/bricksouq.db` (photos follow it to `/data/uploads`) |
   | `APPLE_BUNDLE_ID` | `doody.lego` |
   | `ADMIN_TOKEN` | a long random string — see below |

   Generate the admin token on your Mac:

   ```bash
   node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"
   ```

4. **Create → Volume → mount path `/data`**, attached to this service.

   This is the step from the warning above. Do not skip it. The database lands at
   `/data/bricksouq.db` and photos at `/data/uploads/` — one volume covers both.

It redeploys automatically. Check it:

```bash
curl https://YOUR-APP.up.railway.app/v1/health
```

You want `{"ok":true,...,"devAuth":false,...}`. **`devAuth` must be `false`** — if it
says `true`, `NODE_ENV` is not set to `production` and anyone can sign in as anyone.

---

## Step 3 — Seed it (optional)

An empty Browse screen is a bad first impression while you are testing. From the
Railway service, open the shell and run:

```bash
npm run seed
```

Skip this for a real launch — you do not want fake listings in front of real users.

---

## Step 4 — Point the app at it

Already done — `ServerConfig.defaultURL` in `files/HTTPBackend.swift` points at the
deployed server, which is what a TestFlight or App Store build must talk to.

For day-to-day work against your Mac, override it per-scheme rather than editing that
line, so a local address can never ship by accident:

```
Xcode → Edit Scheme → Run → Arguments → Environment Variables
BRICKSOUQ_SERVER_URL = http://localhost:8080
```

**Testing against the deployed server needs real Sign in with Apple.** `/v1/auth/dev`
is disabled whenever `NODE_ENV=production`, which is the point of it — so set
`skipSignIn = false` in `RootView` before pointing a build at Railway. Browsing works
either way; publishing is what needs a session.

Two things follow from being on HTTPS now:

- The `NSAllowsLocalNetworking` ATS exception in `README.md` is no longer needed.
- `BRICKSOUQ_SERVER_URL` in your scheme still overrides this, so you can keep pointing
  at your Mac while developing. Check that it is empty when you build for the App Store.

---

## Step 5 — Back it up

Two things now: the database and the photos. A backup of one without the other gives
you listings pointing at images that no longer exist.

On a VPS, a cron entry:

```
0 3 * * * sqlite3 /data/bricksouq.db ".backup /data/backups/db-$(date +\%F).db" && tar czf /data/backups/photos-$(date +\%F).tar.gz -C /data uploads
```

Use `.backup` rather than copying the file — SQLite is in WAL mode and a plain `cp` of a
live database can capture a torn write.

Copy the results somewhere that is not the server. A backup on the same disk is not a
backup; it is a second copy of the thing that will fail.

---

## Step 6 — Prove the volume actually works

Do this before you trust it with anything. A missing volume fails **silently** — the
app works perfectly right up until a redeploy, and then the data is gone.

1. Post a listing with a photo from the app.
2. In Railway, hit **Redeploy**.
3. Open the app again. The listing should still be there.

If it vanished, `DATABASE_PATH` and the volume's mount path disagree. The deploy log
prints where the server actually put things:

```
  database    /data/bricksouq.db
  photos      /data/uploads
```

Anything other than `/data/...` there means the volume is not being used.

## Step 7 — Before real users, not before testing

- **Apple token revocation.** Add `APPLE_TEAM_ID`, `APPLE_KEY_ID` and the `.p8` key
  contents so account deletion revokes with Apple. Reviewers check this. On a host,
  paste the key into a variable and write it to a file at boot rather than committing
  the `.p8`.
- **Fill in the profanity list** in `lib/moderation.js`, including Arabic.
- **Watch the report log.** Reports print a line marked `[REPORT]` and Apple expects
  action within 24 hours. Railway keeps logs; point them at email or Slack before you
  rely on noticing.

---

## Other hosts

The `Dockerfile` is standard, so these all work the same way — the only thing that
changes is where you click:

| Host | Volume support | Notes |
|---|---|---|
| **Railway** | Yes | Easiest. Steps above. |
| **Render** | Yes, on paid instances | Free tier has no disk — your data will vanish. |
| **Fly.io** | Yes, `fly volumes create` | Cheapest at scale, more CLI work. |
| **Hetzner / DigitalOcean VPS** | It is your disk | €4/mo, most control. You handle TLS (Caddy is easiest) and security updates yourself. |

Avoid anything serverless — Vercel, Netlify, Cloudflare Workers. They have no
persistent filesystem, so SQLite cannot work there at all. That would mean moving to
Postgres first, which you do not need yet.

---

## When to leave SQLite

Not yet. One SQLite file on one box will comfortably handle a Qatar-sized marketplace —
tens of thousands of listings and far more readers than you will have for a long time.

Move to Postgres when you need more than one server, or when writes actually start
contending. The queries in `lib/repository.js` are ordinary SQL and will mostly port
as-is. Migrating before you need to costs you weeks and buys nothing.
