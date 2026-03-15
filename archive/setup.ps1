# Create directory structure
New-Item -ItemType Directory -Force -Path "src\lib" | Out-Null
New-Item -ItemType Directory -Force -Path "src\pages\api" | Out-Null
New-Item -ItemType Directory -Force -Path "src\pages\draw" | Out-Null
New-Item -ItemType Directory -Force -Path "src\styles" | Out-Null
New-Item -ItemType Directory -Force -Path "sql" | Out-Null

# package.json
@'
{
  "name": "secret-santa-picker",
  "version": "0.1.0",
  "private": true,
  "scripts": {
    "dev": "next dev",
    "build": "next build",
    "start": "next start"
  },
  "dependencies": {
    "next": "14.2.5",
    "react": "^18",
    "react-dom": "^18",
    "mssql": "^11.0.1",
    "nodemailer": "^6.9.14",
    "uuid": "^10.0.0"
  },
  "devDependencies": {
    "@types/node": "^20",
    "@types/react": "^18",
    "@types/react-dom": "^18",
    "@types/uuid": "^10",
    "@types/nodemailer": "^6",
    "typescript": "^5"
  }
}

'@ | Set-Content -Path "package.json" -Encoding UTF8

# next.config.js
@'
/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
}

module.exports = nextConfig

'@ | Set-Content -Path "next.config.js" -Encoding UTF8

# tsconfig.json
@'
{
  "compilerOptions": {
    "target": "es5",
    "lib": ["dom", "dom.iterable", "esnext"],
    "allowJs": true,
    "skipLibCheck": true,
    "strict": true,
    "noEmit": true,
    "esModuleInterop": true,
    "module": "esnext",
    "moduleResolution": "bundler",
    "resolveJsonModule": true,
    "isolatedModules": true,
    "jsx": "preserve",
    "incremental": true,
    "paths": {
      "@/*": ["./src/*"]
    }
  },
  "include": ["next-env.d.ts", "**/*.ts", "**/*.tsx"],
  "exclude": ["node_modules"]
}

'@ | Set-Content -Path "tsconfig.json" -Encoding UTF8

# .env.local.example
@'
# Azure SQL Database
AZURE_SQL_SERVER=your-server.database.windows.net
AZURE_SQL_DATABASE=your-database-name
AZURE_SQL_USER=your-username
AZURE_SQL_PASSWORD=your-password

# Gmail (App Password)
GMAIL_USER=your-email@gmail.com
GMAIL_APP_PASSWORD=your-16-char-app-password

# App
NEXT_PUBLIC_BASE_URL=https://yourdomain.com

'@ | Set-Content -Path ".env.local.example" -Encoding UTF8

# src/lib/db.ts
@'
import sql from 'mssql';

const config: sql.config = {
  server: process.env.AZURE_SQL_SERVER!,
  database: process.env.AZURE_SQL_DATABASE!,
  user: process.env.AZURE_SQL_USER!,
  password: process.env.AZURE_SQL_PASSWORD!,
  options: {
    encrypt: true,
    trustServerCertificate: false,
  },
};

let pool: sql.ConnectionPool | null = null;

export async function getPool(): Promise<sql.ConnectionPool> {
  if (!pool) {
    pool = await sql.connect(config);
  }
  return pool;
}

export { sql };

'@ | Set-Content -Path "src\lib\db.ts" -Encoding UTF8

# src/lib/email.ts
@'
import nodemailer from 'nodemailer';

const transporter = nodemailer.createTransport({
  service: 'gmail',
  auth: {
    user: process.env.GMAIL_USER,
    pass: process.env.GMAIL_APP_PASSWORD,
  },
});

export async function sendMatchEmail(
  toName: string,
  toEmail: string,
  matchName: string
): Promise<void> {
  await transporter.sendMail({
    from: `Secret Santa <${process.env.GMAIL_USER}>`,
    to: toEmail,
    subject: "🎁 Your Secret Santa Match",
    text: `Dear ${toName},\n\nYou have drawn ${matchName}'s name for the gift exchange this year.\n\nHappy gifting!`,
    html: `
      <div style="font-family: Georgia, serif; max-width: 480px; margin: 0 auto; padding: 32px; color: #1a1a1a;">
        <p style="font-size: 18px; margin-bottom: 24px;">Dear ${toName},</p>
        <p style="font-size: 16px; line-height: 1.6;">
          You have drawn <strong>${matchName}</strong>'s name for the gift exchange this year.
        </p>
        <p style="font-size: 14px; color: #888; margin-top: 32px;">Happy gifting!</p>
      </div>
    `,
  });
}

'@ | Set-Content -Path "src\lib\email.ts" -Encoding UTF8

# src/lib/matching.ts
@'
export interface Participant {
  id?: number;
  name: string;
  email: string;
  group: string;
}

export interface Match {
  giver: Participant;
  receiver: Participant;
}

/**
 * Checks whether a valid matching is mathematically possible.
 * A valid matching requires that no single group holds more than floor(n/2)
 * participants when n is even, or floor(n/2) when n is odd — more precisely,
 * no group can have more members than the total number of people outside that group
 * (since each group member needs a receiver from outside the group,
 * and also needs to receive from outside the group).
 *
 * The exact condition: for a valid derangement-with-constraints to exist,
 * no group should account for more than half the participants (strictly more
 * than n/2 means it's impossible).
 */
export function isMatchingPossible(participants: Participant[]): {
  possible: boolean;
  reason?: string;
} {
  const n = participants.length;
  if (n < 2) {
    return { possible: false, reason: 'At least 2 participants are required.' };
  }

  // Count group sizes (only for named groups)
  const groupCounts: Record<string, number> = {};
  for (const p of participants) {
    const g = p.group.trim();
    if (g) {
      groupCounts[g] = (groupCounts[g] || 0) + 1;
    }
  }

  for (const [group, count] of Object.entries(groupCounts)) {
    if (count >= n) {
      return {
        possible: false,
        reason: `All participants are in group "${group}". No valid matches can be made.`,
      };
    }
    if (count > n / 2) {
      return {
        possible: false,
        reason: `Group "${group}" has too many members (${count} out of ${n}). A valid matching is impossible because there aren't enough people outside this group.`,
      };
    }
  }

  return { possible: true };
}

