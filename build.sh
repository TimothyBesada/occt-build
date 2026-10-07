#!/usr/bin/env bash
#
# Builds the pinned OCCT into an install prefix: the 27-toolkit modeling and
# STEP set, shared, with no third-party dependencies.
#
#   ./build.sh --prefix DIR [--work-dir DIR] [--jobs N]
#   ./build.sh --config
#   ./build.sh --config-hash
#   ./build.sh --source-archive FILE [--work-dir DIR]
#
# Needs bash 3.2+, git, CMake 3.16+ and a C++17 compiler; uses Ninja when it is
# installed. Runs on macOS and Linux. See README.md.

set -euo pipefail

OCCT_VERSION=8.0.1
OCCT_TAG=V8_0_1
OCCT_COMMIT=b8f597c677811d1f9f4d8a97f5ae2825c0353a42
OCCT_REPO=https://github.com/Open-Cascade-SAS/OCCT

# The 27-toolkit modeling and STEP set: the closure of the roots in
# BUILD_ADDITIONAL_TOOLKITS below. The build fails if the install differs.
#
# TKDESTEP (STEPControl and STEPCAFControl) links TKXCAF, and TKXCAF links
# TKVCAF, TKV3d and TKService, and TKV3d links TKHLR. OCCT's CMake builds that
# whole closure; with every USE_* off none of it needs a third-party library.
TOOLKITS="TKernel TKMath TKG2d TKG3d TKGeomBase TKBRep TKGeomAlgo TKTopAlgo
TKShHealing TKPrim TKMesh TKBO TKBool TKFillet TKOffset TKFeat TKHLR TKService
TKV3d TKCDF TKLCAF TKCAF TKVCAF TKXSBase TKDE TKXCAF TKDESTEP"

# The build configuration. These lines, each followed by a newline, hash to the
# config hash (the first 16 hex digits of their SHA-256). `cmake.*` lines are
# passed to CMake on every platform, `linux.cmake.*` and `macos.cmake.*` lines
# only there, so one hash covers both targets.
#
# Anything that changes the build or the archives' contents must change these
# lines; if nothing else does, bump occt-build.revision.
CONFIG=(
  "occt.version=$OCCT_VERSION"
  "occt.commit=$OCCT_COMMIT"
  "occt-build.revision=1"
  "cmake.CMAKE_BUILD_TYPE=Release"
  "cmake.BUILD_LIBRARY_TYPE=Shared"
  "cmake.BUILD_RELEASE_DISABLE_EXCEPTIONS=OFF"
  "cmake.BUILD_MODULE_FoundationClasses=OFF"
  "cmake.BUILD_MODULE_ModelingData=OFF"
  "cmake.BUILD_MODULE_ModelingAlgorithms=OFF"
  "cmake.BUILD_MODULE_Visualization=OFF"
  "cmake.BUILD_MODULE_ApplicationFramework=OFF"
  "cmake.BUILD_MODULE_DataExchange=OFF"
  "cmake.BUILD_MODULE_Draw=OFF"
  "cmake.BUILD_ADDITIONAL_TOOLKITS=TKPrim;TKMesh;TKBO;TKBool;TKFillet;TKOffset;TKFeat;TKDESTEP"
  "cmake.BUILD_GTEST=OFF"
  "cmake.BUILD_DOC_Overview=OFF"
  "cmake.BUILD_USE_PCH=OFF"
  "cmake.BUILD_USE_VCPKG=OFF"
  "cmake.USE_D3D=OFF"
  "cmake.USE_DRACO=OFF"
  "cmake.USE_EIGEN=OFF"
  "cmake.USE_FFMPEG=OFF"
  "cmake.USE_FREEIMAGE=OFF"
  "cmake.USE_FREETYPE=OFF"
  "cmake.USE_GLES2=OFF"
  "cmake.USE_OPENGL=OFF"
  "cmake.USE_OPENVR=OFF"
  "cmake.USE_RAPIDJSON=OFF"
  "cmake.USE_TBB=OFF"
  "cmake.USE_TK=OFF"
  "cmake.USE_VTK=OFF"
  "cmake.USE_XLIB=OFF"
  "cmake.USE_MMGR_TYPE=NATIVE"
  "cmake.CMAKE_C_FLAGS=-ffp-contract=off"
  "cmake.CMAKE_CXX_FLAGS=-ffp-contract=off"
  "linux.cmake.CMAKE_INSTALL_RPATH=\$ORIGIN"
  "macos.cmake.INSTALL_NAME_DIR=@rpath"
  "macos.cmake.CMAKE_INSTALL_RPATH=@loader_path"
  "macos.cmake.CMAKE_OSX_DEPLOYMENT_TARGET=11.0"
)

