import unittest

from cart import Cart


class CartTest(unittest.TestCase):
    def setUp(self):
        self.cart = Cart()
        self.cart.add("keyboard", 80)
        self.cart.add("cable", 10, qty=2)

    def test_subtotal(self):
        self.assertEqual(self.cart.subtotal(), 100)

    def test_discount(self):
        self.assertEqual(self.cart.apply_discount(25), 75)

    def test_total(self):
        self.assertEqual(self.cart.total(percent=10), 108.0)


if __name__ == "__main__":
    unittest.main()
