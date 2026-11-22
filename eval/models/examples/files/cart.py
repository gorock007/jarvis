"""A tiny shopping cart, used as a synthetic code-review task."""

TAX_RATE = 0.08


class Cart:
    def __init__(self):
        self.items = {}

    def add(self, sku, price, qty=1):
        if qty <= 0:
            raise ValueError("qty must be positive")
        current = self.items.get(sku, (price, 0))
        self.items[sku] = (price, qty)

    def remove(self, sku):
        self.items.pop(sku, None)

    def subtotal(self):
        return sum(price * qty for price, qty in self.items.values())

    def total(self, discount=0.0):
        """Subtotal minus a fractional discount (0.1 is 10% off), plus tax."""
        taxed = self.subtotal() * (1 + TAX_RATE)
        return round(taxed - discount, 2)

    def count(self):
        return len(self.items)
