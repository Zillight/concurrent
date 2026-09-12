-- Phase 3: Approval workflow
--
--   1. create_requisition now instantiates an approval_svc.approval_instances
--      row on submit: prefers a template bound to the requisition's branch,
--      falls back to the org-wide default (branch_id is null). Steps whose
--      amount band doesn't contain the requisition total are skipped — both
--      at instantiation and on every advance.
--   2. advance_approval_instance rewritten to be amount-aware (was linear).
--   3. New approver RPCs: get_my_pending_approvals() + act_on_requisition().
--      Approval outcomes sync back to purchase_svc.requisitions.status, and
--      the status-history row the trigger writes gets annotated with
--      changed_by + the approver's comment.
--   4. get_my_context() now returns a permissions array so the frontend can
--      gate UI (e.g. the Approvals tab) on requisition.approve.* codes.
--
-- Design note: workflow_steps.position_id points at a concrete position, so
-- a chain is "finance_lead@branch -> head_of_finance -> lead_pastor". It
-- cannot express "the head of whichever department submitted" — acceptable
-- today because the submitter IS the departmental head. If member-level
-- submission lands later, add dynamic position resolution then.

-- ── 1. Amount-aware advancement ──────────────────────────────────────────
create or replace function approval_svc.advance_approval_instance()
returns trigger
language plpgsql
as $$
declare
  v_req_total numeric(14,2);
  v_next_step int;
begin
  if new.action = 'rejected' then
    update approval_svc.approval_instances set status = 'rejected' where id = new.approval_instance_id;
    return new;
  end if;

  select r.total_amount into v_req_total
  from purchase_svc.v_public_requisition r
  join approval_svc.approval_instances ai on ai.requisition_id = r.id
  where ai.id = new.approval_instance_id;

  -- Next step past the one just acted on whose amount band fits the total.
  select min(ws.step_order) into v_next_step
  from approval_svc.workflow_steps ws
  join approval_svc.approval_instances ai on ai.template_id = ws.template_id
  where ai.id = new.approval_instance_id
    and ws.step_order > new.step_order
    and (ws.min_amount is null or v_req_total >= ws.min_amount)
    and (ws.max_amount is null or v_req_total <= ws.max_amount);

  if v_next_step is null then
    update approval_svc.approval_instances set status = 'approved' where id = new.approval_instance_id;
  else
    update approval_svc.approval_instances set current_step = v_next_step where id = new.approval_instance_id;
  end if;

  return new;
end;
$$;

-- ── 2. create_requisition: instantiate the approval on submit ────────────
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
  v_requested_by uuid := auth.uid();
  v_req_number   text;
  v_template     uuid;
  v_first_step   int;
begin
  if v_requested_by is null then
    raise exception 'Not authenticated';
  end if;

  if not public.has_permission('requisition.create') then
    raise exception 'Permission denied: requisition.create';
  end if;

  -- Scope check: the caller must actively hold a position in the branch +
  -- department they're submitting for.
  if not exists (
    select 1
    from public.position_assignments pa
    join public.positions pos
      on pos.id = pa.position_id and pos.is_active
    where pa.profile_id = v_requested_by
      and pa.end_date is null
      and pos.branch_id = create_requisition.branch_id
      and pos.department_id = create_requisition.department_id
  ) then
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

  -- Kick off the approval workflow: branch template wins, org default is
  -- the fallback. If no template exists the requisition still submits and
  -- get_requisition_details shows approval: null.
  select wt.id into v_template
  from approval_svc.workflow_templates wt
  where wt.is_active
    and (wt.branch_id = create_requisition.branch_id or wt.branch_id is null)
  order by (wt.branch_id is null) asc, wt.created_at asc
  limit 1;

  if v_template is not null then
    -- First applicable step for a fresh requisition (total is still 0 —
    -- items are attached after creation; amount-gated first steps are
    -- vanishingly rare, and every advance re-evaluates against the real
    -- total anyway).
    select min(ws.step_order) into v_first_step
    from approval_svc.workflow_steps ws
    where ws.template_id = v_template
      and (ws.min_amount is null or ws.min_amount <= 0)
      and (ws.max_amount is null or ws.max_amount >= 0);

    if v_first_step is not null then
      insert into approval_svc.approval_instances
        (requisition_id, template_id, current_step, status)
      values (id, v_template, v_first_step, 'pending');
    end if;
  end if;

  return next;
end;
$$;

