#import <objc/runtime.h>

#include <errno.h>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>

static const uint64_t STWO_ZIG_ARCHIVE_ENTRY_LIMIT = 128u;
static const uint64_t STWO_ZIG_ARCHIVE_BYTE_LIMIT = 512u * 1024u * 1024u;
static const uint64_t STWO_ZIG_ARCHIVE_PER_ENTRY_BYTE_LIMIT = 128u * 1024u * 1024u;
static const uint64_t STWO_ZIG_ARCHIVE_QUARANTINE_ENTRY_LIMIT = 8u;
static const uint64_t STWO_ZIG_ARCHIVE_QUARANTINE_BYTE_LIMIT = 64u * 1024u * 1024u;
static const CFTimeInterval STWO_ZIG_ARCHIVE_LOCK_TIMEOUT_SECONDS = 5.0;

@interface StwoZigArchiveStoreState : NSObject
@property(nonatomic, copy) NSString *root;
@property(nonatomic, copy) NSString *archives;
@property(nonatomic, copy) NSString *quarantine;
@property(nonatomic) uint64_t diskHits;
@property(nonatomic) uint64_t diskMisses;
@property(nonatomic) uint64_t diskEvictions;
@property(nonatomic) uint64_t diskRebuilds;
@property(nonatomic) uint64_t diskRejections;
@property(nonatomic) uint64_t diskQuarantines;
@property(nonatomic) uint64_t lockAcquisitions;
@property(nonatomic) uint64_t lockContentions;
@property(nonatomic) uint64_t lockTimeouts;
@property(nonatomic) uint64_t publicationSuccesses;
@property(nonatomic) uint64_t publicationFailures;
@property(nonatomic) uint64_t bytesPublished;
@property(nonatomic) uint64_t bytesEvicted;
@property(nonatomic) uint64_t persistenceBypasses;
@property(nonatomic) double lockWaitSeconds;
@property(nonatomic) uint64_t diskEntries;
@property(nonatomic) uint64_t diskBytes;
@property(nonatomic) uint64_t quarantineEntries;
@property(nonatomic) uint64_t quarantineBytes;
@end
@implementation StwoZigArchiveStoreState
@end

@interface StwoZigArchiveDiskEntry : NSObject
@property(nonatomic, copy) NSString *path;
@property(nonatomic) uint64_t bytes;
@property(nonatomic) int64_t seconds;
@property(nonatomic) long nanoseconds;
@end
@implementation StwoZigArchiveDiskEntry
@end

static const void *STWO_ZIG_ARCHIVE_STORE_STATE_KEY = &STWO_ZIG_ARCHIVE_STORE_STATE_KEY;

static NSString *eval_archive_store_root(void) {
    const char *override = getenv("STWO_ZIG_METAL_CACHE_DIR");
    if (override != NULL) {
        if (override[0] != '/') return nil;
        NSString *path = [NSString stringWithUTF8String:override];
        return path.length > 0u ? [path stringByStandardizingPath] : nil;
    }
    NSURL *cache = [[[NSFileManager defaultManager]
        URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask] firstObject];
    if (cache == nil) cache = [NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES];
    return [[[[cache URLByAppendingPathComponent:@"dev.stwo-zig" isDirectory:YES]
        URLByAppendingPathComponent:@"metal" isDirectory:YES]
        URLByAppendingPathComponent:@"eval-archives-v3" isDirectory:YES] path];
}

static StwoZigArchiveStoreState *eval_archive_store_state(StwoZigMetalRuntime *runtime) {
    StwoZigArchiveStoreState *state = objc_getAssociatedObject(runtime, STWO_ZIG_ARCHIVE_STORE_STATE_KEY);
    if (state == nil) {
        state = [StwoZigArchiveStoreState new];
        state.root = eval_archive_store_root();
        state.archives = [state.root stringByAppendingPathComponent:@"archives"];
        state.quarantine = [state.root stringByAppendingPathComponent:@"quarantine"];
        objc_setAssociatedObject(runtime, STWO_ZIG_ARCHIVE_STORE_STATE_KEY, state,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return state;
}

static void eval_archive_posix_error(NSError **error, NSString *operation) {
    if (error == NULL) return;
    *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ failed: %s", operation, strerror(errno)]
    }];
}

