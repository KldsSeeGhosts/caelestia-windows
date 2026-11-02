// Source guard: plugin logs must not stream a raw per-screen name or key.
// Wrap them in settings::logId() or drop the value. The backend has the same
// guard in src/windows/test/log_redaction_guard_test.cpp.

#include <qdir.h>
#include <qdiriterator.h>
#include <qfile.h>
#include <qregularexpression.h>
#include <qstring.h>
#include <qstringlist.h>
#include <qtest.h>

namespace {

QString stripStrings(const QString& text) {
    auto out = QString();
    auto inString = false;
    auto escaped = false;
    for (const auto character : text) {
        if (escaped) {
            escaped = false;
            out += QLatin1Char(' ');
        } else if (inString) {
            if (character == QLatin1Char('\\'))
                escaped = true;
            else if (character == QLatin1Char('"'))
                inString = false;
            out += QLatin1Char(' ');
        } else if (character == QLatin1Char('"')) {
            inString = true;
            out += QLatin1Char(' ');
        } else {
            out += character;
        }
    }
    return out;
}

QString stripLineComments(QString text) {
    auto index = text.indexOf(QStringLiteral("//"));
    while (index >= 0) {
        auto end = text.indexOf(QLatin1Char('\n'), index);
        if (end < 0)
            end = text.size();
        text.remove(index, end - index);
        index = text.indexOf(QStringLiteral("//"));
    }
    return text;
}

QString stripSafeCalls(QString text) {
    for (const auto& name : {QStringLiteral("logId"), QStringLiteral("logPath")}) {
        auto searchFrom = 0;
        while (true) {
            auto start = text.indexOf(name, searchFrom);
            if (start < 0)
                break;
            auto open = start + name.size();
            while (open < text.size() && text.at(open).isSpace())
                open++;
            if (open >= text.size() || text.at(open) != QLatin1Char('(')) {
                searchFrom = open;
                continue;
            }
            auto depth = 0;
            auto end = -1;
            for (auto index = open; index < text.size(); index++) {
                if (text.at(index) == QLatin1Char('('))
                    depth++;
                else if (text.at(index) == QLatin1Char(')') && --depth == 0) {
                    end = index;
                    break;
                }
            }
            if (end < 0)
                break;
            text.replace(start, end - start + 1, QStringLiteral(" safe "));
            searchFrom = start + 6;
        }
    }
    return text;
}

// A raw per-screen value: the screen itself, its name, or a name lookup. Reading
// another property of a screen (screen->geometry(), m_screen->devicePixelRatio())
// streams no identifier, so only an accessor other than name() is let through.
QRegularExpressionMatch rawScreenValue(const QString& code) {
    static const auto pattern = QRegularExpression(
        QStringLiteral(R"(\b(?:screen|m_screen)\b(?!\s*(?:->|\.)\s*(?!name\b)[A-Za-z_])|\b(?:screenName|nameFor)\b)")
    );
    return pattern.match(code);
}

// A settings file's path contains the per-monitor directory, which is named
// after the monitor, so the path is as sensitive as the name.
QRegularExpressionMatch rawLayerPath(const QString& code) {
    static const auto pattern = QRegularExpression(QStringLiteral(R"(\bm_path\b)"));
    return pattern.match(code);
}

bool isLogStart(const QString& line) {
    static const auto pattern = QRegularExpression(
        QStringLiteral(R"(\bqC(?:Debug|Info|Warning|Critical)\b|\bq(?:Debug|Info|Warning|Critical)\s*\()")
    );
    return pattern.match(line).hasMatch();
}

} // namespace

