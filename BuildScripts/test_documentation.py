#!/usr/bin/env python3
"""Offline stdlib documentation checks; never import model/server dependencies.

Supports the conventional inline/reference links, ATX headings and explicit HTML
anchors used in this repository. This is not a complete CommonMark renderer,
external-link checker, installation test, or CUDA/phone validation.
"""
import ast
import html
from pathlib import Path
import re
import subprocess
import tempfile
import unicodedata
import unittest
from urllib.parse import unquote, urlsplit


ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "https://github.com/FBKmai/PicaX-private"
BRANCH = "iphone-duo-ios27"
CLONE = f"git clone --branch {BRANCH} {REPOSITORY}.git"
PAGES = (
    "README.md", "CONTRIBUTING.md", "SECURITY.md", "Docs/LanSuperResolution.md",
    "Docs/Development.md", "Docs/Architecture.md", "Docs/HATOptimization.md",
    "Docs/SuperResolution.md",
)


def markdown_parts(text):
    """Return prose and fenced blocks, without treating code examples as links."""
    prose, blocks, code = [], [], []
    fence = None
    for line in text.splitlines():
        if fence is not None:
            closing = rf"^ {{0,3}}{re.escape(fence[0])}{{{len(fence)},}}\s*$"
            if re.match(closing, line):
                blocks.append("\n".join(code))
                code, fence = [], None
            else:
                code.append(line)
            prose.append("")
            continue
        opening = re.match(r"^ {0,3}(`{3,}|~{3,})(.*)$", line)
        if opening:
            fence = opening[1]
            prose.append("")
        else:
            prose.append(line)
    if fence is not None:
        blocks.append("\n".join(code))
    return "\n".join(prose), blocks


def link_targets(text):
    prose, _ = markdown_parts(text)
    prose = re.sub(r"(`+).*?\1", "", prose)
    inline = re.compile(
        r'''\]\(\s*(<[^>\n]+>|(?:\\.|[^()\s]|\([^()\n]*\))+)'''
        r'''(?:[ \t]+["'][^\n]*?["'])?[ \t]*\)''')
    reference = re.compile(r"^ {0,3}\[[^\]\n]+\]:\s*(<[^>\n]+>|\S+)", re.MULTILINE)
    for pattern in (inline, reference):
        for match in pattern.finditer(prose):
            target = match[1].strip("<>")
            yield html.unescape(re.sub(r"\\([()])", r"\1", target))


def heading_slug(heading):
    heading = re.sub(r"<[^>]*>", "", html.unescape(heading)).strip().lower()
    # GitHub retains Unicode letters/numbers and -/_, but drops punctuation.
    heading = "".join(char for char in heading
                      if char in " -_" or unicodedata.category(char)[0] in "LMN")
    return heading.replace(" ", "-")


def anchors(text):
    prose, _ = markdown_parts(text)
    result = set(re.findall(r'''\b(?:id|name)=["']([^"']+)["']''', prose))
    generated = set()
    for match in re.finditer(r"^ {0,3}#{1,6}\s+(.+?)\s*#*\s*$", prose, re.MULTILINE):
        base = heading_slug(match[1])
        candidate, suffix = base, 0
        while candidate in generated:
            suffix += 1
            candidate = f"{base}-{suffix}"
        generated.add(candidate)
    return result | generated


def local_link_errors(page, text, root):
    errors = []
    for target in link_targets(text):
        url = urlsplit(target)
        if url.scheme or url.netloc:
            continue  # No network access; external existence is not tested.
        path = unquote(url.path)
        resolved = ((root / path.lstrip("/")) if path.startswith("/")
                    else (page.parent / path if path else page)).resolve()
        if not resolved.is_relative_to(root.resolve()):
            errors.append(f"{target}: outside repository")
        elif not resolved.exists():
            errors.append(f"{target}: missing target")
        elif url.fragment and resolved.suffix.lower() == ".md":
            if unquote(url.fragment) not in anchors(resolved.read_text(encoding="utf-8")):
                errors.append(f"{target}: missing anchor")
    return errors


