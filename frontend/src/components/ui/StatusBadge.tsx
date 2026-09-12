export type RequisitionStatus = "pending" | "approved" | "rejected" | "modified";

const statusConfig: Record<
  RequisitionStatus,
  { label: string; badgeClass: string; borderClass: string; icon: string; iconClass: string }
> = {
  pending: {
    label: "PENDING",
    badgeClass: "bg-primary-container text-on-primary-container",
    borderClass: "border-primary",
    icon: "hourglass_empty",
    iconClass: "text-primary",
  },
  approved: {
    label: "APPROVED",
    badgeClass: "bg-secondary-container text-on-secondary-container",
    borderClass: "border-secondary",
    icon: "check_circle",
    iconClass: "text-secondary",
  },
  rejected: {
    label: "REJECTED",
    badgeClass: "bg-error-container text-on-error-container",
    borderClass: "border-error",
    icon: "cancel",
    iconClass: "text-error",
  },
  modified: {
    label: "MODIFIED",
    badgeClass: "bg-tertiary-container text-on-tertiary-container",
    borderClass: "border-tertiary",
    icon: "edit_note",
    iconClass: "text-tertiary",
  },
};

export function getStatusConfig(status: RequisitionStatus) {
  return statusConfig[status];
}

export default function StatusBadge({ status }: { status: RequisitionStatus }) {
  const config = statusConfig[status];
  return (
    <span className={`px-2 py-0.5 rounded font-semibold text-[11px] ${config.badgeClass}`}>
      {config.label}
    </span>
  );
}