class PluginLogRedactionGuardTest: public QObject {
    Q_OBJECT

private slots:
    void otherScreenPropertiesAreNotIdentifiers() {
        // Properties that carry no identifier.
        QVERIFY(!rawScreenValue(QStringLiteral("qCDebug(lc) << screen->geometry();")).hasMatch());
        QVERIFY(!rawScreenValue(QStringLiteral("qCDebug(lc) << m_screen->devicePixelRatio();")).hasMatch());
        QVERIFY(!rawScreenValue(QStringLiteral("qCDebug(lc) << screen . size ();")).hasMatch());
        // The screen itself, its name and name lookups still are.
        QVERIFY(rawScreenValue(QStringLiteral("qCDebug(lc) << screen;")).hasMatch());
        QVERIFY(rawScreenValue(QStringLiteral("qCDebug(lc) << screen->name();")).hasMatch());
        QVERIFY(rawScreenValue(QStringLiteral("qCDebug(lc) << m_screen.name();")).hasMatch());
        QVERIFY(rawScreenValue(QStringLiteral("qCDebug(lc) << screenName;")).hasMatch());
        QVERIFY(rawScreenValue(QStringLiteral("qCDebug(lc) << nameFor(layer);")).hasMatch());
        QVERIFY(rawScreenValue(QStringLiteral("qCDebug(lc) << screen->geometry() << screen;")).hasMatch());
    }

    void layerPathsAreRaw() {
        QVERIFY(rawLayerPath(QStringLiteral("qCWarning(lc, , qUtf8Printable(m_path));")).hasMatch());
        QVERIFY(rawLayerPath(QStringLiteral("qCDebug(lc) << m_path;")).hasMatch());
        // Wrapped in logId() it is stripped before matching.
        QVERIFY(!rawLayerPath(stripSafeCalls(QStringLiteral("qCDebug(lc) << logId(m_path);"))).hasMatch());
    }

    void screenNamesAreRedacted() {
        auto root = QDir(QStringLiteral(CAELESTIA_PLUGIN_SRC));
        QVERIFY2(root.exists(), qPrintable(QStringLiteral("Source root missing: %1").arg(root.path())));

        auto failures = QStringList();
        auto iterator = QDirIterator(
            root.path(),
            {QStringLiteral("*.cpp"), QStringLiteral("*.hpp")},
            QDir::Files,
            QDirIterator::Subdirectories
        );
        while (iterator.hasNext()) {
            const auto path = iterator.next();
            const auto relative = root.relativeFilePath(path);
            if (relative.startsWith(QStringLiteral("test/")) || relative.startsWith(QStringLiteral("test\\")))
                continue;
            if (relative == QStringLiteral("Settings/redact.cpp") || relative == QStringLiteral("Settings/redact.hpp"))
                continue;

            QFile file(path);
            if (!file.open(QFile::ReadOnly | QFile::Text)) {
                failures.append(QStringLiteral("%1: cannot read").arg(relative));
                continue;
            }
            const auto lines = QString::fromUtf8(file.readAll()).split(QLatin1Char('\n'));
            for (auto index = 0; index < lines.size(); index++) {
                const auto trimmed = lines.at(index).trimmed();
                if (trimmed.startsWith(QStringLiteral("//")) || trimmed.startsWith(QLatin1Char('*')))
                    continue;
                if (!isLogStart(lines.at(index)))
                    continue;

                auto statement = QString();
                auto statementLine = index + 1;
                auto cursor = index;
                while (cursor < lines.size() && cursor < index + 30) {
                    statement += lines.at(cursor);
                    statement += QLatin1Char('\n');
                    if (lines.at(cursor).contains(QLatin1Char(';')))
                        break;
                    cursor++;
                }
                index = cursor;

                const auto code = stripSafeCalls(stripLineComments(stripStrings(statement)));
                auto raw = rawScreenValue(code);
                if (!raw.hasMatch() && relative == QStringLiteral("Settings/settingsfile.cpp"))
                    raw = rawLayerPath(code);
                if (raw.hasMatch()) {
                    failures.append(QStringLiteral("%1:%2: raw screen value `%3` is streamed to a log")
                                        .arg(relative)
                                        .arg(statementLine)
                                        .arg(raw.captured(0)));
                }
            }
        }

        if (!failures.isEmpty()) {
            QFAIL(qPrintable(
                QStringLiteral("Unredacted plugin screen logs (drop the value or wrap it in logId()):\n%1")
                    .arg(failures.mid(0, 20).join(QLatin1Char('\n')))
            ));
        }
    }
};

QTEST_GUILESS_MAIN(PluginLogRedactionGuardTest)
#include "log_redaction_guard_test.moc"
