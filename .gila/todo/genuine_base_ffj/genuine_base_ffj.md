---
title: Arena in PNG parser is probablamatic if there are reallocations
status: todo
priority: medium
priority_value: 50
owner: adiraj
created: 2025-12-18T05:21:40Z
---

Currently in the PNG parser we have 3 buffers that we use while parsing the image.

1. The `raw_data` buffer is used to store the raw data from the PNG IDAT chunks.
2. The `uncompressed_data` buffer is used to store the uncompressed data from the Zlib chunks.
3. The `filter_buffer` buffer is used to store the filtered data from the scanlines.

Currently I expect an stdx.Arena to be passed to the parser for these buffers but I need to ensure
that the arena has enough memory and is there any way i can ensure no reallocations are done on the
arena? And if reallocations are needed what do we do?


