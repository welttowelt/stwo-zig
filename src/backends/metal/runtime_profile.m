#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <dlfcn.h>
#include <fcntl.h>
#include <mach/mach_time.h>
#include <objc/runtime.h>
#include <unistd.h>

// This file is imported by runtime.m. Profiling is dormant unless
// STWO_ZIG_METAL_PROFILE_OUT names an NDJSON output file.

static const void *StwoProfilePipelineNameKey = &StwoProfilePipelineNameKey;

// Encoder profiling consumes paired 8-byte timestamp samples. Keep the sample
// buffer within Metal's 32 KiB limit on supported Apple Silicon devices.
static const NSUInteger StwoProfileMaxEncodersPerCommandBuffer = 2048u;

static double stwo_profile_cpu_milliseconds(uint64_t start, uint64_t end) {
    static mach_timebase_info_data_t timebase;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mach_timebase_info(&timebase); });
    if (end < start) return 0.0;
    return (double)(end - start) * (double)timebase.numer /
           (double)timebase.denom / 1.0e6;
}

static NSString *stwo_profile_callsite_name(void *address) {
    Dl_info info;
    if (address != NULL && dladdr(address, &info) != 0 && info.dli_sname != NULL) {
        const char *symbol = info.dli_sname;
        if (symbol[0] == '_') symbol += 1;
        return [NSString stringWithUTF8String:symbol] ?: @"metal_command";
    }
    return @"metal_command";
}

static NSString *stwo_profile_status_name(MTLCommandBufferStatus status) {
    switch (status) {
        case MTLCommandBufferStatusNotEnqueued: return @"not_enqueued";
        case MTLCommandBufferStatusEnqueued: return @"enqueued";
        case MTLCommandBufferStatusCommitted: return @"committed";
        case MTLCommandBufferStatusScheduled: return @"scheduled";
        case MTLCommandBufferStatusCompleted: return @"completed";
        case MTLCommandBufferStatusError: return @"error";
    }
    return @"unknown";
}

static NSUInteger stwo_profile_size_product(MTLSize size) {
    if (size.width == 0u || size.height == 0u || size.depth == 0u) return 0u;
    if (size.width > NSUIntegerMax / size.height) return NSUIntegerMax;
    NSUInteger result = size.width * size.height;
    if (result > NSUIntegerMax / size.depth) return NSUIntegerMax;
    return result * size.depth;
}

@interface StwoProfileSink : NSObject
@property(nonatomic, strong) id<MTLDevice> device;
@property(nonatomic, strong) id<MTLCounterSet> timestampCounterSet;
@property(nonatomic) BOOL stageBoundaryCounters;
@property(nonatomic) BOOL encoderCountersRequested;
@property(nonatomic) BOOL encoderCountersEnabled;
@property(nonatomic) NSUInteger maxEncoders;
@property(nonatomic) uint64_t gpuTimestampFrequency;
@property(nonatomic) int fileDescriptor;
@property(nonatomic) uint64_t sequence;
- (instancetype)initWithDevice:(id<MTLDevice>)device path:(NSString *)path;
- (void)writeEvent:(NSDictionary *)event;
@end

