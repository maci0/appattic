#include "corehost.h"
#include "embed.h"
#include "hostexec.h"

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

static QStringList languageBinDirs() {
    QStringList dirs;
    const QDir home = QDir::home();
    const QStringList rel = {
        QStringLiteral(".local/bin"),
        QStringLiteral("bin"),
        QStringLiteral(".bun/bin"),
        QStringLiteral(".deno/bin"),
        QStringLiteral(".volta/bin"),
        QStringLiteral(".yarn/bin"),
        QStringLiteral(".cargo/bin"),
        QStringLiteral(".fnm/aliases/default/bin"),
        QStringLiteral(".local/share/pnpm"),
        QStringLiteral(".npm-global/bin"),
    };
    for (const QString &r : rel) {
        const QString p = home.filePath(r);
        if (QDir(p).exists()) dirs << p;
    }
    const QDir nvm(home.filePath(QStringLiteral(".nvm/versions/node")));
    if (nvm.exists()) {
        const QStringList vers = nvm.entryList(QDir::Dirs | QDir::NoDotAndDotDot);
        for (const QString &v : vers) {
            const QString bin = nvm.filePath(v + QStringLiteral("/bin"));
            if (QDir(bin).exists()) dirs << bin;
        }
    }
    if (!qEnvironmentVariableIsEmpty("FLATPAK_ID")) {
        dirs << QStringLiteral("/run/host/usr/bin")
             << QStringLiteral("/run/host/usr/local/bin")
             << QStringLiteral("/run/host/usr/sbin")
             << QStringLiteral("/run/host/bin");
    }
    return dirs;
}

static bool hostHasExecutable(const QString &name) {
    if (!QStandardPaths::findExecutable(name).isEmpty()) return true;
    const QStringList extra = languageBinDirs();
    if (extra.isEmpty()) return false;
    return !QStandardPaths::findExecutable(name, extra).isEmpty();
}

