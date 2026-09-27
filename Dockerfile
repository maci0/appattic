FROM swift:5.10.1-jammy
ARG SOURCE_DATE_EPOCH=0
ENV LC_ALL=C
ENV LANG=C
ENV TZ=UTC
ENV SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}

COPY scripts/linux-deps.sh \
     scripts/verify-sha256.sh \
     scripts/dep-checksums.sha256 \
     /tmp/appattic/scripts/
RUN apt-get update \
    && apt-get install -y --no-install-recommends git \
    && bash /tmp/appattic/scripts/linux-deps.sh --install \
    && bash /tmp/appattic/scripts/linux-deps.sh --install-wasmtime \
    && rm -rf /var/lib/apt/lists/*
ENV WASMTIME_DIR=/opt/wasmtime-c-api

WORKDIR /src
COPY . .
# AppAttic Qt 6 link is proven by scripts/linux-qt-link.sh (ldd libQt6Widgets + --smoke).
RUN swift test --filter AppAtticScanTests --disable-automatic-resolution \
    && swift build -c debug --product appattic --disable-automatic-resolution \
    && bash scripts/linux-qt-link.sh \
    && bash scripts/verify-qt-link.sh
