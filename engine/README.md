# drift-engine

Out-of-process torrent engine for Drift (Stage B). C++17 + libtorrent 2.1.2,
ARM64-only, talks versioned JSON-lines over a Unix domain socket. See
`docs-internal/EMBEDDED-ENGINE.md` (§4–§6) for the architecture and protocol.

## Build (one command)

```sh
./build.sh
```

Prerequisites on macOS 26 (arm64):

- Xcode Command Line Tools / full Xcode
- CMake ≥ 3.20 (`brew install cmake`)
- Boost ≥ 1.70 with Boost.JSON (`brew install boost`)
- OpenSSL 3 (`brew install openssl@3`)

The build is static (`BUILD_SHARED_LIBS=OFF`); no runtime Homebrew dependency
is linked into the shipped binary beyond macOS system libraries.

## Layout

```
src/                 engine sources (E1+)
third_party/libtorrent/  pinned submodule, tag v2.1.2
licenses/            attribution shipped with the DMG
check-upstreams.sh   compare pinned libtorrent with upstream latest
```

## License hygiene

BSD-3 only. libtorrent (BSD-3), Boost (BSL-1.0) and OpenSSL (Apache-2.0)
attribution lives in `licenses/`. qBittorrent (GPL-2.0+) and the GPL
`search-plugins` `.py` files are never copied into this directory or the app
bundle.
