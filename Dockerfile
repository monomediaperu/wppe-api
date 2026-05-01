# wppe-api — sirve archivos estaticos para api.wp.pe
#
# Imagen base: nginx:alpine (mas pequena que -slim, ~10 MB).
# Health endpoint en /status/ping.json. CORS abierto en /bridge/.
FROM nginx:alpine

# Copiar archivos publicos al webroot estandar de nginx.
COPY public/ /usr/share/nginx/html/

# Reemplazar config default por la nuestra (CORS + cache TTL diferenciado).
COPY nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80

# Comando default de la imagen alpine ya hace `nginx -g 'daemon off;'`.
