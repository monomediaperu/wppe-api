# wppe-api

Endpoints estáticos públicos para `api.wp.pe`. Sirve archivos JSON y zips de releases del plugin **WP.pe Bridge** y otros servicios WP.pe.

[![Status](https://img.shields.io/badge/status-public-brightgreen)](https://api.wp.pe/status/ping.json)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

## Endpoints

| Path | Descripción | Cache |
|---|---|---|
| `/bridge/whitelist.json` | Whitelist de dominios autorizados para el plugin sin modo demo. | 5 min |
| `/bridge/latest.json` | Manifest de versión latest del plugin + URL del zip. | 5 min |
| `/bridge/releases/wppe-bridge-X.Y.Z.zip` | Mirror público de releases del plugin. | 1 año (immutable) |
| `/status/ping.json` | Health check. | no-cache |

CORS abierto (`Access-Control-Allow-Origin: *`) en todos los endpoints.

## Stack

- **Nginx alpine** sirviendo archivos estáticos.
- **Coolify** sobre VPS de Mono Media para deploy.
- **Cloudflare** al frente con DNS + WAF + cache.
- **Dominio**: `api.wp.pe` (proxied via CF).

## Tareas operativas

### 1. Agregar un dominio a la whitelist

Cuando un cliente nuevo va a usar el plugin sin modo demo:

1. Editar `public/bridge/whitelist.json` agregando el dominio al array `domains`.
2. Soporta wildcards: `*.cliente.com`, `cliente.com`, `subdominio.cliente.com`.
3. Actualizar `updated_at` al timestamp ISO-8601 actual.
4. Commit + push a `main`.
5. Coolify auto-deploya en ~1 min.
6. Cloudflare cachea 5 min — el cliente verá el cambio en máximo 5 min sin acción manual (o purgar cache CF para inmediato).

Ejemplo:

```json
{
  "version": 1,
  "updated_at": "2026-05-15T14:30:00Z",
  "domains": [
    "wp.pe",
    "*.wp.pe",
    "anden.com.pe",
    "nuevo-cliente.com"
  ]
}
```

### 2. Publicar un release nuevo del plugin

**Automatizado desde 2026-05-01.** El repo privado `wppe-sperant-bridge` tiene un GitHub Action (`.github/workflows/mirror-release.yml`) que cuando hago `gh release create vX.Y.Z` allí, auto-mirroea acá:

1. Descarga el zip del release del repo del plugin.
2. Hace clone de `wppe-api` con un PAT (secret `WPPE_API_PAT`).
3. Copia el zip a `public/bridge/releases/`.
4. Actualiza `public/bridge/latest.json`.
5. Commit + push.
6. Coolify auto-deploya en ~30-60s.

**Cero pasos manuales** en cada release nuevo.

#### Si necesitás subir un release manualmente (fallback)

```bash
cp ~/Downloads/wppe-bridge-X.Y.Z.zip public/bridge/releases/
# Editar latest.json -> nueva versión + zip_url
git add -A
git commit -m "release: wppe-bridge vX.Y.Z (manual)"
git push
```

#### Si necesitás regenerar el PAT (rotación)

1. GitHub → Settings → Developer settings → Personal access tokens → Fine-grained.
2. New token con scope `repo` solo en `monomediaperu/wppe-api`.
3. Permission: `Contents: Read and Write`.
4. En el repo del plugin → Settings → Secrets and variables → Actions → editar `WPPE_API_PAT` con el nuevo token.

### 3. Verificar que todo está vivo

```bash
curl https://api.wp.pe/status/ping.json
# {"status":"ok","service":"api.wp.pe"}

curl https://api.wp.pe/bridge/whitelist.json
curl https://api.wp.pe/bridge/latest.json

curl -I https://api.wp.pe/bridge/releases/wppe-bridge-2.0.1.zip
# HTTP/2 200 + Content-Type: application/zip
```

## Deploy local (testing)

```bash
docker build -t wppe-api:dev .
docker run -p 8080:80 wppe-api:dev
# Visitar http://localhost:8080/
```

## Deploy producción (Coolify)

Coolify está configurado para hacer auto-deploy en cada push a `main`:

1. Coolify hace `git clone` del repo.
2. Build con el `Dockerfile` (nginx alpine + COPY de `public/`).
3. Run del container con port 80 expuesto.
4. Traefik/Caddy de Coolify enruta `https://api.wp.pe` al container.
5. Let's Encrypt provee SSL automáticamente.

Si necesitás invalidar cache de Cloudflare después de un cambio crítico:
- Cloudflare Dashboard → wp.pe → Caching → Configuration → Purge Everything (o por URL específica).

## Roadmap

- [ ] GitHub Action para auto-mirrorear releases del repo privado del plugin a este repo (sin paso manual).
- [ ] Webhook desde Cloudflare para purge cache automático cuando cambia `whitelist.json`.
- [ ] Endpoint `/bridge/changelog.json` con últimas N versiones (para mostrar en sub-página Inicio del plugin "tenés version X.Y.Z, latest es A.B.C").
- [ ] Endpoint `/bridge/install-stats.json` (count anónimo de instalaciones por país, opt-in).

## Soporte

- Email: soporte@mono.media
- Operado por: [Mono Media SAC](https://mono.media)
- Repo del plugin (privado): `wppe-sperant-bridge` (este repo es solo el mirror público de assets)

## Licencia

MIT — los archivos servidos por este endpoint pueden tener licencias propias (los zips del plugin son GPL-3.0-or-later).

<!-- Updated: 2026-05-04T20:35:44Z -->
