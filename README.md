# Secret Santa Picker

A full-stack web application for running Secret Santa gift exchanges. Create a draw, assign participants to groups to prevent unwanted pairings, share a results link, and optionally send every participant an email revealing their match — all in a few clicks.

Built with **Next.js**, **TypeScript**, and **Azure SQL**, deployed on **Vercel**.

---

## Features

- **Conflict-free matching** — assign participants to groups (e.g. families, teams) and the algorithm guarantees no one draws someone from their own group
- **Up to 50 participants** across up to 20 groups per draw
- **Shareable results link** — send the URL to everyone; the public view shows who gives to whom without revealing email addresses
- **Email notifications** — the draw organizer can trigger one-click emails that tell each participant their match; protected by Cloudflare Turnstile CAPTCHA
- **Admin access** — the creator gets a private admin link that unlocks participant emails, the ability to delete the draw, and an "edit and redraw" flow
- **Soft-delete** — draws can be hidden from view without destroying data

---

## Tech Stack

| Layer | Technology |
|---|---|
| Framework | Next.js 15 (pages router), React 18, TypeScript 5 |
| Database | Azure SQL Server via `mssql` |
| Email | Nodemailer + Gmail SMTP |
| CAPTCHA | Cloudflare Turnstile |
| Input sanitization | `sanitize-html` |
| Deployment | Vercel |

---

## Getting Started

### Prerequisites

