#include "corehost.h"
#include "embed.h"
#include "hostexec.h"

#include <QByteArray>
#include <QCoreApplication>
#include <QDir>
#include <QFileInfo>
#include <QStandardPaths>

#include <initializer_list>
#include <vector>

static int homePathTag(const char *xdgEnv, const QString &rel);

/* An empty, padded, or relative APPATTIC_CORE_OUT is ignored and the
   candidates below are searched, the rule every other path-valued variable
   here follows (XDG_RUNTIME_DIR in diskpage.cpp, the XDG roots in
   finding.cpp, `core/host/hostexec.c`). Used verbatim, a value that arrives
   padded or relative named a directory that holds no appattic_core.wasm, and
   the window said the engine was missing while naming a path the user never
   typed. A trailing separator is dropped for the same reason as everywhere
   else: the caller appends "/appattic_core.wasm", and POSIX leaves a doubled
   separator implementation-defined. The root itself may be "/". */
QString coreOutDir() {
    const QString env = QString::fromUtf8(qgetenv("APPATTIC_CORE_OUT")).trimmed();
    if (QDir::isAbsolutePath(env)) {
        QString root = env;
        while (root.size() > 1 && root.endsWith(QLatin1Char('/'))) root.chop(1);
        return root;
    }

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

/* A plugin runs only when its host dependency answers. Three shapes cover
   every stem: an executable on PATH, an XDG root (an absolute override wins),
   or a home-relative directory. Anything else loads with tag 1. */
struct ExecRule {
    const char *stem;
    std::initializer_list<const char *> names;
};
static const ExecRule kExecRules[] = {
    {"snapd", {"snap"}},
    {"pacman", {"pacman"}},
    {"aur", {"paru", "yay", "pikaur"}},
    {"apt", {"apt-get", "apt", "dpkg"}},
    {"dnf", {"dnf5", "dnf", "yum"}},
    {"zypper", {"zypper"}},
    {"flatpak", {"flatpak"}},
    {"npm", {"npm", "node"}},
    {"pnpm", {"pnpm"}},
    {"bun", {"bun"}},
    {"pipx", {"pipx"}},
    {"pip", {"pip", "pip3"}},
    {"uv", {"uv"}},
    {"brew", {"brew"}},
    {"gem", {"gem"}},
    {"composer", {"composer"}},
    {"deno", {"deno"}},
};

struct XdgRule {
    const char *stem;
    const char *env;
    const char *rel;
};
static const XdgRule kXdgRules[] = {
    {"path_xdg_config", "XDG_CONFIG_HOME", ".config"},
    {"path_xdg_data", "XDG_DATA_HOME", ".local/share"},
    {"path_xdg_cache", "XDG_CACHE_HOME", ".cache"},
    {"path_xdg_state", "XDG_STATE_HOME", ".local/state"},
};

struct HomeRule {
    const char *stem;
    std::initializer_list<const char *> dirs;
};
static const HomeRule kHomeRules[] = {
    {"path_xdg_lib", {".local/lib"}},
    {"path_var_app", {".var/app"}},
    {"path_user_bin", {".local/bin", "bin"}},
    {"path_shadow", {".local/bin", "bin", ".cargo/bin", ".local/share/applications"}},
};

static int pluginTag(const QString &wasmPath) {
    const QFileInfo fi(wasmPath);
    const QString stem = fi.completeBaseName();
    if (stem == QLatin1String("container_runtime")) {
        if (hostHasExecutable(QStringLiteral("podman"))) return 2;
        if (hostHasExecutable(QStringLiteral("docker"))) return 1;
        return 0;
    }
    if (stem == QLatin1String("path_home_dot")) {
        return QDir::home().exists() ? 1 : 0;
    }
    for (const XdgRule &r : kXdgRules) {
        if (stem == QLatin1String(r.stem)) {
            return homePathTag(r.env, QString::fromUtf8(r.rel));
        }
    }
    for (const HomeRule &r : kHomeRules) {
        if (stem != QLatin1String(r.stem)) continue;
        for (const char *dir : r.dirs) {
            if (QDir::home().exists(QString::fromUtf8(dir))) return 1;
        }
        return 0;
    }
    for (const ExecRule &r : kExecRules) {
        if (stem != QLatin1String(r.stem)) continue;
        for (const char *name : r.names) {
            if (hostHasExecutable(QString::fromUtf8(name))) return 1;
        }
        return 0;
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

void shutdownCoreWasm() {
    appattic_wasm_shutdown();
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
