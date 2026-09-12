-- Phase 3b: Lead Accountant + disbursement
--
-- Approval chain is now: finance_lead -> head_of_finance -> lead_pastor
-- (every requisition, no amount gating). Once fully approved, the
-- lead_accountant — org-scoped, sees every branch — dispenses the funds,
-- moving the requisition to 'fulfilled' and optionally recording which
-- banking_account the money came out of.

insert into public.permissions (code, description, category) values
  ('requisition.dispense', 'Disburse funds for an approved requisition (mark fulfilled)', 'finance');

insert into public.roles (code, name, description, scope) values
  ('lead_accountant', 'Lead Accountant',
   'Organization-wide disbursement. Sees approved requisitions across all branches and releases funds.',
   'organization');

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r
join public.permissions p
  on p.code in ('requisition.dispense', 'requisition.view.all', 'banking.view')
where r.code = 'lead_accountant';

-- superadmin keeps every permission, including the new one
insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r, public.permissions p
where r.code = 'superadmin' and p.code = 'requisition.dispense';

-- ── disburse_requisition ─────────────────────────────────────────────────
-- Approved -> fulfilled. Caller needs requisition.dispense (lead_accountant).
create or replace function public.disburse_requisition(
  requisition_id     uuid,
  banking_account_id uuid default null,
  comment            text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, purchase_svc
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'Not authenticated';
  end if;
  if not public.has_permission('requisition.dispense') then
    raise exception 'Permission denied: requisition.dispense';
  end if;

  if banking_account_id is not null and not exists (
    select 1 from public.banking_accounts
    where id = banking_account_id and is_active
  ) then
    raise exception 'Unknown or inactive banking account';
  end if;

  update purchase_svc.requisitions
  set status = 'fulfilled',
      banking_account_id = coalesce(
        disburse_requisition.banking_account_id,
        requisitions.banking_account_id
      )
  where id = disburse_requisition.requisition_id
    and status = 'approved';

  if not found then
    raise exception 'Requisition is not in approved state — cannot disburse';
  end if;

  -- Annotate the history row the status trigger just wrote.
  update purchase_svc.requisition_status_history h
  set changed_by = v_uid, note = disburse_requisition.comment
  where h.id = (
    select id from purchase_svc.requisition_status_history
    where requisition_status_history.requisition_id = disburse_requisition.requisition_id
    order by changed_at desc limit 1
  );

  return jsonb_build_object('status', 'fulfilled');
end;
$$;

-- ── Grants ───────────────────────────────────────────────────────────────
revoke execute on function public.disburse_requisition(uuid, uuid, text)
  from public, anon;

grant execute on function public.disburse_requisition(uuid, uuid, text)
  to authenticated;
