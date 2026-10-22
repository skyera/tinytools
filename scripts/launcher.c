/* Single-file Windows launcher. The resource is a hashed, compressed bundle.
 * Cache files are validated and repaired under an exclusive extraction lock.
 * No shell, installer, external decompressor, or administrator rights needed. */
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#include <windows.h>
#include <shlobj.h>
#include <shellapi.h>
#include <bcrypt.h>
#include <compressapi.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include "bundle.h"

#define PATH_CAP 4096
#define COMMAND_CAP 32767
static int cli_mode;
static BCRYPT_ALG_HANDLE sha_algorithm;

static int valid_handle(HANDLE h) { return h && h != INVALID_HANDLE_VALUE; }

static void report(const wchar_t *message) {
    DWORD error = GetLastError();
    wchar_t detail[1024] = L"", text[2048];
    FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
                   NULL, error, 0, detail, 1024, NULL);
    swprintf(text, 2048, L"tinytools: %ls\n%ls (Windows error %lu)\n", message, detail, error);
    if (cli_mode) {
        HANDLE out = GetStdHandle(STD_ERROR_HANDLE);
        DWORD mode, written;
        if (GetConsoleMode(out, &mode)) {
            WriteConsoleW(out, text, (DWORD)wcslen(text), &written, NULL);
        } else {
            char utf8[8192];
            int n = WideCharToMultiByte(CP_UTF8, 0, text, -1, utf8, sizeof(utf8), NULL, NULL);
            if (n > 0) WriteFile(out, utf8, (DWORD)n - 1, &written, NULL);
        }
    } else {
        MessageBoxW(NULL, text, L"tinytools", MB_OK | MB_ICONERROR);
    }
}

static int join(wchar_t out[PATH_CAP], const wchar_t *parent, const wchar_t *leaf) {
    if (wcslen(parent) + wcslen(leaf) + 2 > PATH_CAP) {
        SetLastError(ERROR_FILENAME_EXCED_RANGE); return 0;
    }
    swprintf(out, PATH_CAP, L"%ls\\%ls", parent, leaf);
    return 1;
}

static int directory(const wchar_t *path) {
    if (CreateDirectoryW(path, NULL)) return 1;
    DWORD attributes = GetFileAttributesW(path);
    if (attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_DIRECTORY)
        && !(attributes & FILE_ATTRIBUTE_REPARSE_POINT)) return 1;
    SetLastError(ERROR_CANNOT_MAKE); return 0;
}

static int parents(wchar_t *path) {
    /* Extraction paths have an existing absolute cache prefix. */
    for (wchar_t *p = path + 3; *p; ++p) {
        if (*p == L'\\' || *p == L'/') {
            wchar_t separator = *p;
            *p = 0;
            int ok = directory(path);
            *p = separator;
            if (!ok) return 0;
        }
    }
    return 1;
}

static int hash_memory(const unsigned char *data, size_t size, unsigned char digest[32]) {
    BCRYPT_HASH_HANDLE hash = NULL;
    if (BCryptCreateHash(sha_algorithm, &hash, NULL, 0, NULL, 0, 0) < 0) return 0;
    int ok = 1;
    while (size) {
        ULONG chunk = size > 65536 ? 65536 : (ULONG)size;
        if (BCryptHashData(hash, (PUCHAR)data, chunk, 0) < 0) { ok = 0; break; }
        data += chunk; size -= chunk;
    }
    if (ok) ok = BCryptFinishHash(hash, digest, 32, 0) >= 0;
    BCryptDestroyHash(hash);
    return ok;
}

