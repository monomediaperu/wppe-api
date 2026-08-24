#!/usr/bin/env bash
#
# mono-ftp-mirror.sh — Espejo FTP con panel de avance para migraciones de sitios
# Mono Media SAC · https://api.wp.pe/migrate-web/
#
# Corre como usuario del sitio, sin root, en el servidor DESTINO. Jala el árbol
# remoto sin escribir nada en el origen: el caso típico es una cuenta con la
# cuota llena donde no se puede generar un backup.
#
# v1.2.1 · línea de fases en el panel · status.json para monitoreo externo
#         · eventos.log con la línea de tiempo de la corrida
# v1.2  · detección de Cloudflare en el host FTP antes de conectar
#       · estrategia de transferencia: archivo por archivo vs zip, con medición
#         real de red y puerta de validación (el zip lo crea el operador en el
#         panel; esta herramienta nunca escribe en el origen)
#       · watchdog con relanzamiento gobernado por clase de fallo
#       · diagnóstico por capas y reconciliación de faltantes al cierre
#       · --update verificado por SHA256 contra api.wp.pe
#
# IMPORTANTE — qué es y qué no es la primera capa de detección:
#   NO es un antivirus. Dos niveles: CRÍTICO (evidencia, no sospecha — el árbol
#   no se despliega) y REVISAR (necesita ojo humano). Alta señal, bajo ruido:
#   ante la duda entre reportar o callar, se calla. Sin hallazgos NO significa
#   limpio. No reemplaza la erradicación ni el criterio humano.
#
# Uso:
#   ./migrate-web.sh                  # interactivo: caso + alcance + descarga + escaneo
#   ./migrate-web.sh --attach         # reengancha el panel a una descarga viva
#   ./migrate-web.sh --scan-only      # solo escanea un árbol ya descargado
#   ./migrate-web.sh --no-scan        # descarga sin escanear
#   ./migrate-web.sh --version        # versión + SHA256 del archivo en disco
#   ./migrate-web.sh --update         # actualizar desde api.wp.pe (verificado)
#   ./migrate-web.sh --help
#
set -euo pipefail

VERSION="1.3.1"

# ------------------------------------------------------------------ ajustes
REFRESH="${MONO_REFRESH:-2}"
LOG="wget.log"
PIDFILE=".mono-mirror.pid"
LISTING_EVERY=5
WATCH_EVERY=15                        # cada N ciclos, vigilancia en vivo
ALERTS="alertas-vivo.txt"

# v1.2.1 — monitoreo: el estado vive separado de la vista. El panel es efímero
# (muere con el SSH); estos dos sobreviven y se pueden leer desde afuera.
STATUS_JSON="status.json"              # estado actual, atómico, para polling
EVENTS="eventos.log"                   # línea de tiempo append-only con hora

# §5 — resiliencia de conexión.
STALL_WARN="${MONO_STALL_WARN:-90}"    # s sin avance de bytes → aviso en panel
STALL_KILL="${MONO_STALL_KILL:-300}"   # s sin avance → matar y relanzar
MAX_RELAUNCH="${MONO_MAX_RELAUNCH:-5}" # relanzamientos máximos por sesión
CALIBRATE_AT="${MONO_CALIBRATE_AT:-75}" # s de avance real antes de estimar (§4)
BACKOFF_SEQ="${MONO_BACKOFF_SEQ:-30 60 120 240 300}"  # backoff exponencial con tope (§5.3)
NO_AUTO_RETRY=0                        # --no-auto-retry: no retener la contraseña

# §3.4 — distribución. El binario siempre versionado e inmutable; el puntero es
# latest.json. Nunca una ruta estable cuyo contenido cambie para el pin de hash.
LATEST_URL="${MONO_LATEST_URL:-https://api.wp.pe/migrate-web/latest.json}"

# --------------------------------------------------------------- presentación
if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_B=$'\033[1m'; C_DIM=$'\033[2m'
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_ACC=$'\033[36m'
  TTY=1
else
  C_RESET=""; C_B=""; C_DIM=""; C_OK=""; C_WARN=""; C_ERR=""; C_ACC=""
  TTY=0
fi

die()  { printf '%s\n' "${C_ERR}✗ $*${C_RESET}" >&2; exit 1; }
warn() { printf '%s\n' "${C_WARN}⚠ $*${C_RESET}" >&2; }
ok()   { printf '%s\n' "${C_OK}✓ $*${C_RESET}"; }
info() { printf '%s\n' "  $*"; }

usage() {
  cat <<EOF
${C_B}mono-ftp-mirror.sh v${VERSION}${C_RESET} — espejo FTP con panel y triaje de integridad

  --attach        Solo abre el panel sobre una descarga ya en curso
  --scan-only     No descarga: escanea el árbol que ya está en el destino
  --no-scan       Descarga sin ejecutar el escaneo final
  --no-auto-retry No retener la contraseña; si wget muere, la pide de nuevo
  --dest DIR      Directorio destino (por defecto: el actual)
  --refresh N     Segundos entre refrescos (por defecto: ${REFRESH})
  --version       Versión y SHA256 de este archivo
  --update        Buscar y aplicar una versión nueva desde api.wp.pe
  --help          Esta ayuda

Variables de entorno opcionales:
  MONO_HOST  MONO_USER  MONO_PATH  MONO_EXCLUDES  MONO_EXPECT_MB
  MONO_WP_LOCALE   locale para checksums de core (por defecto: auto/en_US)
  MONO_STALL_WARN  MONO_STALL_KILL  MONO_MAX_RELAUNCH  (resiliencia §5)

La contraseña nunca se toma de variables de entorno ni de argumentos.
EOF
}

# --------------------------------------------------------------- formateadores
human() {
  awk -v b="${1:-0}" 'BEGIN{
    split("B KB MB GB TB PB", u, " ");
    i=1; while (b >= 1024 && i < 6) { b/=1024; i++ }
    if (i==1) printf "%d %s", b, u[i]; else printf "%.2f %s", b, u[i]
  }'
}
human_rate() { printf '%s/s' "$(human "${1:-0}")"; }
hms() {
  local s="${1:-0}"; [ "$s" -lt 0 ] && s=0
  printf '%02d:%02d:%02d' $((s/3600)) $(((s%3600)/60)) $((s%60))
}
thousands() { printf "%'d" "${1:-0}" 2>/dev/null || printf '%d' "${1:-0}"; }

# --------------------------------------------------------------- monitoreo
# Fases del ciclo de vida. PHASE avanza en un solo sentido:
#   conexion → estrategia → descarga → verificacion → escaneo → cierre
PHASE="conexion"
set_phase() { PHASE="$1"; event "fase: $1"; write_status; return 0; }

# Línea de tiempo append-only. El panel muestra el AHORA; esto guarda el CUÁNDO.
event() {
  printf '%s  %s\n' "$(date +%H:%M:%S 2>/dev/null || echo '--:--:--')" "$*" \
    >> "$EVENTS" 2>/dev/null || true
  return 0
}

# Sanitiza un valor para meterlo entre comillas en JSON hecho a mano: quita
# comillas dobles, backslashes y saltos de línea (los valores son hostnames y
# rutas controladas; esto es cinturón, no parser).
json_str() { printf '%s' "$1" | tr -d '"\\\n\r'; }

# Estado actual en JSON, escrito atómicamente (tmp + mv). Para polling local
# (`watch cat status.json`), remoto (`ssh nodo cat .../status.json`) o un cron
# que alerte si la migración se detuvo.
write_status() {
  local tmp pct=0 target eta_s=0 avg=0 elapsed now
  now=$(date +%s 2>/dev/null || echo 0)
  elapsed=$(( now - ${START:-now} )); [ "$elapsed" -lt 1 ] && elapsed=1
  if [ "${EXPECT_BYTES:-0}" -gt 0 ]; then target=$EXPECT_BYTES; else target=${DET_BYTES:-0}; fi
  if [ "${target:-0}" -gt 0 ]; then
    pct=$(( ${BYTES:-0} * 100 / target )); [ "$pct" -gt 100 ] && pct=100
  fi
  avg=$(( ${BYTES:-0} / elapsed ))
  if [ "$avg" -gt 0 ] && [ "$target" -gt "${BYTES:-0}" ]; then
    eta_s=$(( (target - ${BYTES:-0}) / avg ))
  fi
  tmp="${STATUS_JSON}.tmp"
  {
    printf '{\n'
    printf '  "tool": "mono-ftp-mirror",\n'
    printf '  "version": "%s",\n' "$VERSION"
    printf '  "phase": "%s",\n' "$(json_str "$PHASE")"
    printf '  "origin": "ftp://%s%s",\n' "$(json_str "${FTPHOST:-}")" "$(json_str "${RPATH:-}")"
    printf '  "pct": %d,\n' "$pct"
    printf '  "pct_basis": "%s",\n' "$( [ "${EXPECT_BYTES:-0}" -gt 0 ] && printf 'declared' || printf 'discovered' )"
    printf '  "files_downloaded": %d,\n' "${FILES:-0}"
    printf '  "files_detected": %d,\n' "${DET_FILES:-0}"
    printf '  "bytes_downloaded": %d,\n' "${BYTES:-0}"
    printf '  "bytes_target": %d,\n' "${target:-0}"
    printf '  "speed_now_bps": %d,\n' "${SP_NOW:-0}"
    printf '  "speed_avg_bps": %d,\n' "$avg"
    printf '  "eta_s": %d,\n' "$eta_s"
    printf '  "stalled": %s,\n' "$( [ "${STALLED:-0}" -eq 1 ] && printf 'true' || printf 'false' )"
    printf '  "retries": %d,\n' "${RELAUNCHES:-0}"
    printf '  "retries_max": %d,\n' "${MAX_RELAUNCH:-5}"
    printf '  "dominant_error_class": "%s",\n' "$(json_str "${DOMINANT_CLASS:-}")"
    printf '  "live_watch_hits": %d,\n' "${LIVE_HITS:-0}"
    printf '  "scan_critical": %d,\n' "${CRIT:-0}"
    printf '  "scan_review": %d,\n' "${REVIEW:-0}"
    printf '  "updated_at": "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)"
    printf '}\n'
  } > "$tmp" 2>/dev/null && mv -f "$tmp" "$STATUS_JSON" 2>/dev/null || true
  return 0
}

phase_idx() {  # posición de una fase en el ciclo (para saber si ya pasó)
  case "$1" in
    conexion) echo 0 ;; estrategia) echo 1 ;; descarga) echo 2 ;;
    verificacion) echo 3 ;; escaneo) echo 4 ;; cierre) echo 5 ;; *) echo 9 ;;
  esac
}

# Línea de fases para el panel: dónde estoy y qué falta, antes que cualquier
# número. ✓ hecha · ● en curso · ○ pendiente.
phase_line() {
  local out="" p mark label
  local pct_txt=""
  for p in conexion estrategia descarga verificacion escaneo cierre; do
    case "$p" in
      conexion)     label="Conexión" ;;
      estrategia)   label="Estrategia" ;;
      descarga)     label="Descarga" ;;
      verificacion) label="Verificar" ;;
      escaneo)      label="Escanear" ;;
      cierre)       label="Cierre" ;;
    esac
    if [ "$p" = "estrategia" ]; then
      # La estrategia se decide DENTRO de la descarga (checkpoint sobre avance
      # real): su marca la da STRATEGY_DONE, no la posición en la lista.
      [ "${STRATEGY_DONE:-0}" -eq 1 ] && mark="✓" || mark="○"
      out="${out:+$out · }${mark} ${label}"
    elif [ "$p" = "$PHASE" ]; then
      mark="●"
      [ "$p" = "descarga" ] && pct_txt=" ${1:-0}%"
      out="${out:+$out · }${mark} ${label}${pct_txt}"; pct_txt=""
    else
      # ¿Antes o después de la fase actual? Comparación por índice (un glob
      # posicional falla con fases adyacentes: los espacios se solapan).
      if [ "$(phase_idx "$p")" -lt "$(phase_idx "$PHASE")" ]; then
        mark="✓"
      else
        mark="○"
      fi
      out="${out:+$out · }${mark} ${label}"
    fi
  done
  printf '%s' "$out"
  return 0
}

# --------------------------------------------------------------- versión/update §3.4

# SHA256 de un archivo: sha256sum (GNU) o shasum -a 256 (macOS/BSD).
sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    echo ""
  fi
}

cmd_version() {
  local self sha
  self=$(command -v -- "$0" 2>/dev/null || printf '%s' "$0")
  sha=$(sha256_file "$self")
  echo "mono-ftp-mirror v${VERSION}"
  echo "SHA256: ${sha:-'(sin sha256sum/shasum en este sistema)'}"
  echo "Archivo: $self"
  exit 0
}

# --update: consulta latest.json, compara, descarga a temporal, verifica el
# SHA256 declarado, reemplaza con mv atómico y conserva la anterior como .bak.
# Si algo falla en cualquier punto, NO toca el archivo en uso. Un checksum que
# no coincide aborta SIN borrar la descarga (es evidencia) y sale con código
# distinto de cero.
cmd_update() {
  echo "── Auto-actualización desde $LATEST_URL ──"
  command -v wget >/dev/null 2>&1 || { echo "✗ wget no está instalado." >&2; exit 1; }

  local self sha_now
  self=$(command -v -- "$0" 2>/dev/null || printf '%s' "$0")
  [ -w "$self" ] || { echo "✗ Sin permiso de escritura sobre $self." >&2; exit 1; }

  local tmpdir manifest
  tmpdir=$(mktemp -d) || exit 1
  manifest="$tmpdir/latest.json"
  if ! wget -q -T 20 -O "$manifest" "$LATEST_URL"; then
    echo "✗ No se pudo descargar latest.json (¿sin salida a internet?)." >&2
    rm -rf "$tmpdir"; exit 1
  fi

  # Parseo sin jq: claves conocidas de un JSON que generamos nosotros.
  local new_ver url want_sha
  new_ver=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' "$manifest" | tail -1 | cut -d'"' -f4)
  url=$(grep -oE '"url"[[:space:]]*:[[:space:]]*"[^"]+"' "$manifest" | head -1 | cut -d'"' -f4)
  want_sha=$(grep -oE '"sha256"[[:space:]]*:[[:space:]]*"[0-9a-fA-F]{64}"' "$manifest" | head -1 | cut -d'"' -f4)

  if [ -z "$new_ver" ] || [ -z "$url" ] || [ -z "$want_sha" ]; then
    echo "✗ latest.json no tiene la forma esperada (version/url/sha256)." >&2
    rm -rf "$tmpdir"; exit 1
  fi
  case "$url" in
    https://*) : ;;
    *) echo "✗ La URL del release no es https: $url" >&2; rm -rf "$tmpdir"; exit 1 ;;
  esac

  if [ "$new_ver" = "$VERSION" ]; then
    echo "✓ Ya estás en la última versión ($VERSION). Sin cambios."
    rm -rf "$tmpdir"; exit 0
  fi
  echo "  Disponible: v$new_ver (actual: v$VERSION)"
  echo "  URL: $url"

  local newfile="$tmpdir/mono-ftp-mirror-$new_ver.sh"
  if ! wget -q -T 60 -O "$newfile" "$url"; then
    echo "✗ Descarga fallida." >&2
    rm -rf "$tmpdir"; exit 1
  fi

  local got_sha
  got_sha=$(sha256_file "$newfile")
  if [ -z "$got_sha" ]; then
    echo "✗ Sin sha256sum/shasum: no puedo verificar. No se actualiza." >&2
    rm -rf "$tmpdir"; exit 1
  fi
  if [ "$got_sha" != "$want_sha" ]; then
    echo "✗ CHECKSUM NO COINCIDE." >&2
    echo "  esperado: $want_sha" >&2
    echo "  obtenido: $got_sha" >&2
    echo "  El archivo descargado queda en $newfile como evidencia. NO lo ejecutes." >&2
    exit 1                                  # no borrar: es evidencia
  fi

  if ! bash -n "$newfile" 2>/dev/null; then
    echo "✗ El script descargado tiene errores de sintaxis. Abortando." >&2
    rm -rf "$tmpdir"; exit 1
  fi

  cp -- "$self" "${self}.bak" || { echo "✗ No pude crear el .bak." >&2; rm -rf "$tmpdir"; exit 1; }
  chmod +x "$newfile"
  if ! mv -- "$newfile" "$self"; then
    echo "✗ mv falló; el archivo en uso quedó intacto (backup en ${self}.bak)." >&2
    rm -rf "$tmpdir"; exit 1
  fi
  sha_now=$(sha256_file "$self")
  echo "✓ Actualizado: v$VERSION → v$new_ver"
  echo "  SHA256: $sha_now"
  echo "  Anterior: ${self}.bak"
  rm -rf "$tmpdir"
  exit 0
}

# --------------------------------------------------------------- argumentos
ATTACH=0; SCAN_ONLY=0; DO_SCAN=1; DEST="$PWD"
# Los flags con valor exigen su argumento explícitamente: `shift 2` con un
# flag colgando al final mataría el script bajo set -e sin mensaje.
need_val() { [ $# -ge 2 ] || die "El flag $1 necesita un valor. Ver --help."; }
# Guarda de sourcing: no parsear los args del test runner cuando se sourcea.
if [ "${MONO_FTP_MIRROR_LIB:-0}" != "1" ]; then
while [ $# -gt 0 ]; do
  case "$1" in
    --attach)    ATTACH=1; shift ;;
    --scan-only) SCAN_ONLY=1; shift ;;
    --no-scan)   DO_SCAN=0; shift ;;
    --no-auto-retry) NO_AUTO_RETRY=1; shift ;;
    --version|-v) cmd_version ;;
    --update)    cmd_update ;;
    --dest)      need_val "$@"; DEST="$2"; shift 2 ;;
    --refresh)   need_val "$@"; REFRESH="$2"; shift 2 ;;
    --help|-h)   usage; exit 0 ;;
    *) die "Opción desconocida: $1 (usa --help)" ;;
  esac
done
fi

