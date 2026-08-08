FROM debian:stable-slim

# curl = stahování 256 KB range z TorBox CDN
# mkvtoolnix-cli = mkvmerge -J (CLI varianta bez GUI, menší image)
# ca-certificates = HTTPS na api.torbox.app a CDN nody bez certifikátových chyb
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        curl \
        mkvtoolnix \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Fáze 1: žádná logika, jen držet kontejner naживу,
# ať se přes Coolify terminál dá napojit a testovat ručně.
CMD ["sleep", "infinity"]
