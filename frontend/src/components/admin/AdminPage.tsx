"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import Icon from "@/components/ui/Icon";
import TopAppBar from "@/components/layout/TopAppBar";
import BottomNav from "@/components/layout/BottomNav";
import { useUser } from "@/lib/UserContext";
import { supabase } from "@/lib/supabaseClient";

interface Role {
  id: string;
  code: string;
  name: string;
  scope: "organization" | "branch" | "group" | "department";
}
interface Branch { id: string; name: string }
interface Department { id: string; name: string; branch_id: string }

interface SeatInfo {
  position_id: string;
  title: string | null;
  roles: { code: string; name: string } | null;
  branches: { name: string } | null;
  departments: { name: string } | null;
}

interface UserRow {
  id: string;
  full_name: string;
  email: string;
  is_active: boolean;
  position_assignments: { end_date: string | null; positions: SeatInfo | null }[];
  department_members: { department_id: string }[];
}

export interface Scope {
  branch_id: string;
  department_id?: string;
}

const inputCls =
  "w-full px-4 py-3 rounded-xl bg-surface-container-low border border-outline-variant text-on-surface focus:outline-none focus:ring-2 focus:ring-primary";
const labelCls =
  "block text-xs font-semibold text-on-surface-variant mb-1 uppercase tracking-wider";

// Checkbox multi-select for scopes. What shows depends on the role's scope:
//   branch      -> branch checkboxes
//   department  -> department checkboxes (grouped under their branch)
//   group       -> departments (each becomes coverage for a per-branch seat)
//   organization-> nothing
function ScopeSelector({
  role,
  branches,
  departments,
  value,
  onChange,
}: {
  role: Role | undefined;
  branches: Branch[];
  departments: Department[];
  value: Scope[];
  onChange: (scopes: Scope[]) => void;
}) {
  if (!role || role.scope === "organization") return null;

  const needsBranch = role.scope === "branch";
  const needsDept = role.scope === "department" || role.scope === "group";

  const toggleBranch = (id: string) => {
    const has = value.some((s) => s.branch_id === id && !s.department_id);
    onChange(
      has
        ? value.filter((s) => !(s.branch_id === id && !s.department_id))
        : [...value, { branch_id: id }]
    );
  };

  const toggleDept = (d: Department) => {
    const has = value.some((s) => s.department_id === d.id);
    onChange(
      has
        ? value.filter((s) => s.department_id !== d.id)
        : [...value, { branch_id: d.branch_id, department_id: d.id }]
    );
  };

  const branchChecked = (id: string) => value.some((s) => s.branch_id === id && !s.department_id);
  const deptChecked = (id: string) => value.some((s) => s.department_id === id);

  return (
    <div className="space-y-3">
      {needsBranch && (
        <div>
          <label className={labelCls}>Branches</label>
          <div className="rounded-xl border border-outline-variant divide-y divide-outline-variant">
            {branches.map((b) => (
              <label key={b.id} className="flex items-center gap-3 px-4 py-2.5 cursor-pointer">
                <input
                  type="checkbox"
                  checked={branchChecked(b.id)}
                  onChange={() => toggleBranch(b.id)}
                  className="w-4 h-4 accent-primary"
                />
                <span className="text-sm text-on-surface">{b.name}</span>
              </label>
            ))}
          </div>
        </div>
      )}

      {needsDept && (
        <div>
          <label className={labelCls}>
            Departments{role.scope === "group" ? " (coverage)" : ""}
          </label>
          <div className="rounded-xl border border-outline-variant divide-y divide-outline-variant max-h-56 overflow-y-auto">
            {branches.map((b) => {
              const depts = departments.filter((d) => d.branch_id === b.id);
              if (!depts.length) return null;
              return (
                <div key={b.id}>
                  <p className="px-4 py-1.5 text-[11px] font-semibold uppercase tracking-wider text-on-surface-variant bg-surface-container-low">
                    {b.name}
                  </p>
                  {depts.map((d) => (
                    <label key={d.id} className="flex items-center gap-3 px-4 py-2.5 cursor-pointer">
                      <input
                        type="checkbox"
                        checked={deptChecked(d.id)}
                        onChange={() => toggleDept(d)}
                        className="w-4 h-4 accent-primary"
                      />
                      <span className="text-sm text-on-surface">{d.name}</span>
                    </label>
                  ))}
                </div>
              );
            })}
          </div>
        </div>
      )}
    </div>
  );
}

