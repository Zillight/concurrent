-- Phase 1 RPC test script
-- Run this in the Supabase SQL Editor (Dashboard → SQL Editor → New query)
-- It seeds minimal test data, calls every RPC, and prints results.
-- Safe to re-run — it cleans up after itself.

-- ── 1. Seed test data ────────────────────────────────────────────────────

-- Test organization
insert into public.organizations (id, name)
values ('11111111-1111-1111-1111-111111111111', 'Test Church')
on conflict (id) do nothing;

-- Test branch
insert into public.branches (id, organization_id, name, code)
values ('22222222-2222-2222-2222-222222222222',
        '11111111-1111-1111-1111-111111111111', 'Lagos HQ', 'LAG01')
on conflict (id) do nothing;

-- Test department
insert into public.departments (id, branch_id, name, code)
values ('33333333-3333-3333-3333-333333333333',
        '22222222-2222-2222-2222-222222222222', 'Media', 'MED')
on conflict (id) do nothing;

-- Test auth user (required because profiles.id FK → auth.users.id)
insert into auth.users (id, email, aud, role, email_confirmed_at, instance_id)
values ('44444444-4444-4444-4444-444444444444',
        'testuser@concurrent.test', 'authenticated', 'authenticated', now(), '00000000-0000-0000-0000-000000000000')
on conflict (id) do nothing;

-- The handle_new_user trigger should have auto-created a profile.
-- If not, create it manually:
insert into public.profiles (id, full_name, email)
values ('44444444-4444-4444-4444-444444444444', 'Test User', 'testuser@concurrent.test')
on conflict (id) do nothing;

-- Assign departmental_head position so the user has requisition.create permission
insert into public.positions (id, role_id, branch_id, department_id, title)
select '55555555-5555-5555-5555-555555555555',
       r.id,
       '22222222-2222-2222-2222-222222222222',
       '33333333-3333-3333-3333-333333333333',
       'Departmental Head, Media'
from public.roles r where r.code = 'departmental_head'
on conflict (id) do nothing;

insert into public.position_assignments (position_id, profile_id)
values ('55555555-5555-5555-5555-555555555555',
        '44444444-4444-4444-4444-444444444444')
on conflict do nothing;

-- ── 2. Test create_requisition ───────────────────────────────────────────
-- auth.uid() is null in SQL Editor, so auth checks are skipped and
-- requested_by parameter is used via coalesce.

select '--- create_requisition ---' as test;

select * from public.create_requisition(
  title         := 'Test Bulk Requisition',
  description   := 'Phase 1 RPC test — 3 items',
  requested_by  := '44444444-4444-4444-4444-444444444444',
  branch_id     := '22222222-2222-2222-2222-222222222222',
  department_id := '33333333-3333-3333-3333-333333333333',
  currency      := 'NGN'
);

-- ── 3. Test create_requisition_items ─────────────────────────────────────
-- Grab the requisition ID we just created and add items to it.

select '--- create_requisition_items ---' as test;

do $$
declare
  v_req_id uuid;
begin
  select id into v_req_id
  from purchase_svc.requisitions
  where title = 'Test Bulk Requisition'
  order by created_at desc
  limit 1;

  perform public.create_requisition_items(
    requisition_id := v_req_id,
    items := jsonb_build_array(
      jsonb_build_object('item_name', 'Wireless Microphone', 'quantity', 2,  'unit_price', 45000,  'notes', 'Shure BLX288'),
      jsonb_build_object('item_name', 'HDMI Cable 10m',      'quantity', 5,  'unit_price', 3500,   'notes', null),
      jsonb_build_object('item_name', 'Speaker Stand',       'quantity', 4,  'unit_price', 12000,  'notes', 'Heavy duty')
    )
  );
end $$;

-- ── 4. Verify the requisition + items ────────────────────────────────────

select '--- requisition row ---' as test;
select id, requisition_number, title, status, total_amount, currency
from purchase_svc.requisitions
where title = 'Test Bulk Requisition'
order by created_at desc
limit 1;

select '--- line items ---' as test;
select item_name, quantity, unit_price, line_total, notes
from purchase_svc.requisition_items
where requisition_id = (
  select id from purchase_svc.requisitions
  where title = 'Test Bulk Requisition'
  order by created_at desc
  limit 1
)
order by created_at;

