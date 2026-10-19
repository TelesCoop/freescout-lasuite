# TelesCoop/docker-freescout

A [FreeScout](https://freescout.net/) image that runs entirely without root, for Kubernetes clusters that forbid root containers (Pod Security `restricted`).

## How it works

- The FreeScout code, Composer dependencies included, is taken from the [nfrastack/container-freescout](https://github.com/nfrastack/container-freescout) image (`FREESCOUT_IMAGE` argument of the `Dockerfile`).
- It runs on a minimal Alpine runtime: nginx on port **8080**, php-fpm 8.5 with `intl` for localized dates, the queue worker and the scheduler, all managed by supervisord.
- Every process runs as UID/GID **1000**. Configuration files are owned by root and cannot be modified by the application.
- If a service keeps crashing, the container stops so the orchestrator restarts it.
- Persistent data lives in **`/data`**:
  - `.env`, which holds the `APP_KEY`;
  - `storage/`: attachments, sessions, logs.

## Images

CI publishes the image to GHCR on every push to `main`, once the tests pass:

```text
ghcr.io/telescoop/docker-freescout:sha-<commit>   # immutable, use this in production
ghcr.io/telescoop/docker-freescout:latest
```

The package is private: pulling it requires a GitHub token with the `read:packages` scope.

## Configuration

| Variable | Required | Description |
|---|---|---|
| `APP_URL` | yes | Public URL, e.g. `https://freescout.example.org`. An `https://` URL enables secure cookies and the HTTPS redirect. |
| `DB_TYPE` | no | `mysql` (default), `mariadb` or `pgsql`. |
| `DB_HOST`, `DB_NAME`, `DB_USER`, `DB_PASS` | yes | Database connection. |
| `DB_PORT` | no | 3306 by default, 5432 for `pgsql`. |
| `ADMIN_EMAIL`, `ADMIN_PASS` | on first start | The admin account is created only when the database has no user. |
| `ADMIN_FIRST_NAME`, `ADMIN_LAST_NAME` | no | `Admin` / `User` by default. |
| `TIMEZONE` | no | `UTC` by default. |
| `APP_KEY` | no | When unset, a key is generated on first start and kept in `/data/.env`. **Do not lose it**: it encrypts the mailbox passwords. |
| `FREESCOUT_<KEY>` | no | Writes `<KEY>` to FreeScout's `.env`, e.g. `FREESCOUT_MAIL_DRIVER=smtp`. An empty value, `unset` or `null` removes the key. |
| `<VARIABLE>_FILE` | no | Reads the value of `<VARIABLE>` from a file (Docker/Kubernetes secrets). The container fails if the file does not exist. |

Behind a reverse proxy, set `FREESCOUT_APP_TRUSTED_PROXIES` (e.g. `*`) so FreeScout sees the real client IP. HTTPS is already detected through `X-Forwarded-Proto`.

A missing or invalid setting stops the container with an `[entrypoint] ERROR` message. There is no silent fallback value.

## Running locally

```sh
docker compose up --build
```

FreeScout is then available at http://localhost:8080 (`admin@example.com` / `freescout`).

## Kubernetes deployment

You need a MySQL, MariaDB or PostgreSQL database reachable from the cluster.

1. Create the secret used to pull the private image:

   ```sh
   kubectl create secret docker-registry ghcr-telescoop \
       --docker-server=ghcr.io \
       --docker-username=<GitHub user> \
       --docker-password=<read:packages token>
   ```

2. Create the configuration and secrets:

   ```sh
   kubectl create configmap freescout-config \
       --from-literal=APP_URL=https://freescout.example.org \
       --from-literal=DB_TYPE=mariadb \
       --from-literal=DB_HOST=<host> \
       --from-literal=DB_NAME=freescout \
       --from-literal=DB_USER=freescout \
       --from-literal=ADMIN_EMAIL=<admin email> \
       --from-literal=FREESCOUT_APP_TRUSTED_PROXIES='*'
   kubectl create secret generic freescout-secrets \
       --from-literal=DB_PASS=<password> \
       --from-literal=ADMIN_PASS=<admin password>
   ```

3. Apply the manifest, then expose the `freescout` Service (port 80) through the cluster's Ingress:

   ```sh
   kubectl apply -f deploy/kubernetes/freescout.yaml
   ```

What [`deploy/kubernetes/freescout.yaml`](deploy/kubernetes/freescout.yaml) does:

- Its `securityContext` complies with the `restricted` Pod Security standard.
- `fsGroup: 1000` makes the persistent volume writable.
- It runs **a single** replica with the `Recreate` strategy, because the volume is `ReadWriteOnce` and migrations run at startup.
- The probes send `Host: localhost`, because FreeScout rejects hosts missing from `APP_URL` and `APP_TRUSTED_HOSTS`.

**Upgrading:** replace the `sha-…` tag in the manifest with the newly published tag, then apply it again. Migrations run at startup.

## FreeScout modules

`modules/` is a git submodule pinned to a commit of the private [suitenumerique/freescout-modules](https://github.com/suitenumerique/freescout-modules) repository, which currently provides `PersonalTemplates` and `Presence`. Clone with `git clone --recurse-submodules`, or run `git submodule update --init` in an existing clone.

Modules live in the image only: the build copies every module of `modules/` and links its public assets, and fails when `modules/` is empty. At startup, only their migrations run, with `module:migrate`. Activate each module once in *Manage » Modules*; the choice is stored in the database.

Modules installed from the web interface are lost when the container is recreated: add them to `modules/` instead.

**Updating the modules:**

```sh
git submodule update --remote modules
git commit -am "chore: update FreeScout modules"
```

CI reads the modules repository with a read-only deploy key, stored in the `MODULES_DEPLOY_KEY` secret of this repository.

## Upgrading FreeScout

Change the nfrastack image tag in the `FREESCOUT_IMAGE` argument of the `Dockerfile`, then push to `main`. CI tests and publishes the image.

## Tests

The `.github/workflows/build-test.yml` workflow runs these tests and publishes only when they pass:

- `tests/e2e.sh <image>` runs the image with Docker and MariaDB, with `--cap-drop ALL`. It checks:
  - the admin login;
  - that no process runs as root;
  - that the modules are migrated and their assets linked;
  - that after the container is recreated, the `APP_KEY` is kept and the admin is not created again.
- `tests/k8s.sh <image>` deploys the unmodified manifest to a [kind](https://kind.sigs.k8s.io/) cluster, in a namespace enforcing the `restricted` Pod Security standard, and waits for the deployment to be ready.

## Inherited files

`Containerfile`, `rootfs/`, `build-assets/`, `examples/` and `CHANGELOG.md` come from the nfrastack repository. They are not used to build this image.

## License

MIT. Derived from [nfrastack/container-freescout](https://github.com/nfrastack/container-freescout) (see [LICENSE](LICENSE)).