def argument_contract(source):
    """Read argparse declarations with AST; do not import or execute the CLI."""
    options = {}
    for node in ast.walk(ast.parse(source)):
        if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                and node.func.attr == "add_argument"):
            continue
        metadata = {}
        for item in node.keywords:
            try:
                metadata[item.arg] = ast.literal_eval(item.value)
            except (ValueError, TypeError):
                pass  # e.g. Path, ALIASES or DEFAULT_WINDOW_BATCH
        for item in node.args:
            if isinstance(item, ast.Constant) and isinstance(item.value, str) and item.value.startswith("--"):
                options[item.value] = metadata
    return options


def command_errors(command, contract):
    used = set(re.findall(r"(?<![\w-])--[a-z][a-z0-9-]*", command))
    errors = [f"unknown option {option}" for option in sorted(used - contract.keys())]
    errors.extend(f"missing required option {option}" for option, spec in contract.items()
                  if spec.get("required") and option not in used)
    return errors


class ParserTests(unittest.TestCase):
    def test_fences_and_inline_code_are_not_links(self):
        text = "[real](README.md)\n```md\n[no](missing.md)\n```\n`[no](also.md)`"
        self.assertEqual(list(link_targets(text)), ["README.md"])
        self.assertEqual(markdown_parts("~~~text\nx\n~~~")[1], ["x"])

    def test_link_forms_and_external_urls(self):
        text = '[x](<a b.md#测试> "title")\n![x](image.png)\n[x][ref]\n[ref]: guide.md#here\n[x](https://example.org/a_(b))'
        self.assertEqual(list(link_targets(text)),
                         ["a b.md#测试", "image.png", "https://example.org/a_(b)", "guide.md#here"])

    def test_nested_badge_link_checks_both_destinations(self):
        text = '[![License](https://example.org/badge.svg)](LICENSE)'
        self.assertEqual(list(link_targets(text)), ["https://example.org/badge.svg", "LICENSE"])

    def test_heading_unicode_duplicates_and_explicit_ids(self):
        text = '# 获取手机 App\n## `Name` & More!\n## 获取手机 App\n<a id="tests"></a>\n```\n# fake\n```'
        self.assertEqual(anchors(text), {"获取手机-app", "name--more", "获取手机-app-1", "tests"})

    def test_missing_anchor_file_and_repository_escape(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            page = root / "index.md"
            page.write_text("# 中文 Heading\n", encoding="utf-8")
            self.assertEqual(local_link_errors(page, "[ok](#%E4%B8%AD%E6%96%87-heading)", root), [])
            errors = local_link_errors(page, "[x](none.md) [x](#absent) [x](../outside.md)", root)
            self.assertEqual(len(errors), 3)
            self.assertIn("outside repository", errors[2])

    def test_argument_inspection_does_not_execute_source(self):
        source = '''raise RuntimeError("must not execute")
parser.add_argument("--path", required=True)
parser.add_argument("--precision", default="float32", choices=["float32", "bfloat16"])
'''
        contract = argument_contract(source)
        self.assertEqual(contract["--precision"]["default"], "float32")
        self.assertEqual(command_errors("--path x --precision bfloat16", contract), [])
        self.assertEqual(command_errors("--typo", contract),
                         ["unknown option --typo", "missing required option --path"])


class DocumentationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Enumerate git paths, never recursively walk .venv, weights or user data.
        result = subprocess.run(
            ["git", "-C", str(ROOT), "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", "*.md"],
            check=True, capture_output=True)
        cls.markdown = sorted(set(result.stdout.decode("utf-8").rstrip("\0").split("\0")))
        cls.pages = {path: (ROOT / path).read_text(encoding="utf-8") for path in PAGES}

    def test_relative_links_and_anchors(self):
        self.assertTrue(self.markdown)
        for relative in self.markdown:
            page = ROOT / relative
            with self.subTest(page=relative):
                self.assertTrue(page.resolve().is_relative_to(ROOT), "Markdown must stay inside repository")
                self.assertTrue(page.is_file(), "Tracked Markdown is missing")
                errors = local_link_errors(page, page.read_text(encoding="utf-8"), ROOT)
                self.assertEqual(errors, [], "\n".join(errors))

    def test_homepage_navigation_and_source_identity(self):
        readme = self.pages["README.md"]
        targets = set(link_targets(readme))
        for page in PAGES[1:]:
            self.assertIn(page, targets)
        for path in ("README.md", "Docs/LanSuperResolution.md", "Docs/Development.md"):
            with self.subTest(page=path):
                self.assertIn(CLONE, self.pages[path])
                self.assertNotIn("git clone https://github.com/youshen2/PicaX", self.pages[path])
        self.assertIn(f"{REPOSITORY}/actions/workflows/build-iphone-duo.yml", readme)
        for workflow in re.findall(r"actions/workflows/([\w-]+\.yml)", readme):
            self.assertTrue((ROOT / ".github/workflows" / workflow).is_file(), workflow)

    def test_documented_desktop_commands_match_real_options(self):
        scripts = {
            "start-server.cmd": "DesktopServer/picax_lan/cli.py",
            "fetch_models.py": "DesktopServer/fetch_models.py",
            "validate_local.py": "DesktopServer/validate_local.py",
            "validate_transport.py": "DesktopServer/validate_transport.py",
        }
        seen = set()
        pattern = re.compile(r"DesktopServer[\\/](start-server\.cmd|fetch_models\.py|validate_local\.py|validate_transport\.py)\b([^\n]*)")
        for page in ("Docs/LanSuperResolution.md", "Docs/Development.md"):
            for block in markdown_parts(self.pages[page])[1]:
                for match in pattern.finditer(block.replace("\\\n", "")):
                    script, command = match.groups()
                    contract = argument_contract((ROOT / scripts[script]).read_text(encoding="utf-8"))
                    with self.subTest(page=page, script=script, command=command):
                        self.assertEqual(command_errors(command, contract), [])
                        if script == "start-server.cmd" and "--cleanup" not in command:
                            for required in ("--host", "--weights-dir", "--accept-noncommercial-license"):
                                self.assertIn(required, command)
                    seen.add(script)
        self.assertEqual(seen, set(scripts))

    def test_recommended_defaults_and_weight_identity(self):
        contract = argument_contract((ROOT / "DesktopServer/picax_lan/cli.py").read_text(encoding="utf-8"))
        self.assertEqual(contract["--precision"]["default"], "float32")
        self.assertEqual(contract["--hat-attention-backend"]["default"], "eager")
        source = (ROOT / "DesktopServer/picax_lan/hat_memory.py").read_text(encoding="utf-8")
        defaults = {node.targets[0].id: ast.literal_eval(node.value) for node in ast.parse(source).body
                    if isinstance(node, ast.Assign) and len(node.targets) == 1
                    and isinstance(node.targets[0], ast.Name) and node.targets[0].id == "DEFAULT_WINDOW_BATCH"}
        self.assertEqual(defaults["DEFAULT_WINDOW_BATCH"], 128)
        deployment = self.pages["Docs/LanSuperResolution.md"]
        for fragment in ("--model-precision hat-l=bfloat16", "--hat-window-batch 128",
                         "--hat-attention-backend eager", "hat-window-batched-v2",
                         "requirements-windows-cu128.txt", "pip check"):
            self.assertIn(fragment, deployment)
        models = (ROOT / "DesktopServer/picax_lan/models.py").read_text(encoding="utf-8")
        for value in ("38c00c9ff871ae292617ae1127edc150f81c4e0f8f98685e48ff9c9cd87fba3b",
                      "4x_IllustrationJaNai_V3detail_HAT_L_28k_bf16.safetensors"):
            self.assertIn(value, models)
            self.assertIn(value, deployment)
            self.assertIn(value, self.pages["Docs/HATOptimization.md"])

    def test_release_notes_keep_app_list_format(self):
        lines = (ROOT / "RELEASE_NOTES.md").read_text(encoding="utf-8").splitlines()
        self.assertTrue(lines)
        for number, line in enumerate(lines, 1):
            with self.subTest(line=number):
                self.assertTrue(line.strip().startswith("- ") and line.strip()[2:].strip(),
                                "App release notes require a nonempty bullet on every line")

    def test_security_and_historical_paths_are_explicit(self):
        for page in ("README.md", "Docs/LanSuperResolution.md", "SECURITY.md"):
            with self.subTest(page=page):
                text = self.pages[page]
                self.assertIn("HTTP", text)
                self.assertIn("可信局域网", text)
                self.assertRegex(text, r"无认证|无密码|没有访问密码")
        self.assertIn("历史研究", self.pages["Docs/SuperResolution.md"])
        self.assertIn("不是电脑 HAT-L", self.pages["Docs/SuperResolution.md"])
        self.assertIn("过期", self.pages["README.md"])
        self.assertIn("不能用它判断或升级本衍生版本", self.pages["README.md"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