static bool eval_archive_store_directories(StwoZigArchiveStoreState *state, NSError **error) {
    if (state.root == nil || state.archives == nil || state.quarantine == nil) {
        if (error != NULL) *error = [NSError errorWithDomain:@"StwoZigMetalRuntime" code:2
            userInfo:@{NSLocalizedDescriptionKey: @"Invalid STWO_ZIG_METAL_CACHE_DIR"}];
        return false;
    }
    NSFileManager *manager = [NSFileManager defaultManager];
    NSDictionary *attributes = @{NSFilePosixPermissions: @0700};
    if (![manager createDirectoryAtPath:state.archives withIntermediateDirectories:YES
        attributes:attributes error:error]) return false;
    if (![manager createDirectoryAtPath:state.quarantine withIntermediateDirectories:YES
        attributes:attributes error:error]) return false;
    return true;
}

static int eval_archive_store_lock(StwoZigArchiveStoreState *state, NSError **error) {
    if (!eval_archive_store_directories(state, error)) return -1;
    NSString *path = [state.root stringByAppendingPathComponent:@".store.lock"];
    int descriptor = open(path.fileSystemRepresentation, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (descriptor < 0) { eval_archive_posix_error(error, @"Opening Metal archive lock"); return -1; }
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    bool contended = false;
    while (flock(descriptor, LOCK_EX | LOCK_NB) != 0) {
        if (errno != EWOULDBLOCK && errno != EAGAIN) {
            state.lockWaitSeconds += CFAbsoluteTimeGetCurrent() - start;
            eval_archive_posix_error(error, @"Locking Metal archive store");
            close(descriptor);
            return -1;
        }
        if (!contended) {
            contended = true;
            state.lockContentions += 1u;
        }
        if (CFAbsoluteTimeGetCurrent() - start >= STWO_ZIG_ARCHIVE_LOCK_TIMEOUT_SECONDS) {
            state.lockTimeouts += 1u;
            state.lockWaitSeconds += CFAbsoluteTimeGetCurrent() - start;
            close(descriptor);
            return -1;
        }
        usleep(1000u);
    }
    state.lockAcquisitions += 1u;
    state.lockWaitSeconds += CFAbsoluteTimeGetCurrent() - start;
    return descriptor;
}

static void eval_archive_store_unlock(int descriptor) {
    if (descriptor < 0) return;
    flock(descriptor, LOCK_UN);
    close(descriptor);
}

static bool eval_archive_regular_file(NSString *path, struct stat *status) {
    if (lstat(path.fileSystemRepresentation, status) != 0) return false;
    return S_ISREG(status->st_mode);
}

static NSMutableArray<StwoZigArchiveDiskEntry *> *eval_archive_entries(
    NSString *directory, bool quarantine
) {
    NSMutableArray<StwoZigArchiveDiskEntry *> *entries = [NSMutableArray array];
    NSArray<NSString *> *names = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:directory error:nil] ?: @[];
    for (NSString *name in names) {
        bool accepted = quarantine ? [name hasSuffix:@".bad"] :
            ([name hasPrefix:@"stwo-zig-eval-cache-v2-"] && [name hasSuffix:@".binarchive"]);
        if (!accepted) continue;
        NSString *path = [directory stringByAppendingPathComponent:name];
        struct stat status;
        if (!eval_archive_regular_file(path, &status)) continue;
        StwoZigArchiveDiskEntry *entry = [StwoZigArchiveDiskEntry new];
        entry.path = path;
        entry.bytes = (uint64_t)MAX(status.st_size, 0);
        entry.seconds = status.st_mtimespec.tv_sec;
        entry.nanoseconds = status.st_mtimespec.tv_nsec;
        [entries addObject:entry];
    }
    [entries sortUsingComparator:^NSComparisonResult(
        StwoZigArchiveDiskEntry *left, StwoZigArchiveDiskEntry *right
    ) {
        if (left.seconds != right.seconds) return left.seconds < right.seconds ? NSOrderedAscending : NSOrderedDescending;
        if (left.nanoseconds != right.nanoseconds) return left.nanoseconds < right.nanoseconds ? NSOrderedAscending : NSOrderedDescending;
        return [left.path.lastPathComponent compare:right.path.lastPathComponent];
    }];
    return entries;
}

