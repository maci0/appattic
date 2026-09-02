#include "smoke.h"

#include "corehost.h"
#include "finding.h"

#include <QApplication>
#include <QByteArray>
#include <QCoreApplication>
#include <QDate>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileDevice>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonValue>
#include <QSet>
#include <QString>
#include <QStringList>
#include <QTemporaryDir>
#include <QTime>
#include <QTimeZone>
#include <QVector>

#include <cstddef>
#include <cstdio>
#include <cstring>

struct SmokeState {
    int plugins = 0;
    bool path_shadow_plugin = false;
    int path_shadow_findings = 0;
    bool leftover_path_plugin = false;
    bool path_home_dot_active = false;
    bool flatpak_plugin = false;
    int flatpak_unused_runtime = 0;
    int raw_outdated_kind = 0;
    QVector<Finding> findings;
};

static void smokeCollectJson(const char *json, size_t len, void *user) {
    auto *st = static_cast<SmokeState *>(user);
    st->plugins += 1;
    const QByteArray line(json, int(len));
    appendFindingsFromBlob(st->findings, line);

    const QJsonDocument doc = QJsonDocument::fromJson(line);
    if (!doc.isObject()) return;
    const QJsonObject obj = doc.object();
    const QString plugin = obj.value(QStringLiteral("plugin")).toString();
    const QJsonArray arr = obj.value(QStringLiteral("findings")).toArray();
    const int n = arr.size();

    if (plugin == QLatin1String("path-shadow")) {
        st->path_shadow_plugin = true;
        st->path_shadow_findings = n;
    }
    if (plugin.startsWith(QLatin1String("path-"))) {
        st->leftover_path_plugin = true;
    }
    if (plugin == QLatin1String("path-home-dot") && n > 0) {
        st->path_home_dot_active = true;
    }
    if (plugin == QLatin1String("flatpak")) {
        st->flatpak_plugin = true;
        for (const QJsonValue &v : arr) {
            const QJsonObject f = v.toObject();
            if (jsonStr(f, "kind") == QLatin1String("unused-runtime")) {
                st->flatpak_unused_runtime += 1;
            }
        }
    }
    for (const QJsonValue &v : arr) {
        const QJsonObject f = v.toObject();
        const QString kind = jsonStr(f, "kind");
        if (kind.contains(QLatin1String("outdated")) || kind.contains(QLatin1String("upgrade"))) {
            st->raw_outdated_kind += 1;
        }
    }
}

