FROM swift:5.10.1-jammy
ARG SOURCE_DATE_EPOCH=0
ENV LC_ALL=C
ENV LANG=C
ENV TZ=UTC
ENV SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}

LABEL org.opencontainers.image.title="AppAttic" \
      org.opencontainers.image.description="Build image for AppAttic: installs Qt 6, runs AppAtticScanTests, and links the CLI plus the Qt window." \
      org.opencontainers.image.source="https://github.com/maci0/appattic" \
      org.opencontainers.image.url="https://github.com/maci0/appattic" \
      org.opencontainers.image.licenses="LicenseRef-proprietary"

# linux-deps.sh sources verify-sha256.sh, find-zig.sh, find-wasmtime.sh,
# find-swift.sh and find-qt6.sh at startup, and find-zig.sh / find-swift.sh
# resolve the toolchain pin from .zig-version / .swift-version through $ROOT
# while they are being sourced, before argument parsing. A COPY carrying only
# linux-deps.sh and verify-sha256.sh aborts the build at that source with
# "find-zig.sh: No such file or directory" (or ".zig-version missing") before a
# single package is installed.
COPY scripts/linux-deps.sh \
     scripts/verify-sha256.sh \
     scripts/find-zig.sh \
     scripts/find-wasmtime.sh \
     scripts/find-swift.sh \
     scripts/find-qt6.sh \
     scripts/dep-checksums.sha256 \
     /tmp/appattic/scripts/
COPY .zig-version .swift-version /tmp/appattic/
RUN apt-get update \
    && apt-get install -y --no-install-recommends git \
    && bash /tmp/appattic/scripts/linux-deps.sh --install \
    && bash /tmp/appattic/scripts/linux-deps.sh --install-wasmtime \
    && rm -rf /var/lib/apt/lists/* /tmp/appattic
ENV WASMTIME_DIR=/opt/wasmtime-c-api

WORKDIR /src
COPY . .
# The image is a build image, not a runtime one: the last line compiles and
# runs the test suite and never starts a server, so a USER here would only
# break `apt`, the `/opt` toolchain installs, and the Qt smoke's own
# write to $HOME that scripts/linux-qt-link.sh sets up. The runtime posture
# is the packages, not the account.
#
# core/out/*.wasm, ui/linux-qt/build*, .build, dist and the archives under
# dist/.appimage-tools are build output. .dockerignore keeps them out of the
# context; this rm is the belt to that braces, because a context built with
# `docker build` honours .dockerignore and a context tarball piped in does
# not, and a stale core/out/*.wasm in the tree would be what the WASM gate
# loaded instead of the one this build produced.
RUN rm -rf .build .swiftpm .zig-cache .zig-cache-local core/out dist \
        ui/linux-qt/build ui/linux-qt/build-release
# AppAttic Qt 6 link is proven by scripts/linux-qt-link.sh (ldd libQt6Widgets + --smoke).
# The CLI build goes through scripts/swift-build.sh so the checkout path is
# mapped out of the binary, the same way every other build does it. The test
# run calls scripts/test.sh rather than a hand-written `swift test`: that is
# what CI calls, and it adds the .swift-version toolchain check and the
# refusal to report a pass over zero tests, so the image cannot go green on a
# filter that matched nothing.
RUN . scripts/swift-build.sh \
    && bash scripts/test.sh \
    && appattic_swift_build debug --product appattic \
    && bash scripts/linux-qt-link.sh \
    && bash scripts/verify-qt-link.sh