# --------------------------------------------------------------- preflight
preflight() {
  command -v wget >/dev/null 2>&1 || die "wget no está instalado."
  command -v awk  >/dev/null 2>&1 || die "awk no está disponible."
  HAVE_CURL=0; command -v curl    >/dev/null 2>&1 && HAVE_CURL=1
  HAVE_PY=0;   command -v python3 >/dev/null 2>&1 && HAVE_PY=1
  # Resolvedor para la detección de Cloudflare (§6). Opcional: sin ninguno,
  # no se puede comprobar y se avisa; nunca se da por bueno lo no verificado.
  HAVE_GETENT=0; command -v getent >/dev/null 2>&1 && HAVE_GETENT=1
  HAVE_DIG=0;    command -v dig    >/dev/null 2>&1 && HAVE_DIG=1
  # §4: sin unzip no se puede ni verificar ni descomprimir → la opción zip no
  # se ofrece (§3.5). Se declara en la puerta, no en silencio.
  HAVE_UNZIP=0;  command -v unzip  >/dev/null 2>&1 && HAVE_UNZIP=1

  [ -d "$DEST" ] || die "El destino no existe: $DEST"
  cd "$DEST"; DEST="$PWD"

  case "$DEST" in
    */public_html|*/public_html/*)
      die "El destino está dentro de public_html. Sería descargable por HTTP.
   Muévete a un directorio hermano, por ejemplo: ~/forense-<cliente>" ;;
  esac
  [ -w "$DEST" ] || die "Sin permiso de escritura en $DEST"

  local avail
  avail=$(df -Pk "$DEST" | awk 'NR==2{print $4}')
  if [ "${avail:-0}" -lt 2097152 ]; then
    warn "Quedan menos de 2 GB libres ($(human $((avail*1024))))."
  fi
  return 0
}


# --------------------------------------------------------------- Cloudflare §6
#
# Cloudflare sólo hace proxy de HTTP/HTTPS. Si el host FTP resuelve a una IP de
# Cloudflare, el puerto 21 no llega y wget se cuelga reintentando sin pista útil.
# Comprobación previa BLOQUEANTE (§6.2) + comprobación del destino informativa
# (§6.3). Todo degradable: sin resolvedor se avisa, nunca se da por bueno.

CF_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/mono-ftp-mirror"
CF_CACHE_FILE="$CF_CACHE_DIR/cf-ips"
CF_CACHE_TTL=86400                       # 24 h
CF_EMBEDDED_DATE="2026-08-22"            # fecha de la lista de respaldo

# Respaldo embebido para nodos sin salida a internet. Verificado el
# 2026-08-22 contra cloudflare.com/ips-v4 e ips-v6. Cambian de vez en cuando:
# cuando se use este respaldo (y no la lista viva), la salida lo dice con fecha.
cf_embedded_ranges() {
  cat <<'EOF'
173.245.48.0/20
103.21.244.0/22
103.22.200.0/22
103.31.4.0/22
141.101.64.0/18
108.162.192.0/18
190.93.240.0/20
188.114.96.0/20
197.234.240.0/22
198.41.128.0/17
162.158.0.0/15
104.16.0.0/13
104.24.0.0/14
172.64.0.0/13
131.0.72.0/22
2400:cb00::/32
2606:4700::/32
2803:f800::/32
2405:b500::/32
2405:8100::/32
2a06:98c0::/29
2c0f:f248::/32
EOF
}

# Valida que cada línea sea un CIDR IPv4/IPv6 con forma correcta (§9: no meter
# contenido remoto en una comparación sin comprobar su forma). Filtra a stdout.
cf_validate_cidrs() {
  awk '
    /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/ { print; next }
    /^[0-9A-Fa-f:]+\/[0-9]+$/                   { print; next }
  '
}

# Deja los rangos válidos en CF_RANGES (string, uno por línea) y CF_SOURCE en
# {red, cache, embebido}. Preferencia: cache fresca > red > cache vieja > embebido.
CF_RANGES=""; CF_SOURCE=""
cf_load_ranges() {
  CF_RANGES=""; CF_SOURCE=""
  local now age raw=""

  # 1. cache fresca
  if [ -f "$CF_CACHE_FILE" ]; then
    now=$(date +%s 2>/dev/null || echo 0)
    age=$(( now - $(cf_file_mtime "$CF_CACHE_FILE") ))
    if [ "$age" -ge 0 ] && [ "$age" -lt "$CF_CACHE_TTL" ]; then
      raw=$(cf_validate_cidrs < "$CF_CACHE_FILE")
      if [ -n "$raw" ]; then CF_RANGES="$raw"; CF_SOURCE="cache"; return 0; fi
    fi
  fi

  # 2. red (curl), y refrescar cache
  if [ "${HAVE_CURL:-0}" -eq 1 ] || command -v curl >/dev/null 2>&1; then
    local v4 v6
    v4=$(curl -fsSL --max-time 15 https://www.cloudflare.com/ips-v4 2>/dev/null || true)
    v6=$(curl -fsSL --max-time 15 https://www.cloudflare.com/ips-v6 2>/dev/null || true)
    raw=$(printf '%s\n%s\n' "$v4" "$v6" | cf_validate_cidrs)
    if [ -n "$raw" ]; then
      CF_RANGES="$raw"; CF_SOURCE="red"
      mkdir -p "$CF_CACHE_DIR" 2>/dev/null && printf '%s\n' "$raw" > "$CF_CACHE_FILE" 2>/dev/null || true
      return 0
    fi
  fi

  # 3. cache vieja (mejor vieja que nada)
  if [ -f "$CF_CACHE_FILE" ]; then
    raw=$(cf_validate_cidrs < "$CF_CACHE_FILE")
    if [ -n "$raw" ]; then CF_RANGES="$raw"; CF_SOURCE="cache-vieja"; return 0; fi
  fi

  # 4. respaldo embebido
  CF_RANGES=$(cf_embedded_ranges | cf_validate_cidrs)
  CF_SOURCE="embebido"
  return 0
}

cf_file_mtime() {  # imprime epoch del mtime; GNU y BSD stat
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}

# Resuelve un host a IPs (una por línea). getent primero (respeta nsswitch),
# dig como alternativa. Vacío si no hay resolvedor o no resuelve.
resolve_host() {
  local host="$1"
  if [ "${HAVE_GETENT:-0}" -eq 1 ] || command -v getent >/dev/null 2>&1; then
    getent ahosts "$host" 2>/dev/null | awk '{print $1}' | sort -u
    return 0
  fi
  if [ "${HAVE_DIG:-0}" -eq 1 ] || command -v dig >/dev/null 2>&1; then
    { dig +short A "$host" 2>/dev/null; dig +short AAAA "$host" 2>/dev/null; } \
      | grep -E '^[0-9A-Fa-f.:]+$' | sort -u
    return 0
  fi
  return 0   # sin resolvedor: stdout vacío
}

# ¿Hay algún resolvedor disponible?
has_resolver() {
  [ "${HAVE_GETENT:-0}" -eq 1 ] || [ "${HAVE_DIG:-0}" -eq 1 ] \
    || command -v getent >/dev/null 2>&1 || command -v dig >/dev/null 2>&1
}

# ¿La IP $1 cae dentro de alguno de los rangos CF_RANGES?
# python3 (ipaddress) cubre IPv4 e IPv6; sin python3, awk cubre sólo IPv4 y se
# declara la limitación. Devuelve 0 si hay coincidencia.
ip_in_cf() {
  local ip="$1"
  [ -n "$ip" ] || return 1
  [ -n "$CF_RANGES" ] || return 1
  if [ "${HAVE_PY:-0}" -eq 1 ] || command -v python3 >/dev/null 2>&1; then
    # Los rangos van por entorno, NO por stdin: stdin lo ocupa el heredoc con
    # el programa. El match cubre IPv4 e IPv6 vía ipaddress.
    CF_RANGES="$CF_RANGES" python3 - "$ip" >/dev/null 2>&1 <<'PYEOF'
import sys, os, ipaddress
ip = sys.argv[1]
try:
    addr = ipaddress.ip_address(ip)
except ValueError:
    sys.exit(2)
for line in os.environ.get("CF_RANGES", "").splitlines():
    line = line.strip()
    if not line:
        continue
    try:
        if addr in ipaddress.ip_network(line, strict=False):
            sys.exit(0)
    except ValueError:
        continue
sys.exit(1)
PYEOF
    return $?
  fi
  # Fallback awk sólo IPv4.
  case "$ip" in *:*) return 1 ;; esac   # IPv6 sin python3: no se puede
  printf '%s\n' "$CF_RANGES" | awk -v ip="$ip" '
    function a2n(a,   p){ split(a,p,"."); return (p[1]*16777216)+(p[2]*65536)+(p[3]*256)+p[4] }
    /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/ {
      split($0, c, "/"); base=a2n(c[1]); bits=c[2]+0
      if (bits<=0) { found=1; exit }
      mask=(bits>=32)?4294967295:( (2^32) - (2^(32-bits)) )
      ipn=a2n(ip)
      if ( (and_(ipn,mask)) == (and_(base,mask)) ) { found=1; exit }
    }
    function and_(x,y,   r,i,bx,by){ r=0; for(i=0;i<32;i++){ bx=int(x/(2^i))%2; by=int(y/(2^i))%2; if(bx&&by) r+=2^i } return r }
    END{ exit(found?0:1) }
  '
}

# ── §6.2 Comprobación previa, bloqueante ──────────────────────────────────────
# Recibe el host propuesto. Si resuelve a Cloudflare, ofrece alternativas
# resueltas y devuelve por CF_NEW_HOST el host elegido (o vacío = cancelar).
# Devuelve 0 si se puede seguir con FTPHOST ya fijado; 1 si el operador cancela.
CF_NEW_HOST=""
cf_precheck() {
  local host="$1"
  CF_NEW_HOST="$host"

  # IP literal: no se resuelve, pero SÍ se contrasta igual (una IP de CF
  # tipeada a mano sigue siendo CF). §6.2.4 matizado.
  cf_load_ranges

  if ! has_resolver; then
    warn "Sin dig ni getent: NO se pudo comprobar si el host es de Cloudflare."
    info "${C_DIM}El puerto 21 no conecta contra IPs de proxy de Cloudflare.${C_RESET}"
    local a; read -rp "  ¿Continuar bajo tu responsabilidad? [s/N] " a || a=""
    case "$a" in [sS]*) return 0 ;; *) return 1 ;; esac
  fi

  local ips ip hit=""
  case "$host" in
    *[!0-9.]*) ips=$(resolve_host "$host") ;;     # nombre: resolver
    *)         ips="$host" ;;                      # IPv4 literal: usar tal cual
  esac
  # IPv6 literal (tiene ':') también se usa tal cual.
  case "$host" in *:*) ips="$host" ;; esac

  if [ -z "$ips" ]; then
    warn "No se pudo resolver $host."
    info "Revisá el nombre, o probá con la IP de origen del panel del hosting."
    local a; read -rp "  Host FTP alternativo [Enter para cancelar]: " a || a=""
    [ -z "$a" ] && return 1
    cf_precheck "$a"; return $?
  fi

  while IFS= read -r ip; do
    [ -n "$ip" ] || continue
    if ip_in_cf "$ip"; then hit="$ip"; break; fi
  done <<< "$ips"

  if [ -z "$hit" ]; then
    return 0   # limpio, seguir
  fi

  # --- Coincidencia: bloquear y ofrecer alternativas resueltas ---------------
  printf '\n%s\n' "${C_ERR}✗ ${host} resuelve a ${hit} — rango de Cloudflare.${C_RESET}"
  info "Cloudflare sólo enruta HTTP/HTTPS. El puerto 21 no va a conectar."
  [ "$CF_SOURCE" = "embebido" ] && \
    info "${C_DIM}(rangos de respaldo embebidos del ${CF_EMBEDDED_DATE}; sin lista viva)${C_RESET}"
  printf '\n  %s\n' "${C_B}Alternativas, en orden:${C_RESET}"
  info "1. IP de origen directa, la que muestra el panel del hosting"

  # 2 y 3: resolverlas y mostrar sólo si difieren de rangos CF.
  local apex sub
  apex=$(printf '%s' "$host" | sed -E 's/^[^.]+\.//')   # ftp.dom.com -> dom.com
  cf_show_alt "2. Apex ${apex}" "$apex"
  for sub in "cpanel.$apex" "mail.$apex"; do
    cf_show_alt "3. ${sub}" "$sub"
  done
  info "4. El host que sugiere cPanel en \"Configurar cliente FTP\""

  printf '\n'
  local a; read -rp "  Host FTP alternativo [Enter para cancelar]: " a || a=""
  [ -z "$a" ] && return 1
  cf_precheck "$a"; return $?
}

# Resuelve un candidato y lo muestra sólo si NO es Cloudflare (info concreta).
cf_show_alt() {  # etiqueta | host
  local label="$1" h="$2" ips ip good=""
  ips=$(resolve_host "$h")
  while IFS= read -r ip; do
    [ -n "$ip" ] || continue
    if ! ip_in_cf "$ip"; then good="$ip"; break; fi
  done <<< "$ips"
  [ -n "$good" ] && info "${label}: ${C_OK}${good}${C_RESET}"
  return 0
}

# ── §6.3 Comprobación del destino, informativa (no bloquea) ───────────────────
# Recibe el dominio que se está migrando. Si está proxiado, una nota; si no,
# silencio.
cf_dest_note() {
  local domain="$1"
  [ -n "$domain" ] || return 0
  has_resolver || return 0
  [ -n "$CF_RANGES" ] || cf_load_ranges
  local ips ip proxied=""
  ips=$(resolve_host "$domain")
  while IFS= read -r ip; do
    [ -n "$ip" ] || continue
    if ip_in_cf "$ip"; then proxied="$ip"; break; fi
  done <<< "$ips"
  [ -z "$proxied" ] && return 0
  printf '\n'
  info "${C_ACC}ℹ ${domain} está proxiado por Cloudflare (nube naranja).${C_RESET}"
  info "${C_DIM}Al apuntar el DNS acá, Let's Encrypt no podrá validar por HTTP-01${C_RESET}"
  info "${C_DIM}mientras el proxy intercepte /.well-known/acme-challenge/.${C_RESET}"
  info "${C_DIM}Antes del corte: proxy en gris hasta emitir el certificado, o${C_RESET}"
  info "${C_DIM}una regla que deje pasar /.well-known/*.${C_RESET}"
  return 0
}

# ----------------------------------------------------- estrategia §4
#
# Estrategia de transferencia y estimación de tiempo. La restricción que define
# el diseño: FTP no comprime en el origen, y comprimir ESCRIBE en el origen —
# prohibido si el sitio está comprometido. La herramienta nunca genera el zip;
# recomienda, guía y descarga.
#
# Modelo de medición: sobre AVANCE REAL. El espejo arranca de una; a los
# CALIBRATE_AT segundos hay throughput, coste por archivo e inventario parcial
# medidos del tráfico real (no de un probe sintético), y recién ahí se muestra
# la puerta y las dos estimaciones. Elegir zip después de arrancar no pierde
# nada: lo ya bajado queda.

CASE_CLEAN=1          # 1 = migración limpia · 0 = comprometido/bajo investigación
ZIP_ALLOWED=0         # resultado de la puerta §4.2
ZIP_REASON=""         # motivo del descarte, para pantalla e informe
REST_SUPPORTED=-1     # -1 sin probar · 0 no · 1 sí
COMP_RATIO="0.70"     # compresibilidad global estimada
STRATEGY_DONE=0       # el checkpoint corre una sola vez

# §4.1 — la primera pregunta del flujo, antes de credenciales y de cualquier
# estimación. Si es caso 2, la estrategia queda forzada a archivo por archivo
# y NO se vuelve a preguntar.
ask_case_type() {
  printf '%s\n' "${C_B}── Tipo de caso ───────────────────────────────────────${C_RESET}"
  info "1) Migración limpia — el sitio funciona, no hay incidente"
  info "2) Sitio comprometido o bajo investigación"
  local a; read -rp "  Caso [1]: " a || true
  case "${a:-1}" in
    2) CASE_CLEAN=0
       info "${C_DIM}Comprimir modifica el origen y contamina la evidencia:${C_RESET}"
       info "${C_DIM}la estrategia queda en archivo por archivo. No se vuelve a preguntar.${C_RESET}" ;;
    *) CASE_CLEAN=1 ;;
  esac
  printf '\n'
  return 0
}

# §4.4 — compresibilidad por extensión desde los .listing ya descargados.
# Suma bytes por categoría y deja el ratio global en COMP_RATIO (awk, float).
estimate_compressibility() {
  local root="$1"
  COMP_RATIO=$(find "$root" -name '.listing' -exec cat {} + 2>/dev/null | tr -d '\r' | awk '
    /^-/ {
      size = $5 + 0
      name = $NF
      n = split(name, seg, ".")
      ext = (n > 1) ? tolower(seg[n]) : ""
      if (ext ~ /^(jpg|jpeg|png|gif|webp|avif|mp4|mov|mp3|zip|gz|tgz|woff|woff2|pdf|ico)$/)
        b_comp += size
      else if (ext ~ /^(php|js|css|html|htm|txt|json|xml|svg|sql|po|mo|csv|map)$/)
        b_text += size
      else
        b_unk += size
    }
    END {
      total = b_comp + b_text + b_unk
      if (total <= 0) { print "0.70"; exit }
      printf "%.2f", (b_comp*0.98 + b_text*0.30 + b_unk*0.70) / total
    }')
  [ -n "$COMP_RATIO" ] || COMP_RATIO="0.70"
  return 0
}

# §4.5 — las dos estimaciones. Args: bytes_totales n_archivos throughput(B/s)
# overhead(s/archivo, decimal) ratio. Deja segundos (enteros) en:
#   EST_A_XFER EST_A_RT EST_A_TOTAL     (archivo por archivo)
#   EST_B_COMP EST_B_XFER EST_B_UNZ EST_B_TOTAL   (zip)
# y el requisito de espacio (bytes, con margen 1.15) en EST_B_NEED.
compute_estimates() {
  local bytes="$1" files="$2" thr="$3" ovh="$4" ratio="$5" out
  out=$(awk -v B="$bytes" -v N="$files" -v T="$thr" -v O="$ovh" -v R="$ratio" 'BEGIN{
    if (T <= 0) T = 1
    a_xfer = B / T
    a_rt   = N * O
    b_comp = B / (30*1024*1024)     # compresión en el origen ~30 MB/s (§4.5)
    b_xfer = (B * R) / T
    b_unz  = B / (80*1024*1024)     # descompresión local ~80 MB/s (decisión propia)
    need   = B * R * 1.15           # §4.2 C3: margen 15%
    printf "%d %d %d %d %d %d %d %.0f",
      a_xfer, a_rt, a_xfer+a_rt,
      b_comp, b_xfer, b_unz, b_comp+b_xfer+b_unz+O,
      need
  }')
  read -r EST_A_XFER EST_A_RT EST_A_TOTAL EST_B_COMP EST_B_XFER EST_B_UNZ EST_B_TOTAL EST_B_NEED <<< "$out"
  return 0
}

# §4.2 C4 — tabla REST × estabilidad × T_zip. Args: rest(0/1) cortes(0/1)
# t_zip_s. Imprime "ok", "ok-aviso" (sin REST pero corto y estable) o "no".
zip_gate_c4() {
  local rest="$1" cortes="$2" tz="$3"
  if [ "$rest" -eq 1 ]; then echo ok; return 0; fi
  if [ "$cortes" -ne 0 ]; then echo no; return 0; fi
  if [ "$tz" -lt 600 ]; then echo ok-aviso; else echo no; fi
  return 0
}

# §4.6 — regla de recomendación. Args: t_file t_zip clean(0/1) zip_allowed(0/1).
# Imprime "zip" o "archivo".
zip_recommend() {
  local tf="$1" tz="$2" clean="$3" allowed="$4"
  [ "$clean" -eq 1 ] || { echo archivo; return 0; }
  [ "$allowed" -eq 1 ] || { echo archivo; return 0; }
  [ "$tz" -gt 0 ] && [ "$tf" -gt $((2 * tz)) ] && { echo zip; return 0; }
  echo archivo
  return 0
}

# Probe de REST (§4.2 C4.1): pedir un rango de 101 bytes sobre un archivo ya
# descargado (así se puede comparar el contenido, no solo el tamaño). Deja
# REST_SUPPORTED en 0/1. Sin curl o sin candidato: queda -1 (no comprobado).
rest_probe() {
  local root="$1"
  REST_SUPPORTED=-1
  [ "$HAVE_CURL" -eq 1 ] || return 0
  [ -n "${FTPPASS:-}" ] || return 0
  # Candidato: archivo local ya bajado, >1 KB, con su ruta remota derivable.
  local cand rel remote tmp
  cand=$(find "$(mirror_root)" -type f ! -name '.listing' -size +1k 2>/dev/null | head -1)
  [ -n "$cand" ] || return 0
  rel="${cand#"$DEST"/}"                      # p.ej. public_html/wp-load.php
  remote="/${rel}"                            # ruta remota estilo wget
  tmp=$(mktemp)
  build_auth_files
  if curl -s --connect-timeout 15 --max-time 30 -K "$CURLRC" \
       -r 100-200 "ftp://${FTPHOST}${remote}" -o "$tmp" 2>/dev/null; then
    local got want
    got=$(stat -c %s "$tmp" 2>/dev/null || stat -f %z "$tmp" 2>/dev/null || echo 0)
    if [ "$got" -eq 101 ]; then
      # comparar el tramo con el archivo local (dd 101 bytes desde offset 100)
      want=$(dd if="$cand" bs=1 skip=100 count=101 2>/dev/null | cksum | awk '{print $1}')
      got=$(cksum < "$tmp" | awk '{print $1}')
      [ "$got" = "$want" ] && REST_SUPPORTED=1 || REST_SUPPORTED=0
    else
      REST_SUPPORTED=0                        # devolvió todo o falló: no hay REST
    fi
  else
    REST_SUPPORTED=0
  fi
  wipe_auth_files
  rm -f "$tmp"
  return 0
}

# §4.2 C2 — ¿la cuenta FTP alcanza fuera del docroot? Lista el directorio padre
# del home por FTP (probe literal del HANDOFF). Enjaulada → el zip viviría
# dentro del docroot: descartado salvo aceptación explícita.
zip_reach_probe() {
  [ "$HAVE_CURL" -eq 1 ] || return 1
  [ -n "${FTPPASS:-}" ] || return 1
  local out
  build_auth_files
  out=$(curl -s --connect-timeout 15 --max-time 30 -K "$CURLRC" \
        --list-only "ftp://${FTPHOST}/../" 2>/dev/null || true)
  wipe_auth_files
  [ -n "$out" ]
}

# §4.2 — la puerta completa. Cuatro condiciones, lista visible, y el zip no se
# ofrece si alguna falla. Deja ZIP_ALLOWED/ZIP_REASON. Necesita EST_B_* ya
# calculadas (para el número de espacio y T_zip).
zip_gate() {
  local cortes="$1"
  ZIP_ALLOWED=0; ZIP_REASON=""
  local c1=0 c2=0 c3=0 c4v="" panel_ok="" free_gb="" need_h
  need_h=$(human "$EST_B_NEED")

  printf '%s\n' "${C_B}── ¿Se puede comprimir en el origen? ──────────────────${C_RESET}"

  # C1 — permitido
  if [ "$CASE_CLEAN" -eq 1 ]; then
    c1=1; printf '  %s\n' "${C_OK}✓ Caso limpio, sin incidente abierto${C_RESET}"
  else
    printf '  %s\n' "${C_ERR}✗ Sitio comprometido: comprimir modifica el origen y contamina la evidencia${C_RESET}"
    ZIP_REASON="comprimir modifica el origen y contamina la evidencia"
  fi

  # unzip local (§3.5): sin él no hay verificación ni descompresión.
  if [ "$HAVE_UNZIP" -ne 1 ]; then
    printf '  %s\n' "${C_ERR}✗ unzip no está en este servidor: no se puede verificar ni descomprimir${C_RESET}"
    ZIP_REASON="${ZIP_REASON:-falta unzip en el destino}"
  fi

  # C2 — posible (panel + alcance FTP)
  if [ "$c1" -eq 1 ] && [ "$HAVE_UNZIP" -eq 1 ]; then
    read -rp "  ¿Tenés File Manager o Terminal en el panel del hosting? [s/N] " panel_ok || true
    case "$panel_ok" in
      [sS]*)
        if zip_reach_probe; then
          c2=1; printf '  %s\n' "${C_OK}✓ Acceso al panel confirmado · la cuenta FTP alcanza fuera del docroot${C_RESET}"
        else
          printf '  %s\n' "${C_WARN}⚠ La cuenta FTP está enjaulada: el zip sólo podría vivir DENTRO del docroot,${C_RESET}"
          printf '  %s\n' "${C_WARN}  descargable por cualquiera que adivine el nombre.${C_RESET}"
          local acc; read -rp "  ¿Crearlo dentro igual y borrarlo apenas termine? [s/N] " acc || true
          case "$acc" in [sS]*) c2=1 ;; *) ZIP_REASON="${ZIP_REASON:-cuenta FTP enjaulada en el docroot}" ;; esac
        fi ;;
      *)
        printf '  %s\n' "${C_ERR}✗ Sin panel no hay forma de crear el zip: FTP no comprime${C_RESET}"
        ZIP_REASON="${ZIP_REASON:-sin File Manager/Terminal en el panel}" ;;
    esac
  fi

  # C3 — espacio (se pregunta al operador, con el número requerido a la vista)
  if [ "$c2" -eq 1 ]; then
    info "El zip va a pesar aproximadamente $(human "$((EST_B_NEED * 100 / 115))")."
    info "Con margen de seguridad hacen falta ${need_h} libres en el origen."
    info "${C_DIM}Si la compresión se queda sin espacio a mitad, deja un zip truncado que${C_RESET}"
    info "${C_DIM}igual ocupa lo escrito: una cuenta al 90 %% pasa al 100 %% y rompe el correo.${C_RESET}"
    read -rp "  ¿Cuánto espacio libre reporta el panel? (GB): " free_gb || true
    local need_gb_x100 free_x100
    need_gb_x100=$(awk -v n="$EST_B_NEED" 'BEGIN{printf "%d", n/1024/1024/1024*100}')
    free_x100=$(awk -v g="${free_gb:-0}" 'BEGIN{printf "%d", g*100}' 2>/dev/null || echo 0)
    if [ "${free_x100:-0}" -ge "${need_gb_x100:-0}" ] && [ "${free_x100:-0}" -gt 0 ]; then
      c3=1; printf '  %s\n' "${C_OK}✓ Espacio libre en el origen: ${free_gb} GB · requiere ${need_h}${C_RESET}"
    else
      printf '  %s\n' "${C_ERR}✗ Espacio libre en el origen: ${free_gb:-0} GB · requiere ${need_h}${C_RESET}"
      ZIP_REASON="${ZIP_REASON:-no hay espacio en el origen ($need_h requeridos)}"
    fi
  fi

  # C4 — la red aguanta una transferencia larga y única
  if [ "$c3" -eq 1 ]; then
    rest_probe "$(mirror_root)"
    case "$REST_SUPPORTED" in
      1) printf '  %s\n' "${C_OK}✓ Reanudación por rango (REST) soportada${C_RESET}" ;;
      0) printf '  %s\n' "${C_WARN}○ Sin REST: un corte reinicia el zip desde cero${C_RESET}" ;;
      *) printf '  %s\n' "${C_WARN}○ REST no comprobado (sin curl o sin candidato)${C_RESET}" ;;
    esac
    local rest_bit=0; [ "$REST_SUPPORTED" -eq 1 ] && rest_bit=1
    c4v=$(zip_gate_c4 "$rest_bit" "$cortes" "$EST_B_TOTAL")
    case "$c4v" in
      ok)       ZIP_ALLOWED=1 ;;
      ok-aviso) ZIP_ALLOWED=1
                printf '  %s\n' "${C_WARN}  (aviso: sin REST, un corte a mitad del zip lo reinicia desde cero)${C_RESET}" ;;
      no)
        if [ "$cortes" -ne 0 ]; then
          printf '  %s\n' "${C_ERR}✗ La conexión tuvo cortes durante la medición: una transferencia única no compensa${C_RESET}"
          ZIP_REASON="línea inestable (hubo cortes) y sin reanudación por rango"
        else
          printf '  %s\n' "${C_ERR}✗ Sin REST y T_zip ≥ 10 min: la apuesta no compensa${C_RESET}"
          ZIP_REASON="sin REST y transferencia estimada ≥ 10 min"
        fi ;;
    esac
  fi

  if [ "$ZIP_ALLOWED" -ne 1 ]; then
    printf '\n  %s\n' "▸ Zip descartado: ${ZIP_REASON:-no pasó la puerta}."
    printf '  %s\n\n' "Se procede archivo por archivo."
  fi
  return 0
}

# Panel de estrategia (§4.5): las dos estimaciones con desglose, SIEMPRE ambas,
# incluso con el zip descartado (con el motivo al lado).
show_estimates() {
  local files="$1" bytes="$2" thr="$3" ovh="$4" reco="$5"
  printf '%s\n' "${C_B}── Estrategia de transferencia ────────────────────────${C_RESET}"
  printf '  %s\n' "${C_DIM}Medición de red (sobre el avance real, no un probe)${C_RESET}"
  printf '    Throughput          %s\n' "$(human_rate "$thr")"
  printf '    Coste por archivo   %ss\n' "$ovh"
  printf '    Archivos            %s%s\n' "$(thousands "$files")" "$( [ "$INVENTORY_PARTIAL" -eq 1 ] && printf ' (inventario aún parcial)' )"
  printf '    Peso                %s\n' "$(human "$bytes")"
  printf '    Compresibilidad     %s\n' "$COMP_RATIO"
  printf '\n'
  printf '  A) Archivo por archivo\n'
  printf '     Transferencia   %s\n' "$(hms "$EST_A_XFER")"
  printf '     Round trips     %s%s\n' "$(hms "$EST_A_RT")" \
    "$(awk -v r="$EST_A_RT" -v t="$EST_A_TOTAL" 'BEGIN{ if (t>0 && r*100/t >= 60) printf "   ← el %d %% del tiempo", r*100/t }')"
  printf '     TOTAL           %s\n' "$(hms "$EST_A_TOTAL")"
  printf '\n'
  printf '  B) Zip creado a mano en el panel del hosting%s\n' \
    "$( [ "$ZIP_ALLOWED" -ne 1 ] && printf ' — DESCARTADO: %s' "$ZIP_REASON" )"
  printf '     Comprimir       %s   (estimado, corre en el origen)\n' "$(hms "$EST_B_COMP")"
  printf '     Transferencia   %s\n' "$(hms "$EST_B_XFER")"
  printf '     Descomprimir    %s\n' "$(hms "$EST_B_UNZ")"
  printf '     TOTAL           %s\n' "$(hms "$EST_B_TOTAL")"
  printf '     Requiere %s libres en el origen\n' "$(human "$EST_B_NEED")"
  printf '\n'
  if [ "$reco" = "zip" ]; then
    local ratio_x
    ratio_x=$(awk -v a="$EST_A_TOTAL" -v b="$EST_B_TOTAL" 'BEGIN{ if (b>0) printf "%.0f", a/b; else print "?" }')
    printf '  ▸ Recomendación: B, unas %s× más rápido.\n' "$ratio_x"
    printf '    %s\n' "${C_WARN}Pero comprimir ESCRIBE en el origen. Si hay incidente de${C_RESET}"
    printf '    %s\n' "${C_WARN}seguridad abierto, elegí A.${C_RESET}"
  else
    printf '  ▸ Recomendación: A, archivo por archivo — menos pasos manuales,\n'
    printf '    no toca el origen, reanudable sin rehacer nada.\n'
  fi
  printf '\n'
  return 0
}

# Orquestador: corre una sola vez, a los CALIBRATE_AT s de avance real.
# Si el operador elige zip, detiene el espejo y pasa a zip_flow.
INVENTORY_PARTIAL=1
strategy_checkpoint() {
  STRATEGY_DONE=1
  local elapsed thr ovh files bytes cortes
  elapsed=$(( $(date +%s) - START )); [ "$elapsed" -lt 1 ] && elapsed=1

  count_detected
  files=$DET_FILES; bytes=$DET_BYTES
  # Si el operador declaró tamaño esperado y es mayor, usarlo (inventario parcial).
  if [ "$EXPECT_BYTES" -gt "$bytes" ]; then bytes=$EXPECT_BYTES; fi
  if [ "$files" -lt 1 ] || [ "$bytes" -lt 1 ]; then
    warn "Aún no hay inventario suficiente para estimar; sigo descargando."
    STRATEGY_DONE=0
    return 0
  fi
  # ¿wget ya terminó de recorrer? Entonces el inventario es completo.
  download_finished && INVENTORY_PARTIAL=0 || INVENTORY_PARTIAL=1

  # Throughput puro ≈ pico sostenido; promedio como piso.
  thr=$(( BYTES / elapsed )); [ "$SP_MAX" -gt "$thr" ] && thr=$SP_MAX
  [ "$thr" -lt 1 ] && thr=1
  # Overhead despejado del avance real: elapsed = BYTES/thr + FILES*ovh.
  ovh=$(awk -v e="$elapsed" -v b="$BYTES" -v t="$thr" -v n="$FILES" 'BEGIN{
    if (n < 1) n = 1
    o = (e - b/t) / n
    if (o < 0.05) o = 0.05          # clamp: la fórmula puede dar negativo
    if (o > 2.0)  o = 2.0
    printf "%.2f", o
  }')

  estimate_compressibility "$(mirror_root)"
  compute_estimates "$bytes" "$files" "$thr" "$ovh" "$COMP_RATIO"

  # Estabilidad: ¿hubo timeouts/reconexiones en lo que va de log?
  classify_log "$LOG"
  cortes=0; [ "${CC_TIMEOUT:-0}" -gt 0 ] && cortes=1

  # Pantalla: pausa el panel, muestra puerta + estimaciones, pregunta.
  [ "$TTY" -eq 1 ] && printf '\033[2J\033[H'
  printf '\n'
  zip_gate "$cortes"
  local reco
  reco=$(zip_recommend "$EST_A_TOTAL" "$EST_B_TOTAL" "$CASE_CLEAN" "$ZIP_ALLOWED")
  show_estimates "$files" "$bytes" "$thr" "$ovh" "$reco"

  if [ "$ZIP_ALLOWED" -eq 1 ]; then
    event "estrategia: zip habilitado por la puerta"
  else
    event "estrategia: zip descartado (${ZIP_REASON:-puerta})"
  fi
  if [ "$ZIP_ALLOWED" -ne 1 ]; then
    info "La descarga archivo por archivo sigue corriendo; vuelvo al panel."
    sleep 2; [ "$TTY" -eq 1 ] && printf '\033[2J'
    return 0
  fi

  local d="A"; [ "$reco" = "zip" ] && d="B"
  local opt; read -rp "  ¿Estrategia? [${d}] " opt || true; opt="${opt:-$d}"
  case "$opt" in
    [bB]*)
      event "estrategia elegida: B (zip)"
      # Detener el espejo: lo bajado queda (cuenta como avance si se cae a A).
      if kill -0 "$PID" 2>/dev/null; then
        kill "$PID" 2>/dev/null || true; sleep 1; kill -9 "$PID" 2>/dev/null || true
      fi
      if zip_flow; then
        ZIP_COMPLETED=1
      else
        warn "El zip no llegó sano: vuelvo a archivo por archivo."
        launch_wget || true
      fi ;;
    *)
      event "estrategia elegida: A (archivo por archivo)"
      info "Archivo por archivo. El espejo nunca se detuvo; vuelvo al panel."
      sleep 1; [ "$TTY" -eq 1 ] && printf '\033[2J' ;;
  esac
  return 0
}

ZIP_COMPLETED=0
ZIP_EXTRACT_DIR=""

# §4.7 — flujo zip: la herramienta no comprime; guía, espera y descarga.
# Devuelve 0 si el zip llegó, verificó y se descomprimió; 1 para caer a A.
ZIP_DELETED_CONFIRMED=0
zip_flow() {
  local rnd zipname
  rnd=$(od -An -tx1 -N4 /dev/urandom 2>/dev/null | tr -d ' \n')
  [ -n "$rnd" ] || rnd="a1b2c3d4"
  zipname="migracion-${rnd}.zip"

  printf '\n%s\n' "${C_B}── Crear el zip en el panel del hosting ───────────────${C_RESET}"
  info "1. Entrá al File Manager del panel (cPanel: File Manager)."
  info "2. Seleccioná la carpeta del sitio (p.ej. public_html) → Compress → zip."
  printf '  %s\n' "${C_ERR}3. El zip se crea FUERA de public_html — en /home/<usuario>/.${C_RESET}"
  printf '  %s\n' "${C_ERR}   Un zip del sitio dentro del docroot es descargable por${C_RESET}"
  printf '  %s\n' "${C_ERR}   cualquiera que adivine el nombre: filtración total.${C_RESET}"
  info "4. Nombre sugerido (no predecible): ${C_B}${zipname}${C_RESET}"
  printf '\n'

  local rpath_zip
  read -rp "  Ruta remota exacta del zip (Enter cancela y cae a A): " rpath_zip || true
  [ -z "$rpath_zip" ] && return 1
  [ "${rpath_zip:0:1}" = "/" ] || rpath_zip="/$rpath_zip"

  local zsize
  read -rp "  Tamaño que reporta el panel (MB, Enter para omitir): " zsize || true

  # Descarga con reanudación (un solo archivo: --continue sí funciona).
  local zlocal
  zlocal="$DEST/$(basename "$rpath_zip")"
  info "Descargando ${rpath_zip}…"
  build_auth_files
  if ! wget --continue --tries=5 --waitretry=10 --timeout=30 \
       --config="$WGETRC" -O "$zlocal" "ftp://${FTPHOST}${rpath_zip}" \
       --append-output="$LOG" -q; then
    wipe_auth_files
    warn "La descarga del zip falló."
    return 1
  fi
  wipe_auth_files

  # Verificación de tamaño contra lo declarado (si lo declaró).
  local got_b
  got_b=$(stat -c %s "$zlocal" 2>/dev/null || stat -f %z "$zlocal" 2>/dev/null || echo 0)
  if [ -n "$zsize" ] && [ "$zsize" -gt 0 ] 2>/dev/null; then
    local want_b=$((zsize * 1024 * 1024)) diff
    diff=$(( got_b > want_b ? got_b - want_b : want_b - got_b ))
    if [ "$diff" -gt $((want_b / 20)) ]; then   # >5% de desvío
      warn "Tamaño descargado ($(human "$got_b")) difiere del declarado (${zsize} MB)."
    fi
  fi

  # Blindaje zip-slip ANTES del CRC: rechazar entradas con .. o ruta absoluta.
  # Un zip creado en un origen quizá comprometido puede intentar escribir fuera
  # del directorio forense.
  if unzip -l "$zlocal" 2>/dev/null | awk 'NR>3 {print $4}' \
       | grep -qE '(^/|(^|/)\.\.(/|$))'; then
    warn "El zip contiene rutas absolutas o '..': posible zip-slip. Se descarta."
    rm -f "$zlocal"
    return 1
  fi

  # §4.7.6 — unzip -t obligatorio. CRC roto → descartar, no reparar.
  info "Verificando integridad (unzip -t)…"
  if ! unzip -tqq "$zlocal" >/dev/null 2>&1; then
    warn "CRC inválido: el zip llegó corrupto o la compresión se truncó."
    warn "Se descarta (no se intenta reparar) y se cae a archivo por archivo."
    rm -f "$zlocal"
    return 1
  fi
  ok "Zip íntegro ($(human "$got_b"))."

  # Descomprimir SIEMPRE a un subdirectorio nuevo (nunca al DEST directo).
  local exdir
  exdir="$DEST/zip-extract-$(date +%Y%m%d-%H%M)"
  mkdir -p "$exdir"
  info "Descomprimiendo en $(basename "$exdir")/…"
  if ! unzip -q "$zlocal" -d "$exdir"; then
    warn "La descompresión falló. El zip queda en disco como evidencia."
    return 1
  fi
  ok "Descomprimido."
  ZIP_EXTRACT_DIR="$exdir"

  # §4.7.7 ampliado — borrar el zip del origen: doble confirmación real
  # (la segunda tipea el nombre), y sólo con la copia verificada. DELE es la
  # única escritura permitida sobre el origen (desvío consciente de §8.4,
  # documentado: en caso limpio no hay evidencia que contaminar).
  printf '\n%s\n' "${C_B}── Limpieza del origen ────────────────────────────────${C_RESET}"
  info "A borrar   ftp://${FTPHOST}${rpath_zip}   ($(human "$got_b"))"
  printf '  %s\n' "${C_WARN}Esto ejecuta DELE por FTP sobre el servidor del cliente.${C_RESET}"
  printf '  %s\n' "${C_WARN}Es irreversible y el zip no está en la papelera de ningún lado.${C_RESET}"
  local a1 a2
  read -rp "  1/2 ¿Borrar el zip del origen? [s/N] " a1 || true
  case "$a1" in
    [sS]*)
      read -rp "  2/2 Escribí el nombre exacto del archivo para confirmar: " a2 || true
      if [ "$a2" = "$(basename "$rpath_zip")" ]; then
        build_auth_files
        if curl -s --connect-timeout 15 --max-time 30 -K "$CURLRC" \
             -Q "DELE $rpath_zip" "ftp://${FTPHOST}/" -o /dev/null 2>/dev/null; then
          # Verificar ausencia re-listando (no confiar en el exit code).
          if curl -s --connect-timeout 15 --max-time 30 -K "$CURLRC" --list-only \
               "ftp://${FTPHOST}$(dirname "$rpath_zip")/" 2>/dev/null \
               | grep -qxF "$(basename "$rpath_zip")"; then
            warn "El zip TODAVÍA aparece en el listado. Borralo a mano desde el panel."
          else
            event "DELE: zip borrado del origen, ausencia verificada por re-listado"
            ok "Zip borrado del origen (verificado por re-listado)."
            ZIP_DELETED_CONFIRMED=1
          fi
        else
          warn "DELE falló (¿cuenta sin permiso de borrado?). Borralo desde el panel."
        fi
        wipe_auth_files
      else
        warn "El nombre no coincide. No se borró nada."
      fi ;;
    *) : ;;
  esac
  if [ "$ZIP_DELETED_CONFIRMED" -ne 1 ]; then
    printf '  %s\n' "${C_ERR}▸ PENDIENTE: borrar ${rpath_zip} del origen desde el panel.${C_RESET}"
  fi
  return 0
}

# --------------------------------------------------------------- credenciales
AUTHDIR=""; WGETRC=""; CURLRC=""
build_auth_files() {
  local old_umask
  old_umask=$(umask); umask 077
  AUTHDIR=$(mktemp -d "${TMPDIR:-/tmp}/monoftp.XXXXXXXX")
  WGETRC="$AUTHDIR/wgetrc"; CURLRC="$AUTHDIR/curlrc"
  printf 'ftp_user = %s\nftp_password = %s\n' "$FTPUSER" "$FTPPASS" > "$WGETRC"
  printf 'user = "%s:%s"\n' "$FTPUSER" "$FTPPASS" > "$CURLRC"
  chmod 600 "$WGETRC" "$CURLRC"
  umask "$old_umask"
  return 0
}
wipe_auth_files() {
  [ -n "$AUTHDIR" ] || return 0
  [ -f "$WGETRC" ] && { shred -u "$WGETRC" 2>/dev/null || rm -f "$WGETRC"; }
  [ -f "$CURLRC" ] && { shred -u "$CURLRC" 2>/dev/null || rm -f "$CURLRC"; }
  rmdir "$AUTHDIR" 2>/dev/null || true
  AUTHDIR=""
  return 0
}
trap 'wipe_auth_files' EXIT

ask_credentials() {
  printf '%s\n' "${C_B}── Conexión de origen ─────────────────────────────────${C_RESET}"
  FTPHOST="${MONO_HOST:-}"
  while [ -z "$FTPHOST" ]; do read -rp "  Host o IP del FTP: " FTPHOST || die "Cancelado."; done

  # §6.2 — comprobación de Cloudflare ANTES de pedir credenciales: si el host
  # no puede conectar, no tiene sentido tipear la contraseña. Puede sustituir
  # FTPHOST por una alternativa resuelta, o cancelar.
  if cf_precheck "$FTPHOST"; then
    [ -n "$CF_NEW_HOST" ] && FTPHOST="$CF_NEW_HOST"
  else
    die "Cancelado: el host FTP no puede conectar (Cloudflare o sin resolver)."
  fi

  FTPUSER="${MONO_USER:-}"
  while [ -z "$FTPUSER" ]; do read -rp "  Usuario FTP: " FTPUSER || die "Cancelado."; done
  FTPPASS=""
  while [ -z "$FTPPASS" ]; do
    read -rsp "  Contraseña (no se muestra): " FTPPASS || die "Cancelado."; printf '\n'
    [ -z "$FTPPASS" ] && warn "Vacía. Reintenta."
  done
  printf '  %s\n' "${C_DIM}(${#FTPPASS} caracteres cargados)${C_RESET}"

  RPATH="${MONO_PATH:-}"
  if [ -z "$RPATH" ]; then
    read -rp "  Ruta remota [/public_html/]: " RPATH || true
    RPATH="${RPATH:-/public_html/}"
  fi
  [ "${RPATH:0:1}" = "/" ] || RPATH="/$RPATH"
  [ "${RPATH: -1}" = "/" ] || RPATH="$RPATH/"

  build_auth_files
  return 0
}

# --------------------------------------------------------------- alcance
# Nombres que pertenecen a una instalación estándar de WordPress.
WP_DIRS="wp-admin wp-includes wp-content"
wp_known_file() {
  case "$1" in
    wp-config.php|wp-config-sample.php|wp-load.php|wp-settings.php|wp-blog-header.php|\
    wp-cron.php|wp-login.php|wp-mail.php|wp-links-opml.php|wp-signup.php|wp-activate.php|\
    wp-trackback.php|wp-comments-post.php|xmlrpc.php|index.php|license.txt|readme.html|\
    .htaccess|.user.ini|robots.txt|favicon.ico) return 0 ;;
    *) return 1 ;;
  esac
}

REMOTE_ENTRIES=()   # "tipo|tamaño|nombre"
remote_list() {
  [ "$HAVE_CURL" -eq 1 ] || return 1
  local raw
  raw=$(curl -s --connect-timeout 20 --max-time 90 -K "$CURLRC" \
        --ftp-method nocwd "ftp://${FTPHOST}${RPATH}" 2>/dev/null) || return 1
  [ -n "$raw" ] || return 1
  REMOTE_ENTRIES=()
  while IFS= read -r line; do
    case "$line" in
      d*) local t="dir" ;;
      -*) local t="file" ;;
      *)  continue ;;
    esac
    local size name
    size=$(printf '%s' "$line" | awk '{print $5}')
    name=$(printf '%s' "$line" | awk '{ for (i=9; i<=NF; i++) printf "%s%s", $i, (i<NF ? " " : "") }')
    [ -z "$name" ] && continue
    case "$name" in .|..) continue ;; esac
    REMOTE_ENTRIES+=("$t|${size:-0}|$name")
  done <<< "$raw"
  [ "${#REMOTE_ENTRIES[@]}" -gt 0 ]
  return $?
}

choose_scope() {
  EXCLUDES="${MONO_EXCLUDES:-}"
  printf '\n%s\n' "${C_B}── Alcance de la migración ────────────────────────────${C_RESET}"

  if ! remote_list; then
    warn "No se pudo listar el remoto (curl no disponible o LIST rechazado)."
    info "Se continúa sin inventario previo."
    if [ -z "$EXCLUDES" ]; then
      printf '  %s\n' "${C_DIM}Excluir directorios (coma). Ej: /public_html/anterior${C_RESET}"
      read -rp "  Excluir [ninguno]: " EXCLUDES || true
    fi
    return 0
  fi

  local i=0 is_wp=0 non_wp=() e t s n mark
  printf '  %s\n' "${C_DIM}Contenido de ${RPATH}${C_RESET}"
  printf '  %-4s %-5s %-11s %-30s %s\n' "#" "Tipo" "Tamaño" "Nombre" "WordPress"
  for e in "${REMOTE_ENTRIES[@]}"; do
    i=$((i+1))
    IFS='|' read -r t s n <<< "$e" || true
    mark="${C_WARN}no${C_RESET}"
    if [ "$t" = "dir" ]; then
      case " $WP_DIRS " in *" $n "*) mark="${C_OK}sí${C_RESET}" ;; esac
    else
      if wp_known_file "$n"; then mark="${C_OK}sí${C_RESET}"; fi
    fi
    [ "$n" = "wp-includes" ] && is_wp=1
    if [ "$mark" != "${C_OK}sí${C_RESET}" ] && [ "$t" = "dir" ]; then non_wp+=("$n"); fi
    printf '  %-4s %-5s %-11s %-30s %b\n' "$i" "$t" \
      "$( if [ "$t" = dir ]; then printf '—'; else human "$s"; fi )" "$n" "$mark"
  done

  printf '\n'
  if [ "$is_wp" -eq 1 ]; then
    ok "Instalación de WordPress detectada en la raíz."
  else
    warn "No se ve wp-includes aquí. WordPress puede estar en un subdirectorio."
  fi
  if [ "${#non_wp[@]}" -gt 0 ]; then
    warn "Directorios ajenos a WordPress: ${non_wp[*]}"
    info "${C_DIM}Código fuera de WordPress en el docroot es superficie de ataque${C_RESET}"
    info "${C_DIM}y candidato a vector de entrada. No migrarlo no exime de analizarlo.${C_RESET}"
  fi

  printf '\n  %s\n' "${C_B}¿Qué se descarga?${C_RESET}"
  info "1) Todo el árbol remoto"
  info "2) Solo WordPress  ${C_DIM}(excluye lo ajeno: ${non_wp[*]:-nada})${C_RESET}"
  info "3) Personalizado   ${C_DIM}(eliges qué excluir por número)${C_RESET}"
  printf '\n'
  local opt; read -rp "  Opción [2]: " opt || true; opt="${opt:-2}"

  case "$opt" in
    1) EXCLUDES=""; SCOPE="todo" ;;
    2)
      SCOPE="wordpress"; EXCLUDES=""
      local d
      for d in "${non_wp[@]}"; do
        EXCLUDES="${EXCLUDES:+$EXCLUDES,}${RPATH}${d}"
      done
      ;;
    3)
      SCOPE="personalizado"
      printf '  %s\n' "${C_DIM}Números a EXCLUIR, separados por coma (Enter = no excluir nada)${C_RESET}"
      local sel idx
      read -rp "  Excluir #: " sel || true
      EXCLUDES=""
      IFS=',' read -ra idx <<< "${sel// /}" || true
      local k
      for k in "${idx[@]:-}"; do
        case "$k" in ''|*[!0-9]*) continue ;; esac
        [ "$k" -ge 1 ] && [ "$k" -le "${#REMOTE_ENTRIES[@]}" ] || continue
        IFS='|' read -r t s n <<< "${REMOTE_ENTRIES[$((k-1))]}" || true
        if [ "$t" = "dir" ]; then
          EXCLUDES="${EXCLUDES:+$EXCLUDES,}${RPATH}${n}"
        else
          warn "#$k ($n) es un archivo; --exclude-directories no aplica. Se omite."
        fi
      done
      ;;
    *) die "Opción inválida." ;;
  esac
  return 0
}

ask_expected() {
  EXPECT_MB="${MONO_EXPECT_MB:-}"
  if [ -z "$EXPECT_MB" ]; then
    printf '  %s\n' "${C_DIM}Tamaño esperado en MB, para un %% estable. Enter para omitir.${C_RESET}"
    read -rp "  Tamaño esperado (MB) [auto]: " EXPECT_MB || true
  fi
  case "$EXPECT_MB" in
    ''|*[!0-9]*) EXPECT_BYTES=0 ;;
    *)           EXPECT_BYTES=$((EXPECT_MB * 1024 * 1024)) ;;
  esac

  printf '\n%s\n' "${C_B}── Resumen ────────────────────────────────────────────${C_RESET}"
  info "Origen    ftp://${FTPHOST}${RPATH}"
  info "Usuario   ${FTPUSER}"
  info "Destino   ${DEST}"
  info "Alcance   ${SCOPE:-todo}"
  info "Excluye   ${EXCLUDES:-(nada)}"
  info "Escaneo   $( [ "$DO_SCAN" -eq 1 ] && printf 'sí, al terminar' || printf 'desactivado' )"
  printf '\n'
  local go; read -rp "  ¿Iniciar la descarga? [s/N] " go || true
  case "$go" in [sS]*) ;; *) die "Cancelado por el operador." ;; esac
  return 0
}

# --------------------------------------------------------------- lanzamiento
# Lanza (o relanza) wget. §5.4: regenera el wgetrc con umask 077 llamando a
# build_auth_files (NO se modifica esa función), arranca, y borra las
# credenciales de disco con shred a los 2 s vía wipe_auth_files. La contraseña
# vive en la variable de shell FTPPASS (no exportada) durante la sesión, salvo
# --no-auto-retry, que la borra tras cada lanzamiento y la vuelve a pedir.
# Devuelve 0 si wget quedó vivo tras 2 s.
launch_wget() {
  if [ -z "${FTPPASS:-}" ]; then
    while [ -z "${FTPPASS:-}" ]; do
      read -rsp "  Contraseña para continuar (no se muestra): " FTPPASS || return 1
      printf '\n'
    done
  fi
  wipe_auth_files          # limpiar cualquier auth previa (la de ask_credentials
                           # o la del relanzamiento anterior) antes de regenerar
  build_auth_files
  local args=(
    --mirror --no-host-directories --no-parent --inet4-only --passive-ftp
    --no-remove-listing --no-verbose --append-output="$LOG"
    --tries=5 --waitretry=10 --timeout=30 --config="$WGETRC"
  )
  [ -n "$EXCLUDES" ] && args+=( --exclude-directories="$EXCLUDES" )

  nohup wget "${args[@]}" "ftp://${FTPHOST}${RPATH}" >/dev/null 2>&1 &
  PID=$!
  echo "$PID" > "$PIDFILE"

  sleep 2
  wipe_auth_files                       # shred a los 2 s (nunca vuelve a disco)
  [ "$NO_AUTO_RETRY" -eq 1 ] && FTPPASS=""   # modo sin retención

  kill -0 "$PID" 2>/dev/null
}

start_mirror() {
  set_phase descarga
  if launch_wget; then
    event "descarga iniciada (PID $PID)"
    ok "Descarga iniciada (PID $PID). Credenciales temporales eliminadas."
    sleep 1
    return 0
  fi
  # wget no está vivo tras 2 s: puede ser un fallo inmediato, o un espejo chico
  # que terminó completo antes del sleep. Distinguir por el marcador de wget.
  if download_finished; then
    event "descarga iniciada y completada de inmediato (espejo pequeño)"
    ok "Descarga completada de inmediato (espejo pequeño)."
    return 0
  fi
  printf '\n%s\n' "${C_ERR}wget terminó de inmediato sin completar. Últimas líneas del log:${C_RESET}"
  tail -20 "$LOG" 2>/dev/null || true
  # No morir: monitor verá el proceso muerto, clasificará el log y correrá el
  # diagnóstico (escalera + informe) o parará según la clase.
  return 0
}

# --------------------------------------------------------------- métricas
LOGPOS=0; FILES=0; BYTES=0; ERRORS=0
DET_FILES=0; DET_BYTES=0
SP_MIN=0; SP_MAX=0; SP_NOW=0
PREV_BYTES=0; PREV_TS=0
LIVE_HITS=0

parse_new_log() {
  local size chunk nums nf nb ne
  size=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
  [ "$size" -le "$LOGPOS" ] && return 0
  chunk=$(tail -c "+$((LOGPOS + 1))" "$LOG" 2>/dev/null | head -c "$((size - LOGPOS))") || chunk=""
  LOGPOS=$size
  [ -z "$chunk" ] && return 0
  nums=$(printf '%s\n' "$chunk" | sed -n 's/.*\[\([0-9][0-9]*\)\] -> .*/\1/p' || true)
  if [ -n "$nums" ]; then
    read -r nf nb <<<"$(printf '%s\n' "$nums" | awk '{n++; b+=$1} END{printf "%d %d", n+0, b+0}')" || true
    nf=${nf:-0}; nb=${nb:-0}
    FILES=$((FILES + nf)); BYTES=$((BYTES + nb))
  fi
  ne=$(printf '%s\n' "$chunk" | grep -ciE 'error|failed|refused|timed out|no such file' || true)
  ERRORS=$((ERRORS + ${ne:-0}))
  return 0
}

