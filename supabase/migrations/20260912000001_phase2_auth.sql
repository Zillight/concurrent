-- Phase 2: Authentication hardening
--
-- Now that Supabase Auth provides a real auth.uid(), this migration:
--   1. Adds get_my_context() — the frontend bootstrap call returning the
--      caller's profile + active position(s) (branch/department/role),
--      replacing the hardcoded IDs the PWA used pre-auth.
--   2. Re-signs create_requisition WITHOUT the transitional requested_by
--      parameter — the owner is always auth.uid() now, and the submitted
--      branch/department must match a position the caller actively holds.
--   3. Converts every "auth.uid() is null -> skip/return" bypass in the
--      Phase 1 RPCs into a hard failure.
--   4. Revokes EXECUTE from public/anon on all frontend RPCs. Postgres
--      grants EXECUTE to PUBLIC by default, so the Phase 1 GRANT to
--      authenticated alone never actually excluded anonymous callers.

-- ── get_my_context ───────────────────────────────────────────────────────
-- Single bootstrap call for the PWA after login.
-- Output shape (jsonb):
--   { "profile": { "id", "full_name", "email" },
--     "positions": [ { "position_id", "role_code", "role_name", "title",
--                      "branch_id", "branch_name",
--                      "department_id", "department_name" } ] }
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

-- ── create_requisition (post-auth signature) ─────────────────────────────
-- Drop the old 6-arg form first: CREATE OR REPLACE cannot remove a param.
drop function if exists public.create_requisition(text, text, uuid, uuid, uuid, text);

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
set search_path = public, purchase_svc
as $$
declare
  v_requested_by uuid := auth.uid();
  v_req_number   text;
begin
  if v_requested_by is null then
    raise exception 'Not authenticated';
  end if;

  if not public.has_permission('requisition.create') then
    raise exception 'Permission denied: requisition.create';
  end if;

  -- Scope check: the caller must actively hold a position in the branch +
  -- department they're submitting for. Stops a departmental head from
  -- filing requisitions under another department's name.
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

  return next;
end;
$$;

-- ── create_requisition_items ─────────────────────────────────────────────
create or replace function public.create_requisition_items(
  requisition_id uuid,
  items          jsonb
)
returns void
language plpgsql
security definer
set search_path = public, purchase_svc
as $$
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  -- Authorization: caller must own the requisition.
  if not exists (
    select 1 from purchase_svc.requisitions
    where id = requisition_id and requested_by = auth.uid()
  ) then
    raise exception 'Permission denied: not the requisition owner';
  end if;

  -- Guard: can only add items to draft or submitted requisitions.
  if not exists (
    select 1 from purchase_svc.requisitions
    where id = requisition_id and status in ('draft', 'submitted')
  ) then
    raise exception 'Cannot add items to a requisition that is already in review or beyond';
  end if;

  -- Single INSERT...SELECT from the JSON array — no procedural loop needed.
  insert into purchase_svc.requisition_items (
    requisition_id, item_name, quantity, unit_price, notes
  )
  select
    requisition_id,
    elem->>'item_name',
    (elem->>'quantity')::numeric(10,2),
    (elem->>'unit_price')::numeric(14,2),
    nullif(elem->>'notes', '')
  from jsonb_array_elements(items) as elem;
end;
$$;

-- ── get_dashboard_stats ──────────────────────────────────────────────────
create or replace function public.get_dashboard_stats()
returns jsonb
language plpgsql
security definer
set search_path = public, purchase_svc
as $$
declare
  v_profile uuid := auth.uid();
begin
  if v_profile is null then
    raise exception 'Not authenticated';
  end if;

  return (
    select jsonb_build_object(
      'pending',   count(*) filter (where r.status in ('submitted', 'in_review')),
      'approved',  count(*) filter (where r.status = 'approved'),
      'rejected',  count(*) filter (where r.status = 'rejected'),
      'completed', count(*) filter (where r.status = 'fulfilled'),
      'recent_activity', coalesce((
        select jsonb_agg(jsonb_build_object(
          'requisition_id', h.requisition_id,
          'title',          r2.title,
          'status',         h.to_status,
          'changed_at',     h.changed_at,
          'note',           h.note
        ) order by h.changed_at desc)
        from purchase_svc.requisition_status_history h
        join purchase_svc.requisitions r2 on r2.id = h.requisition_id
        where r2.requested_by = v_profile
           or public.has_permission('requisition.view.all')
      ), '[]'::jsonb)
    )
    from purchase_svc.requisitions r
    where r.requested_by = v_profile
       or public.has_permission('requisition.view.all')
  );
