import os
import struct
import tempfile
import unittest
from unittest import mock

import runner


def gguf(pairs):
    """A tiny GGUF header with string metadata, enough for gguf_metadata()."""
    def string(text):
        data = text.encode()
        return struct.pack("<Q", len(data)) + data
    body = b"".join(string(k) + struct.pack("<I", 8) + string(v) for k, v in pairs)
    return b"GGUF" + struct.pack("<IQQ", 3, 0, len(pairs)) + body


class GGUFTests(unittest.TestCase):
    def test_reads_adapter_metadata(self):
        meta = runner.gguf_metadata(gguf([("general.architecture", "qwen35"), ("general.type", "adapter")]))
        self.assertEqual(meta, {"general.architecture": "qwen35", "general.type": "adapter"})

    def test_stops_quietly_where_the_data_ends(self):
        data = gguf([("general.architecture", "qwen3"), ("tokenizer.ggml.model", "gpt2")])
        self.assertEqual(runner.gguf_metadata(data[:-3]), {"general.architecture": "qwen3"})

    def test_rejects_other_files(self):
        with self.assertRaises(ValueError):
            runner.gguf_metadata(b"PK\x03\x04 not a gguf")


class AdapterNamingTests(unittest.TestCase):
    def test_refs_and_links(self):
        self.assertEqual(runner.parse_adapter_ref("acme/brand-lora"), ("acme/brand-lora", None))
        self.assertEqual(runner.parse_adapter_ref("https://huggingface.co/acme/brand-lora/blob/main/a-f16.gguf"),
                         ("acme/brand-lora", "a-f16.gguf"))
        self.assertEqual(runner.parse_adapter_ref("hf.co/acme/brand-lora/tree/main/adapter"), ("acme/brand-lora", "adapter"))
        for bad in ["", "justone", "acme/../etc", "acme/brand lora"]:
            with self.assertRaises(ValueError, msg=bad):
                runner.parse_adapter_ref(bad)

    def test_base_must_come_from_hugging_face(self):
        self.assertEqual(runner.hf_base("ollama/hf.co/unsloth/Qwen3.5-9B-GGUF:Q4_K_M"), ("unsloth/Qwen3.5-9B-GGUF", "Q4_K_M"))
        with self.assertRaises(ValueError):
            runner.hf_base("ollama/qwen3:4b")

    def test_model_name(self):
        self.assertEqual(runner.adapter_model_name("acme/Brand-Voice-LoRA", "hf.co/unsloth/Qwen3.5-9B-GGUF:Q4_K_M"),
                         "lora/brand-voice-lora:qwen3.5-9b")

    def test_matching(self):
        base = {"architecture": "qwen35"}
        self.assertFalse(runner.adapter_matches({"architecture": "llama"}, base, "Qwen/Qwen3.5-9B"), "another architecture")
        self.assertTrue(runner.adapter_matches({"base_model": "unsloth/Qwen3.5-9B-bnb-4bit"}, base, "Qwen/Qwen3.5-9B"))
        self.assertFalse(runner.adapter_matches({"base_model": "Qwen/Qwen3-4B-Instruct-2507"}, base, "Qwen/Qwen3.5-9B"))
        self.assertIsNone(runner.adapter_matches({"architecture": "qwen35"}, base, "Qwen/Qwen3.5-9B"), "same family, size unknown")


class LoRAServerTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.patch = mock.patch.object(runner, "LORA_DIR", self.dir)
        self.patch.start()
        self.lora = runner.LoRAServer()

    def tearDown(self):
        self.patch.stop()

    def entry(self, name, base, path):
        open(path, "w").close()
        return {"name": name, "base": base, "path": path, "repo": "acme/x", "format": "gguf", "display": name}

    def test_each_request_turns_on_only_its_adapter(self):
        base = "hf.co/unsloth/Qwen3.5-9B-GGUF:Q4_K_M"
        a, b = os.path.join(self.dir, "a.gguf"), os.path.join(self.dir, "b.gguf")
        self.lora.add(self.entry("lora/a:qwen3.5-9b", base, a))
        self.lora.add(self.entry("lora/b:qwen3.5-9b", base, b))
        self.lora.add(self.entry("lora/c:other", "hf.co/x/Other-GGUF:Q4_K_M", os.path.join(self.dir, "c.gguf")))
        with mock.patch.object(self.lora, "ensure", lambda base: [a, b]):
            body = self.lora.chat_body("lora/b:qwen3.5-9b", {"messages": [], "stream": True})
        self.assertEqual(body["lora"], [{"id": 0, "scale": 0.0}, {"id": 1, "scale": 1.0}])
        self.assertTrue(body["stream"])
        self.assertEqual(body["chat_template_kwargs"], {"enable_thinking": False}, "answers, not hidden thinking")
        with self.assertRaises(ValueError):
            self.lora.chat_body("lora/missing:x", {})

    def test_remove_deletes_the_file_and_the_listing(self):
        path = os.path.join(self.dir, "a.gguf")
        self.lora.add(self.entry("lora/a:qwen3.5-9b", "hf.co/u/Q-GGUF:Q4_K_M", path))
        self.assertEqual([a["name"] for a in self.lora.adapters()], ["lora/a:qwen3.5-9b"])
        self.assertTrue(self.lora.remove("lora/a:qwen3.5-9b"))
        self.assertEqual(self.lora.adapters(), [])
        self.assertFalse(os.path.exists(path))
        self.assertFalse(self.lora.remove("lora/a:qwen3.5-9b"))

    def test_models_list_has_each_adapter(self):
        self.lora.add(self.entry("lora/a:qwen3.5-9b", "hf.co/u/Q-GGUF:Q4_K_M", os.path.join(self.dir, "a.gguf")))
        with mock.patch.object(runner, "LORA", self.lora), mock.patch.object(runner, "IN_CONTAINER", False), \
                mock.patch.object(runner, "backend_status", lambda: {}):
            ids = [m["id"] for m in runner.list_models()]
        self.assertIn("lora/a:qwen3.5-9b", ids)


if __name__ == "__main__":
    unittest.main()
