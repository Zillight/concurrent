"use client";

import Icon from "@/components/ui/Icon";
import { RequisitionItem } from "./types";

interface SubmissionPreviewProps {
  items: RequisitionItem[];
  currency: string;
  total: number;
  submitting: boolean;
  onConfirm: () => void;
  onBack: () => void;
}

export default function SubmissionPreview({
  items,
  currency,
  total,
  submitting,
  onConfirm,
  onBack,
}: SubmissionPreviewProps) {
  return (
    <div>
      <div className="mb-6 bg-white rounded-xl shadow-sm border-t-4 border-primary overflow-hidden">
        <div className="p-4 border-b border-outline-variant">
          <h3 className="text-sm font-bold text-on-surface">Submission Preview</h3>
          <p className="text-xs text-on-surface-variant">Review all items before submitting.</p>
        </div>
        <div className="divide-y divide-outline-variant">
          {items.map((item) => (
            <div key={item.id} className="flex items-center justify-between p-4">
              <div>
                <p className="text-sm font-semibold text-on-surface">
                  {item.name} <span className="text-on-surface-variant font-normal">x{item.quantity}</span>
                </p>
                {item.description && (
                  <p className="text-xs text-on-surface-variant">{item.description}</p>
                )}
              </div>
              <p className="text-sm font-bold text-primary">
                {currency}&nbsp;{(item.quantity * item.unitPrice).toLocaleString()}
              </p>
            </div>
          ))}
        </div>
      </div>

      <div className="bg-primary-container p-6 rounded-xl mb-8 flex flex-col items-center justify-center text-on-primary-container shadow-sm border border-primary">
        <span className="text-xs opacity-80 uppercase tracking-widest mb-1">Estimated Requisition Total</span>
        <span className="text-2xl font-extrabold">
          {currency}&nbsp;{total.toLocaleString()}
        </span>
      </div>

      <div className="flex gap-3 mb-6">
        <button
          onClick={onBack}
          className="flex-1 py-3 rounded-lg border border-outline text-on-surface-variant font-semibold"
        >
          Back
        </button>
        <button
          onClick={onConfirm}
          disabled={submitting}
          className="flex-1 py-3 rounded-lg bg-primary text-on-primary font-semibold shadow-sm flex items-center justify-center gap-2 disabled:opacity-60 active:scale-95 transition-transform"
        >
          {submitting ? (
            "Submitting..."
          ) : (
            <>
              <Icon name="send" className="text-[18px]" />
              Confirm Submission
            </>
          )}
        </button>
      </div>
    </div>
  );
}