static int smokeVerifyHelpers() {
    if (humanSize(0) != QLatin1String("0 B")) {
        std::fprintf(stderr, "humanSize(0) mismatch\n");
        return 1;
    }
    if (humanSize(1024) != QLatin1String("1.0 KB")) {
        std::fprintf(stderr, "humanSize(1024) mismatch\n");
        return 1;
    }
    if (humanSize(1048525) != QLatin1String("1.0 MB")) {
        std::fprintf(stderr, "humanSize(1048525) should bump 1024.0 KB to 1.0 MB\n");
        return 1;
    }
    if (humanSize(1023 * 1024) != QLatin1String("1023.0 KB")) {
        std::fprintf(stderr, "humanSize(1023 KiB) mismatch\n");
        return 1;
    }
    Finding f;
    f.path = QString::fromUtf8("/tmp/Cafe\xCC\x81");
    QSet<QString> ignored;
    ignored.insert(pathIdentityKey(QString::fromUtf8("/tmp/Caf\xC3\xA9")));
    if (!leftoverIsIgnored(f, ignored)) {
        std::fprintf(stderr, "leftoverIsIgnored NFC/NFD mismatch\n");
        return 1;
    }
    if (scriptHasCommands(QStringLiteral("#!/bin/sh\nset -e\n# comment\n"))) {
        std::fprintf(stderr, "scriptHasCommands preamble-only should be empty\n");
        return 1;
    }
    if (!scriptHasCommands(QStringLiteral("#!/bin/sh\nset -e\nrm -rf /tmp/x\n"))) {
        std::fprintf(stderr, "scriptHasCommands missed rm\n");
        return 1;
    }

    if (outdatedIsUpdatable(QStringLiteral("apt"), QString())
        || outdatedIsUpdatable(QStringLiteral("pacman"), QString())
        || outdatedIsUpdatable(QStringLiteral("dnf"), QString())
        || outdatedIsUpdatable(QStringLiteral("zypper"), QString())
        || outdatedIsUpdatable(QStringLiteral("pip"), QString())
        || outdatedIsUpdatable(QStringLiteral("snapd"), QString())
        || outdatedIsUpdatable(QStringLiteral("brew-cask"), QStringLiteral("untrusted"))) {
        std::fprintf(stderr, "outdatedIsUpdatable: report-only manager or untrusted cask\n");
        return 1;
    }
    if (outdatedIsUpdatable(QStringLiteral("flatpak"), QStringLiteral("unused-runtime"))
        || outdatedIsUpdatable(QStringLiteral("flatpak"), QStringLiteral("orphan"))) {
        std::fprintf(stderr,
            "outdatedIsUpdatable: non-outdated kind must not inherit an update action\n");
        return 1;
    }
    if (!outdatedIsUpdatable(QStringLiteral("brew-formula"), QString())
        || !outdatedIsUpdatable(QStringLiteral("brew-cask"), QString())
        || !outdatedIsUpdatable(QStringLiteral("flatpak"), QString())
        || !outdatedIsUpdatable(QStringLiteral("flatpak"), QStringLiteral("outdated"))) {
        std::fprintf(stderr, "outdatedIsUpdatable: brew/flatpak must be updatable\n");
        return 1;
    }

    QVector<Finding> rows;
    appendFindingsFromBlob(rows, QByteArrayLiteral(
        "{\"plugin\":\"apt\",\"findings\":[{"
        "\"kind\":\"outdated\",\"id\":\"git\",\"name\":\"git\","
        "\"current_version\":\"1.0\",\"latest_version\":\"2.0\","
        "\"status\":\"outdated\",\"updatable\":false,"
        "\"command\":\"apt install --only-upgrade git\",\"manager\":\"apt\"}]}"));
    if (rows.size() != 1 || !isOutdated(rows[0]) || rows[0].updatable
        || canMarkCleanup(rows[0], Page::Outdated)) {
        std::fprintf(stderr, "updatable: apt status=outdated must not override updatable:false\n");
        return 1;
    }

    rows.clear();
    appendFindingsFromBlob(rows, QByteArrayLiteral(
        "{\"plugin\":\"brew\",\"findings\":[{"
        "\"kind\":\"outdated\",\"id\":\"wget\",\"name\":\"wget\","
        "\"status\":\"outdated\",\"updatable\":true,"
        "\"command\":\"brew upgrade wget\",\"manager\":\"brew-formula\"}]}"));
    if (rows.size() != 1 || !rows[0].updatable || !canMarkCleanup(rows[0], Page::Outdated)) {
        std::fprintf(stderr, "updatable: brew-formula with updatable:true\n");
        return 1;
    }

    rows.clear();
    appendFindingsFromBlob(rows, QByteArrayLiteral(
        "{\"plugin\":\"brew\",\"findings\":[{"
        "\"kind\":\"untrusted\",\"id\":\"sketchy\",\"name\":\"sketchy\","
        "\"status\":\"outdated\",\"updatable\":true,\"manager\":\"brew-cask\"}]}"));
    if (rows.size() != 1 || rows[0].updatable || canMarkCleanup(rows[0], Page::Outdated)) {
        std::fprintf(stderr, "updatable: untrusted must win over updatable:true\n");
        return 1;
    }

    rows.clear();
    appendFindingsFromBlob(rows, QByteArrayLiteral(
        "{\"plugin\":\"pacman\",\"findings\":[{"
        "\"kind\":\"outdated\",\"id\":\"vim\",\"name\":\"vim\","
        "\"status\":\"outdated\",\"manager\":\"pacman\"}]}"));
    if (rows.size() != 1 || rows[0].updatable) {
        std::fprintf(stderr, "updatable: omitted updatable must not infer from status\n");
        return 1;
    }

    rows.clear();
    appendFindingsFromBlob(rows, QByteArrayLiteral(
        "{\"plugin\":\"brew\",\"findings\":[{"
        "\"kind\":\"outdated\",\"id\":\"cask\",\"name\":\"cask\","
        "\"status\":\"outdated\",\"manager\":\"brew-cask\"}]}"));
    if (rows.size() != 1 || !rows[0].updatable) {
        std::fprintf(stderr, "updatable: omitted updatable should follow manager brew-cask\n");
        return 1;
    }
    return 0;
}

