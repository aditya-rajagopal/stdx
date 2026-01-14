---
title: Update png parser to parse IDAT chunks streaming
status: todo
priority_value: 50
priority: medium
owner: aditya
created: 2026-01-12T22:13:50Z
tags: 
- png
---

Change the parsing of the idat chunks to be a reader. Rather than reading the entire png file into memory we can 
only read the data we need. So we can chain read -> deflate -> filter and fill a pixel buffer as we go.

Look at `std.compress.Decompress` for a good example of how to do this. Decide if this is usable or to keep my own
implementation.
