// Helper coverage for finding.cpp and diskusage.cpp. These tests need no scan
// and no wasm host, so they run in their own binary instead of inside the
// shipped Qt app (scripts/linux-qt-link.sh runs both).
#include "diskusage.h"
#include "finding.h"

#include <QDate>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
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

static int verifyHelpers() {
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
    QVector<Finding> largeSize;
    appendFindingsFromBlob(largeSize, QByteArrayLiteral(
        "{\"findings\":[{\"name\":\"large\",\"size_bytes\":9007199254740993}]}"));
    if (largeSize.size() != 1 || largeSize[0].bytes != Q_INT64_C(9007199254740993)) {
        std::fprintf(stderr, "64-bit JSON integer lost precision\n");
        return 1;
    }
    QVector<Finding> invalidSize;
    appendFindingsFromBlob(invalidSize, QByteArrayLiteral(
        "{\"findings\":[{\"name\":\"invalid\",\"size_bytes\":\"not-a-number\"}]}"));
    if (invalidSize.size() != 1 || invalidSize[0].bytes != -1) {
        std::fprintf(stderr, "invalid JSON integer treated as zero\n");
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
    if (!QFile::exists(QStringLiteral(":/icons/appattic.png"))) {
        std::fprintf(stderr, "icon: embedded :/icons/appattic.png missing\n");
        return 1;
    }
    if (pluginScanLabel(QStringLiteral("pacman")) != QLatin1String("Checking pacman packages")) {
        std::fprintf(stderr, "pluginScanLabel: pacman\n");
        return 1;
    }
    if (pluginScanLabel(QStringLiteral("aur")) != QLatin1String("Checking AUR packages")) {
        std::fprintf(stderr, "pluginScanLabel: aur\n");
        return 1;
    }
    if (pluginScanLabel(QStringLiteral("leftover-sizes"))
        != QLatin1String("Measuring leftover sizes")) {
        std::fprintf(stderr, "pluginScanLabel: leftover-sizes\n");
        return 1;
    }
    if (pluginScanLabel(QStringLiteral("path_home_dot"))
        != QLatin1String("Scanning leftover data in the home folder")) {
        std::fprintf(stderr, "pluginScanLabel: path_home_dot underscore\n");
        return 1;
    }
    if (pluginScanLabel(QStringLiteral("path-shadow")) != QLatin1String("Scanning PATH overlays")) {
        std::fprintf(stderr, "pluginScanLabel: path-shadow\n");
        return 1;
    }
    if (!pluginScanLabel(QStringLiteral("container-runtime")).contains(QLatin1String("container"))) {
        std::fprintf(stderr, "pluginScanLabel: container-runtime\n");
        return 1;
    }
    if (pluginScanLabel(QStringLiteral("deno")) != QLatin1String("Checking Deno global installs")) {
        std::fprintf(stderr, "pluginScanLabel: deno\n");
        return 1;
    }

    if (!outdatedIsUpdatable(QStringLiteral("apt"), QString())
        || !outdatedIsUpdatable(QStringLiteral("pacman"), QString())
        || !outdatedIsUpdatable(QStringLiteral("aur"), QString())
        || !outdatedIsUpdatable(QStringLiteral("dnf"), QString())
        || !outdatedIsUpdatable(QStringLiteral("yum"), QString())
        || !outdatedIsUpdatable(QStringLiteral("zypper"), QString())) {
        std::fprintf(stderr, "outdatedIsUpdatable: named distro upgrades must be updatable\n");
        return 1;
    }
    if (outdatedIsUpdatable(QStringLiteral("pip"), QString())
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
        "{\"plugin\":\"apt\",\"findings\":[{"
        "\"kind\":\"outdated\",\"id\":\"git\",\"name\":\"git\","
        "\"status\":\"outdated\",\"updatable\":true,"
        "\"command\":\"apt install --only-upgrade git\",\"manager\":\"apt\"}]}"));
    if (rows.size() != 1 || !rows[0].updatable
        || rows[0].updateCommand != QLatin1String("apt install --only-upgrade git")
        || !canMarkCleanup(rows[0], Page::Outdated)) {
        std::fprintf(stderr, "updatable: apt command must become the update action\n");
        return 1;
    }

    rows.clear();
    appendFindingsFromBlob(rows, QByteArrayLiteral(
        "{\"plugin\":\"pacman\",\"findings\":[{"
        "\"kind\":\"outdated\",\"id\":\"vim\",\"name\":\"vim\","
        "\"status\":\"outdated\",\"manager\":\"pacman\"}]}"));
    if (rows.size() != 1 || !rows[0].updatable) {
        std::fprintf(stderr, "updatable: omitted updatable should follow manager pacman\n");
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
    Finding leftover;
    leftover.plugin = QStringLiteral("path-home-dot");
    leftover.status = QStringLiteral("orphaned");
    leftover.kind = QStringLiteral("dir");
    leftover.path = QStringLiteral("/home/alice/.config/gone-app");
    leftover.extraPaths << QStringLiteral("/home/alice/.local/share/gone-app")
                        << QStringLiteral("/usr/share/gone-app");
    const QString rm = leftoverCleanupCommand(leftover);
    if (!rm.contains(QLatin1String("rm -rf ")) || !rm.contains(QLatin1Char('\''))
        || rm.contains(QLatin1String("rm -rf /home/alice"))
        || !rm.contains(QLatin1String("'/home/alice/.local/share/gone-app'"))
        || rm.contains(QLatin1String("/usr/share"))) {
        std::fprintf(stderr, "leftoverCleanupCommand: path leftover must be quoted rm -rf including extraPaths\n");
        return 1;
    }
    if (!canMarkCleanup(leftover, Page::Leftovers)) {
        std::fprintf(stderr, "canMarkCleanup: leftover row must be markable for the list tickbox\n");
        return 1;
    }
    Finding ppa;
    ppa.kind = QStringLiteral("ppa");
    ppa.status = QStringLiteral("review");
    ppa.path = QStringLiteral("/etc/apt/sources.list.d/deadsnakes-ubuntu-ppa-noble.list");
    const QString ppaRm = leftoverCleanupCommand(ppa);
    if (!ppaRm.contains(QLatin1String("rm -f "))
        || !ppaRm.contains(QLatin1String("'/etc/apt/sources.list.d/deadsnakes-ubuntu-ppa-noble.list'"))
        || !commandNeedsRoot(ppaRm)
        || !withRootCmd(ppaRm).startsWith(QLatin1String("rootcmd "))) {
        std::fprintf(stderr, "leftoverCleanupCommand: PPA source must be quoted rm -f after confirm\n");
        return 1;
    }
    if (!commandNeedsRoot(QStringLiteral("apt-get -y install --only-upgrade git"))
        || !commandNeedsRoot(QStringLiteral("pacman --noconfirm -S vim"))
        || !commandNeedsRoot(QStringLiteral("paru --noconfirm -S vim"))
        || !commandNeedsRoot(QStringLiteral("yay --noconfirm -S vim"))
        || !commandNeedsRoot(QStringLiteral("snap remove hello"))
        || commandNeedsRoot(QStringLiteral("rm -rf '/home/alice/.config/gone-app'"))
        || commandNeedsRoot(QStringLiteral("pip uninstall -y --user httpie"))
        || commandNeedsRoot(QStringLiteral("rm -rf '/home/alice/etc/apt/sources.list.d/x.list'"))) {
        std::fprintf(stderr, "commandNeedsRoot: distro/AUR/snap yes, user leftover/pip no\n");
        return 1;
    }
    Finding keepRm;
    keepRm.plugin = QStringLiteral("path-xdg-config");
    keepRm.kind = QStringLiteral("orphan-dir");
    keepRm.status = QStringLiteral("keep");
    keepRm.path = QStringLiteral("/home/alice/.mozilla");
    if (!leftoverCleanupCommand(keepRm).isEmpty()) {
        std::fprintf(stderr, "leftoverCleanupCommand: keep leftover must not emit rm\n");
        return 1;
    }
    Finding infixPpa;
    infixPpa.plugin = QStringLiteral("path-xdg-config");
    infixPpa.kind = QStringLiteral("orphan-dir");
    infixPpa.status = QStringLiteral("orphaned");
    infixPpa.path = QStringLiteral("/etc/foo/etc/apt/sources.list.d/x.list");
    if (!leftoverCleanupCommand(infixPpa).isEmpty()) {
        std::fprintf(stderr, "leftoverCleanupCommand: infix sources.list.d is not a PPA file\n");
        return 1;
    }
    Finding pkg;
    pkg.kind = QStringLiteral("orphan");
    pkg.name = QStringLiteral("libfoo0");
    pkg.command = QStringLiteral("apt-get purge -y libfoo0");
    pkg.children << QStringLiteral("libbar1");
    const QString childCmd = packageChildCommand(pkg, QStringLiteral("libbar1"));
    if (childCmd != QLatin1String("apt-get purge -y 'libbar1'")) {
        std::fprintf(stderr, "packageChildCommand: expected quoted child target (%s)\n",
            childCmd.toUtf8().constData());
        return 1;
    }
    if (!packageChildCommand(pkg, QStringLiteral("libbar1; rm -rf /")).isEmpty()) {
        std::fprintf(stderr, "packageChildCommand: metacharacters in child name\n");
        return 1;
    }
    QVector<Finding> grouped;
    Finding a;
    a.plugin = QStringLiteral("path-xdg-config");
    a.kind = QStringLiteral("orphan-dir");
    a.status = QStringLiteral("orphaned");
    a.name = QStringLiteral("gone-app");
    a.path = QStringLiteral("/home/alice/.config/gone-app");
    a.bytes = 10;
    Finding b;
    b.plugin = QStringLiteral("path-xdg-cache");
    b.kind = QStringLiteral("orphan-dir");
    b.status = QStringLiteral("orphaned");
    b.name = QStringLiteral("gone-app");
    b.path = QStringLiteral("/home/alice/.cache/gone-app");
    b.bytes = 20;
    grouped << a << b;
    groupLinuxLeftovers(grouped);
    if (grouped.size() != 1 || grouped[0].extraPaths.size() != 1
        || grouped[0].bytes != 30) {
        std::fprintf(stderr, "groupLinuxLeftovers: same-name leftovers must merge extraPaths\n");
        return 1;
    }
    QVector<Finding> keepGroup;
    Finding keepFx;
    keepFx.plugin = QStringLiteral("path-home-dot");
    keepFx.kind = QStringLiteral("orphan-dir");
    keepFx.status = QStringLiteral("keep");
    keepFx.name = QStringLiteral(".mozilla");
    keepFx.path = QStringLiteral("/home/alice/.mozilla");
    Finding orphanFx;
    orphanFx.plugin = QStringLiteral("path-xdg-config");
    orphanFx.kind = QStringLiteral("orphan-dir");
    orphanFx.status = QStringLiteral("orphaned");
    orphanFx.name = QStringLiteral("firefox");
    orphanFx.path = QStringLiteral("/home/alice/.config/firefox");
    keepGroup << keepFx << orphanFx;
    groupLinuxLeftovers(keepGroup);
    if (keepGroup.size() != 2) {
        std::fprintf(stderr, "groupLinuxLeftovers: keep leftover must not merge into an orphan\n");
        return 1;
    }
    QVector<Finding> aliasGroup;
    Finding moz;
    moz.plugin = QStringLiteral("path-home-dot");
    moz.kind = QStringLiteral("orphan-dir");
    moz.status = QStringLiteral("orphaned");
    moz.name = QStringLiteral(".mozilla");
    moz.path = QStringLiteral("/home/alice/.mozilla");
    moz.bytes = 5;
    Finding fx;
    fx.plugin = QStringLiteral("path-xdg-config");
    fx.kind = QStringLiteral("orphan-dir");
    fx.status = QStringLiteral("orphaned");
    fx.name = QStringLiteral("firefox");
    fx.path = QStringLiteral("/home/alice/.config/firefox");
    fx.bytes = 7;
    aliasGroup << moz << fx;
    groupLinuxLeftovers(aliasGroup);
    if (aliasGroup.size() != 1 || aliasGroup[0].extraPaths.size() != 1) {
        std::fprintf(stderr, "groupLinuxLeftovers: firefox/mozilla orphans must merge\n");
        return 1;
    }
    Finding snapOrphan;
    snapOrphan.plugin = QStringLiteral("snapd");
    snapOrphan.kind = QStringLiteral("orphan-dir");
    snapOrphan.path = QStringLiteral("/home/alice/snap/gone-app");
    const QString snapRm = leftoverCleanupCommand(snapOrphan);
    if (!snapRm.contains(QLatin1String("rm -rf ")) || !snapRm.contains(QLatin1Char('\''))) {
        std::fprintf(stderr, "leftoverCleanupCommand: snap orphan-dir must be quoted rm -rf\n");
        return 1;
    }
    QSet<QString> desks;
    desks.insert(QStringLiteral("firefox"));
    desks.insert(QStringLiteral("code"));
    if (!leftoverNameMatchesDesktop(QStringLiteral("firefox"), desks)
        || !leftoverNameMatchesDesktop(QStringLiteral("Code"), desks)
        || !leftoverNameMatchesDesktop(QStringLiteral(".mozilla"), desks)
        || leftoverNameMatchesDesktop(QStringLiteral("gone-app"), desks)
        || leftoverNameMatchesDesktop(QStringLiteral("firefox-esr"), desks)
        || leftoverNameMatchesDesktop(QStringLiteral("git"), desks)) {
        std::fprintf(stderr, "leftoverNameMatchesDesktop: installed desktop stem matching\n");
        return 1;
    }
    if (matchPage(leftover, Page::DiskUsage) || !matchPage(leftover, Page::Leftovers)) {
        std::fprintf(stderr, "disk: leftover must not appear on Disk Usage\n");
        return 1;
    }
    {
        QTemporaryDir tmp;
        if (!tmp.isValid()) {
            std::fprintf(stderr, "leftover size: temp dir failed\n");
            return 1;
        }
        const QString dir = tmp.path() + QStringLiteral("/gone-app");
        if (!QDir().mkpath(dir)) {
            std::fprintf(stderr, "leftover size: mkpath failed\n");
            return 1;
        }
        QFile f(dir + QStringLiteral("/data.bin"));
        if (!f.open(QIODevice::WriteOnly) || f.write(QByteArray(4096, 'x')) != 4096) {
            std::fprintf(stderr, "leftover size: write failed\n");
            return 1;
        }
        f.close();
        Finding sized;
        sized.plugin = QStringLiteral("path-xdg-config");
        sized.kind = QStringLiteral("orphan-dir");
        sized.status = QStringLiteral("orphaned");
        sized.path = dir;
        QVector<Finding> one;
        one << sized;
        enrichLeftoverSizes(one);
        if (one[0].bytes < 4096) {
            std::fprintf(stderr, "leftover size: expected measured bytes, got %lld\n",
                static_cast<long long>(one[0].bytes));
            return 1;
        }
        QVector<Finding> many;
        for (int i = 0; i < 8; ++i) {
            const QString sub = tmp.path() + QStringLiteral("/gone-%1").arg(i);
            if (!QDir().mkpath(sub)) {
                std::fprintf(stderr, "leftover size: parallel mkpath failed\n");
                return 1;
            }
            QFile part(sub + QStringLiteral("/data.bin"));
            if (!part.open(QIODevice::WriteOnly) || part.write(QByteArray(4096, 'x')) != 4096) {
                std::fprintf(stderr, "leftover size: parallel write failed\n");
                return 1;
            }
            part.close();
            Finding row = sized;
            row.path = sub;
            row.name = QStringLiteral("gone-%1").arg(i);
            many << row;
        }
        enrichLeftoverSizes(many);
        for (int i = 0; i < many.size(); ++i) {
            if (many[i].bytes < 4096) {
                std::fprintf(stderr, "leftover size: parallel %d got %lld\n",
                    i, static_cast<long long>(many[i].bytes));
                return 1;
            }
        }
        const QDir homeCfg(QDir::home().filePath(QStringLiteral(".config")));
        QString liveName;
        const QStringList prefer = {
            QStringLiteral("atopile"),
            QStringLiteral("cachyos-hello.json"),
            QStringLiteral("cachyos"),
        };
        for (const QString &n : prefer) {
            if (QFileInfo::exists(homeCfg.filePath(n))) {
                liveName = n;
                break;
            }
        }
        if (liveName.isEmpty()) {
            const QStringList files = homeCfg.entryList(QDir::Files);
            if (!files.isEmpty()) liveName = files.first();
        }
        if (homeCfg.exists() && !liveName.isEmpty()) {
            QJsonObject finding;
            finding.insert(QStringLiteral("kind"), QStringLiteral("orphan-dir"));
            finding.insert(QStringLiteral("name"), liveName);
            finding.insert(QStringLiteral("path"),
                QStringLiteral("/home/user/.config/") + liveName);
            finding.insert(QStringLiteral("status"), QStringLiteral("orphaned"));
            QJsonObject blob;
            blob.insert(QStringLiteral("plugin"), QStringLiteral("path-xdg-config"));
            blob.insert(QStringLiteral("findings"), QJsonArray{finding});
            QVector<Finding> live;
            appendFindingsFromBlob(live, QJsonDocument(blob).toJson(QJsonDocument::Compact));
            if (live.size() != 1) {
                std::fprintf(stderr, "leftover size: live leftover JSON ingest\n");
                return 1;
            }
            if (QDir::homePath() != QLatin1String("/home/user")
                && live[0].path.contains(QLatin1String("/home/user/"))) {
                std::fprintf(stderr, "leftover size: /home/user path not expanded (%s)\n",
                    live[0].path.toUtf8().constData());
                return 1;
            }
            if (!QFileInfo::exists(live[0].path)) {
                std::fprintf(stderr, "leftover size: expanded live path missing (%s)\n",
                    live[0].path.toUtf8().constData());
                return 1;
            }
            enrichLeftoverSizes(live);
            if (live[0].bytes < 0) {
                std::fprintf(stderr, "leftover size: live leftover still unknown (%s)\n",
                    live[0].path.toUtf8().constData());
                return 1;
            }
        }
    }
    Finding owned;
    owned.plugin = QStringLiteral("path-xdg-config");
    owned.status = QStringLiteral("keep");
    owned.kind = QStringLiteral("orphan-dir");
    owned.name = QStringLiteral("firefox");
    if (matchPage(owned, Page::Leftovers)) {
        std::fprintf(stderr, "leftovers: keep/owned leftover must not list on Leftovers\n");
        return 1;
    }
    return 0;
}

static int checkTiming() {
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
    if (expandHomeUserPlaceholder(
            QStringLiteral("/home/user/.config/gone-app"), home)
        != QStringLiteral("/home/alice/.config/gone-app")) {
        std::fprintf(stderr, "expand: /home/user path\n");
        return 1;
    }
    if (expandHomeUserPlaceholder(
            QStringLiteral("rm -rf /home/user/.config/gone-app"), home)
        != QStringLiteral("rm -rf /home/alice/.config/gone-app")) {
        std::fprintf(stderr, "expand: /home/user command\n");
        return 1;
    }
    if (expandHomeUserPlaceholder(QStringLiteral("/home/username/foo"), home)
        != QStringLiteral("/home/username/foo")) {
        std::fprintf(stderr, "expand: over-replaced username\n");
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

static int writeFile(const QString &path, const QByteArray &body) {
    QFile f(path);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate)) return 1;
    if (f.write(body) != body.size()) return 1;
    return 0;
}

static int checkDiskUsage() {
    QTemporaryDir tmp;
    if (!tmp.isValid()) {
        std::fprintf(stderr, "disk: temp dir failed\n");
        return 1;
    }
    const QString root = tmp.path();
    const QString sub = root + QStringLiteral("/big");
    if (!QDir().mkpath(sub)) {
        std::fprintf(stderr, "disk: mkpath failed\n");
        return 1;
    }
    const QByteArray payload(4096, 'x');
    if (writeFile(sub + QStringLiteral("/a.bin"), payload)
        || writeFile(root + QStringLiteral("/small.txt"), QByteArray("hi\n"))) {
        std::fprintf(stderr, "disk: write failed\n");
        return 1;
    }
    const QString linkDir = root + QStringLiteral("/linkdir");
    if (!QFile::link(sub, linkDir)) {
        std::fprintf(stderr, "disk: symlink failed\n");
        return 1;
    }

    DiskScanOptions opts;
    opts.oneFileSystem = true;
    DiskNode *tree = scanDiskTree(root, opts);
    if (!tree || tree->unreadable || tree->children.size() < 2) {
        std::fprintf(stderr, "disk: scan produced no children\n");
        delete tree;
        return 1;
    }
    const DiskNode *big = nullptr;
    const DiskNode *small = nullptr;
    const DiskNode *link = nullptr;
    for (const DiskNode *c : tree->children) {
        if (c->name == QLatin1String("big")) big = c;
        if (c->name == QLatin1String("small.txt")) small = c;
        if (c->name == QLatin1String("linkdir")) link = c;
    }
    if (!big || !big->isDir || big->apparent < 4096) {
        std::fprintf(stderr, "disk: big dir apparent size missing\n");
        delete tree;
        return 1;
    }
    if (!small || small->isDir || small->apparent < 3) {
        std::fprintf(stderr, "disk: small file missing\n");
        delete tree;
        return 1;
    }
    if (measurePathBytes(sub) < 4096) {
        std::fprintf(stderr, "disk: measurePathBytes missed the 4096-byte file\n");
        delete tree;
        return 1;
    }
    if (!link || link->isDir) {
        std::fprintf(stderr, "disk: directory symlink was followed\n");
        delete tree;
        return 1;
    }
    if (tree->apparent < big->apparent || tree->items < 3) {
        std::fprintf(stderr, "disk: root totals too small\n");
        delete tree;
        return 1;
    }
    tree->sortChildren(false);
    if (tree->children.isEmpty() || tree->children[0]->name != QLatin1String("big")) {
        std::fprintf(stderr, "disk: sort by apparent did not put big first\n");
        delete tree;
        return 1;
    }
    delete tree;
    tree = nullptr;

    const QString many = root + QStringLiteral("/many");
    if (!QDir().mkpath(many)) {
        std::fprintf(stderr, "disk: many mkpath failed\n");
        return 1;
    }
    for (int i = 0; i < 200; ++i) {
        const QString n = QStringLiteral("%1/f%2.txt").arg(many).arg(i);
        if (writeFile(n, QByteArray("x\n"))) {
            std::fprintf(stderr, "disk: many write failed\n");
            return 1;
        }
    }
    tree = scanDiskTree(root, opts);
    if (!tree || tree->unreadable) {
        std::fprintf(stderr, "disk: rescan after many files failed\n");
        delete tree;
        return 1;
    }
    const DiskNode *manyNode = nullptr;
    for (const DiskNode *c : tree->children) {
        if (c->name == QLatin1String("many")) manyNode = c;
    }
    if (!manyNode || !manyNode->isDir || manyNode->children.size() < 200) {
        std::fprintf(stderr, "disk: getdents listing missed files (%d)\n",
            manyNode ? int(manyNode->children.size()) : -1);
        delete tree;
        return 1;
    }
    const QString linkRoot = root + QStringLiteral("/rootlink");
    if (!QFile::link(sub, linkRoot)) {
        std::fprintf(stderr, "disk: root symlink failed\n");
        delete tree;
        return 1;
    }
    delete tree;
    tree = scanDiskTree(linkRoot, opts);
    if (!tree || tree->unreadable || tree->children.isEmpty()) {
        std::fprintf(stderr, "disk: scan of directory symlink root failed\n");
        delete tree;
        return 1;
    }
    bool sawBin = false;
    for (const DiskNode *c : tree->children) {
        if (c->name == QLatin1String("a.bin")) sawBin = true;
    }
    if (!sawBin) {
        std::fprintf(stderr, "disk: symlink root did not follow to contents\n");
        delete tree;
        return 1;
    }
    delete tree;

    const QVector<DiskVolume> vols = listDiskVolumes();
    bool hasRoot = false;
    for (const DiskVolume &v : vols) {
        if (v.isRoot && v.bytesTotal > 0) hasRoot = true;
        if (v.rootPath == QLatin1String("/proc")) {
            std::fprintf(stderr, "disk: listed virtual /proc\n");
            return 1;
        }
        if (v.fileSystem.toLower() == QLatin1String("tmpfs")
            && v.rootPath != QLatin1String("/")
            && !v.isHome) {
            std::fprintf(stderr, "disk: listed tmpfs %s\n", v.rootPath.toUtf8().constData());
            return 1;
        }
        if (v.rootPath == QLatin1String("/run")
            || v.rootPath.startsWith(QLatin1String("/run/"))) {
            std::fprintf(stderr, "disk: listed /run mount %s\n", v.rootPath.toUtf8().constData());
            return 1;
        }
    }
    if (!hasRoot) {
        std::fprintf(stderr, "disk: file system volume missing\n");
        return 1;
    }
    if (diskContentsLabel(1, true) != QLatin1String("Empty")) {
        std::fprintf(stderr, "disk: empty contents label\n");
        return 1;
    }
    if (diskContentsLabel(5, true) != QLatin1String("4 items")) {
        std::fprintf(stderr, "disk: items label\n");
        return 1;
    }
    std::fprintf(stdout, "disk: ok\n");
    return 0;
}

int main() {
    const int checks[] = {
        verifyHelpers(), checkPrivacy(), checkTiming(), checkDiskUsage(),
    };
    for (const int rc : checks) {
        if (rc != 0) return rc;
    }
    std::fprintf(stdout, "helpers: ok\n");
    return 0;
}
