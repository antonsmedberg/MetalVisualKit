# Media

`loader-simulator.png` is the verified iOS 26.5 simulator frame used in the root
README. It demonstrates the particle renderer only and is not evidence of LiDAR
hardware behaviour.

Future device recordings belong here:

| File | Content | Target |
|---|---|---|
| `particle-loader.gif` | One full sweep 0 → 100% ending in the completion release, with a drag across the particles mid-sweep so the repulsion is visible | ~4 s, < 5 MB |
| `point-cloud.gif` | Slow pan across a desk or room corner, depth slider adjusted once so the colour-map range shifts | ~5 s, < 5 MB |

Record from the example app on device, then:

```
make gif IN=loader.mov OUT=Media/particle-loader.gif
make gif IN=cloud.mov  OUT=Media/point-cloud.gif
```

The recipe targets 15 fps at 600 px wide, which keeps both files well under
GitHub's comfortable rendering size.

If no LiDAR device is available, record the demo cloud instead and say so in the
README caption. An honest caption costs nothing; a misleading one is the kind of
thing a reviewer notices.
