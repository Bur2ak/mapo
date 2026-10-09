import { Hono } from "hono";
import type { Order, OrderItem } from "../../../../packages/shared/types";
import { priceOf, saveOrder } from "../lib/db";
import { addPoints } from "../lib/loyalty";

type Env = { Bindings: { DB: D1Database } };
const orders = new Hono<Env>();

orders.post("/", async (c) => {
  const { items, customerId } = await c.req.json<{ items: OrderItem[]; customerId: string }>();
  const order: Order = { id: crypto.randomUUID(), items, status: "placed", totalCents: await priceOf(c.env.DB, items) };
  await saveOrder(c.env.DB, order);
  await addPoints(c.env.DB, customerId, order.totalCents);
  return c.json(order, 201);
});

orders.get("/:id", async (c) => {
  const order = await c.env.DB.prepare("SELECT * FROM orders WHERE id = ?").bind(c.req.param("id")).first();
  return order ? c.json(order) : c.notFound();
});

orders.patch("/:id/status", async (c) => {
  const { status } = await c.req.json<{ status: Order["status"] }>();
  await c.env.DB.prepare("UPDATE orders SET status = ? WHERE id = ?").bind(status, c.req.param("id")).run();
  return c.body(null, 204);
});

export default orders;
