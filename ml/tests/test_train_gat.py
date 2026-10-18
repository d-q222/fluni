"""Static checks for scripts/train_gat.py (no training, writes nothing).

    ml/.venv/bin/python ml/tests/test_train_gat.py
"""
import py_compile
import subprocess
import sys
from pathlib import Path

ML = Path(__file__).resolve().parents[1]
SCRIPT = ML / "scripts" / "train_gat.py"

py_compile.compile(str(SCRIPT), doraise=True)
for argv in (["--help"], ["--dry-run", "--kernel-init"]):
    out = subprocess.run([sys.executable, str(SCRIPT), *argv], capture_output=True, text=True)
    assert out.returncode == 0, out.stderr
    print(out.stdout[-1500:])
print("OK")
