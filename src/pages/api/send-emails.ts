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

