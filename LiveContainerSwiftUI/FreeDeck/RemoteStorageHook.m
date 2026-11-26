//
//  RemoteStorageHook.m
//  FreeDeck
//
//  The implementation behind RemoteStorageHook.h — read that first. In
//  short: injected into guest apps, this rebinding layer turns reads of
//  remote-marker files (Documents/FDRemote/, or anything with a .fdmeta
//  sidecar) into HTTP Range requests against the FreeDeck server, fronted
//  by a small LRU disk cache with a size cap.
//
//  Layout of this file:
//    1. Memory-management macros (ARC and MRC alike)
//    2. A minimal fishhook-style symbol rebinding (self-contained, no deps)
//    3. Configuration from the environment and user defaults
//    4. The LRU cache (index.json + POSIX file I/O)
//    5. Remote-file detection (marker directory / .fdmeta sidecar)
//    6. HTTP Range fetching (NSURLSession, bridged synchronously)
//    7. The hooks: fopen, mmap, NSData, NSFileManager
//    8. The exported control functions and the install routine
//
//  Everything internal avoids the hooked entry points: file reads use the
//  real fopen saved before rebinding or plain POSIX open/pread, so the
//  hooks cannot re-enter themselves through their own bookkeeping.
//

#import "RemoteStorageHook.h"

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <objc/runtime.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>
#import <fcntl.h>
#import <limits.h>
#import <float.h>

// MARK: - 1. Memory management

// No explicit retain/release/autorelease appears in this file; these macros
// are the only place the two modes differ. Under ARC they are no-ops.
#if __has_feature(objc_arc)
#define FD_RETAIN(x) (x)
#define FD_RELEASE(x) ((void)(x))
#define FD_AUTORELEASE(x) (x)
#else
#define FD_RETAIN(x) [(x) retain]
#define FD_RELEASE(x) [(x) release]
#define FD_AUTORELEASE(x) [(x) autorelease]
#endif

// MARK: - 2. Symbol rebinding (fishhook-style)

// A rebinding: route calls to `name` through `replacement`, and (optionally)
// receive the original implementation in `replaced`.
struct fd_rebinding {
    const char *name;
    void *replacement;
    void **replaced;
};

static struct fd_rebinding *_fd_rebindings = NULL;
static size_t _fd_rebindings_count = 0;

