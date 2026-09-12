-- Purchase Service: requisition data, owned exclusively by purchase_svc.
--
-- This schema is not exposed through the Supabase auto-generated API
-- (only `public` is listed under API > Data API > Exposed schemas by
-- default). The Purchase Service backend reaches it over a direct
-- Postgres connection as the `svc_purchase` role, calling the shared
-- public.*_for() authorization functions to enforce RBAC in application
-- code rather than relying on PostgREST-driven RLS.

create table purchase_svc.requisitions (
  id                 uuid primary key default gen_random_uuid(),
  requisition_number text not null unique,
  branch_id          uuid not null references public.branches(id),
  department_id      uuid not null references public.departments(id),
  requested_by       uuid not null references public.profiles(id),
  title              text not null,
  description        text,
  currency           text not null default 'NGN',
  total_amount       numeric(14,2) not null default 0,
  banking_account_id uuid references public.banking_accounts(id),
  status             text not null default 'draft'
                     check (status in ('draft', 'submitted', 'in_review', 'approved',
                                        'rejected', 'cancelled', 'fulfilled')),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

create table purchase_svc.requisition_items (
  id             uuid primary key default gen_random_uuid(),
  requisition_id uuid not null references purchase_svc.requisitions(id) on delete cascade,
  item_name      text not null,
  quantity       numeric(10,2) not null default 1 check (quantity > 0),
  unit_price     numeric(14,2) not null default 0 check (unit_price >= 0),
  line_total     numeric(14,2) generated always as (quantity * unit_price) stored,
  notes          text,
  created_at     timestamptz not null default now()
);

create table purchase_svc.requisition_status_history (
  id             uuid primary key default gen_random_uuid(),
  requisition_id uuid not null references purchase_svc.requisitions(id) on delete cascade,
  from_status    text,
  to_status      text not null,
  changed_by     uuid references public.profiles(id),
  changed_at     timestamptz not null default now(),
  note           text
);

-- Keep requisitions.total_amount in sync with its line items.
create or replace function purchase_svc.recalc_requisition_total()
returns trigger
language plpgsql
as $$
declare
  affected_requisition uuid := coalesce(new.requisition_id, old.requisition_id);
begin
  update purchase_svc.requisitions
  set total_amount = coalesce(
        (select sum(line_total) from purchase_svc.requisition_items where requisition_id = affected_requisition),
        0)
  where id = affected_requisition;
  return null;
end;
$$;

create trigger recalc_total_on_item_change
  after insert or update or delete on purchase_svc.requisition_items
  for each row execute function purchase_svc.recalc_requisition_total();

-- Record every status transition for audit/cycle-time reporting.
create or replace function purchase_svc.log_status_change()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'INSERT' or new.status is distinct from old.status then
    insert into purchase_svc.requisition_status_history (requisition_id, from_status, to_status)
    values (new.id, case when tg_op = 'INSERT' then null else old.status end, new.status);
  end if;
  return new;
end;
$$;

create trigger log_requisition_status_change
  after insert or update on purchase_svc.requisitions
  for each row execute function purchase_svc.log_status_change();

create trigger set_updated_at before update on purchase_svc.requisitions
  for each row execute function public.set_updated_at();

-- A narrow, read-only contract for the Approval Service: just enough to
-- route and display a requisition, without granting access to the full
-- purchase_svc schema. No physical foreign key crosses the service
-- boundary -- requisition_id is treated as an opaque external reference
-- by approval_svc, matching how these services would relate if split
-- into separate databases later.
--
-- Deliberately NOT security_invoker: this view's contract is "whatever
-- columns/rows are defined here", independent of the querying service's
-- own grants on the base table. Runs with the view owner's rights, and
-- access is controlled purely by the GRANT SELECT on the view below.
create view purchase_svc.v_public_requisition as
select
  id, requisition_number, branch_id, department_id, requested_by,
  total_amount, currency, status
from purchase_svc.requisitions;

-- ── Service role & grants ───────────────────────────────────────────────
--
-- NOLOGIN by design: this migration only shapes the role's privileges.
-- Grant LOGIN and set a password out-of-band (Supabase SQL editor or
-- `supabase secrets`), never in a committed migration file, e.g.:
--   alter role svc_purchase with login password '<rotate-me>';
--
-- BYPASSRLS: the service connects directly to Postgres, not through
-- PostgREST, so there is no Supabase JWT and therefore no auth.uid() for
-- the public.*_for() functions or per-row policies to key off. The service
-- is expected to call public.has_permission_for(...) itself with the
-- acting user's profile id before writing. RLS stays enabled on this
-- schema's tables purely as a deny-by-default net for any other role
-- (e.g. anon/authenticated, if purchase_svc were ever accidentally
-- exposed through the Data API) -- it has no effect on svc_purchase.

create role svc_purchase nologin bypassrls;

alter table purchase_svc.requisitions             enable row level security;
alter table purchase_svc.requisition_items        enable row level security;
alter table purchase_svc.requisition_status_history enable row level security;

grant usage on schema purchase_svc to svc_purchase;
grant all on all tables in schema purchase_svc to svc_purchase;
alter default privileges in schema purchase_svc grant all on tables to svc_purchase;

-- Read-only access to shared identity/org/RBAC data, and the ability to run
-- the same authorization checks the client-facing RLS policies use.
grant usage on schema public to svc_purchase;
grant select on
  public.organizations, public.branches, public.departments, public.banking_accounts,
  public.profiles, public.roles, public.permissions, public.role_permissions,
  public.positions, public.position_assignments
  to svc_purchase;
grant execute on function
  public.has_permission_for(uuid, text),
  public.is_admin_for(uuid),
  public.can_view_branch_for(uuid, uuid),
  public.can_view_department_for(uuid, uuid)
  to svc_purchase;
