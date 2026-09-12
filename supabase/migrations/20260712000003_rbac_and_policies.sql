-- Foundation & Identity: RBAC helper functions, RLS policies, and the
-- "permission preview" views used by the admin user-creation UI.

-- ── Helper functions ─────────────────────────────────────────────────────
--
-- Every check comes in two forms:
--   *_for(target_profile, ...)  -- explicit profile id; callable by the
--                                  Purchase/Approval services over their own
--                                  direct Postgres connection, where there is
--                                  no Supabase JWT and therefore no auth.uid()
--   the auth.uid()-based wrapper -- used by RLS policies and any client call
--                                  made through PostgREST as 'authenticated'
-- Both forms share the same logic so authorization never drifts between the
-- client-facing path and the service-to-service path.

-- The active positions held by the given user right now. This is the single
-- source of truth every permission check and RLS policy reads from.
create or replace function public.positions_for(target_profile uuid)
returns table (position_id uuid, role_code text, role_scope text, branch_id uuid, department_id uuid)
language sql
stable
security definer
set search_path = public
as $$
  select p.id, r.code, r.scope, p.branch_id, p.department_id
  from public.position_assignments pa
  join public.positions p on p.id = pa.position_id and p.is_active
  join public.roles r on r.id = p.role_id
  where pa.profile_id = target_profile and pa.end_date is null;
$$;

create or replace function public.my_positions()
returns table (position_id uuid, role_code text, role_scope text, branch_id uuid, department_id uuid)
language sql
stable
as $$
  select * from public.positions_for(auth.uid());
$$;

create or replace function public.is_admin_for(target_profile uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.positions_for(target_profile) where role_code = 'admin');
$$;

create or replace function public.is_admin()
returns boolean
language sql
stable
as $$
  select public.is_admin_for(auth.uid());
$$;

-- Does target_profile hold any active position whose role grants perm_code?
-- This is the core RBAC check, and also what powers the "permission preview"
-- shown during user/position creation (see the views below).
create or replace function public.has_permission_for(target_profile uuid, perm_code text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.positions_for(target_profile) mp
    join public.roles r on r.code = mp.role_code
    join public.role_permissions rp on rp.role_id = r.id
    join public.permissions perm on perm.id = rp.permission_id and perm.code = perm_code
  );
$$;

create or replace function public.has_permission(perm_code text)
returns boolean
language sql
stable
as $$
  select public.has_permission_for(auth.uid(), perm_code);
$$;

create or replace function public.can_view_branch_for(target_profile uuid, target_branch uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.is_admin_for(target_profile) or exists (
    select 1 from public.positions_for(target_profile)
    where role_scope = 'organization' or branch_id = target_branch
  );
$$;

create or replace function public.can_view_branch(target_branch uuid)
returns boolean
language sql
stable
as $$
  select public.can_view_branch_for(auth.uid(), target_branch);
$$;

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
  );
$$;

create or replace function public.can_view_department(target_department uuid)
returns boolean
language sql
stable
as $$
  select public.can_view_department_for(auth.uid(), target_department);
$$;

-- ── Row Level Security ───────────────────────────────────────────────────

alter table public.organizations       enable row level security;
alter table public.branches            enable row level security;
alter table public.departments         enable row level security;
alter table public.banking_accounts    enable row level security;
alter table public.profiles            enable row level security;
alter table public.roles               enable row level security;
alter table public.permissions         enable row level security;
alter table public.role_permissions    enable row level security;
alter table public.positions           enable row level security;
alter table public.position_assignments enable row level security;

-- organizations: every authenticated member can see the org they belong to;
-- only admins configure it.
create policy "organizations_select" on public.organizations
  for select using (auth.role() = 'authenticated');
create policy "organizations_manage" on public.organizations
  for all using (public.has_permission('org.manage')) with check (public.has_permission('org.manage'));

-- branches: visible to org-wide roles, admins, or anyone with a position at
-- that specific branch. Managed by admins only.
create policy "branches_select" on public.branches
  for select using (public.can_view_branch(id));
create policy "branches_manage" on public.branches
  for all using (public.has_permission('org.manage')) with check (public.has_permission('org.manage'));

-- departments: same shape as branches, one level down.
create policy "departments_select" on public.departments
  for select using (public.can_view_department(id));
create policy "departments_manage" on public.departments
  for all using (public.has_permission('org.manage')) with check (public.has_permission('org.manage'));

-- banking_accounts: finance-privileged roles only, scoped to their branch.
create policy "banking_accounts_select" on public.banking_accounts
  for select using (public.has_permission('banking.view') and public.can_view_branch(branch_id));
create policy "banking_accounts_manage" on public.banking_accounts
  for all using (public.has_permission('banking.manage')) with check (public.has_permission('banking.manage'));

