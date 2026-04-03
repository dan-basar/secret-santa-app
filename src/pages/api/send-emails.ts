import type { NextApiRequest, NextApiResponse } from 'next';
import { getPool, withRetry, sql } from '@/lib/db';
import { sendMatchEmail } from '@/lib/email';
import { stripHtml } from '@/lib/sanitize';

const DAILY_EMAIL_LIMIT = 495;

export default async function handler(req: NextApiRequest, res: NextApiResponse) {
  if (req.method !== 'POST') return res.status(405).end();

  const { id, organizerName, organizerEmail, turnstileToken } = req.body;
  if (!id || typeof id !== 'string') return res.status(400).end();
  if (!organizerName || typeof organizerName !== 'string' || !organizerName.trim()) return res.status(400).json({ error: 'Organizer name is required.' });
  if (!organizerEmail || typeof organizerEmail !== 'string' || !organizerEmail.trim()) return res.status(400).json({ error: 'Organizer email is required.' });

  // Sanitize organizer inputs to prevent HTML injection in emails
  const safeOrganizerName = stripHtml(organizerName);
  const safeOrganizerEmail = organizerEmail.trim().toLowerCase();

  if (!safeOrganizerName) return res.status(400).json({ error: 'Organizer name must contain valid text (HTML is not allowed).' });

  const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
  if (!emailRegex.test(safeOrganizerEmail)) return res.status(400).json({ error: 'Invalid organizer email format.' });

  // Verify Turnstile token
  if (!turnstileToken) {
    return res.status(400).json({ error: 'CAPTCHA verification required.' });
  }

  const turnstileResponse = await fetch(
    'https://challenges.cloudflare.com/turnstile/v0/siteverify',
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        secret: process.env.TURNSTILE_SECRET_KEY,
        response: turnstileToken,
      }),
    }
  );

  const turnstileResult = await turnstileResponse.json();

  if (!turnstileResult.success) {
    return res.status(403).json({ error: 'CAPTCHA verification failed.' });
  }

  try {
    const dbData = await withRetry(async () => {
      const pool = await getPool();

      const r1 = new sql.Request(pool);
      const drawResult = await r1
        .input('drawId', sql.UniqueIdentifier, id)
        .query(`SELECT id, emails_sent_at, deleted_at FROM Draws WHERE id = @drawId`);

      if (!drawResult.recordset.length) return null;

      const draw = drawResult.recordset[0];
      if (draw.deleted_at || draw.emails_sent_at) return { draw, matches: null };

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

      return { draw, matches: matchesResult.recordset };
    });

    if (!dbData) return res.status(404).json({ error: 'Draw not found.' });

    if (dbData.draw.deleted_at) return res.status(410).json({ error: 'This draw has been deleted.' });

    if (dbData.draw.emails_sent_at) return res.status(409).json({ error: 'Emails have already been sent for this draw.' });

    // Step 1: Check global daily email cap
    const toSend = dbData.matches!.filter((match: any) => match.giver_email);

    const dailyCount = await withRetry(async () => {
      const pool = await getPool();
      const rCap = new sql.Request(pool);
      const capResult = await rCap.query(
        `SELECT ISNULL(emails_sent, 0) AS emails_sent FROM DailyEmailLog WHERE log_date = CAST(GETUTCDATE() AS DATE)`
      );
      return (capResult.recordset[0]?.emails_sent ?? 0) as number;
    });

    if (dailyCount + toSend.length > DAILY_EMAIL_LIMIT) {
      return res.status(503).json({
        error: `The daily email limit of ${DAILY_EMAIL_LIMIT} has been reached. Please try again tomorrow.`,
      });
    }

    // Step 3: Optimistically mark emails as sent BEFORE sending
    await withRetry(async () => {
      const pool = await getPool();
      const rUpdate = new sql.Request(pool);
      await rUpdate
        .input('drawId', sql.UniqueIdentifier, id)
        .input('organizerName', sql.NVarChar(200), safeOrganizerName)
        .input('organizerEmail', sql.NVarChar(320), safeOrganizerEmail)
        .query(`
          UPDATE Draws
          SET emails_sent_at = GETUTCDATE(), organizer_name = @organizerName, organizer_email = @organizerEmail
          WHERE id = @drawId AND emails_sent_at IS NULL
        `);
    });

    // Step 4: Verify the update succeeded (optimistic lock)
    const lockCheck = await withRetry(async () => {
      const pool = await getPool();
      const rCheck = new sql.Request(pool);
      const checkResult = await rCheck
        .input('drawId', sql.UniqueIdentifier, id)
        .query(`SELECT emails_sent_at FROM Draws WHERE id = @drawId`);
      return checkResult.recordset[0];
    });

    if (!lockCheck?.emails_sent_at) {
      return res.status(500).json({ error: 'Failed to lock draw for email sending.' });
    }

    // Step 5: Send the emails
    const results = await Promise.allSettled(
      toSend.map((match: any) =>
        sendMatchEmail(match.giver_name, match.giver_email, match.receiver_name, safeOrganizerName, safeOrganizerEmail)
      )
    );

    // Step 6: Check results
    const failures = results.filter(r => r.status === 'rejected');

    if (failures.length > 0 && failures.length === toSend.length) {
      // ALL emails failed — roll back the timestamp so user can retry (don't log to daily counter)
      await withRetry(async () => {
        const pool = await getPool();
        const rRollback = new sql.Request(pool);
        await rRollback
          .input('drawId', sql.UniqueIdentifier, id)
          .query(`UPDATE Draws SET emails_sent_at = NULL WHERE id = @drawId`);
      });

      return res.status(500).json({ error: 'Failed to send emails. Please try again.' });
    }

    // Step 7: Record successfully sent emails in the daily counter
    const actualSent = toSend.length - failures.length;
    await withRetry(async () => {
      const pool = await getPool();
      const rLog = new sql.Request(pool);
      await rLog
        .input('count', sql.Int, actualSent)
        .query(`
          MERGE DailyEmailLog WITH (HOLDLOCK) AS target
          USING (SELECT CAST(GETUTCDATE() AS DATE) AS log_date) AS source
          ON target.log_date = source.log_date
          WHEN MATCHED THEN UPDATE SET emails_sent = emails_sent + @count
          WHEN NOT MATCHED THEN INSERT (log_date, emails_sent) VALUES (source.log_date, @count);
        `);
    });

    return res.status(200).json({
      success: true,
      totalSent: actualSent,
      totalFailed: failures.length,
    });
  } catch (err) {
    console.error(err);
    return res.status(500).json({ error: 'Failed to send emails. Please try again.' });
  }
}
