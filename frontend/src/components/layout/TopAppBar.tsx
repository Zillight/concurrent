"use client";

import Icon from "@/components/ui/Icon";

interface TopAppBarProps {
  title?: string;
  onBack?: () => void;
  onSignOut?: () => void;
}

export default function TopAppBar({ title = "Concurrent", onBack, onSignOut }: TopAppBarProps) {
  return (
    <header className="fixed top-0 w-full z-50 flex justify-between items-center px-4 h-16 bg-surface border-b border-outline-variant shadow-sm">
      <div className="flex items-center gap-3">
        {onBack ? (
          <button
            onClick={onBack}
            className="p-2 -ml-2 rounded-full hover:bg-surface-container-high transition-colors active:scale-95"
          >
            <Icon name="arrow_back" className="text-primary" />
          </button>
        ) : (
          <Icon name="account_balance" className="text-primary" filled />
        )}
        <h1 className="text-lg font-bold text-primary">{title}</h1>
      </div>
      <div className="flex items-center">
        <button className="relative p-2 rounded-full hover:bg-surface-container-high transition-colors active:scale-95">
          <Icon name="notifications" className="text-on-surface-variant" />
          <span className="absolute top-1 right-1 bg-error text-white text-[10px] font-bold w-4 h-4 flex items-center justify-center rounded-full border-2 border-surface">
            3
          </span>
        </button>
        {onSignOut && (
          <button
            onClick={onSignOut}
            aria-label="Sign out"
            className="p-2 rounded-full hover:bg-surface-container-high transition-colors active:scale-95"
          >
            <Icon name="logout" className="text-on-surface-variant" />
          </button>
        )}
      </div>
    </header>
  );
}
