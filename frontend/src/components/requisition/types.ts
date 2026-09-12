export interface RequisitionItem {
  id: string;
  name: string;
  description?: string;
  category: string;
  quantity: number;
  unitPrice: number;
  mileage?: number;
  technicalDetails?: string;
}

export const CATEGORIES = [
  { value: "vehicle", label: "Vehicle" },
  { value: "office-supplies", label: "Office Supplies" },
  { value: "equipment", label: "Equipment" },
  { value: "other", label: "Other" },
];
