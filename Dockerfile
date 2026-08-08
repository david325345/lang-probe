FROM debian:stable-slim

# curl = range download z TorBox CDN
# mkvtoolnix = mkvmerge -J (jazyky stop)
# jq = čisté parsování/generování JSON (čitelný výstup pro indexer)
# cron = noční automatické spouštění
# ca-certificates = HTTPS bez certifikátových chyb
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        curl \
        mkvtoolnix \
        jq \
        cron \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY probe.sh /app/probe.sh
COPY crontab /etc/cron.d/lang-probe
COPY entrypoint.sh /app/entrypoint.sh

RUN chmod +x /app/probe.sh /app/entrypoint.sh \
    && chmod 0644 /etc/cron.d/lang-probe \
    && crontab /etc/cron.d/lang-probe

# entrypoint spustí cron démona a pak drží kontejner naживу
CMD ["/app/entrypoint.sh"]