@implementation StwoProfileSink
- (instancetype)initWithDevice:(id<MTLDevice>)device path:(NSString *)path {
    self = [super init];
    if (self == nil) return nil;
    _device = device;
    _fileDescriptor = open(path.fileSystemRepresentation, O_CREAT | O_TRUNC | O_WRONLY, 0600);
    if (_fileDescriptor < 0) return nil;
    _maxEncoders = 1024u;
    NSString *configuredMax = NSProcessInfo.processInfo.environment[@"STWO_ZIG_METAL_PROFILE_MAX_ENCODERS"];
    if (configuredMax != nil) {
        long long value = configuredMax.longLongValue;
        if (value > 0) {
            _maxEncoders = MIN((NSUInteger)value, StwoProfileMaxEncodersPerCommandBuffer);
        }
    }
    _stageBoundaryCounters = [device supportsCounterSampling:MTLCounterSamplingPointAtStageBoundary];
    _encoderCountersRequested = [NSProcessInfo.processInfo.environment[
        @"STWO_ZIG_METAL_PROFILE_ENCODER_COUNTERS"] isEqualToString:@"1"];
    for (id<MTLCounterSet> set in device.counterSets) {
        if ([set.name isEqualToString:MTLCommonCounterSetTimestamp]) {
            _timestampCounterSet = set;
            break;
        }
    }
    if (_timestampCounterSet == nil) _stageBoundaryCounters = NO;
    _encoderCountersEnabled = _encoderCountersRequested && _stageBoundaryCounters;
    if (_encoderCountersEnabled) {
        // Metal returns the paired CPU timestamp in nanoseconds. Calibrate the
        // GPU tick domain directly; mach_timebase conversion would apply twice.
        MTLTimestamp cpu0 = 0, gpu0 = 0, cpu1 = 0, gpu1 = 0;
        [device sampleTimestamps:&cpu0 gpuTimestamp:&gpu0];
        usleep(10000);
        [device sampleTimestamps:&cpu1 gpuTimestamp:&gpu1];
        if (cpu1 > cpu0 && gpu1 > gpu0)
            _gpuTimestampFrequency = (uint64_t)((double)(gpu1 - gpu0) * 1.0e9 /
                                                (double)(cpu1 - cpu0));
    }
    NSMutableArray *counterSets = [NSMutableArray array];
    for (id<MTLCounterSet> set in device.counterSets) {
        NSMutableArray *counters = [NSMutableArray array];
        for (id<MTLCounter> counter in set.counters) [counters addObject:counter.name];
        [counterSets addObject:@{ @"name": set.name, @"counters": counters }];
    }
    [self writeEvent:@{
        @"schema": @"stwo-metal-profile-v1",
        @"type": @"metadata",
        @"device": device.name,
        @"pid": @(getpid()),
        @"stage_boundary_timestamps_supported": @(_stageBoundaryCounters),
        @"encoder_timestamps_requested": @(_encoderCountersRequested),
        @"encoder_timestamps_enabled": @(_encoderCountersEnabled),
        @"gpu_timestamp_frequency_hz": @(_gpuTimestampFrequency),
        @"max_encoders_per_command_buffer": @(_maxEncoders),
        @"counter_sets": counterSets,
    }];
    return self;
}

- (void)dealloc {
    if (_fileDescriptor >= 0) close(_fileDescriptor);
}

- (void)writeEvent:(NSDictionary *)event {
    @synchronized(self) {
        if (_fileDescriptor < 0) return;
        NSMutableDictionary *encoded = [event mutableCopy];
        if (encoded[@"schema"] == nil) encoded[@"schema"] = @"stwo-metal-profile-v1";
        if (encoded[@"sequence"] == nil) encoded[@"sequence"] = @(_sequence++);
        NSError *error = nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:encoded options:NSJSONWritingSortedKeys error:&error];
        if (data == nil || error != nil) return;
        const uint8_t *bytes = data.bytes;
        size_t remaining = data.length;
        while (remaining > 0u) {
            ssize_t written = write(_fileDescriptor, bytes, remaining);
            if (written <= 0) return;
            bytes += (size_t)written;
            remaining -= (size_t)written;
        }
        (void)write(_fileDescriptor, "\n", 1u);
    }
}
@end

@interface StwoProfileEncoderRecord : NSObject
@property(nonatomic, copy) NSString *kind;
@property(nonatomic, strong) NSMutableArray<NSString *> *pipelines;
@property(nonatomic, strong) NSMutableSet<NSValue *> *boundBuffers;
@property(nonatomic) NSUInteger dispatchCount;
@property(nonatomic) uint64_t gridThreads;
@property(nonatomic) NSUInteger maxThreadgroupThreads;
@property(nonatomic) uint64_t boundBufferCapacityBytes;
@property(nonatomic) uint64_t inlineBytes;
@property(nonatomic) uint64_t blitBytes;
@property(nonatomic) NSUInteger sampleStart;
@property(nonatomic) NSUInteger sampleEnd;
@property(nonatomic) BOOL debugGroupPushed;
@end

@implementation StwoProfileEncoderRecord
- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _pipelines = [NSMutableArray array];
        _boundBuffers = [NSMutableSet set];
        _sampleStart = MTLCounterDontSample;
        _sampleEnd = MTLCounterDontSample;
    }
    return self;
}
@end

