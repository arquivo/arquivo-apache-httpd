# arquivo-apache-httpd

Apache httpd image of [Arquivo.pt](https://arquivo.pt), the front web server of the brokers.
See [arquivo/pwa-technologies#1487](https://github.com/arquivo/pwa-technologies/issues/1487).

It is the official [`httpd:2.4`](https://hub.docker.com/_/httpd) image (Debian trixie), pinned by
digest, plus the third-party modules that Arquivo.pt uses, compiled with `apxs` on a build stage:

| Module | Source |
|---|---|
| `mod_qos` | [mod-qos](https://sourceforge.net/projects/mod-qos/), compiled |
| `mod_maxminddb` | [maxmind/mod_maxminddb](https://github.com/maxmind/mod_maxminddb), compiled against Debian `libmaxminddb` |
| `mod_ssl`, `mod_proxy_uwsgi`, `mod_ratelimit` | official image |

`python3` is also installed, to run the `url_escape.py` `RewriteMap` program.

## Configuration layout

The image keeps the official image layout (`ServerRoot` `/usr/local/apache2`, runs `httpd -D FOREGROUND`
and the workers as `daemon`), and adds the CentOS layout that the Arquivo.pt configuration
(`arquivo-operation/roles/httpd`) is written for:

| Path | Content |
|---|---|
| `/usr/local/apache2/conf/httpd.conf` | stock `httpd.conf`, with its `LoadModule` list replaced by `Include conf.modules.d/*.conf` and ending with `IncludeOptional conf.d/*.conf` |
| `/usr/local/apache2/conf.modules.d/` | `LoadModule` of every module the Arquivo.pt configuration uses (the [`conf.modules.d`](conf.modules.d) of this repository), event MPM |
| `/usr/local/apache2/conf.d/` | empty, for the site configuration |

When porting the CentOS `httpd.conf.j2` keep its `Include conf.modules.d/*.conf` and
`IncludeOptional conf.d/*.conf`, and mount the rendered configuration over `conf/httpd.conf`
and `conf.d/`, so the modules list stays the one of the image. A module the image does
not load is enabled by mounting an extra file on `conf.modules.d/`, the official image
ships every standard httpd module on `/usr/local/apache2/modules/`.

Paths of the CentOS configuration that differ on the image:

| CentOS | Image |
|---|---|
| `ServerRoot "/etc/httpd"` | `ServerRoot "/usr/local/apache2"` |
| `User apache` / `Group apache` | `User daemon` / `Group daemon` |
| `/usr/sbin/rotatelogs` | `/usr/local/apache2/bin/rotatelogs` (on `PATH`) |
| `/run/httpd` (`Mutex`, `SSLSessionCache`) | `/usr/local/apache2/logs` |
| `TypesConfig /etc/mime.types` | `TypesConfig conf/mime.types` |
| `RewriteMap … "prg:/etc/httpd/external.prg/url_escape.py"` (`#!/usr/local/bin/python3.9`) | `"prg:/usr/bin/python3 <path>/url_escape.py"` |

## Build and test

```bash
make build   # docker build -t arquivo/arquivo-apache-httpd:test .
make test    # build + tests/smoke-test.sh
```

[`tests/smoke-test.sh`](tests/smoke-test.sh) runs the image with
[`tests/smoke-test.conf`](tests/smoke-test.conf) and checks that `mod_maxminddb` geolocates a
client (with a MaxMind test database), that `mod_qos` limits a client, that `mod_proxy_uwsgi`
proxies to a `uwsgi://` backend, that `mod_ratelimit` throttles a download and that `mod_ssl`
serves HTTPS. It runs on CI before the image is pushed.

## Release

The [GitHub workflow](.github/workflows/docker.yml) builds, tests and pushes
`arquivo/arquivo-apache-httpd` to Docker Hub, tagged `latest` (from `main`/`master`) and
`sha-<commit>`, as the other Arquivo.pt images. The usual flow of `arquivo-operation` applies:
dev uses `latest`, preprod is pinned to a `sha-*` tag with
`cicd-scripts/update-docker-images-on-preprod.py` and prod receives it with
`cicd-scripts/promote-docker-images-from-preprod-to-prod.py`.

## Upgrades

- **httpd**: the base image is pinned by tag and digest on both `FROM` lines of the
  [`Dockerfile`](Dockerfile); Dependabot proposes the bumps. To bump by hand:
  `docker buildx imagetools inspect httpd:<version>-trixie` and use its `Digest`.
- **mod_qos / mod_maxminddb**: update `MOD_*_VERSION` and `MOD_*_SHA256` on the
  [`Dockerfile`](Dockerfile) (`sha256sum` of the release tarball).
