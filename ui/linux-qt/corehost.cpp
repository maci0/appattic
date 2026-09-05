#include "corehost.h"
#include "embed.h"

#include <QByteArray>
#include <QCoreApplication>
#include <QDir>
#include <QFileInfo>
#include <QStandardPaths>

#include <vector>

static int homePathTag(const char *xdgEnv, const QString &rel);

QString coreOutDir() {
    const QByteArray env = qgetenv("APPATTIC_CORE_OUT");
    if (!env.isEmpty()) return QString::fromUtf8(env);

    const QDir exeDir(QCoreApplication::applicationDirPath());
    const QStringList candidates = {
        exeDir.absoluteFilePath(QStringLiteral("../share/appattic")),
        exeDir.absoluteFilePath(QStringLiteral("../../../core/out")),
        exeDir.absoluteFilePath(QStringLiteral("../../core/out")),
    };
    for (const QString &c : candidates) {
        if (QFileInfo::exists(c + QStringLiteral("/appattic_core.wasm"))) {
            return QDir(c).canonicalPath();
        }
    }
    return QDir(candidates.constFirst()).absolutePath();
}

static int pluginTag(const QString &wasmPath) {
    const QFileInfo fi(wasmPath);
    const QString stem = fi.completeBaseName();
    if (stem == QLatin1String("container_runtime")) {
        if (!QStandardPaths::findExecutable(QStringLiteral("podman")).isEmpty()) return 2;
        if (!QStandardPaths::findExecutable(QStringLiteral("docker")).isEmpty()) return 1;
        return 0;
    }
    if (stem == QLatin1String("snapd")) {
        return QStandardPaths::findExecutable(QStringLiteral("snap")).isEmpty() ? 0 : 1;
    }
    if (stem == QLatin1String("path_xdg_config")) {
        return homePathTag("XDG_CONFIG_HOME", QStringLiteral(".config"));
    }
    if (stem == QLatin1String("path_xdg_data")) {
        return homePathTag("XDG_DATA_HOME", QStringLiteral(".local/share"));
    }
    if (stem == QLatin1String("path_xdg_cache")) {
        return homePathTag("XDG_CACHE_HOME", QStringLiteral(".cache"));
    }
    if (stem == QLatin1String("path_xdg_state")) {
        return homePathTag("XDG_STATE_HOME", QStringLiteral(".local/state"));
    }
    if (stem == QLatin1String("path_xdg_lib")) {
        return QDir::home().exists(QStringLiteral(".local/lib")) ? 1 : 0;
    }
    if (stem == QLatin1String("path_var_app")) {
        return QDir::home().exists(QStringLiteral(".var/app")) ? 1 : 0;
    }
    if (stem == QLatin1String("path_shadow")) {
        const QDir home = QDir::home();
        if (home.exists(QStringLiteral(".local/bin"))) return 1;
        if (home.exists(QStringLiteral("bin"))) return 1;
        if (home.exists(QStringLiteral(".cargo/bin"))) return 1;
        if (home.exists(QStringLiteral(".local/share/applications"))) return 1;
        return 0;
    }
    if (stem == QLatin1String("path_user_bin")) {
        if (QDir::home().exists(QStringLiteral(".local/bin"))) return 1;
        if (QDir::home().exists(QStringLiteral("bin"))) return 1;
        return 0;
    }
    if (stem == QLatin1String("path_home_dot")) {
        return QDir::home().exists() ? 1 : 0;
    }
    if (stem == QLatin1String("path_application_support")) {
        return QDir::home().exists(QStringLiteral("Library/Application Support")) ? 1 : 0;
    }
    if (stem == QLatin1String("path_caches")) {
        return QDir::home().exists(QStringLiteral("Library/Caches")) ? 1 : 0;
    }
    if (stem == QLatin1String("path_preferences")) {
        return QDir::home().exists(QStringLiteral("Library/Preferences")) ? 1 : 0;
    }
    if (stem == QLatin1String("path_saved_state")) {
        return QDir::home().exists(QStringLiteral("Library/Saved Application State")) ? 1 : 0;
    }
    if (stem == QLatin1String("path_containers")) {
        return QDir::home().exists(QStringLiteral("Library/Containers")) ? 1 : 0;
    }
    if (stem == QLatin1String("path_group_containers")) {
        return QDir::home().exists(QStringLiteral("Library/Group Containers")) ? 1 : 0;
    }
    if (stem == QLatin1String("path_logs")) {
        return QDir::home().exists(QStringLiteral("Library/Logs")) ? 1 : 0;
    }
    if (stem == QLatin1String("path_webkit")) {
        return QDir::home().exists(QStringLiteral("Library/WebKit")) ? 1 : 0;
    }
    if (stem == QLatin1String("path_httpstorages")) {
        return QDir::home().exists(QStringLiteral("Library/HTTPStorages")) ? 1 : 0;
    }
    if (stem == QLatin1String("path_launchagents")) {
        return QDir::home().exists(QStringLiteral("Library/LaunchAgents")) ? 1 : 0;
    }
    if (stem == QLatin1String("pacman")) {
        return QStandardPaths::findExecutable(QStringLiteral("pacman")).isEmpty() ? 0 : 1;
    }
    if (stem == QLatin1String("apt")) {
        if (!QStandardPaths::findExecutable(QStringLiteral("apt-get")).isEmpty()) return 1;
        if (!QStandardPaths::findExecutable(QStringLiteral("apt")).isEmpty()) return 1;
        return 0;
    }
    if (stem == QLatin1String("dnf")) {
        if (!QStandardPaths::findExecutable(QStringLiteral("dnf5")).isEmpty()) return 1;
        if (!QStandardPaths::findExecutable(QStringLiteral("dnf")).isEmpty()) return 1;
        if (!QStandardPaths::findExecutable(QStringLiteral("yum")).isEmpty()) return 1;
        return 0;
    }
    if (stem == QLatin1String("zypper")) {
        return QStandardPaths::findExecutable(QStringLiteral("zypper")).isEmpty() ? 0 : 1;
    }
    if (stem == QLatin1String("flatpak")) {
        return QStandardPaths::findExecutable(QStringLiteral("flatpak")).isEmpty() ? 0 : 1;
    }
    if (stem == QLatin1String("npm")) {
        return QStandardPaths::findExecutable(QStringLiteral("npm")).isEmpty() ? 0 : 1;
    }
    if (stem == QLatin1String("pnpm")) {
        return QStandardPaths::findExecutable(QStringLiteral("pnpm")).isEmpty() ? 0 : 1;
    }
    if (stem == QLatin1String("bun")) {
        return QStandardPaths::findExecutable(QStringLiteral("bun")).isEmpty() ? 0 : 1;
    }
    if (stem == QLatin1String("pipx")) {
        return QStandardPaths::findExecutable(QStringLiteral("pipx")).isEmpty() ? 0 : 1;
    }
    if (stem == QLatin1String("pip")) {
        if (!QStandardPaths::findExecutable(QStringLiteral("pip")).isEmpty()) return 1;
        if (!QStandardPaths::findExecutable(QStringLiteral("pip3")).isEmpty()) return 1;
        return 0;
    }
    if (stem == QLatin1String("uv")) {
        return QStandardPaths::findExecutable(QStringLiteral("uv")).isEmpty() ? 0 : 1;
    }
    if (stem == QLatin1String("brew")) {
        return QStandardPaths::findExecutable(QStringLiteral("brew")).isEmpty() ? 0 : 1;
    }
    if (stem == QLatin1String("gem")) {
        return QStandardPaths::findExecutable(QStringLiteral("gem")).isEmpty() ? 0 : 1;
    }
    if (stem == QLatin1String("composer")) {
        return QStandardPaths::findExecutable(QStringLiteral("composer")).isEmpty() ? 0 : 1;
    }
    return 1;
}