end;
$$;

-- ── get_my_requisitions ──────────────────────────────────────────────────
create or replace function public.get_my_requisitions(
  status_filter text default null
)
returns table (
  id                 uuid,
  requisition_number text,
  title              text,
  total_amount       numeric(14,2),
  currency           text,
  status             text,
  department_name    text,
  created_at         timestamptz
)
language plpgsql
security definer
set search_path = public, purchase_svc
as $$
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  return query
  select
    r.id, r.requisition_number, r.title, r.total_amount, r.currency,
    r.status, d.name as department_name, r.created_at
  from purchase_svc.requisitions r
  join public.departments d on d.id = r.department_id
  where (
      r.requested_by = auth.uid()
      or public.has_permission('requisition.view.all')
      or (
        public.has_permission('requisition.view.own')
        and public.can_view_department(r.department_id)
      )
    )
    and (status_filter is null or r.status = status_filter)
  order by r.created_at desc;
end;
$$;

-- ── get_requisition_details ──────────────────────────────────────────────
create or replace function public.get_requisition_details(
  requisition_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, purchase_svc, approval_svc
as $$
declare
  v_req_id uuid := requisition_id;
  v_result jsonb;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  -- Authorization: caller must be the owner, have view.all, or have view.own
  -- for the requisition's department.
  if not exists (
    select 1 from purchase_svc.requisitions r
    where r.id = v_req_id
      and (
        r.requested_by = auth.uid()
        or public.has_permission('requisition.view.all')
        or (
          public.has_permission('requisition.view.own')
          and public.can_view_department(r.department_id)
        )
      )
  ) then
    raise exception 'Permission denied: cannot view this requisition';
  end if;

  select jsonb_build_object(
    'id',                 r.id,
    'requisition_number', r.requisition_number,
    'title',              r.title,
    'description',        r.description,
    'status',             r.status,
    'total_amount',       r.total_amount,
    'currency',           r.currency,
    'created_at',         r.created_at,
    'department_name',    d.name,
    'branch_name',        b.name,
    'requested_by_name',  p.full_name,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',         ri.id,
        'item_name',  ri.item_name,
        'quantity',   ri.quantity,
        'unit_price', ri.unit_price,
        'line_total', ri.line_total,
        'notes',      ri.notes
      ) order by ri.created_at)
      from purchase_svc.requisition_items ri
      where ri.requisition_id = v_req_id
    ), '[]'::jsonb),
    'approval', (
      select jsonb_build_object(
        'status',       ai.status,
        'current_step', ai.current_step
      )
      from approval_svc.approval_instances ai
      where ai.requisition_id = v_req_id
    )
  )
  into v_result
  from purchase_svc.requisitions r
  join public.departments d on d.id = r.department_id
  join public.branches b     on b.id = r.branch_id
  join public.profiles p     on p.id = r.requested_by
  where r.id = v_req_id;

  return v_result;
end;
$$;

-- ── Grants ───────────────────────────────────────────────────────────────
-- EXECUTE on functions defaults to PUBLIC — revoke it explicitly, then
-- re-grant to authenticated only.
revoke execute on function
  public.get_my_context(),
  public.create_requisition(text, text, uuid, uuid, text),
  public.create_requisition_items(uuid, jsonb),
  public.get_dashboard_stats(),
  public.get_my_requisitions(text),
  public.get_requisition_details(uuid)
  from public, anon;

grant execute on function
  public.get_my_context(),
  public.create_requisition(text, text, uuid, uuid, text),
  public.create_requisition_items(uuid, jsonb),
  public.get_dashboard_stats(),
  public.get_my_requisitions(text),
  public.get_requisition_details(uuid)
  to authenticated;
