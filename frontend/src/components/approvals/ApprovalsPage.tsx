"use client";

import { useCallback, useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import Icon from "@/components/ui/Icon";
import TopAppBar from "@/components/layout/TopAppBar";
import BottomNav from "@/components/layout/BottomNav";
import { useUser } from "@/lib/UserContext";
import { supabase } from "@/lib/supabaseClient";

interface PendingApproval {
  requisition_id: string;
  requisition_number: string;
  title: string;
  total_amount: number;
  currency: string;
  status: string;
  department_name: string;
  branch_name: string;
  requested_by_name: string;
  step_order: number;
  submitted_at: string;
}

interface RequisitionDetail {
  id: string;
  requisition_number: string;
  title: string;
  description: string | null;
  status: string;
  total_amount: number;
  currency: string;
  department_name: string;
  branch_name: string;
  requested_by_name: string;
  items: {
    id: string;
    item_name: string;
    quantity: number;
    unit_price: number;
    line_total: number;
    notes: string | null;
  }[];
  approval: { status: string; current_step: number } | null;
}

function money(amount: number, currency: string) {
  const symbol = currency === "USD" ? "$" : "₦";
  return `${symbol}${Number(amount).toLocaleString()}`;
}

export default function ApprovalsPage() {
  const router = useRouter();
  const { signOut, permissions } = useUser();
  const canApprove = permissions.some((p) => p.startsWith("requisition.approve"));
  const canAdmin = permissions.includes("users.manage") || permissions.includes("roles.assign");
  const [pending, setPending] = useState<PendingApproval[]>([]);
  const [loading, setLoading] = useState(true);
  const [selected, setSelected] = useState<RequisitionDetail | null>(null);
  const [detailLoading, setDetailLoading] = useState(false);
  const [comment, setComment] = useState("");
  const [acting, setActing] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const loadPending = useCallback(async () => {
    const { data, error: rpcError } = await supabase.rpc("get_my_pending_approvals");
    if (!rpcError) setPending(data ?? []);
    setLoading(false);
  }, []);

  useEffect(() => {
    supabase.rpc("get_my_pending_approvals").then(({ data, error: rpcError }) => {
      if (!rpcError) setPending(data ?? []);
      setLoading(false);
    });
  }, []);

  const openDetail = async (requisitionId: string) => {
    setDetailLoading(true);
    setComment("");
    setError(null);
    const { data, error: rpcError } = await supabase.rpc("get_requisition_details", {
      requisition_id: requisitionId,
    });
    if (rpcError) setError(rpcError.message);
    else setSelected(data);
    setDetailLoading(false);
  };

  const act = async (action: "approved" | "rejected") => {
    if (!selected) return;
    setActing(true);
    setError(null);
    const { error: rpcError } = await supabase.rpc("act_on_requisition", {
      requisition_id: selected.id,
      action,
      comment: comment.trim() || null,
    });
    setActing(false);
    if (rpcError) {
      setError(rpcError.message);
      return;
    }
    setSelected(null);
    loadPending();
  };

  if (detailLoading) {
    return (
      <div className="flex flex-col min-h-screen">
        <TopAppBar title="Approvals" onBack={() => setSelected(null)} onSignOut={signOut} />
        <main className="flex-1 mt-16 px-4 py-10 flex items-center justify-center">
          <p className="text-on-surface-variant">Loading…</p>
        </main>
      </div>
    );
  }

  if (selected) {
    return (
      <div className="flex flex-col min-h-screen">
        <TopAppBar title={selected.requisition_number} onBack={() => setSelected(null)} onSignOut={signOut} />
        <main className="flex-1 mt-16 mb-6 px-4 py-6 overflow-y-auto">
          <section className="mb-4">
            <h2 className="text-xl font-bold text-on-surface">{selected.title}</h2>
            <p className="text-sm text-on-surface-variant">
              {selected.department_name} · {selected.branch_name} · by {selected.requested_by_name}
            </p>
            {selected.description && (
              <p className="text-sm text-on-surface-variant mt-2">{selected.description}</p>
            )}
          </section>

          <section className="bg-surface-container-lowest rounded-xl shadow-sm overflow-hidden mb-4">
            {selected.items.map((item) => (
              <div key={item.id} className="flex justify-between items-center px-4 py-3 border-b border-outline-variant last:border-0">
                <div>
                  <p className="text-sm font-semibold text-on-surface">{item.item_name}</p>
                  <p className="text-xs text-on-surface-variant">
                    {item.quantity} × {money(item.unit_price, selected.currency)}
                    {item.notes ? ` · ${item.notes}` : ""}
                  </p>
                </div>
                <span className="text-sm font-bold text-on-surface">
                  {money(item.line_total, selected.currency)}
                </span>
              </div>
            ))}
            <div className="flex justify-between items-center px-4 py-3 bg-surface-container-low">
              <span className="text-xs font-semibold uppercase tracking-wider text-on-surface-variant">Total</span>
              <span className="text-lg font-extrabold text-primary">
                {money(selected.total_amount, selected.currency)}
              </span>
            </div>
          </section>

          <textarea
            value={comment}
            onChange={(e) => setComment(e.target.value)}
            placeholder="Comment (optional — recorded in the audit trail)"
            rows={3}
            className="w-full px-4 py-3 rounded-xl bg-surface-container-low border border-outline-variant text-on-surface focus:outline-none focus:ring-2 focus:ring-primary mb-4"
          />

          {error && (
            <p className="text-sm text-error bg-error-container rounded-lg px-4 py-3 mb-4">{error}</p>
          )}

          <div className="flex gap-3">
            <button
              onClick={() => act("rejected")}
              disabled={acting}
              className="flex-1 py-4 bg-error-container text-on-error-container font-semibold rounded-xl active:scale-95 transition-transform disabled:opacity-60"
            >
              Reject
            </button>
            <button
              onClick={() => act("approved")}
              disabled={acting}
              className="flex-1 py-4 bg-primary text-on-primary font-semibold rounded-xl active:scale-95 transition-transform disabled:opacity-60"
            >
              {acting ? "Working…" : "Approve"}
            </button>
          </div>
        </main>
      </div>
    );
  }

  return (
    <div className="flex flex-col min-h-screen">
      <TopAppBar title="Approvals" onSignOut={signOut} />
      <main className="flex-1 mt-16 mb-20 px-4 py-6 overflow-y-auto">
        <h2 className="text-xl font-bold text-on-surface mb-1">Awaiting your decision</h2>
        <p className="text-sm text-on-surface-variant mb-6">
          Requisitions routed to a position you currently hold.
        </p>

        {loading ? (
          <p className="text-sm text-on-surface-variant">Loading…</p>
        ) : pending.length === 0 ? (
          <div className="flex flex-col items-center py-12 text-center">
            <Icon name="task_alt" className="text-on-surface-variant text-4xl mb-3" />
            <p className="text-sm text-on-surface-variant">Nothing waiting on you right now.</p>
          </div>
        ) : (
          <div className="space-y-3">
            {pending.map((item) => (
              <button
                key={item.requisition_id}
                onClick={() => openDetail(item.requisition_id)}
                className="w-full text-left bg-surface-container-lowest rounded-xl shadow-sm p-4 border-l-4 border-primary active:scale-[0.98] transition-transform"
              >
                <div className="flex justify-between items-start mb-1">
                  <span className="text-xs font-semibold text-primary">{item.requisition_number}</span>
                  <span className="text-sm font-bold text-on-surface">
                    {money(item.total_amount, item.currency)}
                  </span>
                </div>
                <h3 className="text-sm font-semibold text-on-surface">{item.title}</h3>
                <p className="text-xs text-on-surface-variant mt-1">
                  {item.department_name} · {item.branch_name} · {item.requested_by_name}
                </p>
              </button>
            ))}
          </div>
        )}
      </main>
      <BottomNav
        active="approvals"
        canApprove={canApprove}
        canAdmin={canAdmin}
        onNavigate={(key) => {
          if (key === "home") router.push("/");
          if (key === "board") router.push("/board");
          if (key === "admin") router.push("/admin");
        }}
      />
    </div>
  );
}
