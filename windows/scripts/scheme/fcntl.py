"""Minimal fcntl shim for Windows.

The upstream caelestia CLI imports ``fcntl`` from its theme writer even for the
``scheme`` subcommand. Windows has no fcntl module, so this file is installed in
the profile-local virtual environment's site-packages. It implements the
advisory flock calls the CLI uses with msvcrt's byte lock, which is enough for
its single "do not run two theme writers" guard.
"""

from __future__ import annotations

import msvcrt
import os

LOCK_SH = 0x01
LOCK_EX = 0x02
LOCK_NB = 0x04
LOCK_UN = 0x08


def flock(fd: int, operation: int) -> None:
    if operation & LOCK_UN:
        try:
            os.lseek(fd, 0, os.SEEK_SET)
            msvcrt.locking(fd, msvcrt.LK_UNLCK, 1)
        except OSError:
            pass
        return

    mode = msvcrt.LK_NBLCK if operation & LOCK_NB else msvcrt.LK_LOCK
    os.lseek(fd, 0, os.SEEK_SET)
    try:
        msvcrt.locking(fd, mode, 1)
    except OSError as exc:
        if operation & LOCK_NB:
            raise BlockingIOError(str(exc)) from exc
        raise
