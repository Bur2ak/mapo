import { Hono } from "hono";
import menu from "./routes/menu";
import orders from "./routes/orders";

const app = new Hono();

app.route("/api/menu", menu);
app.route("/api/orders", orders);
app.get("/api/health", (c) => c.text("ok"));

export default app;
