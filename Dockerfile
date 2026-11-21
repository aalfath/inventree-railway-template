# InvenTree for Railway: the official InvenTree image, pinned by version and
# digest, plus a small wrapper that runs the web server, the background worker
# and a Caddy file server in one container, so all three share the data volume
# (a Railway volume attaches to one service only).
#
# To update: change the FROM pins (tag and digest) and add a CHANGELOG.md entry.

# Caddy serves /static and /media, as in upstream's docker compose setup.
FROM caddy:2.11.9@sha256:4851e54a46b206517c574821bb5cc67f170d2156041e9fbc4c9193b45e84a75b AS caddy

FROM inventree/inventree:1.7.3@sha256:bd58a1d1891dac39a19b5c40a7fa6bd9fc4d6752ae0bd69da4582a4afce5dfb7

COPY --from=caddy /usr/bin/caddy /usr/local/bin/caddy
COPY Caddyfile Caddyfile.setup /etc/inventree-railway/
COPY railway-start.sh /usr/local/bin/railway-start.sh
RUN chmod +x /usr/local/bin/railway-start.sh

# Gunicorn listens on localhost only; Caddy listens on $PORT (8080 by default).
ENV INVENTREE_WEB_ADDR=127.0.0.1 \
    INVENTREE_WEB_PORT=8000 \
    INVENTREE_TEMPLATE_VERSION=1.7.3 \
    XDG_DATA_HOME=/tmp/caddy-data \
    XDG_CONFIG_HOME=/tmp/caddy-config

EXPOSE 8080

# The image's ENTRYPOINT (init.sh) creates the data folders, then runs this.
CMD ["/usr/local/bin/railway-start.sh"]
