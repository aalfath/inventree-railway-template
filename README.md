[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/new/template/inventree-1?utm_medium=integration&utm_source=button&utm_campaign=inventree)

# InvenTree on Railway

A one-click [Railway](https://railway.com) template for [InvenTree](https://inventree.org), the open-source inventory and parts management system: parts, stock locations, suppliers, purchase and sales orders, build orders and bills of materials, with a web UI and a REST API.

## What it deploys

- **InvenTree 1.7.3**, the official image `inventree/inventree:1.7.3`, pinned by digest in the [`Dockerfile`](Dockerfile).
- **One InvenTree service** with a public HTTPS domain and a health check on `/api/system/health/`. [`railway-start.sh`](railway-start.sh) runs the database migrations and collects static files, then starts three processes in the same container:
  - the web server (Gunicorn),
  - the background worker (`invoke worker`, django-q2), which runs scheduled and long tasks such as reports, imports and notifications,
  - [Caddy](https://caddyserver.com) 2.11.9 on `$PORT`, which serves `/static`, serves uploaded files under `/media` only to signed-in users, and proxies everything else to Gunicorn. This is the same layout as upstream's Docker Compose setup, with Railway's edge doing TLS.

  The three share one container because a Railway volume attaches to one service only, and the worker and Caddy both need the uploaded files.
- **One volume at `/home/inventree/data`** for uploads, static files, plugins, backups and `config.yaml`, so they survive redeploys and restarts.
- **Railway Postgres** (the database) and **Railway Redis** (cache and worker coordination), reached over Railway's private network.

The first start on a fresh database takes about two minutes (migrations, then static files). Meanwhile the health check answers and other pages say InvenTree is starting. Later restarts take about 20 seconds.

## Variables

| Variable | Default | What it does |
|---|---|---|
| `INVENTREE_ADMIN_USER` | `admin` | User name of the first admin account. Used on the first start only. |
| `INVENTREE_ADMIN_PASSWORD` | generated (`${{secret(24)}}`) | Password of that admin. Copy it from the service's Variables tab to sign in, then change it in the app. |
| `INVENTREE_SECRET_KEY` | generated | Django secret key (sessions, tokens). Don't change it after deploy. |
| `INVENTREE_SITE_URL` | `https://${{RAILWAY_PUBLIC_DOMAIN}}` | Public URL of the site. Change it when you add a custom domain. |
| `INVENTREE_DB_*` | references to `Postgres` | Private connection to the bundled Postgres. |
| `INVENTREE_CACHE_*` | references to `Redis` | Private connection to the bundled Redis. |
| `PORT` | `8080` | Port Caddy listens on; the public domain points at it. |

The first admin's email defaults to `admin@localhost`; change it in the app, or add `INVENTREE_ADMIN_EMAIL` before the first start.

Fixed settings live in `railway-start.sh` and can be overridden with a service variable: proxy headers on, secure cookies on, plugins enabled, 2 Gunicorn workers, 2 background workers, log level `WARNING`. Any other [InvenTree setting](https://docs.inventree.org/en/stable/start/config/) can be added as a variable too, for example the `INVENTREE_EMAIL_*` settings for outgoing mail.

## After deploying

1. Open the public URL and sign in as `admin` with the generated `INVENTREE_ADMIN_PASSWORD`.
2. Change the password (and the email) under your user settings.
3. Optional: set up email (`INVENTREE_EMAIL_HOST`, `INVENTREE_EMAIL_PORT`, `INVENTREE_EMAIL_USERNAME`, `INVENTREE_EMAIL_PASSWORD`, `INVENTREE_EMAIL_SENDER`, `INVENTREE_EMAIL_TLS`) so that password resets and notifications work.

## Updates

This template builds from this repository. When a new InvenTree version is tested here, the `Dockerfile` pin is bumped and an entry added to [`CHANGELOG.md`](CHANGELOG.md). Railway then shows an "update available" notice on your project, and you choose when to apply it. On the first start of a new version, migrations run and static files are collected again. Back up your Postgres database before applying an update with a major version change.

## Licence

InvenTree is MIT licensed. The wrapper files in this repository are MIT licensed too.
