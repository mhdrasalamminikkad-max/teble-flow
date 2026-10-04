export const dynamic = 'force-dynamic';

export async function GET() {
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
  let version = 0;
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
        signal: AbortSignal.timeout(6000),
      });
      const result = (await response.json()) as { version?: number };
      version = Number(result.version) || 0;
      databaseReady = response.ok && version >= 1;
      if (databaseReady) setupMessage = 'Pilot database is reachable.';
      else if (response.status === 401 || response.status === 403)
        setupMessage = 'The project rejected the key. Check its API key configuration.';
    } catch {
      setupMessage = 'Could not reach the project. Retry after checking the connection.';
    }
  }

  return Response.json(
    {
      url,
      publishableKey: keyPresent ? key : '',
      configured: keyPresent && databaseReady,
      version,
      keyPresent,
      databaseReady,
      setupMessage,
    },
    { headers: { 'Cache-Control': 'no-store' } }
  );
}
