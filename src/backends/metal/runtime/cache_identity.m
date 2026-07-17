typedef NS_ENUM(uint8_t, StwoZigEvalLibraryKind) {
    StwoZigEvalLibraryKindSource = 1u,
    StwoZigEvalLibraryKindMetallib = 2u,
};

static NSString *eval_sha256_hex(const void *bytes, size_t length) {
    if (bytes == NULL && length != 0u) return nil;
    CC_SHA256_CTX context;
    if (CC_SHA256_Init(&context) != 1) return nil;
    size_t consumed = 0u;
    while (consumed < length) {
        size_t remaining = length - consumed;
        CC_LONG chunk = (CC_LONG)MIN(remaining, (size_t)UINT32_MAX);
        if (CC_SHA256_Update(&context, (const uint8_t *)bytes + consumed, chunk) != 1) return nil;
        consumed += chunk;
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    if (CC_SHA256_Final(digest, &context) != 1) return nil;
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2u];
    for (size_t i = 0u; i < CC_SHA256_DIGEST_LENGTH; ++i) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

static NSString *eval_length_prefixed(NSString *value) {
    return [NSString stringWithFormat:@"%lu:%@", (unsigned long)value.length, value];
}

@interface StwoZigEvalRuntimeIdentity : NSObject <NSCopying>
@property(nonatomic) uint64_t registryID;
@property(nonatomic, copy) NSString *architectureName;
@property(nonatomic, copy) NSString *familySetSha256;
@property(nonatomic, copy) NSString *osVersion;
@property(nonatomic, copy) NSString *osBuild;
@property(nonatomic, copy) NSString *compileProfile;
@property(nonatomic, copy) NSString *canonical;
@end

@implementation StwoZigEvalRuntimeIdentity
- (id)copyWithZone:(NSZone *)zone { (void)zone; return self; }
- (NSUInteger)hash { return self.canonical.hash; }
- (BOOL)isEqual:(id)other {
    return [other isKindOfClass:[StwoZigEvalRuntimeIdentity class]] &&
        [self.canonical isEqualToString:((StwoZigEvalRuntimeIdentity *)other).canonical];
}
@end

@interface StwoZigEvalLibraryKey : NSObject <NSCopying>
@property(nonatomic, strong) StwoZigEvalRuntimeIdentity *runtimeIdentity;
@property(nonatomic) StwoZigEvalLibraryKind kind;
@property(nonatomic, copy) NSString *contentSha256;
@property(nonatomic) uint64_t contentBytes;
@property(nonatomic, copy) NSString *canonical;
@end

@interface StwoZigEvalArchiveKey : NSObject <NSCopying>
@property(nonatomic, strong) StwoZigEvalLibraryKey *libraryKey;
@property(nonatomic, copy) NSString *pipelineContract;
@property(nonatomic, copy) NSString *canonical;
@property(nonatomic, copy) NSString *canonicalSha256;
@end

@implementation StwoZigEvalArchiveKey
- (id)copyWithZone:(NSZone *)zone { (void)zone; return self; }
- (NSUInteger)hash { return self.canonical.hash; }
- (BOOL)isEqual:(id)other {
    return [other isKindOfClass:[StwoZigEvalArchiveKey class]] &&
        [self.canonical isEqualToString:((StwoZigEvalArchiveKey *)other).canonical];
}
@end

@implementation StwoZigEvalLibraryKey
- (id)copyWithZone:(NSZone *)zone { (void)zone; return self; }
- (NSUInteger)hash { return self.canonical.hash; }
- (NSComparisonResult)compare:(StwoZigEvalLibraryKey *)other {
    return [self.canonical compare:other.canonical];
}
- (BOOL)isEqual:(id)other {
    return [other isKindOfClass:[StwoZigEvalLibraryKey class]] &&
        [self.canonical isEqualToString:((StwoZigEvalLibraryKey *)other).canonical];
}
@end

@interface StwoZigEvalPipelineKey : NSObject <NSCopying>
@property(nonatomic, strong) StwoZigEvalLibraryKey *libraryKey;
@property(nonatomic, copy) NSString *functionName;
@property(nonatomic, copy) NSString *functionConstantIdentity;
@property(nonatomic, copy) NSString *descriptorContract;
@property(nonatomic, copy) NSString *canonical;
@end

@implementation StwoZigEvalPipelineKey
- (id)copyWithZone:(NSZone *)zone { (void)zone; return self; }
- (NSUInteger)hash { return self.canonical.hash; }
- (BOOL)isEqual:(id)other {
    return [other isKindOfClass:[StwoZigEvalPipelineKey class]] &&
        [self.canonical isEqualToString:((StwoZigEvalPipelineKey *)other).canonical];
}
@end

static NSString *eval_family_set_sha256(id<MTLDevice> device) {
    static const NSInteger familyIDs[] = {
        1001, 1002, 1003, 1004, 1005, 1006, 1007, 1008, 1009, 1010,
        2001, 2002, 3001, 3002, 3003, 5001, 5002,
    };
    NSMutableString *families = [NSMutableString string];
    for (size_t i = 0u; i < sizeof(familyIDs) / sizeof(familyIDs[0]); ++i) {
        MTLGPUFamily family = (MTLGPUFamily)familyIDs[i];
        if ([device supportsFamily:family]) [families appendFormat:@"%ld,", (long)familyIDs[i]];
    }
    NSData *encoded = [families dataUsingEncoding:NSUTF8StringEncoding];
    return eval_sha256_hex(encoded.bytes, encoded.length);
}

static StwoZigEvalRuntimeIdentity *eval_runtime_identity(id<MTLDevice> device) {
    NSDictionary *system = [NSDictionary dictionaryWithContentsOfFile:
        @"/System/Library/CoreServices/SystemVersion.plist"];
    NSOperatingSystemVersion version = [NSProcessInfo processInfo].operatingSystemVersion;
    NSString *osVersion = system[@"ProductVersion"] ?: [NSString stringWithFormat:
        @"%ld.%ld.%ld", (long)version.majorVersion, (long)version.minorVersion,
        (long)version.patchVersion];
    NSString *osBuild = system[@"ProductBuildVersion"] ?:
        [NSProcessInfo processInfo].operatingSystemVersionString;
    NSString *architecture = nil;
    if (@available(macOS 14.0, *)) architecture = device.architecture.name;
    if (architecture.length == 0u) architecture = device.name;

    StwoZigEvalRuntimeIdentity *identity = [StwoZigEvalRuntimeIdentity new];
    identity.registryID = device.registryID;
    identity.architectureName = architecture;
    identity.familySetSha256 = eval_family_set_sha256(device);
    identity.osVersion = osVersion;
    identity.osBuild = osBuild;
    identity.compileProfile = @"dynamic-v1;language=metal3.1;math=safe;minimum-macos=14.0";
    identity.canonical = [NSString stringWithFormat:
        @"runtime-v1|registry=%016llx|architecture=%@|families=%@|os-version=%@|os-build=%@|profile=%@",
        (unsigned long long)identity.registryID,
        eval_length_prefixed(identity.architectureName), identity.familySetSha256,
        eval_length_prefixed(identity.osVersion), eval_length_prefixed(identity.osBuild),
        eval_length_prefixed(identity.compileProfile)];
    return identity;
}

static StwoZigEvalLibraryKey *eval_library_key(
    StwoZigEvalRuntimeIdentity *runtimeIdentity,
    StwoZigEvalLibraryKind kind,
    NSString *contentSha256,
    uint64_t contentBytes
) {
    if (runtimeIdentity == nil || contentSha256.length != CC_SHA256_DIGEST_LENGTH * 2u ||
        contentBytes == 0u) return nil;
    StwoZigEvalLibraryKey *key = [StwoZigEvalLibraryKey new];
    key.runtimeIdentity = runtimeIdentity;
    key.kind = kind;
    key.contentSha256 = contentSha256;
    key.contentBytes = contentBytes;
    key.canonical = [NSString stringWithFormat:
        @"library-v2|runtime=%@|kind=%u|content-sha256=%@|content-bytes=%llu",
        eval_length_prefixed(runtimeIdentity.canonical), (unsigned)kind, contentSha256,
        (unsigned long long)contentBytes];
    return key;
}

static StwoZigEvalPipelineKey *eval_pipeline_key(
    StwoZigEvalLibraryKey *libraryKey,
    NSString *functionName
) {
    if (libraryKey == nil || functionName.length == 0u) return nil;
    StwoZigEvalPipelineKey *key = [StwoZigEvalPipelineKey new];
    key.libraryKey = libraryKey;
    key.functionName = functionName;
    key.functionConstantIdentity = @"none";
    key.descriptorContract = @"compute-default-v1";
    key.canonical = [NSString stringWithFormat:
        @"pipeline-v2|library=%@|function=%@|function-constants=%@|descriptor=%@",
        eval_length_prefixed(libraryKey.canonical), eval_length_prefixed(functionName),
        key.functionConstantIdentity, key.descriptorContract];
    return key;
}

static StwoZigEvalArchiveKey *eval_archive_key(StwoZigEvalLibraryKey *libraryKey) {
    if (libraryKey == nil) return nil;
    StwoZigEvalArchiveKey *key = [StwoZigEvalArchiveKey new];
    key.libraryKey = libraryKey;
    key.pipelineContract = @"compute-default-v1";
    key.canonical = [NSString stringWithFormat:@"archive-v2|library=%@|pipeline-contract=%@",
        eval_length_prefixed(libraryKey.canonical), key.pipelineContract];
    NSData *encoded = [key.canonical dataUsingEncoding:NSUTF8StringEncoding];
    key.canonicalSha256 = eval_sha256_hex(encoded.bytes, encoded.length);
    return key;
}
