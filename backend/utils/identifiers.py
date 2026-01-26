"""Identifier utilities and path sanitization."""

import re


def extract_year(date_value: str | int | None) -> int | None:
    """Extract the year as an integer from various date formats.

    Handles:
        - Integer year: 2024 -> 2024
        - String year: "2024" -> 2024
        - ISO date: "2024-01-15" -> 2024
        - Partial date: "2024-01" -> 2024

    Returns:
        The year as an integer, or None if extraction fails.
    """
    if date_value is None:
        return None

    if isinstance(date_value, int):
        return date_value

    if isinstance(date_value, str):
        date_str = date_value.strip()
        if not date_str:
            return None

        # Try to extract year from beginning of string (handles YYYY, YYYY-MM, YYYY-MM-DD)
        match = re.match(r"^(\d{4})", date_str)
        if match:
            return int(match.group(1))

    return None


def normalize_artist_name(name: str | None) -> str | None:
    """Normalize artist name by extracting first artist from multi-artist strings.

    Splits by "/" and returns the first artist, stripped of whitespace.
    Example: "Justin Timberlake/50 Cent" -> "Justin Timberlake"
    """
    if name is None:
        return None
    if not name:
        return name
    if "/" in name:
        name = name.split("/")[0]
    return name.strip()


def get_artist_grouping_key(name: str) -> str:
    """Get case-insensitive key for artist grouping.

    Example: "Afrojack" and "afrojack" -> "afrojack"
    """
    normalized = normalize_artist_name(name)
    return normalized.lower() if normalized else ""


def sanitize_s3_key(name: str, fallback: str = "Unknown") -> str:
    """Sanitize a string for use as an S3 key path component.

    Args:
        name: The string to sanitize (artist, album, or track name)
        fallback: Value to use if name is empty after sanitization

    Returns:
        A sanitized string safe for use in S3 keys (only A-Z, a-z, 0-9, and dashes)
    """
    if not name:
        return fallback

    # Replace spaces and underscores with dashes
    sanitized = re.sub(r"[\s_]+", "-", name)

    # Remove all characters except alphanumeric and dashes
    sanitized = re.sub(r"[^A-Za-z0-9-]", "", sanitized)

    # Collapse multiple dashes into single dash
    sanitized = re.sub(r"-+", "-", sanitized)

    # Trim leading/trailing dashes
    sanitized = sanitized.strip("-")

    # Handle empty result
    if not sanitized:
        return fallback

    return sanitized
