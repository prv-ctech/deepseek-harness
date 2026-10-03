# Plus codec redistribution review — evidence pack

Evidence for the operator decision behind `SELKIES_REDISTRIBUTION_REVIEWED`
(see [selkies.md](selkies.md)). It records what the pinned artifact actually
contains, which obligations are met and which are not. **It is not a legal
clearance and it does not set the variable**: that stays an operator act.

## Pin under review

| Item | Value | How checked |
| --- | --- | --- |
| Selkies native package | `selkies-2.0.0-bookworm-amd64.deb`, 64,634,714 bytes | downloaded; `sha256sum` = `fd02cbc08b94eb65f5e834c11849084eec605564d5964f2500dc1209425dc620`, equal to `SELKIES_SHA256` in `Dockerfile` |
| Control | `Package: selkies`, `Version: 2.0.0-1~bookworm`, `License: MPL-2.0` | `dpkg-deb -e` on that download |
| Source commit | `3ec56fb1538cf077c27156f5ab75b6595a83c461` (release 2.0.0, published 2026-09-23) | release metadata for tag `2.0.0` |
| Payload | 5,244 files, all inside `/opt/selkies` and `/usr/lib/*/selkies_*_interposer.so` | `dpkg-deb -x` |
| Vendored wheels | `pixelflux` 2.1.0, `pcmflux` 2.1.0 | `*.dist-info` in the payload |

`Depends` of the deb: `python3 libpulse0 libxcb1 libxkbcommon0 libx11-xcb1
libva2 libva-drm2 libva-x11-2 libdrm2 libgbm1 libegl1 libwayland-server0
libglib2.0-0 libpixman-1-0 libxcb-render0 libxcb-shm0 libxcb-dri3-0
libxfixes3 libxext6 libice6 libsm6` — **no distro `ffmpeg` or `x264`**, and the
`Dockerfile` installs neither, so unlike Selkies' own container images the GPL
codecs reach this image only through the pixelflux wheel. Confirm in the built
image with `dpkg -l | grep -E 'x264|ffmpeg'` (expected: empty).

## GPL components actually shipped

All three are in `/opt/selkies/lib/python3.11/site-packages/pixelflux.libs/`
(exactly 12 files, the 12 shared objects below; **no notice file of any kind**
ships beside them).

| Component | Image file | License | Corresponding source |
| --- | --- | --- | --- |
| libx264 | `libx264-03b89520.so.165` | GPL-2.0-or-later | x264 `stable` = `b35605ace3ddf7c1a5d67a2eb553f034aef41d55` (2025-06-08), whose `x264.h` has `X264_BUILD 165`, matching the SONAME |
| libx265 | `libx265-01f14378.so.216` | GPL-2.0-or-later | tag `4.2` = `e444744c0397`, whose `source/CMakeLists.txt` sets `X265_BUILD 216`, matching the SONAME |
| FFmpeg (avcodec, avfilter, avformat, avutil, swresample, swscale) | `libavcodec-b9a9f86d.so.62.28.100`, `libavfilter-cdec111f.so.11.14.100`, `libavformat-13c66e9d.so.62.12.100`, `libavutil-3ace01cb.so.60.26.100`, `libswresample-c2e2aa1c.so.6.3.100`, `libswscale-c3beef9f.so.9.5.100` | GPL-2.0-or-later (as built) | release tarball `ffmpeg-8.1.tar.xz`; `n8.1` `libavcodec/version.h` is `62.28.100` |

Evidence read out of the binaries themselves:

```
libavcodec: --prefix=/usr/local --enable-shared --disable-static --disable-programs
            --disable-doc --enable-libkvazaar --enable-libvpx --enable-libsvtav1
            --enable-libdav1d --enable-gpl --enable-libx265
libavcodec license: GPL version 2 or later
FFmpeg version n8.1
```

No `--enable-version3`, so these GPL parts are **GPL-2.0-or-later**, not GPLv3.
The surrounding permissive library versions match the pixelflux recipe exactly:
libvpx 1.15.2 (`v1.15.2`), dav1d `1.5.1-0-g42b2b24`, kvazaar v2.3.2, SVT-AV1
v4.2.0.

Every source ref above comes from pixelflux's own wheel recipe
(`pyproject.toml`, tag 2.1.0, `[tool.cibuildwheel.linux] before-all`:
`clone_source stable x264`, `clone_source 4.2 x265`,
`clone_source v1.15.2 libvpx`, `clone_source v4.2.0 svtav1`,
`clone_source 1.5.1 dav1d`, `clone_source v2.3.2 kvazaar`,
`clone_source n8.1 ffmpeg`), i.e. the script that controls compilation and
linking is public at that tag.