@interface StwoProfileCommandRecord : NSObject
@property(nonatomic, strong) StwoProfileSink *sink;
@property(nonatomic, strong) id<MTLCounterSampleBuffer> counterBuffer;
@property(nonatomic, strong) NSMutableArray<StwoProfileEncoderRecord *> *encoders;
@property(nonatomic, copy) NSString *callsite;
@property(nonatomic) uint64_t createdAt;
@property(nonatomic) uint64_t commitStartedAt;
@property(nonatomic) uint64_t commitFinishedAt;
@property(nonatomic) double waitCpuMilliseconds;
@property(nonatomic) NSUInteger nextSample;
@property(nonatomic) BOOL counterOverflow;
@property(nonatomic, copy) NSString *counterAllocationError;
@property(nonatomic) BOOL finished;
- (StwoProfileEncoderRecord *)beginEncoder:(NSString *)kind;
- (void)finishCommand:(id<MTLCommandBuffer>)command;
@end

@implementation StwoProfileCommandRecord
- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _encoders = [NSMutableArray array];
        _createdAt = mach_continuous_time();
    }
    return self;
}

- (StwoProfileEncoderRecord *)beginEncoder:(NSString *)kind {
    StwoProfileEncoderRecord *record = [StwoProfileEncoderRecord new];
    record.kind = kind;
    if (self.counterBuffer != nil && self.nextSample + 2u <= self.counterBuffer.sampleCount) {
        record.sampleStart = self.nextSample++;
        record.sampleEnd = self.nextSample++;
    } else if (self.counterBuffer != nil) {
        self.counterOverflow = YES;
    }
    [self.encoders addObject:record];
    return record;
}

- (void)finishCommand:(id<MTLCommandBuffer>)command {
    if (self.finished) return;
    self.finished = YES;
    NSData *samples = nil;
    if (self.counterBuffer != nil && self.nextSample > 0u)
        samples = [self.counterBuffer resolveCounterRange:NSMakeRange(0u, self.nextSample)];
    const MTLCounterResultTimestamp *timestamps = samples.bytes;
    NSUInteger timestampCount = samples.length / sizeof(MTLCounterResultTimestamp);

    NSMutableArray *encodedEncoders = [NSMutableArray arrayWithCapacity:self.encoders.count];
    NSMutableOrderedSet<NSString *> *operationKernels = [NSMutableOrderedSet orderedSet];
    double encoderGpuTotal = 0.0;
    NSUInteger counterErrorSamples = 0u;
    for (StwoProfileEncoderRecord *encoder in self.encoders) {
        NSMutableDictionary *entry = [@{
            @"kind": encoder.kind,
            @"pipelines": encoder.pipelines,
            @"dispatches": @(encoder.dispatchCount),
            @"grid_threads": @(encoder.gridThreads),
            @"max_threadgroup_threads": @(encoder.maxThreadgroupThreads),
            @"bound_buffer_capacity_bytes": @(encoder.boundBufferCapacityBytes),
            @"inline_bytes": @(encoder.inlineBytes),
            @"blit_bytes": @(encoder.blitBytes),
        } mutableCopy];
        [operationKernels addObjectsFromArray:encoder.pipelines];
        if (timestamps != NULL && self.sink.gpuTimestampFrequency > 0u &&
            encoder.sampleStart < timestampCount && encoder.sampleEnd < timestampCount) {
            uint64_t start = timestamps[encoder.sampleStart].timestamp;
            uint64_t end = timestamps[encoder.sampleEnd].timestamp;
            if (start != MTLCounterErrorValue && end != MTLCounterErrorValue && end >= start) {
                double gpuMilliseconds = (double)(end - start) * 1000.0 /
                                         (double)self.sink.gpuTimestampFrequency;
                entry[@"gpu_ms"] = @(gpuMilliseconds);
                encoderGpuTotal += gpuMilliseconds;
            } else {
                counterErrorSamples += (start == MTLCounterErrorValue ? 1u : 0u) +
                                       (end == MTLCounterErrorValue ? 1u : 0u);
            }
        }
        [encodedEncoders addObject:entry];
    }

    double commandGpuMilliseconds = 0.0;
    if (command.GPUEndTime >= command.GPUStartTime)
        commandGpuMilliseconds = (command.GPUEndTime - command.GPUStartTime) * 1000.0;
    NSString *operation = self.callsite;
    if ([operation isEqualToString:@"metal_command"] && operationKernels.count > 0u)
        operation = [operationKernels.array componentsJoinedByString:@"+"];
    NSMutableDictionary *event = [@{
        @"type": @"command_buffer",
        @"operation": operation,
        @"status": stwo_profile_status_name(command.status),
        @"gpu_ms": @(commandGpuMilliseconds),
        @"encoder_gpu_ms": @(encoderGpuTotal),
        @"unattributed_gpu_ms": @(MAX(0.0, commandGpuMilliseconds - encoderGpuTotal)),
        @"encode_cpu_ms": @(self.commitStartedAt > 0u ?
            stwo_profile_cpu_milliseconds(self.createdAt, self.commitStartedAt) : 0.0),
        @"commit_cpu_ms": @(self.commitFinishedAt >= self.commitStartedAt ?
            stwo_profile_cpu_milliseconds(self.commitStartedAt, self.commitFinishedAt) : 0.0),
        @"wait_cpu_ms": @(self.waitCpuMilliseconds),
        @"encoders": encodedEncoders,
        @"counter_overflow": @(self.counterOverflow),
        @"counter_samples_requested": @(self.nextSample),
        @"counter_samples_resolved": @(timestampCount),
        @"counter_error_samples": @(counterErrorSamples),
    } mutableCopy];
    if (command.label != nil) event[@"label"] = command.label;
    if (command.error != nil) event[@"error"] = command.error.localizedDescription ?: @"Metal command error";
    if (self.counterAllocationError != nil) event[@"counter_allocation_error"] = self.counterAllocationError;
    [self.sink writeEvent:event];
}
@end

