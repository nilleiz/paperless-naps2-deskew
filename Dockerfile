FROM debian:bookworm-slim

ARG DEBIAN_FRONTEND=noninteractive

ENV INPUT_DIR=/input \
    OUTPUT_DIR=/output \
    POLL_SECONDS=10 \
    ARCHIVE_ORIGINALS=true \
    NAPS2_EXTRA_ARGS="" \
    PUID=1000 \
    PGID=1000 \
    HOME=/naps2 \
    XDG_CONFIG_HOME=/naps2/.config \
    XDG_DATA_HOME=/naps2/.local/share \
    XDG_CACHE_HOME=/naps2/.cache \
    DOTNET_CLI_HOME=/naps2/.dotnet \
    WORK_DIR=/tmp/paperless-naps2-deskew

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl gnupg gosu bash coreutils findutils; \
    install -d -m 0755 /etc/apt/keyrings; \
    curl -fsSL https://www.naps2.com/naps2-public.pgp | gpg --dearmor -o /etc/apt/keyrings/naps2.gpg; \
    echo "deb [signed-by=/etc/apt/keyrings/naps2.gpg] https://downloads.naps2.com ./" > /etc/apt/sources.list.d/naps2.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends naps2; \
    groupadd --gid 1000 naps2; \
    useradd --uid 1000 --gid 1000 --home-dir /naps2 --create-home --shell /usr/sbin/nologin naps2; \
    mkdir -p /input /output /naps2/.config /naps2/.local/share /naps2/.cache /naps2/.dotnet /tmp/paperless-naps2-deskew; \
    chown -R naps2:naps2 /input /output /naps2 /tmp/paperless-naps2-deskew; \
    apt-get purge -y --auto-remove curl gnupg; \
    rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

VOLUME ["/input", "/output"]
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