static int pluginTag(const QString &wasmPath) {
    const QFileInfo fi(wasmPath);
    const QString stem = fi.completeBaseName();
    if (stem == QLatin1String("container_runtime")) {
        if (hostHasExecutable(QStringLiteral("podman"))) return 2;
        if (hostHasExecutable(QStringLiteral("docker"))) return 1;
        return 0;
    }
    if (stem == QLatin1String("snapd")) {
        return hostHasExecutable(QStringLiteral("snap")) ? 1 : 0;
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
    if (stem == QLatin1String("pacman")) {
        return hostHasExecutable(QStringLiteral("pacman")) ? 1 : 0;
    }
    if (stem == QLatin1String("aur")) {
        if (hostHasExecutable(QStringLiteral("paru"))) return 1;
        if (hostHasExecutable(QStringLiteral("yay"))) return 1;
        if (hostHasExecutable(QStringLiteral("pikaur"))) return 1;
        return 0;
    }
    if (stem == QLatin1String("apt")) {
        if (hostHasExecutable(QStringLiteral("apt-get"))) return 1;
        if (hostHasExecutable(QStringLiteral("apt"))) return 1;
        if (hostHasExecutable(QStringLiteral("dpkg"))) return 1;
        return 0;
    }
    if (stem == QLatin1String("dnf")) {
        if (hostHasExecutable(QStringLiteral("dnf5"))) return 1;
        if (hostHasExecutable(QStringLiteral("dnf"))) return 1;
        if (hostHasExecutable(QStringLiteral("yum"))) return 1;
        return 0;
    }
    if (stem == QLatin1String("zypper")) {
        return hostHasExecutable(QStringLiteral("zypper")) ? 1 : 0;
    }
    if (stem == QLatin1String("flatpak")) {
        return hostHasExecutable(QStringLiteral("flatpak")) ? 1 : 0;
    }
    if (stem == QLatin1String("npm")) {
        if (hostHasExecutable(QStringLiteral("npm"))) return 1;
        if (hostHasExecutable(QStringLiteral("node"))) return 1;
        return 0;
    }
    if (stem == QLatin1String("pnpm")) {
        return hostHasExecutable(QStringLiteral("pnpm")) ? 1 : 0;
    }
    if (stem == QLatin1String("bun")) {
        return hostHasExecutable(QStringLiteral("bun")) ? 1 : 0;
    }
    if (stem == QLatin1String("pipx")) {
        return hostHasExecutable(QStringLiteral("pipx")) ? 1 : 0;
    }
    if (stem == QLatin1String("pip")) {
        if (hostHasExecutable(QStringLiteral("pip"))) return 1;
        if (hostHasExecutable(QStringLiteral("pip3"))) return 1;
        return 0;
    }
    if (stem == QLatin1String("uv")) {
        return hostHasExecutable(QStringLiteral("uv")) ? 1 : 0;
    }
    if (stem == QLatin1String("brew")) {
        return hostHasExecutable(QStringLiteral("brew")) ? 1 : 0;
    }
    if (stem == QLatin1String("gem")) {
        return hostHasExecutable(QStringLiteral("gem")) ? 1 : 0;
    }
    if (stem == QLatin1String("composer")) {
        return hostHasExecutable(QStringLiteral("composer")) ? 1 : 0;
    }
    if (stem == QLatin1String("deno")) {
        return hostHasExecutable(QStringLiteral("deno")) ? 1 : 0;
    }
    return 1;
}

static int homePathTag(const char *xdgEnv, const QString &rel) {
    const QString env = QString::fromUtf8(qgetenv(xdgEnv)).trimmed();
    if (QDir::isAbsolutePath(env)) return QDir(env).exists() ? 1 : 0;
    return QDir::home().exists(rel) ? 1 : 0;
}

/* The load list is the built output, not a second hand-kept registry. It used
   to be 27 literal names duplicating core/build.sh's wasm_sources: a plugin
   built but not listed never activated, and the only cross-check counted
   modules, so the drift was silent. Sorted for a stable progress order. */
QStringList pluginWasmFiles(const QString &out) {
    QDir dir(out);
    const QStringList names = dir.entryList(
        QStringList{QStringLiteral("*.wasm")},
        QDir::Files,
        QDir::Name
    );
    QStringList paths;
    paths.reserve(names.size());
    for (const QString &n : names) {
        if (n == QLatin1String("appattic_core.wasm")) continue;
        paths << (out + QLatin1Char('/') + n);
    }
    return paths;
}

QStringList taggedPluginSpecs(const QString &out) {
    /* pluginTag resolves binaries through PATH, so the user tool dirs must be
       applied before tagging. runCoreWasm holds the inverse. */
    appattic_host_apply_user_path();
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
    size_t errlen,
    void (*onProgress)(const char *pluginId, int index, int total, void *user)
) {
    std::vector<QByteArray> specBytes;
    std::vector<char *> ptrs;
    specBytes.reserve(size_t(pluginSpecs.size()));
    ptrs.reserve(size_t(pluginSpecs.size()));
    for (const QString &s : pluginSpecs) specBytes.push_back(s.toUtf8());
    for (QByteArray &s : specBytes) ptrs.push_back(s.data());
    const QByteArray coreUtf8 = coreWasm.toUtf8();
    const int rc = appattic_wasm_run(
        coreUtf8.constData(),
        ptrs.empty() ? nullptr : ptrs.data(),
        int(ptrs.size()),
        onJson,
        onProgress,
        user,
        err,
        errlen
    );
    /* PATH is process-global. Undo the apply that taggedPluginSpecs made so a
       long-lived UI does not keep the scan's PATH after the scan ends. */
    appattic_host_restore_user_path();
    return rc;
}

void requestCoreWasmCancel() {
    appattic_host_exec_request_cancel();
}

void clearCoreWasmCancel() {
    appattic_host_exec_clear_cancel();
}

void restoreCoreWasmPath() {
    appattic_host_restore_user_path();
}
