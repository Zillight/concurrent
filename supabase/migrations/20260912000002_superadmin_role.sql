-- Phase 2b: superadmin role
--
-- Hierarchy: superadmin > admin > leads (lead_pastor / head_of_finance /
-- finance_lead) > departmental_head.
--
-- superadmin is the sole holder of the user-management powers:
--   users.manage  — create accounts
--   roles.assign  — assign people to positions
--   (+ password resets, which are gated on users.manage in the
--    admin-users edge function)

insert into public.roles (code, name, description, scope) values
  ('superadmin', 'Super Admin',
   'Root administrator. Sole holder of account creation, position assignment, and password resets.',
   'organization');

-- superadmin gets every permission in the catalog
insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from public.roles r, public.permissions p
where r.code = 'superadmin';

-- strip user/role management from admin — superadmin only from here on
delete from public.role_permissions rp
using public.roles r, public.permissions p
where rp.role_id = r.id
  and rp.permission_id = p.id
  and r.code = 'admin'
  and p.code in ('users.manage', 'roles.assign');
