"use client";

import Icon from "@/components/ui/Icon";
import { RequisitionItem } from "./types";

interface ItemCardProps {
  item: RequisitionItem;
  currency: string;
  onRemove: (id: string) => void;
}

export default function ItemCard({ item, currency, onRemove }: ItemCardProps) {
  const subtotal = item.quantity * item.unitPrice;

  return (
    <div className="bg-white rounded-lg shadow-sm border-t-4 border-primary p-4 mb-4">
      <div className="flex justify-between items-start mb-3">
        <div>
          <h3 className="text-sm font-semibold text-on-surface">{item.name}</h3>
          {item.description && (
            <p className="text-xs text-on-surface-variant">{item.description}</p>
          )}
        </div>
        <button onClick={() => onRemove(item.id)} className="text-error p-1">
          <Icon name="delete" />
        </button>
      </div>
      <div className="grid grid-cols-2 gap-4 pt-3 border-t border-surface-container">
        <div>
          <p className="text-[11px] text-outline uppercase">Quantity</p>
          <p className="text-sm font-bold">{item.quantity}</p>
        </div>
        <div className="text-right">
          <p className="text-[11px] text-outline uppercase">Unit Price</p>
          <p className="text-sm">
            {currency}&nbsp;{item.unitPrice.toLocaleString()}
          </p>
        </div>
      </div>
      {item.category === "vehicle" && (item.mileage || item.technicalDetails) && (
        <div className="mt-3 pt-3 border-t border-dashed border-outline-variant text-xs text-on-surface-variant space-y-1">
          {item.mileage ? <p>Mileage: {item.mileage} km</p> : null}
          {item.technicalDetails ? <p>Details: {item.technicalDetails}</p> : null}
        </div>
      )}
      <div className="mt-4 pt-3 border-t border-dashed border-outline-variant flex justify-between items-center">
        <span className="text-xs font-semibold text-on-surface-variant">SUBTOTAL</span>
        <span className="text-sm font-bold text-primary">
          {currency}&nbsp;{subtotal.toLocaleString()}
        </span>
      </div>
    </div>
  );
}
