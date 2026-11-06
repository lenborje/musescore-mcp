"""Command-line interface for musescore-mcp.

Subcommands:
  serve             run the MCP server (default when invoked with no arguments;
                    this is what MCP hosts register)
  install-plugin    copy the bundled MuseScore plugin into MuseScore's plugin
                    directory (--allow-eval to enable run_qml)
  doctor            check the installation (python, deps, tools, plugin
                    version, live WebSocket probe)
  set-mixer-sound   offline .mscz mixer-sound surgery (run with MuseScore closed)
  docs              print a bundled document (cookbook, actions, install-prompt)
"""

import argparse
import asyncio
import json
import re
import sys

import websockets

from . import __version__, assets, set_mixer_sound
from .installation import plugin_dirs

PLUGIN_FILENAME = "musescore-mcp-plugin.qml"
EXPECTED_TOOLS = 7

DOC_ALIASES = {
    "cookbook": "AGENT-COOKBOOK.md",
    "actions": "ACTIONS.md",
    "install-prompt": "INSTALL-PROMPT.md",
}


def _candidate_plugin_dirs(override=None):
    return plugin_dirs(override)


# --- subcommands -----------------------------------------------------------

def cmd_serve(_args):
    from .server import main as serve_main
    serve_main()


def cmd_install_plugin(args):
    src = assets.plugin_qml_path()
    content = src.read_text(encoding="utf-8")

    if args.allow_eval:
        needle = "property bool allowEval: false"
        if content.count(needle) != 1:
            sys.exit(f"error: expected exactly one {needle!r} in {src}")
        content = content.replace(needle, "property bool allowEval: true")

    target_dir = _candidate_plugin_dirs(args.plugin_dir)[0]
    dest = target_dir / PLUGIN_FILENAME

    if args.dry_run:
        print(f"dry run - would install:")
        print(f"  from:  {src}")
        print(f"  to:    {dest}")
        print(f"  allowEval: {'true' if args.allow_eval else 'false'}")
        print("  Match this directory to MuseScore Preferences > General > Folders > Plugins.")
        return

    target_dir.mkdir(parents=True, exist_ok=True)
    if dest.exists():
        backup = dest.with_name(dest.name + ".bak")
        backup.write_bytes(dest.read_bytes())
        print(f"backed up existing plugin to {backup}")
    dest.write_text(content, encoding="utf-8")
    print(f"installed {dest}")
    print(f"  source: {src}")
    print(f"  plugin version: {__version__}, allowEval: {'true' if args.allow_eval else 'false'}")
    print()
    print("Next steps (GUI - needs a human):")
    print("  1. Check Preferences > General > Folders > Plugins matches the directory above.")
    print("     For a custom folder, pass --plugin-dir to install-plugin and doctor.")
    print("  2. If MuseScore was running during the copy: fully quit and restart it")
    print("     (plugin QML is cached for the lifetime of the process).")
    print("  3. Plugins > Manage plugins: enable \"MuseScore API Server\".")
    print("  4. Open a score, then Plugins > MuseScore API Server each session.")