// Writes one function pointer into a (possibly read-only) symbol slot,
// making the page writable first — iOS 15+ keeps __DATA_CONST read-only
// after dyld is done with it.
static void fd_write_pointer(void **slot, void *value) {
    long page_size = getpagesize();
    uintptr_t page = (uintptr_t)slot & ~((uintptr_t)page_size - 1);
    vm_protect(mach_task_self(), (vm_address_t)page, (vm_size_t)page_size, false,
               VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    *slot = value;
}

static void fd_rebind_section(const struct section_64 *section, intptr_t slide,
                              struct nlist_64 *symtab, char *strtab,
                              uint32_t *indirect_symtab) {
    uint32_t *indices = indirect_symtab + section->reserved1;
    void **bindings = (void **)((uintptr_t)slide + section->addr);
    uint32_t count = (uint32_t)(section->size / sizeof(void *));
    for (uint32_t i = 0; i < count; i++) {
        uint32_t symtab_index = indices[i];
        if (symtab_index == INDIRECT_SYMBOL_ABS ||
            symtab_index == INDIRECT_SYMBOL_LOCAL ||
            symtab_index == (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) {
            continue;
        }
        char *symbol_name = strtab + symtab[symtab_index].n_un.n_strx;
        // Mach-O symbol names carry a leading underscore; our rebindings
        // use the plain C names.
        if (symbol_name[0] != '_' || symbol_name[1] == '\0') {
            continue;
        }
        for (size_t j = 0; j < _fd_rebindings_count; j++) {
            if (strcmp(symbol_name + 1, _fd_rebindings[j].name) != 0) {
                continue;
            }
            if (_fd_rebindings[j].replaced != NULL && *_fd_rebindings[j].replaced == NULL) {
                *_fd_rebindings[j].replaced = bindings[i];
            }
            if (bindings[i] != _fd_rebindings[j].replacement) {
                fd_write_pointer(&bindings[i], _fd_rebindings[j].replacement);
            }
            break;
        }
    }
}

static void fd_rebind_image(const struct mach_header *header, intptr_t slide) {
    if (header->magic != MH_MAGIC_64) {
        return; // iOS 16 devices are arm64 only; 32-bit slices do not exist.
    }
    const struct mach_header_64 *header64 = (const struct mach_header_64 *)header;
    uintptr_t cursor = (uintptr_t)header64 + sizeof(struct mach_header_64);

    struct symtab_command *symtab_cmd = NULL;
    struct dysymtab_command *dysymtab_cmd = NULL;
    struct segment_command_64 *linkedit = NULL;

    for (uint32_t i = 0; i < header64->ncmds; i++) {
        struct load_command *command = (struct load_command *)cursor;
        if (command->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *segment = (struct segment_command_64 *)cursor;
            if (strcmp(segment->segname, SEG_LINKEDIT) == 0) {
                linkedit = segment;
            }
        } else if (command->cmd == LC_SYMTAB) {
            symtab_cmd = (struct symtab_command *)cursor;
        } else if (command->cmd == LC_DYSYMTAB) {
            dysymtab_cmd = (struct dysymtab_command *)cursor;
        }
        cursor += command->cmdsize;
    }
    if (symtab_cmd == NULL || dysymtab_cmd == NULL || linkedit == NULL) {
        return;
    }

    uintptr_t linkedit_base = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
    struct nlist_64 *symtab = (struct nlist_64 *)(linkedit_base + symtab_cmd->symoff);
    char *strtab = (char *)(linkedit_base + symtab_cmd->stroff);
    uint32_t *indirect_symtab = (uint32_t *)(linkedit_base + dysymtab_cmd->indirectsymoff);

    cursor = (uintptr_t)header64 + sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < header64->ncmds; i++) {
        struct load_command *command = (struct load_command *)cursor;
        if (command->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *segment = (struct segment_command_64 *)cursor;
            if (strcmp(segment->segname, SEG_DATA) == 0 ||
                strcmp(segment->segname, "__DATA_CONST") == 0 ||
                strcmp(segment->segname, "__AUTH_CONST") == 0 ||
                strcmp(segment->segname, "__AUTH") == 0 ||
                strcmp(segment->segname, "__DATA_DIRTY") == 0) {
                struct section_64 *sections =
                    (struct section_64 *)(cursor + sizeof(struct segment_command_64));
                for (uint32_t j = 0; j < segment->nsects; j++) {
                    struct section_64 *section = &sections[j];
                    uint32_t type = section->flags & SECTION_TYPE;
                    if (type == S_LAZY_SYMBOL_POINTERS || type == S_NON_LAZY_SYMBOL_POINTERS) {
                        fd_rebind_section(section, slide, symtab, strtab, indirect_symtab);
                    }
                }
            }
        }
        cursor += command->cmdsize;
    }
}

// Registers the rebinding for every image already loaded and for every
// image loaded later (dyld calls the callback for those too).
static void fd_rebind_symbols(struct fd_rebinding rebindings[], size_t count) {
    if (count == 0) {
        return;
    }
    size_t new_count = _fd_rebindings_count + count;
    struct fd_rebinding *grown =
        realloc(_fd_rebindings, sizeof(struct fd_rebinding) * new_count);
    if (grown == NULL) {
        return;
    }
    memcpy(grown + _fd_rebindings_count, rebindings, sizeof(struct fd_rebinding) * count);
    _fd_rebindings = grown;
    _fd_rebindings_count = new_count;

    _dyld_register_func_for_add_image(fd_rebind_image);
}

// MARK: - 3. Configuration

static NSString *fd_config_server(void);
static NSString *fd_config_token(void);

static NSString *fd_string_from(const char *environment_name, NSString *defaults_key) {
    const char *value = getenv(environment_name);
    if (value != NULL && value[0] != '\0') {
        return [NSString stringWithUTF8String:value];
    }
    id stored = [[NSUserDefaults standardUserDefaults] objectForKey:defaults_key];
    if ([stored isKindOfClass:[NSString class]] && [(NSString *)stored length] > 0) {
        return (NSString *)stored;
    }
    return nil;
}

static NSString *fd_config_server(void) {
    static NSString *server = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        server = FD_RETAIN(fd_string_from("FREEDECK_SERVER", @"freedeck.server"));
    });
    return server;
}

