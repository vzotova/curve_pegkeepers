"""Compile the stableswap-ng stack with its own 0.3.10 compiler, for a 0.4.3 boa to deploy."""

import hashlib
import json
import os
import subprocess

NG = os.environ.get("STABLESWAP_NG", r"C:/workspace/curve/stableswap-ng")
VYPER = rf"{NG}/.venv/Scripts/vyper.exe"
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ng_build.json")

TARGETS = {
    "math": ("contracts/main/CurveStableSwapNGMath.vy", "bytecode"),
    "views": ("contracts/main/CurveStableSwapNGViews.vy", "bytecode"),
    "factory": ("contracts/main/CurveStableSwapFactoryNG.vy", "bytecode"),
    "amm_blueprint": ("contracts/main/CurveStableSwapNG.vy", "blueprint_bytecode"),
    "amm": ("contracts/main/CurveStableSwapNG.vy", "bytecode"),
    "erc20": ("contracts/mocks/ERC20.vy", "bytecode"),
    "erc4626": ("contracts/mocks/ERC4626.vy", "bytecode"),
    "erc20oracle": ("contracts/mocks/ERC20Oracle.vy", "bytecode"),
}

env = dict(os.environ, PYTHONWARNINGS="ignore")
build = {}
for name, (path, fmt) in TARGETS.items():
    code = subprocess.run(
        [VYPER, "-f", fmt, path], cwd=NG, capture_output=True, text=True, env=env
    ).stdout.strip()
    abi = subprocess.run(
        [VYPER, "-f", "abi", path], cwd=NG, capture_output=True, text=True, env=env
    ).stdout.strip()
    if not code.startswith("0x"):
        raise SystemExit(f"{name}: compile failed")
    build[name] = {"bytecode": code, "abi": json.loads(abi)}
    print(f"  {name:14} {fmt:18} {(len(code) - 2) // 2:6} bytes")

# the sources this was compiled from, so a stale fixture fails loudly rather than
# silently testing a pool that no longer exists
digest = hashlib.sha256()
for _, (path, _fmt) in sorted(TARGETS.items()):
    digest.update(open(os.path.join(NG, path), "rb").read())
build["_sources_sha256"] = digest.hexdigest()
json.dump(build, open(OUT, "w"))
print(f"wrote {OUT}")