static int homePathTag(const char *xdgEnv, const QString &rel) {
    const QString env = QString::fromUtf8(qgetenv(xdgEnv)).trimmed();
    if (QDir::isAbsolutePath(env)) return QDir(env).exists() ? 1 : 0;
    return QDir::home().exists(rel) ? 1 : 0;
}

QStringList pluginWasmFiles(const QString &out) {
    const QStringList names = {
        QStringLiteral("/container_runtime.wasm"),
        QStringLiteral("/snapd.wasm"),
        QStringLiteral("/path_xdg_config.wasm"),
        QStringLiteral("/path_xdg_data.wasm"),
        QStringLiteral("/path_xdg_cache.wasm"),
        QStringLiteral("/path_xdg_state.wasm"),
        QStringLiteral("/path_xdg_lib.wasm"),
        QStringLiteral("/path_var_app.wasm"),
        QStringLiteral("/path_shadow.wasm"),
        QStringLiteral("/path_user_bin.wasm"),
        QStringLiteral("/path_home_dot.wasm"),
        QStringLiteral("/path_application_support.wasm"),
        QStringLiteral("/path_caches.wasm"),
        QStringLiteral("/path_preferences.wasm"),
        QStringLiteral("/path_saved_state.wasm"),
        QStringLiteral("/path_containers.wasm"),
        QStringLiteral("/path_group_containers.wasm"),
        QStringLiteral("/path_logs.wasm"),
        QStringLiteral("/path_webkit.wasm"),
        QStringLiteral("/path_httpstorages.wasm"),
        QStringLiteral("/path_launchagents.wasm"),
        QStringLiteral("/pacman.wasm"),
        QStringLiteral("/apt.wasm"),
        QStringLiteral("/dnf.wasm"),
        QStringLiteral("/zypper.wasm"),
        QStringLiteral("/flatpak.wasm"),
        QStringLiteral("/npm.wasm"),
        QStringLiteral("/pnpm.wasm"),
        QStringLiteral("/bun.wasm"),
        QStringLiteral("/pipx.wasm"),
        QStringLiteral("/uv.wasm"),
        QStringLiteral("/brew.wasm"),
        QStringLiteral("/gem.wasm"),
        QStringLiteral("/composer.wasm"),
        QStringLiteral("/pip.wasm"),
    };
    QStringList paths;
    paths.reserve(names.size());
    for (const QString &n : names) paths << (out + n);
    return paths;
}

