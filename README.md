# TABLEFLOW

Mobile-first dining application with a deep-green, cream and lime visual system.

## Working demo
- Customer: menu search and filters, dish customisation, quantity controls, persistent bag, orders, preparation status, live bill and service requests.
- Restaurant: floor overview, order workflow, kitchen display, menu availability and creation, permanent table QR downloads, visit closure, team records, settings and CSV order export.
- Super admin: sample restaurant network, restaurant creation, subscription plan and module toggles, demo user records and recurring-revenue summaries.
- Browser-local persistence and same-browser tab updates. No live restaurant orders, payments, authentication or cross-device synchronization.

Routes: `/`, `/cart`, `/orders`, `/bill`, `/service`, `/restaurant/overview`, `/restaurant/orders`, `/restaurant/kitchen`, `/restaurant/menu`, `/restaurant/tables`, `/restaurant/analytics`, `/restaurant/staff`, `/restaurant/settings`, `/super-admin/overview`, `/super-admin/restaurants`, `/super-admin/subscriptions`, `/super-admin/modules`, `/super-admin/revenue`, `/super-admin/users`, `/super-admin/settings`.

Use Workspaces in the header to switch perspectives. To test a visit: add a dish, place the order, move it through Restaurant → Kitchen display, view the customer bill, request payment, then close the session in Restaurant → Tables & QR. Start a fresh visit in the customer screen; previous orders stay in restaurant history.

## Source and backend
React / TypeScript / Vinext, Radix/Shadcn controls and Lucide icons. QR PNGs generated locally with qrcode. See `supabase/README.md` for the unapplied database foundation and the remaining production work. Figma extraction was blocked by the user's Starter MCP call limit, so this build follows recovered brand and functional requirements rather than claiming an exact Figma match.

## Image sources
Demo photography only; replace with restaurant-owned/licensed product photographs before commercial launch.
- Biryani: https://www.copperchimney.co.nz/assets/images/biryani.png
- Grilled chicken: https://www.taqashimandi.com/assets/images/about/02-flame.jpeg
- Lime and mint: https://www.nomooo.jp/imgs/p/27f1-qqd9Hzg_NUzBXvtYA2auJeWlZSTkpGQ/32569.jpg

## Validation
TypeScript compilation and production build passed. Browser tests covered order placement (₹338 subtotal, ₹354.90 with 5% demo tax), kitchen status updates, the 390px responsive layout, bill requests, QR rendering, visit closure and a fresh visit's empty bill. Structured WebMCP tools are feature-detected; the available browser did not expose modelContext, so tool execution could not be validated. The Supabase SQL has not been executed or security-tested against a live project.

## October responsiveness update

Screen switches use local React state and hash history rather than server navigation; the mounted cart and visit remain intact. Saved state is schema-validated, invalid data is backed up under `tableflow-demo-v1-recovery`, and writes are batched after interactions. Order submission reads the latest state and rejects closed visits, unavailable dishes and price changes. Repeat submission of the consumed bag is a no-op. QR generation is loaded on demand with progress and retry feedback. Currency formatting is reused and menu images decode asynchronously.

Mobile app features include safe-area navigation, install guidance, manifest icons and an offline fallback. This is an installable web app, not an app-store native binary. No orders are queued for a production server while offline.

Validation: `npx tsc --noEmit` and `node --test tests/tableflow.test.mjs` (six tests). The current update has not received a fresh real-browser performance or accessibility audit because browser verification tooling was unavailable. Production operation still requires Supabase provisioning, authenticated roles, tenant isolation verification, real-time integration, device/session isolation and end-to-end/load testing. Runtime environment configuration was empty during this update. Do not use the local demo to serve real diners.

## Local POS and mobile overflow update

Staff workspace entry now uses a browser-local username and PIN setup/unlock screen, manual locking and a 15-minute inactivity lock. It remains a local privacy lock, not Supabase authentication. The site audience remains owner-private. Customer menu entry is unchanged.

