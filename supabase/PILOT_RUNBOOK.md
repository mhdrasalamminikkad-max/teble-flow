# TABLEFLOW: three-table pilot

## Current status

Implementation prepared; activation and physical trial **not completed**.

Project: https://auilicfdkfyxgexeqqfc.supabase.co
Site entry: `/pilot`; staff POS: `/pilot?staff=1`.

The existing demo is intentionally separate. An unavailable backend never falls back to fake successful orders. The published Site remains owner-private; customer phones need an explicitly approved access arrangement before the trial. Do not share the owner's sign-in credentials.

## Activation, by the project owner

1. The owner-supplied publishable key and project URL are now configured as `SUPABASE_PUBLISHABLE_KEY` and `SUPABASE_URL`. The app checks the database health RPC before enabling the pilot. No secret key is needed in browser code.
2. Review and apply `002_live_pilot.sql` once in a staging Supabase project first. It is standalone and does not depend on `001_foundation.sql`. It creates an isolated `tableflow_pilot` schema and narrow public RPCs. Do not blindly re-run it after partial manual changes.
3. From the trusted SQL editor, provision one restaurant with a real name, a slug and a unique 8–12 digit manager PIN. Do not paste the PIN in chat or commit it to source. Example shape (replace every placeholder):

   `select tableflow_pilot.provision('RESTAURANT NAME','restaurant-slug','manager-username','YOUR_8_TO_12_DIGIT_PIN');`

   The returned UUID identifies the restaurant. Three table records and permanent random QR tokens are created. There is no default account or default PIN.
4. Load the actual menu into `tableflow_pilot.menu`: restaurant UUID, name, description, price in INR, category, veg, image URL and availability. Verify prices and tax before any diners use it. The code does not silently seed demo dishes into the live restaurant.
5. Create additional staff through trusted SQL only using `tableflow_pilot.pin_hash(...)`; assign `kitchen` or `waiter`, not manager unless needed. The local-looking POS form verifies credentials on the database server. Revoking a staff record's `active` flag invalidates its sessions on subsequent requests.
6. Confirm `public.tfp_signals` is in `supabase_realtime`. This table contains only an unrelated opaque UUID and a revision counter, readable by anonymous clients. Order records, guest tokens, restaurant identities, PIN hashes and visit codes are never published through this table. The change event triggers an authorized snapshot fetch. A three-second polling fallback refreshes after missed events.
7. Apply an explicitly chosen Site access policy so the intended test devices can enter. Keep the audience unchanged until the owner approves the intended viewers.
8. Run the staging scenarios below before enabling real ordering at the restaurant.

## Table operation

- Staff sign in with restaurant code, username and PIN. The session lasts at most eight hours and the UI locks after 15 minutes of inactivity.
- Open table 1, 2 or 3. Download and print that table's permanent QR.
- Give its current eight-digit visit code to the diners. Each device scans the QR and enters the code, receives its own guest token, and keeps its own bag. All diners at that visit see the same table bill.
- Kitchen updates tickets from Placed → Preparing → Ready → Served. A waiter can only mark Ready tickets Served.
- Manager confirms counter payment and closes the visit. Closure is refused until all tickets are served. Online payments are outside this pilot.
- The next visit gets a new ID and join code. Old guest tokens cannot submit new orders. An old already-accepted request can still be acknowledged safely after closure.
- Never clear browser storage while an order says confirmation needed. Reconnect and use Retry same order, which retains the exact request ID and payload.

## Real-device acceptance sheet (all pending)

Use two customer phones (include the Samsung/Android target device) and one separate kitchen device. Run on both restaurant Wi-Fi and mobile data. Record actual device, browser, network, time and ticket IDs. No timings below are measured results; they are trial targets.

