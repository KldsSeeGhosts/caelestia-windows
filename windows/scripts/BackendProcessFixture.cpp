#include <qcoreapplication.h>
#include <qprocess.h>
#include <qstringlist.h>
#include <windows.h>

#include "../deps/quickshell/src/io/processcore.hpp"

int main(int argc, char** argv) {
	QCoreApplication app(argc, argv);
	auto args = app.arguments();
	if (args.size() != 4) return 2;
	QProcess helper;
	qs::io::process::ownHelper(&helper);
	helper.start(args[1], {QStringLiteral("hold"), args[2]});
	if (!helper.waitForStarted(5000)) return 3;
	QProcess detached;
	detached.setProgram(args[1]);
	detached.setArguments({QStringLiteral("hold"), args[3]});
	qs::io::process::disownHandles(&detached);
	if (!detached.startDetached()) return 4;
	Sleep(INFINITE);
	return 0;
}