count_detected() {
  local out
  out=$(find "$DEST" -name '.listing' -exec cat {} + 2>/dev/null \
        | awk '/^-/ {n++; b+=$5} END{printf "%d %d", n+0, b+0}' || printf '0 0')
  read -r DET_FILES DET_BYTES <<<"$out" || true
  DET_FILES=${DET_FILES:-0}; DET_BYTES=${DET_BYTES:-0}
  return 0
}

update_speed() {
  local now dt delta
  now=$(date +%s)
  if [ "$PREV_TS" -eq 0 ]; then PREV_TS=$now; PREV_BYTES=$BYTES; return 0; fi
  dt=$((now - PREV_TS)); [ "$dt" -le 0 ] && return 0
  delta=$((BYTES - PREV_BYTES))
  SP_NOW=$((delta / dt)); PREV_TS=$now; PREV_BYTES=$BYTES
  if [ "$SP_NOW" -gt 0 ]; then
    if [ "$SP_MAX" -eq 0 ] || [ "$SP_NOW" -gt "$SP_MAX" ]; then SP_MAX=$SP_NOW; fi
    if [ "$SP_MIN" -eq 0 ] || [ "$SP_NOW" -lt "$SP_MIN" ]; then SP_MIN=$SP_NOW; fi
  fi
  return 0
}

