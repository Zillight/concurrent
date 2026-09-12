"use client";

import { useMemo, useState } from "react";
import Icon from "@/components/ui/Icon";
import TopAppBar from "@/components/layout/TopAppBar";
import ItemCard from "./ItemCard";
import ItemFormSheet from "./ItemFormSheet";
import SubmissionPreview from "./SubmissionPreview";
import { RequisitionItem } from "./types";
import { supabase } from "@/lib/supabaseClient";
import { useUser } from "@/lib/UserContext";

// TODO: Replace with the department's actual budget for the current budget year.
const DEPARTMENT_BUDGET_LIMIT_NGN = 500000;

interface RequisitionFlowProps {
  onClose: () => void;
}

type Step = "items" | "preview" | "success";

export default function RequisitionFlow({ onClose }: RequisitionFlowProps) {
  const { positions } = useUser();
  // Department-scoped positions the caller can submit under — a user may
  // belong to several departments and picks one per requisition.
  const deptPositions = useMemo(
    () => positions.filter((p) => p.branch_id && p.department_id),
    [positions]
  );
  const [step, setStep] = useState<Step>("items");
  const [items, setItems] = useState<RequisitionItem[]>([]);
  const [showAddItem, setShowAddItem] = useState(false);
  const [isUSD, setIsUSD] = useState(false);
  const [selectedPositionId, setSelectedPositionId] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const selectedPosition =
    deptPositions.find((p) => p.position_id === selectedPositionId) ?? deptPositions[0];

  const currency = isUSD ? "$" : "₦";

  const total = useMemo(
    () => items.reduce((sum, item) => sum + item.quantity * item.unitPrice, 0),
    [items]
  );

  const overBudget = !isUSD && total > DEPARTMENT_BUDGET_LIMIT_NGN;

  const handleAddItem = (item: RequisitionItem) => setItems((prev) => [...prev, item]);
  const handleRemoveItem = (id: string) => setItems((prev) => prev.filter((i) => i.id !== id));

  const handleConfirmSubmit = async () => {
    setSubmitting(true);
    setError(null);

    try {
      // Branch + department come from the position the caller selected —
      // the DB re-validates they actually hold it and derives
      // requested_by from auth.uid().
      if (!selectedPosition?.branch_id || !selectedPosition.department_id) {
        throw new Error("No department position assigned to your account");
      }

      const { data: requisition, error: requisitionError } = await supabase.rpc(
        "create_requisition",
        {
          title: "New Bulk Requisition",
          description: `Bulk requisition with ${items.length} item(s) submitted from the PWA`,
          branch_id: selectedPosition.branch_id,
          department_id: selectedPosition.department_id,
          currency: isUSD ? "USD" : "NGN",
        }
      );

      if (requisitionError) throw requisitionError;

      const requisition_id = requisition[0].id;

      const { error: itemsError } = await supabase.rpc("create_requisition_items", {
        requisition_id,
        items: items.map((item) => ({
          item_name: item.name,
          quantity: item.quantity,
          unit_price: item.unitPrice,
          notes: item.technicalDetails ?? item.description ?? null,
        })),
      });

      if (itemsError) throw itemsError;

      setStep("success");
    } catch (err) {
      console.error("Failed to submit requisition:", err);
      setError(
        err instanceof Error && err.message
          ? err.message
          : "Something went wrong submitting the requisition. Please try again."
      );
    } finally {
      setSubmitting(false);
    }
  };

  if (step === "success") {
    return (
      <div className="flex flex-col min-h-screen">
        <TopAppBar title="Submitted" onBack={onClose} />
        <main className="flex-1 mt-16 px-4 py-10 flex flex-col items-center text-center">
          <div className="w-16 h-16 rounded-full bg-secondary-container flex items-center justify-center mb-4">
            <Icon name="check_circle" className="text-on-secondary-container text-3xl" filled />
          </div>
          <h2 className="text-lg font-bold text-on-surface mb-2">Requisition Submitted</h2>
          <p className="text-sm text-on-surface-variant mb-8">
            Your bulk requisition has been sent to the approval workflow.
          </p>
          <button
            onClick={onClose}
            className="w-full py-3 bg-primary text-on-primary font-semibold rounded-lg"
          >
            Back to Dashboard
          </button>
        </main>
      </div>
    );
  }

  return (
    <div className="flex flex-col min-h-screen">
      <TopAppBar
        title={step === "items" ? "New Requisition" : "Preview & Submit"}
        onBack={step === "preview" ? () => setStep("items") : onClose}
      />
      <main className="flex-1 mt-16 mb-6 px-4 py-6 overflow-y-auto">
        <div className="mb-6">
          <div className="flex justify-between items-end mb-2">
            <span className="text-xs font-semibold text-primary uppercase tracking-wider">
              Step {step === "items" ? "1" : "2"} of 2
            </span>
            <span className="text-xs text-on-surface-variant italic">
              {step === "items" ? "Itemized Costs" : "Review & Submit"}
            </span>
          </div>
          <div className="w-full bg-surface-container-high h-1.5 rounded-full overflow-hidden">
            <div
              className="bg-primary h-full transition-all"
              style={{ width: step === "items" ? "50%" : "100%" }}
            />
          </div>
        </div>

        {step === "items" && (
          <>
            <div className="mb-4">
              <label
                htmlFor="department"
                className="block text-xs font-semibold text-on-surface-variant mb-1 uppercase tracking-wider"
              >
                Submitting for
              </label>
              {deptPositions.length > 1 ? (
                <select
                  id="department"
                  value={selectedPosition?.position_id ?? ""}
                  onChange={(e) => setSelectedPositionId(e.target.value)}
                  className="w-full px-4 py-3 rounded-xl bg-surface-container-low border border-outline-variant text-on-surface focus:outline-none focus:ring-2 focus:ring-primary"
                >
                  {deptPositions.map((p) => (
                    <option key={p.position_id} value={p.position_id}>
                      {p.department_name} · {p.branch_name}
                    </option>
                  ))}
                </select>
              ) : (
                <p className="text-sm font-semibold text-on-surface px-1 py-2">
                  {selectedPosition
                    ? `${selectedPosition.department_name} · ${selectedPosition.branch_name}`
                    : "No department assigned to your account"}
                </p>
              )}
            </div>

            <div className="flex items-center justify-between mb-4">
              <h2 className="text-sm font-semibold text-on-surface-variant uppercase">
                Itemized Cost Breakdown
              </h2>
              <button
                onClick={() => setIsUSD((prev) => !prev)}
                className="flex items-center gap-1 px-3 py-1 rounded-full bg-surface-container-high text-xs font-semibold text-on-surface-variant"
              >
                <Icon name="currency_exchange" className="text-[16px]" />
                {isUSD ? "USD ($)" : "NGN (₦)"}
              </button>
            </div>

            {items.length === 0 && (
              <p className="text-sm text-on-surface-variant mb-4">
                No items added yet. Tap &quot;Add Item&quot; below to get started.
              </p>
            )}

            {items.map((item) => (
              <ItemCard key={item.id} item={item} currency={currency} onRemove={handleRemoveItem} />
            ))}

            <button
              onClick={() => setShowAddItem(true)}
              className="w-full flex items-center justify-center gap-2 py-4 border-2 border-dashed border-outline-variant rounded-xl text-primary font-semibold hover:bg-surface-container-low transition-colors active:scale-95"
            >
              <Icon name="add_circle" />
              Add Item
            </button>

            <div className="bg-primary-container p-6 rounded-xl mt-8 mb-4 flex flex-col items-center justify-center text-on-primary-container shadow-sm border border-primary">
              <span className="text-xs opacity-80 uppercase tracking-widest mb-1">
                Estimated Requisition Total
              </span>
              <span className="text-2xl font-extrabold">
                {currency}&nbsp;{total.toLocaleString()}
              </span>
            </div>

            {overBudget && (
              <div className="flex items-start gap-2 p-4 bg-error-container text-on-error-container rounded-lg mb-4 text-sm">
                <Icon name="warning" className="text-[18px] mt-0.5" />
                <span>
                  This total exceeds your department&apos;s available budget of ₦
                  {DEPARTMENT_BUDGET_LIMIT_NGN.toLocaleString()} for this budget year.
                </span>
              </div>
            )}

            <button
              onClick={() => setStep("preview")}
              disabled={items.length === 0 || overBudget}
              className="w-full bg-primary text-on-primary py-4 rounded-lg font-semibold shadow-sm hover:opacity-95 transition-all active:scale-95 disabled:opacity-40"
            >
              Preview Requisition
            </button>
          </>
        )}

        {step === "preview" && (
          <>
            {error && (
              <div className="flex items-start gap-2 p-4 bg-error-container text-on-error-container rounded-lg mb-4 text-sm">
                <Icon name="error" className="text-[18px] mt-0.5" />
                <span>{error}</span>
              </div>
            )}
            <SubmissionPreview
              items={items}
              currency={currency}
              total={total}
              submitting={submitting}
              onConfirm={handleConfirmSubmit}
              onBack={() => setStep("items")}
            />
          </>
        )}
      </main>

      {showAddItem && (
        <ItemFormSheet onAdd={handleAddItem} onClose={() => setShowAddItem(false)} />
      )}
    </div>
  );
}
