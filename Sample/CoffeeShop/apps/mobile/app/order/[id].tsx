import { useEffect, useState } from "react";
import { Text } from "react-native";
import type { Order } from "../../../../packages/shared/types";
import { formatPrice } from "../../components/DrinkCard";
import { fetchOrder } from "../../lib/api";

export default function OrderScreen({ id }: { id: string }) {
  const [order, setOrder] = useState<Order | null>(null);

  useEffect(() => {
    const timer = setInterval(() => fetchOrder(id).then(setOrder), 3000);
    return () => clearInterval(timer);
  }, [id]);

  if (!order) return <Text>Loading…</Text>;
  return <Text>{order.status} · {formatPrice(order.totalCents)}</Text>;
}
