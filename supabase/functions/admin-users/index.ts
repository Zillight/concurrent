// Edge Function: admin-users
//
// Staff-only auth means there's no public sign-up — admins create accounts
// and reset passwords here. The service_role key never leaves this function.
//
// Authorization: caller must be authenticated AND hold the users.manage
// permission (checked via public.has_permission_for, which resolves through
// the caller's active position assignments).
//
// POST body: { "action": "create_user",    "email", "password", "full_name",
//              "role_code", "branch_id"?, "department_id"? }  — role_code and
//              its scope ids are REQUIRED; no account exists without a position.
//              Multi-department users: call an "assign_position" flow per dept
//              (added when the admin UI lands).
//            { "action": "reset_password", "user_id", "password" }
//            { "action": "deactivate",     "user_id" }
//            { "action": "reactivate",     "user_id" }
//            { "action": "update_user",    "user_id", "full_name"?, "email"? }
//            { "action": "delete_user",    "user_id" }
//            { "action": "assign_position",   "user_id", "role_code",
//              "branch_id"?, "department_id"? }
//            { "action": "unassign_position", "user_id", "position_id" }
//
// Deploy: npx supabase functions deploy admin-users
// Call:   POST <project>/functions/v1/admin-users with the caller's JWT.

import { createClient } from "jsr:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return json({ error: "Missing Authorization header" }, 401);

  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  // Who is calling?
  const { data: { user: caller }, error: authError } =
    await admin.auth.getUser(authHeader.replace("Bearer ", ""));
  if (authError || !caller) return json({ error: "Invalid or expired session" }, 401);

  const body = await req.json().catch(() => ({}));
  const { action } = body;

  // Each action is gated on its own permission (superadmin holds both).
  const requiredPermission =
    action === "assign_position" || action === "unassign_position"
      ? "roles.assign"
      : "users.manage";

  const { data: allowed, error: permError } = await admin.rpc(
    "has_permission_for",
    { target_profile: caller.id, perm_code: requiredPermission },
  );
  if (permError || !allowed) {
    return json({ error: `Permission denied: ${requiredPermission}` }, 403);
  }

  // Normalize to a scopes array: [{ branch_id, department_id? }]
  const toScopes = (b: Record<string, unknown>) => {
    if (Array.isArray(b.scopes) && b.scopes.length) return b.scopes as {
      branch_id: string; department_id?: string;
    }[];
    if (b.branch_id) {
      return [{ branch_id: b.branch_id as string, department_id: b.department_id as string | undefined }];
    }
    return [];
  };

  // Find or create the position seat for (role, branch, department).
  const findOrCreateSeat = async (
    roleId: string, branchId: string | null, departmentId: string | null,
  ) => {
    let q = admin.from("positions").select("id").eq("role_id", roleId).eq("is_active", true);
    q = branchId ? q.eq("branch_id", branchId) : q.is("branch_id", null);
    q = departmentId ? q.eq("department_id", departmentId) : q.is("department_id", null);
    const { data: existing } = await q.maybeSingle();
    if (existing) return { position: existing, error: null };

    const { data: created, error } = await admin
      .from("positions")
      .insert({ role_id: roleId, branch_id: branchId, department_id: departmentId })
      .select("id")
      .single();
    return { position: created, error };
  };

  // Assign a profile to every scope in the list, honouring role semantics:
  //   member      -> department_members rows (no seat, view-only)
  //   leader_2    -> one group seat at the branch + position_departments coverage
  //   dept roles  -> one seat per (branch, dept)
  //   branch/org  -> one seat per scope / single org seat
  const assignScopes = async (
    profileId: string,
    role: { id: string; code: string; scope: string },
    scopes: { branch_id: string; department_id?: string }[],
  ) => {
    const results: string[] = [];

    if (role.code === "member") {
      const rows = scopes
        .filter((s) => s.department_id)
        .map((s) => ({ profile_id: profileId, department_id: s.department_id }));
      if (!rows.length) return { error: "member role requires at least one department_id" };
      const { error } = await admin.from("department_members").upsert(rows);
      return error ? { error: error.message } : { results: ["membership"] };
    }

    if (role.scope === "organization") {
      const { position, error } = await findOrCreateSeat(role.id, null, null);
      if (error) return { error: error.message };
      const { error: aErr } = await admin
        .from("position_assignments")
        .insert({ position_id: position.id, profile_id: profileId });
      return aErr ? { error: aErr.message } : { results: [position.id] };
    }

    for (const s of scopes) {
      if (role.scope === "group") {
        // One seat per branch; departments become its coverage list.
        const { position, error } = await findOrCreateSeat(role.id, s.branch_id, null);
        if (error) return { error: error.message };
        if (s.department_id) {
          await admin.from("position_departments").upsert({
            position_id: position.id, department_id: s.department_id,
          });
        }
        const { error: aErr } = await admin
          .from("position_assignments")
          .upsert({ position_id: position.id, profile_id: profileId });
        if (aErr) return { error: aErr.message };
        results.push(position.id);
      } else {
        if (role.scope === "department" && !s.department_id) {
          return { error: "department-scoped roles require department_id in each scope" };
        }
        const { position, error } = await findOrCreateSeat(
          role.id, s.branch_id, role.scope === "department" ? s.department_id! : null,
        );
        if (error) return { error: error.message };
        const { error: aErr } = await admin
          .from("position_assignments")
          .insert({ position_id: position.id, profile_id: profileId });
        if (aErr) return { error: aErr.message };
        results.push(position.id);
      }
    }
    return { results };
  };

  switch (action) {
    case "create_user": {
      // No account without a role + scope.
      const { email, password, full_name, role_code } = body;
      const scopes = toScopes(body);
      if (!email || !password || !role_code) {
        return json({ error: "email, password and role_code are required" }, 400);
      }

      const { data: role } = await admin
        .from("roles")
        .select("id, code, scope")
        .eq("code", role_code)
        .single();
      if (!role) return json({ error: `Unknown role_code: ${role_code}` }, 400);
      if (role.scope !== "organization" && !scopes.length) {
        return json({ error: "non-organization roles require at least one scope" }, 400);
      }

      const { data, error } = await admin.auth.admin.createUser({
        email,
        password,
        email_confirm: true, // staff accounts skip the confirmation email
        user_metadata: { full_name: full_name ?? email },
      });
      if (error) return json({ error: error.message }, 400);

      const { results, error: assignErr } = await assignScopes(
        data.user.id, role, scopes,
      );
      if (assignErr) {
        return json(
          { error: `User created but assignment failed: ${assignErr}`, user_id: data.user.id },
          500,
        );
      }

      return json(
        { user: { id: data.user.id, email: data.user.email }, assignments: results },
        201,
      );
    }

    case "assign_position": {
      const { user_id, role_code } = body;
      const scopes = toScopes(body);
      if (!user_id || !role_code) {
        return json({ error: "user_id and role_code are required" }, 400);
      }

      const { data: role } = await admin
        .from("roles")
        .select("id, code, scope")
        .eq("code", role_code)
        .single();
      if (!role) return json({ error: `Unknown role_code: ${role_code}` }, 400);
      if (role.scope !== "organization" && !scopes.length) {
        return json({ error: "non-organization roles require at least one scope" }, 400);
      }

      const { results, error } = await assignScopes(user_id, role, scopes);
      if (error) return json({ error }, 409);
      return json({ assignments: results });
    }

    case "unassign_position": {
      // End-date the caller-out's active assignment on a position — the seat
      // frees up and all routing/permissions reroute immediately.
      const { user_id, position_id } = body;
      if (!user_id || !position_id) {
        return json({ error: "user_id and position_id are required" }, 400);
      }
      const { error } = await admin
        .from("position_assignments")
        .update({ end_date: new Date().toISOString().slice(0, 10) })
        .eq("position_id", position_id)
        .eq("profile_id", user_id)
        .is("end_date", null);
      if (error) return json({ error: error.message }, 500);
      return json({ ok: true });
    }

    case "reset_password": {
      const { user_id, password } = body;
      if (!user_id || !password) {
        return json({ error: "user_id and password are required" }, 400);
      }
      const { error } = await admin.auth.admin.updateUserById(user_id, { password });
      if (error) return json({ error: error.message }, 400);
      return json({ ok: true });
    }

    case "deactivate": {
      const { user_id } = body;
      if (!user_id) return json({ error: "user_id is required" }, 400);
      // Banning blocks login; the profile stays for audit/history.
      const { error } = await admin.auth.admin.updateUserById(user_id, {
        ban_duration: "876000h", // ~100 years = effectively permanent
      });
      if (error) return json({ error: error.message }, 400);
      await admin.from("profiles").update({ is_active: false }).eq("id", user_id);
      return json({ ok: true });
    }

    case "reactivate": {
      const { user_id } = body;
      if (!user_id) return json({ error: "user_id is required" }, 400);
      const { error } = await admin.auth.admin.updateUserById(user_id, {
        ban_duration: "none",
      });
      if (error) return json({ error: error.message }, 400);
      await admin.from("profiles").update({ is_active: true }).eq("id", user_id);
      return json({ ok: true });
    }

    case "update_user": {
      // Edit name/email. Email change goes through auth so login moves with it;
      // the profiles row mirrors whatever auth accepts.
      const { user_id, full_name, email } = body;
      if (!user_id) return json({ error: "user_id is required" }, 400);
      if (!full_name && !email) {
        return json({ error: "nothing to update" }, 400);
      }

      if (email) {
        const { error } = await admin.auth.admin.updateUserById(user_id, {
          email,
          email_confirm: true, // admin-set emails skip verification
        });
        if (error) return json({ error: error.message }, 400);
      }

      const updates: Record<string, string> = {};
      if (full_name) updates.full_name = full_name;
      if (email) updates.email = email;
      const { error } = await admin
        .from("profiles")
        .update(updates)
        .eq("id", user_id);
      if (error) return json({ error: error.message }, 500);
      return json({ ok: true });
    }

    case "delete_user": {
      // Hard delete — profiles cascade, history rows keep their audit text.
      const { user_id } = body;
      if (!user_id) return json({ error: "user_id is required" }, 400);
      if (user_id === caller.id) {
        return json({ error: "Cannot delete your own account" }, 400);
      }
      const { error } = await admin.auth.admin.deleteUser(user_id);
      if (error) return json({ error: error.message }, 400);
      return json({ ok: true });
    }

    default:
      return json({ error: `Unknown action: ${action}` }, 400);
  }
});
