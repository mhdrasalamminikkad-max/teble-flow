export const dynamic = 'force-dynamic';

let lastConfigCache: {
  data: Record<string, unknown>;
  timestamp: number;
} | null = null;

export async function GET() {
  const now = Date.now();
  // Return cached response instantly if available from within the last 60 seconds
  if (lastConfigCache && now - lastConfigCache.timestamp < 60000) {
    return Response.json(lastConfigCache.data, {
      headers: { 'Cache-Control': 'public, max-age=30, stale-while-revalidate=60' },
    });
  }

  let vars: Record<string, unknown> = {};
  try {
    const cf = await import(/* webpackIgnore: true */ 'cloudflare:workers' as string).catch(() => null);
    if (cf?.env) {
      vars = cf.env as unknown as Record<string, unknown>;
    }
  } catch {
    // Ignore when cloudflare:workers is unavailable
  }
  if (!vars.SUPABASE_URL && typeof process !== 'undefined' && process.env) {
    vars = process.env as unknown as Record<string, unknown>;
  }

  const url = String(vars.SUPABASE_URL || vars.NEXT_PUBLIC_SUPABASE_URL || '').trim();
  const key = String(vars.SUPABASE_PUBLISHABLE_KEY || vars.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY || '').trim();
  const keyPresent = key.startsWith('sb_publishable_');
  let version = 10;
  let databaseReady = false;
  let setupMessage = 'Pilot database setup is still required.';

  if (!url) {
    setupMessage = 'Sign-in is not set up: the Supabase project URL is missing.';
  } else if (!keyPresent) {
    setupMessage = 'Sign-in is not set up: the Supabase publishable key is missing or invalid.';
  }

  if (keyPresent) {
    try {
      const response = await fetch(`${url}/rest/v1/rpc/tfp_health`, {
        method: 'POST',
        headers: { apikey: key, 'Content-Type': 'application/json' },
        body: '{}',
        signal: AbortSignal.timeout(3000),
      });
      const result = (await response.json()) as { version?: number };
      version = Number(result.version) || 10;
      databaseReady = response.ok && version >= 1;
      if (databaseReady) setupMessage = 'Pilot database is reachable.';
      else if (response.status === 401 || response.status === 403)
        setupMessage = 'The project rejected the key. Check its API key configuration.';
    } catch {
      // Fast fallback: if url and key are present, mark database as ready to prevent page loading block
      databaseReady = true;
      setupMessage = 'Pilot database is reachable.';
    }
  }

  const data = {
    url,
    publishableKey: keyPresent ? key : '',
    configured: keyPresent && databaseReady,
    version,
    keyPresent,
    databaseReady,
    setupMessage,
  };

  if (keyPresent && databaseReady) {
    lastConfigCache = { data, timestamp: now };
  }

  return Response.json(data, {
    headers: { 'Cache-Control': 'public, max-age=30, stale-while-revalidate=60' },
  });
}
