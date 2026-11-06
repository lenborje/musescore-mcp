"""Locate user plugin directories without requiring Qt or a running MuseScore."""

import os
from pathlib import Path
import shlex
import sys


def _windows_documents_dir() -> Path | None:
    """Ask Windows for Documents, including OneDrive/folder redirection."""
    import ctypes
    from uuid import UUID

    try:
        shell = ctypes.WinDLL("shell32")
        ole = ctypes.WinDLL("ole32")
        get_path = shell.SHGetKnownFolderPath
        get_path.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_void_p,
                             ctypes.POINTER(ctypes.c_void_p)]
        get_path.restype = ctypes.c_long
        free = ole.CoTaskMemFree
        free.argtypes = [ctypes.c_void_p]
        free.restype = None
        # FOLDERID_Documents, with Windows GUID byte order.
        folder = (ctypes.c_ubyte * 16).from_buffer_copy(
            UUID("fdd39ad0-238f-46af-adb4-6c85480369c7").bytes_le)
        pointer = ctypes.c_void_p()
        try:
            if get_path(ctypes.byref(folder), 0, None, ctypes.byref(pointer)) == 0 and pointer.value:
                return Path(ctypes.wstring_at(pointer))
        finally:
            if pointer.value:
                free(pointer)
    except (OSError, AttributeError):
        pass
    return None


def documents_dir() -> Path:
    home = Path.home()
    if sys.platform == "win32":
        return _windows_documents_dir() or home / "Documents"
    if sys.platform.startswith("linux"):
        config_home = Path(os.environ.get("XDG_CONFIG_HOME") or home / ".config")
        if not config_home.is_absolute():
            config_home = home / ".config"
        try:
            lines = (config_home / "user-dirs.dirs").read_text(encoding="utf-8").splitlines()
            for line in lines:
                key, sep, value = line.strip().partition("=")
                if sep and key.strip() == "XDG_DOCUMENTS_DIR":
                    # Parse data only; never source the file or execute a shell.
                    values = shlex.split(value, comments=True)
                    if len(values) == 1:
                        path = Path(values[0].replace("${HOME}", str(home)).replace("$HOME", str(home)))
                        if path.is_absolute():
                            return path
        except (OSError, UnicodeError, ValueError):
            pass
    return home / "Documents"


def plugin_dirs(override: str | None = None) -> list[Path]:
    """Explicit flag > environment > OS Documents; legacy Linux paths are diagnostic only.

    MuseScore's custom plugin-folder preference is not inferred. Callers should
    use the explicit override when that preference differs from the default.
    """
    selected = override if override is not None else os.environ.get("MUSESCORE_MCP_PLUGIN_DIR")
    if selected is not None:
        if not selected.strip():
            raise ValueError("Plugin directory must not be empty")
        return [Path(selected).expanduser().absolute()]
    paths = [documents_dir() / "MuseScore4" / "Plugins"]
    if sys.platform.startswith("linux"):
        home = Path.home()
        paths.extend([home / ".local/share/MuseScore/MuseScore4/Plugins",
                      home / ".config/MuseScore/MuseScore4/plugins"])
    return list(dict.fromkeys(paths))