select '--- status history ---' as test;
select from_status, to_status, changed_at
from purchase_svc.requisition_status_history
where requisition_id = (
  select id from purchase_svc.requisitions
  where title = 'Test Bulk Requisition'
  order by created_at desc
  limit 1
)
order by changed_at;

-- ── 5. Test get_requisition_details ──────────────────────────────────────
-- auth.uid() is null in SQL Editor → returns null. That's expected.
-- To test with auth context, we'd need to set local JWT claims (see below).

select '--- get_requisition_details (expect null — no auth context in SQL Editor) ---' as test;
select public.get_requisition_details(
  (select id from purchase_svc.requisitions where title = 'Test Bulk Requisition' order by created_at desc limit 1)
) as details;

-- ── 6. Test get_dashboard_stats ───────────────────────────────────────────
-- Same — returns zeros without auth context.

select '--- get_dashboard_stats (expect zeros — no auth context in SQL Editor) ---' as test;
select public.get_dashboard_stats() as stats;

-- ── 7. Test with simulated auth context ──────────────────────────────────
-- The Supabase SQL Editor only shows the result grid for the LAST statement
-- of whatever you run, and has no psql-style "Messages" panel — so `set
-- local` (transaction-scoped) must be re-run together with each individual
-- test. Select all 4 lines of ONE block below (the set_config + set local
-- x2 + ONE test select) and run them together with Cmd+Enter / Ctrl+Enter.
-- Repeat 3x, swapping in a different final select each time.

-- IMPORTANT: if a previous test left the session stuck as "authenticated"
-- (permission denied for schema purchase_svc on a fresh run), run this
-- alone first to restore full access:
--
--   reset role;
--   reset request.jwt.claim.sub;
--
-- Each block below explicitly resets role at the end so it can't leak into
-- whatever you run next.

-- Test A — get_dashboard_stats with simulated auth:
select set_config('myapp.test_req_id',
  (select id::text from purchase_svc.requisitions where title = 'Test Bulk Requisition' order by created_at desc limit 1), false);
set local role authenticated;
set local request.jwt.claim.sub = '44444444-4444-4444-4444-444444444444';
select public.get_dashboard_stats() as dashboard_stats_with_auth;
reset role;
reset request.jwt.claim.sub;

-- Test B — get_my_requisitions with simulated auth:
select set_config('myapp.test_req_id',
  (select id::text from purchase_svc.requisitions where title = 'Test Bulk Requisition' order by created_at desc limit 1), false);
set local role authenticated;
set local request.jwt.claim.sub = '44444444-4444-4444-4444-444444444444';
select * from public.get_my_requisitions();
reset role;
reset request.jwt.claim.sub;

-- Test C — get_requisition_details with simulated auth:
select set_config('myapp.test_req_id',
  (select id::text from purchase_svc.requisitions where title = 'Test Bulk Requisition' order by created_at desc limit 1), false);
set local role authenticated;
set local request.jwt.claim.sub = '44444444-4444-4444-4444-444444444444';
select public.get_requisition_details(current_setting('myapp.test_req_id')::uuid) as requisition_details;
reset role;
reset request.jwt.claim.sub;

-- ── 8. Cleanup ───────────────────────────────────────────────────────────
-- Uncomment the block below to remove all test data after verifying.
-- Leave it commented if you want to keep the test data for frontend dev.

-- delete from purchase_svc.requisition_items
--   where requisition_id in (select id from purchase_svc.requisitions where title = 'Test Bulk Requisition');
-- delete from purchase_svc.requisitions where title = 'Test Bulk Requisition';
-- delete from public.position_assignments where position_id = '55555555-5555-5555-5555-555555555555';
-- delete from public.positions where id = '55555555-5555-5555-5555-555555555555';
-- delete from public.profiles where id = '44444444-4444-4444-4444-444444444444';
-- delete from auth.users where id = '44444444-4444-4444-4444-444444444444';
-- delete from public.departments where id = '33333333-3333-3333-3333-333333333333';
-- delete from public.branches where id = '22222222-2222-2222-2222-222222222222';
-- delete from public.organizations where id = '11111111-1111-1111-1111-111111111111';