static void stwo_profile_record_buffer(StwoProfileEncoderRecord *record, id<MTLBuffer> buffer) {
    if (buffer == nil) return;
    NSValue *identity = [NSValue valueWithNonretainedObject:buffer];
    if (![record.boundBuffers containsObject:identity]) {
        [record.boundBuffers addObject:identity];
        record.boundBufferCapacityBytes += buffer.length;
    }
}

static void stwo_profile_record_pipeline(StwoProfileEncoderRecord *record,
                                         id<MTLComputePipelineState> pipeline,
                                         id<MTLComputeCommandEncoder> encoder) {
    NSString *name = objc_getAssociatedObject(pipeline, StwoProfilePipelineNameKey);
    if (name == nil) name = pipeline.label;
    if (name == nil) name = @"unnamed_compute_pipeline";
    if (![record.pipelines containsObject:name]) [record.pipelines addObject:name];
    if (encoder.label == nil) encoder.label = name;
    if (!record.debugGroupPushed) {
        [encoder pushDebugGroup:name];
        record.debugGroupPushed = YES;
    }
}

@interface StwoProfileComputeEncoderProxy : NSProxy {
    __strong id<MTLComputeCommandEncoder> _inner;
    __strong StwoProfileEncoderRecord *_record;
}
+ (id<MTLComputeCommandEncoder>)proxyWithEncoder:(id<MTLComputeCommandEncoder>)encoder
                                          record:(StwoProfileEncoderRecord *)record;
@end

