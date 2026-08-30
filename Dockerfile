FROM swift:5.10-jammy

COPY scripts/linux-deps.sh /tmp/linux-deps.sh
RUN apt-get update \
    && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/* \
    && bash /tmp/linux-deps.sh --install \
    && bash /tmp/linux-deps.sh --install-wasmtime
ENV WASMTIME_DIR=/opt/wasmtime-c-api

WORKDIR /src
COPY . .
# AppAttic Qt 6 link is proven by scripts/linux-qt-link.sh (ldd libQt6Widgets + --smoke).
RUN swift test --filter AppAtticScanTests \
    && swift build -c debug --product appattic \
    && bash scripts/linux-qt-link.sh \
    && grep -q '^LINUX_QT_LINK=ok$' src/linux/build/LINUX_QT_LINK.txt \
    && grep -q '^LINUX_QT_SMOKE=ok$' src/linux/build/LINUX_QT_LINK.txt \
    && grep -q '^plugin:path-shadow$' src/linux/build/LINUX_QT_LINK.txt \
    && grep -Eq '^wasm: ok \([1-9][0-9]* plugins\)$' src/linux/build/LINUX_QT_LINK.txt \
    && grep -Eq '^tables: ok \(leftovers=[1-9][0-9]* stale=[1-9][0-9]*' src/linux/build/LINUX_QT_LINK.txt
