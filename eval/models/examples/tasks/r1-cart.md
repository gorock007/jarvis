kind: review
title: shopping cart with two planted bugs
context: files/cart.py
# Adding a SKU twice replaces its quantity instead of adding to it.
bug: B1 files/cart.py:13-14
# The discount is a fraction but is subtracted as an amount, after tax.
bug: B2 files/cart.py:24-25
tolerance: 1
---
Review this Python module for bugs: code that does not do what its names,
docstrings or callers would expect. Ignore style.