static void eval_archive_prune_directory(
    StwoZigArchiveStoreState *state, NSString *directory, bool quarantine,
    uint64_t entryLimit, uint64_t byteLimit, NSString *protectedPath
) {
    NSMutableArray<StwoZigArchiveDiskEntry *> *entries = eval_archive_entries(directory, quarantine);
    uint64_t bytes = 0u;
    for (StwoZigArchiveDiskEntry *entry in entries) bytes += entry.bytes;
    while ((uint64_t)entries.count > entryLimit || bytes > byteLimit) {
        NSUInteger victim = 0u;
        while (victim < entries.count && [entries[victim].path isEqualToString:protectedPath]) victim += 1u;
        if (victim == entries.count) {
            state.diskRejections += 1u;
            state.persistenceBypasses += 1u;
            break;
        }
        StwoZigArchiveDiskEntry *entry = entries[victim];
        if ([[NSFileManager defaultManager] removeItemAtPath:entry.path error:nil]) {
            bytes -= entry.bytes;
            state.diskEvictions += 1u;
            state.bytesEvicted += entry.bytes;
            [entries removeObjectAtIndex:victim];
        } else {
            state.diskRejections += 1u;
            state.persistenceBypasses += 1u;
            break;
        }
    }
    if (quarantine) {
        state.quarantineEntries = (uint64_t)entries.count;
        state.quarantineBytes = bytes;
    } else {
        state.diskEntries = (uint64_t)entries.count;
        state.diskBytes = bytes;
    }
}

static void eval_archive_store_maintenance(
    StwoZigArchiveStoreState *state, NSString *protectedPath
) {
    NSArray<NSString *> *names = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:state.archives error:nil] ?: @[];
    for (NSString *name in names) {
        if ([name hasPrefix:@".stwo-zig-"] && [name hasSuffix:@".binarchive"]) {
            NSString *path = [state.archives stringByAppendingPathComponent:name];
            struct stat status;
            uint64_t bytes = eval_archive_regular_file(path, &status) ?
                (uint64_t)MAX(status.st_size, 0) : 0u;
            if ([[NSFileManager defaultManager] removeItemAtPath:path error:nil]) {
                state.diskEvictions += 1u;
                state.bytesEvicted += bytes;
            } else {
                state.diskRejections += 1u;
                state.persistenceBypasses += 1u;
            }
        }
    }
    eval_archive_prune_directory(state, state.archives, false,
        STWO_ZIG_ARCHIVE_ENTRY_LIMIT, STWO_ZIG_ARCHIVE_BYTE_LIMIT, protectedPath);
    eval_archive_prune_directory(state, state.quarantine, true,
        STWO_ZIG_ARCHIVE_QUARANTINE_ENTRY_LIMIT, STWO_ZIG_ARCHIVE_QUARANTINE_BYTE_LIMIT, nil);
}

static NSString *eval_archive_path(StwoZigArchiveStoreState *state, StwoZigEvalArchiveKey *key) {
    if (key.canonicalSha256.length != CC_SHA256_DIGEST_LENGTH * 2u) return nil;
    NSString *name = [NSString stringWithFormat:@"stwo-zig-eval-cache-v2-%@.binarchive",
        key.canonicalSha256];
    return [state.archives stringByAppendingPathComponent:name];
}

static id<MTLBinaryArchive> eval_archive_new(
    id<MTLDevice> device, NSString *path, bool load, NSError **error
) {
    MTLBinaryArchiveDescriptor *descriptor = [MTLBinaryArchiveDescriptor new];
    if (load) descriptor.url = [NSURL fileURLWithPath:path];
    return [device newBinaryArchiveWithDescriptor:descriptor error:error];
}

static bool eval_archive_quarantine_locked(
    StwoZigArchiveStoreState *state, NSString *path
) {
    NSString *name = [NSString stringWithFormat:@"%@.%@.bad",
        path.lastPathComponent, NSUUID.UUID.UUIDString];
    NSString *destination = [state.quarantine stringByAppendingPathComponent:name];
    if (rename(path.fileSystemRepresentation, destination.fileSystemRepresentation) != 0) return false;
    state.diskQuarantines += 1u;
    return true;
}