Responsive fixes address card min-content sizing, wrapping price/add controls, long notes and headings, cart quantities, service grids, dialogs and admin grids. Table scrolling stays within its own container. No global overflow clipping is used to conceal oversized controls. TypeScript and eight focused logic tests passed; fresh phone/browser visual verification remains pending because the required browser-control capability is unavailable.

## Connected three-table pilot

`/pilot` is the opt-in live backend path; it fails closed until `SUPABASE_PUBLISHABLE_KEY` is configured. `SUPABASE_URL` points to the user-supplied project. The main app remains the demo. The pilot implements server-verified POS PINs, scoped kitchen snapshots, status updates, permanent table QR links plus rotating visit codes, per-device draft bags, server-priced idempotent ordering, visit-specific bills, confirmed settlement and Realtime refresh signals with a three-second polling fallback.

Use `supabase/002_live_pilot.sql` (standalone, unapplied) and `supabase/PILOT_RUNBOOK.md` for activation and the physical-device acceptance sheet. No actual restaurant, real menu, staff credentials or live database records have been created. The local SQL tests use PostgreSQL in PGlite with pgcrypto, not the user's remote project. Physical-device/network/concurrent-process testing and the restaurant pilot remain pending. The owner's Site sharing policy has not changed.

## Workspace redesign and operations

The live `/login` portal now includes platform and restaurant navigation, an overview, invoice and payment tracking, restaurant activation controls, guest feedback follow-up, and manager-only table and staff controls. Guest reviews are submitted from the live bill screen. Ratings of three stars or below are flagged while unresolved. Google reviews can be logged manually; automatic Google synchronization is not implemented.

Apply `supabase/006_operations.sql` after `004_restaurant_admin.sql` to enable the new server operations (health version 3). It does not reset credentials. This migration has not been applied to a remote database in this session. The UI keeps existing kitchen and provisioning tools available on older database versions. Configure the existing Supabase environment bindings for connected use; no demo revenue or restaurant records are substituted for live data.

Visual changes cover the scanner landing page, sign-in, dining, kitchen, menu settings and new management workspaces. Warm paper backgrounds, pine navigation, restrained terracotta accents, serif headings and responsive card/table layouts replace the previous styling. Preview with `npm run dev` at http://localhost:5173.

Validation: TypeScript, production build and 14 existing client/QR/order/privacy-lock tests passed. Live database mutation tests and authenticated dashboard visual verification require a configured backend; these are not claimed as complete.

## Mobile-style workspace and exclusive QR access

The owner/admin workspace now opens with large function cards and a bottom navigation dock. Each card opens its tool with a Home return button. Diners have a matching Home screen for menu, bag, order tracking and bill/feedback.

Apply `supabase/007_exclusive_qr.sql` once in the Supabase SQL Editor, after migration 006. This requires the project owner's SQL access; a publishable API key cannot execute migrations. The update advertises health version 4. Until installed, the new diner screen reports that QR access is awaiting its database update rather than showing a nonfunctional code-free flow.

Staff still open and settle table visits. Diners scan the permanent QR without entering a visit code. A new guest token revokes the previous device for that visit, without deleting orders or creating a new bill. The old screen changes to a session-ended page through Realtime or the three-second visible-page polling fallback; background/offline screens update when they reconnect. Browsers cannot forcibly close a tab opened by the diner. Server checks deny revoked devices' order and review requests even before their screen refreshes. Retrying an old claim never steals access back. Rescanning through the built-in scanner starts a new guest token.

The migration ends pre-upgrade guest access, so apply between services and have diners rescan. Code-based entry is disabled server-side. Possession of the permanent table QR now permits takeover, as requested; do not share table QR links publicly.

Validation: six PostgreSQL/WASM tests cover code-free claims, revoked reads/orders/reviews, preserving existing orders, disabling legacy code entry, independent tables, invalid tokens, and single-active-guest behavior. These local tests do not substitute for a two-phone Realtime/network test against the remote project.

## Owner login management and automatic pending invoices