static int smokeVerifyTables(const SmokeState &st) {
    const QVector<Finding> &findings = st.findings;
    if (findings.isEmpty()) {
        std::fprintf(stderr, "tables: no findings parsed from plugin JSON\n");
        return 1;
    }

    const int leftovers = countPageRows(findings, Page::Leftovers);
    const int stale = countPageRows(findings, Page::Stale);
    const int outdated = countPageRows(findings, Page::Outdated);
    const int packages = countPageRows(findings, Page::Packages);

    int pathLeftovers = 0;
    bool hasMozilla = false;
    bool hasWine = false;
    int shadowLeftovers = 0;
    int flatpakUnusedAsPackage = 0;

    for (const Finding &f : findings) {
        if (f.plugin.startsWith(QLatin1String("path-")) && isLeftover(f)) {
            ++pathLeftovers;
            if (f.path.contains(QLatin1String(".mozilla"))) hasMozilla = true;
            if (f.path.contains(QLatin1String(".wine"))) hasWine = true;
        }
        if (f.plugin == QLatin1String("path-shadow") && isLeftover(f)) {
            ++shadowLeftovers;
        }
        if (f.plugin == QLatin1String("flatpak") && f.kind == QLatin1String("unused-runtime")) {
            if (!isPackage(f)) {
                std::fprintf(stderr,
                    "tables: flatpak unused-runtime not classified as package (%s)\n",
                    f.id.toUtf8().constData());
                return 1;
            }
            ++flatpakUnusedAsPackage;
        }
        if (isLeftover(f) && !matchPage(f, Page::Leftovers)) {
            std::fprintf(stderr, "tables: leftover finding not in Leftovers table\n");
            return 1;
        }
        if (isOutdated(f) && !matchPage(f, Page::Outdated)) {
            std::fprintf(stderr, "tables: outdated finding not in Outdated table\n");
            return 1;
        }
        if (isPackage(f) && !matchPage(f, Page::Packages)) {
            std::fprintf(stderr, "tables: package finding not in Packages table\n");
            return 1;
        }
        if (isStale(f) && !matchPage(f, Page::Stale)) {
            std::fprintf(stderr, "tables: stale finding not in Stale table\n");
            return 1;
        }
        if (isOutdated(f)) {
            const QString plug = f.plugin;
            const bool distro = plug == QLatin1String("apt") || plug == QLatin1String("pacman")
                || plug == QLatin1String("dnf") || plug == QLatin1String("zypper")
                || plug == QLatin1String("snapd") || plug == QLatin1String("gem")
                || plug == QLatin1String("composer") || plug == QLatin1String("pip");
            if (distro && f.updatable) {
                std::fprintf(stderr, "tables: distro outdated marked updatable (%s %s)\n",
                    plug.toUtf8().constData(), f.name.toUtf8().constData());
                return 1;
            }
            if (distro && canMarkCleanup(f, Page::Outdated)) {
                std::fprintf(stderr, "tables: distro outdated selectable on Outdated (%s %s)\n",
                    plug.toUtf8().constData(), f.name.toUtf8().constData());
                return 1;
            }
            if (plug == QLatin1String("brew") && !f.updatable) {
                std::fprintf(stderr, "tables: brew outdated not updatable (%s)\n",
                    f.name.toUtf8().constData());
                return 1;
            }
        }
    }

    if (pathLeftovers < 1) {
        std::fprintf(stderr, "tables: no path-* leftover findings (classifier/ingest broken)\n");
        return 1;
    }
    if (st.path_home_dot_active) {
        if (!hasMozilla || !hasWine) {
            std::fprintf(stderr,
                "tables: path-home-dot active but missing .mozilla/.wine fixture paths\n");
            return 1;
        }
        if (stale < 1) {
            std::fprintf(stderr,
                "tables: path-home-dot leftovers with timing not classified as stale\n");
            return 1;
        }
    }
    // path-shadow: only assert when plugin returned findings (tag 1 / overlay dirs present).
    if (st.path_shadow_findings > 0 && shadowLeftovers < 1) {
        std::fprintf(stderr, "tables: path-shadow findings not classified as leftovers\n");
        return 1;
    }
    // Outdated: only assert when fixtures emitted outdated-kind rows.
    if (st.raw_outdated_kind > 0 && outdated < 1) {
        std::fprintf(stderr, "tables: outdated fixture rows not classified as outdated\n");
        return 1;
    }
    // flatpak unused-runtime: only assert when flatpak plugin returned them.
    if (st.flatpak_unused_runtime > 0 && flatpakUnusedAsPackage < st.flatpak_unused_runtime) {
        std::fprintf(stderr, "tables: flatpak unused-runtime not routed to Packages\n");
        return 1;
    }

    std::fprintf(stdout, "tables: ok (leftovers=%d stale=%d outdated=%d packages=%d)\n",
        leftovers, stale, outdated, packages);
    return 0;
}

