import { Pressable, Text } from "react-native";
import type { Drink } from "../../../packages/shared/types";

export function DrinkCard({ drink, onAdd }: { drink: Drink; onAdd: (d: Drink) => void }) {
  return (
    <Pressable onPress={() => onAdd(drink)}>
      <Text>{drink.hot ? "☕" : "🧊"} {drink.name}</Text>
      <Text>{formatPrice(drink.priceCents)}</Text>
    </Pressable>
  );
}

export function formatPrice(cents: number): string {
  return `€${(cents / 100).toFixed(2)}`;
}