static NSString *fd_config_token(void) {
    static NSString *token = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        token = FD_RETAIN(fd_string_from("FREEDECK_TOKEN", @"freedeck.token"));
    });
    return token;
}

static NSString *fd_cache_directory(void) {
    static NSString *directory = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *configured = fd_string_from("FREEDECK_CACHE_DIR", @"freedeck.cacheDir");
        if (configured.length == 0) {
            configured = [NSTemporaryDirectory() stringByAppendingPathComponent:@"freedeck-cache"];
        }
        [[NSFileManager defaultManager] createDirectoryAtPath:configured
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:NULL];
        directory = FD_RETAIN(configured);
    });
    return directory;
}

static long long fd_cache_cap_bytes(void) {
    static long long cap = 0;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const char *fromEnv = getenv("FREEDECK_CACHE_CAP");
        if (fromEnv != NULL && fromEnv[0] != '\0') {
            cap = atoll(fromEnv);
        } else {
            NSNumber *stored = [[NSUserDefaults standardUserDefaults] objectForKey:@"freedeck.cacheCapBytes"];
            if ([stored isKindOfClass:[NSNumber class]]) {
                cap = [stored longLongValue];
            }
        }
        if (cap <= 0) {
            cap = 1024LL * 1024LL * 1024LL; // 1 GB, as documented.
        }
    });
    return cap;
}

// MARK: - 4. The LRU cache

// The cache: one file per remote URL in fd_cache_directory(), named by an
// FNV-1a hash of the URL, and an index.json holding, per entry, the file
// name, the file's current length, the byte ranges actually fetched (so
// holes from partial fetches are never served), and the time of last use
// for LRU eviction.

static NSObject *fd_cache_lock(void) {
    static NSObject *lock = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lock = [[NSObject alloc] init];
    });
    return lock;
}

static NSMutableDictionary *fd_cache_index(void) {
    static NSMutableDictionary *index = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        index = [[NSMutableDictionary alloc] init];
        NSString *indexPath = [fd_cache_directory() stringByAppendingPathComponent:@"index.json"];
        NSData *data = [[NSFileManager defaultManager] contentsAtPath:indexPath];
        if (data != nil) {
            id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
            if ([parsed isKindOfClass:[NSDictionary class]]) {
                [index addEntriesFromDictionary:(NSDictionary *)parsed];
            }
        }
    });
    return index;
}

static NSString *fd_cache_index_path(void) {
    return [fd_cache_directory() stringByAppendingPathComponent:@"index.json"];
}

// Saves the index; must be called with the cache lock held. NSData's
// write path is not one of the hooked entry points, so this cannot
// re-enter the hooks.
static void fd_cache_save_index_locked(void) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:fd_cache_index() options:0 error:NULL];
    if (data == nil) {
        return;
    }
    [data writeToFile:fd_cache_index_path() atomically:YES];
}

static NSMutableDictionary *fd_cache_entry_locked(NSString *key) {
    id entry = fd_cache_index()[key];
    return [entry isKindOfClass:[NSDictionary class]] ? (NSMutableDictionary *)entry : nil;
}

// Forward declarations used before their definitions.
static unsigned long long fd_fnv1a64(NSString *string);
static void fd_cache_evict_if_needed_locked(void);

static unsigned long long fd_fnv1a64(NSString *string) {
    NSData *bytes = [string dataUsingEncoding:NSUTF8StringEncoding];
    const uint8_t *cursor = bytes.bytes;
    unsigned long long hash = 1469598103934665603ULL;
    for (NSUInteger i = 0; i < bytes.length; i++) {
        hash ^= cursor[i];
        hash *= 1099511628211ULL;
    }
    return hash;
}

static NSMutableDictionary *fd_cache_ensure_entry_locked(NSString *key) {
    NSMutableDictionary *entry = fd_cache_entry_locked(key);
    if (entry != nil) {
        return entry;
    }
    entry = [NSMutableDictionary dictionaryWithDictionary:@{
        @"file": [NSString stringWithFormat:@"%016llx.cache", fd_fnv1a64(key)],
        @"fileLength": @0,
        @"ranges": [NSMutableArray array],
        @"access": @([[NSDate date] timeIntervalSince1970])
    }];
    fd_cache_index()[key] = entry;
    return entry;
}

