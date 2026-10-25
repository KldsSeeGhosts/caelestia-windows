#pragma once

#include <qglobal.h>

// Qt's read-only static metaobjects need explicit DLL exports and imports.
#if defined(Q_OS_WIN) && defined(caelestia_core_EXPORTS)
#define CAELESTIA_CORE_API Q_DECL_EXPORT
#elif defined(Q_OS_WIN)
#define CAELESTIA_CORE_API Q_DECL_IMPORT
#else
#define CAELESTIA_CORE_API
#endif

#if defined(Q_OS_WIN) && defined(caelestia_settings_EXPORTS)
#define CAELESTIA_SETTINGS_API Q_DECL_EXPORT
#elif defined(Q_OS_WIN)
#define CAELESTIA_SETTINGS_API Q_DECL_IMPORT
#else
#define CAELESTIA_SETTINGS_API
#endif

#if defined(Q_OS_WIN) && defined(caelestia_config_EXPORTS)
#define CAELESTIA_CONFIG_API Q_DECL_EXPORT
#elif defined(Q_OS_WIN)
#define CAELESTIA_CONFIG_API Q_DECL_IMPORT
#else
#define CAELESTIA_CONFIG_API
#endif
