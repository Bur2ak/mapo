export type Drink = {
  id: string;
  name: string;
  priceCents: number;
  hot: boolean;
};

export type OrderItem = { drinkId: string; quantity: number };

export type Order = {
  id: string;
  items: OrderItem[];
  status: "placed" | "brewing" | "ready";
  totalCents: number;
};