int smokeTiming() {
    const QDateTime z = parseIsoInstant(QStringLiteral("2026-08-17T12:30:00Z"));
    const QDateTime offset = parseIsoInstant(QStringLiteral("2026-08-17T12:30:00+00:00"));
    if (!z.isValid() || !offset.isValid()
        || qAbs(z.toUTC().toSecsSinceEpoch() - offset.toUTC().toSecsSinceEpoch()) > 0) {
        std::fprintf(stderr, "timing: Z and +00:00 must be the same instant\n");
        return 1;
    }
    const QDateTime naive = parseIsoInstant(QStringLiteral("2026-04-01T15:00:00"));
    const QDateTime naiveZ = parseIsoInstant(QStringLiteral("2026-04-01T15:00:00Z"));
    if (!naive.isValid() || naive.toUTC().toSecsSinceEpoch() != naiveZ.toUTC().toSecsSinceEpoch()) {
        std::fprintf(stderr, "timing: timezone-less ISO must be UTC\n");
        return 1;
    }
    const QDateTime micro = parseIsoInstant(QStringLiteral("2026-04-01T15:00:00.123456Z"));
    if (!micro.isValid()
        || qAbs(micro.toMSecsSinceEpoch() - naiveZ.toMSecsSinceEpoch() - 123) > 1) {
        std::fprintf(stderr, "timing: XBEL microseconds truncated to millis\n");
        return 1;
    }

    Finding idle;
    idle.idleDays = 120;
    if (modifiedLabel(idle) != QLatin1String("120 days ago")) {
        std::fprintf(stderr, "timing: idleDays label\n");
        return 1;
    }
    Finding today;
    today.mtime = QDateTime::currentDateTimeUtc().toString(Qt::ISODate);
    if (modifiedLabel(today) != QLatin1String("Today")) {
        std::fprintf(stderr, "timing: current UTC mtime should be Today (%s)\n",
            modifiedLabel(today).toUtf8().constData());
        return 1;
    }

    const QTimeZone ny(QByteArray("America/New_York"));
    if (ny.isValid()) {
        // 2026-03-08 04:30 UTC is 2026-03-07 23:30 EST (spring-forward is 07:00 UTC).
        const QDateTime utc = parseIsoInstant(QStringLiteral("2026-03-08T04:30:00Z"));
        if (!utc.isValid() || utc.toTimeZone(ny).date() != QDate(2026, 3, 7)) {
            std::fprintf(stderr, "timing: UTC instant must be previous local day in New York\n");
            return 1;
        }
        Finding crossed;
        crossed.mtime = QStringLiteral("2026-03-08T04:30:00Z");
        const QDateTime nyNow(QDate(2026, 9, 2), QTime(12, 0), ny);
        if (modifiedLabel(crossed, nyNow) != QLatin1String("2026-03-07")) {
            std::fprintf(stderr,
                "timing: UTC prefix must not win over local date (%s)\n",
                modifiedLabel(crossed, nyNow).toUtf8().constData());
            return 1;
        }
        const QDateTime saturday(QDate(2026, 3, 7), QTime(23, 30), ny);
        const QDateTime sunday(QDate(2026, 3, 8), QTime(22, 30), ny);
        if (saturday.secsTo(sunday) >= 86400) {
            std::fprintf(stderr, "timing: expected spring-forward elapsed < 24h\n");
            return 1;
        }
        if (saturday.toTimeZone(ny).date().daysTo(sunday.toTimeZone(ny).date()) != 1) {
            std::fprintf(stderr, "timing: spring-forward must still be one local calendar day\n");
            return 1;
        }
        const QDateTime morning(QDate(2026, 11, 1), QTime(0, 0), ny);
        const QDateTime evening(QDate(2026, 11, 1), QTime(23, 30), ny);
        if (morning.secsTo(evening) <= 86400) {
            std::fprintf(stderr, "timing: expected fall-back elapsed > 24h\n");
            return 1;
        }
        if (morning.toTimeZone(ny).date().daysTo(evening.toTimeZone(ny).date()) != 0) {
            std::fprintf(stderr, "timing: fall-back same local day must stay today\n");
            return 1;
        }
    }

    Finding dateOnly;
    dateOnly.mtime = QStringLiteral("2026-08-17");
    const QString dateLabel = modifiedLabel(dateOnly);
    if (dateLabel == QLatin1String("-")) {
        std::fprintf(stderr, "timing: date-only mtime must parse\n");
        return 1;
    }

    std::fprintf(stdout, "timing: ok\n");
    return 0;
}

