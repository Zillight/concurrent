-- Frontend RPC functions: bridge between PostgREST (public, exposed) and
-- purchase_svc (not exposed). Each function is SECURITY DEFINER so it can
-- write to purchase_svc tables, but it checks RBAC via auth.uid() before
-- doing anything.
--
-- Parameter names match exactly what the frontend sends via supabase.rpc()
-- — PostgREST requires an exact key-to-parameter-name match.
--
-- Once a dedicated Purchase Service backend exists, these can be replaced
-- with direct Postgres calls from that service using svc_purchase.

-- ── Requisition number sequence ──────────────────────────────────────────
-- REQ-YYYYMMDD-NNNN, padded to 4 digits. Good for ~10k requisitions per day
-- before the padding looks uneven (still works, just wider).
create sequence if not exists purchase_svc.requisition_number_seq;

-- ── create_requisition ───────────────────────────────────────────────────
-- Creates a new requisition in 'submitted' status and returns its core
-- fields. The frontend reads [0].id from the returned array.
--
-- The requested_by parameter is transitional: once Phase 2 (Auth) ships,
-- the function should use auth.uid() exclusively and the parameter should
-- be removed. For now we coalesce so pre-auth development still works.
create or replace function public.create_requisition(
  title         text,
  description   text,
  requested_by  uuid,
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
  v_requested_by uuid := coalesce(auth.uid(), requested_by);
  v_req_number   text;
begin
  -- Authorization: caller must hold requisition.create.
  -- Skipped when auth.uid() is null (pre-auth development).
  if auth.uid() is not null and not public.has_permission('requisition.create') then
    raise exception 'Permission denied: requisition.create';
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
-- Bulk-inserts line items from a JSON array. Each element should have:
--   { "item_name": text, "quantity": number, "unit_price": number, "notes": text|null }
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
  -- Authorization: caller must own the requisition.
  -- Skipped when auth.uid() is null (pre-auth development).
  if auth.uid() is not null and not exists (
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
-- Returns status counts + recent activity for the caller.
-- Output shape (jsonb):
--   { "pending": N, "approved": N, "rejected": N, "completed": N,
--     "recent_activity": [ { "requisition_id", "title", "status", "changed_at", "note" }, ... ] }
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
    return jsonb_build_object(
      'pending', 0, 'approved', 0, 'rejected', 0, 'completed', 0,
      'recent_activity', '[]'::jsonb
    );
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
-- Returns requisitions visible to the caller: own + department-scoped +
-- org-wide (if requisition.view.all). Optional status filter.
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
    return;  -- pre-auth: empty result set
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
-- Returns a single requisition with its line items and approval status.
-- Output shape (jsonb):
--   { "id", "requisition_number", "title", "description", "status",
--     "total_amount", "currency", "created_at",
--     "department_name", "branch_name", "requested_by_name",
--     "items": [ { "id", "item_name", "quantity", "unit_price", "line_total", "notes" } ],
--     "approval": { "status", "current_step" } | null }
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
    return null;
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
-- Only authenticated users can call these RPCs. anon gets nothing.
grant execute on function
  public.create_requisition(text, text, uuid, uuid, uuid, text),
  public.create_requisition_items(uuid, jsonb),
  public.get_dashboard_stats(),
  public.get_my_requisitions(text),
  public.get_requisition_details(uuid)
  to authenticated;
