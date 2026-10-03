# occt-build

Prebuilt [Open CASCADE Technology](https://dev.opencascade.org/) (OCCT) archives.

[`build.sh`](build.sh) builds one pinned OCCT with OCCT's own CMake, and GitHub Actions publishes the result for macOS arm64 and Linux x64 as release archives.

## What is built

- **OCCT 8.0.1**: tag `V8_0_1`, commit `b8f597c677811d1f9f4d8a97f5ae2825c0353a42`, fetched with git and checked against that commit.
- **The 16-toolkit modeling set**: the closure of `TKPrim`, `TKMesh`, `TKBO`, `TKBool`, `TKFillet`, `TKOffset` and `TKFeat`, which is `TKernel`, `TKMath`, `TKG2d`, `TKG3d`, `TKGeomBase`, `TKBRep`, `TKGeomAlgo`, `TKTopAlgo`, `TKShHealing`, `TKPrim`, `TKMesh`, `TKBO`, `TKBool`, `TKFillet`, `TKOffset` and `TKFeat`.
- **No third-party dependencies**: every `USE_*` option off, and no Draw. The libraries depend only on the system's C and C++ runtimes.
- **Shared libraries, Release**, with `BUILD_RELEASE_DISABLE_EXCEPTIONS=OFF`, so OCCT's range and argument checks stay exceptions.
- **`-ffp-contract=off`** for C and C++, so the compiler never fuses multiplies and adds. The build fails if any compile command lacks it.
- **Relocatable**: on Linux every library has the runpath `$ORIGIN`; on macOS the install names are `@rpath/…` and every library has the rpath `@loader_path`. Each library finds its OCCT dependencies next to itself, wherever the archive is unpacked. On macOS the deployment target is 11.0.

`./build.sh --config` prints the full configuration.

## Releases

Each release is tagged `occt-<version>-<config hash>` and attaches:

| Asset | What it is |
|---|---|
| `occt-<version>-<config hash>-aarch64-apple-darwin.tar.gz` | the install prefix for macOS arm64 |
| `occt-<version>-<config hash>-x86_64-unknown-linux-gnu.tar.gz` | the install prefix for Linux x64 |
| `SHA256SUMS` | the SHA-256 of every other asset |
| `occt-<version>-source.tar.gz` | the exact OCCT source that was built (`git archive` of the pinned commit) |
| `build.sh` | the build script |
| `LICENSE_LGPL_21.txt`, `OCCT_LGPL_EXCEPTION.txt` | OCCT's license and its exception |

Targets are named by their Rust target triple. Each archive holds a single directory named like the archive, which is the install prefix:

```
occt-8.0.1-<config hash>-<target>/
  manifest.json                  the build manifest (below)
  include/opencascade/           the headers; Standard_Version.hxx reports 8.0.1
  lib/                           libTK*.so / libTK*.dylib, with their version symlinks
  lib/cmake/opencascade/         OCCT's CMake package files
  bin/                           OCCT's environment scripts (env.sh, custom.sh)
  share/opencascade/resources/   OCCT's resource files
  share/doc/opencascade/         LICENSE_LGPL_21.txt, OCCT_LGPL_EXCEPTION.txt
  share/occt-build/              build.sh
```

To install one into a prefix:

```sh
curl -fLO https://github.com/TimothyBesada/occt-build/releases/download/<tag>/<archive>
curl -fLO https://github.com/TimothyBesada/occt-build/releases/download/<tag>/SHA256SUMS
grep " <archive>\$" SHA256SUMS | shasum -a 256 -c -
mkdir -p "$PREFIX" && tar -xzf <archive> -C "$PREFIX" --strip-components=1
```

## Building locally

Needs bash, git, CMake 3.16 or newer, and a C++17 compiler (Xcode's command-line tools on macOS, GCC or Clang on Linux). Ninja is used when it is installed. A build takes 15–30 minutes, depending on the machine.

```sh
./build.sh --prefix ~/opt/occt-8.0.1
```

- `--prefix DIR` is where OCCT is installed. It must be empty or not exist. The script writes `manifest.json` there.
- `--work-dir DIR` is where the source is fetched and the build runs, and it is kept afterwards; a clean checkout of the pinned commit there is reused. By default a temporary directory is used and removed.
- `--jobs N` sets the build's parallelism; it defaults to the number of CPUs.

The script verifies the build before it finishes: every compile command carries `-ffp-contract=off` and none disables exceptions, and the installed libraries are exactly the 16-toolkit set.

Two more modes need no compiler:

```sh
./build.sh --config-hash                      # print the config hash
./build.sh --source-archive occt-src.tar.gz   # fetch the pinned source as a tarball
```

To check an archive or a prefix the way CI does (Python 3.8+, a C++17 compiler, and `otool` or `readelf`):

```sh
python3 ci/check-archive.py ~/opt/occt-8.0.1
```

## The config hash

The config hash identifies a build configuration, so caches of OCCT builds can be keyed on it. It is the first 16 hex digits of the SHA-256 of the configuration lines in `build.sh`, each followed by a newline:

```sh
./build.sh --config | shasum -a 256 | cut -c1-16   # same as ./build.sh --config-hash
```

The lines cover:

- the OCCT version and commit;
- `occt-build.revision`, bumped when the archives' contents change and nothing else in the configuration does;
- every CMake option and compiler flag the script passes. `cmake.*` lines apply on every platform, and `linux.cmake.*` and `macos.cmake.*` lines only on that platform, so one hash covers both targets.

The compiler and the target are not part of the hash; `manifest.json` records them.

## manifest.json

Every install prefix, from a release or a local build, carries a `manifest.json`:

| Field | Value |
|---|---|
| `schema` | `1` |
| `occt` | `version`, `tag` and `commit` |
| `target` | the target triple, e.g. `aarch64-apple-darwin` |
| `config_hash` | the config hash |
| `config` | the configuration lines that hash to `config_hash` |
| `compiler`, `c_compiler` | the C++ and C compilers: CMake's `id` and `version`, and the first line of `--version` as `description` |
| `flags` | `cflags` and `cxxflags` passed to the compilers, and the `cmake` options passed on this platform |
| `toolkits` | the 16 toolkits |

## CI and publishing a release

[`.github/workflows/build.yml`](.github/workflows/build.yml) builds both targets on GitHub's free runners (`macos-15` and `ubuntu-24.04`) for every pull request and every push to `main`. It then checks each packed archive with `ci/check-archive.py`, from a fresh directory:

- the layout and every field of the manifest, against `build.sh`;
- install names and rpaths, with `otool -D`/`-L`/`-l` on macOS and `readelf -d` on Linux;
- that each library loads by absolute path with no library search path set;
- that a small program ([`ci/smoke.cpp`](ci/smoke.cpp)) builds against the archive, meshes a box, and catches an OCCT exception as `std::exception`.

To publish a release of the configuration on `main`, either run the workflow from the Actions tab with **release** ticked, or push the tag:

```sh
git tag "occt-8.0.1-$(./build.sh --config-hash)" && git push origin --tags
```

The release job refuses a tag that doesn't match the configuration, and never replaces an existing release. A configuration that changes gets a new hash, and so a new release.

## License

OCCT is licensed under the [GNU LGPL 2.1](https://github.com/Open-Cascade-SAS/OCCT/blob/V8_0_1/LICENSE_LGPL_21.txt) with the [Open CASCADE exception](https://github.com/Open-Cascade-SAS/OCCT/blob/V8_0_1/OCCT_LGPL_EXCEPTION.txt). Each release attaches OCCT's source, the build script and both texts, which together are the source offer for the libraries it distributes.
