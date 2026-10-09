import { Hono } from "hono";
import { listDrinks } from "../lib/db";

type Env = { Bindings: { DB: D1Database } };
const menu = new Hono<Env>();

menu.get("/", async (c) => c.json(await listDrinks(c.env.DB)));

menu.get("/:id", async (c) => {
  const drink = await c.env.DB.prepare("SELECT * FROM drinks WHERE id = ?").bind(c.req.param("id")).first();
  return drink ? c.json(drink) : c.notFound();
});

export default menu;
