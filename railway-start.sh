#!/bin/bash
# Railway start script for InvenTree.
# Runs database migrations and collects static files, then starts the web
# server (gunicorn), the background worker (django-q2) and Caddy side by side.
# If any of them exits, the container exits and Railway restarts it.
set -euo pipefail

# Fixed settings (the template only carries references, secrets and prompts).
export INVENTREE_DB_ENGINE="${INVENTREE_DB_ENGINE:-postgresql}"
export INVENTREE_CACHE_ENABLED="${INVENTREE_CACHE_ENABLED:-True}"
export INVENTREE_USE_X_FORWARDED_HOST="${INVENTREE_USE_X_FORWARDED_HOST:-True}"
export INVENTREE_USE_X_FORWARDED_PORT="${INVENTREE_USE_X_FORWARDED_PORT:-True}"
export INVENTREE_USE_X_FORWARDED_PROTO="${INVENTREE_USE_X_FORWARDED_PROTO:-True}"
export INVENTREE_SESSION_COOKIE_SECURE="${INVENTREE_SESSION_COOKIE_SECURE:-True}"
export INVENTREE_PLUGINS_ENABLED="${INVENTREE_PLUGINS_ENABLED:-True}"
export INVENTREE_LOG_LEVEL="${INVENTREE_LOG_LEVEL:-WARNING}"
export INVENTREE_GUNICORN_WORKERS="${INVENTREE_GUNICORN_WORKERS:-2}"
export INVENTREE_BACKGROUND_WORKERS="${INVENTREE_BACKGROUND_WORKERS:-2}"
export INVENTREE_GUNICORN_TIMEOUT="${INVENTREE_GUNICORN_TIMEOUT:-90}"
export INVENTREE_ADMIN_USER="${INVENTREE_ADMIN_USER:-admin}"
export PORT="${PORT:-8080}"

if [[ -z "${INVENTREE_SITE_URL:-}" ]]; then
  echo "ERROR: INVENTREE_SITE_URL is empty. Give the service a public domain and set INVENTREE_SITE_URL=https://YOUR-DOMAIN." >&2
  exit 1
fi
# Host name of the site, used by Caddy for the health check.
site_host="${INVENTREE_SITE_URL#*://}"
site_host="${site_host%%/*}"
export INVENTREE_SITE_HOST="${site_host%%:*}"

cd "${INVENTREE_HOME:-/home/inventree}"

# While the setup steps below run, a placeholder server answers the health
# check, so a slow first start (fresh database) never hits Railway's
# health-check timeout.
caddy run --adapter caddyfile --config /etc/inventree-railway/Caddyfile.setup &
setup_pid=$!

echo "InvenTree ${INVENTREE_TEMPLATE_VERSION:-}: waiting for the database..."
invoke wait

echo "Running database migrations..."
# Same steps as upstream's "invoke migrate" (without its slow post-tasks),
# under a Postgres advisory lock so two overlapping deploys never migrate at once.
cd "${INVENTREE_BACKEND_DIR}/InvenTree"
python3 - <<'PY'
import os, subprocess, sys
import psycopg

conn = psycopg.connect(
    host=os.environ["INVENTREE_DB_HOST"],
    port=os.environ.get("INVENTREE_DB_PORT", "5432"),
    dbname=os.environ["INVENTREE_DB_NAME"],
    user=os.environ["INVENTREE_DB_USER"],
    password=os.environ["INVENTREE_DB_PASSWORD"],
    autocommit=True,
)
conn.execute("SELECT pg_advisory_lock(727930)")
try:
    for cmd in (
        "runmigrations",
        "migrate --run-syncdb --no-input",
        "remove_stale_contenttypes --include-stale-apps --no-input",
    ):
        subprocess.run([sys.executable, "manage.py", *cmd.split()], check=True)
finally:
    conn.execute("SELECT pg_advisory_unlock(727930)")
    conn.close()
PY
cd "${INVENTREE_HOME:-/home/inventree}"

# Collect static files once per image version (takes about a minute), and
# again whenever the template version changes.
marker="${INVENTREE_STATIC_ROOT}/.railway-static-version"
if [[ "$(cat "$marker" 2>/dev/null || true)" != "${INVENTREE_TEMPLATE_VERSION:-unknown}" ]]; then
  echo "Collecting static files..."
  invoke static
  echo "${INVENTREE_TEMPLATE_VERSION:-unknown}" > "$marker"
else
  echo "Static files already collected for ${INVENTREE_TEMPLATE_VERSION:-unknown}; skipping."
fi

# Stop the placeholder server before the real one takes the port.
kill -TERM "$setup_pid" 2>/dev/null || true
wait "$setup_pid" 2>/dev/null || true

# Start the three processes.
gunicorn -c ./gunicorn.conf.py InvenTree.wsgi \
  -b "${INVENTREE_WEB_ADDR}:${INVENTREE_WEB_PORT}" \
  --chdir "${INVENTREE_BACKEND_DIR}/InvenTree" &
web_pid=$!

invoke worker &
worker_pid=$!

caddy run --adapter caddyfile --config /etc/inventree-railway/Caddyfile &
caddy_pid=$!

term() {
  kill -TERM "$web_pid" "$worker_pid" "$caddy_pid" 2>/dev/null || true
  wait || true
}
trap term TERM INT

set +e
wait -n "$web_pid" "$worker_pid" "$caddy_pid"
code=$?
echo "A process exited (code $code); stopping the others so Railway restarts the service." >&2
term
exit "$code"
