"use client";

import { useState } from "react";
import Icon from "@/components/ui/Icon";
import { CATEGORIES, RequisitionItem } from "./types";

interface ItemFormSheetProps {
  onAdd: (item: RequisitionItem) => void;
  onClose: () => void;
}

export default function ItemFormSheet({ onAdd, onClose }: ItemFormSheetProps) {
  const [name, setName] = useState("");
  const [description, setDescription] = useState("");
  const [category, setCategory] = useState("office-supplies");
  const [quantity, setQuantity] = useState("1");
  const [unitPrice, setUnitPrice] = useState("");
  const [mileage, setMileage] = useState("");
  const [technicalDetails, setTechnicalDetails] = useState("");

  const canSubmit = name.trim() !== "" && Number(unitPrice) > 0 && Number(quantity) > 0;

  const handleAdd = () => {
    if (!canSubmit) return;
    onAdd({
      id: crypto.randomUUID(),
      name,
      description,
      category,
      quantity: Number(quantity),
      unitPrice: Number(unitPrice),
      mileage: category === "vehicle" ? Number(mileage) || 0 : undefined,
      technicalDetails: category === "vehicle" ? technicalDetails : undefined,
    });
    onClose();
  };

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/40">
      <div className="bg-surface w-full max-w-lg rounded-t-2xl shadow-2xl max-h-[90vh] overflow-y-auto">
        <div className="flex items-center justify-between px-6 py-4 border-b border-outline-variant sticky top-0 bg-surface">
          <h3 className="text-lg font-bold text-on-surface">Add Item</h3>
          <button onClick={onClose} className="p-1 rounded-full hover:bg-surface-container-high">
            <Icon name="close" className="text-outline" />
          </button>
        </div>

        <div className="p-6 space-y-4">
          <div>
            <label className="block text-xs font-semibold text-on-surface-variant mb-1 uppercase">Item Name</label>
            <input
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="e.g. Camera"
              className="w-full px-3 py-2 border border-outline-variant rounded-lg text-sm focus:ring-2 focus:ring-primary focus:border-primary outline-none"
            />
          </div>

          <div>
            <label className="block text-xs font-semibold text-on-surface-variant mb-1 uppercase">Description</label>
            <input
              value={description}
              onChange={(e) => setDescription(e.target.value)}
              placeholder="e.g. Professional Video Equipment"
              className="w-full px-3 py-2 border border-outline-variant rounded-lg text-sm focus:ring-2 focus:ring-primary focus:border-primary outline-none"
            />
          </div>

          <div>
            <label className="block text-xs font-semibold text-on-surface-variant mb-1 uppercase">Category</label>
            <select
              value={category}
              onChange={(e) => setCategory(e.target.value)}
              className="w-full px-3 py-2 border border-outline-variant rounded-lg text-sm focus:ring-2 focus:ring-primary focus:border-primary outline-none bg-white"
            >
              {CATEGORIES.map((c) => (
                <option key={c.value} value={c.value}>
                  {c.label}
                </option>
              ))}
            </select>
          </div>

          <div className="grid grid-cols-2 gap-4">
            <div>
              <label className="block text-xs font-semibold text-on-surface-variant mb-1 uppercase">Quantity</label>
              <input
                type="number"
                min={1}
                value={quantity}
                onChange={(e) => setQuantity(e.target.value)}
                className="w-full px-3 py-2 border border-outline-variant rounded-lg text-sm focus:ring-2 focus:ring-primary focus:border-primary outline-none"
              />
            </div>
            <div>
              <label className="block text-xs font-semibold text-on-surface-variant mb-1 uppercase">Unit Price (₦)</label>
              <input
                type="number"
                min={0}
                value={unitPrice}
                onChange={(e) => setUnitPrice(e.target.value)}
                className="w-full px-3 py-2 border border-outline-variant rounded-lg text-sm focus:ring-2 focus:ring-primary focus:border-primary outline-none"
              />
            </div>
          </div>

          {category === "vehicle" && (
            <div className="space-y-4 p-4 bg-surface-container-low rounded-lg border border-outline-variant">
              <p className="text-xs font-semibold text-on-surface-variant uppercase">Vehicle Details</p>
              <div>
                <label className="block text-xs text-on-surface-variant mb-1">Mileage (km)</label>
                <input
                  type="number"
                  value={mileage}
                  onChange={(e) => setMileage(e.target.value)}
                  className="w-full px-3 py-2 border border-outline-variant rounded-lg text-sm focus:ring-2 focus:ring-primary focus:border-primary outline-none"
                />
              </div>
              <div>
                <label className="block text-xs text-on-surface-variant mb-1">Technical Details</label>
                <input
                  value={technicalDetails}
                  onChange={(e) => setTechnicalDetails(e.target.value)}
                  className="w-full px-3 py-2 border border-outline-variant rounded-lg text-sm focus:ring-2 focus:ring-primary focus:border-primary outline-none"
                />
              </div>
            </div>
          )}
        </div>

        <div className="p-6 pt-0">
          <button
            onClick={handleAdd}
            disabled={!canSubmit}
            className="w-full py-3 bg-primary text-on-primary font-semibold rounded-lg disabled:opacity-40 active:scale-95 transition-transform"
          >
            Add Item
          </button>
        </div>
      </div>
    </div>
  );
}
