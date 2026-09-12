"use client";

import Icon from "@/components/ui/Icon";

const navItems = [
  { key: "home", label: "Home", icon: "home" },
  { key: "approvals", label: "Approvals", icon: "approval", approverOnly: true },
  { key: "board", label: "Board", icon: "view_kanban" },
  { key: "add", label: "Add", icon: "add_circle" },
  { key: "admin", label: "Admin", icon: "admin_panel_settings", adminOnly: true },
  { key: "profile", label: "Profile", icon: "person" },
];

interface BottomNavProps {
  active?: string;
  onNavigate?: (key: string) => void;
  canApprove?: boolean;
  canAdmin?: boolean;
}

export default function BottomNav({ active = "home", onNavigate, canApprove = false, canAdmin = false }: BottomNavProps) {
  return (
    <nav className="fixed bottom-0 w-full z-50 flex justify-around items-center px-4 py-2 bg-surface rounded-t-xl shadow-[0_-2px_10px_rgba(0,0,0,0.06)] border-t border-outline-variant">
      {navItems
        .filter((item) => (!item.approverOnly || canApprove) && (!item.adminOnly || canAdmin))
        .map((item) => {
          const isActive = item.key === active;
          return (
            <button
              key={item.key}
              onClick={() => onNavigate?.(item.key)}
              className={`flex flex-col items-center justify-center px-4 py-1 rounded-full transition-transform duration-200 active:scale-90 ${
                isActive ? "text-primary font-bold" : "text-on-surface-variant"
              }`}
            >
              <Icon name={item.icon} filled={isActive} />
              <span className="text-[11px] mt-1">{item.label}</span>
            </button>
          );
        })}
    </nav>
  );
}
