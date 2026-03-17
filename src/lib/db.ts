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
  connectionTimeout: 5000,
  requestTimeout: 5000,
};

let pool: sql.ConnectionPool | null = null;

export async function getPool(): Promise<sql.ConnectionPool> {
  if (pool && !pool.connected) {
    pool = null;
  }
  if (!pool) {
    pool = await sql.connect(config);
  }
  return pool;
}

export function resetPool(): void {
  pool = null;
}

export { sql };