@implementation StwoProfileComputeEncoderProxy
+ (id<MTLComputeCommandEncoder>)proxyWithEncoder:(id<MTLComputeCommandEncoder>)encoder
                                          record:(StwoProfileEncoderRecord *)record {
    StwoProfileComputeEncoderProxy *proxy = [StwoProfileComputeEncoderProxy alloc];
    proxy->_inner = encoder;
    proxy->_record = record;
    return (id<MTLComputeCommandEncoder>)proxy;
}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    return [(id)_inner methodSignatureForSelector:selector];
}
- (void)forwardInvocation:(NSInvocation *)invocation { [invocation invokeWithTarget:_inner]; }
- (BOOL)respondsToSelector:(SEL)selector { return [super respondsToSelector:selector] || [_inner respondsToSelector:selector]; }
- (void)setComputePipelineState:(id<MTLComputePipelineState>)state {
    stwo_profile_record_pipeline(_record, state, _inner);
    [_inner setComputePipelineState:state];
}
- (void)setBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index {
    stwo_profile_record_buffer(_record, buffer);
    [_inner setBuffer:buffer offset:offset atIndex:index];
}
- (void)setBytes:(const void *)bytes length:(NSUInteger)length atIndex:(NSUInteger)index {
    _record.inlineBytes += length;
    [_inner setBytes:bytes length:length atIndex:index];
}
- (void)dispatchThreads:(MTLSize)threadsPerGrid threadsPerThreadgroup:(MTLSize)threadsPerThreadgroup {
    _record.dispatchCount += 1u;
    _record.gridThreads += stwo_profile_size_product(threadsPerGrid);
    _record.maxThreadgroupThreads = MAX(_record.maxThreadgroupThreads,
                                        stwo_profile_size_product(threadsPerThreadgroup));
    [_inner dispatchThreads:threadsPerGrid threadsPerThreadgroup:threadsPerThreadgroup];
}
- (void)dispatchThreadgroups:(MTLSize)threadgroupsPerGrid threadsPerThreadgroup:(MTLSize)threadsPerThreadgroup {
    _record.dispatchCount += 1u;
    NSUInteger groups = stwo_profile_size_product(threadgroupsPerGrid);
    NSUInteger threads = stwo_profile_size_product(threadsPerThreadgroup);
    if (groups != NSUIntegerMax && threads != NSUIntegerMax &&
        (threads == 0u || groups <= NSUIntegerMax / threads))
        _record.gridThreads += groups * threads;
    _record.maxThreadgroupThreads = MAX(_record.maxThreadgroupThreads, threads);
    [_inner dispatchThreadgroups:threadgroupsPerGrid threadsPerThreadgroup:threadsPerThreadgroup];
}
- (void)dispatchThreadgroupsWithIndirectBuffer:(id<MTLBuffer>)indirectBuffer
                          indirectBufferOffset:(NSUInteger)indirectBufferOffset
                         threadsPerThreadgroup:(MTLSize)threadsPerThreadgroup {
    _record.dispatchCount += 1u;
    _record.maxThreadgroupThreads = MAX(_record.maxThreadgroupThreads,
                                        stwo_profile_size_product(threadsPerThreadgroup));
    stwo_profile_record_buffer(_record, indirectBuffer);
    [_inner dispatchThreadgroupsWithIndirectBuffer:indirectBuffer
                              indirectBufferOffset:indirectBufferOffset
                             threadsPerThreadgroup:threadsPerThreadgroup];
}
- (void)endEncoding {
    if (_record.debugGroupPushed) {
        [_inner popDebugGroup];
        _record.debugGroupPushed = NO;
    }
    [_inner endEncoding];
}
@end

@interface StwoProfileBlitEncoderProxy : NSProxy {
    __strong id<MTLBlitCommandEncoder> _inner;
    __strong StwoProfileEncoderRecord *_record;
}
+ (id<MTLBlitCommandEncoder>)proxyWithEncoder:(id<MTLBlitCommandEncoder>)encoder
                                       record:(StwoProfileEncoderRecord *)record;
@end

@implementation StwoProfileBlitEncoderProxy
+ (id<MTLBlitCommandEncoder>)proxyWithEncoder:(id<MTLBlitCommandEncoder>)encoder
                                       record:(StwoProfileEncoderRecord *)record {
    StwoProfileBlitEncoderProxy *proxy = [StwoProfileBlitEncoderProxy alloc];
    proxy->_inner = encoder;
    proxy->_record = record;
    encoder.label = @"stwo_zig_blit";
    [encoder pushDebugGroup:@"stwo_zig_blit"];
    record.debugGroupPushed = YES;
    return (id<MTLBlitCommandEncoder>)proxy;
}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    return [(id)_inner methodSignatureForSelector:selector];
}
- (void)forwardInvocation:(NSInvocation *)invocation { [invocation invokeWithTarget:_inner]; }
- (BOOL)respondsToSelector:(SEL)selector { return [super respondsToSelector:selector] || [_inner respondsToSelector:selector]; }
- (void)copyFromBuffer:(id<MTLBuffer>)sourceBuffer sourceOffset:(NSUInteger)sourceOffset
              toBuffer:(id<MTLBuffer>)destinationBuffer destinationOffset:(NSUInteger)destinationOffset
                  size:(NSUInteger)size {
    stwo_profile_record_buffer(_record, sourceBuffer);
    stwo_profile_record_buffer(_record, destinationBuffer);
    _record.blitBytes += size;
    [_inner copyFromBuffer:sourceBuffer sourceOffset:sourceOffset toBuffer:destinationBuffer
         destinationOffset:destinationOffset size:size];
}
- (void)fillBuffer:(id<MTLBuffer>)buffer range:(NSRange)range value:(uint8_t)value {
    stwo_profile_record_buffer(_record, buffer);
    _record.blitBytes += range.length;
    [_inner fillBuffer:buffer range:range value:value];
}
- (void)endEncoding {
    if (_record.debugGroupPushed) {
        [_inner popDebugGroup];
        _record.debugGroupPushed = NO;
    }
    [_inner endEncoding];
}
@end