static int checkPrivacy() {
    const QString home = QStringLiteral("/home/alice");
    const QString redacted = redactHomePaths(
        QStringLiteral("rm: cannot remove '/home/alice/Library/Caches/Foo': Permission denied"),
        home);
    if (redacted.contains(QLatin1String("/home/alice"))) {
        std::fprintf(stderr, "redact: home path remains (%s)\n", redacted.toUtf8().constData());
        return 1;
    }
    if (!redacted.contains(QLatin1String("~/Library/Caches/Foo"))) {
        std::fprintf(stderr, "redact: expected tilde path (%s)\n", redacted.toUtf8().constData());
        return 1;
    }
    const QString neighbor = redactHomePaths(QStringLiteral("/home/alice2/secret"), home);
    if (!neighbor.contains(QLatin1String("/home/alice2"))) {
        std::fprintf(stderr, "redact: over-redacted neighbor home\n");
        return 1;
    }
    QTemporaryDir tmp;
    if (!tmp.isValid()) {
        std::fprintf(stderr, "redact: temp dir failed\n");
        return 1;
    }
    const QString dir = tmp.filePath(QStringLiteral("appattic"));
    if (!QDir().mkpath(dir)) {
        std::fprintf(stderr, "redact: mkpath failed\n");
        return 1;
    }
    const QString path = dir + QStringLiteral("/settings.json");
    QFile f(path);
    if (!f.open(QIODevice::WriteOnly) || f.write("{}") != 2) {
        std::fprintf(stderr, "redact: write failed\n");
        return 1;
    }
    f.close();
    restrictPrivateDataFile(path);
    const QFile::Permissions filePerms = QFileInfo(path).permissions();
    const QFile::Permissions dirPerms = QFileInfo(dir).permissions();
    if (filePerms & (QFileDevice::ReadGroup | QFileDevice::ReadOther
            | QFileDevice::WriteGroup | QFileDevice::WriteOther)) {
        std::fprintf(stderr, "redact: settings file is group/other readable\n");
        return 1;
    }
    if (dirPerms & (QFileDevice::ReadGroup | QFileDevice::ReadOther
            | QFileDevice::ExeGroup | QFileDevice::ExeOther)) {
        std::fprintf(stderr, "redact: appattic dir is group/other accessible\n");
        return 1;
    }
    std::fprintf(stdout, "redact: ok\n");
    return 0;
}