-- profiles: everyone can see their own profile; admins/user-managers see all;
-- self-service updates are limited to one's own row.
create policy "profiles_select_self_or_admin" on public.profiles
  for select using (id = auth.uid() or public.is_admin() or public.has_permission('users.manage'));
create policy "profiles_update_self" on public.profiles
  for update using (id = auth.uid()) with check (id = auth.uid());
create policy "profiles_manage_admin" on public.profiles
  for all using (public.has_permission('users.manage')) with check (public.has_permission('users.manage'));

-- roles / permissions / role_permissions: readable by every authenticated
-- user so the admin UI can render a full permission preview while assigning
-- a role, before the assignment is saved. Only admins edit the catalog.
create policy "roles_select" on public.roles
  for select using (auth.role() = 'authenticated');
create policy "roles_manage" on public.roles
  for all using (public.has_permission('roles.assign')) with check (public.has_permission('roles.assign'));

create policy "permissions_select" on public.permissions
  for select using (auth.role() = 'authenticated');
create policy "permissions_manage" on public.permissions
  for all using (public.has_permission('roles.assign')) with check (public.has_permission('roles.assign'));

create policy "role_permissions_select" on public.role_permissions
  for select using (auth.role() = 'authenticated');
create policy "role_permissions_manage" on public.role_permissions
  for all using (public.has_permission('roles.assign')) with check (public.has_permission('roles.assign'));

-- positions: the org chart is visible to all authenticated users (needed to
-- pick approvers / preview routing); only admins create or retire positions.
create policy "positions_select" on public.positions
  for select using (auth.role() = 'authenticated');
create policy "positions_manage" on public.positions
  for all using (public.has_permission('roles.assign')) with check (public.has_permission('roles.assign'));

-- position_assignments: users see their own assignment history; admins/user-
-- managers see and manage everyone's.
create policy "position_assignments_select" on public.position_assignments
  for select using (profile_id = auth.uid() or public.is_admin() or public.has_permission('users.manage'));
create policy "position_assignments_manage" on public.position_assignments
  for all using (public.has_permission('roles.assign')) with check (public.has_permission('roles.assign'));

-- ── Permission preview views (for the admin user/position-creation UI) ──

-- Every permission a given role grants -- drive the "here's exactly what
-- this person will be able to do" preview shown before an admin confirms
-- a new position assignment.
create view public.v_role_permission_preview
  with (security_invoker = true) as
select
  r.id          as role_id,
  r.code        as role_code,
  r.name        as role_name,
  r.scope       as role_scope,
  perm.code     as permission_code,
  perm.description as permission_description,
  perm.category as permission_category
from public.roles r
join public.role_permissions rp on rp.role_id = r.id
join public.permissions perm on perm.id = rp.permission_id
order by r.code, perm.category, perm.code;

-- Who currently holds each position -- this is what approval routing and
-- the admin org chart both read, so "who" can change without touching
-- workflow configuration.
create view public.v_active_position_holders
  with (security_invoker = true) as
select
  pos.id            as position_id,
  r.code            as role_code,
  r.name            as role_name,
  pos.branch_id,
  pos.department_id,
  pa.profile_id,
  pr.full_name,
  pr.email,
  pa.start_date
from public.positions pos
join public.roles r on r.id = pos.role_id
left join public.position_assignments pa on pa.position_id = pos.id and pa.end_date is null
left join public.profiles pr on pr.id = pa.profile_id
where pos.is_active;

-- ── Grants for the `authenticated` PostgREST role ───────────────────────
--
-- RLS policies alone are not enough: Postgres checks table-level GRANTs
-- before it ever evaluates a row-security policy. Supabase's `authenticated`
-- role starts with no DML privileges on tables you create, so without these
-- grants every client request would fail with "permission denied" rather
-- than being filtered by the policies above. `anon` intentionally gets
-- nothing -- this is an internal staff system, not a public-facing one.
grant usage on schema public to authenticated;
grant select, insert, update, delete on
  public.organizations, public.branches, public.departments, public.banking_accounts,
  public.profiles, public.roles, public.permissions, public.role_permissions,
  public.positions, public.position_assignments
  to authenticated;
grant select on public.v_role_permission_preview, public.v_active_position_holders to authenticated;
alter default privileges in schema public grant select, insert, update, delete on tables to authenticated;

-- Only the auth.uid()-based wrappers are exposed to clients -- never the
-- *_for(target_profile, ...) variants, which would let any authenticated
-- user query an arbitrary other user's positions/permissions over RPC.
-- Those stay reserved for the trusted service roles (see purchase_svc /
-- approval_svc migrations).
grant execute on function
  public.my_positions(), public.is_admin(), public.has_permission(text),
  public.can_view_branch(uuid), public.can_view_department(uuid)
  to authenticated;
