#!/usr/bin/env python3
"""Checks an occt-build archive or install prefix.

Usage: ci/check-archive.py PATH

PATH is a release archive (.tar.gz), which is unpacked into a fresh temporary
directory first, or an install prefix. Every check runs against that copy, so
a pass means the libraries work from wherever they are unpacked:

  layout     the headers, with Standard_Version.hxx at 8.0.1; exactly the
             16-toolkit set; the license texts and the build script
  manifest   every field of manifest.json, against this repo's build.sh, and
             the config hash recomputed from the config lines
  linkage    install names and rpaths (otool on macOS, readelf on Linux): each
             library finds its OCCT dependencies next to itself, and depends
             on nothing outside OCCT but the system's C and C++ runtimes
  loading    each library dlopen'ed by absolute path in a fresh process, with
             no library search path set
  smoke      ci/smoke.cpp compiled against the prefix: it meshes a box and
             catches an OCCT exception as std::exception

Needs Python 3.8+, a C++17 compiler, and otool (macOS) or readelf (Linux).
"""

import hashlib
import json
import os
import platform
import re
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BUILD_SH = REPO / "build.sh"

TOOLKITS = {
    "TKernel", "TKMath", "TKG2d", "TKG3d", "TKGeomBase", "TKBRep",
    "TKGeomAlgo", "TKTopAlgo", "TKShHealing", "TKPrim", "TKMesh", "TKBO",
    "TKBool", "TKFillet", "TKOffset", "TKFeat",
}
# The libraries the smoke test links directly; the rest load transitively.
SMOKE_LIBS = ["TKMesh", "TKPrim", "TKTopAlgo", "TKBRep", "TKG3d", "TKMath", "TKernel"]
# One public header per root toolkit of the set.
HEADERS = [
    "BRepPrimAPI_MakeBox.hxx",       # TKPrim
    "BRepMesh_IncrementalMesh.hxx",  # TKMesh
    "BRepAlgoAPI_Fuse.hxx",          # TKBO
    "BRepFill_Filling.hxx",          # TKBool
    "BRepFilletAPI_MakeFillet.hxx",  # TKFillet
    "BRepOffsetAPI_MakeThickSolid.hxx",  # TKOffset
    "BRepFeat_MakePrism.hxx",        # TKFeat
]
LINUX_SYSTEM_LIBS = {
    "libc.so.6", "libm.so.6", "libstdc++.so.6", "libgcc_s.so.1",
    "libpthread.so.0", "libdl.so.2", "librt.so.1",
    "ld-linux-x86-64.so.2", "ld-linux-aarch64.so.1",
}
MACOS_SYSTEM_PREFIXES = ("/usr/lib/", "/System/Library/")
SEARCH_PATH_VARS = (
    "LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH", "DYLD_FALLBACK_LIBRARY_PATH",
    "DYLD_FRAMEWORK_PATH", "DYLD_INSERT_LIBRARIES",
)

errors = []


def check(ok, message):
    if not ok:
        errors.append(message)
        print(f"  FAIL {message}")
    return ok


def run(args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, text=True, **kwargs).stdout


def clean_env():
    return {k: v for k, v in os.environ.items() if k not in SEARCH_PATH_VARS}


def pin():
    """The OCCT_* variables and the config lines of build.sh."""
    values = dict(re.findall(r"^OCCT_(\w+)=(\S+)$", BUILD_SH.read_text(), re.M))
    config = run([str(BUILD_SH), "--config"]).splitlines()
    return values, config


def host():
    system = platform.system()
    arch = {"arm64": "aarch64"}.get(platform.machine(), platform.machine())
    if system == "Darwin":
        return "macos", f"{arch}-apple-darwin", "dylib"
    if system == "Linux":
        return "linux", f"{arch}-unknown-linux-gnu", "so"
    sys.exit(f"unsupported OS {system}")


def unpack(archive, into):
    print(f"Unpacking {archive.name}")
    with tarfile.open(archive) as tar:
        names = tar.getnames()
        tops = {n.split("/", 1)[0] for n in names}
        expected = archive.name[: -len(".tar.gz")]
        check(tops == {expected}, f"the archive's top-level directory is {sorted(tops)}, expected {expected}")
        for member in tar.getmembers():
            check(not member.name.startswith("/") and ".." not in Path(member.name).parts,
                  f"unsafe path in archive: {member.name}")
        if errors:
            sys.exit(1)
        if hasattr(tarfile, "data_filter"):
            tar.extractall(into, filter="data")
        else:
            tar.extractall(into)
    return Path(into) / expected


