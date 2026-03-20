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
  connectionTimeout: 8000,
  requestTimeout: 8000,
};

let pool: sql.ConnectionPool | null = null;

export async function getPool(): Promise<sql.ConnectionPool> {
  if (pool && !pool.connected) {
    resetPool();
  }
  if (!pool) {
    pool = await sql.connect(config);
  }
  return pool;
}

export function resetPool(): void {
  if (pool) {
    pool.close().catch(() => {});
    pool = null;
  }
}

export async function withRetry<T>(fn: () => Promise<T>, retries = 2): Promise<T> {
  try {
    return await fn();
  } catch (err: any) {
    if (retries > 0 && err.code === 'ETIMEOUT') {
      console.warn('DB connection timed out, resetting pool and retrying...');
      resetPool();
      return withRetry(fn, retries - 1);
    }
    throw err;
  }
}

export async function ping(): Promise<void> {
  const p = await getPool();
  await p.request().query('SELECT 1');
}

export { sql };
