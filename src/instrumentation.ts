export async function register() {
  if (process.env.NEXT_RUNTIME === 'nodejs') {
    const { getPool } = await import('@/lib/db');
    getPool().catch(() => {}); // fire-and-forget, don't block startup
  }
}