static NSString *fd_cache_file_path_locked(NSString *key) {
    NSMutableDictionary *entry = fd_cache_ensure_entry_locked(key);
    return [fd_cache_directory() stringByAppendingPathComponent:entry[@"file"]];
}

// Marks the entry as just used. Must be called with the lock held.
static void fd_cache_touch_locked(NSString *key) {
    NSMutableDictionary *entry = fd_cache_ensure_entry_locked(key);
    entry[@"access"] = @([[NSDate date] timeIntervalSince1970]);
}

// Whether [offset, offset + length) is fully backed by fetched data.
static BOOL fd_cache_covers_locked(NSString *key, long long offset, long long length) {
    NSMutableDictionary *entry = fd_cache_entry_locked(key);
    if (entry == nil || length <= 0) {
        return length <= 0;
    }
    long long wantedEnd = offset + length;
    NSArray *ranges = entry[@"ranges"];
    for (id pair in ranges) {
        NSArray *bounds = (NSArray *)pair;
        if (![bounds isKindOfClass:[NSArray class]] || bounds.count < 2) {
            continue;
        }
        long long start = [bounds[0] longLongValue];
        long long end = [bounds[1] longLongValue];
        if (start <= offset && wantedEnd <= end) {
            return YES;
        }
    }
    return NO;
}

// Adds [start, end] to the entry's coverage, merging overlaps.
static void fd_cache_merge_range_locked(NSString *key, long long start, long long end) {
    NSMutableDictionary *entry = fd_cache_ensure_entry_locked(key);
    NSMutableArray *ranges = entry[@"ranges"];
    if (![ranges isKindOfClass:[NSMutableArray class]]) {
        ranges = [NSMutableArray arrayWithArray:[ranges isKindOfClass:[NSArray class]] ? ranges : @[]];
        entry[@"ranges"] = ranges;
    }
    long long mergedStart = start;
    long long mergedEnd = end;
    NSMutableArray *kept = [NSMutableArray array];
    for (id pair in ranges) {
        NSArray *bounds = (NSArray *)pair;
        if (![bounds isKindOfClass:[NSArray class]] || bounds.count < 2) {
            continue;
        }
        long long s = [bounds[0] longLongValue];
        long long e = [bounds[1] longLongValue];
        if (e + 1 < mergedStart || s > mergedEnd + 1) {
            [kept addObject:bounds];
        } else {
            if (s < mergedStart) mergedStart = s;
            if (e > mergedEnd) mergedEnd = e;
        }
    }
    [kept addObject:@[@(mergedStart), @(mergedEnd)]];
    [kept sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
        return [a[0] compare:b[0]];
    }];
    entry[@"ranges"] = kept;
}

// Evicts least-recently-used entries until the cache fits under its cap.
static void fd_cache_evict_if_needed_locked(void) {
    long long cap = fd_cache_cap_bytes();
    long long total = 0;
    NSMutableDictionary *index = fd_cache_index();
    for (id key in index) {
        NSDictionary *entry = index[key];
        total += [entry[@"fileLength"] longLongValue];
    }
    while (total > cap && index.count > 0) {
        NSString *oldestKey = nil;
        NSTimeInterval oldest = DBL_MAX;
        for (id key in index) {
            NSDictionary *entry = index[key];
            NSTimeInterval access = [entry[@"access"] doubleValue];
            if (access < oldest) {
                oldest = access;
                oldestKey = key;
            }
        }
        if (oldestKey == nil) {
            break;
        }
        NSString *path = fd_cache_file_path_locked(oldestKey);
        NSDictionary *entry = index[oldestKey];
        total -= [entry[@"fileLength"] longLongValue];
        unlink(path.fileSystemRepresentation);
        [index removeObjectForKey:oldestKey];
    }
    fd_cache_save_index_locked();
}

