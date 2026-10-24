# immich-decompose

*docker-compose, taken apart.* Installs and upgrades [Immich](https://github.com/immich-app/immich) on Debian 13
(trixie) without Docker. It rebuilds what the official images contain, from the
same sources and pinned versions, and runs it all as systemd services.

This is an unofficial community project, not affiliated with Immich. Report problems
with the script here, not to the Immich team.

```bash
./immich-decompose.sh install            # latest release
./immich-decompose.sh install v3.3.5     # a specific release
./immich-decompose.sh upgrade [VERSION]  # build the new release, then switch over
./immich-decompose.sh status
```

## Requirements

- **System**: Debian 13, amd64 or arm64, with systemd as init. Run the script as root.
- **Resources**: about 4 GiB of RAM and 15 GiB of disk for the build. A build takes
  15–20 minutes on 4 cores.
- **Network**: outbound access to GitHub, ghcr.io, nodejs.org, npm, PyPI,
  Hugging Face, deb.debian.org and apt.postgresql.org.
- **Media location**: it must be writable by the `immich` user. If it's mounted
  storage, set `IMMICH_UID`/`IMMICH_GID` to match its ownership. The script stops
  early if it can't write there.

## What it sets up

Each docker-compose service becomes a systemd service:

| docker-compose service    | Here                                                                      |
|---------------------------|---------------------------------------------------------------------------|
| `immich-server`           | `immich-server.service`: server, web UI and CLI, plus the base image's libraries (libvips, ImageMagick, libheif, libjxl, libraw, jpegli, jellyfin-ffmpeg, Intel OpenCL on amd64) |
| `immich-machine-learning` | `immich-machine-learning.service`, a Python venv built with uv              |
| `database`                | PostgreSQL 17 + pgvector + VectorChord, same tuning, data checksums on    |
| `redis`                   | Debian `valkey-server`                                                    |

Files and folders, in place of `.env` and the volumes:

| Docker                       | Here                                                        |
|------------------------------|-------------------------------------------------------------|
| `.env`                       | `/etc/immich/immich.env`, plus `/etc/immich/ml.env` for ML  |
| `UPLOAD_LOCATION` (`/data`)  | `IMMICH_MEDIA_LOCATION`, default `/var/lib/immich/library`  |
| `model-cache` volume         | `/var/lib/immich/model-cache`                               |
| `DB_DATA_LOCATION`           | `/var/lib/postgresql/17/main`                               |
| the images                   | `/opt/immich/releases/<version>`, active one at `/opt/immich/current`; libraries in `/usr/local` |
| `docker exec … immich-admin` | `immich-admin`                                              |

The web UI listens on port 2283 on all interfaces, as in Docker. PostgreSQL, Valkey
and machine learning listen on localhost only.

**Versions** come from the release you choose, not from the script. The script
reads which `immich-app/base-images` commit the release's server image was built
from (via ghcr.io), then runs that commit's own build scripts. Node.js, uv,
extism-js/binaryen, VectorChord, ffmpeg and the geodata files are all taken from
the release's Dockerfiles and lock files.

## Settings

Pass these as environment variables, e.g. `UPLOAD_LOCATION=/mnt/photos ./immich-decompose.sh install`.

**Locations and user**

| Variable                    | Default                       | Notes |
|-----------------------------|-------------------------------|-------|
| `UPLOAD_LOCATION`           | `/var/lib/immich/library`     | Photos and videos. Only read on first install; after that, `immich.env` is the source of truth. |
| `ML_CACHE_LOCATION`         | `/var/lib/immich/model-cache` | ML models, about 2 GiB |
| `IMMICH_ROOT`               | `/opt/immich`                 | Built releases |
| `CONFIG_DIR`                | `/etc/immich`                 | `immich.env` and `ml.env` |
| `IMMICH_UID` / `IMMICH_GID` | system-assigned               | Fixed ids for the `immich` user, e.g. to match mounted storage |

**Database**

| Variable           | Default        | Notes |
|--------------------|----------------|-------|
| `PG_MAJOR`         | `17`           | PostgreSQL 14–18 |
| `DB_DATA_LOCATION` | Debian default | First install only. Use local storage, never NFS/SMB. |
| `DB_STORAGE_TYPE`  | `SSD`          | `HDD` uses the image's HDD tuning |
| `DB_USERNAME`      | `immich`       | First install only |
| `DB_DATABASE_NAME` | `immich`       | First install only |

**Machine learning and hardware**

| Variable       | Default | Notes |
|----------------|---------|-------|
| `INSTALL_ML`   | `1`     | `0` skips machine learning; then point `IMMICH_MACHINE_LEARNING_URL` elsewhere |
| `ML_DEVICE`    | `cpu`   | onnxruntime variant: `openvino`, `cuda`, `rocm`, `armnn`, `rknn`. Only `cpu` is tested, and GPU runtimes (CUDA/cuDNN etc.) are not installed. |
| `INTEL_OPENCL` | `auto`  | Intel OpenCL runtime for HW tone-mapping (`auto` = amd64) |

**Build and upgrades**

| Variable            | Default                  | Notes |
|---------------------|--------------------------|-------|
| `BUILD_JOBS`        | `nproc`                  | Lower it if the build runs out of memory |
| `BUILD_CACHE`       | `/var/cache/immich-build`| Sources, pnpm/uv caches, build tools |
| `CLEAN_BUILD_CACHE` | `0`                      | `1` deletes the build cache afterwards |
| `KEEP_RELEASES`     | `2`                      | Built releases kept in `/opt/immich/releases` |
| `FORCE_REBUILD`     | `0`                      | `1` rebuilds everything |
| `BASE_IMAGES_REF`   | auto-detected            | Override the `immich-app/base-images` commit |

Runtime settings (TZ, port, and so on) go in `/etc/immich/immich.env`, the same
variables as the Docker `.env`. Then run
`systemctl restart immich-server immich-machine-learning`. The ML service gets its
own `IMMICH_HOST`/`IMMICH_PORT` from `ml.env`, because both services share one host.

For hardware transcoding, make `/dev/dri` (or the NVIDIA devices) available on the
system. The `immich` user is already in the `video` and `render` groups.

## Upgrades

`upgrade` builds the new release next to the running one. It then stops the
services, switches the `/opt/immich/current` symlink and starts them again. Native
libraries are rebuilt only when the release changes them. Immich doesn't support
downgrades, because database migrations only go forward, so take a snapshot or
backup before upgrading.

## Differences from Docker

- **Shared libraries**: jpegli's `libjpeg.so.62` in `/usr/local/lib` shadows
  Debian's libjpeg-turbo. The image deletes Debian's copy instead.
- **APT sources**: Debian testing is added at pin priority 100, only to install
  `libde265` from it, as the image does.
- **Databases**: PostgreSQL 17 instead of 14, and Valkey 8 instead of 9. Both are
  within Immich's supported ranges.
- **Database role**: the role is a superuser, as in Docker. Immich needs this for
  extensions and its built-in backups.
- **Healthchecks**: none. systemd restarts services that exit.
