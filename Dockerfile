# Small nginx image
FROM nginx:1.27-alpine

# Replace default web root content
COPY index.html /usr/share/nginx/html/index.html

# (optional) basic health endpoint already works: GET /
EXPOSE 80