// Writes fetched bytes into the cache file and records the coverage.
static void fd_cache_store(NSString *key, long long offset, NSData *data, long long fileLengthHint) {
    if (data.length == 0) {
        return;
    }
    @synchronized (fd_cache_lock()) {
        NSString *path = fd_cache_file_path_locked(key);
        int descriptor = open(path.fileSystemRepresentation, O_RDWR | O_CREAT, 0644);
        if (descriptor == -1) {
            return;
        }
        long long end = offset + (long long)data.length;
        long long needed = end;
        if (fileLengthHint > needed) {
            needed = fileLengthHint;
        }
        ftruncate(descriptor, needed);
        pwrite(descriptor, data.bytes, data.length, (off_t)offset);
        close(descriptor);

        NSMutableDictionary *entry = fd_cache_ensure_entry_locked(key);
        entry[@"fileLength"] = @(MAX([entry[@"fileLength"] longLongValue], needed));
        fd_cache_merge_range_locked(key, offset, end - 1);
        fd_cache_touch_locked(key);
        fd_cache_evict_if_needed_locked();
    }
}

// MARK: - 5. Remote-file detection

// A remote file is one under .../Documents/FDRemote/ (the marker directory
// the FreeDeck server fills), or one with a `<path>.fdmeta` sidecar holding
// {"url": "...", "size": 123}. Paths ending in .fdmeta themselves are
// never remote: that keeps the sidecar read below out of the hooks.

static NSString *fd_remote_marker = @"/Documents/FDRemote/";

// Reads a file with the real fopen — never with anything this file hooks.
static NSData *fd_read_file_unhooked(NSString *path) {
    static FILE *(*real_fopen)(const char *, const char *) = NULL;
    if (real_fopen == NULL) {
        real_fopen = dlsym(RTLD_DEFAULT, "fopen");
    }
    if (real_fopen == NULL) {
        return nil;
    }
    FILE *file = real_fopen(path.fileSystemRepresentation, "rb");
    if (file == NULL) {
        return nil;
    }
    NSMutableData *data = [NSMutableData data];
    uint8_t buffer[8192];
    size_t got;
    while ((got = fread(buffer, 1, sizeof(buffer), file)) > 0) {
        [data appendBytes:buffer length:got];
    }
    fclose(file);
    return data;
}

// Returns @{ @"url": NSString, @"size": NSNumber } for a remote path, or
// nil for an ordinary local file. Size is -1 when not yet known.
static NSDictionary *fd_remote_info(NSString *path) {
    if (path.length == 0 || [path hasSuffix:@".fdmeta"]) {
        return nil;
    }

    NSData *sidecar = fd_read_file_unhooked([path stringByAppendingString:@".fdmeta"]);
    if (sidecar != nil) {
        id parsed = [NSJSONSerialization JSONObjectWithData:sidecar options:0 error:NULL];
        if ([parsed isKindOfClass:[NSDictionary class]]) {
            NSString *url = ((NSDictionary *)parsed)[@"url"];
            if ([url isKindOfClass:[NSString class]] && url.length > 0) {
                NSNumber *size = ((NSDictionary *)parsed)[@"size"];
                return @{
                    @"url": url,
                    @"size": ([size isKindOfClass:[NSNumber class]] ? size : @(-1))
                };
            }
        }
    }

    NSRange marker = [path rangeOfString:fd_remote_marker];
    if (marker.location != NSNotFound && fd_config_server().length > 0) {
        NSString *relative = [path substringFromIndex:NSMaxRange(marker)];
        NSString *escaped = [relative stringByAddingPercentEncodingWithAllowedCharacters:
                             [NSCharacterSet URLPathAllowedCharacterSet]];
        NSString *url = [NSString stringWithFormat:@"%@/api/files/%@",
                         [fd_config_server() stringByTrimmingCharactersInSet:
                          [NSCharacterSet characterSetWithCharactersInString:@"/"]],
                         escaped];
        return @{@"url": url, @"size": @(-1)};
    }
    return nil;
}

static BOOL fd_is_remote_path(NSString *path) {
    return fd_remote_info(path) != nil;
}

// MARK: - 6. HTTP Range fetching

