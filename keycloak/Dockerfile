# Custom Keycloak image with Cloudflare Turnstile SPI (bind flows in Admin Console).
#
# Build:
#   docker build -t kb-keycloak:26.0 .
#
# Prod: knowledge-base-deploy/keycloak — set KEYCLOAK_IMAGE in .env.

ARG KEYCLOAK_VERSION=26.0
ARG TURNSTILE_PROVIDER_VERSION=0.1.0-alpha.77

FROM alpine:3.20 AS icons
RUN apk add --no-cache imagemagick librsvg
WORKDIR /work
COPY assets/favicon.svg .
RUN magick -background none favicon.svg -define icon:auto-resize=64,48,32,16 favicon.ico

FROM quay.io/keycloak/keycloak:${KEYCLOAK_VERSION} AS builder

ARG TURNSTILE_PROVIDER_VERSION

USER root
ADD --chmod=644 \
  "https://github.com/zymlabs/keycloak-cloudflare-turnstile-provider/releases/download/${TURNSTILE_PROVIDER_VERSION}/zymlabs-cloudflare-turnstile-provider-${TURNSTILE_PROVIDER_VERSION}.jar" \
  /opt/keycloak/providers/zymlabs-cloudflare-turnstile-provider.jar
USER keycloak

RUN /opt/keycloak/bin/kc.sh build

FROM quay.io/keycloak/keycloak:${KEYCLOAK_VERSION}

COPY --from=builder /opt/keycloak/ /opt/keycloak/
COPY themes/ /opt/keycloak/themes/
COPY assets/favicon.svg /opt/keycloak/themes/kb/login/resources/img/favicon.svg
COPY assets/favicon.svg /opt/keycloak/themes/kb/admin/resources/favicon.svg
COPY --from=icons /work/favicon.ico /opt/keycloak/themes/kb/login/resources/img/favicon.ico
