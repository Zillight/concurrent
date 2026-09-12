-- Approval Service: workflow configuration and approval decisions, owned
-- exclusively by approval_svc. Same isolation model as purchase_svc: not
-- exposed via the Data API, reached only over a direct Postgres connection
-- as the `svc_approval` role.
--
-- Position-based routing lives here: every workflow_steps row points at a
-- public.positions row, never at a public.profiles row. Resolving "who
-- approves this right now" always goes through public.v_active_position_holders,
-- so reassigning a position instantly redirects every in-flight approval.

create table approval_svc.workflow_templates (
  id          uuid primary key default gen_random_uuid(),
  branch_id   uuid references public.branches(id),  -- null = organization-wide default template
  name        text not null,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table approval_svc.workflow_steps (
  id           uuid primary key default gen_random_uuid(),
  template_id  uuid not null references approval_svc.workflow_templates(id) on delete cascade,
  step_order   int not null check (step_order > 0),
  position_id  uuid not null references public.positions(id),
  min_amount   numeric(14,2),
  max_amount   numeric(14,2),
  unique (template_id, step_order),
  check (min_amount is null or max_amount is null or min_amount <= max_amount)
);

-- requisition_id is deliberately NOT a foreign key to purchase_svc.requisitions.
-- Treating it as an opaque external reference keeps the two service schemas
-- independently evolvable -- exactly what "decoupled service model" calls
-- for, even though both currently live in one physical database for ACID
-- guarantees during the Foundation phase.
create table approval_svc.approval_instances (
  id             uuid primary key default gen_random_uuid(),
  requisition_id uuid not null unique,
  template_id    uuid not null references approval_svc.workflow_templates(id),
  current_step   int not null default 1,
  status         text not null default 'pending'
                 check (status in ('pending', 'approved', 'rejected', 'cancelled')),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create table approval_svc.approval_actions (
  id                   uuid primary key default gen_random_uuid(),
  approval_instance_id uuid not null references approval_svc.approval_instances(id) on delete cascade,
  step_order           int not null,
  position_id          uuid not null references public.positions(id),
  acted_by             uuid not null references public.profiles(id),
  action               text not null check (action in ('approved', 'rejected', 'delegated')),
  comment              text,
  acted_at             timestamptz not null default now()
);

create trigger set_updated_at before update on approval_svc.workflow_templates
  for each row execute function public.set_updated_at();
create trigger set_updated_at before update on approval_svc.approval_instances
  for each row execute function public.set_updated_at();

-- Advance current_step (or close out the instance) whenever an action is recorded.
create or replace function approval_svc.advance_approval_instance()
returns trigger
language plpgsql
as $$
declare
  total_steps int;
begin
  if new.action = 'rejected' then
    update approval_svc.approval_instances set status = 'rejected' where id = new.approval_instance_id;
    return new;
  end if;

  select count(*) into total_steps
  from approval_svc.workflow_steps ws
  join approval_svc.approval_instances ai on ai.template_id = ws.template_id
  where ai.id = new.approval_instance_id;

  update approval_svc.approval_instances
  set status = case when current_step >= total_steps then 'approved' else 'pending' end,
      current_step = least(current_step + 1, total_steps)
  where id = new.approval_instance_id;

  return new;
end;
$$;

create trigger advance_on_approval_action
  after insert on approval_svc.approval_actions
  for each row execute function approval_svc.advance_approval_instance();

-- A narrow, read-only contract for the Purchase Service: just enough to
-- show approval progress on a requisition, without exposing the full
-- workflow configuration or action history. Deliberately NOT
-- security_invoker -- see purchase_svc.v_public_requisition for why.
create view approval_svc.v_public_status as
select
  requisition_id, status, current_step
from approval_svc.approval_instances;

-- The heart of position-based routing: resolve "who approves this, right
-- now" for every pending approval by joining the step's position against
-- whoever currently holds it. If the position's holder changes tomorrow,
-- this view reflects that automatically with zero workflow changes.
create view approval_svc.v_current_approver
  with (security_invoker = true) as
select
  ai.id as approval_instance_id,
  ai.requisition_id,
  ai.current_step as step_order,
  ws.position_id,
  vaph.role_code,
  vaph.profile_id,
  vaph.full_name,
  vaph.email
from approval_svc.approval_instances ai
join approval_svc.workflow_steps ws
  on ws.template_id = ai.template_id and ws.step_order = ai.current_step
left join public.v_active_position_holders vaph on vaph.position_id = ws.position_id
where ai.status = 'pending';

-- ── Service role & grants ───────────────────────────────────────────────
-- See purchase_svc's migration for the rationale behind NOLOGIN/BYPASSRLS.

create role svc_approval nologin bypassrls;

alter table approval_svc.workflow_templates   enable row level security;
alter table approval_svc.workflow_steps       enable row level security;
alter table approval_svc.approval_instances   enable row level security;
alter table approval_svc.approval_actions     enable row level security;

grant usage on schema approval_svc to svc_approval;
grant all on all tables in schema approval_svc to svc_approval;
alter default privileges in schema approval_svc grant all on tables to svc_approval;

grant usage on schema public to svc_approval;
grant select on
  public.organizations, public.branches, public.departments, public.banking_accounts,
  public.profiles, public.roles, public.permissions, public.role_permissions,
  public.positions, public.position_assignments
  to svc_approval;
grant execute on function
  public.has_permission_for(uuid, text),
  public.is_admin_for(uuid),
  public.can_view_branch_for(uuid, uuid),
  public.can_view_department_for(uuid, uuid)
  to svc_approval;

-- Cross-service contracts, granted narrowly in both directions.
grant select on approval_svc.v_public_status to svc_purchase;
grant select on purchase_svc.v_public_requisition to svc_approval;