usage() {
  cat <<EOF
Usage:
  $0 --prefix DIR [--work-dir DIR] [--jobs N]
      Build OCCT $OCCT_VERSION ($OCCT_TAG, $OCCT_COMMIT) and install it into
      DIR, which must be empty or not exist. Writes DIR/manifest.json.
  $0 --config
      Print the build configuration.
  $0 --config-hash
      Print the config hash.
  $0 --source-archive FILE [--work-dir DIR]
      Fetch the pinned OCCT source and write it to FILE as a .tar.gz.

Options:
  --work-dir DIR  Where the source is fetched and the build runs. Kept
                  afterwards; by default a temporary directory that is removed.
  --jobs N        Parallel build jobs (default: the number of CPUs).
EOF
}

log() { printf '==> %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | cut -d' ' -f1
  fi
}

config_hash() { printf '%s\n' "${CONFIG[@]}" | sha256 | cut -c1-16; }

detect_platform() {
  local arch os
  case "$(uname -s)" in
    Linux) PLATFORM=linux os=unknown-linux-gnu LIB_EXT=so ;;
    Darwin) PLATFORM=macos os=apple-darwin LIB_EXT=dylib ;;
    *) die "unsupported OS $(uname -s): macOS and Linux only" ;;
  esac
  arch=$(uname -m)
  [ "$arch" = arm64 ] && arch=aarch64
  TARGET="$arch-$os"
}

# Prints the value of a config line, e.g. `config_value cmake.CMAKE_CXX_FLAGS`.
config_value() {
  local line
  for line in "${CONFIG[@]}"; do
    case "$line" in "$1"=*) printf '%s\n' "${line#*=}" ;; esac
  done
}

# Prints the -D options for this platform, one per line.
cmake_options() {
  local line
  for line in "${CONFIG[@]}"; do
    case "$line" in
      cmake.*) printf -- '-D%s\n' "${line#cmake.}" ;;
      "$PLATFORM".cmake.*) printf -- '-D%s\n' "${line#"$PLATFORM".cmake.}" ;;
    esac
  done
}

# Fetches the pinned commit into $1, or reuses a clean checkout of it there.
fetch_source() {
  local src=$1
  if [ -d "$src/.git" ] &&
    [ "$(git -C "$src" rev-parse HEAD 2>/dev/null)" = "$OCCT_COMMIT" ] &&
    [ -z "$(git -C "$src" status --porcelain)" ]; then
    log "Reusing the OCCT source in $src"
    return
  fi
  log "Fetching OCCT $OCCT_COMMIT from $OCCT_REPO"
  rm -rf "$src"
  mkdir -p "$src"
  git -C "$src" init -q
  git -C "$src" fetch -q --depth 1 "$OCCT_REPO" "$OCCT_COMMIT"
  git -C "$src" -c advice.detachedHead=false checkout -q FETCH_HEAD
  [ "$(git -C "$src" rev-parse HEAD)" = "$OCCT_COMMIT" ] ||
    die "fetched $(git -C "$src" rev-parse HEAD), expected $OCCT_COMMIT"
}

json_string() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '"%s"' "$s"
}

# Prints the arguments as a JSON array of strings.
json_array() {
  local sep="" item
  printf '['
  for item in "$@"; do
    printf '%s\n    %s' "$sep" "$(json_string "$item")"
    sep=,
  done
  printf '\n  ]'
}

# Reads `set(VAR "value")` from a CMake compiler-info file.
cmake_compiler_var() {
  sed -n "s/^set($2 \"\(.*\)\")\$/\1/p" "$1" | head -n1
}