# Vigilancia en vivo: solo señales baratas y de alta confianza sobre lo que
# ya aterrizó. Lo caro (checksums, grep de contenido) va en el escaneo final.
WATCH_MARK=".mono-watch-mark"
live_watch() {
  local found newf
  if [ ! -e "$WATCH_MARK" ]; then : > "$WATCH_MARK"; return 0; fi
  found=0
  # 1. PHP dentro de uploads — nunca es legítimo
  newf=$(find "$DEST" -newer "$WATCH_MARK" -path '*/uploads/*' \
         \( -name '*.php' -o -name '*.phtml' -o -name '*.php[0-9]' \) 2>/dev/null || true)
  # 2. PHP oculto o con extensión de camuflaje
  newf="$newf"$'\n'$(find "$DEST" -newer "$WATCH_MARK" \
         \( -name '.*.php' -o -name '*.php.suspected' -o -name '*.ico.php' \
            -o -name '*.php.bak' -o -name '*.phar' \) 2>/dev/null || true)
  : > "$WATCH_MARK"
  newf=$(printf '%s\n' "$newf" | sed '/^[[:space:]]*$/d' || true)
  [ -z "$newf" ] && return 0
  found=$(printf '%s\n' "$newf" | wc -l)
  printf '%s\n' "$newf" >> "$ALERTS"
  LIVE_HITS=$((LIVE_HITS + found))
  return 0
}

bar() {
  local pct="$1" width=38 filled i out=""
  filled=$(( pct * width / 100 ))
  [ "$filled" -gt "$width" ] && filled=$width
  [ "$filled" -lt 0 ] && filled=0
  for ((i=0; i<filled; i++)); do out+="█"; done
  for ((i=filled; i<width; i++)); do out+="░"; done
  printf '%s' "$out"
}

# --------------------------------------------------------------- panel
# shellcheck disable=SC2059  # ${line}=\033[K va en el format string a propósito:
# tiene que interpretarse como escape ANSI de borrado de línea en cada printf.
render() {
  local elapsed avg target pct eta estado line
  elapsed=$(( $(date +%s) - START )); [ "$elapsed" -lt 1 ] && elapsed=1
  avg=$((BYTES / elapsed))
  if [ "$EXPECT_BYTES" -gt 0 ]; then target=$EXPECT_BYTES; else target=$DET_BYTES; fi
  if [ "$target" -gt 0 ]; then pct=$(( BYTES * 100 / target )); [ "$pct" -gt 100 ] && pct=100
  else pct=0; fi
  if [ "$avg" -gt 0 ] && [ "$target" -gt "$BYTES" ]; then
    eta=$(hms $(( (target - BYTES) / avg )))
  else eta="--:--:--"; fi
  if kill -0 "$PID" 2>/dev/null; then estado="${C_OK}● descargando${C_RESET}"
  else estado="${C_ACC}■ finalizado${C_RESET}"; fi

  write_status

  [ "$TTY" -eq 1 ] && printf '\033[H'
  line="\033[K"
  printf "${C_B}  mono-ftp-mirror v%s${C_RESET}${line}\n" "$VERSION"
  printf "  %s${line}\n" "$(phase_line "$pct")"
  printf "  ${C_DIM}%s${C_RESET}${line}\n" "────────────────────────────────────────────────────────"
  printf "  Origen     ${C_ACC}ftp://%s%s${C_RESET}${line}\n" "$FTPHOST" "$RPATH"
  printf "  Destino    %s${line}\n" "$DEST"
  printf "  Alcance    %-14s PID %-8s %b${line}\n" "${SCOPE:-todo}" "$PID" "$estado"
  printf "${line}\n"
  printf "  [%s] %3d %%${line}\n" "$(bar "$pct")" "$pct"
  printf "${line}\n"
  printf "  Archivos   ${C_B}%s${C_RESET} descargados  /  %s detectados${line}\n" \
         "$(thousands "$FILES")" "$(thousands "$DET_FILES")"
  printf "  Datos      ${C_B}%s${C_RESET}  /  %s%s${line}\n" \
         "$(human "$BYTES")" "$(human "$target")" \
         "$( [ "$EXPECT_BYTES" -gt 0 ] && printf ' (estimado)' || printf ' (detectado)' )"
  printf "${line}\n"
  printf "  Velocidad  actual %-12s promedio %s${line}\n" \
         "$(human_rate "$SP_NOW")" "$(human_rate "$avg")"
  printf "             mínima %-12s máxima   %s${line}\n" \
         "$(human_rate "$SP_MIN")" "$(human_rate "$SP_MAX")"
  printf "${line}\n"
  printf "  Tiempo     transcurrido %s     ETA %s${line}\n" "$(hms "$elapsed")" "$eta"
  if [ "$ERRORS" -gt 0 ]; then
    printf "  Errores    ${C_WARN}%s en el log${C_RESET}${line}\n" "$(thousands "$ERRORS")"
  else
    printf "  Errores    ${C_OK}0${C_RESET}${line}\n"
  fi
  if [ "$LIVE_HITS" -gt 0 ]; then
    printf "  Vigilancia ${C_ERR}%s archivo(s) sospechoso(s)${C_RESET} ${C_DIM}→ %s${C_RESET}${line}\n" \
           "$(thousands "$LIVE_HITS")" "$ALERTS"
  else
    printf "  Vigilancia ${C_OK}sin hallazgos${C_RESET}${line}\n"
  fi
  # §5 — estancamiento y reintentos.
  if [ "${STALLED:-0}" -eq 1 ]; then
    printf "  Conexión   ${C_WARN}⚠ sin avance${C_RESET}${line}\n"
  fi
  if [ "${RELAUNCHES:-0}" -gt 0 ]; then
    printf "  Reintentos ${C_WARN}%s/%s${C_RESET} ${C_DIM}· último %s${C_RESET}${line}\n" \
           "$RELAUNCHES" "$MAX_RELAUNCH" "${LAST_RELAUNCH_AT:-—}"
  fi
  printf "  ${C_DIM}%s${C_RESET}${line}\n" "────────────────────────────────────────────────────────"
  printf "  ${C_DIM}Ctrl-C cierra el panel; la descarga continúa.${C_RESET}${line}\n"
  [ "$TTY" -eq 1 ] && printf '\033[J'
  return 0
}

