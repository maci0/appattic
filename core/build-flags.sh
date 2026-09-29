# shellcheck shell=bash
# Sourced by core/build.sh and scripts/verify-reproducible.sh. Requires nothing.
#
# The compiler flag lists core/build.sh builds the shipped artifacts with,
# in one place. scripts/verify-reproducible.sh builds the artifacts it diffs
# from the same lists, so the check that proves the build reproducible
# compiles what the release compiles. Two copies meant a hardening flag or a
# zig setting added to the build did not reach the check.
#
# appattic_host_flags <build root> fills:
#   cc_cflags          per-file and optimization flags, build root mapped out
#   cc_ldflags         platform link flags
# cc_strict_warnings is the warning set both C compile lines carry, and
# zig_build_flags is what every WASM module is emitted with.

appattic_host_flags() {
    local root="$1"
    if [[ -z "$root" ]]; then
        echo "appattic_host_flags: needs the tree being built" >&2
        return 2
    fi
    cc_cflags=(-O2 -Wall -Wextra -fstack-protector-strong
        -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=2 -fPIE
        "-ffile-prefix-map=$root=." "-fdebug-prefix-map=$root=." "-fmacro-prefix-map=$root=.")
    cc_ldflags=()
    case "$(uname -s)" in
        Linux)
            cc_ldflags=(-pie "-Wl,-z,relro,-z,now" "-Wl,-z,noexecstack")
            cc_cflags+=(-fstack-clash-protection)
            case "$(uname -m)" in
                x86_64)
                    cc_cflags+=(-fcf-protection=full)
                    cc_ldflags+=(-fcf-protection=full)
                    ;;
                aarch64|arm64)
                    cc_cflags+=(-mbranch-protection=standard)
                    ;;
                *)
                    # An architecture with no branch-protection flag named for
                    # it still gets -fstack-clash-protection and the rest.
                    ;;
            esac
            ;;
        Darwin)
            cc_ldflags=("-Wl,-pie")
            ;;
        *)
            cc_ldflags=(-pie)
            ;;
    esac
}

# shellcheck disable=SC2034  # read by the scripts that source this file
cc_strict_warnings=(-Werror -Wformat=2 -Wformat-security -Wshadow
    -Wstrict-prototypes -Wconversion -Wpedantic -Wnull-dereference)

# Every WASM module is emitted with these, plus -femit-bin naming the artifact.
# shellcheck disable=SC2034  # read by the scripts that source this file
zig_build_flags=(-target wasm32-freestanding -fno-entry -rdynamic
    -OReleaseSmall -fstrip)

# Stamp the named files to SOURCE_DATE_EPOCH. The precompiled image beside a
# WASM module is bound to it by a `.cwasm.stamp` holding that module's size and
# mtime, and packaging ships the stamp as file content, so a module left at its
# own build mtime gives two builds of one source two different artifacts.
# BSD date has no -d and BSD touch has no -d @epoch, so the epoch is rendered to
# the one `touch -t` spelling both accept, and the stamp is applied with TZ=UTC
# because `touch -t` reads its argument in local time: rendering in UTC and
# applying in local time lands the file as far off as the zone is, and the
# offset is a different `.cwasm.stamp` on every host. With no epoch in the
# environment the files are left alone rather than stamped with a time of the
# build's own.
appattic_touch_epoch() {
    if [[ -z "${SOURCE_DATE_EPOCH:-}" ]]; then
        return 0
    fi
    local stamp
    case "$(uname -s)" in
        Darwin) stamp="$(date -u -r "$SOURCE_DATE_EPOCH" +%Y%m%d%H%M.%S)" ;;
        *) stamp="$(date -u -d "@${SOURCE_DATE_EPOCH}" +%Y%m%d%H%M.%S)" ;;
    esac
    TZ=UTC touch -t "$stamp" -- "$@"
}