| Scenario | Expected result | Actual result |
|---|---|---|
| 320/360/390/412 px widths, portrait and landscape | No horizontal page overflow; every control reachable | Pending |
| Tap navigation, Add, quantity | Visible feedback within 200 ms on target phones | Pending |
| Simultaneous orders from tables 1–3 | Correct restaurant, table, items, notes and price | Pending |
| Two diners at the same table | Independent bags; combined visit bill | Pending |
| Ten rapid taps on Place order | Exactly one confirmed ticket | Pending |
| Disconnect immediately after placing | Unconfirmed state; reconnect/retry yields exactly one ticket | Pending |
| Kill/reopen the tab during an uncertain submission | Verify browser session restoration; do not assume recovery after sessionStorage is cleared | Pending |
| Disable Realtime, retain HTTP | Polling recovers updates; no missing orders | Pending |
| Disable all networking | Offline warning; no false order confirmation | Pending |
| Kitchen event latency | Target ≤2 seconds on good Wi-Fi; fallback about 3 seconds plus request time | Pending |
| Close visit and scan again | New code/visit; empty new bill; old token blocked | Pending |
| Wrong restaurant staff token | No reads or updates across tenants | Pending |
| Missing/changed price, sold-out dish | Rejected by server; bag remains for review | Pending |
| Lost login, expired or revoked staff session | No privileged read/write; sign in again | Pending |
| Bill and counter settlement | Match independent manual total | Pending |

## Pilot schedule and stop conditions

First run a staff-only rehearsal with clearly identified test orders and no food preparation. After all acceptance rows pass, run one supervised service period at two tables. Add the third only after ticket and bill reconciliation succeeds. Keep the existing manual/POS ordering process available.

Stop immediately for a missing, duplicate, cross-table or incorrectly priced order; stop if staff cannot distinguish accepted from uncertain orders. Reconcile kitchen tickets and manual records before resuming. Do not send duplicate replacement orders merely because an acknowledgment was lost.

At the end, compare submitted request IDs, kitchen tickets, fulfilled items and manual receipts; record median/slowest observed latency and every issue. Approve a wider launch only after fixes and a clean repeat trial.

## Checks run in the development environment

- TypeScript validation and production build (see latest delivery for completion).
- Existing demo/state and local-lock tests.
- Client transport tests for lost responses, exact retry payloads, corrupt pending bags and bill arithmetic.
- Database SQL executed using PostgreSQL in PGlite with the real pgcrypto extension. Tests cover two tenants, repeated requests, multiple diner tokens, prices/quantities, visit turnover, PIN lockout, revocation, private schema permissions and lifecycle transitions.

PGlite runs one PostgreSQL engine in WASM and serializes queries. Promise-based repeat submissions are **not** a distributed/concurrent Supabase load test. These tests do not verify remote RLS configuration, Realtime delivery, physical phones, restaurant operations or production response times. Required browser-control tooling was unavailable in this session.

To repeat SQL checks, install `@electric-sql/pglite` into a scratch test directory and run `PGLITE_MODULE_ROOT=/absolute/path/to/node_modules/@electric-sql/pglite node --test tests/pilot-database.test.mjs` from the repository.

## Ready-to-run rehearsal bootstrap

After applying `002_live_pilot.sql`, run `003_pilot_rehearsal.sql` once. It provisions the restaurant code `tableflow-rehearsal`, three tables and explicitly marked TEST dishes, plus manager and kitchen logins. The SQL result contains newly generated PINs; save them privately. No fixed/default PIN exists in the source.

Open `/pilot?staff=1` on the kitchen device and sign in using one of those credentials. Use the manager account to open tables and download QR codes. Run the acceptance sheet with no food preparation or payment. This bootstrap is for rehearsal only; load a real restaurant's verified details, menu, staff and tax configuration separately before a supervised customer pilot.

Remote check during this change: the supplied project accepted the publishable-key request and returned `PGRST202` / HTTP 404 for `tfp_login`, confirming the pilot RPC was not present in its schema cache. No SQL or live records were written remotely by the assistant.