on_int() {
  trap - INT
  printf '\n\n'
  local a; read -rp "  ¿Detener también la descarga? [s/N] " a || a=""
  case "$a" in
    [sS]*)
      kill "$PID" 2>/dev/null || true; sleep 1; kill -9 "$PID" 2>/dev/null || true
      rm -f "$PIDFILE"
      warn "Descarga detenida. Relanza el script para reanudar." ;;
    *)
      ok "Panel cerrado. wget sigue corriendo en PID $PID."
      info "Reengancha con:  $0 --attach" ;;
  esac
  exit 0
}

# ¿wget terminó su recorrido? Marca el fin normal de --mirror en el log.
download_finished() {
  tail -15 "$LOG" 2>/dev/null | grep -qE 'FINISHED --|Downloaded: [0-9]' || return 1
}

# Watchdog §5.2: sin avance de bytes durante STALL_WARN → aviso; durante
# STALL_KILL con wget vivo → matar (el bucle lo relanza al verlo muerto).
watchdog_check() {
  local now idle
  now=$(date +%s)
  if [ "$BYTES" -gt "${LAST_PROGRESS_BYTES:-0}" ]; then
    LAST_PROGRESS_BYTES="$BYTES"; LAST_PROGRESS_TS="$now"; STALLED=0
    return 0
  fi
  idle=$(( now - ${LAST_PROGRESS_TS:-$now} ))
  if [ "$idle" -ge "$STALL_KILL" ] && kill -0 "$PID" 2>/dev/null; then
    event "watchdog: ${idle}s sin avance — mato wget (PID $PID) para relanzar"
    kill "$PID" 2>/dev/null || true; sleep 1; kill -9 "$PID" 2>/dev/null || true
    STALLED=1
  elif [ "$idle" -ge "$STALL_WARN" ]; then
    STALLED=1
  fi
  return 0
}

# Decide y ejecuta un relanzamiento (§5.3/§7.4). Devuelve 0 si relanzó, 1 si
# hay que rendirse (clase no reintentable o presupuesto agotado). Deja el motivo
# del abandono en GIVE_UP_CLASS.
maybe_relaunch() {
  local reason="$1" retry b i x
  classify_log "$LOG"
  retry=$(class_retryable "${DOMINANT_CLASS:-}")
  if [ "$retry" = "no" ]; then
    GIVE_UP_CLASS="clase no reintentable (${DOMINANT_CLASS})"
    return 1
  fi
  if [ "$RELAUNCHES" -ge "$MAX_RELAUNCH" ]; then
    GIVE_UP_CLASS="presupuesto de reintentos agotado (${MAX_RELAUNCH})"
    return 1
  fi
  # Backoff por número de relanzamiento; LIMITE_CONEXIONES fuerza ≥120 s.
  i=0; b=300
  for x in $BACKOFF_SEQ; do [ "$i" -eq "$RELAUNCHES" ] && { b=$x; break; }; i=$((i+1)); done
  [ "$retry" = "si-largo" ] && [ "$b" -lt 120 ] && b=120

  render                                  # que el panel muestre el estado antes de esperar
  sleep "$b"
  launch_wget || true
  RELAUNCHES=$((RELAUNCHES+1))
  LAST_RELAUNCH_AT="$(date +%H:%M)"
  event "reintento ${RELAUNCHES}/${MAX_RELAUNCH} · ${reason} · clase ${DOMINANT_CLASS:-?} · backoff ${b}s"
  RETRY_LOG="${RETRY_LOG}Reintento ${RELAUNCHES}/${MAX_RELAUNCH} · ${LAST_RELAUNCH_AT} · ${reason} · clase ${DOMINANT_CLASS} · backoff ${b}s"$'\n'
  return 0
}

# Al rendirse: escalera de diagnóstico (§7.3) + informe (§7.6) + pantalla corta.
diag_give_up() {
  event "me detengo: ${GIVE_UP_CLASS} · clase ${DOMINANT_CLASS:-?}"
  printf '\n'; warn "Me detengo: ${GIVE_UP_CLASS}."
  local curlrc_arg=""
  if [ -n "${FTPPASS:-}" ]; then build_auth_files; curlrc_arg="$CURLRC"; fi
  diagnostic_ladder "$FTPHOST" "$curlrc_arg" "$RPATH" "$DEST"
  [ -n "${FTPPASS:-}" ] && wipe_auth_files
  classify_log "$LOG"
  write_failure_report "$LOG" "$RELAUNCHES" "$RETRY_LOG"

  printf '\n%s\n' "${C_B}── Diagnóstico ────────────────────────────────────────${C_RESET}"
  printf '%s' "$LADDER_OUT"
  printf '\n  ▸ %s\n' "$(ladder_diagnosis)"
  printf '  Clase:  %s\n' "${DOMINANT_CLASS:-?}"
  printf '  Acción: %s\n' "$(class_action "${DOMINANT_CLASS:-}")"
  printf '  Informe de fallo: %s\n' "${C_ACC}$(basename "$FAILURE_REPORT")${C_RESET}"
  return 0
}

monitor() {
  START=$(date +%s)
  [ "$TTY" -eq 1 ] && printf '\033[2J'
  trap on_int INT
  local cycle=0
  LAST_PROGRESS_TS=$(date +%s); LAST_PROGRESS_BYTES=0
  RELAUNCHES=0; RETRY_LOG=""; STALLED=0; GIVE_UP_CLASS=""; LAST_RELAUNCH_AT=""
  while :; do
    parse_new_log
    [ $((cycle % LISTING_EVERY)) -eq 0 ] && count_detected
    [ $((cycle % WATCH_EVERY)) -eq 0 ] && live_watch
    update_speed
    watchdog_check
    render
    # §4 — checkpoint de estrategia: una sola vez, con avance real suficiente.
    if [ "$STRATEGY_DONE" -eq 0 ] && [ $(( $(date +%s) - START )) -ge "$CALIBRATE_AT" ]; then
      strategy_checkpoint
      [ "$ZIP_COMPLETED" -eq 1 ] && break
      LAST_PROGRESS_TS=$(date +%s)          # el checkpoint pausó; resetear watchdog
    fi
    if ! kill -0 "$PID" 2>/dev/null; then
      parse_new_log
      if download_finished; then
        event "descarga completa: $(thousands "$FILES") archivos, $(human "$BYTES")"
        break                              # terminó su recorrido
      fi
      # Murió con el árbol incompleto: relanzar (gobernado por clase/presupuesto).
      if maybe_relaunch "wget terminó incompleto"; then
        LAST_PROGRESS_TS=$(date +%s)        # resetear watchdog tras relanzar
        cycle=$((cycle + 1)); continue
      fi
      break                                 # no reintentable o presupuesto agotado
    fi
    cycle=$((cycle + 1))
    sleep "$REFRESH"
  done
  trap - INT
  parse_new_log; count_detected; live_watch; render
  printf '\n'
  [ -n "$GIVE_UP_CLASS" ] && diag_give_up
  return 0
}


# --------------------------------------------------------------- diagnóstico §7
#
# Reemplaza el contador único de errores por clasificación por firma (§7.2),
# una escalera de diagnóstico activa (§7.3), política de reintento por clase
# (§7.4), reconciliación de faltantes (§7.5) e informe de fallo (§7.6).

# ── §7.2 Clasificación por firma ──────────────────────────────────────────────
# Clasifica UNA línea de log contra la tabla, en orden: la primera que coincide
# gana. Imprime la clase, o nada si la línea no es un error reconocible.
classify_line() {
  local l="$1"
  case "$l" in
    # wget con --no-verbose omite el código 530: queda "Login incorrect." a
    # secas. Las cadenas son inequívocas por sí solas (solo aparecen en fallo
    # de login), así que no se exige el 530.
    *"Login incorrect"*|*"Login authentication failed"*|*"Login failed"*)        echo AUTH ;;
    *"530"*"uthentication failed"*|*"530"*"annot log in"*|*"530 User cannot"*)   echo AUTH ;;
    *"534"*|*"Policy requires SSL"*|*"SSL/TLS required"*)                          echo FTPS_OBLIGATORIO ;;
    *"No space left on device"*|*"Disk quota exceeded"*|*"Write failed"*)          echo DISCO_DESTINO ;;
    *"421 Too many"*|*"maximum number of clients"*|*"530 Sorry, the maximum"*)     echo LIMITE_CONEXIONES ;;
    *"Connection refused"*)                                                        echo SERVICIO_CAIDO ;;
    *"Cannot initiate PASV"*|*"Invalid PASV"*|*"cannot bind"*)                      echo PASV_BLOQUEADO ;;
    *"Temporary failure in name resolution"*|*"unable to resolve"*)                echo DNS_DESTINO ;;
    *"Connection timed out"*|*"Read error"*|*"Data connection timed out"*)          echo TIMEOUT ;;
    *"550 No such file or directory"*)                                             echo RUTA_INEXISTENTE ;;
    *"550 Permission denied"*|*"550 Failed to open file"*)                         echo PERMISO_ARCHIVO ;;
    *) : ;;
  esac
  return 0
}
# NOTA de orden: las firmas no se solapan entre sí (un "550 No such" no matchea
# "Permission denied" ni al revés; "timed out" no matchea "refused"), así que
# reordenar respecto de la tabla del HANDOFF no cambia ninguna clasificación.
# La ambigüedad real es 550-no-such sobre la RUTA BASE vs sobre un ARCHIVO
# suelto: la firma sola no lo distingue. Acá "550 No such" => RUTA_INEXISTENTE;
# el peldaño 5 de la escalera (§7.3) confirma si de verdad falta la ruta base.

# ¿La clase es reintentable? Imprime "no" | "si" | "si-largo" (backoff largo).
class_retryable() {
  case "$1" in
    AUTH|FTPS_OBLIGATORIO|RUTA_INEXISTENTE|DISCO_DESTINO|BLOQUEO_PROBABLE) echo no ;;
    LIMITE_CONEXIONES)                                                     echo si-largo ;;
    PERMISO_ARCHIVO)                                                       echo por-archivo ;;
    SERVICIO_CAIDO|DNS_DESTINO|PASV_BLOQUEADO|TIMEOUT)                     echo si ;;
    *)                                                                     echo si ;;
  esac
  return 0
}

# Cuenta un log completo por clase y detecta el patrón BLOQUEO_PROBABLE:
# hubo descargas exitosas y a partir de cierto punto TODO pasa a TIMEOUT sin
# más éxitos (baneo de IP por antifuerza-bruta). Deja el resultado en:
#   CLASS_COUNTS  (assoc: clase -> n)   · requiere bash 4; con bash 3 usamos
#                                         variables planas CC_<CLASE>.
#   DOMINANT_CLASS  la clase con más peso para decidir la acción
#   BLOCK_DETECTED  1 si patrón de baneo
classify_log() {
  local logf="$1"
  local n_auth=0 n_ftps=0 n_ruta=0 n_disco=0 n_limite=0 n_caido=0 n_pasv=0 \
        n_dns=0 n_perm=0 n_timeout=0
  # timeouts_run = racha de timeouts desde el último éxito (cada éxito la
  # resetea). Al terminar el log, si hubo algún éxito y la racha final es ≥3,
  # es el patrón de baneo.
  local succ_total=0 timeouts_run=0 had_success=0 line cls
  BLOCK_DETECTED=0

  while IFS= read -r line; do
    # ¿Éxito de descarga? (RETR completado: `[bytes] -> "..."`)
    case "$line" in
      *'] -> '*|*' saved ['*)
        succ_total=$((succ_total+1)); had_success=1
        timeouts_run=0
        continue ;;
    esac
    cls=$(classify_line "$line")
    [ -z "$cls" ] && continue
    case "$cls" in
      AUTH)              n_auth=$((n_auth+1)) ;;
      FTPS_OBLIGATORIO)  n_ftps=$((n_ftps+1)) ;;
      RUTA_INEXISTENTE)  n_ruta=$((n_ruta+1)) ;;
      DISCO_DESTINO)     n_disco=$((n_disco+1)) ;;
      LIMITE_CONEXIONES) n_limite=$((n_limite+1)) ;;
      SERVICIO_CAIDO)    n_caido=$((n_caido+1)) ;;
      PASV_BLOQUEADO)    n_pasv=$((n_pasv+1)) ;;
      DNS_DESTINO)       n_dns=$((n_dns+1)) ;;
      PERMISO_ARCHIVO)   n_perm=$((n_perm+1)) ;;
      TIMEOUT)
        n_timeout=$((n_timeout+1))
        timeouts_run=$((timeouts_run+1))
        ;;
    esac
  done < "$logf"

  # Exponer contadores como variables planas (compatibles con bash 3).
  CC_AUTH=$n_auth; CC_FTPS_OBLIGATORIO=$n_ftps; CC_RUTA_INEXISTENTE=$n_ruta
  CC_DISCO_DESTINO=$n_disco; CC_LIMITE_CONEXIONES=$n_limite; CC_SERVICIO_CAIDO=$n_caido
  CC_PASV_BLOQUEADO=$n_pasv; CC_DNS_DESTINO=$n_dns; CC_PERMISO_ARCHIVO=$n_perm
  CC_TIMEOUT=$n_timeout

  # BLOQUEO_PROBABLE: hubo éxitos, y hay una racha final de timeouts sin ningún
  # éxito posterior. Umbral: al menos 3 timeouts consecutivos tras el último
  # éxito. (§7.2 caso especial.)
  if [ "$had_success" -eq 1 ] && [ "$timeouts_run" -ge 3 ]; then
    BLOCK_DETECTED=1
  fi

  # Clase dominante para decidir la acción: las no-reintentables mandan; entre
  # ellas, prioridad AUTH > FTPS > DISCO > RUTA. Si no hay no-reintentables,
  # gana la de mayor conteo entre las reintentables.
  DOMINANT_CLASS=""
  if [ "$BLOCK_DETECTED" -eq 1 ]; then DOMINANT_CLASS="BLOQUEO_PROBABLE"
  elif [ "$n_auth"   -gt 0 ]; then DOMINANT_CLASS="AUTH"
  elif [ "$n_ftps"   -gt 0 ]; then DOMINANT_CLASS="FTPS_OBLIGATORIO"
  elif [ "$n_disco"  -gt 0 ]; then DOMINANT_CLASS="DISCO_DESTINO"
  elif [ "$n_ruta"   -gt 0 ]; then DOMINANT_CLASS="RUTA_INEXISTENTE"
  elif [ "$n_limite" -gt 0 ]; then DOMINANT_CLASS="LIMITE_CONEXIONES"
  elif [ "$n_pasv"   -gt 0 ]; then DOMINANT_CLASS="PASV_BLOQUEADO"
  elif [ "$n_dns"    -gt 0 ]; then DOMINANT_CLASS="DNS_DESTINO"
  elif [ "$n_caido"  -gt 0 ]; then DOMINANT_CLASS="SERVICIO_CAIDO"
  elif [ "$n_timeout" -gt 0 ]; then DOMINANT_CLASS="TIMEOUT"
  elif [ "$n_perm"   -gt 0 ]; then DOMINANT_CLASS="PERMISO_ARCHIVO"
  fi
  return 0
}

# Mensaje-acción por clase (§7.3/§7.4: cada diagnóstico termina en una acción).
class_action() {
  case "$1" in
    AUTH)              echo "Credenciales incorrectas o cuenta deshabilitada. No se reintenta: reintentar dispara la protección antifuerza-bruta del hosting. Verificá usuario y contraseña en el panel." ;;
    FTPS_OBLIGATORIO)  echo "El servidor exige FTPS explícito y wget no lo hace. Usá un cliente con FTPS (lftp/curl) o pedí al hosting habilitar FTP simple para la migración." ;;
    RUTA_INEXISTENTE)  echo "La ruta base remota no existe. Revisá la ruta (¿/public_html/? ¿/htdocs/?) en el panel del hosting." ;;
    DISCO_DESTINO)     echo "Sin espacio en el destino. Liberá espacio en el nodo antes de reintentar." ;;
    LIMITE_CONEXIONES) echo "El origen limita conexiones simultáneas. Backoff largo y una sola conexión; reintenta solo." ;;
    SERVICIO_CAIDO)    echo "El servicio FTP rechazó la conexión (puerto cerrado o caído). Reintento con backoff; si persiste, avisá al hosting." ;;
    PASV_BLOQUEADO)    echo "Modo pasivo bloqueado: el control conecta, los datos no. Probá modo activo o revisá los puertos altos de salida del nodo." ;;
    DNS_DESTINO)       echo "Fallo temporal de resolución. Reintento con backoff; si persiste, revisá el DNS del nodo." ;;
    PERMISO_ARCHIVO)   echo "Archivo puntual sin permiso de lectura. El espejo sigue; el archivo queda en la reconciliación." ;;
    TIMEOUT)           echo "La conexión se pierde (firewall que descarta, baneo, o proxy). Reintento con backoff; ver la escalera de diagnóstico." ;;
    BLOQUEO_PROBABLE)  echo "El origen probablemente baneó la IP del nodo por antifuerza-bruta (hubo éxitos y luego solo timeouts). Suele levantarse solo en 15–60 min. NO se reintenta: insistir extiende el baneo." ;;
    *)                 echo "Sin clasificación clara. Revisá el log crudo y la escalera de diagnóstico." ;;
  esac
  return 0
}

