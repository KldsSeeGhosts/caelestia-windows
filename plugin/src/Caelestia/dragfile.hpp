#pragma once

#include <qstring.h>

// The file a copy-only screenshot offers when it is dragged out of the shell.
// Each drag file lives alone in its own directory, <temp>/caelestia-drag-<uuid>/,
// so that it can carry a normal screenshot name (annotate-<stamp>.png) without
// any chance of colliding with a file of another card, reload or process.
// CUtils::newDragFile() and CUtils::removeDragFile() are the QML entry points.
// The root is a parameter so that tests can use a disposable directory.
namespace caelestia::shell::dragfile {

// A junction, a symlink or any other reparse point. Anything that cannot be
// inspected counts as one, so cleanup refuses rather than guesses.
bool isReparsePoint(const QString& path);

// Whether `name` is acceptable as the single file name of a drag file: one path
// component of at most 120 characters, ending in ".png", with no separator,
// no character Windows forbids in a file name, no leading or trailing space and
// no trailing dot, and not a reserved device name.
bool validName(const QString& name);

// Creates <root>/caelestia-drag-<uuid>/ (it must not exist yet) and, inside it,
// the empty file `name`, and returns the file's path with forward slashes. It
// returns an empty string, and leaves nothing behind, when the name is invalid
// or anything fails.
QString create(const QString& root, const QString& name);

// Removes one drag file and its directory. `path` has to equal
// <root>/caelestia-drag-<32 lower case hex digits>/<valid name> exactly. The
// directory must be a real directory, not a reparse point, and hold at most that
// one entry, which must be a regular file and not a reparse point. Anything else
// is refused and nothing is deleted. It works on exact paths only: no globbing, no
// recursion. Returns true when the directory does not exist afterwards (a drag
// directory that is already gone counts), and false when the path is refused or
// something could not be deleted.
bool remove(const QString& root, const QString& path);

} // namespace caelestia::shell::dragfile
