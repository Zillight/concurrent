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

  // May they manage users?
  const { data: allowed, error: permError } = await admin.rpc(
    "has_permission_for",
    { target_profile: caller.id, perm_code: "users.manage" },
  );
  if (permError || !allowed) {
    return json({ error: "Permission denied: users.manage" }, 403);
  }

  const body = await req.json().catch(() => ({}));
  const { action } = body;

  switch (action) {
    case "create_user": {
      // No account without a role + scope: department roles need
      // branch_id + department_id, branch roles need branch_id.
      const { email, password, full_name, role_code, branch_id, department_id } = body;
      if (!email || !password || !role_code) {
        return json({ error: "email, password and role_code are required" }, 400);
      }

      const { data: role } = await admin
        .from("roles")
        .select("id, scope")
        .eq("code", role_code)
        .single();
      if (!role) return json({ error: `Unknown role_code: ${role_code}` }, 400);
      if (role.scope === "department" && (!branch_id || !department_id)) {
        return json({ error: "department-scoped roles require branch_id and department_id" }, 400);
      }
      if (role.scope === "branch" && !branch_id) {
        return json({ error: "branch-scoped roles require branch_id" }, 400);
      }

      const { data, error } = await admin.auth.admin.createUser({
        email,
        password,
        email_confirm: true, // staff accounts skip the confirmation email
        user_metadata: { full_name: full_name ?? email },
      });
      if (error) return json({ error: error.message }, 400);

      // Find the position seat for (role, branch, department), creating it
      // if this combination hasn't been used before.
      let posQuery = admin
        .from("positions")
        .select("id")
        .eq("role_id", role.id)
        .eq("is_active", true);
      posQuery = branch_id ? posQuery.eq("branch_id", branch_id) : posQuery.is("branch_id", null);
      posQuery = department_id
        ? posQuery.eq("department_id", department_id)
        : posQuery.is("department_id", null);
      let { data: position } = await posQuery.maybeSingle();

      if (!position) {
        const { data: created, error: posError } = await admin
          .from("positions")
          .insert({
            role_id: role.id,
            branch_id: branch_id ?? null,
            department_id: department_id ?? null,
          })
          .select("id")
          .single();
        if (posError) {
          return json(
            { error: `User created but position failed: ${posError.message}`, user_id: data.user.id },
            500,
          );
        }
        position = created;
      }

      const { error: assignError } = await admin
        .from("position_assignments")
        .insert({ position_id: position.id, profile_id: data.user.id });
      if (assignError) {
        // Single-occupancy: an active holder already sits in this position.
        return json(
          {
            error: `User created but position assignment failed: ${assignError.message}`,
            user_id: data.user.id,
          },
          500,
        );
      }

      return json(
        { user: { id: data.user.id, email: data.user.email }, position_id: position.id },
        201,
      );
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
      return json({ ok: true });
    }

    default:
      return json({ error: `Unknown action: ${action}` }, 400);
  }
});
