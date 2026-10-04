# TABLEFLOW backend status

The published UI is an interactive, browser-local demo. This migration is an **unapplied database foundation**, not a claim of a running or verified production backend.

Implemented database design: tenant-qualified foreign keys; Auth membership roles; RLS; permanent table QR tokens; hashed visit bearer tokens; a unique open session per table; atomic server-priced ordering; idempotency keys; guarded status transitions; staff-only session closure; subscription/module/payment-event tables.

Production completion requires:
1. A user-owned Supabase project and applying/reviewing the migration in staging.
2. Tenant bootstrap and Auth provisioning; a trusted operator inserts platform administrators. Do not grant platform-admin provisioning to browsers.
3. A secure server adapter and authenticated UI wiring. Never expose a service-role key. The current workspace selector is explicitly demo navigation, not authentication.
4. Public-menu RPC, service-request RPC, session join mechanism for multiple diners, guest request throttling, and authenticated subscription integration.
5. Realtime publication setup and two-tenant adversarial RLS tests, including cross-tenant inserts and updates, expired visits, concurrent QR scans, retries, and unauthorized status updates.
6. Payment-provider integration, verified webhook signatures, currency and amount validation, idempotency and settlement records. No payments are currently processed. Prices and taxes in the demo are illustrative.
7. PWA installation/offline strategy and a final test on target phones. The manifest is supplied, but offline ordering is not enabled.

Do not point the demo at real operations until these steps are complete. No database or external accounts were created by this implementation.

## Selected project and local POS preference

Project URL supplied by the owner: https://auilicfdkfyxgexeqqfc.supabase.co

No publishable key or management access was supplied. No schema was applied and no connection is claimed. Next provide the project publishable key through configuration and apply/review the schema in staging.

The local POS UI now lets the operator create a username and 6–12 digit PIN for the current browser. The stored credential is a salted PBKDF2 verifier, not a plaintext PIN. Unlock state lives only in component memory, with manual lock and 15-minute idle lock. This is explicitly a device-local privacy feature; it can be bypassed by someone controlling that browser/storage. It does not authenticate Supabase users or authorize tenant operations. Before wiring cloud data, provision trusted devices and verify staff credentials/roles server-side behind the same simple POS interface. No Google or email sign-in UI is requested.
