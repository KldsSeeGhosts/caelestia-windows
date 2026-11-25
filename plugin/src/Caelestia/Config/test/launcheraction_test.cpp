#include <qjsonarray.h>
#include <qjsonobject.h>
#include <qtest.h>

#include "launcherconfig.hpp"

using namespace caelestia::shell::config;
using namespace caelestia::shell::settings;
using Qt::StringLiterals::operator""_s;

class LauncherActionTest: public QObject {
    Q_OBJECT

private slots:
    void validShellActionStaysEnabled() {
        LauncherAction action;
        QList<Diagnostic> diagnostics;
        const QJsonObject json{
            { u"enabled"_s, true },
            { u"name"_s, u"Terminal"_s },
            { u"verb"_s, u"open"_s },
            { u"target"_s, u"wt.exe"_s },
            { u"args"_s, QJsonArray{ u"cmd"_s } },
        };

        QVERIFY(action.syncJson(json, diagnostics));
        QVERIFY(diagnostics.isEmpty());
        QVERIFY(action.enabled());
        QVERIFY(action.decodeValid());
        QCOMPARE(action.target(), u"wt.exe"_s);
        QCOMPARE(action.args(), QStringList{ u"cmd"_s });
    }

    void malformedArgsDisableTheWholeAction() {
        LauncherAction action;
        QList<Diagnostic> diagnostics;
        const QJsonObject json{
            { u"name"_s, u"Terminal"_s },
            { u"verb"_s, u"open"_s },
            { u"target"_s, u"wt.exe"_s },
            { u"args"_s, u"cmd"_s },
        };

        QVERIFY(action.syncJson(json, diagnostics));
        QVERIFY(!diagnostics.isEmpty());
        QVERIFY(!action.decodeValid());
        QVERIFY(action.enabled()); // Decode validity must not rewrite the saved flag.
        diagnostics.clear();
        auto corrected = json;
        corrected.insert(u"args"_s, QJsonArray{ u"cmd"_s });
        QVERIFY(action.syncJson(corrected, diagnostics));
        QVERIFY(diagnostics.isEmpty());
        QVERIFY(action.decodeValid());
    }

    void malformedSecondEndpointDisablesTheWholeAction() {
        LauncherAction action;
        QList<Diagnostic> diagnostics;
        const QJsonObject json{
            { u"name"_s, u"Ambiguous"_s },
            { u"verb"_s, u"open"_s },
            { u"target"_s, u"wt.exe"_s },
            { u"uri"_s, QJsonObject{} },
        };

        QVERIFY(action.syncJson(json, diagnostics));
        QVERIFY(!diagnostics.isEmpty());
        QVERIFY(!action.decodeValid());
    }

    void malformedEnabledFieldCannotStayEnabled() {
        LauncherAction action;
        QList<Diagnostic> diagnostics;
        const QJsonObject json{
            { u"enabled"_s, u"yes"_s },
            { u"verb"_s, u"open"_s },
            { u"target"_s, u"wt.exe"_s },
        };

        QVERIFY(action.syncJson(json, diagnostics));
        QVERIFY(!diagnostics.isEmpty());
        QVERIFY(!action.decodeValid());
    }
};

QTEST_GUILESS_MAIN(LauncherActionTest)
#include "launcheraction_test.moc"