static void eval_archive_store_prepare_library(
    StwoZigMetalRuntime *runtime, StwoZigEvalLibrary *library
) {
    @synchronized(runtime) {
        StwoZigArchiveStoreState *state = eval_archive_store_state(runtime);
        NSString *archivePath = eval_archive_path(state, library.archiveKey);
        library.archiveURL = archivePath == nil ? nil : [NSURL fileURLWithPath:archivePath];
        NSError *error = nil;
        int lock = eval_archive_store_lock(state, &error);
        if (lock < 0) {
            state.diskMisses += 1u; state.diskRejections += 1u; state.persistenceBypasses += 1u;
            library.archive = nil; library.archiveLoaded = false; library.archiveDirty = false;
            return;
        }
        @try {
            eval_archive_store_maintenance(state, nil);
            NSString *path = library.archiveURL.path;
            struct stat status;
            bool exists = lstat(path.fileSystemRepresentation, &status) == 0;
            bool loadable = exists && S_ISREG(status.st_mode) &&
                (uint64_t)MAX(status.st_size, 0) <= STWO_ZIG_ARCHIVE_PER_ENTRY_BYTE_LIMIT;
            id<MTLBinaryArchive> archive = loadable ? eval_archive_new(runtime.device, path, true, &error) : nil;
            if (archive != nil) {
                state.diskHits += 1u;
                library.archive = archive;
                library.archiveLoaded = true;
                [[NSFileManager defaultManager] setAttributes:@{NSFileModificationDate: NSDate.date}
                    ofItemAtPath:path error:nil];
            } else {
                state.diskMisses += 1u;
                if (exists) {
                    state.diskRebuilds += 1u;
                    if (!eval_archive_quarantine_locked(state, path))
                        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
                }
                error = nil;
                library.archive = eval_archive_new(runtime.device, path, false, &error);
                library.archiveLoaded = false;
                if (library.archive == nil) {
                    state.diskRejections += 1u;
                    state.persistenceBypasses += 1u;
                }
            }
            library.archiveDirty = false;
            eval_archive_store_maintenance(state, nil);
        } @finally {
            eval_archive_store_unlock(lock);
        }
    }
}

