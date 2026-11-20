# Brand icons

ZhenTo brand artwork and the pre-generated icons installed into the ISO.

## Layout

- `sources/` — original artwork vendored from [zitzhen/zhenTo-icon](https://github.com/zitzhen/zhenTo-icon):
  - `zhento-short.png` (`zhento短图标.png`, 548×545 RGBA) — short circular logo
  - `zhento-full.png` (`zhento_透明.png`, 1774×887 RGBA) — full banner with wordmark and transparent background
- `files/pixmaps/` — pre-generated brand icons, committed to git. Filenames match the target names in `/usr/share/pixmaps/`:
  - `ubuntu-logo.svg`, `ubuntu-logo-text.svg/.png`, `ubuntu-logo-text-dark.svg/.png`, `debian-logo.png/.bmp`
- `generate-icons.sh` — maintenance tool that regenerates `files/pixmaps/` from `sources/` (requires ImageMagick `convert` and `base64`).
- `edit-icon.sh` — build-time installer: copies the generated icons into `/usr/share/pixmaps/` and the full banner to `/usr/share/backgrounds/zhento.png` of an unpacked ISO root. Called by `build.sh`; never runs inside the chroot.

## Source checksums

| File | SHA256 |
|---|---|
| `zhento-short.png` | `e6d3cbedf49f04319c0a5709d3469411d8a1357bb18f971e93d4bc9faa64513e` |
| `zhento-full.png` | `34ec0ade67f0956240b0b248797dba73ef91bca35d0b92bf26279234390f19db` |

## Regenerating

```bash
./generate-icons.sh
file files/pixmaps/*
git add files/pixmaps
```

The build never regenerates icons: conversion needs ImageMagick, which the CI image does not install. Generated files are committed so builds stay offline and reproducible. Only the seven brand slots are replaced; all other icons in the base image are preserved.

Notes:

- SVG slots are valid SVG files embedding a small PNG via a base64 data URI (not raw PNG bytes with an `.svg` extension).
- The `-text-dark` variants reuse the full banner because no separate dark artwork exists.
- The full banner must keep its alpha channel: the logo is drawn on GDM3 and GNOME Settings against varying backgrounds, so a white background would appear as a jarring white box (issue #53). The transparent source is upstream `zhento_透明.png`.
- `tmp/hicolor&pixmaps.tar.gz` at the repository root is a reference copy of upstream Ubuntu icons; it is ignored by git and not part of the build.