int runVersion(int argc, char **argv) {
    if (qEnvironmentVariableIsEmpty("QT_QPA_PLATFORM")
        && qEnvironmentVariableIsEmpty("DISPLAY")
        && qEnvironmentVariableIsEmpty("WAYLAND_DISPLAY")) {
        qputenv("QT_QPA_PLATFORM", "offscreen");
    }
    QApplication app(argc, argv);
    QApplication::setApplicationName(QStringLiteral("AppAttic"));
    QApplication::setOrganizationName(QStringLiteral("AppAttic"));
    std::fprintf(stdout, "AppAttic 1.1.0\n");
    std::fprintf(stdout, "Qt %s\n", qVersion());
    const QString out = coreOutDir();
    const QString core = out + QStringLiteral("/appattic_core.wasm");
    if (!QFileInfo::exists(core)) {
        std::fprintf(stdout, "wasm: core missing (%s)\n", core.toUtf8().constData());
    } else {
        std::fprintf(stdout, "wasm: core present\n");
    }
    return 0;
}

int runSmoke(int argc, char **argv) {
    if (qEnvironmentVariableIsEmpty("QT_QPA_PLATFORM")
        && qEnvironmentVariableIsEmpty("DISPLAY")
        && qEnvironmentVariableIsEmpty("WAYLAND_DISPLAY")) {
        qputenv("QT_QPA_PLATFORM", "offscreen");
    }
    qputenv("APPATTIC_HOST_EXEC_FIXTURE", "1");
    QApplication app(argc, argv);
    QApplication::setApplicationName(QStringLiteral("AppAttic"));
    QApplication::setOrganizationName(QStringLiteral("AppAttic"));
    std::fprintf(stdout, "AppAttic 1.1.0\n");
    std::fprintf(stdout, "Qt %s\n", qVersion());
    if (smokeVerifyHelpers() != 0) {
        return 1;
    }
    if (const int prc = checkPrivacy()) return prc;

    const QString out = coreOutDir();
    const QString core = out + QStringLiteral("/appattic_core.wasm");
    if (!QFileInfo::exists(core)) {
        std::fprintf(stderr, "wasm: core missing (%s)\n", core.toUtf8().constData());
        std::fprintf(stderr, "build with: bash core/build.sh\n");
        return 1;
    }
    const QStringList plugins = pluginWasmFiles(out);
    int wasm_on_disk = 0;
    for (const QString &p : plugins) {
        if (QFileInfo::exists(p)) ++wasm_on_disk;
    }
    if (wasm_on_disk < 5) {
        std::fprintf(stderr, "wasm: too few plugin modules on disk (%d/%d)\n",
            wasm_on_disk, int(plugins.size()));
        return 1;
    }
    SmokeState st;
    char err[1024];
    err[0] = '\0';
    const int rc = runCoreWasm(
        core,
        taggedPluginSpecs(out),
        smokeCollectJson,
        &st,
        err,
        sizeof err
    );
    if (rc != 0) {
        std::fprintf(stderr, "wasm query failed: %s\n", err[0] ? err : "(no detail)");
        return 1;
    }
    if (st.plugins < 1) {
        std::fprintf(stderr, "wasm: no plugin JSON returned\n");
        return 1;
    }
    if (!st.path_shadow_plugin) {
        std::fprintf(stderr, "wasm: path-shadow plugin missing from scan output\n");
        return 1;
    }
    if (!st.leftover_path_plugin) {
        std::fprintf(stderr, "wasm: no path-* leftover plugin JSON returned\n");
        return 1;
    }
    if (smokeVerifyTables(st) != 0) {
        return 1;
    }
    std::fprintf(stdout, "plugin:path-shadow\n");
    std::fprintf(stdout, "wasm: ok (%d plugins)\n", st.plugins);
    std::fprintf(stdout, "SMOKE=ok\n");
    return 0;
}
