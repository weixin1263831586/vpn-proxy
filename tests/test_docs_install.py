"""Keep the documented installer download patterns honest about failures."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
DOCS = [ROOT / "README.md", ROOT / "docs/operations.md"]


def installer_blocks(text):
    return [block for block in re.findall(r"```bash\n(.*?)```", text, flags=re.S)
            if "mktemp" in block and ("curl" in block or "ssh" in block)]


class DocumentedDownloadPatterns(unittest.TestCase):
    def test_docs_never_source_installer_through_process_substitution(self):
        for doc in DOCS:
            with self.subTest(doc=doc.name):
                content = doc.read_text(encoding="utf-8")
                self.assertGreaterEqual(len(installer_blocks(content)), 1)
                for block in re.findall(r"```bash\n(.*?)```", content, flags=re.S):
                    self.assertNotIn("source <(", block)
                    self.assertNotIn("| bash", block)

    def test_documented_blocks_fail_when_the_download_fails(self):
        for doc in DOCS:
            content = doc.read_text(encoding="utf-8")
            for index, block in enumerate(installer_blocks(content)):
                with self.subTest(doc=doc.name, block=index):
                    with tempfile.TemporaryDirectory() as directory:
                        stubs = Path(directory)
                        for name, code in (("curl", "exit 22\n"), ("ssh", "exit 255\n")):
                            (stubs / name).write_text(f"#!/bin/bash\n{code}")
                            (stubs / name).chmod(0o755)
                        env = dict(os.environ, PATH=f"{stubs}:{os.environ['PATH']}")
                        result = subprocess.run(["bash", "-c", block], env=env,
                                                capture_output=True, text=True)
                        self.assertNotEqual(result.returncode, 0, block)
                        self.assertIn("下载安装脚本失败", result.stderr)

    def test_documented_blocks_propagate_installer_failure(self):
        curl_stub = ('#!/bin/bash\n'
                     'out=""\nprev=""\n'
                     'for arg in "$@"; do [ "$prev" = "-o" ] && out="$arg"; prev="$arg"; done\n'
                     'printf \'echo MARKER_RAN\\nreturn 7\\n\' > "$out"\n')
        ssh_stub = "#!/bin/bash\nprintf 'echo MARKER_RAN\\nreturn 7\\n'\n"
        for doc in DOCS:
            content = doc.read_text(encoding="utf-8")
            for index, block in enumerate(installer_blocks(content)):
                with self.subTest(doc=doc.name, block=index):
                    with tempfile.TemporaryDirectory() as directory:
                        stubs = Path(directory)
                        for name, code in (("curl", curl_stub), ("ssh", ssh_stub)):
                            (stubs / name).write_text(code)
                            (stubs / name).chmod(0o755)
                        env = dict(os.environ, PATH=f"{stubs}:{os.environ['PATH']}")
                        result = subprocess.run(["bash", "-c", block], env=env,
                                                capture_output=True, text=True)
                        self.assertNotEqual(result.returncode, 0, block + result.stderr)
                        self.assertIn("MARKER_RAN", result.stdout)
                        self.assertNotIn("下载安装脚本失败", result.stderr)


if __name__ == "__main__":
    unittest.main()
