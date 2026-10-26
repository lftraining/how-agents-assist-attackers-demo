# Dockerfile — the vendor docs server: plain nginx serving two static files, with no
# outbound connections. The base image is pinned by digest.
FROM nginx:1.30.6-alpine@sha256:750f6c5456af731b47295d124fbed55664eeb1daab4f6bac0b092b7406235091

# nginx's default site serves these files on port 80.
COPY llms.txt   /usr/share/nginx/html/llms.txt
COPY index.html /usr/share/nginx/html/index.html