# ── §7.5 Reconciliación: qué archivos faltan ──────────────────────────────────
# Construye el conjunto esperado desde los .listing y lo compara contra el disco.
#   - Sólo líneas de archivo (empiezan en '-'). 'd' (dir) y 'l' (symlink) NO
#     cuentan como faltantes: wget sobre FTP no siempre baja symlinks.
#   - Compara tamaño: presente pero de tamaño distinto = truncado (peor que
#     ausente, pasa desapercibido).
#   - Descuenta lo excluido por --exclude-directories.
#   - ADICIÓN sobre §7.5: detecta directorios ('d' en un .listing) cuyo
#     subdirectorio local no tiene .listing → "sin listar". Es el hueco
#     silencioso: si wget murió temprano, un árbol a medias se vería "completo"
#     porque esos directorios nunca generaron esperado. Sin esto, el
#     "Reconciliación completa" sería una afirmación insostenible.
#
# Args: reconcile <root> [excludes_csv]
# Deja: REC_EXPECTED REC_PRESENT REC_MISSING REC_TRUNC REC_UNLISTED
#       y escribe faltantes-<stamp>.txt si hay algo. Devuelve 0 si completo.
reconcile() {
  local root="$1" excludes="${2:-}"
  REC_EXPECTED=0; REC_PRESENT=0; REC_MISSING=0; REC_TRUNC=0; REC_UNLISTED=0
  local stamp; stamp=$(date +%Y%m%d-%H%M 2>/dev/null || echo now)
  local missfile="$DEST/faltantes-${stamp}.txt"
  local tmp; tmp=$(mktemp)

  # Normalizar excludes a rutas absolutas bajo $root para el prefijo.
  # (wget usa rutas remotas tipo /public_html/x; acá comparamos por sufijo.)
  # Sin process substitution (/dev/fd no disponible en contenedores de sitios).
  local _lst; _lst=$(mktemp)
  find "$root" -name '.listing' 2>/dev/null > "$_lst" || true
  local listing dir rel line perm name size local_f
  while IFS= read -r listing; do
    dir=$(dirname "$listing")
    # ¿Este directorio está bajo un excluido? Si sí, saltar entero.
    if [ -n "$excludes" ] && rec_is_excluded "$dir" "$root" "$excludes"; then
      continue
    fi
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      perm="${line:0:1}"
      case "$perm" in
        -) : ;;                       # archivo: se evalúa
        d)                            # directorio: ¿tiene .listing local?
          name=$(rec_name "$line")
          [ -z "$name" ] && continue
          case "$name" in .|..) continue ;; esac
          if [ ! -f "$dir/$name/.listing" ] && [ -d "$dir/$name" ]; then
            :  # existe el dir pero sin listing: puede ser hoja vacía, no alarmar
          elif [ ! -e "$dir/$name" ]; then
            # el .listing anuncia un subdir que no está en disco: sin listar
            echo "SINLISTAR|${dir#"$root"/}/$name" >> "$tmp"
            REC_UNLISTED=$((REC_UNLISTED+1))
          fi
          continue ;;
        *) continue ;;                # symlink u otro: no cuenta
      esac
      name=$(rec_name "$line")
      [ -z "$name" ] && continue
      case "$name" in .|..|.listing) continue ;; esac
      size=$(echo "$line" | awk '{print $5}')
      REC_EXPECTED=$((REC_EXPECTED+1))
      local_f="$dir/$name"
      if [ ! -e "$local_f" ]; then
        echo "AUSENTE|${local_f#"$root"/}" >> "$tmp"
        REC_MISSING=$((REC_MISSING+1))
      else
        REC_PRESENT=$((REC_PRESENT+1))
        # Tamaño en disco (GNU stat -c / BSD stat -f).
        local dsize
        dsize=$(stat -c %s "$local_f" 2>/dev/null || stat -f %z "$local_f" 2>/dev/null || echo -1)
        if [ "$dsize" -ge 0 ] && [ -n "$size" ] && [ "$size" -ge 0 ] 2>/dev/null; then
          if [ "$dsize" -ne "$size" ]; then
            echo "TRUNCADO|${local_f#"$root"/}|esperado=$size|disco=$dsize" >> "$tmp"
            REC_TRUNC=$((REC_TRUNC+1))
          fi
        fi
      fi
    done < "$listing"
  done < "$_lst"

  if [ -s "$tmp" ]; then
    { echo "mono-ftp-mirror v$VERSION — reconciliación $stamp"
      echo "Árbol: $root"
      echo "Esperados=$REC_EXPECTED presentes=$REC_PRESENT ausentes=$REC_MISSING truncados=$REC_TRUNC sin-listar=$REC_UNLISTED"
      echo ""
      sort "$tmp"
    } > "$missfile"
  fi
  rm -f "$tmp" "$_lst"

  [ "$REC_MISSING" -eq 0 ] && [ "$REC_TRUNC" -eq 0 ] && [ "$REC_UNLISTED" -eq 0 ]
}

# Nombre de archivo desde una línea de ls -l (campo 9 en adelante, corta " -> ").
rec_name() {
  # tr -d '\r': los .listing reales de FTP vienen con CRLF; sin esto el nombre
  # queda "f.txt\r" y todo aparece como ausente.
  echo "$1" | tr -d '\r' \
    | awk '{ for(i=9;i<=NF;i++){ if($i=="->") break; printf "%s%s", (i>9?" ":""), $i } }'
}

# ¿Está $dir bajo alguno de los directorios excluidos (csv de rutas remotas)?
rec_is_excluded() {
  local dir="$1" root="$2" excludes="$3" e rel remote
  # Los excludes son rutas remotas estilo wget (p.ej. /public_html/anterior).
  # El árbol local $root corresponde a RPATH remoto, así que reconstruimos la
  # ruta remota del dir: RPATH + (dir relativo a root). Sin RPATH, cae a "/".
  rel="${dir#"$root"}"; rel="${rel#/}"          # dir relativo a root, sin / inicial
  remote="${RPATH:-/}"; remote="${remote%/}/$rel"; remote="${remote%/}"
  [ -z "$remote" ] && remote="/"
  IFS=',' read -ra _ex <<< "$excludes"
  for e in "${_ex[@]}"; do
    [ -n "$e" ] || continue
    e="${e%/}"
    case "$remote/" in "$e/"*) return 0 ;; esac   # remote == e o está debajo
  done
  return 1
}

# ── §7.3 Escalera de diagnóstico ──────────────────────────────────────────────
# Prueba activa, capa por capa, hasta el peldaño que falla. Cada peldaño aísla
# UNA cosa. Reusa resolve_host/ip_in_cf de §6. Escribe el resultado en
# LADDER_OUT (texto) y deja LADDER_FAIL con el # del peldaño que falló (0=todo ok).
# Args: diagnostic_ladder <host> <curlrc> <rpath> <dest>
diagnostic_ladder() {
  local host="$1" curlrc="$2" rpath="$3" dest="$4"
  LADDER_OUT=""; LADDER_FAIL=0
  local ips ip cfhit=""

  _rung() { LADDER_OUT="${LADDER_OUT}$(printf '  %s %d. %-26s %s\n' "$1" "$2" "$3" "$4")"$'\n'; }

  # 1 — Resolución DNS
  ips=$(resolve_host "$host")
  if [ -z "$ips" ]; then
    case "$host" in *[!0-9.]*) _rung "✗" 1 "Resolución DNS" "no resuelve"; LADDER_FAIL=1; return 0 ;; esac
    ips="$host"   # IP literal
  fi
  _rung "✓" 1 "Resolución DNS" "$(printf '%s' "$ips" | tr '\n' ' ')"

  # 2 — Rangos de Cloudflare
  [ -n "$CF_RANGES" ] || cf_load_ranges
  while IFS= read -r ip; do [ -n "$ip" ] && ip_in_cf "$ip" && { cfhit="$ip"; break; }; done <<< "$ips"
  if [ -n "$cfhit" ]; then
    _rung "✗" 2 "Fuera de Cloudflare" "$cfhit es rango CF — el puerto 21 no llega"
    LADDER_FAIL=2; return 0
  fi
  _rung "✓" 2 "Fuera de Cloudflare" ""

  # 3 — TCP al puerto 21 (si hay /dev/tcp). §3.5: sin él, peldaño omitido.
  if _have_devtcp; then
    if timeout 8 bash -c "cat < /dev/null > /dev/tcp/${host}/21" 2>/dev/null; then
      _rung "✓" 3 "TCP 21 alcanzable" ""
    else
      _rung "✗" 3 "TCP 21 alcanzable" "puerto cerrado, firewall, o baneo de IP"
      LADDER_FAIL=3; return 0
    fi
  else
    _rung "○" 3 "TCP 21 (omitido)" "sin /dev/tcp en este bash"
  fi

  # 4 — Login sin transferencia (curl --list-only sobre la raíz)
  if [ -n "$curlrc" ] && command -v curl >/dev/null 2>&1; then
    if curl -s --connect-timeout 15 --max-time 40 -K "$curlrc" --list-only \
         "ftp://${host}/" >/dev/null 2>&1; then
      _rung "✓" 4 "Login aceptado" ""
    else
      _rung "✗" 4 "Login aceptado" "credenciales o cuenta suspendida"
      LADDER_FAIL=4; return 0
    fi
  else
    _rung "○" 4 "Login (omitido)" "sin curl o sin curlrc"
  fi

  # 5 — LIST de la ruta base
  if [ -n "$curlrc" ] && command -v curl >/dev/null 2>&1; then
    if curl -s --connect-timeout 15 --max-time 60 -K "$curlrc" --list-only \
         "ftp://${host}${rpath}" >/dev/null 2>&1; then
      _rung "✓" 5 "LIST de la ruta base" "$rpath"
    else
      _rung "✗" 5 "LIST de la ruta base" "ruta inexistente o sin permiso de lectura"
      LADDER_FAIL=5; return 0
    fi
  else
    _rung "○" 5 "LIST (omitido)" "sin curl o sin curlrc"
  fi

  # 6 — RETR de un archivo pequeño conocido (canal de datos / PASV)
  if [ -n "$curlrc" ] && command -v curl >/dev/null 2>&1; then
    local small
    small=$(curl -s --connect-timeout 15 --max-time 60 -K "$curlrc" \
            "ftp://${host}${rpath}" 2>/dev/null | awk '/^-/{print $NF; exit}')
    if [ -n "$small" ]; then
      if timeout 40 curl -s --connect-timeout 15 -K "$curlrc" \
           "ftp://${host}${rpath}${small}" >/dev/null 2>&1; then
        _rung "✓" 6 "RETR de archivo" "$small"
      else
        _rung "✗" 6 "RETR de archivo" "timeout: canal de datos / modo pasivo bloqueado"
        LADDER_FAIL=6; return 0
      fi
    else
      _rung "○" 6 "RETR (omitido)" "no hallé un archivo para probar"
    fi
  else
    _rung "○" 6 "RETR (omitido)" "sin curl o sin curlrc"
  fi

  # 7 — Espacio y escritura en el destino
  local avail
  avail=$(df -Pk "$dest" 2>/dev/null | awk 'NR==2{print $4}')
  if [ -w "$dest" ] && [ "${avail:-0}" -gt 0 ]; then
    _rung "✓" 7 "Espacio en destino" "$(human $((avail*1024))) libres"
  else
    _rung "✗" 7 "Espacio en destino" "sin espacio o sin permiso de escritura"
    LADDER_FAIL=7; return 0
  fi
  return 0
}

_have_devtcp() { (exec 3<>/dev/tcp/127.0.0.1/1 ) 2>/dev/null; local r=$?; exec 3>&- 2>/dev/null || true; [ "$r" -eq 0 ] || [ "$r" -eq 1 ]; }
# /dev/tcp existe si el intento no da "no such file" (r=1 conn refused = existe).

# Diagnóstico legible del peldaño que falló.
ladder_diagnosis() {
  case "$LADDER_FAIL" in
    0) echo "Todos los peldaños pasan: el problema no está en la conectividad básica. Revisá el log crudo y los contadores por clase." ;;
    1) echo "DNS del destino: el host no resuelve. ¿Nombre correcto? ¿El dominio todavía apunta a algún lado?" ;;
    2) echo "Proxy de Cloudflare interceptando el host FTP. Usá la IP de origen del panel (§6)." ;;
    3) echo "Puerto 21 inalcanzable: cerrado, firewall, o baneo de la IP del nodo." ;;
    4) echo "Login rechazado: credenciales incorrectas o cuenta suspendida." ;;
    5) echo "La ruta base no existe o no tiene permiso de lectura." ;;
    6) echo "Control OK, datos no: modo pasivo bloqueado. El origen anuncia un puerto alto no alcanzable desde acá. Probá modo activo, o revisá la salida de puertos altos del nodo." ;;
    7) echo "Disco del destino: sin espacio o sin permiso de escritura." ;;
  esac
  return 0
}

# ── §7.6 Informe de fallo ─────────────────────────────────────────────────────
# Escribe fallo-<stamp>.txt legible por un técnico de soporte del hosting que no
# conoce la herramienta. En pantalla, la versión corta.
write_failure_report() {
  local logf="$1" retries="${2:-0}" retry_log="${3:-}"
  local stamp; stamp=$(date +%Y%m%d-%H%M 2>/dev/null || echo now)
  local out="$DEST/fallo-${stamp}.txt"

  {
    echo "mono-ftp-mirror v$VERSION — informe de fallo"
    echo "Fecha: $(date -Is 2>/dev/null || date)"
    echo "Origen: ftp://${FTPHOST:-?}${RPATH:-}"
    echo ""
    echo "Este informe describe por qué falló una descarga por FTP. Está pensado"
    echo "para un técnico de soporte del hosting: no hace falta conocer la"
    echo "herramienta para leerlo."
    echo ""
    echo "══ 1. Clasificación del fallo ══"
    echo "Clase dominante: ${DOMINANT_CLASS:-(sin clasificar)}"
    echo "Razonamiento: la clase sale de las firmas encontradas en el log (abajo)."
    [ "${BLOCK_DETECTED:-0}" -eq 1 ] && \
      echo "Patrón de baneo: hubo descargas exitosas y luego sólo timeouts consecutivos."
    echo ""
    echo "══ 2. Escalera de diagnóstico ══"
    printf '%s' "${LADDER_OUT:-  (no ejecutada)}"
    echo ""
    echo "  ▸ $(ladder_diagnosis)"
    echo ""
    echo "══ 3. Contadores por clase ══"
    printf '  %-20s %s\n' AUTH "${CC_AUTH:-0}" FTPS_OBLIGATORIO "${CC_FTPS_OBLIGATORIO:-0}" \
      RUTA_INEXISTENTE "${CC_RUTA_INEXISTENTE:-0}" DISCO_DESTINO "${CC_DISCO_DESTINO:-0}" \
      LIMITE_CONEXIONES "${CC_LIMITE_CONEXIONES:-0}" SERVICIO_CAIDO "${CC_SERVICIO_CAIDO:-0}" \
      PASV_BLOQUEADO "${CC_PASV_BLOQUEADO:-0}" DNS_DESTINO "${CC_DNS_DESTINO:-0}" \
      PERMISO_ARCHIVO "${CC_PERMISO_ARCHIVO:-0}" TIMEOUT "${CC_TIMEOUT:-0}"
    echo ""
    echo "══ 4. Últimas 50 líneas del log ══"
    tail -50 "$logf" 2>/dev/null || echo "  (sin log)"
    echo ""
    echo "══ 5. Reintentos ══"
    echo "Total: $retries"
    [ -n "$retry_log" ] && printf '%s\n' "$retry_log"
    echo ""
    echo "══ 6. Acción recomendada ══"
    echo "  $(class_action "${DOMINANT_CLASS:-}")"
  } > "$out"

  # shellcheck disable=SC2034  # lo consume close_out para conservar/mencionar el informe
  FAILURE_REPORT="$out"
  return 0
}

# --------------------------------------------------------------- escáner
#
# Primera capa de detección — NO es un antivirus. Dos niveles:
#   CRÍTICO   evidencia, no sospecha. Si aparece uno, el árbol no se despliega.
#   REVISAR   necesita ojo humano antes de decidir.
# Alta señal, bajo ruido: ante la duda entre reportar o callar, se calla.
REPORT=""
CRIT=0; REVIEW=0

rep() { printf '%s\n' "$*" >> "$REPORT"; }

# nivel(CRITICO|REVISAR) | motivo | ruta
finding() {
  local lvl="$1" why="$2" path="$3" rel
  # SC2295: $DEST literal, no patrón, al recortar el prefijo de la ruta.
  rel="${path#"$DEST"/}"
  rep "[$lvl] $why :: $rel"
  case "$lvl" in
    CRITICO) CRIT=$((CRIT+1)) ;;
    REVISAR) REVIEW=$((REVIEW+1)) ;;
  esac
  return 0
}

# Rutas para la salida en pantalla (máx 8), con su etiqueta corta. Se llenan
# en paralelo a los contadores para no releer el informe después.
SCREEN_HITS=()
screen_hit() {  # nivel | etiqueta-corta | ruta-relativa
  [ "${#SCREEN_HITS[@]}" -ge 64 ] && return 0
  SCREEN_HITS+=("$1|$2|$3")
  return 0
}

# ¿Es el index.php "Silence is golden" que dejan los plugins de hardening?
# Excepción angosta (§ desvío documentado): index.php de ≤200 bytes cuyo
# contenido, sin comentarios ni espacios, sea sólo "<?php". Cualquier otra
# cosa —incluido un index.php con código— sigue siendo hallazgo.
is_silence_index() {
  local f="$1" sz body
  case "$f" in */index.php) ;; *) return 1 ;; esac
  sz=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
  [ "${sz:-9999}" -le 200 ] || return 1
  # Quitar comentarios de línea, comentarios de bloque, espacios y ?>. Lo que
  # queda debe ser exactamente "<?php".
  body=$(sed -e 's://.*$::' -e 's:#.*$::' "$f" 2>/dev/null \
         | tr -d ' \t\r\n' \
         | sed -e 's:/\*[^*]*\*/::g' -e 's:?>$::')
  [ "$body" = "<?php" ]
}

scan_core_checksums() {
  local root="$1"
  local vfile="$root/wp-includes/version.php"
  local ver loc
  [ -f "$vfile" ] || { rep "(sin version.php: no se verifica el core)"
                       CORE_VERIFIED=0; return 0; }
  if [ "$HAVE_PY" -ne 1 ]; then
    rep "(python3 ausente: core NO verificado)"
    warn "python3 ausente: el core NO se verificó."
    CORE_VERIFIED=0; return 0
  fi

  ver=$(grep -oE "\\\$wp_version[[:space:]]*=[[:space:]]*'[^']+'" "$vfile" 2>/dev/null \
        | head -1 | cut -d"'" -f2 || true)
  loc="${MONO_WP_LOCALE:-}"
  if [ -z "$loc" ]; then
    loc=$(grep -oE "\\\$wp_local_package[[:space:]]*=[[:space:]]*'[^']+'" "$vfile" 2>/dev/null \
          | head -1 | cut -d"'" -f2 || true)
    loc="${loc:-en_US}"
  fi

  # version.php es modificable por el atacante: validar antes de meterlo en una
  # URL. §8.2 — estos dos regex NO se tocan.
  case "$ver" in
    ''|*[!0-9.]*) rep "[REVISAR] Versión de core no reconocible en version.php: '${ver}'"
                  REVIEW=$((REVIEW+1)); CORE_VERIFIED=0; return 0 ;;
  esac
  case "$loc" in *[!A-Za-z_]*) loc="en_US" ;; esac

  rep ""; rep "── #1 Integridad del core (wordpress.org $ver / $loc) ──"
  local out rc
  set +e
  out=$(python3 - "$ver" "$loc" "$root" 2>/dev/null <<'PYEOF'
import sys, os, re, json, hashlib, urllib.request
ver, loc, root = sys.argv[1], sys.argv[2], sys.argv[3]
if not re.fullmatch(r"[0-9][0-9.]{0,15}", ver): sys.exit(9)
if not re.fullmatch(r"[A-Za-z_]{2,12}", loc):   sys.exit(9)

def fetch_sums(v, l):
    url = ("https://api.wordpress.org/core/checksums/1.0/"
           f"?version={v}&locale={l}")
    with urllib.request.urlopen(url, timeout=20) as r:
        data = json.load(r)
    s = data.get("checksums") or {}
    if v in s: s = s[v]
    if not isinstance(s, dict) or not s:
        return None
    return {k: x for k, x in s.items() if not k.startswith("wp-content/")}

try:
    sums = fetch_sums(ver, loc)
except Exception:
    sys.exit(8)
if sums is None: sys.exit(7)

def md5(p):
    h = hashlib.md5()
    with open(p, "rb") as f:
        for c in iter(lambda: f.read(1 << 16), b""):
            h.update(c)
    return h.hexdigest()

modified, added, missing, unreadable = {}, {}, [], []
covered = set()
for rel, want in sums.items():
    covered.add(rel)
    full = os.path.join(root, rel)
    if not os.path.exists(full):
        missing.append(rel)
        continue
    try:
        got = md5(full)
        if got != want:
            modified[rel] = got
    except Exception:
        unreadable.append(rel)

# Archivos presentes en wp-admin/ y wp-includes/ que el core NO declara:
# esto es lo que delata un cargador con nombre de aspecto oficial.
for d in ("wp-admin", "wp-includes"):
    base = os.path.join(root, d)
    if not os.path.isdir(base):
        continue
    for dirpath, _dirs, files in os.walk(base):
        for fn in files:
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, root).replace(os.sep, "/")
            if rel in covered or fn == ".listing":
                continue
            try:
                added[rel] = md5(full)
            except Exception:
                added[rel] = ""