# Prints a JSON object for the compiler of language $2 (C or CXX), as CMake
# found it in the build directory $1.
compiler_json() {
  local info path
  for info in "$1"/CMakeFiles/*/CMake"$2"Compiler.cmake; do break; done
  path=$(cmake_compiler_var "$info" CMAKE_"$2"_COMPILER)
  printf '{\n'
  printf '    "id": %s,\n' "$(json_string "$(cmake_compiler_var "$info" CMAKE_"$2"_COMPILER_ID)")"
  printf '    "version": %s,\n' "$(json_string "$(cmake_compiler_var "$info" CMAKE_"$2"_COMPILER_VERSION)")"
  printf '    "description": %s\n' "$(json_string "$("$path" --version | head -n1)")"
  printf '  }'
}

write_manifest() {
  local prefix=$1 build=$2 line
  local options=()
  while IFS= read -r line; do options+=("$line"); done < <(cmake_options)
  {
    printf '{\n'
    printf '  "schema": 1,\n'
    printf '  "occt": {\n'
    printf '    "version": %s,\n' "$(json_string "$OCCT_VERSION")"
    printf '    "tag": %s,\n' "$(json_string "$OCCT_TAG")"
    printf '    "commit": %s\n' "$(json_string "$OCCT_COMMIT")"
    printf '  },\n'
    printf '  "target": %s,\n' "$(json_string "$TARGET")"
    printf '  "config_hash": %s,\n' "$(json_string "$(config_hash)")"
    printf '  "config": %s,\n' "$(json_array "${CONFIG[@]}")"
    printf '  "compiler": %s,\n' "$(compiler_json "$build" CXX)"
    printf '  "c_compiler": %s,\n' "$(compiler_json "$build" C)"
    printf '  "flags": {\n'
    printf '    "cflags": %s,\n' "$(json_string "$(config_value cmake.CMAKE_C_FLAGS)")"
    printf '    "cxxflags": %s,\n' "$(json_string "$(config_value cmake.CMAKE_CXX_FLAGS)")"
    printf '    "cmake": %s\n' "$(json_array "${options[@]}" | sed 's/^/  /; 1s/^  //')"
    printf '  },\n'
    # shellcheck disable=SC2086 # split the list into words
    printf '  "toolkits": %s\n' "$(json_array $TOOLKITS)"
    printf '}\n'
  } >"$prefix/manifest.json"
}

check_compile_commands() {
  local db=$1 total missing
  total=$(grep -c '"command"' "$db" || true)
  missing=$(grep '"command"' "$db" | grep -vc -- '-ffp-contract=off' || true)
  [ "$total" -gt 0 ] || die "no compile commands in $db"
  [ "$missing" -eq 0 ] || die "$missing of $total compile commands lack -ffp-contract=off"
  if grep -q -- '-DNo_Exception' "$db"; then
    die "compile commands define No_Exception; exceptions must stay enabled"
  fi
}

check_toolkits() {
  local lib=$1 built expected
  # shellcheck disable=SC2086
  expected=$(printf '%s\n' $TOOLKITS | sort)
  # shellcheck disable=SC2012 # library names are plain
  built=$(ls "$lib" | sed -n "s/^lib\([A-Za-z0-9_]*\)\.$LIB_EXT\$/\1/p" | sort)
  [ "$built" = "$expected" ] ||
    die "installed toolkits differ from the 27-toolkit set:
$(diff <(echo "$expected") <(echo "$built") || true)"
}

build() {
  local prefix=$1 work=$2 jobs=$3 src build line generator=""
  local options=()
  src="$work/src"
  build="$work/build"

  fetch_source "$src"

  while IFS= read -r line; do options+=("$line"); done < <(cmake_options)
  command -v ninja >/dev/null 2>&1 && generator=Ninja

  log "Configuring (config hash $(config_hash), target $TARGET)"
  rm -rf "$build"
  cmake -S "$src" -B "$build" ${generator:+-G "$generator"} \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
    "${options[@]}"
  check_compile_commands "$build/compile_commands.json"

  log "Building with $jobs jobs"
  cmake --build "$build" --parallel "$jobs"

  log "Installing into $prefix"
  cmake --install "$build"
  check_toolkits "$prefix/lib"
  mkdir -p "$prefix/share/occt-build"
  cp "$SCRIPT" "$prefix/share/occt-build/build.sh"
  write_manifest "$prefix" "$build"
  log "Done: $prefix"
}

main() {
  local mode="" prefix="" work="" jobs="" out=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --prefix) prefix=${2:?--prefix needs a directory}; mode=build; shift 2 ;;
      --work-dir) work=${2:?--work-dir needs a directory}; shift 2 ;;
      --jobs) jobs=${2:?--jobs needs a number}; shift 2 ;;
      --config) mode=config; shift ;;
      --config-hash) mode=config-hash; shift ;;
      --source-archive) out=${2:?--source-archive needs a file}; mode=source; shift 2 ;;
      -h | --help) usage; exit 0 ;;
      *) usage >&2; die "unknown argument: $1" ;;
    esac
  done

  case "$mode" in
    config) printf '%s\n' "${CONFIG[@]}"; return ;;
    config-hash) config_hash; return ;;
    "") usage >&2; exit 2 ;;
  esac

  command -v git >/dev/null 2>&1 || die "git is required"
  SCRIPT="$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")"

  if [ -z "$work" ]; then
    work=$(mktemp -d "${TMPDIR:-/tmp}/occt-build.XXXXXX")
    # shellcheck disable=SC2064 # expand $work now
    trap "rm -rf '$work'" EXIT
  fi
  mkdir -p "$work"
  work=$(cd "$work" && pwd -P)

  case "$mode" in
    source)
      mkdir -p "$(dirname "$out")"
      out="$(cd "$(dirname "$out")" && pwd -P)/$(basename "$out")"
      fetch_source "$work/src"
      git -C "$work/src" archive --format=tar --prefix="occt-$OCCT_VERSION/" HEAD |
        gzip -n -9 >"$out"
      log "Wrote $out"
      ;;
    build)
      command -v cmake >/dev/null 2>&1 || die "cmake is required"
      detect_platform
      if [ -e "$prefix" ] && [ -n "$(ls -A "$prefix")" ]; then
        die "the prefix $prefix is not empty"
      fi
      mkdir -p "$prefix"
      prefix=$(cd "$prefix" && pwd -P)
      [ -n "$jobs" ] || jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)
      build "$prefix" "$work" "$jobs"
      ;;
  esac
}

# Exit on the same line, so that editing this file during a build is safe.
main "$@"; exit
