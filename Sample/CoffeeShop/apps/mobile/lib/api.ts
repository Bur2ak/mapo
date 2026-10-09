import type { Drink, Order, OrderItem } from "../../../packages/shared/types";

const API_URL = process.env.EXPO_PUBLIC_API_URL ?? "http://localhost:8787";

async function get<T>(path: string): Promise<T> {
  const res = await fetch(`${API_URL}${path}`);
  if (!res.ok) throw new Error(`GET ${path}: ${res.status}`);
  return res.json() as Promise<T>;
}

async function post<T>(path: string, body: unknown): Promise<T> {
  const res = await fetch(`${API_URL}${path}`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
  if (!res.ok) throw new Error(`POST ${path}: ${res.status}`);
  return res.json() as Promise<T>;
}

export const fetchMenu = () => get<Drink[]>("/api/menu");

export const fetchDrink = (id: string) => get<Drink>(`/api/menu/${id}`);

export const placeOrder = (items: OrderItem[], customerId: string) => post<Order>("/api/orders", { items, customerId });

export const fetchOrder = (id: string) => get<Order>(`/api/orders/${id}`);