# ── Sonda de core mezclado ────────────────────────────────────────────────────
# Un auto-update interrumpido (típico con la cuota llena — el mismo motivo por
# el que no se puede generar backup) deja cientos de archivos de OTRA versión
# oficial. Ante desvío masivo, probar versiones vecinas: lo que coincida byte a
# byte con un release oficial se reclasifica; lo que no coincida con NINGUNO
# queda CRÍTICO — ese es el residuo que importa.
SKEW_MIN = 20
skew_ver, skew_files = None, set()
if len(modified) + len(added) >= SKEW_MIN:
    try:
        with urllib.request.urlopen(
                "https://api.wordpress.org/core/stable-check/1.0/", timeout=15) as r:
            all_vers = list(json.load(r).keys())
    except Exception:
        all_vers = []
    def vt(v):
        try: return tuple(int(x) for x in v.split("."))
        except ValueError: return (0,)
    mine = vt(ver)
    cand = sorted((v for v in all_vers if v != ver and vt(v)[0] > 0),
                  key=lambda v: (abs(vt(v)[0]-mine[0]), [abs(a-b) for a, b
                       in zip(list(vt(v))+[0,0], list(mine)+[0,0])]))[:6]
    best_n = 0
    for cv in cand:
        try:
            csums = fetch_sums(cv, loc) or fetch_sums(cv, "en_US")
        except Exception:
            continue
        if not csums:
            continue
        hits = set()
        for rel, got in modified.items():
            if csums.get(rel) == got:
                hits.add(rel)
        for rel, got in added.items():
            if got and csums.get(rel) == got:
                hits.add(rel)
        if len(hits) > best_n:
            best_n, skew_ver, skew_files = len(hits), cv, hits

for rel in sorted(modified):
    print(("MEZCLADO|" if rel in skew_files else "MODIFICADO|") + rel)
for rel in sorted(added):
    print(("MEZCLADO|" if rel in skew_files else "ANADIDO|") + rel)
for rel in missing:
    # Con core mezclado, un "ausente" puede ser un archivo que la otra versión
    # ya no trae; sin sonda concluyente se reporta igual (REVISAR, no CRÍTICO).
    print(f"FALTANTE|{rel}")
for rel in unreadable:
    print(f"ILEGIBLE|{rel}")
if skew_ver:
    print(f"SKEW|{skew_ver}|{len(skew_files)}")
print("OK|fin")
PYEOF
)
  rc=$?
  set -e

  case "$rc" in
    8) rep "[INFO] Sin acceso a api.wordpress.org — core NO verificado."
       warn "No se pudo verificar el core (sin red hacia api.wordpress.org)."
       CORE_VERIFIED=0; return 0 ;;
    9) rep "[INFO] Versión/locale rechazados por validación — core NO verificado."
       CORE_VERIFIED=0; return 0 ;;
    7) rep "[INFO] wordpress.org no devolvió checksums para $ver/$loc — core NO verificado."
       CORE_VERIFIED=0; return 0 ;;
  esac

  CORE_VERIFIED=1
  SKEW_FOUND_VER=""; SKEW_FOUND_N=0
  CORE_DECL_VER="$ver"; CORE_BAD_N=0; CORE_ALIEN_N=0
  CORE_ALIEN_TMP=$(mktemp)
  local n_mod=0 n_add=0 n_miss=0 n_skew=0 kind rel skew_ver=""
  while IFS='|' read -r kind rel; do
    [ -z "${kind:-}" ] && continue
    case "$kind" in
      MODIFICADO) finding CRITICO "core ALTERADO" "$root/$rel"
                  [ "$n_mod" -lt 3 ] && screen_hit CRITICO "core ALTERADO" "$rel"
                  n_mod=$((n_mod+1)) ;;
      ANADIDO)    finding CRITICO "AJENO al core" "$root/$rel"
                  [ "$n_add" -lt 3 ] && screen_hit CRITICO "AJENO al core" "$rel"
                  printf '%s\n' "$rel" >> "$CORE_ALIEN_TMP"
                  n_add=$((n_add+1)) ;;
      MEZCLADO)   rep "(core mezclado) :: $rel"
                  n_skew=$((n_skew+1)) ;;
      FALTANTE)   finding REVISAR "core declarado y ausente" "$root/$rel"; n_miss=$((n_miss+1)) ;;
      ILEGIBLE)   finding REVISAR "core ilegible" "$root/$rel" ;;
      SKEW)       IFS='|' read -r skew_ver _ <<< "$rel" || true ;;
    esac
  done <<< "$out"
  if [ -n "$skew_ver" ] && [ "${n_skew:-0}" -gt 0 ]; then
    # UN hallazgo accionable en vez de cientos de críticos. Lo que NO coincidió
    # con ninguna versión oficial quedó arriba como CRÍTICO.
    SKEW_FOUND_VER="$skew_ver"; SKEW_FOUND_N=$n_skew
    finding REVISAR "core MEZCLADO: $n_skew archivos coinciden byte a byte con la versión oficial $skew_ver (auto-update interrumpido, típico con cuota llena) — reinstalar el core" "$root/wp-includes"
    screen_hit REVISAR "core mezclado ($skew_ver)" "reinstalar core: $n_skew arch. son de la $skew_ver"
    event "escaneo: core mezclado — $n_skew archivos coinciden con la $skew_ver oficial"
  fi
  CORE_BAD_N=$((n_mod + n_miss)); CORE_ALIEN_N=$n_add
  rep ""
  rep "Resumen core: alterados=$n_mod  ajenos=$n_add  ausentes=$n_miss  mezclados=${n_skew}${skew_ver:+ (coinciden con $skew_ver)}"
  return 0
}

# Alimenta stdin de un consumidor con la salida de un comando, sin pipe (el
# pipe corre el consumidor en un subshell y pierde los contadores) y sin
# process substitution (los contenedores de sitios no montan /dev/fd, y
# `< <(...)` muere con "/dev/fd/63: No such file or directory" — hallazgo de
# la primera migración real). Archivo temporal: portable a cualquier bash.
#   feed_from <consumidor con args...> -- <productor con args...>
feed_from() {
  local _cons=() _t
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do _cons+=("$1"); shift; done
  shift   # el --
  _t=$(mktemp)
  "$@" > "$_t" 2>/dev/null || true
  "${_cons[@]}" < "$_t"
  rm -f "$_t"
  return 0
}

# Recorre un conjunto de rutas (una por línea en stdin) y emite finding+screen.
emit_paths() {  # nivel | motivo | etiqueta-corta
  local lvl="$1" why="$2" tag="$3" f rel
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    finding "$lvl" "$why" "$f"
    rel="${f#"$DEST"/}"
    screen_hit "$lvl" "$tag" "$rel"
  done
  return 0
}

scan_tree() {
  set_phase escaneo
  local root="$1"
  local stamp; stamp=$(date +%Y%m%d-%H%M)
  REPORT="$DEST/scan-${stamp}.txt"
  CRIT=0; REVIEW=0; SCREEN_HITS=(); CORE_VERIFIED=0

  : > "$REPORT"
  rep "mono-ftp-mirror v$VERSION — primera capa de detección"
  rep "Fecha:   $(date -Is 2>/dev/null || date)"
  rep "Árbol:   $root"
  rep ""
  rep "AVISO DE ALCANCE. Esto es una primera capa de detección, no un antivirus."
  rep "Sin hallazgos no significa limpio. Los CRÍTICO por checksum de core son"
  rep "concluyentes; el resto es alta señal, bajo ruido, pero no exhaustivo."
  rep ""

  info "${C_DIM}Analizando el árbol descargado…${C_RESET}"

  # #1 — Integridad del core contra wordpress.org (el corazón).
  scan_core_checksums "$root"

  # #3 — PHP ejecutable bajo uploads. Excepción: index.php silence-is-golden.
  rep ""; rep "── #3 PHP ejecutable en uploads ──"
  local f _up; _up=$(mktemp)
  find "$root" -path '*/uploads/*' \
       \( -name '*.php' -o -name '*.phtml' -o -name '*.php[0-9]' -o -name '*.phar' \) \
       2>/dev/null > "$_up" || true
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if is_silence_index "$f"; then
      rep "(ignorado, index.php silence-is-golden) :: ${f#"$DEST"/}"
      continue
    fi
    finding CRITICO "PHP en uploads" "$f"
    screen_hit CRITICO "PHP en uploads" "${f#"$DEST"/}"
  done < "$_up"
  rm -f "$_up"

  # NOTA — emit_paths se alimenta vía feed_from (archivo temporal), nunca con
  # un pipe (subshell: pierde contadores) ni con process substitution
  # (/dev/fd no existe en los contenedores de sitios — visto en producción).

  # #4 — .htaccess con ejecución inyectada.
  rep ""; rep "── #4 .htaccess con PHP inyectado ──"
  feed_from emit_paths CRITICO ".htaccess: auto_prepend/handler PHP" ".htaccess inyectado" -- \
    grep -rlE 'auto_prepend_file|auto_append_file|AddType[[:space:]]+application/x-httpd-php' \
        "$root" --include='.htaccess' 

  # #5 — Firmas de webshell conocidas.
  rep ""; rep "── #5 Firmas de webshell ──"
  feed_from emit_paths CRITICO "firma de webshell" "webshell" -- \
    grep -rlE 'FilesMan|WSO [0-9]|c99shell|r57shell|b374k|IndoXploit|MiniShell' \
        "$root" --include='*.php' 

  # #6 — Función variable sobre superglobal.
  rep ""; rep "── #6 Función variable sobre superglobal ──"
  # shellcheck disable=SC2016  # regex de grep, no expansión de shell
  feed_from emit_paths CRITICO "superglobal como función" "\$_[..]()" -- \
    grep -rlE '\$_(POST|GET|REQUEST|COOKIE)\[[^]]{1,40}\][[:space:]]*\(' \
        "$root" --include='*.php' 

  # #7 — eval sobre codificado + preg_replace /e.
  # El modificador /e va AL FINAL del patrón, entre el delimitador y la comilla
  # de cierre: preg_replace('/x/e', ...). Un "/e" en el MEDIO es contenido
  # (eventbrite.com/e/… en Jetpack disparaba falso positivo — visto en la
  # primera migración real). Backreferencia \2: extensión de GNU grep, presente
  # en los nodos Ubuntu donde corre esto.
  rep ""; rep "── #7 eval(codificado) / preg_replace /e ──"
  feed_from emit_paths CRITICO "eval/preg_replace ofuscado" "eval(...)" -- \
    grep -rlE "eval[[:space:]]*\\([[:space:]]*(base64_decode|gzinflate|str_rot13)|preg_replace[[:space:]]*\\([[:space:]]*([\"']).*[/#~@%!|][imsxuADSUXJ]*e[imsxuADSUXJ]*\\2[[:space:]]*," \
        "$root" --include='*.php' 

  # #10 — eval/assert DIRECTO sobre superglobal (cierra el hueco de sacar el
  # grep genérico: assert($_POST[..]) no lo agarra ni #6 ni #7).
  rep ""; rep "── #10 eval/assert directo sobre superglobal ──"
  # shellcheck disable=SC2016  # regex de grep, no expansión de shell
  feed_from emit_paths CRITICO "eval/assert sobre superglobal" "assert(\$_..)" -- \
    grep -rlE '(eval|assert)[[:space:]]*\([[:space:]]*\$_(POST|GET|REQUEST|COOKIE)' \
        "$root" --include='*.php' 

  # #8 — Nombres de camuflaje.  REVISAR.
  rep ""; rep "── #8 Nombres de camuflaje ──"
  feed_from emit_paths REVISAR "nombre de camuflaje" "camuflaje" -- \
    find "$root" \( -name '.*.php' -o -name '*.php.suspected' \
        -o -name '*.ico.php' -o -name '*.php.bak' \)

  # #9 — mu-plugins con contenido.  REVISAR.
  rep ""; rep "── #9 mu-plugins con contenido ──"
  if [ -d "$root/wp-content/mu-plugins" ]; then
    local n; n=$(find "$root/wp-content/mu-plugins" -name '*.php' 2>/dev/null | wc -l | tr -d ' ')
    if [ "${n:-0}" -gt 0 ]; then
      finding REVISAR "mu-plugins con $n PHP — se cargan siempre, revisar" \
              "$root/wp-content/mu-plugins"
      screen_hit REVISAR "mu-plugins" "wp-content/mu-plugins ($n PHP)"
      find "$root/wp-content/mu-plugins" -name '*.php' 2>/dev/null \
        | sed 's|^|    |' >> "$REPORT" || true
    else
      rep "(mu-plugins presente pero sin PHP)"
    fi
  else
    rep "(sin mu-plugins)"
  fi

  # ── CONTEXTO (no cuenta como hallazgo) ────────────────────────────────────
  rep ""; rep "══ CONTEXTO (informativo, no suma a ningún contador) ══"
  rep "Agrupación temporal de PHP por día de modificación. El día con un pico"
  rep "anómalo suele ser la fecha del compromiso; es el dato que el cliente"
  rep "necesita para evaluar su plazo de notificación (art. 34 DS 016-2024-JUS)."
  rep "No se interpreta aquí, sólo se presenta."
  rep ""
  rep "── PHP por día de modificación (top 12) ──"
  find "$root" -name '*.php' -printf '%TY-%Tm-%Td\n' 2>/dev/null \
    | sort | uniq -c | sort -rn | head -12 | sed 's|^|    |' >> "$REPORT" || true
  rep ""
  rep "── PHP modificados más recientemente (top 30) ──"
  find "$root" -name '*.php' -printf '%TY-%Tm-%Td %TH:%TM  %p\n' 2>/dev/null \
    | sort -r | head -30 | sed "s|$root/||" | sed 's|^|    |' >> "$REPORT" || true

  # ── Resumen en archivo ────────────────────────────────────────────────────
  rep ""; rep "══ RESUMEN ══"
  rep "CRÍTICO: $CRIT   REVISAR: $REVIEW"
  if [ "$CORE_VERIFIED" -eq 1 ]; then
    rep "Core: verificado contra wordpress.org"
  else
    rep "Core: NO verificado (ver arriba el motivo)"
  fi

  event "escaneo: CRÍTICO=$CRIT REVISAR=$REVIEW · $(basename "$REPORT")"
  write_status
  scan_screen_summary
  return 0
}

# Salida en pantalla: máximo ~15 líneas, máx 8 rutas. La frase de alcance es
# obligatoria aunque salgan cero hallazgos.
scan_screen_summary() {
  local crit_labels review_labels
  crit_labels=$(scan_labels_for CRITICO)
  review_labels=$(scan_labels_for REVISAR)

  printf '\n%s\n' "${C_B}── Primera capa de detección ──────────────────────────${C_RESET}"
  if [ "$CRIT" -gt 0 ]; then
    printf '  %s %3d   %s\n' "${C_ERR}CRÍTICO${C_RESET}" "$CRIT" "${C_DIM}${crit_labels}${C_RESET}"
  else
    printf '  %s %3d\n' "${C_OK}CRÍTICO${C_RESET}" 0
  fi
  if [ "$REVIEW" -gt 0 ]; then
    printf '  %s %3d   %s\n' "${C_WARN}REVISAR${C_RESET}" "$REVIEW" "${C_DIM}${review_labels}${C_RESET}"
  else
    printf '  %s %3d\n' "${C_OK}REVISAR${C_RESET}" 0
  fi

  if [ "${#SCREEN_HITS[@]}" -gt 0 ]; then
    printf '\n'
    local shown=0 e lvl tag rel pass
    # Dos pasadas: primero los CRÍTICO, después los REVISAR. Máx 8 en total.
    for pass in CRITICO REVISAR; do
      for e in "${SCREEN_HITS[@]}"; do
        [ "$shown" -ge 8 ] && break
        IFS='|' read -r lvl tag rel <<< "$e" || true
        [ "$lvl" = "$pass" ] || continue
        # Normalizar a ruta relativa a la raíz del sitio (quitar public_html/)
        # y, si es larga, mostrar la cola: el nombre del archivo es lo útil.
        rel="${rel#public_html/}"
        [ "${#rel}" -gt 34 ] && rel="…${rel: -33}"
        printf '  ▸ %-34s %s\n' "$rel" "$tag"
        shown=$((shown+1))
      done
    done
    if [ "${#SCREEN_HITS[@]}" -gt 8 ]; then
      printf '  %s\n' "${C_DIM}… y $(( ${#SCREEN_HITS[@]} - 8 )) más en el informe${C_RESET}"
    fi
  fi

  [ "$CORE_VERIFIED" -eq 1 ] || printf '\n  %s\n' "${C_WARN}Core NO verificado — ver el informe.${C_RESET}"

  printf '\n  Informe: %s\n' "${C_ACC}$(basename "$REPORT")${C_RESET}"
  printf '  %s\n' "${C_DIM}Esto es una primera capa, no un antivirus. Sin hallazgos${C_RESET}"
  printf '  %s\n' "${C_DIM}no significa limpio.${C_RESET}"

  if [ "$CRIT" -gt 0 ]; then
    printf '\n'
    warn "No despliegues este árbol mientras haya CRÍTICOS abiertos."
  fi
  return 0
}

# ── Reinstalación del core sobre la COPIA (nunca el origen) ──────────────────
# Cuando la sonda detecta core mezclado, ofrece completar la actualización que
# quedó a medias: descargar el paquete oficial de LA VERSIÓN QUE LOS ARCHIVOS
# YA SON (no "la última": la migración replica, no mejora — el salto de versión
# es mantenimiento post-migración), verificarlo archivo por archivo contra
# api.wordpress.org ANTES de copiar nada, instalar solo lo que el manifiesto
# oficial declara (wp-content jamás se toca), y re-escanear.
SKEW_FOUND_VER=""; SKEW_FOUND_N=0
CORE_DECL_VER=""; CORE_BAD_N=0; CORE_ALIEN_N=0; CORE_ALIEN_TMP=""
offer_core_reinstall() {
  local root="$1" ver=""
  # Dispara con core mezclado (versión = la que los archivos ya son) o con
  # core alterado/ausente en caso limpio (versión = la declarada).
  if [ -n "$SKEW_FOUND_VER" ]; then ver="$SKEW_FOUND_VER"
  elif [ "${CORE_BAD_N:-0}" -gt 0 ] || [ "${CORE_ALIEN_N:-0}" -gt 0 ]; then ver="$CORE_DECL_VER"
  fi
  [ -n "$ver" ] || return 0
  if [ "$CASE_CLEAN" -ne 1 ]; then
    info "Caso comprometido: la reinstalación del core es parte de la erradicación,"
    info "no de este flujo. Conservá esta copia intacta como referencia primero."
    return 0
  fi
  if [ "$HAVE_UNZIP" -ne 1 ] || [ "$HAVE_PY" -ne 1 ]; then
    warn "Núcleo con desvíos, pero falta unzip o python3 para reinstalar"
    warn "verificado. Hacelo a mano con el zip oficial de la $ver."
    return 0
  fi

  printf '\n%s\n' "${C_B}── Reinstalar el núcleo de WordPress ──────────────────${C_RESET}"
  if [ -n "$SKEW_FOUND_VER" ]; then
    info "El auto-update quedó a medias: $SKEW_FOUND_N archivos ya son de la $ver."
  else
    info "El núcleo tiene ${CORE_BAD_N} archivo(s) alterados o ausentes."
  fi
  info "Se reemplaza SOLO el núcleo: wp-admin/, wp-includes/ y los archivos"
  info "de raíz de WordPress, por el paquete oficial ${ver} verificado contra"
  info "api.wordpress.org antes de copiar un solo byte."
  printf '  %s\n' "${C_B}NO se tocan los archivos del cliente:${C_RESET} temas, plugins, uploads"
  info "(todo wp-content/) y wp-config.php quedan exactamente como están."
  info "Con esto, cualquier alteración, error o infección DENTRO del núcleo"
  info "queda eliminada."
  if [ "${CORE_ALIEN_N:-0}" -gt 0 ]; then
    info "Además: ${CORE_ALIEN_N} archivo(s) AJENOS al núcleo (reinstalar no los"
    info "borra) se mueven a una cuarentena local para tu revisión."
  fi
  local a; read -rp "  ¿Reinstalar el núcleo oficial $ver sobre la copia? [s/N] " a || a=""
  case "$a" in [sS]*) ;; *) info "Queda pendiente: reinstalar el núcleo a mano."; return 0 ;; esac

  local tmpd; tmpd=$(mktemp -d)
  info "Descargando wordpress-${ver}.zip…"
  if ! wget -q -T 180 -O "$tmpd/wp.zip" "https://wordpress.org/wordpress-${ver}.zip"; then
    warn "No pude descargar el paquete oficial. Sin cambios."; rm -rf "$tmpd"; return 0
  fi
  if ! unzip -q "$tmpd/wp.zip" -d "$tmpd" || [ ! -d "$tmpd/wordpress" ]; then
    warn "El zip no descomprimió como se esperaba. Sin cambios."; rm -rf "$tmpd"; return 0
  fi

  info "Verificando el paquete contra api.wordpress.org e instalando…"
  local pyrc=0
  set +e
  python3 - "$ver" "$tmpd/wordpress" "$root" <<'PYEOF'
