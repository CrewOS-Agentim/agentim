import unittest

import runner

GB = 1024 ** 3


class AssessTests(unittest.TestCase):
    def check(self, weights, available, ceiling=20 * GB, disk=100 * GB):
        return runner.assess(weights, total=24 * GB, available=available, ceiling=ceiling, free_disk=disk)

    def test_fits(self):
        self.assertEqual(self.check(4 * GB, 16 * GB)["verdict"], "fits")

    def test_tight(self):
        result = self.check(8 * GB, 6 * GB)
        self.assertEqual(result["verdict"], "tight")
        self.assertTrue(result["can_pull"])

    def test_too_large(self):
        result = self.check(40 * GB, 16 * GB)
        self.assertEqual(result["verdict"], "too_large")
        self.assertFalse(result["can_pull"])

    def test_not_enough_disk(self):
        self.assertEqual(self.check(4 * GB, 16 * GB, disk=2 * GB)["verdict"], "not_enough_disk")


class RefTests(unittest.TestCase):
    def test_library(self):
        self.assertEqual(runner.parse_ollama_ref("qwen3:0.6b"), ("registry.ollama.ai", "library/qwen3", "0.6b"))
        self.assertEqual(runner.parse_ollama_ref("llama3.2"), ("registry.ollama.ai", "library/llama3.2", "latest"))

    def test_user_namespace(self):
        self.assertEqual(runner.parse_ollama_ref("someone/model:7b"), ("registry.ollama.ai", "someone/model", "7b"))

    def test_hugging_face(self):
        self.assertEqual(runner.parse_ollama_ref("hf.co/bartowski/X-GGUF:Q8_0"), ("hf.co", "bartowski/X-GGUF", "Q8_0"))
        self.assertEqual(runner.parse_ollama_ref("hf.co/bartowski/X-GGUF")[2], "Q4_K_M")

    def test_gguf_size_sums_split_files(self):
        files = [
            {"path": "m-Q4_K_M-00001-of-00002.gguf", "size": 10},
            {"path": "m-Q4_K_M-00002-of-00002.gguf", "size": 5},
            {"path": "m-Q8_0.gguf", "size": 99},
            {"path": "README.md", "size": 1},
        ]
        self.assertEqual(runner.gguf_size(files, "Q4_K_M"), 15)
        with self.assertRaises(ValueError):
            runner.gguf_size(files, "Q2_K")


class MemoryTests(unittest.TestCase):
    def test_host_memory_is_sane(self):
        total, available, ceiling = runner.host_memory()
        self.assertGreater(total, 0)
        self.assertLessEqual(available, total)
        self.assertLessEqual(ceiling, total)


if __name__ == "__main__":
    unittest.main()
