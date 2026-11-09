#pragma once

#include <qstring.h>

#ifdef CAELESTIA_DRAGFILE_HOOKS
#include <functional>
#endif

// The file a copy-only screenshot offers when it is dragged out of the shell.
// Each drag file lives alone in its own directory, <temp>/caelestia-drag-<uuid>/,
// so that it can carry a normal screenshot name (annotate-<stamp>.png) without
// any chance of colliding with a file of another card, reload or process.
// CUtils::newDragFile() and CUtils::removeDragFile() are the QML entry points.
// The root is a parameter so that tests can use a disposable directory.
//
// On Windows every create and delete step works through handles, never through
// a path that was checked earlier. The drag directory is opened without
// FILE_SHARE_DELETE, so no other process can rename or delete it, or put a
// junction in its place, while it is held. The file is checked and deleted
// through its own handle, and the directory is deleted through its pinned handle.
// The temp root may itself be a junction: its final path is resolved once per call
// and every drag directory must resolve to <that path>\caelestia-drag-<uuid>.
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
// returns an empty string when the name is invalid or anything fails. A failure
// undoes only what this call created, through the handles it created them with:
// it never deletes by path, and it deletes nothing when a check on the new
// directory failed, because it cannot then tell what the path refers to.
QString create(const QString& root, const QString& name);

// Removes one drag file and its directory. `path` has to equal
// <root>/caelestia-drag-<32 lower case hex digits>/<valid name> exactly. The
// directory must be a real directory, not a reparse point, with the expected
// final path, and hold at most that one entry, which must be a regular file, not
// a reparse point, with a single hard link. Anything else is refused and nothing
// is deleted. It works on exact paths only: no globbing, no recursion. Returns true
// when the directory does not exist afterwards (a drag directory that is already
// gone counts), and false when the path is refused or something could not be
// deleted.
bool remove(const QString& root, const QString& path);

#ifdef CAELESTIA_DRAGFILE_HOOKS
// Test seam, compiled only into the dragfile test. The hook runs between two
// steps of create() and remove() so that a test can change the file system at the
// exact moment a race would. `directory` is the drag directory.
namespace testing {

enum class Step {
    AfterRootResolved,     // remove, create: the temp root's final path is known
    AfterDirectoryCreated, // create: mkdir succeeded, the directory is not pinned yet
    BeforeFileCreated,     // create: the directory is pinned
    BeforeFileRemoval,     // remove: the directory is pinned and enumerated
    BeforeDirectoryRemoval // remove: the file is gone, the directory is still pinned
};

void setHook(std::function<void(Step, const QString& directory)> hook);

} // namespace testing
#endif

} // namespace caelestia::shell::dragfile
