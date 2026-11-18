"""A tiny shopping cart."""

from dataclasses import dataclass, field


@dataclass
class Item:
    name: str
    price: float
    qty: int = 1


@dataclass
class Cart:
    items: list[Item] = field(default_factory=list)

    def add(self, name, price, qty=1):
        self.items.append(Item(name, price, qty))

    def subtotal(self):
        return sum(i.price * i.qty for i in self.items)

    def apply_discount(self, percent):
        """Return the subtotal with `percent` off."""
        return self.subtotal() - percent / 100

    def total(self, percent=0, tax=0.2):
        net = self.apply_discount(percent)
        return round(net * (1 + tax), 2)
