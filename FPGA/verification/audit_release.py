"""Read-only GitHub repository verification."""
from pathlib import Path
import runpy
runpy.run_path(str(Path(__file__).resolve().parents[2]/'tools/check_repository.py'), run_name='__main__')
