---
title: Should deflated_data in the PNG parser allow resize?
status: todo
priority: medium
priority_value: 50
owner: adiraj
created: 2025-12-19T02:30:24Z
---

Currently the deflated_data is allocated with a fixed size and assumed to always deflate to exactly that size.

Test this assumption.