The GPL parts combine with MPL-2.0 Selkies/pixelflux/pcmflux and permissive code
into the extension binaries, so the distributed combination is under
GPL-2.0-or-later terms for those parts; MPL-2.0 is GPL-compatible through its
secondary-license clause. Codec **patent** licensing (H.264/H.265 pools) is
separate from copyright compliance and is not addressed by any of this.

## Non-GPL obligations

| Class | What ships | Status |
| --- | --- | --- |
| MPL-2.0 (Selkies, pixelflux, pcmflux, bundled web client) | deb carries the Selkies Python sources and the built `selkies_web` client; both wheels ship `dist-info/licenses/LICENSE` **and** `LICENSES.md` | Met: the MPL files travel in their preferred form; the shipped `LICENSES.md` files are byte-identical to the pinned pixelflux 2.1.0 (`a5c112d9…`) and pcmflux 2.1.0 (`ddf1bb07…`) tags |
| LGPL-2.1-or-later (`glibc`, `libpulse` and the tree bundled in `pcmflux.libs/`: libpulsecommon, libasyncns, libsndfile, libsystemd, libgcrypt, libgpg-error, libmount, libblkid; Debian `pulseaudio`; `selkies/Xlib` fork) | separate shared objects on the loader path; `selkies/Xlib/LICENSE` (LGPL-3.0 text) is shipped | Replaceability holds for the `.so` files (dynamic linking, no static relink); note the image runs read-only root, so "replace the library" means a rebuilt image or a mounted overlay, not a runtime swap |
| Debian-packaged GPL programs installed by our `Dockerfile` (`openbox`, `iproute2`) | unmodified Debian binaries + Debian's `/usr/share/doc/<pkg>/copyright` | Customary route only: Debian provides the source, we ship no offer. Verify the copyright files survive the build (`ls /usr/share/doc/openbox/copyright`) |
| Permissive attributions (libvpx, dav1d, SVT-AV1, kvazaar, Pillow's libjpeg-turbo/libpng/…, the Python dependencies, Rust crates) | inventories exist upstream; wheel `LICENSES.md` names each component | **License texts are not shipped**; attribution relies on links to upstream inventories |
| Google Chrome (`-plus` only) | pre-existing image posture | Out of scope here; Chrome's own redistribution terms are a separate question from the codec notices |

## Gaps that block a cleared redistribution

1. **No GPL-2.0 text in the image.** `pixelflux.libs/` has 12 `.so` files and no
   license or notice file. The Python dependencies do ship their own licenses
   (`*.dist-info/licenses/`), but nothing carries the text for the GPL parts
   bundled beside them.
2. **No notice or attribution file is added by this repository** — not to the
   image, not to the published tag, so a recipient of
   `ghcr.io/prv-ctech/deepseek-harness-plus` gets no statement of the GPL parts.
3. **No corresponding-source availability statement.** GPLv2 §3 wants the
   complete corresponding source (or a written offer) to accompany the
   distributed image. The exact sources are now pinned above, but nothing the
   recipient receives says where to get them.
4. **The build/link script is not shipped**, only public at the pinned tag.
5. Text for the native libraries bundled inside the wheels (libvpx, dav1d,
   SVT-AV1, kvazaar, and Pillow's bundled libraries) is absent; only the
   inventory that names them ships.

## Minimal actions that would close it

- Ship a `THIRD-PARTY-NOTICES` file in the `-plus` image (e.g.
  `/usr/share/doc/dsh-plus/`) containing GPL-2.0 text, the component/source
  table above and the attribution list — or, instead of shipping the sources,
  a written offer naming the URLs.
- Decide which form of source compliance the project gives recipients (ship
  source in-image, or a durable written offer), and state it in the README and
  in this document.
- Only then set repository variable `SELKIES_REDISTRIBUTION_REVIEWED=true`; reset
  it whenever this pin or the wheel recipe changes.

## Review record

Reviewed 2026-10-03 against the artifacts above by inspecting the pinned deb,
the embedded codec metadata and the upstream inventories at their pinned tags.
**Not done here:** no Docker build or run, no image-level inspection of the
final `-plus` layer, no legal opinion, no patent analysis. Live media acceptance
and the Unraid deployment are untouched by this review.

```sh
# On a Docker host, against the built test image (read-only checks):
docker run --rm --entrypoint sh dsh-plus-selkies:test -c '
  find /opt/selkies -name "LICENSE*" -o -name "*NOTICE*" | head
  ls /opt/selkies/lib/python3.11/site-packages/pixelflux.libs/
  dpkg -l | grep -E "x264|ffmpeg" || echo "no distro codec packages"
  ls /usr/share/doc/openbox/copyright'
```
