from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE_PATH = ROOT / "src/backends/metal/runtime.m"
ZIG_SOURCE_PATH = ROOT / "src/backends/metal/runtime.zig"
ZIG_ABI_SOURCE_PATH = ROOT / "src/backends/metal/runtime/abi.zig"


def function_body(source: str, name: str, next_name: str) -> str:
    start = source.index(name)
    end = source.index(next_name, start)
    return source[start:end]


class MetalPipelineCacheSourceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = SOURCE_PATH.read_text()
        cls.zig_source = ZIG_SOURCE_PATH.read_text()
        cls.zig_abi_source = ZIG_ABI_SOURCE_PATH.read_text()

    def test_file_backed_libraries_use_canonical_runtime_cache(self):
        body = function_body(
            self.source,
            "void *stwo_zig_metal_eval_library_load(",
            "void *stwo_zig_metal_eval_library_compile(",
        )
        self.assertIn("stringByResolvingSymlinksInPath", body)
        self.assertIn("@synchronized(runtime)", body)
        self.assertIn("runtime.evalLibraries[cacheKey]", body)
        self.assertIn("result.cacheKey = cacheKey", body)

    def test_file_backed_metallib_cache_and_archive_are_content_addressed(self):
        body = function_body(
            self.source,
            "void *stwo_zig_metal_eval_library_load(",
            "void *stwo_zig_metal_eval_library_compile(",
        )
        self.assertIn("NSDataReadingMappedIfSafe", body)
        self.assertIn("eval_source_sha256_hex(libraryData.bytes, libraryData.length)", body)
        self.assertIn('metallib:sha256:%@:%zu', body)
        self.assertIn("eval_metallib_archive_path(libraryDigest, libraryData.length)", body)
        self.assertNotIn('stringByAppendingString:@".binarchive"', body)
        helper = function_body(
            self.source,
            "static NSString *eval_metallib_archive_path(",
            "static bool serialize_eval_archive(",
        )
        self.assertIn("NSTemporaryDirectory()", helper)
        self.assertIn("stwo-zig-eval-metallib-sha256-%@-%zu.binarchive", helper)

    def test_archive_hit_is_probed_before_confirmed_miss_population(self):
        body = function_body(
            self.source,
            "static id<MTLComputePipelineState> resolve_eval_pipeline(",
            "void *stwo_zig_metal_eval_library_load(",
        )
        cache = body.index("runtime.evalPipelines[pipelineKey]")
        probe = body.index("MTLPipelineOptionFailOnBinaryArchiveMiss")
        direct_compile = body.index("newComputePipelineStateWithFunction", probe)
        populate = body.index("addComputePipelineFunctionsWithDescriptor", direct_compile)
        dirty = body.index("library.archiveDirty = true", populate)
        self.assertLess(cache, probe)
        self.assertLess(probe, direct_compile)
        self.assertLess(direct_compile, populate)
        self.assertLess(populate, dirty)
        self.assertEqual(self.source.count("addComputePipelineFunctionsWithDescriptor"), 1)

    def test_eval_and_witness_prepares_share_pipeline_resolver(self):
        witness = function_body(
            self.source,
            "void *stwo_zig_metal_witness_prepare_library(",
            "void stwo_zig_metal_witness_plan_destroy(",
        )
        evaluation = function_body(
            self.source,
            "void *stwo_zig_metal_eval_prepare_library(",
            "bool stwo_zig_metal_eval_library_serialize(",
        )
        self.assertIn("resolve_eval_pipeline(runtime, library, name", witness)
        self.assertIn("resolve_eval_pipeline(runtime, library, name", evaluation)
        self.assertNotIn("addComputePipelineFunctionsWithDescriptor", witness)
        self.assertNotIn("addComputePipelineFunctionsWithDescriptor", evaluation)

    def test_source_compiled_library_uses_content_keyed_runtime_cache_and_archive(self):
        body = function_body(
            self.source,
            "void *stwo_zig_metal_eval_library_compile(",
            "void stwo_zig_metal_eval_library_destroy(",
        )
        self.assertIn("eval_source_sha256_hex(source_bytes, source_len)", body)
        self.assertIn(
            'NSString *cacheKey = [NSString stringWithFormat:@"source:sha256:%@:%zu"',
            body,
        )
        self.assertIn("[cached.sourceBytes isEqualToData:sourceData]", body)
        self.assertIn("Metal source cache identity collision", body)
        key = body.index("eval_source_sha256_hex(source_bytes, source_len)")
        synchronized = body.index("@synchronized(runtime)", key)
        lookup = body.index("runtime.evalLibraries[cacheKey]", synchronized)
        hit = body.index("runtime.evalLibraryCacheHits += 1u", lookup)
        miss = body.index("runtime.evalLibraryCacheMisses += 1u", hit)
        compile_library = body.index("newLibraryWithSource", miss)
        insertion = body.index("runtime.evalLibraries[cacheKey] = result", compile_library)
        self.assertLess(key, synchronized)
        self.assertLess(synchronized, lookup)
        self.assertLess(lookup, hit)
        self.assertLess(hit, miss)
        self.assertLess(miss, compile_library)
        self.assertLess(compile_library, insertion)
        self.assertIn("result.cacheKey = cacheKey", body)
        self.assertIn("result.sourceBytes = sourceData", body)
        self.assertIn("NSTemporaryDirectory()", body)
        self.assertIn("stwo-zig-eval-sha256-%@-%zu.binarchive", body)
        self.assertIn("result.archiveLoaded", body)
        self.assertIn("newBinaryArchiveWithDescriptor", body)

    def test_source_identity_uses_full_sha256_not_fnv64(self):
        identity = function_body(
            self.source,
            "static NSString *eval_source_sha256_hex(",
            "static bool serialize_eval_archive(",
        )
        self.assertIn("CC_SHA256_Init", identity)
        self.assertIn("CC_SHA256_Update", identity)
        self.assertIn("CC_SHA256_Final", identity)
        self.assertIn("CC_SHA256_DIGEST_LENGTH * 2u", identity)
        self.assertNotIn("1099511628211", self.source)
        self.assertNotIn("14695981039346656037", self.source)

    def test_source_cache_returns_independently_retained_handles(self):
        compile_body = function_body(
            self.source,
            "void *stwo_zig_metal_eval_library_compile(",
            "void stwo_zig_metal_eval_library_destroy(",
        )
        destroy_body = function_body(
            self.source,
            "void stwo_zig_metal_eval_library_destroy(",
            "void *stwo_zig_metal_witness_prepare_library(",
        )
        self.assertIn("return (__bridge_retained void *)cached", compile_body)
        self.assertIn("return (__bridge_retained void *)result", compile_body)
        self.assertIn("runtime.evalLibraries[cacheKey] = result", compile_body)
        self.assertIn("CFRelease(library_ptr)", destroy_body)
        self.assertIn("@property(nonatomic, weak) StwoZigMetalRuntime *runtimeOwner", self.source)

    def test_dirty_archives_are_serialized_in_stable_order(self):
        serialize = function_body(
            self.source,
            "static bool serialize_eval_archive(",
            "static id<MTLComputePipelineState> resolve_eval_pipeline(",
        )
        destroy = function_body(
            self.source,
            "void stwo_zig_metal_runtime_destroy(",
            "void *stwo_zig_metal_merkle_commit(",
        )
        self.assertIn("if (!library.archiveDirty) return true", serialize)
        self.assertIn("library.archiveDirty = false", serialize)
        self.assertIn("sortedArrayUsingSelector:@selector(compare:)", destroy)
        self.assertIn("if (!library.archiveDirty) continue", destroy)
        self.assertIn("serialize_eval_archive(library, &error, &didSerialize)", destroy)

    def test_cache_counters_increment_only_at_observed_events(self):
        load = function_body(
            self.source,
            "void *stwo_zig_metal_eval_library_load(",
            "void *stwo_zig_metal_eval_library_compile(",
        )
        resolve = function_body(
            self.source,
            "static id<MTLComputePipelineState> resolve_eval_pipeline(",
            "void *stwo_zig_metal_eval_library_load(",
        )
        serialize = function_body(
            self.source,
            "bool stwo_zig_metal_eval_library_serialize(",
            "void stwo_zig_metal_eval_destroy(",
        )
        self.assertIn("runtime.evalLibraryCacheHits += 1u", load)
        self.assertIn("runtime.evalLibraryCacheMisses += 1u", load)
        compile_library = function_body(
            self.source,
            "void *stwo_zig_metal_eval_library_compile(",
            "void stwo_zig_metal_eval_library_destroy(",
        )
        self.assertIn("runtime.evalLibraryCacheHits += 1u", compile_library)
        self.assertIn("runtime.evalLibraryCacheMisses += 1u", compile_library)
        self.assertIn("runtime.evalPipelineCacheHits += 1u", resolve)
        self.assertIn("if (pipeline != nil) runtime.evalBinaryArchiveHits += 1u", resolve)
        self.assertLess(
            resolve.index("newComputePipelineStateWithFunction", resolve.index("MTLPipelineOptionFailOnBinaryArchiveMiss")),
            resolve.index("runtime.evalBinaryArchiveMisses += 1u"),
        )
        self.assertLess(
            resolve.index("addComputePipelineFunctionsWithDescriptor"),
            resolve.index("runtime.evalArchivePopulations += 1u"),
        )
        self.assertIn("runtime.evalDirectCompiles += 1u", resolve)
        self.assertIn("@finally", resolve)
        self.assertIn("runtime.evalPipelinePreparationSeconds +=", resolve)
        self.assertIn("if (didSerialize && runtimeOwner != nil)", serialize)
        self.assertIn("runtimeOwner.evalArchiveSerializations += 1u", serialize)

    def test_stats_abi_is_read_only_and_zero_initialized_in_zig(self):
        fields = (
            "library_cache_hits",
            "library_cache_misses",
            "pipeline_cache_hits",
            "binary_archive_hits",
            "binary_archive_misses",
            "direct_compiles",
            "archive_populations",
            "archive_serializations",
            "pipeline_preparation_seconds",
        )
        for field in fields:
            self.assertIn(field, self.source)
            self.assertIn(field, self.zig_abi_source)
        self.assertIn("pub const PipelineCacheStats = extern struct", self.zig_abi_source)
        self.assertIn("return std.mem.zeroes(PipelineCacheStats)", self.zig_abi_source)
        self.assertIn("pub const PipelineCacheStats = abi.PipelineCacheStats", self.zig_source)
        self.assertIn("pub fn pipelineCacheStats(self: *const Runtime)", self.zig_source)
        self.assertIn('test "pipeline cache stats zero value"', self.zig_abi_source)


if __name__ == "__main__":
    unittest.main()
