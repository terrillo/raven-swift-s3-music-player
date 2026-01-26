"""Thread-safe caching utilities."""

import threading
from typing import Callable, Generic, TypeVar

K = TypeVar("K")
V = TypeVar("V")


class ThreadSafeCache(Generic[K, V]):
    """A generic thread-safe cache."""

    def __init__(self) -> None:
        self._cache: dict[K, V] = {}
        self._lock = threading.Lock()

    def get(self, key: K) -> V | None:
        """Get a value from the cache."""
        with self._lock:
            return self._cache.get(key)

    def set(self, key: K, value: V) -> None:
        """Set a value in the cache."""
        with self._lock:
            self._cache[key] = value

    def contains(self, key: K) -> bool:
        """Check if a key exists in the cache."""
        with self._lock:
            return key in self._cache

    def get_or_compute(self, key: K, compute_fn: Callable[[], V]) -> V:
        """Get from cache or compute and cache the result.

        Note: The compute_fn is called outside the lock to avoid deadlocks.
        This means the function may be called multiple times for the same key
        in a race condition, but that's acceptable for our use case.
        """
        # First check without computing
        with self._lock:
            if key in self._cache:
                return self._cache[key]

        # Compute outside the lock
        value = compute_fn()

        # Store the result
        with self._lock:
            # Check again in case another thread computed it
            if key not in self._cache:
                self._cache[key] = value
            return self._cache[key]

    def clear(self) -> None:
        """Clear all cached values."""
        with self._lock:
            self._cache.clear()

    def __len__(self) -> int:
        """Return the number of cached items."""
        with self._lock:
            return len(self._cache)