// One Range GET, bridged to synchronous with a semaphore (the completion
// runs on NSURLSession's own queue, so this cannot deadlock). Asks for
// [start, endInclusive]; outTotal receives the file's total size when the
// server reports one (Content-Range on 206, Content-Length on 200).
static NSData *fd_http_fetch(NSString *urlString, long long start, long long endInclusive,
                             long long *outTotal) {
    NSURL *url = [NSURL URLWithString:urlString];
    if (url == nil) {
        return nil;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 60;
    [request setValue:[NSString stringWithFormat:@"bytes=%lld-%lld", start, endInclusive]
   forHTTPHeaderField:@"Range"];
    NSString *token = fd_config_token();
    if (token.length > 0) {
        [request setValue:[NSString stringWithFormat:@"Bearer %@", token]
       forHTTPHeaderField:@"Authorization"];
    }

    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSData *result = nil;
    __block NSHTTPURLResponse *http = nil;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithRequest:request
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
              (void)error; // A nil body signals failure below.
              result = FD_RETAIN(data);
              if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
                  http = FD_RETAIN((NSHTTPURLResponse *)response);
              }
              dispatch_semaphore_signal(semaphore);
          }];
    [task resume];

    long timedOut = dispatch_semaphore_wait(
        semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60 * NSEC_PER_SEC)));
    if (timedOut != 0) {
        [task cancel];
        FD_RELEASE(result);
        FD_RELEASE(http);
        return nil;
    }

    NSInteger status = http.statusCode;
    if (outTotal != NULL) {
        NSString *contentRange = [http valueForHTTPHeaderField:@"Content-Range"];
        NSRange slash = [contentRange rangeOfString:@"/"];
        if (slash.location != NSNotFound) {
            long long total = [[contentRange substringFromIndex:NSMaxRange(slash)] longLongValue];
            if (total > 0) {
                *outTotal = total;
            }
        } else if (status == 200 && http.expectedContentLength > 0) {
            *outTotal = http.expectedContentLength;
        }
    }

    NSData *answer = FD_AUTORELEASE(result);
    if (!((status == 200 || status == 206) && answer != nil)) {
        answer = nil;
    }
    FD_RELEASE(http);
    return answer;
}

// Ensures [offset, offset + length) of the remote file is cached, fetching
// in 4 MB chunks and skipping what is already covered. `full` widens the
// span to the whole file, which fopen and NSData need to serve arbitrary
// reads. Returns the cache file's path, or nil on failure.
static NSString *fd_cache_ensure(NSString *path, long long offset, long long length, BOOL full) {
    NSDictionary *info = fd_remote_info(path);
    if (info == nil) {
        return nil;
    }
    NSString *key = info[@"url"];
    long long total = [info[@"size"] longLongValue];

    if (total <= 0) {
        // A size learned on an earlier fetch is kept in the index; use it
        // before asking the server again.
        @synchronized (fd_cache_lock()) {
            NSDictionary *entry = fd_cache_entry_locked(key);
            NSNumber *known = entry[@"size"];
            if ([known isKindOfClass:[NSNumber class]] && [known longLongValue] > 0) {
                total = [known longLongValue];
            }
        }
    }

    if (total <= 0) {
        // Size not known yet: ask for the first byte and read the total out
        // of the answer. A server that ignores Range answers with the whole
        // body, which is just as good — it lands in the cache.
        long long reported = -1;
        NSData *probe = fd_http_fetch(key, 0, 0, &reported);
        if (reported > 0) {
            total = reported;
        }
        if (probe != nil) {
            if (total <= 0) {
                total = (long long)probe.length;
            }
            fd_cache_store(key, 0, probe, total);
        }
        if (total <= 0) {
            return nil;
        }
    }

    @synchronized (fd_cache_lock()) {
        NSMutableDictionary *entry = fd_cache_ensure_entry_locked(key);
        entry[@"size"] = @(total);
        fd_cache_touch_locked(key);
    }

    long long spanStart = full ? 0 : offset;
    long long spanLength = full ? total : length;
    if (spanLength <= 0) {
        return nil;
    }
    if (spanStart + spanLength > total) {
        spanLength = total - spanStart;
    }
    if (spanLength <= 0) {
        return nil;
    }

    const long long chunk = 4LL * 1024 * 1024;
    long long cursor = spanStart;
    while (cursor < spanStart + spanLength) {
        long long want = MIN(chunk, spanStart + spanLength - cursor);
        BOOL covered = NO;
        @synchronized (fd_cache_lock()) {
            covered = fd_cache_covers_locked(key, cursor, want);
        }
        if (!covered) {
            long long endInclusive = cursor + want - 1;
            long long reported = -1;
            NSData *data = fd_http_fetch(key, cursor, endInclusive, &reported);
            if (reported > 0 && reported > total) {
                total = reported;
            }
            if (data == nil) {
                return nil;
            }
            // A 200 answer carries the whole file regardless of the Range
            // asked for; store it from the start.
            long long storeAt = ((long long)data.length > want && cursor > 0) ? 0 : cursor;
            fd_cache_store(key, storeAt, data, total);
        }
        cursor += want;
    }

    @synchronized (fd_cache_lock()) {
        fd_cache_touch_locked(key);
        fd_cache_save_index_locked();
        return fd_cache_file_path_locked(key);
    }
}