/**
 * Attempts to create a valid matching using a shuffle-and-verify approach
 * with backtracking fallback. Returns null if no valid matching found after
 * max attempts (should not happen if isMatchingPossible returns true).
 */
export function createMatches(participants: Participant[]): Match[] | null {
  const MAX_ATTEMPTS = 1000;

  for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
    const shuffled = [...participants].sort(() => Math.random() - 0.5);
    const result: Match[] = [];
    let valid = true;

    for (let i = 0; i < participants.length; i++) {
      const giver = participants[i];
      const receiver = shuffled[i];

      if (
        giver.name === receiver.name ||
        (giver.group.trim() &&
          receiver.group.trim() &&
          giver.group.trim().toLowerCase() === receiver.group.trim().toLowerCase())
      ) {
        valid = false;
        break;
      }

      result.push({ giver, receiver });
    }

    if (valid) return result;
  }

  // Fallback: deterministic backtracking
  return backtrackMatch(participants);
}

function backtrackMatch(
  participants: Participant[],
  index = 0,
  used = new Set<number>(),
  result: Match[] = []
): Match[] | null {
  if (index === participants.length) return result;

  const giver = participants[index];
  const indices = shuffle(
    Array.from({ length: participants.length }, (_, i) => i)
  );

  for (const ri of indices) {
    if (used.has(ri)) continue;
    const receiver = participants[ri];
    if (
      giver.name === receiver.name ||
      (giver.group.trim() &&
        receiver.group.trim() &&
        giver.group.trim().toLowerCase() ===
          receiver.group.trim().toLowerCase())
    )
      continue;

    used.add(ri);
    result.push({ giver, receiver });
    const sub = backtrackMatch(participants, index + 1, used, result);
    if (sub) return sub;
    used.delete(ri);
    result.pop();
  }

  return null;
}

