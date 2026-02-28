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

