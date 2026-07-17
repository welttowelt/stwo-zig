from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE_PATH = ROOT / "src/backends/metal/runtime.m"
RECIPE_PATH = ROOT / "src/backends/metal/recipes/composition.zig"


def function_body(source: str, name: str, next_name: str) -> str:
    start = source.index(name)
    end = source.index(next_name, start)
    return source[start:end]


class MetalCompositionBatchingSourceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = SOURCE_PATH.read_text()
        cls.source = source
        cls.body = function_body(
            source,
            "bool stwo_zig_metal_composition_finalize_prepared(",
            "bool stwo_zig_metal_composition_prepared(",
        )
        cls.graph = function_body(
            source,
            "bool stwo_zig_metal_composition_prepared(",
            "bool stwo_zig_metal_eval_prepared(",
        )

    def test_standalone_finalize_has_one_production_and_two_diagnostic_waits(self):
        self.assertEqual(self.body.count("[production_command commit]"), 1)
        self.assertEqual(self.body.count("[production_command waitUntilCompleted]"), 1)
        self.assertEqual(self.body.count("[command commit]"), 2)
        self.assertEqual(self.body.count("[command waitUntilCompleted]"), 2)

    def test_ifft_layers_reuse_the_existing_command_buffer(self):
        loop_start = self.body.index(
            "for (uint32_t layer = 1u; layer < log_size; ++layer)"
        )
        loop_end = self.body.index("uint32_t factor = plan.scaleFactor", loop_start)
        loop = self.body[loop_start:loop_end]
        self.assertNotIn("commandBuffer", loop)
        self.assertNotIn("[command commit]", loop)
        self.assertNotIn("[command waitUntilCompleted]", loop)

    def test_finalize_dependency_order_is_preserved(self):
        first = self.body.index("runtime.circleIfftFirstSparse")
        layer = self.body.index("runtime.circleIfftLayerSparse", first)
        rescale = self.body.index("runtime.circleRescaleSparse", layer)
        split = self.body.index("runtime.compositionSplit", rescale)
        final_commit = self.body.index("[command commit]", split)
        self.assertLess(first, layer)
        self.assertLess(layer, rescale)
        self.assertLess(rescale, split)
        self.assertLess(split, final_commit)

    def test_production_graph_has_one_submission_and_one_wait(self):
        self.assertEqual(self.graph.count("[command commit]"), 1)
        self.assertEqual(self.graph.count("[command waitUntilCompleted]"), 1)
        front = self.graph.index("encode_composition_front_production")
        finalize = self.graph.index("encode_composition_finalize_production", front)
        commit = self.graph.index("[command commit]", finalize)
        self.assertLess(front, finalize)
        self.assertLess(finalize, commit)

    def test_encoding_nodes_do_not_submit_or_wait(self):
        front = function_body(
            self.source,
            "static void encode_composition_front_production(",
            "bool stwo_zig_metal_composition_front_prepared(",
        )
        finalize = function_body(
            self.source,
            "static void encode_composition_finalize_production(",
            "bool stwo_zig_metal_composition_finalize_prepared(",
        )
        for node in (front, finalize):
            self.assertNotIn("[command commit]", node)
            self.assertNotIn("[command waitUntilCompleted]", node)

    def test_complete_recipe_uses_combined_graph_and_partial_diagnostic_uses_front(self):
        recipe = RECIPE_PATH.read_text()
        start = recipe.index("pub const Recipe = struct")
        body = recipe[start:]
        branch = body.index("self.accumulated_gpu_ms += if (self.complete)")
        combined = body.index("self.metal.compositionPrepared(", branch)
        diagnostic = body.index("self.metal.compositionFrontPrepared(", combined)
        self.assertLess(branch, combined)
        self.assertLess(combined, diagnostic)
        self.assertIn(
            "if (!self.complete) return recovery.RecoveryError.MissingRecipe;",
            body,
        )
        self.assertNotIn("self.metal.compositionFinalizePrepared(", body)


if __name__ == "__main__":
    unittest.main()
