import type { NextApiRequest, NextApiResponse } from 'next';
import { getPool, sql } from '@/lib/db';

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