def libraries(lib, ext):
    """Maps each toolkit to its real library file, checking the symlinks to it."""
    real = {}
    for path in sorted(lib.iterdir()):
        m = re.fullmatch(rf"lib(\w+)\.{ext}", path.name)
        if not m:
            continue
        check(path.is_symlink(), f"{path.name} should be a symlink to the versioned library")
        target = path.resolve()
        check(target.parent == lib.resolve(), f"{path.name} resolves outside lib/: {target}")
        link = path
        while link.is_symlink():
            check(not os.readlink(link).startswith("/"), f"{link.name} is an absolute symlink")
            link = link.parent / os.readlink(link)
        real[m.group(1)] = target
    return real


def check_layout(prefix, ext, values):
    print("Layout")
    include = prefix / "include" / "opencascade"
    version = include / "Standard_Version.hxx"
    if check(version.is_file(), "include/opencascade/Standard_Version.hxx is missing"):
        text = version.read_text()
        check(f'#define OCC_VERSION_COMPLETE "{values["VERSION"]}"' in text,
              f"Standard_Version.hxx does not report {values['VERSION']}")
        check(not re.search(r"^\s*#define OCC_VERSION_DEVELOPMENT", text, re.M),
              "Standard_Version.hxx defines OCC_VERSION_DEVELOPMENT")
    for header in HEADERS:
        check((include / header).is_file(), f"header {header} is missing")
    real = libraries(prefix / "lib", ext)
    check(set(real) == TOOLKITS,
          f"libraries differ from the 16-toolkit set: missing {sorted(TOOLKITS - set(real))}, "
          f"extra {sorted(set(real) - TOOLKITS)}")
    for name in ("LICENSE_LGPL_21.txt", "OCCT_LGPL_EXCEPTION.txt"):
        check(any(prefix.rglob(name)), f"{name} is missing")
    script = prefix / "share" / "occt-build" / "build.sh"
    check(script.is_file() and script.read_bytes() == BUILD_SH.read_bytes(),
          "share/occt-build/build.sh is missing or differs from this repo's build.sh")
    return real


def check_manifest(prefix, os_name, target, values, config, archive):
    print("Manifest")
    try:
        manifest = json.loads((prefix / "manifest.json").read_text())
    except (OSError, ValueError) as e:
        check(False, f"manifest.json is missing or invalid: {e}")
        return
    get = lambda *keys: _dig(manifest, keys)
    config_hash = hashlib.sha256("".join(line + "\n" for line in config).encode()).hexdigest()[:16]
    options = []
    for line in config:
        for scope in ("cmake.", f"{os_name}.cmake."):
            if line.startswith(scope):
                options.append("-D" + line[len(scope):])
    check(get("schema") == 1, "manifest schema is not 1")
    check(get("occt", "version") == values["VERSION"], f"occt.version is not {values['VERSION']}")
    check(get("occt", "tag") == values["TAG"], f"occt.tag is not {values['TAG']}")
    check(get("occt", "commit") == values["COMMIT"], f"occt.commit is not {values['COMMIT']}")
    check(get("target") == target, f"target is {get('target')!r}, expected {target}")
    check(get("config") == config, "config differs from build.sh --config")
    check(get("config_hash") == config_hash, f"config_hash is {get('config_hash')!r}, expected {config_hash}")
    for compiler in ("compiler", "c_compiler"):
        for key in ("id", "version", "description"):
            check(isinstance(get(compiler, key), str) and get(compiler, key),
                  f"{compiler}.{key} is missing")
    for key in ("cflags", "cxxflags"):
        check("-ffp-contract=off" in str(get("flags", key)), f"flags.{key} lacks -ffp-contract=off")
    check(get("flags", "cmake") == options, "flags.cmake differs from the config's options")
    check(set(get("toolkits") or []) == TOOLKITS, "toolkits differ from the 16-toolkit set")
    if archive:
        name = f"occt-{values['VERSION']}-{config_hash}-{target}.tar.gz"
        check(archive.name == name, f"the archive is named {archive.name}, expected {name}")
    print(f"  occt {get('occt', 'version')} {get('occt', 'commit')}, config hash {get('config_hash')}")
    print(f"  compiler {get('compiler', 'description')}")


def _dig(value, keys):
    for key in keys:
        if not isinstance(value, dict):
            return None
        value = value.get(key)
    return value