function shuffle<T>(arr: T[]): T[] {
  const a = [...arr];
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

'@ | Set-Content -Path "src\lib\matching.ts" -Encoding UTF8

# src/pages/_app.tsx
@'
import type { AppProps } from 'next/app';
import '` @/styles/globals.css';

export default function App({ Component, pageProps }: AppProps) {
  return <Component {...pageProps} />;
}

'@ | Set-Content -Path "src\pages\_app.tsx" -Encoding UTF8

# src/pages/index.tsx
@'
import { useState, useCallback } from 'react';
import { useRouter } from 'next/router';
import Head from 'next/head';
import styles from '` @/styles/Home.module.css';

interface Participant {
  id: string;
  name: string;
  email: string;
  group: string;
}

const MAX_PARTICIPANTS = 50;

function generateId() {
  return Math.random().toString(36).slice(2);
}

function emptyParticipant(): Participant {
  return { id: generateId(), name: '', email: '', group: '' };
}

export default function Home() {
  const router = useRouter();

  // Groups
  const [groups, setGroups] = useState<string[]>(['']);

  // Participants
  const [participants, setParticipants] = useState<Participant[]>([
    emptyParticipant(),
    emptyParticipant(),
  ]);

  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);

  // --- Group handlers ---
  const addGroup = () => {
    setGroups((g) => [...g, '']);
  };

  const updateGroup = (index: number, value: string) => {
    setGroups((g) => {
      const next = [...g];
      next[index] = value;
      return next;
    });
  };

  const removeGroup = (index: number) => {
    const removed = groups[index].trim();
    setGroups((g) => g.filter((_, i) => i !== index));
    // Clear any participants referencing this group
    if (removed) {
      setParticipants((ps) =>
        ps.map((p) =>
          p.group === removed ? { ...p, group: '' } : p
        )
      );
    }
  };

  const validGroups = groups.map((g) => g.trim()).filter(Boolean);

  // --- Participant handlers ---
  const addParticipant = () => {
    if (participants.length >= MAX_PARTICIPANTS) return;
    setParticipants((ps) => [...ps, emptyParticipant()]);
  };

  const updateParticipant = (id: string, field: keyof Participant, value: string) => {
    setParticipants((ps) =>
      ps.map((p) => (p.id === id ? { ...p, [field]: value } : p))
    );
  };

  const removeParticipant = (id: string) => {
    if (participants.length <= 2) return;
    setParticipants((ps) => ps.filter((p) => p.id !== id));
  };

  // --- Submit ---
  const handleSubmit = useCallback(async () => {
    setError('');

    const filled = participants.filter((p) => p.name.trim() || p.email.trim());
    const invalid = filled.filter(
      (p) => !p.name.trim() || !p.email.trim() || !/\S+@\S+\.\S+/.test(p.email)
    );

    if (filled.length < 2) {
      setError('Please enter at least 2 participants.');
      return;
    }
    if (invalid.length > 0) {
      setError('Please make sure every participant has a valid name and email address.');
      return;
    }

    const payload = filled.map((p) => ({
      name: p.name.trim(),
      email: p.email.trim(),
      group: p.group,
    }));

    setLoading(true);
    try {
      const res = await fetch('/api/create-draw', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ participants: payload }),
      });

      const data = await res.json();

      if (!res.ok) {
        setError(data.error || 'Something went wrong. Please try again.');
        return;
      }

      router.push(`/draw/${data.drawId}`);
    } catch {
      setError('Network error. Please check your connection and try again.');
    } finally {
      setLoading(false);
    }
  }, [participants, router]);

  const filledCount = participants.filter((p) => p.name.trim()).length;

  return (
    <>
      <Head>
        <title>Secret Santa Picker</title>
        <meta name="description" content="Draw Secret Santa matches and notify everyone by email." />
      </Head>

      <div className={styles.page}>
        <header className={styles.header}>
          <div className={styles.headerInner}>
            <span className={styles.icon}>🎁</span>
            <div>
              <h1 className={styles.title}>Secret Santa Picker</h1>
              <p className={styles.subtitle}>Enter your groups and participants, then draw matches.</p>
            </div>
          </div>
        </header>

        <main className={styles.main}>
          {/* Step 1: Groups */}
          <section className={`${styles.section} card`}>
            <div className={styles.sectionHeader}>
              <h2 className={styles.sectionTitle}>
                <span className={styles.step}>1</span>
                Groups
              </h2>
              <p className={styles.sectionDesc}>
                Optional. Members of the same group won't be matched with each other.
              </p>
            </div>

            <div className={styles.groupList}>
              {groups.map((g, i) => (
                <div key={i} className={styles.groupRow}>
                  <input
                    type="text"
                    placeholder={`Group ${i + 1} name`}
                    value={g}
                    onChange={(e) => updateGroup(i, e.target.value)}
                    maxLength={100}
                  />
                  <button
                    className={`btn btn-secondary ${styles.removeBtn}`}
                    onClick={() => removeGroup(i)}
                    title="Remove group"
                    disabled={groups.length === 1}
                  >
                    ×
                  </button>
                </div>
              ))}
            </div>

            <button className={`btn btn-secondary ${styles.addBtn}`} onClick={addGroup}>
              + Add group
            </button>
          </section>

          {/* Step 2: Participants */}
          <section className={`${styles.section} card`}>
            <div className={styles.sectionHeader}>
              <h2 className={styles.sectionTitle}>
                <span className={styles.step}>2</span>
                Participants
                <span className={styles.count}>{filledCount} / {MAX_PARTICIPANTS}</span>
              </h2>
              <p className={styles.sectionDesc}>
                Enter each person's name, email, and optionally assign them to a group.
              </p>
            </div>

            <div className={styles.participantHeader}>
              <span>Name</span>
              <span>Email</span>
              <span>Group</span>
              <span />
            </div>

            <div className={styles.participantList}>
              {participants.map((p, i) => (
                <div key={p.id} className={`${styles.participantRow} fade-in`}>
                  <input
                    type="text"
                    placeholder={`Person ${i + 1}`}
                    value={p.name}
                    onChange={(e) => updateParticipant(p.id, 'name', e.target.value)}
                    maxLength={200}
                  />
                  <input
                    type="email"
                    placeholder="email@example.com"
                    value={p.email}
                    onChange={(e) => updateParticipant(p.id, 'email', e.target.value)}
                    maxLength={320}
                  />
                  <select
                    value={p.group}
                    onChange={(e) => updateParticipant(p.id, 'group', e.target.value)}
                  >
                    <option value="">No group</option>
                    {validGroups.map((g) => (
                      <option key={g} value={g}>{g}</option>
                    ))}
                  </select>
                  <button
                    className={`btn btn-secondary ${styles.removeBtn}`}
                    onClick={() => removeParticipant(p.id)}
                    disabled={participants.length <= 2}
                    title="Remove participant"
                  >
                    ×
                  </button>
                </div>
              ))}
            </div>

            {participants.length < MAX_PARTICIPANTS && (
              <button className={`btn btn-secondary ${styles.addBtn}`} onClick={addParticipant}>
                + Add participant
              </button>
            )}
          </section>

          {error && <p className="error-msg fade-in">{error}</p>}

          <div className={styles.submitRow}>
            <button
              className="btn btn-primary"
              onClick={handleSubmit}
              disabled={loading}
            >
              {loading ? 'Drawing matches…' : '🎁 Draw matches'}
            </button>
          </div>
        </main>

        <footer className={styles.footer}>
          <p>Matches are randomly generated and saved with a shareable link.</p>
        </footer>
      </div>
    </>
  );
}

'@ | Set-Content -Path "src\pages\index.tsx" -Encoding UTF8

# src/pages/draw/[id].tsx
@'
import { useEffect, useState } from 'react';
import { useRouter } from 'next/router';
import Head from 'next/head';
import Link from 'next/link';
import styles from '` @/styles/Draw.module.css';

interface Match {
  giver_name: string;
  giver_email: string;
  giver_group: string | null;
  receiver_name: string;
  receiver_group: string | null;
}

interface DrawData {
  id: string;
  created_at: string;
  emails_sent_at: string | null;
  participants: Array<{ name: string; email: string; group_name: string | null }>;
  matches: Match[];
}

type PageState = 'loading' | 'loaded' | 'deleted' | 'not-found' | 'error';

