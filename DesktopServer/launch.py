"""Run with python -I -B; add only this trusted source directory."""
import multiprocessing
import sys
from pathlib import Path

if __name__ == "__main__":
    multiprocessing.freeze_support()
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from picax_lan.cli import main
    main()
