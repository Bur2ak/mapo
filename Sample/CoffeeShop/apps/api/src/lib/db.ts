import type { Drink, Order, OrderItem } from "../../../../packages/shared/types";

export async function listDrinks(db: D1Database): Promise<Drink[]> {
  const { results } = await db.prepare("SELECT id, name, price_cents, hot FROM drinks ORDER BY name").all();
  return results.map(toDrink);
}

export async function priceOf(db: D1Database, items: OrderItem[]): Promise<number> {
  let total = 0;
  for (const item of items) {
    const row = await db.prepare("SELECT price_cents FROM drinks WHERE id = ?").bind(item.drinkId).first<{ price_cents: number }>();
    total += (row?.price_cents ?? 0) * item.quantity;
  }
  return total;
}

export async function saveOrder(db: D1Database, order: Order): Promise<void> {
  await db.prepare("INSERT INTO orders (id, status, total_cents, created_at) VALUES (?, ?, ?, ?)")
    .bind(order.id, order.status, order.totalCents, Date.now()).run();
  for (const item of order.items) {
    await db.prepare("INSERT INTO order_items (order_id, drink_id, quantity) VALUES (?, ?, ?)")
      .bind(order.id, item.drinkId, item.quantity).run();
  }
}

function toDrink(r: Record<string, unknown>): Drink {
  return { id: String(r.id), name: String(r.name), priceCents: Number(r.price_cents), hot: r.hot === 1 };
}
