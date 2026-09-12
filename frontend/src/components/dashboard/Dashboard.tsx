"use client";

import { useState } from "react";
import Icon from "@/components/ui/Icon";
import TopAppBar from "@/components/layout/TopAppBar";
import BottomNav from "@/components/layout/BottomNav";
import RequisitionFlow from "@/components/requisition/RequisitionFlow";

const activity = [
  {
    title: "Equipment Purchase",
    detail: "Approved by HoF",
    time: "2h ago",
    icon: "check_circle",
    iconBg: "bg-secondary-container",
    iconColor: "text-on-secondary-container",
  },
  {
    title: "Office Supplies",
    detail: "Modified by Lead Pastor (Amount reduced to ₦80,000)",
    time: "4h ago",
    icon: "edit_note",
    iconBg: "bg-tertiary-container",
    iconColor: "text-on-tertiary-container",
  },
  {
    title: "Monthly Internet",
    detail: "Rejected by Finance Lead",
    time: "Yesterday",
    icon: "cancel",
    iconBg: "bg-error-container",
    iconColor: "text-on-error-container",
  },
];

export default function Dashboard() {
  const [showRequisition, setShowRequisition] = useState(false);

  if (showRequisition) {
    return <RequisitionFlow onClose={() => setShowRequisition(false)} />;
  }

  return (
    <div className="flex flex-col min-h-screen">
      <TopAppBar title="Concurrent" />
      <main className="flex-1 mt-16 mb-20 px-4 py-6 overflow-y-auto">
        <section className="mb-6">
          <h2 className="text-xl font-bold text-on-surface">Welcome, Media Team</h2>
          <p className="text-sm text-on-surface-variant">Your financial overview for today.</p>
        </section>

        <section className="mb-6 bg-surface-container-lowest rounded-xl shadow-sm overflow-hidden border-t-4 border-primary">
          <div className="p-4">
            <h3 className="text-xs font-semibold text-on-surface-variant mb-4 tracking-wider uppercase">
              Your Requisitions Status
            </h3>
            <div className="grid grid-cols-2 gap-4">
              <div className="p-4 rounded-lg bg-surface-container-low flex flex-col items-start">
                <span className="text-2xl font-bold text-primary">2</span>
                <span className="text-xs text-on-surface-variant">Pending</span>
              </div>
              <div className="p-4 rounded-lg bg-secondary-container flex flex-col items-start">
                <span className="text-2xl font-bold text-on-secondary-container">1</span>
                <span className="text-xs text-on-secondary-container">Approved</span>
              </div>
              <div className="p-4 rounded-lg bg-error-container flex flex-col items-start">
                <span className="text-2xl font-bold text-error">0</span>
                <span className="text-xs text-on-error-container">Rejected</span>
              </div>
              <div className="p-4 rounded-lg bg-surface-container-high flex flex-col items-start">
                <span className="text-2xl font-bold text-on-surface">5</span>
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
              {activity.map((item, index) => (
                <div
                  key={index}
                  className={`flex gap-4 ${
                    index !== activity.length - 1 ? "pb-4 border-b border-outline-variant" : ""
                  }`}
                >
                  <div className={`w-10 h-10 rounded-full ${item.iconBg} flex items-center justify-center shrink-0`}>
                    <Icon name={item.icon} className={`${item.iconColor} text-[20px]`} filled />
                  </div>
                  <div className="flex flex-col">
                    <h4 className="text-sm font-semibold text-on-surface">{item.title}</h4>
                    <p className="text-sm text-on-surface-variant">{item.detail}</p>
                    <span className="text-[11px] text-outline mt-1">{item.time}</span>
                  </div>
                </div>
              ))}
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