@interface StwoProfileCommandBufferProxy : NSProxy {
    __strong id<MTLCommandBuffer> _inner;
    __strong StwoProfileCommandRecord *_record;
}
+ (id<MTLCommandBuffer>)proxyWithCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                                          sink:(StwoProfileSink *)sink
                                      callsite:(NSString *)callsite;
@end

@implementation StwoProfileCommandBufferProxy
+ (id<MTLCommandBuffer>)proxyWithCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                                          sink:(StwoProfileSink *)sink
                                      callsite:(NSString *)callsite {
    StwoProfileCommandBufferProxy *proxy = [StwoProfileCommandBufferProxy alloc];
    proxy->_inner = commandBuffer;
    proxy->_record = [StwoProfileCommandRecord new];
    proxy->_record.sink = sink;
    proxy->_record.callsite = callsite;
    if (sink.encoderCountersEnabled) {
        MTLCounterSampleBufferDescriptor *descriptor = [MTLCounterSampleBufferDescriptor new];
        descriptor.counterSet = sink.timestampCounterSet;
        descriptor.label = @"stwo-zig encoder timestamps";
        descriptor.storageMode = MTLStorageModeShared;
        descriptor.sampleCount = sink.maxEncoders * 2u;
        NSError *error = nil;
        proxy->_record.counterBuffer = [sink.device newCounterSampleBufferWithDescriptor:descriptor error:&error];
        if (proxy->_record.counterBuffer == nil)
            proxy->_record.counterAllocationError = error.localizedDescription ?: @"counter buffer allocation failed";
    }
    return (id<MTLCommandBuffer>)proxy;
}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    return [(id)_inner methodSignatureForSelector:selector];
}
- (void)forwardInvocation:(NSInvocation *)invocation { [invocation invokeWithTarget:_inner]; }
- (BOOL)respondsToSelector:(SEL)selector { return [super respondsToSelector:selector] || [_inner respondsToSelector:selector]; }
- (id<MTLComputeCommandEncoder>)computeCommandEncoder {
    StwoProfileEncoderRecord *record = [_record beginEncoder:@"compute"];
    id<MTLComputeCommandEncoder> encoder = nil;
    if (record.sampleStart != MTLCounterDontSample) {
        MTLComputePassDescriptor *descriptor = [MTLComputePassDescriptor computePassDescriptor];
        MTLComputePassSampleBufferAttachmentDescriptor *attachment = descriptor.sampleBufferAttachments[0];
        attachment.sampleBuffer = _record.counterBuffer;
        attachment.startOfEncoderSampleIndex = record.sampleStart;
        attachment.endOfEncoderSampleIndex = record.sampleEnd;
        encoder = [_inner computeCommandEncoderWithDescriptor:descriptor];
    } else {
        encoder = [_inner computeCommandEncoder];
    }
    return [StwoProfileComputeEncoderProxy proxyWithEncoder:encoder record:record];
}
- (id<MTLBlitCommandEncoder>)blitCommandEncoder {
    StwoProfileEncoderRecord *record = [_record beginEncoder:@"blit"];
    id<MTLBlitCommandEncoder> encoder = nil;
    if (record.sampleStart != MTLCounterDontSample) {
        MTLBlitPassDescriptor *descriptor = [MTLBlitPassDescriptor blitPassDescriptor];
        MTLBlitPassSampleBufferAttachmentDescriptor *attachment = descriptor.sampleBufferAttachments[0];
        attachment.sampleBuffer = _record.counterBuffer;
        attachment.startOfEncoderSampleIndex = record.sampleStart;
        attachment.endOfEncoderSampleIndex = record.sampleEnd;
        encoder = [_inner blitCommandEncoderWithDescriptor:descriptor];
    } else {
        encoder = [_inner blitCommandEncoder];
    }
    return [StwoProfileBlitEncoderProxy proxyWithEncoder:encoder record:record];
}
- (void)commit {
    if (_record.commitStartedAt == 0u) _record.commitStartedAt = mach_continuous_time();
    NSMutableOrderedSet<NSString *> *kernels = [NSMutableOrderedSet orderedSet];
    for (StwoProfileEncoderRecord *encoder in _record.encoders)
        [kernels addObjectsFromArray:encoder.pipelines];
    NSString *label = _record.callsite;
    if ([label isEqualToString:@"metal_command"] && kernels.count > 0u)
        label = [kernels.array componentsJoinedByString:@"+"];
    _inner.label = label;
    [_inner commit];
    _record.commitFinishedAt = mach_continuous_time();
}
- (void)waitUntilCompleted {
    uint64_t start = mach_continuous_time();
    [_inner waitUntilCompleted];
    _record.waitCpuMilliseconds += stwo_profile_cpu_milliseconds(start, mach_continuous_time());
    [_record finishCommand:_inner];
}
@end