import sys, os, json, shutil, hashlib, urllib.request
ver, src, dst = sys.argv[1], sys.argv[2], sys.argv[3]
url = ("https://api.wordpress.org/core/checksums/1.0/"
       f"?version={ver}&locale=en_US")
try:
    with urllib.request.urlopen(url, timeout=25) as r:
        data = json.load(r)
except Exception:
    sys.exit(8)
sums = data.get("checksums") or {}
if ver in sums: sums = sums[ver]
if not isinstance(sums, dict) or not sums: sys.exit(7)

def md5(p):
    h = hashlib.md5()
    with open(p, "rb") as f:
        for c in iter(lambda: f.read(1 << 16), b""):
            h.update(c)
    return h.hexdigest()

# Dos pasadas: primero verificar TODO el paquete; recién si está íntegro,
# copiar. Nunca instalar a medias. Solo entradas del manifiesto oficial
# (eso además hace imposible el zip-slip: las rutas salen de la API, no
# del zip) y nunca wp-content/.
plan = []
for rel, want in sums.items():
    if rel.startswith("wp-content/"):
        continue
    srcf = os.path.join(src, rel)
    if not os.path.isfile(srcf) or md5(srcf) != want:
        print(f"VERIFY-FAIL|{rel}")
        sys.exit(6)
    plan.append(rel)
for rel in plan:
    dstf = os.path.join(dst, rel)
    os.makedirs(os.path.dirname(dstf), exist_ok=True)
    shutil.copy2(os.path.join(src, rel), dstf)
print(f"INSTALADOS|{len(plan)}")
PYEOF
  pyrc=$?
  set -e
  rm -rf "$tmpd"
  if [ "$pyrc" -ne 0 ]; then
    case "$pyrc" in
      6) warn "El paquete descargado NO pasó la verificación de checksums. Sin cambios." ;;
      7|8) warn "No pude verificar contra api.wordpress.org. Sin cambios." ;;
      *) warn "Fallo inesperado en la reinstalación (rc=$pyrc). Sin cambios." ;;
    esac
    return 0
  fi
  ok "Reinstalación verificada: núcleo oficial $ver instalado en la copia."
  event "núcleo reinstalado: $ver oficial, verificado contra api.wordpress.org"

  # Cuarentena de los ajenos al núcleo: se MUEVEN (no se borran) a un
  # directorio fuera del árbol servible, para revisión. Reinstalar solo
  # sobreescribe lo declarado; esto retira lo que el manifiesto no conoce.
  if [ -s "${CORE_ALIEN_TMP:-/dev/null}" ]; then
    local qdir rel moved=0
    qdir="$DEST/cuarentena-core-$(date +%Y%m%d-%H%M)"
    while IFS= read -r rel; do
      [ -f "$root/$rel" ] || continue
      mkdir -p "$qdir/$(dirname "$rel")"
      mv -- "$root/$rel" "$qdir/$rel" && moved=$((moved+1))
    done < "$CORE_ALIEN_TMP"
    if [ "$moved" -gt 0 ]; then
      ok "$moved archivo(s) ajenos al núcleo movidos a $(basename "$qdir")/ para revisión."
      event "cuarentena: $moved archivos ajenos al núcleo → $(basename "$qdir")"
    fi
  fi
  rm -f "${CORE_ALIEN_TMP:-}"

  info "Re-escaneando…"
  scan_tree "$root"
  info "Recordatorio: al importar la BD, WordPress pedirá completar la"
  info "actualización de base de datos (wp-admin/upgrade.php o wp core update-db)."
  return 0
}

# Etiquetas cortas distintas de un nivel, para la línea-resumen (dedup, máx 3).
scan_labels_for() {  # nivel
  local want="$1" e lvl tag rel out=""
  [ "${#SCREEN_HITS[@]}" -gt 0 ] || return 0
  for e in "${SCREEN_HITS[@]}"; do
    IFS='|' read -r lvl tag rel <<< "$e" || true
    [ "$lvl" = "$want" ] || continue
    case " $out " in *" $tag "*) continue ;; esac
    out="${out:+$out · }$tag"
  done
  printf '%s' "$out" | awk -F' · ' '{n=(NF>3?3:NF); for(i=1;i<=n;i++) printf "%s%s", $i, (i<n?" · ":"")}'
  return 0
}

# --------------------------------------------------------------- verificación
# Raíz del espejo en disco = DEST + la ruta de RPATH (wget --no-host-directories
# baja /public_html/ dentro de DEST/public_html/). Si no existe, cae a DEST.
mirror_root() {
  local r="$DEST/${RPATH#/}"; r="${r%/}"
  [ -d "$r" ] && printf '%s' "$r" || printf '%s' "$DEST"
}

verify() {
  set_phase verificacion
  printf '\n%s\n' "${C_B}── Verificación de la copia ───────────────────────────${C_RESET}"
  local rroot total du_h
  rroot=$(mirror_root)
  total=$(find "$DEST" -type f ! -name '.listing' ! -name "$LOG" 2>/dev/null | wc -l | tr -d ' ')
  du_h=$(du -sh "$DEST" 2>/dev/null | awk '{print $1}')
  info "Archivos en disco   $(thousands "$total")"
  info "Peso en disco       ${du_h:-?}"

  printf '\n  %s\n' "${C_B}Dotfiles críticos${C_RESET}"
  local d
  for d in ".htaccess" ".user.ini" "wp-content/uploads/.htaccess"; do
    if [ -e "$rroot/$d" ]; then ok "$d"
    else printf '  %s\n' "${C_WARN}○ $d — no está (puede no existir en origen)${C_RESET}"; fi
  done

  # §7.2 — resumen por clase (una sola pasada al final, no en vivo).
  classify_log "$LOG"
  printf '\n'
  if [ -n "${DOMINANT_CLASS:-}" ]; then
    warn "El log tiene errores. Clase dominante: ${DOMINANT_CLASS}."
    info "${C_DIM}$(class_action "$DOMINANT_CLASS")${C_RESET}"
  else
    ok "Sin errores clasificables en el log."
  fi

  # §7.5 — reconciliación: la única afirmación sólida de que el espejo está
  # entero. Requiere además que wget haya cerrado su recorrido.
  # Camino zip: no hay .listing del contenido; la integridad la garantizó el
  # CRC por entrada (unzip -t). Se dice explícitamente y no se finge reconciliar.
  printf '\n'
  if [ "$ZIP_COMPLETED" -eq 1 ]; then
    ok "Integridad del zip verificada por CRC (unzip -t); reconciliación por listado no aplica."
    return 0
  fi
  if reconcile "$rroot" "$EXCLUDES"; then
    if download_finished; then
      event "reconciliación completa: $REC_PRESENT/$REC_EXPECTED"
      ok "Reconciliación completa — $(thousands "$REC_PRESENT") de $(thousands "$REC_EXPECTED") esperados."
    else
      warn "Sin faltantes por ahora, pero wget no cerró su recorrido:"
      info "el árbol puede estar incompleto. No cortes DNS todavía."
    fi
  else
    local mf
    # shellcheck disable=SC2012  # nombre con timestamp controlado, sin glob raro
    mf=$(ls "$DEST"/faltantes-*.txt 2>/dev/null | tail -1)
    event "reconciliación INCOMPLETA: $REC_PRESENT/$REC_EXPECTED · ausentes=$REC_MISSING truncados=$REC_TRUNC sin-listar=$REC_UNLISTED"
    warn "Reconciliación   $(thousands "$REC_PRESENT") de $(thousands "$REC_EXPECTED") esperados"
    printf '  %s✗ %s ausentes · %s truncados · %s sin listar%s → %s\n' \
      "$C_ERR" "$REC_MISSING" "$REC_TRUNC" "$REC_UNLISTED" "$C_RESET" \
      "$(basename "${mf:-faltantes.txt}")"
  fi
  return 0
}

# --------------------------------------------------------------- cierre
close_out() {
  set_phase cierre
  printf '\n%s\n' "${C_B}── Cierre de la conexión ──────────────────────────────${C_RESET}"
  info "Al confirmar: se termina el wget, los .listing se archivan en tar.gz"
  info "y se retiran del árbol. El informe de escaneo se conserva."
  printf '\n'
  local a; read -rp "  ¿Cerrar la conexión y archivar los listados? [s/N] " a || a=""
  case "$a" in
    [sS]*) ;;
    *) warn "Cierre omitido."; return 0 ;;
  esac

  if [ -n "${PID:-}" ] && kill -0 "$PID" 2>/dev/null; then
    kill "$PID" 2>/dev/null || true; sleep 1; kill -9 "$PID" 2>/dev/null || true
    info "Proceso wget terminado."
  fi
  rm -f "$PIDFILE" "$WATCH_MARK"

  local stamp arch count
  stamp=$(date +%Y%m%d-%H%M); arch="listados-remotos-${stamp}.tar.gz"
  count=$(find "$DEST" -name '.listing' 2>/dev/null | wc -l)
  if [ "${count:-0}" -gt 0 ]; then
    find "$DEST" -name '.listing' -print0 2>/dev/null \
      | tar --null -czf "$arch" --files-from=- 2>/dev/null || true
    find "$DEST" -name '.listing' -delete 2>/dev/null || true
    ok "$(thousands "$count") listados archivados en $arch"
  fi

  # §6.3 — nota informativa: si el dominio que se migra está proxiado por
  # Cloudflare, avisar del problema de Let's Encrypt al cortar el DNS. No
  # bloquea. Deriva el dominio del host FTP (quita un 'ftp.' inicial). Si el
  # host es una IP, no hay dominio que comprobar y se omite en silencio.
  local mig_domain=""
  case "$FTPHOST" in
    *[!0-9.]*) mig_domain="${FTPHOST#ftp.}" ;;
  esac
  cf_dest_note "$mig_domain"

  # Informe de cierre: el registro queda ACÁ aunque los operativos se borren.
  # Anota qué se hizo, la reconciliación, el DELE del zip si hubo, y las
  # últimas líneas del log antes de que el log se vaya.
  local cierre="$DEST/cierre-${stamp}.txt"
  {
    echo "mono-ftp-mirror v$VERSION — informe de cierre"
    echo "Fecha:  $(date -Is 2>/dev/null || date)"
    echo "Origen: ftp://${FTPHOST:-?}${RPATH:-}"
    echo "Destino: $DEST"
    echo ""
    echo "Reconciliación: esperados=${REC_EXPECTED:-?} presentes=${REC_PRESENT:-?} ausentes=${REC_MISSING:-?} truncados=${REC_TRUNC:-?} sin-listar=${REC_UNLISTED:-?}"
    if [ "${ZIP_COMPLETED:-0}" -eq 1 ]; then
      echo "Vía zip: verificado por CRC (unzip -t)."
      if [ "${ZIP_DELETED_CONFIRMED:-0}" -eq 1 ]; then
        echo "Zip del origen: BORRADO por DELE, ausencia verificada por re-listado."
      else
        echo "Zip del origen: PENDIENTE de borrar desde el panel."
      fi
    fi
    echo ""
    echo "── Últimas 50 líneas de wget.log ──"
    tail -50 "$LOG" 2>/dev/null || echo "(sin log)"
  } > "$cierre"
  ok "Informe de cierre: $(basename "$cierre")"

  # Limpieza de operativos en el DESTINO. Los informes (scan-*, faltantes-*,
  # fallo-*, cierre-*) SIEMPRE se conservan: §9 los pone en el directorio
  # forense a propósito. NUNCA se toca ~/.bash_history — es del operador.
  printf '\n%s\n' "${C_B}── Limpieza del destino ───────────────────────────────${C_RESET}"
  info "Se conservan: informes (escaneo, reconciliación, fallo, cierre),"
  info "              eventos.log y status.json (el registro de la corrida)."
  info "Se borran:    wget.log, alertas en vivo y marcas temporales."
  local lz; read -rp "  ¿Limpiar los operativos? [s/N] " lz || lz=""
  case "$lz" in
    [sS]*)
      rm -f "$LOG" "$ALERTS" "$PIDFILE" "$WATCH_MARK"
      rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}/mono-ftp-mirror" 2>/dev/null || true
      ok "Operativos borrados. El registro queda en $(basename "$cierre")." ;;
    *) info "Operativos conservados." ;;
  esac

  # Checklist del ORIGEN: lo que este script no puede tocar porque vive en el
  # panel, no en el FTP. Prometer "cero rastro" sin nombrarlo sería mentir.
  printf '\n%s\n' "${C_B}── Pendientes en el ORIGEN (no automatizables) ────────${C_RESET}"
  printf '  %s\n' "${C_ERR}1. Eliminar la cuenta FTP temporal de la migración — es un${C_RESET}"
  printf '  %s\n' "${C_ERR}   acceso permanente al sitio del cliente si queda viva.${C_RESET}"
  info "2. Borrar backups o exports que el panel haya generado como archivo."
  info "3. Borrar los .sql exportados a archivo (si no fueron descarga directa)."
  if [ "${ZIP_COMPLETED:-0}" -eq 1 ] && [ "${ZIP_DELETED_CONFIRMED:-0}" -ne 1 ]; then
    printf '  %s\n' "${C_ERR}4. BORRAR EL ZIP del origen — quedó pendiente.${C_RESET}"
  fi

  printf '\n%s\n' "${C_B}── Siguiente paso ─────────────────────────────────────${C_RESET}"
  info "1. Revisar el informe de escaneo antes de tocar nada"
  info "2. Exportar la base de datos (phpMyAdmin: Personalizado + DROP TABLE + gzip)"
  info "3. Si el panel destino dejó un WordPress preinstalado: pisar sus archivos"
  info "   con este árbol pero CONSERVAR su wp-config.php (credenciales de BD"
  info "   nuevas + salts rotados = sesiones viejas invalidadas). Ajustar"
  info "   \$table_prefix al del dump importado — si difiere, el sitio carga vacío."
  info "4. Al primer ingreso, WordPress puede pedir actualizar la BD: es normal"
  info "   (wp-admin/upgrade.php o wp core update-db)."
  info "5. Descargar los Raw Access Logs del panel de origen — se rotan"
  info "6. Rotar credenciales: panel, FTP, base de datos, DNS/CDN, pasarela"
  info "7. Erradicación sobre la copia, nunca sobre el origen"
  printf '\n'

  # Autodestrucción (higiene, no borrado de huellas): la herramienta se retira
  # del servidor al terminar; el registro (informes) se queda. Nunca automática,
  # default No. Volver a instalarla es un comando de una línea.
  local self sd
  self=$(command -v -- "$0" 2>/dev/null || printf '%s' "$0")
  case "$self" in
    */mono-ftp-mirror*|*/migrate-web*)
      printf '%s\n' "${C_B}── Retirar la herramienta ─────────────────────────────${C_RESET}"
      info "Se borra:  $self (y su .sha256 si está al lado)"
      info "Se queda:  todo el árbol descargado y todos los informes"
      read -rp "  ¿Borrar la herramienta de este servidor? [s/N] " sd || sd=""
      case "$sd" in
        [sS]*)
          # Subshell desprendido: bash lee el script por bloques; borrar $0 en
          # caliente puede dejarlo leyendo un archivo desaparecido. El subshell
          # espera a que este proceso muera y recién entonces borra.
          ( sleep 1
            while kill -0 $$ 2>/dev/null; do sleep 1; done
            shred -u -- "$self" 2>/dev/null || rm -f -- "$self"
            rm -f -- "${self}.sha256" "${self}.bak" 2>/dev/null
          ) >/dev/null 2>&1 &
          disown 2>/dev/null || true
          ok "Se borrará al salir. Para reinstalar: el comando del README." ;;
        *) info "La herramienta queda instalada." ;;
      esac ;;
  esac
  return 0
}

# --------------------------------------------------------------- main
main() {
  preflight

  if [ "$SCAN_ONLY" -eq 1 ]; then
    local root="$DEST"
    [ -d "$DEST/public_html" ] && root="$DEST/public_html"
    scan_tree "$root"
    offer_core_reinstall "$root"
    exit 0
  fi

  if [ "$ATTACH" -eq 1 ]; then
    [ -f "$PIDFILE" ] || die "No hay $PIDFILE en $DEST."
    PID=$(cat "$PIDFILE")
    kill -0 "$PID" 2>/dev/null || die "El PID $PID ya no está vivo."
    FTPHOST="${MONO_HOST:-(en curso)}"; RPATH="${MONO_PATH:-}"; SCOPE="(en curso)"
    STRATEGY_DONE=1        # la estrategia se decidió al lanzar; no reinterrogar
    EXPECT_BYTES=0
    [ -n "${MONO_EXPECT_MB:-}" ] && EXPECT_BYTES=$((MONO_EXPECT_MB * 1024 * 1024))
    ok "Reenganchando al PID $PID"; sleep 1
  else
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
      die "Ya hay una descarga viva (PID $(cat "$PIDFILE")). Usa: $0 --attach"
    fi
    SCOPE="todo"
    ask_case_type          # §4.1 — la primera pregunta del flujo
    ask_credentials
    choose_scope
    ask_expected
    # §5.5 — reanudación entre sesiones: si ya hay árbol parcial, decirlo. wget
    # --mirror continúa sin rebajar lo bajado; sin este aviso parece que va a
    # empezar de cero.
    local prior
    prior=$(find "$DEST" -name '.listing' 2>/dev/null | head -1 || true)
    if [ -n "$prior" ]; then
      local pf; pf=$(find "$DEST" -type f ! -name '.listing' ! -name "$LOG" 2>/dev/null | wc -l | tr -d ' ')
      warn "Ya hay una descarga parcial acá: $(thousands "$pf") archivos en disco."
      info "wget continúa desde donde quedó; no se rebaja lo ya bajado."
    fi
    start_mirror
  fi

  monitor
  verify

  if [ "$DO_SCAN" -eq 1 ]; then
    local root="$DEST"
    # Camino zip: el árbol vivo está en el subdirectorio de extracción.
    if [ -n "$ZIP_EXTRACT_DIR" ] && [ -d "$ZIP_EXTRACT_DIR" ]; then
      root="$ZIP_EXTRACT_DIR"
      [ -d "$ZIP_EXTRACT_DIR/public_html" ] && root="$ZIP_EXTRACT_DIR/public_html"
    elif [ -d "$DEST/public_html" ]; then
      root="$DEST/public_html"
    fi
    scan_tree "$root"
    offer_core_reinstall "$root"
  fi

  close_out
}

# Guarda de sourcing: con MONO_FTP_MIRROR_LIB=1 el archivo se puede "source"
# para probar funciones puras (clasificador, estimador, CF, reconciliación)
# sin ejecutar el flujo. En uso normal corre main como siempre.
if [ "${MONO_FTP_MIRROR_LIB:-0}" != "1" ]; then
  main "$@"
fi