- Node.js LTS and npm
- An Azure SQL Server instance (or any SQL Server — see [Database Setup](#database-setup))
- A Gmail account with an [app-specific password](https://support.google.com/accounts/answer/185833) configured
- A [Cloudflare Turnstile](https://www.cloudflare.com/products/turnstile/) site/secret key pair

### Environment Variables

Create a `.env.local` file in the project root. All variables are required.

```dotenv
# Azure SQL Server
AZURE_SQL_SERVER=your-server.database.windows.net
AZURE_SQL_DATABASE=your-database-name
AZURE_SQL_USER=your-db-username
AZURE_SQL_PASSWORD=your-db-password

# Gmail SMTP
GMAIL_USER=you@gmail.com
GMAIL_APP_PASSWORD=your-16-char-app-password

# Cloudflare Turnstile
NEXT_PUBLIC_TURNSTILE_SITE_KEY=your-site-key
TURNSTILE_SECRET_KEY=your-secret-key
```

### Database Setup

Run the schema script against your SQL Server instance once to create all required tables:

```bash
# Using sqlcmd
sqlcmd -S <server> -d <database> -U <user> -P <password> -i sql/setup.sql
```

This creates four tables:

| Table | Purpose |
|---|---|
| `Draws` | One row per draw session |
| `Participants` | Each person in a draw |
| `Matches` | Giver → receiver pairs |
| `DailyEmailLog` | Rate-limiting counter for outbound email |

See [`sql/setup.sql`](sql/setup.sql) for the full schema.

### Installation and Running

```bash
# Install dependencies
npm install

# Start the development server
npm run dev
# → http://localhost:3000/secret-santa

# Production build
npm run build
npm start
```

---

## How It Works

### Matching Algorithm

Matching is handled in [`src/lib/matching.ts`](src/lib/matching.ts).

**Constraints:**
- A participant can never draw themselves
- Participants in the same group cannot draw each other

**Feasibility check:** Before any DB write, the algorithm validates that a solution is mathematically possible. If any single group contains more than 50% of the participants, a valid assignment is provably impossible and the draw is rejected with an error message.

**Two-phase matching:**
1. **Phase 1 — Random shuffle** (up to 1,000 attempts): shuffle the participant list and pair each giver with the participant at the same index. If a candidate assignment violates any constraint, discard and retry.
2. **Phase 2 — Backtracking fallback**: if Phase 1 exhausts all attempts (very rare in practice), a deterministic recursive search finds a valid assignment, backtracking when it hits a dead end.

### Email Flow

Email sending is intentionally one-shot and protected:

1. The organizer fills in their name and email on the results page
2. A Cloudflare Turnstile challenge is verified server-side
3. A daily email cap (495 emails/day) is checked against `DailyEmailLog` to stay within Gmail SMTP limits
4. `emails_sent_at` is stamped on the draw before any emails go out — re-sending is rejected with a `409 Conflict`
5. Each participant with an email address receives a message revealing their match; the timestamp is rolled back only if every single email fails

### Admin Access

When a draw is created, the API returns both a `drawId` and a random `adminKey`. The home page redirects the creator to `/draw/<id>?key=<adminKey>`. The admin view:

- Shows participant email addresses in the results table
- Enables the **Delete draw** action (soft-delete)
- Enables **Edit and redraw** — participant data is saved to `sessionStorage`, the draw is deleted, and the user is returned to the home page with the form pre-filled

Anyone with only the draw ID (the shareable link) sees a read-only view with emails hidden.

---

## Project Structure

```
src/
  lib/
    db.ts             # Azure SQL singleton connection pool with retry/backoff logic
    matching.ts       # Conflict-free matching algorithm (shuffle + backtracking)
    email.ts          # Nodemailer email service
    sanitize.ts       # HTML stripping utility (XSS prevention)
  pages/
    api/
      create-draw.ts  # POST: validate input, run matching, persist draw in a transaction
      get-draw.ts     # GET: fetch draw + participants + matches; respects admin key
      send-emails.ts  # POST: CAPTCHA check, rate-limit check, send emails (idempotent)
      delete-draw.ts  # POST: soft-delete a draw
      health.ts       # GET: DB health check (called by Vercel cron)
      ping.ts         # GET: lightweight connectivity warm-up
    _app.tsx          # App wrapper (loads Turnstile script)
    index.tsx         # Home page — group + participant form
    draw/[id].tsx     # Results page — matches table, email send, admin actions
  styles/
    globals.css       # Design tokens (CSS custom properties), resets, typography
    Home.module.css
    Draw.module.css
  instrumentation.ts  # Next.js server hook — warms the DB pool on startup
sql/
  setup.sql           # Full database schema
next.config.js        # basePath, serverExternalPackages
vercel.json           # Function timeout, region, cron schedule
```

---

## API Reference

All endpoints are under the `/secret-santa/api/` path prefix.

| Method | Path | Description |
|---|---|---|
| `POST` | `/api/create-draw` | Validate participants, generate matches, persist everything in a transaction. Returns `{ drawId, adminKey }`. |
| `GET` | `/api/get-draw?id=<uuid>[&key=<adminKey>]` | Fetch draw, participants, and matches. Returns `410` for deleted draws; includes emails only when a valid admin key is supplied. |
| `POST` | `/api/send-emails` | Verify CAPTCHA, check daily limit, send match emails. Idempotent — returns `409` if already sent. |
| `POST` | `/api/delete-draw` | Soft-delete a draw by setting `deleted_at`. Idempotent. |
| `GET` | `/api/health` | Returns `{ ok: true }` if the DB is reachable; `503` otherwise. Called by Vercel cron daily. |
| `GET` | `/api/ping` | Lightweight connectivity check used to warm the connection pool. |

**Error shape:** all error responses use `{ "error": "<message>" }` JSON with an appropriate HTTP status code (`400`, `404`, `409`, `410`, `422`, `503`).

---

## Deployment

This app is designed to deploy to **Vercel**. The key configuration files are [`vercel.json`](vercel.json) and [`next.config.js`](next.config.js).

### Vercel Setup

1. Import the repository in the Vercel dashboard
2. Add all [environment variables](#environment-variables) under **Project Settings → Environment Variables**
3. Deploy — no build command changes are needed

### Configuration Notes

- **Base path**: all routes are served under `/secret-santa` (set via `basePath` in `next.config.js`). Do not remove this or all internal links and API calls will break.
- **Function timeout**: API functions are capped at 10 seconds (configured in `vercel.json`).
- **Region**: functions deploy to `cle1` (Cleveland). Change this in `vercel.json` if needed.
- **Cron job**: `vercel.json` schedules a daily `GET /secret-santa/api/health` at 17:00 UTC to keep the Azure SQL connection warm. Remove or adjust if you use a different database host.
- **`mssql` driver**: listed under `serverExternalPackages` in `next.config.js` — this is required for the native Azure SQL driver to work correctly in Vercel's serverless environment.

---

## Database Schema

```
Draws
  id               UNIQUEIDENTIFIER  PK (GUID)
  created_at       DATETIME2
  emails_sent_at   DATETIME2         NULL — set when emails are dispatched
  deleted_at       DATETIME2         NULL — set on soft-delete
  organizer_name   NVARCHAR(200)     NULL
  organizer_email  NVARCHAR(320)     NULL
  admin_key        NVARCHAR(100)     NULL — secret UUID for admin access

Participants
  id               INT IDENTITY      PK
  draw_id          UNIQUEIDENTIFIER  FK → Draws(id)
  name             NVARCHAR(200)
  email            NVARCHAR(320)
  group_name       NVARCHAR(200)     NULL

Matches
  id               INT IDENTITY      PK
  draw_id          UNIQUEIDENTIFIER  FK → Draws(id)
  giver_id         INT               FK → Participants(id)
  receiver_id      INT               FK → Participants(id)

DailyEmailLog
  log_date         DATE              PK
  emails_sent      INT               — incremented per email sent
```

Conventions: `snake_case` column names, GUIDs for public-facing IDs, `INT IDENTITY` for internal join keys, soft deletes only, parameterized queries throughout.

---

## Contributing

Pull requests are welcome.

- **TypeScript strict mode** is enforced — avoid `any` unless genuinely unavoidable
- **No test runner is configured** — verify changes manually via the dev server
- **No linter** beyond `tsc --noEmit` — keep code style consistent with the surrounding file
- **SQL**: always use parameterized queries; never interpolate user input into SQL strings
- **Multi-step writes** must use transactions with explicit rollback on error
- Open a PR against `main`; feature branches should use descriptive kebab-case names