def check_linkage_linux(real):
    print("Linkage (readelf -d)")
    dynamic = {
        tk: re.findall(r"\((NEEDED|SONAME|RUNPATH|RPATH)\)\s+.*?\[(.*)\]", run(["readelf", "-d", str(p)]))
        for tk, p in real.items()
    }
    sonames = {tk: next((v for k, v in entries if k == "SONAME"), None) for tk, entries in dynamic.items()}
    occt = set(sonames.values())
    for tk, path in real.items():
        entries = dynamic[tk]
        check(sonames[tk] == f"lib{tk}.so.8.0", f"{path.name}: SONAME is {sonames[tk]}")
        paths = [v for k, v in entries if k in ("RUNPATH", "RPATH")]
        check(paths == ["$ORIGIN"], f"{path.name}: RUNPATH/RPATH is {paths}, expected ['$ORIGIN']")
        for needed in (v for k, v in entries if k == "NEEDED"):
            check(needed in occt or needed in LINUX_SYSTEM_LIBS,
                  f"{path.name}: unexpected dependency {needed}")
        print(f"  {path.name}: RUNPATH {paths}")


def check_linkage_macos(real, config):
    print("Linkage (otool -D, -L, -l)")
    minos = next(l.split("=", 1)[1] for l in config if l.startswith("macos.cmake.CMAKE_OSX_DEPLOYMENT_TARGET="))
    ids = {tk: run(["otool", "-D", str(p)]).splitlines()[-1].strip() for tk, p in real.items()}
    for tk, path in real.items():
        check(ids[tk] == f"@rpath/lib{tk}.8.0.dylib", f"{path.name}: install name is {ids[tk]}")
        deps = [line.strip().split(" (")[0] for line in run(["otool", "-L", str(path)]).splitlines()[1:]]
        for dep in deps:
            if dep == ids[tk]:
                continue
            check(dep in ids.values() or dep.startswith(MACOS_SYSTEM_PREFIXES),
                  f"{path.name}: unexpected dependency {dep}")
        commands = run(["otool", "-l", str(path)])
        rpaths = re.findall(r"cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (.*) \(offset \d+\)", commands)
        check(rpaths == ["@loader_path"], f"{path.name}: LC_RPATH is {rpaths}, expected ['@loader_path']")
        found = re.findall(r"cmd LC_BUILD_VERSION\n\s+cmdsize \d+\n\s+platform \S+\n\s+minos (\S+)", commands)
        check(found == [minos], f"{path.name}: minos is {found}, expected {minos}")
        print(f"  {path.name}: {ids[tk]}, LC_RPATH {rpaths}")


def check_loading(real):
    print("Loading (dlopen by absolute path, no search path)")
    for tk, path in sorted(real.items()):
        result = subprocess.run(
            [sys.executable, "-c", "import ctypes, sys; ctypes.CDLL(sys.argv[1])", str(path)],
            capture_output=True, text=True, env=clean_env())
        check(result.returncode == 0, f"{path.name} does not load: {result.stderr.strip()}")
    print(f"  {len(real)} libraries load")


def check_smoke(prefix, workdir):
    print("Smoke test")
    lib = prefix / "lib"
    exe = Path(workdir) / "smoke"
    cxx = os.environ.get("CXX", "c++")
    args = [cxx, "-std=c++17", "-I", str(prefix / "include" / "opencascade"),
            str(REPO / "ci" / "smoke.cpp"), "-o", str(exe), "-L", str(lib)]
    args += [f"-l{tk}" for tk in SMOKE_LIBS] + [f"-Wl,-rpath,{lib}"]
    result = subprocess.run(args, capture_output=True, text=True)
    if not check(result.returncode == 0, f"smoke.cpp does not build:\n{result.stderr}"):
        return
    result = subprocess.run([str(exe)], capture_output=True, text=True, env=clean_env())
    print("  " + result.stdout.strip().replace("\n", "\n  "))
    check(result.returncode == 0, f"smoke test failed: {result.stderr.strip()}")


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    path = Path(sys.argv[1]).resolve()
    os_name, target, ext = host()
    values, config = pin()
    with tempfile.TemporaryDirectory(prefix="occt-check.") as workdir:
        archive = path if path.is_file() else None
        prefix = unpack(path, workdir) if archive else path
        real = check_layout(prefix, ext, values)
        check_manifest(prefix, os_name, target, values, config, archive)
        if set(real) == TOOLKITS:
            if os_name == "linux":
                check_linkage_linux(real)
            else:
                check_linkage_macos(real, config)
            check_loading(real)
        check_smoke(prefix, workdir)
    if errors:
        print(f"\n{len(errors)} check(s) failed")
        sys.exit(1)
    print("\nAll checks passed")


if __name__ == "__main__":
    main()
