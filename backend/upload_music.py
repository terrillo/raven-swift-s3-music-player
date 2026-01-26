#!/usr/bin/env python3
"""
Music Upload Script for DigitalOcean Spaces

This is a backwards-compatible wrapper. The implementation has been
refactored into the backend package.

Usage:
    python upload_music.py [--dry-run] [--verbose] [--workers N]

Or use the package directly:
    python -m backend.main [--dry-run] [--verbose] [--workers N]
"""

import sys
from pathlib import Path

# Add parent directory to path for package imports
sys.path.insert(0, str(Path(__file__).parent.parent))

from backend.main import main

if __name__ == "__main__":
    main()
