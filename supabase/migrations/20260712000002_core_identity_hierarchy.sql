-- Foundation & Identity: organizational hierarchy + identity + RBAC catalog
--
-- Hierarchy: organizations -> branches -> departments
-- Identity:  auth.users -> profiles
-- RBAC:      roles -> permissions (via role_permissions)
-- Position-based routing: positions (a role scoped to a branch/department)
--            -> position_assignments (who currently/historically holds it)
--
-- The key design decision for "identity mapping": approval workflows and
-- permission checks always reference a POSITION, never a profile/user id
-- directly. Swapping who holds a position (position_assignments) instantly
-- redirects all routing and permissions without touching workflow config.

-- ── Organizational hierarchy ────────────────────────────────────────────

create table public.organizations (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  legal_name  text,
  timezone    text not null default 'Africa/Lagos',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table public.branches (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name            text not null,
  code            text not null,
  address         text,
  city            text,
  country         text not null default 'Nigeria',
  is_active       boolean not null default true,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (organization_id, name),
  unique (organization_id, code)
);

create table public.departments (
  id          uuid primary key default gen_random_uuid(),
  branch_id   uuid not null references public.branches(id) on delete cascade,
  name        text not null,
  code        text,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (branch_id, name)
);

-- account_number stores only the account number itself; this is Foundation-
-- phase modeling for the admin config UI. For production, move the raw
-- account number into Supabase Vault (supabase.com/docs/guides/database/vault)
-- and keep only a masked/last-4 projection here.
create table public.banking_accounts (
  id             uuid primary key default gen_random_uuid(),
  branch_id      uuid not null references public.branches(id) on delete cascade,
  account_name   text not null,
  account_number text not null,
  bank_name      text not null,
  currency       text not null default 'NGN',
  account_type   text not null default 'operational'
                 check (account_type in ('operational', 'disbursement', 'savings', 'other')),
  is_active      boolean not null default true,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

-- ── Identity ─────────────────────────────────────────────────────────────

create table public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  full_name   text not null,
  email       citext not null unique,
  phone       text,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- Auto-create a profile row whenever a new auth user signs up.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, email)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', new.email),
    new.email
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ── RBAC catalog ─────────────────────────────────────────────────────────

create table public.roles (
  id           uuid primary key default gen_random_uuid(),
  code         text not null unique,
  name         text not null,
  description  text,
  scope        text not null check (scope in ('organization', 'branch', 'department')),
  is_system    boolean not null default true,
  created_at   timestamptz not null default now()
);

create table public.permissions (
  id           uuid primary key default gen_random_uuid(),
  code         text not null unique,
  description  text not null,
  category     text not null check (category in ('admin', 'finance', 'approval', 'purchase'))
);

create table public.role_permissions (
  role_id       uuid not null references public.roles(id) on delete cascade,
  permission_id uuid not null references public.permissions(id) on delete cascade,
  primary key (role_id, permission_id)
);

-- ── Position-based routing ──────────────────────────────────────────────

-- A position is a role scoped to a specific place in the org hierarchy.
-- Org-wide roles (admin, lead_pastor, head_of_finance) leave branch_id and
-- department_id null. Branch-scoped roles (finance_lead) require branch_id.
-- Department-scoped roles (departmental_head) require both branch_id and
-- department_id.
create table public.positions (
  id             uuid primary key default gen_random_uuid(),
  role_id        uuid not null references public.roles(id),
  branch_id      uuid references public.branches(id) on delete cascade,
  department_id  uuid references public.departments(id) on delete cascade,
  title          text,
  is_active      boolean not null default true,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
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
  elsif role_scope = 'department' and (new.branch_id is null or new.department_id is null) then
    raise exception 'department-scoped roles require both branch_id and department_id';
  end if;

  return new;
end;
$$;

create trigger validate_position_scope_trigger
  before insert or update on public.positions
  for each row execute function public.validate_position_scope();

-- One unique position per (role, branch, department) combination.
create unique index positions_unique_scope_idx
  on public.positions (role_id, coalesce(branch_id, '00000000-0000-0000-0000-000000000000'),
                                 coalesce(department_id, '00000000-0000-0000-0000-000000000000'));

-- Who currently/historically holds a position. Only one active (end_date
-- is null) holder per position at a time -- this is the single point of
-- change when "the individual assigned to it changes".
create table public.position_assignments (
  id            uuid primary key default gen_random_uuid(),
  position_id   uuid not null references public.positions(id) on delete cascade,
  profile_id    uuid not null references public.profiles(id) on delete cascade,
  start_date    date not null default current_date,
  end_date      date,
  assigned_by   uuid references public.profiles(id),
  created_at    timestamptz not null default now(),
  check (end_date is null or end_date >= start_date)
);

create unique index position_assignments_one_active_idx
  on public.position_assignments (position_id)
  where (end_date is null);

-- ── updated_at triggers ──────────────────────────────────────────────────

create trigger set_updated_at before update on public.organizations
  for each row execute function public.set_updated_at();
create trigger set_updated_at before update on public.branches
  for each row execute function public.set_updated_at();
create trigger set_updated_at before update on public.departments
  for each row execute function public.set_updated_at();
create trigger set_updated_at before update on public.banking_accounts
  for each row execute function public.set_updated_at();
create trigger set_updated_at before update on public.profiles
  for each row execute function public.set_updated_at();
create trigger set_updated_at before update on public.positions
  for each row execute function public.set_updated_at();

-- ── Seed: the five core roles ────────────────────────────────────────────

insert into public.roles (code, name, description, scope) values
  ('admin',              'Admin',              'Full system configuration and user management access.', 'organization'),
  ('lead_pastor',        'Lead Pastor',         'Executive oversight; final sign-off on high-value requisitions.', 'organization'),
  ('head_of_finance',    'Head of Finance',     'Organization-wide financial oversight and final financial sign-off.', 'organization'),
  ('finance_lead',       'Finance Lead',        'Branch-level financial review and approval.', 'branch'),
  ('departmental_head',  'Departmental Head',   'Department-level requisition creation and first-line approval.', 'department');

-- ── Seed: permission catalog ─────────────────────────────────────────────

insert into public.permissions (code, description, category) values
  ('org.manage',                          'Manage organizations, branches, and departments',      'admin'),
  ('users.manage',                        'Create and deactivate user accounts',                  'admin'),
  ('roles.assign',                        'Assign users to positions',                            'admin'),
  ('banking.manage',                      'Create and edit banking accounts',                     'admin'),
  ('banking.view',                        'View banking account details',                         'finance'),
  ('requisition.approve.finance',         'Approve requisitions at the Finance Lead step',         'finance'),
  ('requisition.approve.head_of_finance', 'Give final financial sign-off on requisitions',         'finance'),
  ('requisition.approve.department',      'Approve requisitions at the Departmental Head step',    'approval'),
  ('requisition.approve.executive',       'Give executive (Lead Pastor) sign-off on requisitions', 'approval'),
  ('workflow.manage',                     'Configure approval workflow templates and steps',       'approval'),
  ('requisition.create',                  'Create a new purchase requisition',                    'purchase'),
  ('requisition.view.own',                'View requisitions within one''s own department',        'purchase'),
  ('requisition.view.all',                'View requisitions across all branches and departments', 'purchase');

-- ── Seed: role -> permission mapping ─────────────────────────────────────

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id from public.roles r, public.permissions p where r.code = 'admin';

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id from public.roles r join public.permissions p
  on p.code in ('requisition.approve.executive', 'requisition.view.all', 'banking.view')
where r.code = 'lead_pastor';

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id from public.roles r join public.permissions p
  on p.code in ('requisition.approve.head_of_finance', 'banking.manage', 'banking.view',
                'requisition.view.all', 'workflow.manage')
where r.code = 'head_of_finance';

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id from public.roles r join public.permissions p
  on p.code in ('requisition.approve.finance', 'banking.view', 'requisition.view.all')
where r.code = 'finance_lead';

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id from public.roles r join public.permissions p
  on p.code in ('requisition.create', 'requisition.approve.department', 'requisition.view.own')
where r.code = 'departmental_head';
