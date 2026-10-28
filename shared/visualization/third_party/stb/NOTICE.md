# stb_image

Unmodified `stb_image.h` and `LICENSE` from
https://github.com/nothings/stb/tree/003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5.
This integration uses the MIT option in the dual MIT/public-domain license.

- `stb_image.h` SHA-256: `594c2fe35d49488b4382dbfaec8f98366defca819d916ac95becf3e75f4200b3`
- `LICENSE` SHA-256: `bebfe904b14301657e4e5d655c811d51fd31b97c455b9cc2d8600d6bac6cff63`

The wrapper enables PNG/JPEG/BMP/TGA, disables stdio, bounds input to 16 MiB,
dimensions to 4096 per side and 8 MiPixels, and caps decoder allocations at
96 MiB per worker. DDS and other image formats are explicit unsupported cases.
Source inclusion is not evidence of fuzzing, security audit or TV qualification.
Keep these notices and the license in corresponding-source distributions.