static bool eval_archive_atomic_serialize_locked(
    StwoZigArchiveStoreState *state, id<MTLBinaryArchive> archive, NSString *target,
    NSError **error, uint64_t *publishedBytes
) {
    NSString *temporaryName = [NSString stringWithFormat:@".stwo-zig-%@.binarchive", NSUUID.UUID.UUIDString];
    NSString *temporary = [state.archives stringByAppendingPathComponent:temporaryName];
    NSURL *temporaryURL = [NSURL fileURLWithPath:temporary];
    if (![archive serializeToURL:temporaryURL error:error]) return false;
    struct stat status;
    if (!eval_archive_regular_file(temporary, &status)) {
        [[NSFileManager defaultManager] removeItemAtPath:temporary error:nil];
        return false;
    }
    uint64_t bytes = (uint64_t)MAX(status.st_size, 0);
    if (bytes > STWO_ZIG_ARCHIVE_PER_ENTRY_BYTE_LIMIT || bytes > STWO_ZIG_ARCHIVE_BYTE_LIMIT) {
        [[NSFileManager defaultManager] removeItemAtPath:temporary error:nil];
        state.diskRejections += 1u;
        return false;
    }
    int file = open(temporary.fileSystemRepresentation, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (file < 0 || fsync(file) != 0) {
        if (file >= 0) close(file);
        [[NSFileManager defaultManager] removeItemAtPath:temporary error:nil];
        return false;
    }
    close(file);
    if (rename(temporary.fileSystemRepresentation, target.fileSystemRepresentation) != 0) {
        eval_archive_posix_error(error, @"Publishing Metal binary archive");
        [[NSFileManager defaultManager] removeItemAtPath:temporary error:nil];
        return false;
    }
    chmod(target.fileSystemRepresentation, 0600);
    int directory = open(state.archives.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    if (directory < 0 || fsync(directory) != 0) {
        if (directory >= 0) close(directory);
        eval_archive_posix_error(error, @"Syncing Metal archive directory");
        return false;
    }
    close(directory);
    if (publishedBytes != NULL) *publishedBytes = bytes;
    return true;
}

static bool eval_archive_store_publish_pipeline(
    StwoZigMetalRuntime *runtime, StwoZigEvalLibrary *library,
    MTLComputePipelineDescriptor *descriptor
) {
    @synchronized(runtime) {
        StwoZigArchiveStoreState *state = eval_archive_store_state(runtime);
        NSError *error = nil;
        int lock = eval_archive_store_lock(state, &error);
        if (lock < 0) {
            state.diskRejections += 1u; state.persistenceBypasses += 1u;
            return false;
        }
        bool published = false;
        @try {
            NSString *path = eval_archive_path(state, library.archiveKey);
            eval_archive_store_maintenance(state, path);
            struct stat status;
            bool exists = eval_archive_regular_file(path, &status) &&
                (uint64_t)MAX(status.st_size, 0) <= STWO_ZIG_ARCHIVE_PER_ENTRY_BYTE_LIMIT;
            id<MTLBinaryArchive> latest = exists ? eval_archive_new(runtime.device, path, true, &error) : nil;
            if (latest == nil && lstat(path.fileSystemRepresentation, &status) == 0) {
                state.diskRebuilds += 1u;
                if (!eval_archive_quarantine_locked(state, path))
                    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
            }
            if (latest == nil) latest = library.archive ?: eval_archive_new(runtime.device, path, false, &error);
            if (latest == nil) {
                state.diskRejections += 1u; state.persistenceBypasses += 1u;
                return false;
            }
            descriptor.binaryArchives = @[latest];
            if (![latest addComputePipelineFunctionsWithDescriptor:descriptor error:&error]) {
                state.diskRejections += 1u; state.persistenceBypasses += 1u;
                library.archive = latest; library.archiveLoaded = true; library.archiveDirty = false;
                return false;
            }
            runtime.evalArchivePopulations += 1u;
            uint64_t bytes = 0u;
            if (eval_archive_atomic_serialize_locked(state, latest, path, &error, &bytes)) {
                state.publicationSuccesses += 1u;
                state.bytesPublished += bytes;
                runtime.evalArchiveSerializations += 1u;
                published = true;
            } else {
                state.publicationFailures += 1u;
                state.persistenceBypasses += 1u;
            }
            library.archive = latest;
            library.archiveLoaded = true;
            library.archiveDirty = false;
            eval_archive_store_maintenance(state, published ? path : nil);
        } @finally {
            eval_archive_store_unlock(lock);
        }
        return published;
    }
}

static bool eval_archive_store_flush_library(
    StwoZigEvalLibrary *library, NSError **error, bool *didSerialize
) {
    if (didSerialize != NULL) *didSerialize = false;
    @synchronized(library) {
        if (!library.archiveDirty) return true;
        StwoZigMetalRuntime *runtime = library.runtimeOwner;
        if (runtime == nil) return false;
        StwoZigArchiveStoreState *state = eval_archive_store_state(runtime);
        state.persistenceBypasses += 1u;
        library.archiveDirty = false;
        return true;
    }
}

static void stwo_zig_metal_archive_store_stats(
    StwoZigMetalRuntime *runtime, StwoZigArchiveStoreStatsV1 *stats
) {
    StwoZigArchiveStoreState *state = eval_archive_store_state(runtime);
    stats->abi_version = 1u;
    stats->struct_size = (uint32_t)sizeof(*stats);
    stats->archive_disk_hits = state.diskHits;
    stats->archive_disk_misses = state.diskMisses;
    stats->archive_disk_evictions = state.diskEvictions;
    stats->archive_disk_rebuilds = state.diskRebuilds;
    stats->archive_disk_rejections = state.diskRejections;
    stats->archive_disk_quarantines = state.diskQuarantines;
    stats->archive_lock_acquisitions = state.lockAcquisitions;
    stats->archive_lock_contentions = state.lockContentions;
    stats->archive_lock_timeouts = state.lockTimeouts;
    stats->archive_publication_successes = state.publicationSuccesses;
    stats->archive_publication_failures = state.publicationFailures;
    stats->archive_bytes_published = state.bytesPublished;
    stats->archive_bytes_evicted = state.bytesEvicted;
    stats->archive_persistence_bypasses = state.persistenceBypasses;
    stats->archive_lock_wait_seconds = state.lockWaitSeconds;
    stats->archive_disk_entries = state.diskEntries;
    stats->archive_disk_bytes = state.diskBytes;
    stats->archive_disk_entry_limit = STWO_ZIG_ARCHIVE_ENTRY_LIMIT;
    stats->archive_disk_byte_limit = STWO_ZIG_ARCHIVE_BYTE_LIMIT;
    stats->archive_per_entry_byte_limit = STWO_ZIG_ARCHIVE_PER_ENTRY_BYTE_LIMIT;
    stats->archive_quarantine_entries = state.quarantineEntries;
    stats->archive_quarantine_bytes = state.quarantineBytes;
    stats->archive_quarantine_entry_limit = STWO_ZIG_ARCHIVE_QUARANTINE_ENTRY_LIMIT;
    stats->archive_quarantine_byte_limit = STWO_ZIG_ARCHIVE_QUARANTINE_BYTE_LIMIT;
}
