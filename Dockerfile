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
# AppAttic Qt 6 link is proven by scripts/linux-qt-link.sh (ldd libQt6Widgets + --smoke).
# The CLI build goes through scripts/swift-build.sh so the checkout path is
# mapped out of the binary, the same way every other build does it.
RUN . scripts/swift-build.sh \
    && swift test --filter AppAtticScanTests --disable-automatic-resolution \
    && appattic_swift_build debug --product appattic \
    && bash scripts/linux-qt-link.sh \
    && bash scripts/verify-qt-link.sh
