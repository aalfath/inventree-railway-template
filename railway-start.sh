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
# First admin account: created on the first start only, if the user doesn't exist.
export INVENTREE_ADMIN_USER="${INVENTREE_ADMIN_USER:-admin}"
export INVENTREE_ADMIN_EMAIL="${INVENTREE_ADMIN_EMAIL:-admin@localhost}"
export PORT="${PORT:-8080}"

if [[ -z "${INVENTREE_SITE_URL:-}" ]]; then
  echo "ERROR: INVENTREE_SITE_URL is empty. Give the service a public domain and set INVENTREE_SITE_URL=https://YOUR-DOMAIN." >&2
  exit 1
fi
# Host name of the site, used by Caddy for the health check.
site_host="${INVENTREE_SITE_URL#*://}"
site_host="${site_host%%/*}"
export INVENTREE_SITE_HOST="${site_host%%:*}"

version="${INVENTREE_TEMPLATE_VERSION:-unknown}"
marker="${INVENTREE_STATIC_ROOT}/.railway-static-version"
first_start=false
[[ "$(cat "$marker" 2>/dev/null || true)" != "$version" ]] && first_start=true

cd "${INVENTREE_HOME:-/home/inventree}"

# On the first start of this version (fresh volume or an upgrade), migrations
# and static collection take a few minutes. A placeholder server answers the
# health check meanwhile, so the deploy never hits Railway's health-check
# timeout. On later restarts the health check waits for the real app instead,
# so a redeploy keeps the old deployment serving until the new one is ready.
setup_pid=""
if $first_start; then
  caddy run --adapter caddyfile --config /etc/inventree-railway/Caddyfile.setup &
  setup_pid=$!
fi

echo "InvenTree ${version}: waiting for the database..."
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

# Collect static files once per version (takes about a minute).
if $first_start; then
  echo "Collecting static files..."
  invoke static
  echo "$version" > "$marker"
else
  echo "Static files already collected for ${version}; skipping."
fi

# Start the web server and the worker.
gunicorn -c ./gunicorn.conf.py InvenTree.wsgi \
  -b "${INVENTREE_WEB_ADDR}:${INVENTREE_WEB_PORT}" \
  --chdir "${INVENTREE_BACKEND_DIR}/InvenTree" &
web_pid=$!

invoke worker &
worker_pid=$!

# Wait until gunicorn answers before Caddy takes over the public port.
for _ in $(seq 1 120); do
  if curl -fsS -o /dev/null -H "Host: ${INVENTREE_SITE_HOST}" \
      "http://${INVENTREE_WEB_ADDR}:${INVENTREE_WEB_PORT}/api/system/health/"; then
    break
  fi
  kill -0 "$web_pid" 2>/dev/null || break
  sleep 1
done

if [[ -n "$setup_pid" ]]; then
  kill -TERM "$setup_pid" 2>/dev/null || true
  wait "$setup_pid" 2>/dev/null || true
fi

caddy run --adapter caddyfile --config /etc/inventree-railway/Caddyfile &
caddy_pid=$!
echo "InvenTree ${version} is up on port ${PORT}."

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
