"use client";

import { useEffect, useState } from "react";
import Icon from "@/components/ui/Icon";
import TopAppBar from "@/components/layout/TopAppBar";
import BottomNav from "@/components/layout/BottomNav";
import RequisitionFlow from "@/components/requisition/RequisitionFlow";
import { useUser } from "@/lib/UserContext";
import { supabase } from "@/lib/supabaseClient";

interface ActivityItem {
  requisition_id: string;
  title: string;
  status: string;
  changed_at: string;
  note: string | null;
}

interface DashboardStats {
  pending: number;
  approved: number;
  rejected: number;
  completed: number;
  recent_activity: ActivityItem[];
}

const statusStyle: Record<string, { icon: string; bg: string; color: string }> = {
  submitted: { icon: "schedule", bg: "bg-surface-container-high", color: "text-on-surface-variant" },
  in_review: { icon: "rate_review", bg: "bg-tertiary-container", color: "text-on-tertiary-container" },
  approved: { icon: "check_circle", bg: "bg-secondary-container", color: "text-on-secondary-container" },
  rejected: { icon: "cancel", bg: "bg-error-container", color: "text-on-error-container" },
  fulfilled: { icon: "inventory_2", bg: "bg-secondary-container", color: "text-on-secondary-container" },
};

function relativeTime(iso: string) {
  const diffMs = Date.now() - new Date(iso).getTime();
  const minutes = Math.floor(diffMs / 60000);
  if (minutes < 60) return minutes <= 1 ? "Just now" : `${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.floor(hours / 24);
  return days === 1 ? "Yesterday" : `${days}d ago`;
}

export default function Dashboard() {
  const [showRequisition, setShowRequisition] = useState(false);
  const { profile, positions, loading, error: userError, signOut } = useUser();
  const [stats, setStats] = useState<DashboardStats | null>(null);

  const departmentPosition = positions.find((p) => p.department_id) ?? positions[0];
  const scopeLabel = departmentPosition?.department_name
    ?? departmentPosition?.branch_name
    ?? "Team";

  useEffect(() => {
    let cancelled = false;
    async function loadStats() {
      const { data, error } = await supabase.rpc("get_dashboard_stats");
      if (!cancelled && !error) setStats(data);
    }
    loadStats();
    return () => {
      cancelled = true;
    };
  }, [showRequisition]);

  if (showRequisition) {
    return <RequisitionFlow onClose={() => setShowRequisition(false)} />;
  }

  return (
    <div className="flex flex-col min-h-screen">
      <TopAppBar title="Concurrent" onSignOut={signOut} />
      <main className="flex-1 mt-16 mb-20 px-4 py-6 overflow-y-auto">
        <section className="mb-6">
          <h2 className="text-xl font-bold text-on-surface">
            Welcome, {loading ? "…" : (profile?.full_name ?? scopeLabel)}
          </h2>
          <p className="text-sm text-on-surface-variant">
            {departmentPosition?.role_name ?? ""}
            {departmentPosition?.department_name ? ` · ${departmentPosition.department_name}` : ""}
            {departmentPosition?.branch_name ? ` · ${departmentPosition.branch_name}` : ""}
          </p>
          {userError && (
            <p className="text-sm text-error mt-2">Could not load your profile: {userError}</p>
          )}
        </section>

        <section className="mb-6 bg-surface-container-lowest rounded-xl shadow-sm overflow-hidden border-t-4 border-primary">
          <div className="p-4">
            <h3 className="text-xs font-semibold text-on-surface-variant mb-4 tracking-wider uppercase">
              Your Requisitions Status
            </h3>
            <div className="grid grid-cols-2 gap-4">
              <div className="p-4 rounded-lg bg-surface-container-low flex flex-col items-start">
                <span className="text-2xl font-bold text-primary">{stats?.pending ?? "–"}</span>
                <span className="text-xs text-on-surface-variant">Pending</span>
              </div>
              <div className="p-4 rounded-lg bg-secondary-container flex flex-col items-start">
                <span className="text-2xl font-bold text-on-secondary-container">{stats?.approved ?? "–"}</span>
                <span className="text-xs text-on-secondary-container">Approved</span>
              </div>
              <div className="p-4 rounded-lg bg-error-container flex flex-col items-start">
                <span className="text-2xl font-bold text-error">{stats?.rejected ?? "–"}</span>
                <span className="text-xs text-on-error-container">Rejected</span>
              </div>
              <div className="p-4 rounded-lg bg-surface-container-high flex flex-col items-start">
                <span className="text-2xl font-bold text-on-surface">{stats?.completed ?? "–"}</span>
                <span className="text-xs text-on-surface-variant">Completed</span>
              </div>
            </div>
          </div>
        </section>

        <section className="mb-6 bg-surface-container-lowest rounded-xl shadow-sm overflow-hidden border-t-4 border-tertiary">
          <div className="p-4">
            <div className="flex justify-between items-center mb-4">
              <h3 className="text-xs font-semibold text-on-surface-variant tracking-wider uppercase">
                Recent Activity
              </h3>
              <Icon name="history" className="text-on-surface-variant text-sm" />
            </div>
            <div className="space-y-4">
              {stats?.recent_activity?.length ? (
                stats.recent_activity.slice(0, 5).map((item) => {
                  const style = statusStyle[item.status] ?? statusStyle.submitted;
                  return (
                    <div key={`${item.requisition_id}-${item.changed_at}`} className="flex gap-4">
                      <div className={`w-10 h-10 rounded-full ${style.bg} flex items-center justify-center shrink-0`}>
                        <Icon name={style.icon} className={`${style.color} text-[20px]`} filled />
                      </div>
                      <div className="flex flex-col">
                        <h4 className="text-sm font-semibold text-on-surface">{item.title}</h4>
                        <p className="text-sm text-on-surface-variant">
                          {item.note ?? `Status: ${item.status}`}
                        </p>
                        <span className="text-[11px] text-outline mt-1">{relativeTime(item.changed_at)}</span>
                      </div>
                    </div>
                  );
                })
              ) : (
                <p className="text-sm text-on-surface-variant">No activity yet.</p>
              )}
            </div>
          </div>
        </section>

        <button
          onClick={() => setShowRequisition(true)}
          className="w-full py-4 bg-primary text-on-primary font-semibold rounded-xl shadow-sm flex items-center justify-center gap-2 active:scale-95 transition-transform duration-150 mb-6"
        >
          <Icon name="add_circle" filled />
          New Bulk Requisition
        </button>
      </main>
      <BottomNav active="home" />
    </div>
  );
}
