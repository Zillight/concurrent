-- Make branches.code optional: derive it from the name when not provided.
drop function if exists public.create_branch(text, text, jsonb);

create or replace function public.create_branch(
  name        text,
  departments jsonb default '[]'::jsonb,
  code        text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org    uuid;
  v_branch uuid;
  v_code   text;
  v_dept   jsonb;
begin
  if not public.has_permission('org.manage') then
    raise exception 'Permission denied: org.manage';
  end if;

  select id into v_org from public.organizations order by created_at limit 1;
  if v_org is null then
    insert into public.organizations (name) values ('Church') returning id into v_org;
  end if;

  v_code := nullif(upper(trim(coalesce(code, ''))), '');
  if v_code is null then
    v_code := upper(substr(regexp_replace(name, '[^A-Za-z]', '', 'g'), 1, 4));
    if v_code = '' then
      v_code := 'BR';
    end if;
  end if;

  insert into public.branches (organization_id, name, code)
  values (v_org, create_branch.name, v_code)
  returning id into v_branch;

  for v_dept in select * from jsonb_array_elements(departments) loop
    insert into public.departments (branch_id, name)
    values (v_branch, v_dept->>'name');
  end loop;

  return v_branch;
end;
$$;

revoke execute on function public.create_branch(text, jsonb, text) from public, anon;
grant execute on function public.create_branch(text, jsonb, text) to authenticated;
