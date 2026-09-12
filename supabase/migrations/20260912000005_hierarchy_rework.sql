-- Phase 4: Hierarchy rework — the real org model
--
--   member (view only, dept seats via department_members)
--   leader_3 (dept head, creates) -> leader_2 (covers a set of depts)
--     -> leader_1 (branch pastor) -> head_of_finance -> lead_accountant dispenses
--   senior_pastor can approve ANY pending requisition directly.
--
-- Structural changes:
--   * roles.level          — chain height, drives "start above the creator"
--   * roles.scope += 'group' — a seat covering an ad-hoc set of departments
--   * position_departments — the coverage list for group-scoped (L2) seats
--   * positions.label      — distinguishes two same-role seats in one scope
--   * department_members   — view-only membership (not a position: many
--                            people share a dept without occupying a seat)
--   * workflow_steps       — position_id OR dynamic resolution
--                            (role_code + scope resolved against the
--                            requisition's own branch/department)
--   * requisition_edits    — upline edit audit (field, old, new, who, when)
--   * notifications        — chain notifications for the bell icon

-- ── Roles: level + 'group' scope ─────────────────────────────────────────
alter table public.roles add column level int;
alter table public.roles drop constraint roles_scope_check;
alter table public.roles add constraint roles_scope_check
  check (scope in ('organization', 'branch', 'group', 'department'));

-- Rename existing roles to the real hierarchy (assignments ride along —
-- they reference role_id, not code).
update public.roles set code = 'leader_3', level = 1,
  name = 'Department Head (Leader 3)',
  description = 'Heads one department. Creates requisitions; first rung of the chain.'
  where code = 'departmental_head';

update public.roles set code = 'leader_1', level = 3,
  name = 'Branch Pastor (Leader 1)',
  description = 'Pastor of a branch. Approves requisitions after Leader 2.'
  where code = 'finance_lead';

update public.roles set code = 'senior_pastor', level = 6,
  name = 'Senior Pastor',
  description = 'Overall leader. Can approve any pending requisition directly, skipping intermediate steps.'
  where code = 'lead_pastor';

update public.roles set level = 4 where code = 'head_of_finance';

insert into public.roles (code, name, description, scope, level) values
  ('leader_2', 'Group Departments Head (Leader 2)',
   'Heads an ad-hoc group of departments within a branch. Approves requisitions from the departments they cover.',
   'group', 2),
  ('member', 'Department Member',
   'View-only member of a department. Sees its requisitions, cannot create or approve.',
   'department', 0);

-- ── Permissions: the two new approval rungs ──────────────────────────────
insert into public.permissions (code, description, category) values
  ('requisition.approve.l2', 'Approve requisitions at the Leader 2 (group departments) step', 'approval'),
  ('requisition.approve.l1', 'Approve requisitions at the Leader 1 (branch pastor) step',    'approval');

-- Reset permission mappings for the renamed/reworked roles.
delete from public.role_permissions rp
using public.roles r
where rp.role_id = r.id and r.code in ('leader_3', 'leader_1');

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id from public.roles r join public.permissions p
  on p.code in ('requisition.create', 'requisition.view.own')
where r.code = 'leader_3';

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id from public.roles r join public.permissions p
  on p.code in ('requisition.create', 'requisition.view.own', 'requisition.approve.l2')
where r.code = 'leader_2';

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id from public.roles r join public.permissions p
  on p.code in ('requisition.create', 'requisition.view.own', 'requisition.approve.l1')
where r.code = 'leader_1';

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id from public.roles r join public.permissions p
  on p.code = 'requisition.view.own'
where r.code = 'member';

-- superadmin picks up the two new approval permissions too
insert into public.role_permissions (role_id, permission_id)
select r.id, p.id from public.roles r, public.permissions p
where r.code = 'superadmin' and p.code in ('requisition.approve.l2', 'requisition.approve.l1');

-- ── Positions: label + group-scope validation ────────────────────────────
alter table public.positions add column label text;

drop index public.positions_unique_scope_idx;
create unique index positions_unique_scope_idx
  on public.positions (
    role_id,
    coalesce(branch_id,     '00000000-0000-0000-0000-000000000000'),
    coalesce(department_id, '00000000-0000-0000-0000-000000000000'),
    coalesce(label, '')
  );

create or replace function public.validate_position_scope()
returns trigger
language plpgsql
as $$
declare
  role_scope text;
begin
  select scope into role_scope from public.roles where id = new.role_id;

  if role_scope = 'organization' and (new.branch_id is not null or new.department_id is not null) then
    raise exception 'organization-scoped roles must not set branch_id or department_id';
  elsif role_scope = 'branch' and (new.branch_id is null or new.department_id is not null) then
    raise exception 'branch-scoped roles require branch_id and must not set department_id';
  elsif role_scope = 'group' and (new.branch_id is null or new.department_id is not null) then
    raise exception 'group-scoped roles require branch_id, must not set department_id — coverage lives in position_departments';
  elsif role_scope = 'department' and (new.branch_id is null or new.department_id is null) then
    raise exception 'department-scoped roles require both branch_id and department_id';
  end if;

  return new;
end;
$$;

-- ── position_departments: L2 coverage ────────────────────────────────────
create table public.position_departments (
  position_id   uuid not null references public.positions(id) on delete cascade,
  department_id uuid not null references public.departments(id) on delete cascade,
  primary key (position_id, department_id)
);

alter table public.position_departments enable row level security;
create policy "position_departments_select" on public.position_departments
  for select using (auth.role() = 'authenticated');
create policy "position_departments_manage" on public.position_departments
  for all using (public.has_permission('roles.assign'))
  with check (public.has_permission('roles.assign'));

grant select, insert, delete on public.position_departments to authenticated;

-- ── department_members: view-only membership ─────────────────────────────
-- Not a position — members don't occupy a seat and don't enter routing.
create table public.department_members (
  department_id uuid not null references public.departments(id) on delete cascade,
  profile_id    uuid not null references public.profiles(id) on delete cascade,
  created_at    timestamptz not null default now(),
  primary key (department_id, profile_id)
);

alter table public.department_members enable row level security;
create policy "department_members_select" on public.department_members
  for select using (
    profile_id = auth.uid()
    or public.is_admin()
    or public.has_permission('users.manage')
  );
create policy "department_members_manage" on public.department_members
  for all using (public.has_permission('users.manage'))
  with check (public.has_permission('users.manage'));

grant select, insert, delete on public.department_members to authenticated;

-- ── Visibility: group coverage + membership ──────────────────────────────
create or replace function public.can_view_department_for(target_profile uuid, target_department uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.is_admin_for(target_profile) or exists (
    select 1 from public.positions_for(target_profile) mp
    where mp.role_scope = 'organization'
       or mp.department_id = target_department
       or (mp.role_scope = 'branch'
           and mp.branch_id = (select branch_id from public.departments where id = target_department))
       or (mp.role_scope = 'group'
           and exists (select 1 from public.position_departments pd
                       where pd.position_id = mp.position_id
                         and pd.department_id = target_department))
  ) or exists (
    select 1 from public.department_members dm
    where dm.profile_id = target_profile and dm.department_id = target_department
  );
$$;

create or replace function public.can_view_department(target_department uuid)
returns boolean
language sql
stable
as $$
  select public.can_view_department_for(auth.uid(), target_department);
$$;

-- ── Workflow steps: dynamic resolution ───────────────────────────────────
alter table approval_svc.workflow_steps
  alter column position_id drop not null,
  add column resolution        text not null default 'position'
                               check (resolution in ('position', 'dynamic')),
  add column dynamic_role_code text,
  add column dynamic_scope     text check (dynamic_scope in ('group', 'branch', 'organization')),
  add constraint workflow_steps_resolution_valid check (
    (resolution = 'position' and position_id is not null)
    or (resolution = 'dynamic' and dynamic_role_code is not null and dynamic_scope is not null)
  );

-- Resolve "which concrete position does this step point at for THIS
-- requisition" — the piece static templates couldn't express.
create or replace function approval_svc.resolve_step_position(
  p_template_id uuid,
  p_step_order  int,
  p_branch_id   uuid,
  p_department_id uuid
)
returns uuid
language sql
stable
security definer
set search_path = public, approval_svc
as $$
  select case
    when ws.resolution = 'position' then ws.position_id
    else (
      select p.id
      from public.positions p
      join public.roles r on r.id = p.role_id
      where p.is_active
        and r.code = ws.dynamic_role_code
        and case ws.dynamic_scope
          when 'organization' then p.branch_id is null and p.department_id is null
          when 'branch'       then p.branch_id = p_branch_id and p.department_id is null
          when 'group'        then exists (
            select 1 from public.position_departments pd
            where pd.position_id = p.id and pd.department_id = p_department_id
          )
        end
      order by p.created_at
      limit 1
    )
  end
  from approval_svc.workflow_steps ws
  where ws.template_id = p_template_id and ws.step_order = p_step_order;
$$;

-- Current approver: resolve the step's position dynamically per requisition.
create or replace view approval_svc.v_current_approver
  with (security_invoker = true) as
select
  ai.id as approval_instance_id,
  ai.requisition_id,
  ai.current_step as step_order,
  rp.position_id,
  vaph.role_code,
  vaph.profile_id,
  vaph.full_name,
  vaph.email
from approval_svc.approval_instances ai
join purchase_svc.v_public_requisition r on r.id = ai.requisition_id
cross join lateral (
  select approval_svc.resolve_step_position(
    ai.template_id, ai.current_step, r.branch_id, r.department_id
  ) as position_id
) rp
left join public.v_active_position_holders vaph on vaph.position_id = rp.position_id
where ai.status = 'pending';

-- ── create_requisition: start the chain above the creator ────────────────
create or replace function public.create_requisition(
  title         text,
  description   text,
  branch_id     uuid,
  department_id uuid,
  currency      text default 'NGN'
)
returns table (
  id                 uuid,
  requisition_number text,
  status             text,
  total_amount       numeric(14,2),
  req_currency       text
)
language plpgsql
security definer
set search_path = public, purchase_svc, approval_svc
as $$
declare
  v_requested_by  uuid := auth.uid();
  v_req_number    text;
  v_template      uuid;
  v_creator_level int;
  v_first_step    int;
  v_approver      uuid;
begin
  if v_requested_by is null then
    raise exception 'Not authenticated';
  end if;
  if not public.has_permission('requisition.create') then
    raise exception 'Permission denied: requisition.create';
  end if;

  -- Scope check + capture the level of the seat they're submitting under.
  select max(r.level) into v_creator_level
  from public.position_assignments pa
  join public.positions pos on pos.id = pa.position_id and pos.is_active
  join public.roles r on r.id = pos.role_id
  where pa.profile_id = v_requested_by
    and pa.end_date is null
    and pos.branch_id = create_requisition.branch_id
    and pos.department_id = create_requisition.department_id;

  if v_creator_level is null then
    raise exception 'Permission denied: no active position in this branch/department';
  end if;

  v_req_number := 'REQ-' || to_char(now(), 'YYYYMMDD') || '-' ||
    lpad(nextval('purchase_svc.requisition_number_seq')::text, 4, '0');

  insert into purchase_svc.requisitions (
    requisition_number, branch_id, department_id, requested_by,
    title, description, currency, status
  )
  values (
    v_req_number, branch_id, department_id, v_requested_by,
    title, description, currency, 'submitted'
  )
  returning
    purchase_svc.requisitions.id,
    purchase_svc.requisitions.requisition_number,
    purchase_svc.requisitions.status,
    purchase_svc.requisitions.total_amount,
    purchase_svc.requisitions.currency
  into id, requisition_number, status, total_amount, req_currency;

  select wt.id into v_template
  from approval_svc.workflow_templates wt
  where wt.is_active
    and (wt.branch_id = create_requisition.branch_id or wt.branch_id is null)
  order by (wt.branch_id is null) asc, wt.created_at asc
  limit 1;

  if v_template is not null then
    -- First step ABOVE the creator's level. Each step's level comes from
    -- its position's role (static) or its dynamic role code.
    select min(ws.step_order) into v_first_step
    from approval_svc.workflow_steps ws
    left join public.positions sp
      on ws.resolution = 'position' and sp.id = ws.position_id
    left join public.roles sr
      on sr.id = coalesce(sp.role_id, (select id from public.roles where code = ws.dynamic_role_code))
    where ws.template_id = v_template
      and coalesce(sr.level, 0) > v_creator_level;

    if v_first_step is not null then
      insert into approval_svc.approval_instances
        (requisition_id, template_id, current_step, status)
      values (id, v_template, v_first_step, 'pending');

      -- Notify whoever the first step routes to.
      select vca.profile_id into v_approver
      from approval_svc.v_current_approver vca
      where vca.requisition_id = create_requisition.id;
      if v_approver is not null then
        insert into public.notifications (profile_id, requisition_id, kind, title, body)
        values (v_approver, create_requisition.id, 'approval_requested',
                'Approval needed: ' || create_requisition.title,
                'A requisition from ' || (
                  select name from public.departments
                  where departments.id = create_requisition.department_id
                ) || ' is waiting on your approval.');
      end if;
    else
      -- Nothing above the creator in the chain — straight to approved.
      update purchase_svc.requisitions
      set status = 'approved'
      where requisitions.id = create_requisition.id;
    end if;
  end if;

  return next;
end;
$$;

-- ── act_on_requisition: + senior pastor override ─────────────────────────
create or replace function public.act_on_requisition(
  requisition_id uuid,
  action         text,
  comment        text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, purchase_svc, approval_svc
as $$
declare
  v_uid         uuid := auth.uid();
  v_instance    approval_svc.approval_instances%rowtype;
  v_step        approval_svc.workflow_steps%rowtype;
  v_req         record;
  v_step_pos    uuid;
  v_is_holder   boolean;
  v_is_executive boolean;
  v_new_status  text;
  v_next_approver uuid;
begin
  if v_uid is null then
    raise exception 'Not authenticated';
  end if;
  if act_on_requisition.action not in ('approved', 'rejected') then
    raise exception 'action must be ''approved'' or ''rejected''';
  end if;

  select * into v_instance
  from approval_svc.approval_instances
  where approval_instances.requisition_id = act_on_requisition.requisition_id
    and status = 'pending';
  if not found then
    raise exception 'No pending approval for this requisition';
  end if;

  select * into v_req
  from purchase_svc.v_public_requisition
  where id = act_on_requisition.requisition_id;

  select * into v_step
  from approval_svc.workflow_steps ws
  where ws.template_id = v_instance.template_id
    and ws.step_order = v_instance.current_step;

  v_step_pos := approval_svc.resolve_step_position(
    v_instance.template_id, v_instance.current_step, v_req.branch_id, v_req.department_id
  );

  select exists (
    select 1 from public.position_assignments pa
    where pa.position_id = v_step_pos and pa.profile_id = v_uid and pa.end_date is null
  ) into v_is_holder;

  select public.has_permission_for(v_uid, 'requisition.approve.executive')
  into v_is_executive;

  if not v_is_holder and not v_is_executive then
    raise exception 'Permission denied: not the current approver';
  end if;

  insert into approval_svc.approval_actions
    (approval_instance_id, step_order, position_id, acted_by, action, comment)
  values (
    v_instance.id, v_instance.current_step, v_step_pos,
    v_uid, act_on_requisition.action, act_on_requisition.comment
  );

  -- Executive override: an approval by someone who wasn't the current
  -- approver closes the instance outright.
  if v_is_executive and not v_is_holder and act_on_requisition.action = 'approved' then
    update approval_svc.approval_instances set status = 'approved' where id = v_instance.id;
  end if;

  select status into v_new_status from approval_svc.approval_instances where id = v_instance.id;

  update purchase_svc.requisitions
  set status = case v_new_status
                 when 'approved' then 'approved'
                 when 'rejected' then 'rejected'
                 else 'in_review'
               end
  where id = act_on_requisition.requisition_id;

  update purchase_svc.requisition_status_history h
  set changed_by = v_uid, note = act_on_requisition.comment
  where h.id = (
    select id from purchase_svc.requisition_status_history
    where requisition_status_history.requisition_id = act_on_requisition.requisition_id
    order by changed_at desc limit 1
  );

  -- Notifications: next approver, or the requester on terminal states.
  if v_new_status = 'pending' then
    select vca.profile_id into v_next_approver
    from approval_svc.v_current_approver vca
    where vca.requisition_id = act_on_requisition.requisition_id;
    if v_next_approver is not null then
      insert into public.notifications (profile_id, requisition_id, kind, title, body)
      values (v_next_approver, act_on_requisition.requisition_id, 'approval_requested',
              'Approval needed: ' || v_req.requisition_number,
              'A requisition is waiting on your approval.');
    end if;
  else
    insert into public.notifications (profile_id, requisition_id, kind, title, body)
    values (v_req.requested_by, act_on_requisition.requisition_id,
            'requisition_' || v_new_status,
            'Requisition ' || v_new_status || ': ' || v_req.requisition_number,
            act_on_requisition.comment);
  end if;

  return jsonb_build_object(
    'approval_status', v_new_status,
    'current_step', (select current_step from approval_svc.approval_instances where id = v_instance.id)
  );
end;
$$;

-- ── Requisition edits by uplines ─────────────────────────────────────────
create table purchase_svc.requisition_edits (
  id             uuid primary key default gen_random_uuid(),
  requisition_id uuid not null references purchase_svc.requisitions(id) on delete cascade,
  edited_by      uuid not null references public.profiles(id),
  field          text not null,
  old_value      text,
  new_value      text,
  edited_at      timestamptz not null default now()
);
alter table purchase_svc.requisition_edits enable row level security;
grant all on purchase_svc.requisition_edits to svc_purchase;

-- Edit title/description and/or replace the item list. Any holder of a step
-- position in this requisition's chain (an upline) or an executive may edit.
create or replace function public.update_requisition(
  requisition_id uuid,
  title          text default null,
  description    text default null,
  items          jsonb default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, purchase_svc, approval_svc
as $$
declare
  v_uid      uuid := auth.uid();
  v_req      purchase_svc.requisitions%rowtype;
  v_allowed  boolean;
  v_old_json text;
begin
  if v_uid is null then
    raise exception 'Not authenticated';
  end if;

  select * into v_req from purchase_svc.requisitions
  where id = update_requisition.requisition_id;
  if not found then
    raise exception 'Requisition not found';
  end if;
  if v_req.status not in ('submitted', 'in_review') then
    raise exception 'Only requisitions still in review can be edited';
  end if;

  -- Upline = holder of ANY step position in this instance's chain, or an
  -- executive (senior pastor). Owner can't edit while it's in review.
  select (
    public.has_permission_for(v_uid, 'requisition.approve.executive')
    or exists (
      select 1
      from approval_svc.approval_instances ai
      join approval_svc.workflow_steps ws on ws.template_id = ai.template_id
      cross join lateral (
        select approval_svc.resolve_step_position(
          ai.template_id, ws.step_order, v_req.branch_id, v_req.department_id
        ) as position_id
      ) rp
      join public.position_assignments pa
        on pa.position_id = rp.position_id
       and pa.profile_id = v_uid
       and pa.end_date is null
      where ai.requisition_id = v_req.id and ai.status = 'pending'
    )
  ) into v_allowed;

  if not v_allowed then
    raise exception 'Permission denied: only uplines in the approval chain may edit';
  end if;

  if title is not null and title is distinct from v_req.title then
    insert into purchase_svc.requisition_edits (requisition_id, edited_by, field, old_value, new_value)
    values (v_req.id, v_uid, 'title', v_req.title, title);
    update purchase_svc.requisitions set title = update_requisition.title where id = v_req.id;
  end if;

  if description is not null and description is distinct from v_req.description then
    insert into purchase_svc.requisition_edits (requisition_id, edited_by, field, old_value, new_value)
    values (v_req.id, v_uid, 'description', v_req.description, description);
    update purchase_svc.requisitions set description = update_requisition.description where id = v_req.id;
  end if;

  if items is not null then
    select coalesce(jsonb_agg(jsonb_build_object(
      'item_name', ri.item_name, 'quantity', ri.quantity,
      'unit_price', ri.unit_price, 'notes', ri.notes
    )), '[]'::jsonb)::text into v_old_json
    from purchase_svc.requisition_items ri where ri.requisition_id = v_req.id;

    insert into purchase_svc.requisition_edits (requisition_id, edited_by, field, old_value, new_value)
    values (v_req.id, v_uid, 'items', v_old_json, items::text);

    delete from purchase_svc.requisition_items where requisition_id = v_req.id;
    insert into purchase_svc.requisition_items (requisition_id, item_name, quantity, unit_price, notes)
    select v_req.id, elem->>'item_name', (elem->>'quantity')::numeric(10,2),
           (elem->>'unit_price')::numeric(14,2), nullif(elem->>'notes', '')
    from jsonb_array_elements(items) as elem;
  end if;

  return jsonb_build_object('updated', true);
end;
$$;

-- ── Notifications ────────────────────────────────────────────────────────
create table public.notifications (
  id             uuid primary key default gen_random_uuid(),
  profile_id     uuid not null references public.profiles(id) on delete cascade,
  requisition_id uuid,
  kind           text not null,
  title          text not null,
  body           text,
  read_at        timestamptz,
  created_at     timestamptz not null default now()
);

alter table public.notifications enable row level security;
create policy "notifications_select_own" on public.notifications
  for select using (profile_id = auth.uid());
create policy "notifications_update_own" on public.notifications
  for update using (profile_id = auth.uid()) with check (profile_id = auth.uid());

grant select, update on public.notifications to authenticated;

create or replace function public.get_my_notifications()
returns table (
  id uuid, requisition_id uuid, kind text, title text, body text,
  read_at timestamptz, created_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;
  return query
  select n.id, n.requisition_id, n.kind, n.title, n.body, n.read_at, n.created_at
  from public.notifications n
  where n.profile_id = auth.uid()
  order by n.created_at desc
  limit 50;
end;
$$;

-- ── Org management: branch + bundled departments ─────────────────────────
create or replace function public.create_branch(
  name        text,
  code        text,
  departments jsonb default '[]'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org     uuid;
  v_branch  uuid;
  v_dept    jsonb;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;
  if not public.has_permission('org.manage') then
    raise exception 'Permission denied: org.manage';
  end if;

  select id into v_org from public.organizations order by created_at limit 1;
  if v_org is null then
    insert into public.organizations (name) values ('Church') returning id into v_org;
  end if;

  insert into public.branches (organization_id, name, code)
  values (v_org, create_branch.name, create_branch.code)
  returning id into v_branch;

  for v_dept in select * from jsonb_array_elements(departments) loop
    insert into public.departments (branch_id, name)
    values (v_branch, v_dept->>'name');
  end loop;

  return v_branch;
end;
$$;

create or replace function public.create_department(
  branch_id uuid,
  name      text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_dept uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;
  if not public.has_permission('org.manage') then
    raise exception 'Permission denied: org.manage';
  end if;
  insert into public.departments (branch_id, name)
  values (create_department.branch_id, create_department.name)
  returning id into v_dept;
  return v_dept;
end;
$$;

-- ── Grants ───────────────────────────────────────────────────────────────
revoke execute on function
  public.create_requisition(text, text, uuid, uuid, text),
  public.act_on_requisition(uuid, text, text),
  public.update_requisition(uuid, text, text, jsonb),
  public.get_my_notifications(),
  public.create_branch(text, text, jsonb),
  public.create_department(uuid, text)
  from public, anon;

grant execute on function
  public.create_requisition(text, text, uuid, uuid, text),
  public.act_on_requisition(uuid, text, text),
  public.update_requisition(uuid, text, text, jsonb),
  public.get_my_notifications(),
  public.create_branch(text, text, jsonb),
  public.create_department(uuid, text)
  to authenticated;
