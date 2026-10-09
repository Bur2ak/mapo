import { useEffect, useState } from "react";
import { FlatList } from "react-native";
import type { Drink, OrderItem } from "../../../../packages/shared/types";
import { DrinkCard } from "../../components/DrinkCard";
import { fetchMenu, placeOrder } from "../../lib/api";

export default function MenuScreen() {
  const [drinks, setDrinks] = useState<Drink[]>([]);
  const [cart, setCart] = useState<OrderItem[]>([]);

  useEffect(() => {
    fetchMenu().then(setDrinks);
  }, []);

  const add = (d: Drink) => setCart((c) => [...c, { drinkId: d.id, quantity: 1 }]);
  const checkout = () => placeOrder(cart, "guest");

  return <FlatList data={drinks} renderItem={({ item }) => <DrinkCard drink={item} onAdd={add} />} />;
}
