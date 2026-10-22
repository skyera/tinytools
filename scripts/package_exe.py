"""Build the Windows single-file launcher. No downloaded packaging dependencies."""
import ctypes
from ctypes import wintypes
import hashlib
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
MAGIC = b"TTBNDL1\0"


def archive(bundle):
    files = sorted(p for p in bundle.rglob("*") if p.is_file())
    data = bytearray(MAGIC + struct.pack("<I", len(files)))
    for path in files:
        if path.is_symlink():
            raise ValueError(f"Refusing symlink in bundle: {path}")
        name = path.relative_to(bundle).as_posix().encode("ascii")
        if any(c not in b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./-" for c in name):
            raise ValueError(f"Unsupported bundle filename: {path}")
        content = path.read_bytes()
        data.extend(struct.pack("<IQ", len(name), len(content)))
        data.extend(hashlib.sha256(content).digest())
        data.extend(name)
        data.extend(content)
    return bytes(data)


def compress(data):
    api = ctypes.WinDLL("cabinet", use_last_error=True)
    api.CreateCompressor.argtypes = [wintypes.DWORD, ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)]
    api.CreateCompressor.restype = wintypes.BOOL
    api.Compress.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t,
                            ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)]
    api.Compress.restype = wintypes.BOOL
    api.CloseCompressor.argtypes = [ctypes.c_void_p]
    api.CloseCompressor.restype = wintypes.BOOL
    handle = ctypes.c_void_p()
    if not api.CreateCompressor(4, None, ctypes.byref(handle)):  # XPRESS_HUFF
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        source = ctypes.create_string_buffer(data)
        required = ctypes.c_size_t()
        if not api.Compress(handle, source, len(data), None, 0, ctypes.byref(required)):
            if ctypes.get_last_error() != 122:  # ERROR_INSUFFICIENT_BUFFER
                raise ctypes.WinError(ctypes.get_last_error())
        output = ctypes.create_string_buffer(required.value)
        if not api.Compress(handle, source, len(data), output, len(output), ctypes.byref(required)):
            raise ctypes.WinError(ctypes.get_last_error())
        return output.raw[:required.value]
    finally:
        api.CloseCompressor(handle)


def tool(env, default):
    name = os.environ.get(env, default)
    found = shutil.which(name)
    if not found:
        raise RuntimeError(f"Cannot find {name}; install it or set {env} to its path")
    return found


def main():
    if sys.platform != "win32":
        raise RuntimeError("The single-EXE target must be built on Windows")
    cc, windres, luajit = tool("CC", "gcc"), tool("WINDRES", "windres"), tool("LUAJIT_EXE", "luajit")
    work = ROOT / "build" / "single-exe"
    work.mkdir(parents=True, exist_ok=True)
    # Fresh staging excludes any old settings or stale files from earlier builds.
    stage = Path(tempfile.mkdtemp(prefix="bundle-", dir=work))
    subprocess.run([luajit, str(ROOT / "scripts/package.lua"), str(stage)], cwd=ROOT, check=True)
    raw = archive(stage)
    digest = hashlib.sha256(raw).digest()
    payload = compress(raw)
    (work / "bundle.bin").write_bytes(payload)
    (work / "bundle.h").write_text(
        f'#define BUNDLE_ID L"{digest.hex()}"\n'
        f'#define BUNDLE_SIZE {len(raw)}u\n'
        'static const unsigned char BUNDLE_SHA[32] = {' +
        ','.join(str(n) for n in digest) + '};\n', encoding="ascii")
    resource_path = (work / "bundle.bin").as_posix()
    (work / "bundle.rc").write_text(f'1 RCDATA "{resource_path}"\n', encoding="ascii")
    subprocess.run([windres, str(work / "bundle.rc"), "-O", "coff", "-o", str(work / "bundle.o")], check=True)
    exe = work / "tinytools.exe"
    subprocess.run([
        cc, "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", "-municode", "-mwindows",
        "-static-libgcc", "-D_WIN32_WINNT=0x0602", "-DNTDDI_VERSION=0x06020000",
        "-I", str(work), str(ROOT / "scripts/launcher.c"), str(work / "bundle.o"),
        "-Wl,--nxcompat,--dynamicbase", "-lbcrypt", "-lcabinet", "-lshell32", "-luser32",
        "-o", str(exe),
    ], check=True)
    destination = ROOT / "dist" / "tinytools.exe"
    destination.parent.mkdir(exist_ok=True)
    assert exe.resolve().is_relative_to(ROOT) and destination.resolve().is_relative_to(ROOT)
    # Publish only after the compiler succeeds; leave a previous build intact on failure.
    os.replace(exe, destination)
    print(f"exe: {destination} ({destination.stat().st_size / 1024 / 1024:.1f} MiB)")
    print(f"exe: content version {digest.hex()[:16]}; {len(raw) / 1024 / 1024:.1f} MiB unpacked")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as exc:
        print(f"exe: {exc}", file=sys.stderr)
        sys.exit(1)