// MARK: - 7. The hooks

static FILE *(*fd_real_fopen)(const char *, const char *) = NULL;
static void *(*fd_real_mmap)(void *, size_t, int, int, int, off_t) = NULL;

static void fd_ensure_originals(void) {
    if (fd_real_fopen == NULL) {
        fd_real_fopen = dlsym(RTLD_DEFAULT, "fopen");
    }
    if (fd_real_mmap == NULL) {
        fd_real_mmap = dlsym(RTLD_DEFAULT, "mmap");
    }
}

// Only modes that cannot change the file are redirected: a guest writing a
// remote path gets the ordinary local behavior.
static BOOL fd_mode_is_readonly(const char *mode) {
    return mode != NULL && strchr(mode, 'w') == NULL && strchr(mode, 'a') == NULL &&
           strchr(mode, '+') == NULL;
}

static FILE *fd_fopen(const char *path, const char *mode) {
    fd_ensure_originals();
    if (path != NULL && fd_mode_is_readonly(mode)) {
        NSString *string = [NSString stringWithUTF8String:path];
        if (string != nil && fd_is_remote_path(string)) {
            NSString *cached = fd_cache_ensure(string, 0, 0, YES);
            if (cached != nil) {
                // The cache file is an ordinary local file, so the caller's
                // fread/fseek/munmap all keep working.
                return fd_real_fopen(cached.fileSystemRepresentation, mode);
            }
            // Fetch failed: fall through, which fails the open for a marker
            // path and behaves normally for everything else.
        }
    }
    return fd_real_fopen(path, mode);
}

static void *fd_mmap(void *addr, size_t len, int prot, int flags, int fd, off_t offset) {
    fd_ensure_originals();
    if (fd >= 0 && len > 0) {
        char pathBuffer[PATH_MAX];
        if (fcntl(fd, F_GETPATH, pathBuffer) != -1) {
            NSString *string = [NSString stringWithUTF8String:pathBuffer];
            if (string != nil && fd_is_remote_path(string)) {
                NSString *cached = fd_cache_ensure(string, (long long)offset, (long long)len, NO);
                if (cached != nil) {
                    // Map the cache file instead. The mapping is a real one,
                    // so the caller's munmap works unchanged; the fetched
                    // range covers exactly what is mapped.
                    int cacheDescriptor = open(cached.fileSystemRepresentation, O_RDONLY);
                    if (cacheDescriptor != -1) {
                        void *mapped = fd_real_mmap(addr, len, prot, flags,
                                                    cacheDescriptor, offset);
                        close(cacheDescriptor);
                        return mapped;
                    }
                }
            }
        }
    }
    return fd_real_mmap(addr, len, prot, flags, fd, offset);
}

@interface NSData (FreeDeckRemoteStorage)
+ (NSData *)fd_dataWithContentsOfFile:(NSString *)path;
+ (NSData *)fd_dataWithContentsOfURL:(NSURL *)url
                             options:(NSDataReadingOptions)options
                               error:(NSError **)error;
@end

@implementation NSData (FreeDeckRemoteStorage)

// After the exchange below, a call to fd_... runs the original
// implementation — which is how these forward without recursing.
+ (NSData *)fd_dataWithContentsOfFile:(NSString *)path {
    if (path != nil && fd_is_remote_path(path)) {
        NSString *cached = fd_cache_ensure(path, 0, 0, YES);
        if (cached != nil) {
            return [self fd_dataWithContentsOfFile:cached];
        }
    }
    return [self fd_dataWithContentsOfFile:path];
}

