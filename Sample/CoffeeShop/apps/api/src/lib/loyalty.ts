/** One point per full euro spent. */
export async function addPoints(db: D1Database, customerId: string, totalCents: number): Promise<number> {
  const earned = Math.floor(totalCents / 100);
  await db.prepare("INSERT INTO loyalty_points (customer_id, points) VALUES (?, ?) ON CONFLICT(customer_id) DO UPDATE SET points = points + ?")
    .bind(customerId, earned, earned).run();
  return earned;
}
