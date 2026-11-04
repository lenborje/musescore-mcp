"""Resolve bundled assets: the MuseScore plugin QML and the docs/ markdown files.

In a built wheel these live under musescore_mcp/assets/ (mapped in by
pyproject.toml at build time via force-include). In a repo checkout or an
editable install they are not in the package directory, so we fall back to
the repository root (src layout: <repo>/src/musescore_mcp/assets.py).
"""

from pathlib import Path

try:
    from importlib import resources
except ImportError:  # pragma: no cover - Python < 3.9 without the module
    resources = None  # type: ignore[assignment]

PLUGIN_FILENAME = "musescore-mcp-plugin.qml"
DOC_NAMES = ("ACTIONS.md", "AGENT-COOKBOOK.md", "INSTALL-PROMPT.md")


def _packaged_assets_dir() -> Path | None:
    if resources is None:
        return None
    try:
        base = Path(str(resources.files("musescore_mcp") / "assets"))
        if (base / PLUGIN_FILENAME).is_file():
            return base
    except Exception:
        pass
    return None


def _repo_root() -> Path | None:
    root = Path(__file__).resolve().parents[2]
    if (root / PLUGIN_FILENAME).is_file() and (root / "docs").is_dir():
        return root
    return None


def plugin_qml_path() -> Path:
    """Path to the bundled musescore-mcp-plugin.qml."""
    base = _packaged_assets_dir()
    if base:
        return base / PLUGIN_FILENAME
    root = _repo_root()
    if root:
        return root / PLUGIN_FILENAME
    raise FileNotFoundError(
        f"{PLUGIN_FILENAME} not found in package assets or repo checkout"
    )


def docs_dir() -> Path:
    """Directory containing ACTIONS.md, AGENT-COOKBOOK.md, INSTALL-PROMPT.md."""
    base = _packaged_assets_dir()
    if base and (base / "docs" / "ACTIONS.md").is_file():
        return base / "docs"
    root = _repo_root()
    if root:
        return root / "docs"
    raise FileNotFoundError("docs not found in package assets or repo checkout")


def read_doc(name: str) -> str:
    """Read one bundled document by file name (e.g. "AGENT-COOKBOOK.md")."""
    if name not in DOC_NAMES:
        raise ValueError(f"unknown doc {name!r}; available: {', '.join(DOC_NAMES)}")
    path = docs_dir() / name
    return path.read_text(encoding="utf-8")