Apply `supabase/008_owner_access_billing.sql` after 007, then reload the app (health version 5). Platform admin → Restaurants shows a login button for each manager account. Admins can rename the account or set a new password; leaving the password blank preserves it. Existing passwords/hashes are never returned. Saving invalidates that owner's sessions and writes an audit entry without storing the plaintext password.

Pending invoices are generated server-side whenever the admin or owner operations workspace loads or refreshes. This is automatic catch-up on access, not a scheduled background job or automatic collection. Existing contracts start automation on the migration date; new contracts start on creation. Monthly invoices use calendar months (no proration), first due date is seven days after start, later months seven days after month start, and setup is issued once. Free plans and currently paused restaurants are skipped; reactivated restaurants catch up missing months since their billing start. Previously issued invoices and payments are preserved. Partial payments reduce the balance and overdue labels use the India calendar date. No messages or payment reminders are sent.

Validation: six database tests cover admin authorization, owner-session invalidation, retaining a password when blank, duplicate-free automatic billing, catch-up, free plans, partial payments, and denial of direct anonymous access. The migration still needs to be applied to the live project by an authorized database operator.

## Restaurant roles and service workspaces

Apply `supabase/009_restaurant_roles.sql` after 008 and reload the app (health version 6). Until then, existing restaurant screens remain available and the login page explains the missing upgrade. This file has been tested locally, not installed remotely by this chat.

Restaurant code is entered once on a device, remembered per backend project, and can be changed at sign-in. Each staff member signs in with their username and password. New/reset restaurant passwords require at least six ASCII letters/numbers, including at least one letter and one number (maximum 72 bytes). Existing passwords remain valid. Restaurant sessions are remembered in browser storage and have no timed expiry; logout, disabling an account, changing credentials/roles, pausing the restaurant, or clearing browser storage ends access. Platform-admin session expiry is unchanged.

The original restaurant owner retains every tool. Restaurant Admin creates named roles and checks Dashboard, Kitchen, Waiter, Biller, Menu and/or Feedback permissions, then assigns users. Admin/role-management privileges remain reserved to the original owner. Permissions are checked in server RPCs, not just navigation. Editing a role signs its members out. Disabling or editing a user revokes that user's sessions.

Kitchen: table-numbered tickets and guarded Placed → Preparing → Ready → Served progression. Waiter: active/available tables, opening visits, QR downloads, order and bill details, served action, and guest requests at the top. Auto order sorts occupied tables oldest visit first, with free tables after them; manual mode uses table number. Requests update through visible-page polling every three seconds. Guests can ask for water, cutlery, a waiter or bill help from their Home screen; duplicate unresolved requests are deduplicated.

Biller: live and recently settled table bills (last seven days), receipt print preview, header/footer text, 58mm/80mm/A4 layout and optional tax breakdown. Totals remain server-derived and cannot be edited as a layout choice. The operator selects matching paper in the printer dialog. Settlement requires all dishes served and the confirmed current total. Restaurant Admin also includes table enable/disable controls, subscription pending amounts and payment history. Dashboard shows service counts and recent settlements; Feedback supports internal follow-up and resolution.

Validation: TypeScript and production build; 35 tests pass across client flows and PostgreSQL/WASM migrations, including permission denial, tenant isolation, persistent-session revocation, service-request deduplication, password rules, bill formats and settlement totals. Remote two-device/physical-printer verification remains to be done after applying 009. No staff credentials or roles were changed in the live project during implementation.

## Username-only restaurant sign-in

Update 010 supersedes the one-time restaurant-code setup. Apply `supabase/010_username_login.sql` after 009 and refresh (health version 7). Staff enter only a username and password; restaurant routing is resolved on the server. The restaurant-code input, remembered device code and provisioning code field are removed. New restaurant records receive an internal identifier automatically; it is not a login credential.

New/renamed staff usernames must be unique across restaurants, ignoring case. Existing duplicates are not silently renamed: login refuses ambiguous active accounts until platform admin/restaurant owners assign unique usernames using the existing access controls. Passwords, role permissions and persistent sessions remain intact. Four local database tests cover duplicate handling, username-only tenant routing, incorrect credentials, inactive accounts and session revocation.