@interface StwoProfileCommandQueueProxy : NSProxy {
    __strong id<MTLCommandQueue> _inner;
    __strong StwoProfileSink *_sink;
}
+ (id<MTLCommandQueue>)proxyWithQueue:(id<MTLCommandQueue>)queue sink:(StwoProfileSink *)sink;
@end

@implementation StwoProfileCommandQueueProxy
+ (id<MTLCommandQueue>)proxyWithQueue:(id<MTLCommandQueue>)queue sink:(StwoProfileSink *)sink {
    StwoProfileCommandQueueProxy *proxy = [StwoProfileCommandQueueProxy alloc];
    proxy->_inner = queue;
    proxy->_sink = sink;
    return (id<MTLCommandQueue>)proxy;
}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    return [(id)_inner methodSignatureForSelector:selector];
}
- (void)forwardInvocation:(NSInvocation *)invocation { [invocation invokeWithTarget:_inner]; }
- (BOOL)respondsToSelector:(SEL)selector { return [super respondsToSelector:selector] || [_inner respondsToSelector:selector]; }
- (id<MTLCommandBuffer>)commandBuffer {
    NSString *callsite = stwo_profile_callsite_name(__builtin_return_address(0));
    return [StwoProfileCommandBufferProxy proxyWithCommandBuffer:[_inner commandBuffer]
                                                            sink:_sink callsite:callsite];
}
- (id<MTLCommandBuffer>)commandBufferWithUnretainedReferences {
    NSString *callsite = stwo_profile_callsite_name(__builtin_return_address(0));
    return [StwoProfileCommandBufferProxy proxyWithCommandBuffer:[_inner commandBufferWithUnretainedReferences]
                                                            sink:_sink callsite:callsite];
}
- (id<MTLCommandBuffer>)commandBufferWithDescriptor:(MTLCommandBufferDescriptor *)descriptor {
    NSString *callsite = stwo_profile_callsite_name(__builtin_return_address(0));
    return [StwoProfileCommandBufferProxy proxyWithCommandBuffer:[_inner commandBufferWithDescriptor:descriptor]
                                                            sink:_sink callsite:callsite];
}
@end

static void stwo_zig_metal_profile_name_pipeline(id<MTLComputePipelineState> pipeline,
                                                  NSString *name) {
    if (NSProcessInfo.processInfo.environment[@"STWO_ZIG_METAL_PROFILE_OUT"].length > 0u &&
        pipeline != nil && name != nil)
        objc_setAssociatedObject(pipeline, StwoProfilePipelineNameKey, name,
                                 OBJC_ASSOCIATION_COPY_NONATOMIC);
}

static id<MTLCommandQueue> stwo_zig_metal_profile_queue(id<MTLCommandQueue> queue,
                                                        id<MTLDevice> device) {
    NSString *path = NSProcessInfo.processInfo.environment[@"STWO_ZIG_METAL_PROFILE_OUT"];
    if (path.length == 0u || queue == nil) return queue;
    StwoProfileSink *sink = [[StwoProfileSink alloc] initWithDevice:device path:path];
    if (sink == nil) return queue;
    return [StwoProfileCommandQueueProxy proxyWithQueue:queue sink:sink];
}
