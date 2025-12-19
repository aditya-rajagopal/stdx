---
title: Arena in PNG parser is probablamatic if there are reallocations
status: done
priority: medium
priority_value: 50
owner: adiraj
created: 2025-12-18T05:21:40Z
completed: 2025-12-19T03:00:37Z
---

Currently in the PNG parser we have 3 buffers that we use while parsing the image.

1. The `raw_data` buffer is used to store the raw data from the PNG IDAT chunks.
2. The `uncompressed_data` buffer is used to store the uncompressed data from the Zlib chunks.
3. The `filter_buffer` buffer is used to store the filtered data from the scanlines.

Currently I expect an stdx.Arena to be passed to the parser for these buffers but I need to ensure
that the arena has enough memory and is there any way i can ensure no reallocations are done on the
arena? And if reallocations are needed what do we do?

Update: 

I added the ability to resize in the arena if it is the last allocation. This should help raw_data expand as necessary.
As it is the only allocation on the arena till the deflate_step.

Currently uncompressed_data is assumed to not be resizable as the output should be a fixed size determined by 
the width, height, bit_depth and channels. [[medium_fang_560]] Tracks this.

Now the only failure condition for the PNG parser wrt to memroy is the arena being too small.