QStringList taggedPluginSpecs(const QString &out) {
    const QStringList plugins = pluginWasmFiles(out);
    QStringList specs;
    specs.reserve(plugins.size());
    for (const QString &p : plugins) {
        specs << (p + QLatin1Char('=') + QString::number(pluginTag(p)));
    }
    return specs;
}

int runCoreWasm(
    const QString &coreWasm,
    const QStringList &pluginSpecs,
    void (*onJson)(const char *json, size_t jsonLen, void *user),
    void *user,
    char *err,
    size_t errlen
) {
    std::vector<QByteArray> specBytes;
    std::vector<char *> ptrs;
    specBytes.reserve(size_t(pluginSpecs.size()));
    ptrs.reserve(size_t(pluginSpecs.size()));
    for (const QString &s : pluginSpecs) specBytes.push_back(s.toUtf8());
    for (QByteArray &s : specBytes) ptrs.push_back(s.data());
    const QByteArray coreUtf8 = coreWasm.toUtf8();
    return appattic_wasm_run(
        coreUtf8.constData(),
        ptrs.empty() ? nullptr : ptrs.data(),
        int(ptrs.size()),
        onJson,
        user,
        err,
        errlen
    );
}

static void appendJsonLine(const char *json, size_t len, void *user) {
    if (!user) return;
    auto *out = static_cast<QByteArray *>(user);
    out->append(json, int(len));
    out->append('\n');
}

int collectCoreWasm(
    const QString &coreWasm,
    const QStringList &pluginSpecs,
    QByteArray *blobs,
    char *err,
    size_t errlen
) {
    return runCoreWasm(coreWasm, pluginSpecs, appendJsonLine, blobs, err, errlen);
}
