"use client";

import { useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import TopAppBar from "@/components/layout/TopAppBar";
import BottomNav from "@/components/layout/BottomNav";
import { useUser } from "@/lib/UserContext";
import { supabase } from "@/lib/supabaseClient";

interface RequisitionRow {
  id: string;
  requisition_number: string;
  title: string;
  total_amount: number;
  currency: string;
  status: string;
  department_name: string;
  created_at: string;
}

const columns: { key: string; label: string; statuses: string[]; accent: string }[] = [
  { key: "pending", label: "Pending", statuses: ["submitted", "in_review"], accent: "border-tertiary" },
  { key: "approved", label: "Approved", statuses: ["approved"], accent: "border-secondary" },
  { key: "dispensed", label: "Dispensed", statuses: ["fulfilled"], accent: "border-primary" },
  { key: "rejected", label: "Rejected", statuses: ["rejected", "cancelled"], accent: "border-error" },
];

function money(amount: number, currency: string) {
  const symbol = currency === "USD" ? "$" : "₦";
  return `${symbol}${Number(amount).toLocaleString()}`;
}

export default function BoardPage() {
  const router = useRouter();
  const { permissions, signOut } = useUser();
  const [requisitions, setRequisitions] = useState<RequisitionRow[]>([]);
  const [loading, setLoading] = useState(true);

  const canApprove = permissions.some((p) => p.startsWith("requisition.approve"));
  const canAdmin = permissions.includes("users.manage") || permissions.includes("roles.assign");

  useEffect(() => {
    supabase.rpc("get_my_requisitions").then(({ data, error }) => {
      if (!error) setRequisitions(data ?? []);
      setLoading(false);
    });
  }, []);

  const grouped = useMemo(
    () =>
      columns.map((col) => ({
        ...col,
        items: requisitions.filter((r) => col.statuses.includes(r.status)),
      })),
    [requisitions]
  );

  return (
    <div className="flex flex-col min-h-screen">
      <TopAppBar title="Board" onSignOut={signOut} />
      <main className="flex-1 mt-16 mb-20 px-4 py-6 overflow-y-auto">
        <h2 className="text-xl font-bold text-on-surface mb-1">Requisition Flow</h2>
        <p className="text-sm text-on-surface-variant mb-6">
          Everything visible in your scope, grouped by status.
        </p>

        {loading ? (
          <p className="text-sm text-on-surface-variant">Loading…</p>
        ) : (
          <div className="space-y-6">
            {grouped.map((col) => (
              <section key={col.key}>
                <div className="flex items-center gap-2 mb-3">
                  <h3 className="text-xs font-semibold uppercase tracking-wider text-on-surface-variant">
                    {col.label}
                  </h3>
                  <span className="text-[11px] px-2 py-0.5 rounded-full bg-surface-container-high text-on-surface-variant">
                    {col.items.length}
                  </span>
                </div>
                <div className="space-y-2">
                  {col.items.length === 0 && (
                    <p className="text-xs text-on-surface-variant italic px-1">Empty</p>
                  )}
                  {col.items.map((r) => (
                    <div
                      key={r.id}
                      className={`bg-surface-container-lowest rounded-xl shadow-sm p-4 border-l-4 ${col.accent}`}
                    >
                      <div className="flex justify-between items-start">
                        <div>
                          <span className="text-xs font-semibold text-primary">
                            {r.requisition_number}
                          </span>
                          <h4 className="text-sm font-semibold text-on-surface">{r.title}</h4>
                          <p className="text-xs text-on-surface-variant mt-0.5">
                            {r.department_name} · {r.status.replace("_", " ")}
                          </p>
                        </div>
                        <span className="text-sm font-bold text-on-surface">
                          {money(r.total_amount, r.currency)}
                        </span>
                      </div>
                    </div>
                  ))}
                </div>
              </section>
            ))}
          </div>
        )}
      </main>
      <BottomNav
        active="board"
        canApprove={canApprove}
        canAdmin={canAdmin}
        onNavigate={(key) => {
          if (key === "home") router.push("/");
          if (key === "approvals") router.push("/approvals");
          if (key === "admin") router.push("/admin");
        }}
      />
    </div>
  );
}