-- ── 3. get_my_pending_approvals ──────────────────────────────────────────
-- Everything currently waiting on the caller: they hold the position the
-- instance's current step routes to.
create or replace function public.get_my_pending_approvals()
returns table (
  requisition_id     uuid,
  requisition_number text,
  title              text,
  total_amount       numeric(14,2),
  currency           text,
  status             text,
  department_name    text,
  branch_name        text,
  requested_by_name  text,
  step_order         int,
  submitted_at       timestamptz
)
language plpgsql
security definer
set search_path = public, purchase_svc, approval_svc
as $$
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  return query
  select
    r.id, r.requisition_number, r.title, r.total_amount, r.currency,
    r.status, d.name, b.name, p.full_name, vca.step_order, r.created_at
  from approval_svc.v_current_approver vca
  join purchase_svc.requisitions r on r.id = vca.requisition_id
  join public.departments d on d.id = r.department_id
  join public.branches    b on b.id = r.branch_id
  join public.profiles    p on p.id = r.requested_by
  where vca.profile_id = auth.uid()
  order by r.created_at asc;
end;
$$;

-- ── 4. act_on_requisition ────────────────────────────────────────────────
-- Approve or reject the requisition currently waiting on the caller.
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
  v_uid        uuid := auth.uid();
  v_instance   approval_svc.approval_instances%rowtype;
  v_step       approval_svc.workflow_steps%rowtype;
  v_new_status text;
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

  select * into v_step
  from approval_svc.workflow_steps ws
  where ws.template_id = v_instance.template_id
    and ws.step_order = v_instance.current_step;

  -- Caller must actively hold the position this step routes to.
  if not exists (
    select 1
    from public.position_assignments pa
    where pa.position_id = v_step.position_id
      and pa.profile_id = v_uid
      and pa.end_date is null
  ) then
    raise exception 'Permission denied: not the current approver';
  end if;

  insert into approval_svc.approval_actions
    (approval_instance_id, step_order, position_id, acted_by, action, comment)
  values (
    v_instance.id, v_instance.current_step, v_step.position_id,
    v_uid, act_on_requisition.action, act_on_requisition.comment
  );

  -- The advance trigger has already moved/closed the instance.
  select status into v_new_status
  from approval_svc.approval_instances where id = v_instance.id;

  update purchase_svc.requisitions
  set status = case v_new_status
                 when 'approved' then 'approved'
                 when 'rejected' then 'rejected'
                 else 'in_review'
               end
  where id = act_on_requisition.requisition_id;

  -- The status trigger just wrote a history row with no actor — annotate it.
  update purchase_svc.requisition_status_history h
  set changed_by = v_uid, note = act_on_requisition.comment
  where h.id = (
    select id from purchase_svc.requisition_status_history
    where requisition_status_history.requisition_id = act_on_requisition.requisition_id
    order by changed_at desc limit 1
  );

  return jsonb_build_object(
    'approval_status', v_new_status,
    'current_step', (select current_step from approval_svc.approval_instances where id = v_instance.id)
  );
end;
$$;

-- ── 5. get_my_context: include permissions ───────────────────────────────
create or replace function public.get_my_context()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_result jsonb;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  select jsonb_build_object(
    'profile', jsonb_build_object(
      'id',        p.id,
      'full_name', p.full_name,
      'email',     p.email
    ),
    'positions', coalesce((
      select jsonb_agg(jsonb_build_object(
        'position_id',     pos.id,
        'role_code',       r.code,
        'role_name',       r.name,
        'title',           pos.title,
        'branch_id',       pos.branch_id,
        'branch_name',     b.name,
        'department_id',   pos.department_id,
        'department_name', d.name
      ))
      from public.position_assignments pa
      join public.positions   pos on pos.id = pa.position_id and pos.is_active
      join public.roles       r   on r.id   = pos.role_id
      left join public.branches    b on b.id = pos.branch_id
      left join public.departments d on d.id = pos.department_id
      where pa.profile_id = p.id and pa.end_date is null
    ), '[]'::jsonb),
    'permissions', coalesce((
      select jsonb_agg(distinct perm.code)
      from public.position_assignments pa
      join public.positions          pos  on pos.id = pa.position_id and pos.is_active
      join public.role_permissions   rp   on rp.role_id = pos.role_id
      join public.permissions        perm on perm.id = rp.permission_id
      where pa.profile_id = p.id and pa.end_date is null
    ), '[]'::jsonb)
  )
  into v_result
  from public.profiles p
  where p.id = auth.uid() and p.is_active;

  if v_result is null then
    raise exception 'Profile not found or inactive';
  end if;

  return v_result;
end;
$$;

-- ── Grants ───────────────────────────────────────────────────────────────
revoke execute on function
  public.get_my_context(),
  public.create_requisition(text, text, uuid, uuid, text),
  public.get_my_pending_approvals(),
  public.act_on_requisition(uuid, text, text)
  from public, anon;

grant execute on function
  public.get_my_context(),
  public.create_requisition(text, text, uuid, uuid, text),
  public.get_my_pending_approvals(),
  public.act_on_requisition(uuid, text, text)
  to authenticated;
