#!/usr/bin/env python3
# mcp-fs — a filesystem MCP server confined to one workspace folder. The write tools let the
# agent build the project.
import os
from pathlib import PurePosixPath

from mcp.server.mcpserver import MCPServer
from mcp.server.transport_security import TransportSecuritySettings

# The workspace folder (FS_WORKSPACE in demo.env). Every path must stay inside it.
WORKSPACE = os.environ.get("FS_WORKSPACE", "/workspace")

mcp = MCPServer("filesystem")


def _anchor(path: str) -> str:
    """Resolve a caller path to an absolute path INSIDE the workspace, WITHOUT following
    symlinks. Relative paths are taken under WORKSPACE. normpath (not realpath) keeps the
    path the agent named, which is what open() — and therefore Falco — sees (D12)."""
    p = path if os.path.isabs(path) else os.path.join(WORKSPACE, path)
    norm = os.path.normpath(p)
    # Refuse any path outside the workspace.
    if norm != WORKSPACE and not norm.startswith(WORKSPACE + os.sep):
        raise ValueError(f"path escapes workspace {WORKSPACE!r}: {path!r}")
    return norm


@mcp.tool()
def read_text_file(path: str) -> str:
    """Read a UTF-8 text file from the workspace and return its contents."""
    target = _anchor(path)
    with open(target, "r", encoding="utf-8") as fh:
        return fh.read()


@mcp.tool()
def list_directory(path: str = ".") -> str:
    """List the entries of a directory in the workspace, one per line (dirs end with '/')."""
    target = _anchor(path)
    entries = []
    for name in sorted(os.listdir(target)):
        full = os.path.join(target, name)
        entries.append(name + ("/" if os.path.isdir(full) else ""))
    return "\n".join(entries) if entries else "(empty)"


@mcp.tool()
def write_file(path: str, content: str) -> str:
    """Create or overwrite a text file in the workspace with the given content."""
    target = _anchor(path)
    os.makedirs(os.path.dirname(target) or WORKSPACE, exist_ok=True)
    with open(target, "w", encoding="utf-8") as fh:
        fh.write(content)
    return f"wrote {len(content)} bytes to {PurePosixPath(target)}"


@mcp.tool()
def create_directory(path: str) -> str:
    """Create a directory (and any missing parents) in the workspace."""
    target = _anchor(path)
    os.makedirs(target, exist_ok=True)
    return f"created directory {PurePosixPath(target)}"


if __name__ == "__main__":
    # DNS-rebinding protection is off; the only client is agentgateway, inside the cluster.
    mcp.run(
        transport="streamable-http",
        host="0.0.0.0",
        port=int(os.environ.get("PORT", "8080")),
        streamable_http_path="/mcp",
        transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=False),
    )
