# The SocketAgent web app: build/web from build-app.sh --web, served as
# static files. build-web-app.sh --deploy builds this on the production
# server with build/web copied in as site/.
FROM nginx:1.27-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY site/ /usr/share/nginx/html/
ARG REVISION=unknown
LABEL org.opencontainers.image.source="https://github.com/Yllib/socketagent-app" \
      org.opencontainers.image.revision="$REVISION"
HEALTHCHECK --interval=30s --timeout=3s CMD wget -qO- http://127.0.0.1/healthz >/dev/null || exit 1
