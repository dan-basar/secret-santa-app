import type { NextApiRequest, NextApiResponse } from 'next';
import { getPool, sql } from '@/lib/db';

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

