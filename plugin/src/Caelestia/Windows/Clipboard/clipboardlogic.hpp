#pragma once

#include <qstring.h>

namespace caelestia::shell::windows {

// Windows.ApplicationModel.DataTransfer.SetHistoryItemAsContentStatus values.
// They are part of the WinRT ABI (Success = 0, AccessDenied = 1,
// ItemDeleted = 2), but the worker only needs the decision, so it is kept out
// of WinRT headers and can be exercised by the light logic test.
enum class ClipboardSetContentStatus : int {
    Success = 0,
    AccessDenied = 1,
    ItemDeleted = 2,
};

struct ClipboardContentResult {
    bool ok = false;
    QString message;
};

// SetHistoryItemAsContent without a Success status must never be reported or
// followed by a synthetic paste: the clipboard still holds the previous entry.
[[nodiscard]] inline ClipboardContentResult clipboardSetContentResult(int status) {
    switch (static_cast<ClipboardSetContentStatus>(status)) {
    case ClipboardSetContentStatus::Success:
        return {true, {}};
    case ClipboardSetContentStatus::AccessDenied:
        return {false, QStringLiteral("Windows denied access to the clipboard history item.")};
    case ClipboardSetContentStatus::ItemDeleted:
        return {false, QStringLiteral("The clipboard history item was deleted before it could be used.")};
    }
    return {false,
        QStringLiteral("Windows returned an unknown clipboard item status (%1).").arg(status)};
}

} // namespace caelestia::shell::windows