export default function DrawPage() {
  const router = useRouter();
  const { id } = router.query;

  const [state, setState] = useState<PageState>('loading');
  const [draw, setDraw] = useState<DrawData | null>(null);

  const [emailLoading, setEmailLoading] = useState(false);
  const [emailError, setEmailError] = useState('');
  const [emailSuccess, setEmailSuccess] = useState(false);

  const [deleteLoading, setDeleteLoading] = useState(false);
  const [deleteConfirm, setDeleteConfirm] = useState(false);
  const [deleted, setDeleted] = useState(false);

  const [copied, setCopied] = useState(false);

  useEffect(() => {
    if (!id) return;
    fetch(`/api/get-draw?id=${id}`)
      .then(async (res) => {
        if (res.status === 410) { setState('deleted'); return; }
        if (res.status === 404) { setState('not-found'); return; }
        if (!res.ok) { setState('error'); return; }
        const data = await res.json();
        setDraw(data);
        setState('loaded');
      })
      .catch(() => setState('error'));
  }, [id]);

  const handleSendEmails = async () => {
    if (!draw) return;
    setEmailLoading(true);
    setEmailError('');
    try {
      const res = await fetch('/api/send-emails', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ id: draw.id }),
      });
      const data = await res.json();
      if (!res.ok) {
        setEmailError(data.error || 'Failed to send emails.');
      } else {
        setEmailSuccess(true);
        setDraw((d) => d ? { ...d, emails_sent_at: new Date().toISOString() } : d);
      }
    } catch {
      setEmailError('Network error. Please try again.');
    } finally {
      setEmailLoading(false);
    }
  };

  const handleDelete = async () => {
    if (!draw) return;
    setDeleteLoading(true);
    try {
      const res = await fetch('/api/delete-draw', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ id: draw.id }),
      });
      if (res.ok) {
        setDeleted(true);
      }
    } catch {
      // silent
    } finally {
      setDeleteLoading(false);
      setDeleteConfirm(false);
    }
  };

  const handleCopyLink = () => {
    navigator.clipboard.writeText(window.location.href);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  if (state === 'loading') {
    return (
      <div className={styles.centered}>
        <p className={styles.muted}>Loading draw…</p>
      </div>
    );
  }

  if (state === 'deleted' || deleted) {
    return (
      <>
        <Head><title>Draw unavailable — Secret Santa Picker</title></Head>
        <div className={styles.centered}>
          <div className={`card ${styles.messageCard}`}>
            <span className={styles.bigIcon}>🚫</span>
            <h2>This draw is no longer available</h2>
            <p className={styles.muted}>The person who created it has deleted the results.</p>
            <Link href="/" className="btn btn-secondary" style={{ marginTop: 16 }}>
              Start a new draw
            </Link>
          </div>
        </div>
      </>
    );
  }

  if (state === 'not-found') {
    return (
      <>
        <Head><title>Draw not found — Secret Santa Picker</title></Head>
        <div className={styles.centered}>
          <div className={`card ${styles.messageCard}`}>
            <span className={styles.bigIcon}>🔍</span>
            <h2>Draw not found</h2>
            <p className={styles.muted}>This link may be invalid or expired.</p>
            <Link href="/" className="btn btn-secondary" style={{ marginTop: 16 }}>
              Start a new draw
            </Link>
          </div>
        </div>
      </>
    );
  }

  if (state === 'error' || !draw) {
    return (
      <div className={styles.centered}>
        <p className={styles.muted}>Something went wrong. Please refresh.</p>
      </div>
    );
  }

  const createdDate = new Date(draw.created_at).toLocaleDateString('en-US', {
    month: 'long', day: 'numeric', year: 'numeric',
  });

  const emailsSentDate = draw.emails_sent_at
    ? new Date(draw.emails_sent_at).toLocaleDateString('en-US', {
        month: 'long', day: 'numeric', year: 'numeric', hour: '2-digit', minute: '2-digit',
      })
    : null;

  return (
    <>
      <Head>
        <title>Draw results — Secret Santa Picker</title>
      </Head>

      <div className={styles.page}>
        <header className={styles.header}>
          <div className={styles.headerInner}>
            <Link href="/" className={styles.homeLink}>🎁 Secret Santa Picker</Link>
            <span className={styles.headerMeta}>Draw created {createdDate}</span>
          </div>
        </header>

        <main className={styles.main}>
          {/* Share bar */}
          <div className={`card ${styles.shareBar}`}>
            <div>
              <p className={styles.shareLabel}>Shareable link</p>
              <p className={styles.shareUrl}>{typeof window !== 'undefined' ? window.location.href : ''}</p>
            </div>
            <button className="btn btn-secondary" onClick={handleCopyLink}>
              {copied ? '✓ Copied' : 'Copy link'}
            </button>
          </div>

          {/* Matches table */}
          <section className={`card ${styles.section}`}>
            <h2 className={styles.sectionTitle}>Matches</h2>
            <p className={styles.sectionDesc}>
              {draw.matches.length} participant{draw.matches.length !== 1 ? 's' : ''} — each person will give a gift to the person listed beside them.
            </p>

            <table className={styles.table}>
              <thead>
                <tr>
                  <th>Giver</th>
                  <th>Group</th>
                  <th>→ Receiving for</th>
                  <th>Group</th>
                </tr>
              </thead>
              <tbody>
                {draw.matches.map((m, i) => (
                  <tr key={i}>
                    <td className={styles.nameCell}>
                      <span className={styles.name}>{m.giver_name}</span>
                      <span className={styles.email}>{m.giver_email}</span>
                    </td>
                    <td>
                      {m.giver_group
                        ? <span className={styles.groupBadge}>{m.giver_group}</span>
                        : <span className={styles.noGroup}>—</span>}
                    </td>
                    <td className={styles.nameCell}>
                      <span className={styles.name}>{m.receiver_name}</span>
                    </td>
                    <td>
                      {m.receiver_group
                        ? <span className={styles.groupBadge}>{m.receiver_group}</span>
                        : <span className={styles.noGroup}>—</span>}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </section>

          {/* Email section */}
          <section className={`card ${styles.section}`}>
            <h2 className={styles.sectionTitle}>Email notifications</h2>

            {emailsSentDate ? (
              <p className="success-msg">
                ✓ Emails were sent on {emailsSentDate}. Each participant has been notified of their match.
              </p>
            ) : (
              <>
                <p className={styles.sectionDesc}>
                  Send each participant an email revealing who they drew. This can only be done once.
                </p>
                {emailError && <p className="error-msg" style={{ marginBottom: 12 }}>{emailError}</p>}
                {emailSuccess && (
                  <p className="success-msg" style={{ marginBottom: 12 }}>
                    ✓ Emails sent successfully!
                  </p>
                )}
                <button
                  className="btn btn-success"
                  onClick={handleSendEmails}
                  disabled={emailLoading || emailSuccess}
                >
                  {emailLoading ? 'Sending…' : `📧 Send emails to all ${draw.matches.length} participants`}
                </button>
              </>
            )}
          </section>

          {/* Delete section */}
          <section className={`card ${styles.section} ${styles.dangerSection}`}>
            <h2 className={styles.sectionTitle}>Delete this draw</h2>
            <p className={styles.sectionDesc}>
              Permanently removes access to this draw. The shareable link will no longer display any results.
              This cannot be undone.
            </p>

            {!deleteConfirm ? (
              <button className="btn btn-danger" onClick={() => setDeleteConfirm(true)}>
                Delete draw
              </button>
            ) : (
              <div className={styles.confirmRow}>
                <p className={styles.confirmText}>Are you sure? This cannot be undone.</p>
                <div className={styles.confirmBtns}>
                  <button
                    className="btn btn-danger"
                    onClick={handleDelete}
                    disabled={deleteLoading}
                  >
                    {deleteLoading ? 'Deleting…' : 'Yes, delete'}
                  </button>
                  <button
                    className="btn btn-secondary"
                    onClick={() => setDeleteConfirm(false)}
                  >
                    Cancel
                  </button>
                </div>
              </div>
            )}
          </section>
        </main>

        <footer className={styles.footer}>
          <Link href="/">← Start a new draw</Link>
        </footer>
      </div>
    </>
  );
}

'@ | Set-Content -Path "src\pages\draw\[id].tsx" -Encoding UTF8

# src/pages/api/create-draw.ts
@'
import type { NextApiRequest, NextApiResponse } from 'next';
import { v4 as uuidv4 } from 'uuid';
import { getPool, sql } from '` @/lib/db';
import { isMatchingPossible, createMatches, Participant } from '` @/lib/matching';

export default async function handler(req: NextApiRequest, res: NextApiResponse) {
  if (req.method !== 'POST') return res.status(405).end();

  const { participants }: { participants: Participant[] } = req.body;

  if (!participants || participants.length < 2) {
    return res.status(400).json({ error: 'At least 2 participants required.' });
  }
  if (participants.length > 50) {
    return res.status(400).json({ error: 'Maximum 50 participants allowed.' });
  }

  const check = isMatchingPossible(participants);
  if (!check.possible) {
    return res.status(422).json({ error: check.reason });
  }

  const matches = createMatches(participants);
  if (!matches) {
    return res.status(422).json({ error: 'Could not find a valid matching. Please adjust your groups.' });
  }

  const drawId = uuidv4();
  const pool = await getPool();
  const transaction = new sql.Transaction(pool);

  try {
    await transaction.begin();

    // Insert draw
    const r0 = new sql.Request(transaction);
    await r0.input('drawId', sql.UniqueIdentifier, drawId).query(
      `INSERT INTO Draws (id) VALUES (@drawId)`
    );

    // Insert participants and capture their DB ids
    const participantIds: number[] = [];
    for (const p of participants) {
      const r = new sql.Request(transaction);
      const result = await r
        .input('drawId', sql.UniqueIdentifier, drawId)
        .input('name', sql.NVarChar(200), p.name)
        .input('email', sql.NVarChar(320), p.email)
        .input('group_name', sql.NVarChar(200), p.group || null)
        .query(
          `INSERT INTO Participants (draw_id, name, email, group_name)
           OUTPUT INSERTED.id
           VALUES (@drawId, @name, @email, @group_name)`
        );
      participantIds.push(result.recordset[0].id);
    }

    // Build a map from participant name to DB id
    const nameToId: Record<string, number> = {};
    for (let i = 0; i < participants.length; i++) {
      nameToId[participants[i].name] = participantIds[i];
    }

    // Insert matches
    for (const match of matches) {
      const r = new sql.Request(transaction);
      await r
        .input('drawId', sql.UniqueIdentifier, drawId)
        .input('giverId', sql.Int, nameToId[match.giver.name])
        .input('receiverId', sql.Int, nameToId[match.receiver.name])
        .query(
          `INSERT INTO Matches (draw_id, giver_participant_id, receiver_participant_id)
           VALUES (@drawId, @giverId, @receiverId)`
        );
    }

    await transaction.commit();
    return res.status(200).json({ drawId });
  } catch (err) {
    await transaction.rollback();
    console.error(err);
    return res.status(500).json({ error: 'Database error. Please try again.' });
  }
}

'@ | Set-Content -Path "src\pages\api\create-draw.ts" -Encoding UTF8

# src/pages/api/get-draw.ts
@'
import type { NextApiRequest, NextApiResponse } from 'next';
import { getPool, sql } from '` @/lib/db';

export default async function handler(req: NextApiRequest, res: NextApiResponse) {
  if (req.method !== 'GET') return res.status(405).end();

  const { id } = req.query;
  if (!id || typeof id !== 'string') return res.status(400).end();

  const pool = await getPool();

  const r1 = new sql.Request(pool);
  const drawResult = await r1
    .input('drawId', sql.UniqueIdentifier, id)
    .query(`SELECT id, created_at, emails_sent_at, deleted_at FROM Draws WHERE id = @drawId`);

  if (!drawResult.recordset.length) {
    return res.status(404).json({ error: 'Draw not found.' });
  }

  const draw = drawResult.recordset[0];

  if (draw.deleted_at) {
    return res.status(410).json({ deleted: true });
  }

  const r2 = new sql.Request(pool);
  const participantsResult = await r2
    .input('drawId', sql.UniqueIdentifier, id)
    .query(`SELECT id, name, email, group_name FROM Participants WHERE draw_id = @drawId`);

  const r3 = new sql.Request(pool);
  const matchesResult = await r3
    .input('drawId', sql.UniqueIdentifier, id)
    .query(`
      SELECT
        g.name AS giver_name,
        g.email AS giver_email,
        g.group_name AS giver_group,
        rv.name AS receiver_name,
        rv.group_name AS receiver_group
      FROM Matches m
      JOIN Participants g ON m.giver_participant_id = g.id
      JOIN Participants rv ON m.receiver_participant_id = rv.id
      WHERE m.draw_id = @drawId
    `);

  return res.status(200).json({
    id: draw.id,
    created_at: draw.created_at,
    emails_sent_at: draw.emails_sent_at,
    participants: participantsResult.recordset,
    matches: matchesResult.recordset,
  });
}

'@ | Set-Content -Path "src\pages\api\get-draw.ts" -Encoding UTF8

# src/pages/api/send-emails.ts
@'
import type { NextApiRequest, NextApiResponse } from 'next';
import { getPool, sql } from '` @/lib/db';
import { sendMatchEmail } from '` @/lib/email';

export default async function handler(req: NextApiRequest, res: NextApiResponse) {
  if (req.method !== 'POST') return res.status(405).end();

  const { id } = req.body;
  if (!id || typeof id !== 'string') return res.status(400).end();

  const pool = await getPool();

  const r1 = new sql.Request(pool);
  const drawResult = await r1
    .input('drawId', sql.UniqueIdentifier, id)
    .query(`SELECT id, emails_sent_at, deleted_at FROM Draws WHERE id = @drawId`);

  if (!drawResult.recordset.length) {
    return res.status(404).json({ error: 'Draw not found.' });
  }

  const draw = drawResult.recordset[0];

  if (draw.deleted_at) {
    return res.status(410).json({ error: 'This draw has been deleted.' });
  }

  if (draw.emails_sent_at) {
    return res.status(409).json({ error: 'Emails have already been sent for this draw.' });
  }

  const r2 = new sql.Request(pool);
  const matchesResult = await r2
    .input('drawId', sql.UniqueIdentifier, id)
    .query(`
      SELECT
        g.name AS giver_name,
        g.email AS giver_email,
        rv.name AS receiver_name
      FROM Matches m
      JOIN Participants g ON m.giver_participant_id = g.id
      JOIN Participants rv ON m.receiver_participant_id = rv.id
      WHERE m.draw_id = @drawId
    `);

  try {
    await Promise.all(
      matchesResult.recordset.map((match) =>
        sendMatchEmail(match.giver_name, match.giver_email, match.receiver_name)
      )
    );

    const r3 = new sql.Request(pool);
    await r3
      .input('drawId', sql.UniqueIdentifier, id)
      .query(`UPDATE Draws SET emails_sent_at = GETUTCDATE() WHERE id = @drawId`);

    return res.status(200).json({ success: true });
  } catch (err) {
    console.error(err);
    return res.status(500).json({ error: 'Failed to send emails. Please try again.' });
  }
}

'@ | Set-Content -Path "src\pages\api\send-emails.ts" -Encoding UTF8

# src/pages/api/delete-draw.ts
@'
import type { NextApiRequest, NextApiResponse } from 'next';
import { getPool, sql } from '` @/lib/db';

export default async function handler(req: NextApiRequest, res: NextApiResponse) {
  if (req.method !== 'POST') return res.status(405).end();

  const { id } = req.body;
  if (!id || typeof id !== 'string') return res.status(400).end();

  const pool = await getPool();

  const r1 = new sql.Request(pool);
  const drawResult = await r1
    .input('drawId', sql.UniqueIdentifier, id)
    .query(`SELECT id, deleted_at FROM Draws WHERE id = @drawId`);

  if (!drawResult.recordset.length) {
    return res.status(404).json({ error: 'Draw not found.' });
  }

  if (drawResult.recordset[0].deleted_at) {
    return res.status(200).json({ success: true }); // Already deleted — idempotent
  }

  const r2 = new sql.Request(pool);
  await r2
    .input('drawId', sql.UniqueIdentifier, id)
    .query(`UPDATE Draws SET deleted_at = GETUTCDATE() WHERE id = @drawId`);

  return res.status(200).json({ success: true });
}

'@ | Set-Content -Path "src\pages\api\delete-draw.ts" -Encoding UTF8

# src/styles/globals.css
@'
@import url('https://fonts.googleapis.com/css2?family=Libre+Baskerville:ital,wght@0,400;0,700;1,400&family=DM+Sans:wght@300;400;500&display=swap');

*, *::before, *::after {
  box-sizing: border-box;
  margin: 0;
  padding: 0;
}

:root {
  --ink: #1a1714;
  --ink-light: #6b6560;
  --ink-faint: #b8b3ae;
  --paper: #faf8f5;
  --paper-warm: #f2ede6;
  --accent: #c84b2f;
  --accent-light: #f0e8e5;
  --success: #2d6a4f;
  --success-light: #e8f5ee;
  --border: #e4dfd9;
  --radius: 4px;
  --font-serif: 'Libre Baskerville', Georgia, serif;
  --font-sans: 'DM Sans', system-ui, sans-serif;
  --shadow: 0 1px 3px rgba(26,23,20,0.08), 0 4px 16px rgba(26,23,20,0.04);
  --shadow-lg: 0 2px 8px rgba(26,23,20,0.1), 0 12px 40px rgba(26,23,20,0.08);
}

html {
  font-size: 16px;
  -webkit-font-smoothing: antialiased;
}

body {
  font-family: var(--font-sans);
  background: var(--paper);
  color: var(--ink);
  min-height: 100vh;
}

h1, h2, h3 {
  font-family: var(--font-serif);
  font-weight: 700;
  line-height: 1.2;
}

a {
  color: var(--accent);
  text-decoration: none;
}

a:hover {
  text-decoration: underline;
}

button {
  font-family: var(--font-sans);
  cursor: pointer;
  border: none;
  outline: none;
}

input, select {
  font-family: var(--font-sans);
  font-size: 14px;
  color: var(--ink);
  background: white;
  border: 1px solid var(--border);
  border-radius: var(--radius);
  padding: 8px 12px;
  transition: border-color 0.15s, box-shadow 0.15s;
  outline: none;
  width: 100%;
}

input:focus, select:focus {
  border-color: var(--ink-light);
  box-shadow: 0 0 0 3px rgba(26,23,20,0.06);
}

input::placeholder {
  color: var(--ink-faint);
}

.btn {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  font-size: 14px;
  font-weight: 500;
  padding: 10px 20px;
  border-radius: var(--radius);
  transition: all 0.15s;
  letter-spacing: 0.01em;
}

.btn-primary {
  background: var(--ink);
  color: white;
}

.btn-primary:hover:not(:disabled) {
  background: #2d2926;
  transform: translateY(-1px);
  box-shadow: var(--shadow);
}

.btn-primary:disabled {
  opacity: 0.4;
  cursor: not-allowed;
}

.btn-secondary {
  background: transparent;
  color: var(--ink);
  border: 1px solid var(--border);
}

.btn-secondary:hover {
  background: var(--paper-warm);
  border-color: var(--ink-faint);
}

.btn-danger {
  background: transparent;
  color: var(--accent);
  border: 1px solid #e8c4bc;
}

.btn-danger:hover {
  background: var(--accent-light);
}

.btn-success {
  background: var(--success);
  color: white;
}

.btn-success:hover:not(:disabled) {
  background: #245941;
  transform: translateY(-1px);
  box-shadow: var(--shadow);
}

.btn-success:disabled {
  opacity: 0.4;
  cursor: not-allowed;
}

.card {
  background: white;
  border: 1px solid var(--border);
  border-radius: 8px;
  box-shadow: var(--shadow);
}

.error-msg {
  font-size: 13px;
  color: var(--accent);
  background: var(--accent-light);
  border: 1px solid #e8c4bc;
  border-radius: var(--radius);
  padding: 10px 14px;
  line-height: 1.5;
}

.success-msg {
  font-size: 13px;
  color: var(--success);
  background: var(--success-light);
  border: 1px solid #b7deca;
  border-radius: var(--radius);
  padding: 10px 14px;
  line-height: 1.5;
}

@keyframes fadeIn {
  from { opacity: 0; transform: translateY(6px); }
  to { opacity: 1; transform: translateY(0); }
}

.fade-in {
  animation: fadeIn 0.3s ease forwards;
}

'@ | Set-Content -Path "src\styles\globals.css" -Encoding UTF8

# src/styles/Home.module.css
@'
.page {
  min-height: 100vh;
  display: flex;
  flex-direction: column;
}

.header {
  border-bottom: 1px solid var(--border);
  padding: 28px 24px;
  background: white;
}

.headerInner {
  max-width: 780px;
  margin: 0 auto;
  display: flex;
  align-items: center;
  gap: 16px;
}

.icon {
  font-size: 32px;
  line-height: 1;
}

.title {
  font-size: 26px;
  color: var(--ink);
  margin-bottom: 4px;
}

.subtitle {
  font-size: 14px;
  color: var(--ink-light);
  font-family: var(--font-sans);
  font-weight: 300;
}

.main {
  flex: 1;
  max-width: 780px;
  width: 100%;
  margin: 0 auto;
  padding: 32px 24px;
  display: flex;
  flex-direction: column;
  gap: 24px;
}

.section {
  padding: 24px;
}

.sectionHeader {
  margin-bottom: 20px;
}

.sectionTitle {
  font-size: 18px;
  display: flex;
  align-items: center;
  gap: 10px;
  margin-bottom: 6px;
}

.step {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 24px;
  height: 24px;
  background: var(--ink);
  color: white;
  border-radius: 50%;
  font-family: var(--font-sans);
  font-size: 12px;
  font-weight: 500;
  flex-shrink: 0;
}

.count {
  font-family: var(--font-sans);
  font-size: 13px;
  font-weight: 400;
  color: var(--ink-faint);
  margin-left: auto;
}

.sectionDesc {
  font-size: 13px;
  color: var(--ink-light);
  line-height: 1.5;
}

.groupList {
  display: flex;
  flex-direction: column;
  gap: 8px;
  margin-bottom: 12px;
}

.groupRow {
  display: flex;
  gap: 8px;
  align-items: center;
}

.groupRow input {
  flex: 1;
}

.removeBtn {
  padding: 8px 12px !important;
  font-size: 18px !important;
  line-height: 1;
  flex-shrink: 0;
  color: var(--ink-faint) !important;
}

.removeBtn:hover:not(:disabled) {
  color: var(--accent) !important;
  border-color: #e8c4bc !important;
  background: var(--accent-light) !important;
}

.addBtn {
  font-size: 13px !important;
  padding: 8px 14px !important;
  color: var(--ink-light) !important;
}

.participantHeader {
  display: grid;
  grid-template-columns: 1fr 1fr 160px 40px;
  gap: 8px;
  padding: 0 0 8px;
  font-size: 11px;
  font-weight: 500;
  text-transform: uppercase;
  letter-spacing: 0.08em;
  color: var(--ink-faint);
  border-bottom: 1px solid var(--border);
  margin-bottom: 8px;
}

.participantList {
  display: flex;
  flex-direction: column;
  gap: 8px;
  margin-bottom: 12px;
}

.participantRow {
  display: grid;
  grid-template-columns: 1fr 1fr 160px 40px;
  gap: 8px;
  align-items: center;
}

.submitRow {
  display: flex;
  justify-content: flex-end;
  padding-top: 8px;
}

.submitRow .btn {
  font-size: 15px !important;
  padding: 12px 28px !important;
}

.footer {
  border-top: 1px solid var(--border);
  padding: 20px 24px;
  text-align: center;
  font-size: 12px;
  color: var(--ink-faint);
}

@media (max-width: 600px) {
  .participantHeader {
    display: none;
  }

  .participantRow {
    grid-template-columns: 1fr 40px;
    grid-template-rows: auto auto auto;
  }

  .participantRow input:nth-child(1) { grid-column: 1; grid-row: 1; }
  .participantRow input:nth-child(2) { grid-column: 1; grid-row: 2; }
  .participantRow select { grid-column: 1; grid-row: 3; }
  .participantRow button { grid-column: 2; grid-row: 1; align-self: start; }
}

'@ | Set-Content -Path "src\styles\Home.module.css" -Encoding UTF8

# src/styles/Draw.module.css
@'
.page {
  min-height: 100vh;
  display: flex;
  flex-direction: column;
}

.centered {
  min-height: 100vh;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 24px;
}

.messageCard {
  padding: 48px 40px;
  text-align: center;
  max-width: 420px;
  width: 100%;
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 12px;
}

.bigIcon {
  font-size: 48px;
  line-height: 1;
  margin-bottom: 8px;
}

.messageCard h2 {
  font-size: 22px;
}

.header {
  border-bottom: 1px solid var(--border);
  padding: 20px 24px;
  background: white;
}

.headerInner {
  max-width: 860px;
  margin: 0 auto;
  display: flex;
  align-items: center;
  justify-content: space-between;
}

.homeLink {
  font-family: var(--font-serif);
  font-weight: 700;
  font-size: 18px;
  color: var(--ink);
  text-decoration: none;
}

.homeLink:hover {
  text-decoration: none;
  color: var(--accent);
}

.headerMeta {
  font-size: 13px;
  color: var(--ink-faint);
}

.main {
  flex: 1;
  max-width: 860px;
  width: 100%;
  margin: 0 auto;
  padding: 32px 24px;
  display: flex;
  flex-direction: column;
  gap: 20px;
}

.shareBar {
  padding: 16px 20px;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 16px;
}

.shareLabel {
  font-size: 11px;
  font-weight: 500;
  text-transform: uppercase;
  letter-spacing: 0.08em;
  color: var(--ink-faint);
  margin-bottom: 4px;
}

.shareUrl {
  font-size: 13px;
  color: var(--ink-light);
  font-family: monospace;
  word-break: break-all;
}

.section {
  padding: 24px;
}

.sectionTitle {
  font-size: 18px;
  margin-bottom: 8px;
}

.sectionDesc {
  font-size: 13px;
  color: var(--ink-light);
  margin-bottom: 16px;
  line-height: 1.5;
}

.table {
  width: 100%;
  border-collapse: collapse;
  font-size: 14px;
}

.table thead tr {
  border-bottom: 2px solid var(--border);
}

.table th {
  text-align: left;
  padding: 8px 12px 10px;
  font-size: 11px;
  font-weight: 500;
  text-transform: uppercase;
  letter-spacing: 0.08em;
  color: var(--ink-faint);
  font-family: var(--font-sans);
}

.table td {
  padding: 12px;
  border-bottom: 1px solid var(--border);
  vertical-align: middle;
}

.table tbody tr:last-child td {
  border-bottom: none;
}

.table tbody tr:hover td {
  background: var(--paper);
}

.nameCell {
  display: flex;
  flex-direction: column;
  gap: 2px;
}

.name {
  font-weight: 500;
  color: var(--ink);
}

.email {
  font-size: 12px;
  color: var(--ink-faint);
}

.groupBadge {
  display: inline-block;
  font-size: 11px;
  padding: 2px 8px;
  background: var(--paper-warm);
  border: 1px solid var(--border);
  border-radius: 100px;
  color: var(--ink-light);
  white-space: nowrap;
}

.noGroup {
  color: var(--ink-faint);
}

.muted {
  color: var(--ink-faint);
  font-size: 14px;
}

.dangerSection {
  border-color: #f0dcd8;
}

.confirmRow {
  display: flex;
  flex-direction: column;
  gap: 12px;
}

.confirmText {
  font-size: 13px;
  color: var(--accent);
}

.confirmBtns {
  display: flex;
  gap: 8px;
}

.footer {
  border-top: 1px solid var(--border);
  padding: 20px 24px;
  text-align: center;
  font-size: 13px;
}

@media (max-width: 600px) {
  .table th:nth-child(2),
  .table td:nth-child(2),
  .table th:nth-child(4),
  .table td:nth-child(4) {
    display: none;
  }

  .shareBar {
    flex-direction: column;
    align-items: flex-start;
  }

  .headerInner {
    flex-direction: column;
    align-items: flex-start;
    gap: 4px;
  }
}

'@ | Set-Content -Path "src\styles\Draw.module.css" -Encoding UTF8

# sql/setup.sql
@'
-- Run this script once in your Azure SQL database to set up the schema.

CREATE TABLE Draws (
  id UNIQUEIDENTIFIER PRIMARY KEY DEFAULT NEWID(),
  created_at DATETIME2 DEFAULT GETUTCDATE(),
  emails_sent_at DATETIME2 NULL,
  deleted_at DATETIME2 NULL
);

CREATE TABLE Participants (
  id INT IDENTITY(1,1) PRIMARY KEY,
  draw_id UNIQUEIDENTIFIER NOT NULL REFERENCES Draws(id),
  name NVARCHAR(200) NOT NULL,
  email NVARCHAR(320) NOT NULL,
  group_name NVARCHAR(200) NULL
);

CREATE TABLE Matches (
  id INT IDENTITY(1,1) PRIMARY KEY,
  draw_id UNIQUEIDENTIFIER NOT NULL REFERENCES Draws(id),
  giver_participant_id INT NOT NULL REFERENCES Participants(id),
  receiver_participant_id INT NOT NULL REFERENCES Participants(id)
);

CREATE INDEX IX_Participants_DrawId ON Participants(draw_id);
CREATE INDEX IX_Matches_DrawId ON Matches(draw_id);

'@ | Set-Content -Path "sql\setup.sql" -Encoding UTF8
