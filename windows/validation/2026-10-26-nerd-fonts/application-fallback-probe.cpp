#include <QGuiApplication>
#include <QFontDatabase>
#include <QTextLayout>
#include <QGlyphRun>
#include <QRawFont>
#include <QDebug>
#include <cstdio>
int main(int argc, char **argv) {
    qInstallMessageHandler([](QtMsgType, const QMessageLogContext &, const QString &message) { std::fprintf(stdout, "%s\n", message.toUtf8().constData()); std::fflush(stdout); });
    QGuiApplication app(argc, argv);
    const QString unique = QStringLiteral("AppOnly Nerd Font Mono");
    if (QFontDatabase::families().contains(unique)) return 1;
    int id = QFontDatabase::addApplicationFont(QString::fromLocal8Bit(argv[1]));
    if (id < 0 || !QFontDatabase::applicationFontFamilies(id).contains(unique)) return 2;
    if (QFontDatabase::addApplicationFont(QString::fromLocal8Bit(argv[2])) < 0) return 3;

    qInfo() << "APPLICATION_ONLY_FAMILY" << unique;

    QFont primary(QStringLiteral("Rubik"), 24);
    primary.setFamilies({QStringLiteral("Rubik"), unique});
    qInfo() << "EXPLICIT_FAMILIES" << primary.families();
    QTextLayout layout(QString::fromUcs4(U"A \uf444 \U000f0baf"), primary);
    layout.beginLayout(); layout.createLine(); layout.endLayout();
    int fallbackGlyphs = 0;
    bool primaryUsed = false;
    for (const QGlyphRun &run : layout.glyphRuns()) {
        qInfo() << "GLYPH_RUN" << run.rawFont().familyName() << run.glyphIndexes();
        primaryUsed |= run.rawFont().familyName() == QStringLiteral("Rubik");
        if (run.rawFont().familyName() == unique) fallbackGlyphs += run.glyphIndexes().size();
        for (quint32 index : run.glyphIndexes()) if (index == 0) return 4;
    }
    if (!primaryUsed || fallbackGlyphs < 2) return 5;
    qInfo() << "APPLICATION_FONT_FALLBACK_PASS";
    return 0;
}