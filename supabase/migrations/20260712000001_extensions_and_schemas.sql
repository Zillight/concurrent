-- Foundation & Identity: extensions and service schemas
--
-- Architecture note: this database hosts a single ACID-compliant Postgres
-- instance, but is logically partitioned into three schemas to mirror a
-- decoupled service model:
--   public       -- shared identity, org hierarchy, and RBAC (owned by no
--                    single service; read by both Purchase and Approval)
--   purchase_svc -- owned exclusively by the Purchase Service
--   approval_svc -- owned exclusively by the Approval Service
--
-- Each service schema gets its own least-privilege Postgres role later
-- (see 20260712000004 / 20260712000005). Cross-schema access between
-- purchase_svc and approval_svc is only ever granted through narrow views,
-- never direct table grants or foreign keys -- this keeps the two services
-- independently evolvable even though they share one physical database.

create extension if not exists pgcrypto;   -- gen_random_uuid()
create extension if not exists citext;     -- case-insensitive email storage

create schema if not exists purchase_svc;
create schema if not exists approval_svc;

comment on schema public is 'Shared identity, organizational hierarchy, and RBAC. Read-only to both services.';
comment on schema purchase_svc is 'Owned by the Purchase Service: requisitions and requisition line items.';
comment on schema approval_svc is 'Owned by the Approval Service: workflow templates, steps, and approval decisions.';

-- Reusable updated_at trigger, used by every mutable table across all schemas.
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;
