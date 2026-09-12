# Church Purchase & Approval System — Database

Supabase (Postgres) schema for **Phase 1: Foundation & Identity** — organizational
hierarchy, RBAC, and position-based identity mapping — plus stubbed-out
`purchase_svc` / `approval_svc` schemas that the Purchase Service and Approval
Service will build on in later phases.

## Architecture

One physical Postgres database, split into three schemas to model a decoupled
service architecture without giving up ACID guarantees:

| Schema | Owner | Exposed via Supabase Data API? | Purpose |
|---|---|---|---|
| `public` | shared | Yes | Organizations, branches, departments, banking accounts, profiles, roles, permissions, positions — read by both services, written mostly by admins |
| `purchase_svc` | Purchase Service | No — direct Postgres connection only | Requisitions, line items, status history |
| `approval_svc` | Approval Service | No — direct Postgres connection only | Workflow templates/steps, approval instances, approval actions |

Only `public` (and Supabase's own `graphql_public`) is listed under
`supabase/config.toml`'s `api.schemas`, so `purchase_svc` and `approval_svc`
are unreachable from client apps (mobile/web) by construction. Each service
gets its own least-privilege Postgres role (`svc_purchase`, `svc_approval`)
for its direct connection, with:

- Full DML on its own schema
- Read-only access to `public` (identity/org/RBAC data)
- `SELECT` on one narrow view exposed by the *other* service
  (`purchase_svc.v_public_requisition`, `approval_svc.v_public_status`) —
  never direct grants on the other service's base tables

`approval_svc.approval_instances.requisition_id` is **not** a foreign key
into `purchase_svc.requisitions`. It's treated as an opaque external
reference on purpose — that's what keeps the two schemas independently
evolvable, matching how they'd relate if they ever moved to separate
databases.

### RBAC + position-based identity mapping

Five seeded roles: `admin`, `lead_pastor`, `head_of_finance` (organization-wide),
`finance_lead` (branch-scoped), `departmental_head` (department-scoped).

The key mechanism, in `public`:

- **`positions`** — a role scoped to a specific branch/department (e.g. "Departmental
  Head, Media, Lagos HQ"). This is what workflow steps and permission checks
  point at.
- **`position_assignments`** — who currently (or historically) holds a
  position. Only one active holder per position at a time.

Approval routing (`approval_svc.v_current_approver`) and permission checks
(`public.has_permission`) always resolve through a position, never a user id
directly. Reassign `position_assignments` and every in-flight approval and
every permission check reflects the change immediately — verified locally:
reassigning the Media department's `departmental_head` position mid-flow
re-routed a pending approval instance with zero workflow config changes.

Every RBAC function ships in two forms:

- `has_permission_for(profile_id, perm_code)` / `is_admin_for(profile_id)` /
  `can_view_branch_for(...)` / `can_view_department_for(...)` — explicit
  profile id, for `svc_purchase`/`svc_approval` calling over a direct
  connection (no Supabase JWT, so no `auth.uid()`)
- `has_permission(perm_code)` / `is_admin()` / `can_view_branch(...)` /
  `can_view_department(...)` — thin wrappers around the above using
  `auth.uid()`, for RLS policies and client calls through PostgREST

The admin "permission preview" UI (shown before confirming a new position
assignment) queries `public.v_role_permission_preview`.

### RLS model

RLS is enabled on every `public` table. `authenticated` has table-level
`GRANT`s (Postgres checks grants before policies, so both are required);
`anon` gets nothing — this is an internal staff system, not public-facing.
`purchase_svc`/`approval_svc` tables also have RLS enabled with no policies,
as a deny-by-default net; the service roles bypass it entirely via
`BYPASSRLS` since they authorize in application code instead (there's no
`auth.uid()` on a direct Postgres connection for policies to key off).

## Migrations

```
supabase/migrations/
  20260712000001_extensions_and_schemas.sql   -- pgcrypto, citext, purchase_svc/approval_svc schemas
  20260712000002_core_identity_hierarchy.sql  -- org hierarchy, profiles, RBAC catalog, positions, seed data
  20260712000003_rbac_and_policies.sql        -- has_permission()/is_admin()/etc, RLS policies, preview views
  20260712000004_purchase_service.sql         -- requisitions + svc_purchase role
  20260712000005_approval_service.sql         -- workflow/approval tables + svc_approval role
```

All five have been applied and manually exercised against a local Postgres
17 instance via the Supabase CLI (`supabase db reset`) — see "What's been
verified" below.

## Setting this up on Supabase Cloud

I can't create a Supabase account or cloud project on your behalf — that
needs your own browser login. Once you've done the one-time setup below, I
(or you) can push these migrations with a single command.

1. **Create the project** (skip if you already have one):
   - Go to [supabase.com/dashboard](https://supabase.com/dashboard) → **New
     project**. Pick an org, name, database password (save it), and region
     (e.g. closest to Nigeria — `eu-west-2`/London is usually the lowest
     latency option Supabase offers).
   - Note the **Project Reference ID** (Settings → General), e.g. `abcdefghijklmnop`.

2. **Authenticate the CLI:**
   ```bash
   cd "<this project directory>"
   npx supabase login
   ```
   This opens a browser for you to approve — no token to copy/paste.

3. **Link and push:**
   ```bash
   npx supabase link --project-ref <your-project-ref>
   npx supabase db push
   ```
   This applies all five migrations to your cloud database in order.

4. **Provision the two service-account passwords** (deliberately not in
   migration files/version control):
   ```sql
   alter role svc_purchase with login password '<generate-a-strong-secret>';
   alter role svc_approval with login password '<generate-a-strong-secret>';
   ```
   Run this once via the Supabase SQL Editor (dashboard → SQL Editor) or
   `psql`. Give each backend service its own direct connection string
   (Settings → Database → Connection string) using its role name and
   password — not the pooled `postgres`/`service_role` credentials.

5. **Create your first admin position + user** so someone can actually log
   in and start configuring branches/departments through the admin UI:
   ```sql
   -- after the person signs up through Supabase Auth (so public.profiles.id exists)
   insert into public.organizations (name) values ('Your Church Name');

   insert into public.positions (id, role_id)
     select gen_random_uuid(), id from public.roles where code = 'admin';

   insert into public.position_assignments (position_id, profile_id)
     values ('<the position id above>', '<the new user''s auth.users id>');
   ```

Once linked, any future schema change just needs a new file under
`supabase/migrations/` (timestamp-prefixed, same as the existing five) and
another `supabase db push`.

## Local development

```bash
npx supabase start   # spins up local Postgres + Studio + API via Docker
npx supabase db reset  # drops and re-applies all migrations from scratch
npx supabase stop    # tears the local stack down
```

Studio runs at `http://localhost:54323` once started.

## What's been verified locally

Applied all five migrations against a real local Postgres 17 instance and
exercised, end-to-end, via `psql`:

- Seeded roles/permissions/role→permission mappings match the five named
  roles and their intended scopes.
- Creating a requisition auto-computes `total_amount` from line items and
  logs every status transition.
- A one-step approval workflow correctly resolves "who approves this right
  now" through `approval_svc.v_current_approver` by joining the workflow
  step's position against its current holder.
- **Position-based routing**: reassigning a position's holder (mid-flight,
  with a pending approval already routed to the old holder) instantly
  redirects both the permission check (`has_permission_for`) and the
  approval-routing view to the new holder — no workflow/template edits
  needed.
- RLS + grants: a `departmental_head` with no `banking.view` permission
  sees zero rows from `banking_accounts`; an `admin` sees all of them.
  `authenticated` needed explicit table `GRANT`s in addition to the RLS
  policies (Postgres checks grants first) — this is already fixed in
  migration 3.

## A note on this directory

This was scaffolded fresh under `Documents/Projects` since it's an
unrelated domain from the `sprint-audit-toolkit` repo. Mid-session, the
directory's on-disk name changed from `church-purchase-approval-system` to
`Concurrent` — the Supabase CLI's `config.toml` (`project_id`) still says
`church-purchase-approval-system`, and the Docker containers/volumes are
tagged with that name, so nothing about the actual database or CLI setup
was affected. Worth double-checking the folder name/location in Finder
once you're back at your machine, and renaming it back if you'd prefer.
