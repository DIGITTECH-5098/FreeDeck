//
//  RemoteStorageHook.h
//  FreeDeck
//
//  A tiny Objective-C dylib that is injected into guest apps so large files
//  can live on the FreeDeck server instead of the device. Reads of paths in
//  the remote-marker directory (Documents/FDRemote/), or of any file that
//  has a .fdmeta sidecar (JSON: {"url": "...", "size": 123}), are served by
//  HTTP Range requests against FREEDECK_SERVER, through an LRU disk cache
//  with a total-size cap (default 1 GB).
//
//  What is intercepted:
//    - fopen / fopen$DARWIN_EXTSN       (C file reads)
//    - mmap                             (mapped reads, by fd → path)
//    - +[NSData dataWithContentsOfFile:]
//    - +[NSData dataWithContentsOfURL:options:error:]
//    - -[NSFileManager fileExistsAtPath:]
//
//  Configuration, read once at install (environment first, then the
//  standard user defaults):
//    FREEDECK_SERVER        base URL, e.g. http://100.64.0.1:8080
//    FREEDECK_TOKEN         optional bearer token
//    FREEDECK_CACHE_DIR     cache directory (default NSTemporaryDirectory()/freedeck-cache)
//    FREEDECK_CACHE_CAP     cache cap in bytes (default 1073741824)
//    (defaults keys: freedeck.server, freedeck.token, freedeck.cacheDir,
//     freedeck.cacheCapBytes)
//
//  Memory management: this file compiles with ARC (Xcode's default) and
//  with ARC disabled. It makes no direct retain/release/autorelease calls;
//  where a value must survive past an autoreleased scope under MRC it goes
//  through the FD_RETAIN / FD_RELEASE / FD_AUTORELEASE macros below, which
//  are no-ops under ARC. Under MRC, run this file with -fno-objc-arc only
//  if you prefer; it is not required either way.
//
//  Exported control surface (C, extern "C" friendly):
//    void fd_storage_hook_install(void);   // idempotent; also runs from a constructor
//    int  fd_cache_preload(const char *path, long long offset, long long length);
//    void fd_cache_evict_all(void);
//    long long fd_cache_size_bytes(void);
//
//  fd_cache_preload returns 0 on success, -1 if the path is not remote,
//  -2 if the fetch failed. It warms the cache with the byte range asked
//  for (the whole file is fetched when the server does not answer with a
//  partial response).
//

#ifndef FreeDeck_RemoteStorageHook_h
#define FreeDeck_RemoteStorageHook_h

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Installs every hook exactly once. Safe to call from anywhere; the
/// dylib's constructor calls it as well.
void fd_storage_hook_install(void);

/// Ensures that the byte range [offset, offset + length) of the remote
/// file behind `path` is in the cache. `path` is a filesystem path as the
/// guest app would use it (a marker path or a file with a .fdmeta sidecar).
/// Returns 0 on success, -1 if `path` is not a remote file, -2 on a
/// network or cache failure.
int fd_cache_preload(const char *path, long long offset, long long length);

/// Drops every cached entry and its index.
void fd_cache_evict_all(void);

/// Current total size of the cache, in bytes.
long long fd_cache_size_bytes(void);

#ifdef __cplusplus
}
#endif

#endif /* FreeDeck_RemoteStorageHook_h */