def cmd_doctor(args):
    ok = True
    print(f"musescore-mcp {__version__}")

    if sys.version_info < (3, 12):
        print(f"[FAIL] Python {sys.version.split()[0]} - 3.12+ required "
              "(typing.TypedDict schema generation needs 3.12)")
        ok = False
    else:
        print(f"[ok] Python {sys.version.split()[0]}")

    try:
        import mcp
        import websockets
        print(f"[ok] dependencies: mcp {getattr(mcp, '__version__', '?')}, "
              f"websockets {getattr(websockets, '__version__', '?')}")
    except Exception as e:
        print(f"[FAIL] dependency import: {e}")
        ok = False

    try:
        from .server import MuseScoreMCP
        tools = asyncio.run(MuseScoreMCP().mcp.list_tools())
        if len(tools) == EXPECTED_TOOLS:
            print(f"[ok] MCP server: {len(tools)} tools")
        else:
            print(f"[FAIL] MCP server: expected {EXPECTED_TOOLS} tools, got {len(tools)}")
            ok = False
    except Exception as e:
        print(f"[FAIL] MCP server init: {e}")
        ok = False

    dirs = _candidate_plugin_dirs(args.plugin_dir)
    for directory in dirs:
        print(f"[info] plugin search directory: {directory}")
    installed = [d / PLUGIN_FILENAME for d in dirs
                 if (d / PLUGIN_FILENAME).is_file()]
    if not installed:
        print("[warn] plugin not installed - run `musescore-mcp install-plugin` "
              "(informational; install it before using the MCP tools)")
    if len(installed) > 1:
        print("[warn] multiple plugin copies found; keep only the copy in MuseScore's configured folder")
    for pth in installed:
        if pth.parent != dirs[0]:
            print(f"[warn] legacy plugin location: {pth.parent}; verify MuseScore's plugin folder "
                  "and reinstall there with --plugin-dir if needed")
        try:
            content = pth.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as error:
            print(f"[FAIL] cannot read plugin {pth}: {error}")
            ok = False
            continue
        m = re.search(r'property string pluginVersion: "([^"]+)"',
                      content)
        pv = m.group(1) if m else "unknown (pre-1.0 plugin)"
        if m and pv == __version__:
            print(f"[ok] plugin {pth} (version {pv})")
        else:
            print(f"[warn] plugin {pth} has version {pv}, expected {__version__} - "
                  "run `musescore-mcp install-plugin` (then restart MuseScore)")

    from .server import _environment_settings
    host, port, timeout = _environment_settings()
    uri = f"ws://{host}:{port}"
    try:
        async def probe():
            async with websockets.connect(uri, open_timeout=min(timeout, 1.5)) as ws:
                await ws.send('{"action": "ping", "params": {}}')
                return json.loads(await asyncio.wait_for(ws.recv(), timeout=min(timeout, 1.5)))

        resp = asyncio.run(probe())
        if not isinstance(resp, dict) or resp.get("status") != "success" or resp.get("result") != "pong":
            print(f"[FAIL] unexpected ping response from {uri}")
            ok = False
        else:
            pv = resp.get("pluginVersion", "?")
            label = "ok" if pv == __version__ else "warn"
            print(f"[{label}] live plugin reachable on {uri} "
                  f"(pluginVersion {pv}{', MISMATCH' if pv != __version__ else ''})")
    except (json.JSONDecodeError, UnicodeError):
        print(f"[FAIL] invalid JSON ping response from {uri}")
        ok = False
    except Exception:
        print(f"[info] live plugin not reachable on {uri} "
              "(normal if MuseScore is closed or the plugin is not started)")

    sys.exit(0 if ok else 1)


def cmd_set_mixer_sound(args):
    set_mixer_sound.run(args)


def cmd_docs(args):
    if args.doc == "list":
        for alias, filename in DOC_ALIASES.items():
            print(f"{alias:14} {filename}")
        return
    name = DOC_ALIASES.get(args.doc)
    if name is None:
        if args.doc in assets.DOC_NAMES:
            name = args.doc
        else:
            sys.exit(f"error: unknown doc {args.doc!r}. Available: "
                     f"{', '.join(list(DOC_ALIASES) + list(assets.DOC_NAMES))}")
    sys.stdout.write(assets.read_doc(name))


# --- parser ----------------------------------------------------------------

def build_parser():
    parser = argparse.ArgumentParser(
        prog="musescore-mcp",
        description="MCP server bridging AI agents to MuseScore Studio 4. "
                    "With no arguments, runs the MCP server (stdio).")
    parser.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    sub = parser.add_subparsers(dest="command")

    p = sub.add_parser("serve", help="run the MCP server (stdio; default)")
    p.set_defaults(func=cmd_serve)

    p = sub.add_parser("install-plugin",
                       help="copy the bundled MuseScore plugin into MuseScore's plugin directory")
    p.add_argument("--allow-eval", action="store_true",
                   help="enable run_qml in the installed plugin (executes arbitrary "
                        "code inside MuseScore; off by default)")
    p.add_argument("--dry-run", action="store_true", help="show what would be done")
    p.add_argument("--plugin-dir", metavar="DIRECTORY",
                   help="MuseScore's configured plugin folder (overrides MUSESCORE_MCP_PLUGIN_DIR)")
    p.set_defaults(func=cmd_install_plugin)

    p = sub.add_parser("doctor", help="check the installation")
    p.add_argument("--plugin-dir", metavar="DIRECTORY",
                   help="check this plugin folder (overrides MUSESCORE_MCP_PLUGIN_DIR)")
    p.set_defaults(func=cmd_doctor)

    p = sub.add_parser("set-mixer-sound",
                       help="offline .mscz mixer sound surgery (MuseScore closed)",
                       description=set_mixer_sound.__doc__,
                       formatter_class=argparse.RawDescriptionHelpFormatter)
    set_mixer_sound.add_arguments(p)
    p.set_defaults(func=cmd_set_mixer_sound)

    p = sub.add_parser("docs", help="print a bundled document")
    p.add_argument("doc", nargs="?", default="cookbook",
                   help="cookbook|actions|install-prompt, or a file name (default: cookbook)")
    p.set_defaults(func=cmd_docs)

    return parser


def main(argv=None):
    if argv is None:
        argv = sys.argv[1:]
    if not argv:
        cmd_serve(None)
        return
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        args.func(args)
    except (OSError, ValueError) as error:
        parser.exit(1, f"error: {error}\n")
