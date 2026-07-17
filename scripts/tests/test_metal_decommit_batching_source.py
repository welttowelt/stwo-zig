from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
RUNTIME = ROOT / "src/backends/metal/runtime.m"
RECIPES = ROOT / "src/backends/metal/protocol_recipes.zig"
SCHEDULE_BINDINGS = ROOT / "src/integrations/cairo_metal/schedule_bindings.zig"


def function_body(source: str, name: str, next_name: str) -> str:
    start = source.index(name)
    end = source.index(next_name, start)
    return source[start:end]


class MetalDecommitBatchingSourceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        runtime = RUNTIME.read_text()
        cls.graph = function_body(
            runtime,
            "bool stwo_zig_metal_decommit_trace_group(",
            "bool stwo_zig_metal_decommit_assemble_trace(",
        )
        recipes = RECIPES.read_text()
        start = recipes.index("pub const DecommitQueryRecipe = struct")
        end = recipes.index("/// Exact Cairo transcript controller", start)
        cls.recipe = recipes[start:end]

    def test_trace_group_uses_one_submission_and_wait(self):
        self.assertEqual(self.graph.count("[command commit]"), 1)
        self.assertEqual(self.graph.count("[command waitUntilCompleted]"), 1)

    def test_gather_precedes_sparse_leaf_in_the_same_command(self):
        command = self.graph.index("id<MTLCommandBuffer> command")
        gather = self.graph.index("decommitGatherTraceValuesResident", command)
        leaves = self.graph.index("decommitSparseLeafGroupResident", gather)
        commit = self.graph.index("[command commit]", leaves)
        self.assertLess(command, gather)
        self.assertLess(gather, leaves)
        self.assertLess(leaves, commit)

    def test_recipe_defers_gather_and_executes_the_combined_graph(self):
        gather = function_body(
            self.recipe,
            "pub fn gatherTraceValues(",
            "pub fn sparseParent(",
        )
        sparse = function_body(
            self.recipe,
            "pub fn sparseLeafGroup(",
            "pub fn assembleTrace(",
        )
        self.assertIn("self.pending_trace_gather =", gather)
        self.assertNotIn("decommitGatherTraceValues(", gather)
        self.assertIn("self.metal.decommitTraceGroup(", sparse)
        self.assertIn("self.pending_trace_gather = null", sparse)

    def test_sn2_schedule_has_370_fused_trace_groups(self):
        source = SCHEDULE_BINDINGS.read_text()
        match = re.search(
            r"decommit_trace_groups_by_tree\s*=\s*\[[^]]+\]\w+\{\s*([^}]+)\}",
            source,
        )
        self.assertIsNotNone(match)
        groups = [int(value.strip()) for value in match.group(1).split(",") if value.strip()]
        self.assertEqual(groups, [11, 216, 142, 1])
        self.assertEqual(sum(groups), 370)


if __name__ == "__main__":
    unittest.main()