static int file_matches(const wchar_t *path, uint64_t expected_size, const unsigned char digest[32]) {
    HANDLE file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                              NULL, OPEN_EXISTING, FILE_FLAG_SEQUENTIAL_SCAN, NULL);
    if (!valid_handle(file)) return 0;
    LARGE_INTEGER size;
    BCRYPT_HASH_HANDLE hash = NULL;
    int ok = GetFileSizeEx(file, &size) && (uint64_t)size.QuadPart == expected_size
        && BCryptCreateHash(sha_algorithm, &hash, NULL, 0, NULL, 0, 0) >= 0;
    unsigned char buffer[65536], actual[32];
    uint64_t total = 0;
    while (ok) {
        DWORD count;
        if (!ReadFile(file, buffer, sizeof(buffer), &count, NULL)) { ok = 0; break; }
        if (!count) break;
        total += count;
        if (BCryptHashData(hash, buffer, count, 0) < 0) ok = 0;
    }
    if (ok) ok = total == expected_size && BCryptFinishHash(hash, actual, 32, 0) >= 0
        && memcmp(actual, digest, 32) == 0;
    if (hash) BCryptDestroyHash(hash);
    CloseHandle(file);
    return ok;
}

static int write_file(const wchar_t *path, const unsigned char *data, uint64_t size) {
    wchar_t temporary[PATH_CAP];
    if (wcslen(path) + 32 >= PATH_CAP) { SetLastError(ERROR_FILENAME_EXCED_RANGE); return 0; }
    swprintf(temporary, PATH_CAP, L"%ls.tmp.%lu", path, GetCurrentProcessId());
    HANDLE file = CreateFileW(temporary, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (!valid_handle(file)) return 0;
    int ok = 1;
    while (size) {
        DWORD count, chunk = size > 65536 ? 65536 : (DWORD)size;
        if (!WriteFile(file, data, chunk, &count, NULL) || count != chunk) { ok = 0; break; }
        data += count; size -= count;
    }
    if (ok) ok = FlushFileBuffers(file);
    DWORD error = GetLastError();
    if (!CloseHandle(file) && ok) { ok = 0; error = GetLastError(); }
    if (ok) {
        ok = MoveFileExW(temporary, path, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
        error = GetLastError();
    }
    if (!ok) DeleteFileW(temporary);
    SetLastError(error);
    return ok;
}

static int safe_name(const unsigned char *name, uint32_t size) {
    if (!size || name[0] == '/' || name[size - 1] == '/') return 0;
    uint32_t component = 0;
    for (uint32_t i = 0; i <= size; ++i) {
        if (i == size || name[i] == '/') {
            uint32_t length = i - component;
            if (!length || name[i - 1] == '.' || (length == 1 && name[component] == '.')
                || (length == 2 && name[component] == '.' && name[component + 1] == '.')) return 0;
            component = i + 1;
        } else {
            unsigned char c = name[i];
            if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
                  || (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '.')) return 0;
        }
    }
    return 1;
}

static int extract(HINSTANCE instance, const wchar_t *cache) {
    HRSRC resource = FindResourceW(instance, MAKEINTRESOURCEW(1), RT_RCDATA);
    if (!resource) return 0;
    HGLOBAL loaded = LoadResource(instance, resource);
    void *compressed = loaded ? LockResource(loaded) : NULL;
    if (!compressed) return 0;
    DECOMPRESSOR_HANDLE decompressor;
    if (!CreateDecompressor(COMPRESS_ALGORITHM_XPRESS_HUFF, NULL, &decompressor)) return 0;
    unsigned char *raw = malloc(BUNDLE_SIZE);
    SIZE_T actual_size = 0;
    int ok = raw && Decompress(decompressor, compressed, SizeofResource(instance, resource),
                               raw, BUNDLE_SIZE, &actual_size) && actual_size == BUNDLE_SIZE;
    CloseDecompressor(decompressor);
    unsigned char digest[32];
    if (ok) ok = hash_memory(raw, BUNDLE_SIZE, digest) && memcmp(digest, BUNDLE_SHA, 32) == 0;
    if (!ok) { free(raw); SetLastError(ERROR_INVALID_DATA); return 0; }
    const unsigned char *p = raw, *end = raw + BUNDLE_SIZE;
    if (end - p < 12 || memcmp(p, "TTBNDL1\0", 8)) goto invalid;
    uint32_t count;
    memcpy(&count, p + 8, 4); p += 12;
    if (!count || count > 100000) goto invalid;
    for (uint32_t i = 0; i < count; ++i) {
        uint32_t name_size;
        uint64_t file_size;
        if (end - p < 44) goto invalid;
        memcpy(&name_size, p, 4); memcpy(&file_size, p + 4, 8);
        const unsigned char *expected_hash = p + 12;
        p += 44;
        if (name_size >= PATH_CAP || name_size > (size_t)(end - p) || !safe_name(p, name_size)) goto invalid;
        wchar_t relative[PATH_CAP], path[PATH_CAP];
        for (uint32_t n = 0; n < name_size; ++n) relative[n] = p[n] == '/' ? L'\\' : p[n];
        relative[name_size] = 0;
        p += name_size;
        if (file_size > (uint64_t)(end - p)) goto invalid;
        if (!join(path, cache, relative) || !parents(path)) { free(raw); return 0; }
        if (!file_matches(path, file_size, expected_hash)) {
            if (!hash_memory(p, (size_t)file_size, digest) || memcmp(digest, expected_hash, 32)) goto invalid;
            if (!write_file(path, p, file_size)) { free(raw); return 0; }
        }
        p += (size_t)file_size;
    }
    if (p != end) goto invalid;
    free(raw);
    return 1;
invalid:
    free(raw); SetLastError(ERROR_INVALID_DATA); return 0;
}

static int append_argument(wchar_t *command, size_t *length, const wchar_t *argument) {
    /* Microsoft CRT quoting: double backslashes before quotes and at the end. */
#define PUT(c) do { if (*length + 1 >= COMMAND_CAP) return 0; command[(*length)++] = (c); } while (0)
    if (*length) PUT(L' ');
    PUT(L'"');
    while (*argument) {
        size_t slashes = 0;
        while (*argument == L'\\') { ++slashes; ++argument; }
        size_t copies = slashes * ((!*argument || *argument == L'"') ? 2 : 1);
        for (size_t n = 0; n < copies; ++n) PUT(L'\\');
        if (!*argument) break;
        if (*argument == L'"') PUT(L'\\');
        PUT(*argument++);
    }
    PUT(L'"');
    command[*length] = 0;
    return 1;
#undef PUT
}

static DWORD launch(const wchar_t *cache, int argc, wchar_t **argv) {
    wchar_t runtime[PATH_CAP], script[PATH_CAP], command[COMMAND_CAP];
    if (!join(runtime, cache, L"luajit.exe") || !join(script, cache, L"apps\\toolbox.lua")) return 125;
    size_t length = 0;
    int ok = append_argument(command, &length, runtime) && append_argument(command, &length, script);
    for (int i = 1; ok && i < argc; ++i) ok = append_argument(command, &length, argv[i]);
    if (!ok) { SetLastError(ERROR_FILENAME_EXCED_RANGE); report(L"Command line is too long"); return 125; }
    STARTUPINFOW startup = {0};
    startup.cb = sizeof(startup);
    HANDLE inherited[3] = {NULL, NULL, NULL};
    if (cli_mode) {
        DWORD ids[3] = {STD_INPUT_HANDLE, STD_OUTPUT_HANDLE, STD_ERROR_HANDLE};
        for (int i = 0; i < 3; ++i) {
            HANDLE original = GetStdHandle(ids[i]);
            if (!valid_handle(original)) {
                original = CreateFileW(L"NUL", i ? GENERIC_WRITE : GENERIC_READ,
                                       FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
            }
            ok = DuplicateHandle(GetCurrentProcess(), original, GetCurrentProcess(), &inherited[i],
                                 0, TRUE, DUPLICATE_SAME_ACCESS);
            if (original != GetStdHandle(ids[i]) && valid_handle(original)) CloseHandle(original);
            if (!ok) break;
        }
        startup.dwFlags = STARTF_USESTDHANDLES;
        startup.hStdInput = inherited[0]; startup.hStdOutput = inherited[1]; startup.hStdError = inherited[2];
    }
    PROCESS_INFORMATION process = {0};
    if (ok) {
        // Inherit the caller's working directory so relative --in paths work.
        ok = CreateProcessW(runtime, command, NULL, NULL, cli_mode, cli_mode ? 0 : CREATE_NO_WINDOW,
                            NULL, NULL, &startup, &process);
    }
    DWORD error = GetLastError();
    for (int i = 0; i < 3; ++i) if (valid_handle(inherited[i])) CloseHandle(inherited[i]);
    if (!ok) { SetLastError(error); report(L"Cannot start the bundled runtime"); return 125; }
    CloseHandle(process.hThread);
    DWORD code = 125;
    if (WaitForSingleObject(process.hProcess, INFINITE) != WAIT_OBJECT_0
        || !GetExitCodeProcess(process.hProcess, &code)) report(L"Cannot wait for the application");
    CloseHandle(process.hProcess);
    return code;
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE previous, LPWSTR command_line, int show) {
    (void)previous; (void)command_line; (void)show;
    int argc;
    wchar_t **argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (!argv) return 125;
    cli_mode = argc > 1;
    if (cli_mode && !valid_handle(GetStdHandle(STD_OUTPUT_HANDLE))) AttachConsole(ATTACH_PARENT_PROCESS);
    wchar_t home[PATH_CAP], base[PATH_CAP], cache_parent[PATH_CAP], cache[PATH_CAP], state[PATH_CAP];
    DWORD n = GetEnvironmentVariableW(L"TINYTOOLS_HOME", base, PATH_CAP);
    int ok = n < PATH_CAP;
    if (!n) {
        ok = SUCCEEDED(SHGetFolderPathW(NULL, CSIDL_LOCAL_APPDATA | CSIDL_FLAG_CREATE, NULL, 0, base))
            && join(home, base, L"tinytools");
    } else if (ok) {
        DWORD full = GetFullPathNameW(base, PATH_CAP, home, NULL);
        ok = full > 0 && full < PATH_CAP;
    }
    if (ok) ok = parents(home) && directory(home)
        && join(cache_parent, home, L"cache") && directory(cache_parent)
        && join(state, home, L"state") && directory(state)
        && join(cache, cache_parent, BUNDLE_ID) && directory(cache);
    if (!ok) { report(L"Cannot create the application cache"); LocalFree(argv); return 125; }
    wchar_t lock_path[PATH_CAP];
    if (!join(lock_path, cache, L".extract.lock")) { report(L"Cache path is too long"); LocalFree(argv); return 125; }
    HANDLE lock = INVALID_HANDLE_VALUE;
    for (int attempt = 0; attempt < 1200; ++attempt) {
        lock = CreateFileW(lock_path, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        if (valid_handle(lock) || GetLastError() != ERROR_SHARING_VIOLATION) break;
        Sleep(50);
    }
    if (!valid_handle(lock)) { report(L"Cannot lock the application cache"); LocalFree(argv); return 125; }
    ok = BCryptOpenAlgorithmProvider(&sha_algorithm, BCRYPT_SHA256_ALGORITHM, NULL, 0) >= 0
        && extract(instance, cache);
    DWORD error = GetLastError();
    if (sha_algorithm) BCryptCloseAlgorithmProvider(sha_algorithm, 0);
    CloseHandle(lock);
    if (!ok) { SetLastError(error); report(L"Cannot unpack or repair the application cache"); LocalFree(argv); return 125; }
    // Prefer short paths for compatibility with Lua's Windows file APIs.
    wchar_t short_cache[PATH_CAP], short_state[PATH_CAP], libraries[PATH_CAP];
    n = GetShortPathNameW(cache, short_cache, PATH_CAP);
    if (n && n < PATH_CAP) wcscpy(cache, short_cache);
    n = GetShortPathNameW(state, short_state, PATH_CAP);
    if (n && n < PATH_CAP) wcscpy(state, short_state);
    ok = join(libraries, cache, L"build\\out")
        && SetEnvironmentVariableW(L"TINYTOOLS_OUT", libraries)
        && SetEnvironmentVariableW(L"TINYTOOLS_STATE_DIR", state);
    DWORD code;
    if (!ok) { report(L"Cannot configure the application paths"); code = 125; }
    else code = launch(cache, argc, argv);
    LocalFree(argv);
    return (int)code;
}
