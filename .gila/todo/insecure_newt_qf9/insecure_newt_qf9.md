---
title: Move PNG decoder from zfracture to stdx
status: todo
priority: high
priority_value: 50
owner: adiraj
created: 2025-12-15T09:05:06Z
---

Links:
https://github.com/aditya-rajagopal/zfracture/blob/6a4825fbb616e92cf45afeae82e34c554036eecf/src/core/image/png.zig

zfracture has been rewritten and the png decoder has been deleted from it. Need to move the png decoder to stdx, clean it up and 
make the api better.