+ (NSData *)fd_dataWithContentsOfURL:(NSURL *)url
                             options:(NSDataReadingOptions)options
                               error:(NSError **)error {
    if (url != nil && url.isFileURL && fd_is_remote_path(url.path)) {
        NSString *cached = fd_cache_ensure(url.path, 0, 0, YES);
        if (cached != nil) {
            return [self fd_dataWithContentsOfURL:[NSURL fileURLWithPath:cached]
                                          options:options
                                            error:error];
        }
    }
    return [self fd_dataWithContentsOfURL:url options:options error:error];
}

@end

@interface NSFileManager (FreeDeckRemoteStorage)
- (BOOL)fd_fileExistsAtPath:(NSString *)path;
@end

@implementation NSFileManager (FreeDeckRemoteStorage)

// A remote file "exists" when the server says so, which a synchronous call
// cannot cheaply check; the marker directory and the sidecar are the
// contract, so their presence is the answer.
- (BOOL)fd_fileExistsAtPath:(NSString *)path {
    if (path != nil && fd_is_remote_path(path)) {
        return YES;
    }
    return [self fd_fileExistsAtPath:path];
}

@end

static void fd_swizzle_instance_method(Class cls, SEL original, SEL replacement) {
    Method originalMethod = class_getInstanceMethod(cls, original);
    Method replacementMethod = class_getInstanceMethod(cls, replacement);
    if (originalMethod == NULL || replacementMethod == NULL) {
        return;
    }
    method_exchangeImplementations(originalMethod, replacementMethod);
}

static void fd_swizzle_class_method(Class cls, SEL original, SEL replacement) {
    fd_swizzle_instance_method(object_getClass(cls), original, replacement);
}

// MARK: - 8. Control surface and installation

int fd_cache_preload(const char *path, long long offset, long long length) {
    if (path == NULL) {
        return -1;
    }
    @autoreleasepool {
        NSString *string = [NSString stringWithUTF8String:path];
        if (string == nil || fd_remote_info(string) == nil) {
            return -1;
        }
        NSString *cached = fd_cache_ensure(string, offset, length, NO);
        return cached != nil ? 0 : -2;
    }
}

void fd_cache_evict_all(void) {
    @autoreleasepool {
        @synchronized (fd_cache_lock()) {
            NSMutableDictionary *index = fd_cache_index();
            for (id key in index) {
                NSString *path = fd_cache_file_path_locked((NSString *)key);
                unlink(path.fileSystemRepresentation);
            }
            [index removeAllObjects];
            fd_cache_save_index_locked();
        }
    }
}

long long fd_cache_size_bytes(void) {
    @autoreleasepool {
        @synchronized (fd_cache_lock()) {
            long long total = 0;
            NSMutableDictionary *index = fd_cache_index();
            for (id key in index) {
                NSDictionary *entry = index[key];
                total += [entry[@"fileLength"] longLongValue];
            }
            return total;
        }
    }
}

void fd_storage_hook_install(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        @autoreleasepool {
            fd_ensure_originals();

            struct fd_rebinding rebindings[] = {
                {"fopen", (void *)fd_fopen, NULL},
                {"fopen$DARWIN_EXTSN", (void *)fd_fopen, NULL},
                {"mmap", (void *)fd_mmap, NULL},
            };
            fd_rebind_symbols(rebindings, sizeof(rebindings) / sizeof(rebindings[0]));

            fd_swizzle_class_method([NSData class],
                                    @selector(dataWithContentsOfFile:),
                                    @selector(fd_dataWithContentsOfFile:));
            fd_swizzle_class_method([NSData class],
                                    @selector(dataWithContentsOfURL:options:error:),
                                    @selector(fd_dataWithContentsOfURL:options:error:));
            fd_swizzle_instance_method([NSFileManager class],
                                       @selector(fileExistsAtPath:),
                                       @selector(fd_fileExistsAtPath:));

            // Load the configuration and the index now, so the first hooked
            // call cannot be the one to race their initialization.
            fd_config_server();
            fd_config_token();
            fd_cache_directory();
            fd_cache_cap_bytes();
            @synchronized (fd_cache_lock()) {
                fd_cache_index();
            }
        }
    });
}

__attribute__((constructor)) static void fd_storage_hook_constructor(void) {
    fd_storage_hook_install();
}
