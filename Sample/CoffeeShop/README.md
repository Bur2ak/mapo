# Coffee Shop (Mapo sample)

A tiny full-stack app to explore in Mapo: an Expo-style mobile app calls a
Hono API on Cloudflare Workers, which reads and writes a D1 (SQLite) database.

Try in Mapo:
- Click `fetchMenu` in `apps/mobile/lib/api.ts` → its arrow goes to `GET /api/menu`.
- Click the `orders` table → see every endpoint that reads or writes it.
- Select `OrderScreen`, then **Find path…** to `order_items`.
