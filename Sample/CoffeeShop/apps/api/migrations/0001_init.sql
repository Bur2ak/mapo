CREATE TABLE drinks (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  price_cents INTEGER NOT NULL,
  hot INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE orders (
  id TEXT PRIMARY KEY,
  status TEXT NOT NULL DEFAULT 'placed',
  total_cents INTEGER NOT NULL,
  created_at INTEGER NOT NULL
);

CREATE TABLE order_items (
  order_id TEXT NOT NULL REFERENCES orders(id),
  drink_id TEXT NOT NULL REFERENCES drinks(id),
  quantity INTEGER NOT NULL
);