export default function AdminPage() {
  const router = useRouter();
  const { profile, permissions, loading: userLoading, signOut } = useUser();
  const canManageUsers = permissions.includes("users.manage");
  const canAssign = permissions.includes("roles.assign");
  const canManageOrg = permissions.includes("org.manage");
  const allowed = canManageUsers || canAssign || canManageOrg;

  const [users, setUsers] = useState<UserRow[]>([]);
  const [roles, setRoles] = useState<Role[]>([]);
  const [branches, setBranches] = useState<Branch[]>([]);
  const [departments, setDepartments] = useState<Department[]>([]);
  const [loading, setLoading] = useState(true);
  const [notice, setNotice] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  // Create-account form
  const [fullName, setFullName] = useState("");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [roleId, setRoleId] = useState("");
  const [scopes, setScopes] = useState<Scope[]>([]);
  const [creating, setCreating] = useState(false);

  // Org management
  const [branchName, setBranchName] = useState("");
  const [branchCode, setBranchCode] = useState("");
  const [branchDepts, setBranchDepts] = useState("");
  const [deptName, setDeptName] = useState("");
  const [deptBranchId, setDeptBranchId] = useState("");
  const [orgBusy, setOrgBusy] = useState(false);

  // Per-user expanded actions
  const [expandedUser, setExpandedUser] = useState<string | null>(null);
  const [assignRoleId, setAssignRoleId] = useState("");
  const [assignScopes, setAssignScopes] = useState<Scope[]>([]);
  const [resetPassword, setResetPassword] = useState("");
  const [busy, setBusy] = useState(false);

  const selectedRole = useMemo(() => roles.find((r) => r.id === roleId), [roles, roleId]);
  const assignRole = useMemo(() => roles.find((r) => r.id === assignRoleId), [roles, assignRoleId]);
  const deptNameById = useMemo(
    () => new Map(departments.map((d) => [d.id, d.name])),
    [departments]
  );

  const loadAll = useCallback(async () => {
    const [u, r, b, d] = await Promise.all([
      supabase
        .from("profiles")
        .select(
          "id, full_name, email, is_active, position_assignments(end_date, positions(id, title, roles(code, name), branches(name), departments(name))), department_members(department_id)"
        )
        .order("created_at"),
      supabase.from("roles").select("id, code, name, scope").order("level"),
      supabase.from("branches").select("id, name").order("name"),
      supabase.from("departments").select("id, name, branch_id").order("name"),
    ]);
    setUsers((u.data as unknown as UserRow[]) ?? []);
    setRoles(r.data ?? []);
    setBranches(b.data ?? []);
    setDepartments(d.data ?? []);
    setLoading(false);
  }, []);

  useEffect(() => {
    if (allowed) {
      Promise.all([
        supabase
          .from("profiles")
          .select(
            "id, full_name, email, is_active, position_assignments(end_date, positions(id, title, roles(code, name), branches(name), departments(name))), department_members(department_id)"
          )
          .order("created_at"),
        supabase.from("roles").select("id, code, name, scope").order("level"),
        supabase.from("branches").select("id, name").order("name"),
        supabase.from("departments").select("id, name, branch_id").order("name"),
      ]).then(([u, r, b, d]) => {
        setUsers((u.data as unknown as UserRow[]) ?? []);
        setRoles(r.data ?? []);
        setBranches(b.data ?? []);
        setDepartments(d.data ?? []);
        setLoading(false);
      });
    } else if (!userLoading) {
      Promise.resolve().then(() => setLoading(false));
    }
  }, [allowed, userLoading]);

  const invoke = async (body: Record<string, unknown>) => {
    const { data, error: fnError } = await supabase.functions.invoke("admin-users", { body });
    if (fnError) {
      const msg = data?.error ?? fnError.message;
      throw new Error(msg);
    }
    return data;
  };

  const handleCreate = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!selectedRole) return;
    if (selectedRole.scope !== "organization" && scopes.length === 0) {
      setError("Select at least one branch/department for this role.");
      return;
    }
    setCreating(true);
    setError(null);
    setNotice(null);
    try {
      await invoke({
        action: "create_user",
        email: email.trim(),
        password,
        full_name: fullName.trim(),
        role_code: selectedRole.code,
        scopes,
      });
      setNotice(`Account created for ${email.trim()} as ${selectedRole.name}.`);
      setFullName(""); setEmail(""); setPassword("");
      setRoleId(""); setScopes([]);
      loadAll();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to create account");
    } finally {
      setCreating(false);
    }
  };

  const handleCreateBranch = async (e: React.FormEvent) => {
    e.preventDefault();
    setOrgBusy(true);
    setError(null);
    try {
      const depts = branchDepts
        .split(",")
        .map((s) => s.trim())
        .filter(Boolean)
        .map((name) => ({ name }));
      const { error: rpcError } = await supabase.rpc("create_branch", {
        name: branchName.trim(),
        code: branchCode.trim().toUpperCase(),
        departments: depts,
      });
      if (rpcError) throw rpcError;
      setNotice(`Branch "${branchName.trim()}" created${depts.length ? ` with ${depts.length} department(s)` : ""}.`);
      setBranchName(""); setBranchCode(""); setBranchDepts("");
      loadAll();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to create branch");
    } finally {
      setOrgBusy(false);
    }
  };

  const handleCreateDept = async (e: React.FormEvent) => {
    e.preventDefault();
    setOrgBusy(true);
    setError(null);
    try {
      const { error: rpcError } = await supabase.rpc("create_department", {
        branch_id: deptBranchId,
        name: deptName.trim(),
      });
      if (rpcError) throw rpcError;
      setNotice(`Department "${deptName.trim()}" created.`);
      setDeptName("");
      loadAll();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to create department");
    } finally {
      setOrgBusy(false);
    }
  };

  const handleAssign = async (userId: string) => {
    if (!assignRole) return;
    if (assignRole.scope !== "organization" && assignScopes.length === 0) {
      setError("Select at least one scope.");
      return;
    }
    setBusy(true);
    setError(null);
    try {
      await invoke({
        action: "assign_position",
        user_id: userId,
        role_code: assignRole.code,
        scopes: assignScopes,
      });
      setNotice("Position assigned.");
      setAssignRoleId(""); setAssignScopes([]);
      loadAll();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Assignment failed");
    } finally {
      setBusy(false);
    }
  };

  const handleUnassign = async (userId: string, positionId: string) => {
    setBusy(true);
    setError(null);
    try {
      await invoke({ action: "unassign_position", user_id: userId, position_id: positionId });
      setNotice("Position removed.");
      loadAll();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to remove position");
    } finally {
      setBusy(false);
    }
  };

  const handleReset = async (userId: string) => {
    if (!resetPassword) return;
    setBusy(true);
    setError(null);
    try {
      await invoke({ action: "reset_password", user_id: userId, password: resetPassword });
      setNotice("Password reset.");
      setResetPassword("");
    } catch (err) {
      setError(err instanceof Error ? err.message : "Reset failed");
    } finally {
      setBusy(false);
    }
  };

  const handleDeactivate = async (userId: string) => {
    if (!confirm("Deactivate this account? They will no longer be able to sign in.")) return;
    setBusy(true);
    setError(null);
    try {
      await invoke({ action: "deactivate", user_id: userId });
      setNotice("Account deactivated.");
      loadAll();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Deactivate failed");
    } finally {
      setBusy(false);
    }
  };

  if (userLoading || loading) {
    return (
      <div className="flex flex-col min-h-screen">
        <TopAppBar title="Admin" onSignOut={signOut} />
        <main className="flex-1 mt-16 px-4 py-10 flex items-center justify-center">
          <p className="text-on-surface-variant">Loading…</p>
        </main>
      </div>
    );
  }

  if (!allowed) {
    return (
      <div className="flex flex-col min-h-screen">
        <TopAppBar title="Admin" onSignOut={signOut} />
        <main className="flex-1 mt-16 px-4 py-10 flex flex-col items-center justify-center text-center">
          <Icon name="lock" className="text-on-surface-variant text-4xl mb-3" />
          <p className="text-on-surface-variant">
            This area needs admin permission.
          </p>
        </main>
        <BottomNav active="admin" canApprove={false} onNavigate={(k) => k === "home" && router.push("/")} />
      </div>
    );
  }

  return (
    <div className="flex flex-col min-h-screen">
      <TopAppBar title="Admin" onSignOut={signOut} />
      <main className="flex-1 mt-16 mb-20 px-4 py-6 overflow-y-auto">
        <h2 className="text-xl font-bold text-on-surface mb-1">People &amp; Organization</h2>
        <p className="text-sm text-on-surface-variant mb-6">
          Signed in as {profile?.full_name}
        </p>

        {notice && (
          <p className="text-sm bg-secondary-container text-on-secondary-container rounded-lg px-4 py-3 mb-4">
            {notice}
          </p>
        )}
        {error && (
          <p className="text-sm bg-error-container text-on-error-container rounded-lg px-4 py-3 mb-4">
            {error}
          </p>
        )}

        {canManageOrg && (
          <section className="bg-surface-container-lowest rounded-xl shadow-sm p-4 mb-6">
            <h3 className="text-xs font-semibold text-on-surface-variant mb-4 tracking-wider uppercase">
              Organization
            </h3>
            <form onSubmit={handleCreateBranch} className="space-y-3 mb-4">
              <p className="text-sm font-semibold text-on-surface">New branch</p>
              <div className="flex gap-2">
                <input required placeholder="Branch name (e.g. Ikeja)" value={branchName}
                  onChange={(e) => setBranchName(e.target.value)} className={inputCls} />
                <input required placeholder="Code" value={branchCode} maxLength={6}
                  onChange={(e) => setBranchCode(e.target.value)} className={`${inputCls} w-24`} />
              </div>
              <input
                placeholder="Departments, comma-separated (e.g. Media, Ushering, Welfare)"
                value={branchDepts}
                onChange={(e) => setBranchDepts(e.target.value)}
                className={inputCls}
              />
              <button type="submit" disabled={orgBusy}
                className="w-full py-2.5 bg-primary text-on-primary text-sm font-semibold rounded-lg disabled:opacity-60">
                Create Branch + Departments
              </button>
            </form>

            <form onSubmit={handleCreateDept} className="space-y-3 pt-4 border-t border-outline-variant">
              <p className="text-sm font-semibold text-on-surface">Add department to a branch</p>
              <div className="flex gap-2">
                <select required value={deptBranchId} onChange={(e) => setDeptBranchId(e.target.value)} className={inputCls}>
                  <option value="" disabled>Branch</option>
                  {branches.map((b) => (
                    <option key={b.id} value={b.id}>{b.name}</option>
                  ))}
                </select>
                <input required placeholder="Department name" value={deptName}
                  onChange={(e) => setDeptName(e.target.value)} className={inputCls} />
              </div>
              <button type="submit" disabled={orgBusy || !deptBranchId}
                className="w-full py-2.5 bg-surface-container-high text-on-surface text-sm font-semibold rounded-lg disabled:opacity-60">
                Add Department
              </button>
            </form>
          </section>
        )}

        {canManageUsers && (
          <section className="bg-surface-container-lowest rounded-xl shadow-sm p-4 mb-6">
            <h3 className="text-xs font-semibold text-on-surface-variant mb-4 tracking-wider uppercase">
              Create account
            </h3>
            <form onSubmit={handleCreate} className="space-y-3">
              <input required placeholder="Full name" value={fullName}
                onChange={(e) => setFullName(e.target.value)} className={inputCls} />
              <input required type="email" placeholder="Email" value={email}
                onChange={(e) => setEmail(e.target.value)} className={inputCls} />
              <input required type="password" placeholder="Temporary password" value={password}
                onChange={(e) => setPassword(e.target.value)} className={inputCls} />

              <div>
                <label className={labelCls}>Role</label>
                <select required value={roleId}
                  onChange={(e) => { setRoleId(e.target.value); setScopes([]); }}
                  className={inputCls}>
                  <option value="" disabled>Select a role</option>
                  {roles.filter((r) => r.code !== "superadmin").map((r) => (
                    <option key={r.id} value={r.id}>{r.name}</option>
                  ))}
                </select>
              </div>

              <ScopeSelector
                role={selectedRole}
                branches={branches}
                departments={departments}
                value={scopes}
                onChange={setScopes}
              />

              <button type="submit" disabled={creating}
                className="w-full py-3 bg-primary text-on-primary font-semibold rounded-xl active:scale-95 transition-transform disabled:opacity-60">
                {creating ? "Creating…" : "Create Account"}
              </button>
            </form>
          </section>
        )}

        <section>
          <h3 className="text-xs font-semibold text-on-surface-variant mb-3 tracking-wider uppercase">
            Users
          </h3>
          <div className="space-y-3">
            {users.map((u) => {
              const activeSeats = u.position_assignments.filter((a) => !a.end_date && a.positions);
              const expanded = expandedUser === u.id;
              return (
                <div key={u.id} className="bg-surface-container-lowest rounded-xl shadow-sm p-4">
                  <button onClick={() => setExpandedUser(expanded ? null : u.id)}
                    className="w-full flex justify-between items-start text-left">
                    <div>
                      <p className="text-sm font-semibold text-on-surface">
                        {u.full_name} {!u.is_active && <span className="text-error">(inactive)</span>}
                      </p>
                      <p className="text-xs text-on-surface-variant">{u.email}</p>
                      <div className="flex flex-wrap gap-1 mt-2">
                        {activeSeats.length === 0 && u.department_members.length === 0 && (
                          <span className="text-[11px] text-on-surface-variant italic">No positions</span>
                        )}
                        {activeSeats.map((a) => (
                          <span key={a.positions!.position_id}
                            className="text-[11px] px-2 py-0.5 rounded-full bg-primary-container text-on-primary-container">
                            {a.positions!.roles?.name}
                            {a.positions!.departments?.name ? ` · ${a.positions!.departments.name}` : ""}
                            {a.positions!.branches?.name ? ` · ${a.positions!.branches.name}` : ""}
                          </span>
                        ))}
                        {u.department_members.map((m) => (
                          <span key={m.department_id}
                            className="text-[11px] px-2 py-0.5 rounded-full bg-surface-container-high text-on-surface-variant">
                            Member · {deptNameById.get(m.department_id) ?? "?"}
                          </span>
                        ))}
                      </div>
                    </div>
                    <Icon name={expanded ? "expand_less" : "expand_more"} className="text-on-surface-variant" />
                  </button>

                  {expanded && (
                    <div className="mt-4 pt-4 border-t border-outline-variant space-y-4">
                      {canAssign && (
                        <div>
                          <label className={labelCls}>Assign position / membership</label>
                          <div className="space-y-2">
                            <select value={assignRoleId}
                              onChange={(e) => { setAssignRoleId(e.target.value); setAssignScopes([]); }}
                              className={inputCls}>
                              <option value="" disabled>Role</option>
                              {roles.filter((r) => r.code !== "superadmin").map((r) => (
                                <option key={r.id} value={r.id}>{r.name}</option>
                              ))}
                            </select>
                            <ScopeSelector
                              role={assignRole}
                              branches={branches}
                              departments={departments}
                              value={assignScopes}
                              onChange={setAssignScopes}
                            />
                            <button disabled={busy || !assignRole}
                              onClick={() => handleAssign(u.id)}
                              className="w-full py-2 bg-primary text-on-primary text-sm font-semibold rounded-lg disabled:opacity-60">
                              Assign
                            </button>
                          </div>
                        </div>
                      )}

                      {canAssign && activeSeats.length > 0 && (
                        <div>
                          <label className={labelCls}>Remove a seat</label>
                          <div className="flex flex-wrap gap-2">
                            {activeSeats.map((a) => (
                              <button key={a.positions!.position_id} disabled={busy}
                                onClick={() => handleUnassign(u.id, a.positions!.position_id)}
                                className="text-[11px] px-2 py-1 rounded-full bg-error-container text-on-error-container disabled:opacity-60">
                                ✕ {a.positions!.roles?.name}
                                {a.positions!.departments?.name ? ` · ${a.positions!.departments.name}` : ""}
                              </button>
                            ))}
                          </div>
                        </div>
                      )}

                      {canManageUsers && (
                        <>
                          <div>
                            <label className={labelCls}>Reset password</label>
                            <div className="flex gap-2">
                              <input type="password" placeholder="New password" value={resetPassword}
                                onChange={(e) => setResetPassword(e.target.value)} className={inputCls} />
                              <button disabled={busy || !resetPassword}
                                onClick={() => handleReset(u.id)}
                                className="px-4 bg-surface-container-high text-on-surface text-sm font-semibold rounded-lg disabled:opacity-60">
                                Reset
                              </button>
                            </div>
                          </div>
                          <button disabled={busy} onClick={() => handleDeactivate(u.id)}
                            className="w-full py-2 bg-error-container text-on-error-container text-sm font-semibold rounded-lg disabled:opacity-60">
                            Deactivate account
                          </button>
                        </>
                      )}
                    </div>
                  )}
                </div>
              );
            })}
          </div>
        </section>
      </main>
      <BottomNav
        active="admin"
        canApprove={permissions.some((p) => p.startsWith("requisition.approve"))}
        canAdmin={allowed}
        onNavigate={(key) => {
          if (key === "home") router.push("/");
          if (key === "approvals") router.push("/approvals");
          if (key === "board") router.push("/board");
        }}
      />
    </div>
  );
}
