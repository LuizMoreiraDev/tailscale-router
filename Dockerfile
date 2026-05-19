# syntax=docker/dockerfile:1.7
FROM tailscale/tailscale:latest

ARG VERSION=dev
ARG BUILD_DATE
ARG VCS_REF

LABEL org.opencontainers.image.title="tailscale-router" \
      org.opencontainers.image.description="Tailscale subnet router with automatic iptables/forwarding/kernel-module setup. Self-contained: leaves no rules on the host when the container is removed." \
      org.opencontainers.image.authors="Luiz Moreira <https://luizmoreira.dev>" \
      org.opencontainers.image.source="https://github.com/LuizMoreiraDev/tailscale-router" \
      org.opencontainers.image.url="https://hub.docker.com/r/luizmoreiradev/tailscale-router" \
      org.opencontainers.image.documentation="https://github.com/LuizMoreiraDev/tailscale-router/blob/main/README.md" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${VCS_REF}"

# The official tailscale image is based on Alpine and already ships iptables and iproute2,
# but we install kmod explicitly for modprobe.
RUN apk add --no-cache iptables iproute2 kmod \
    && rm -f /usr/sbin/iptables /usr/sbin/ip6tables \
    && ln -s /usr/sbin/iptables-nft /usr/sbin/iptables \
    && ln -s /usr/sbin/ip6tables-nft /usr/sbin/ip6tables

COPY router-rules.sh /usr/local/bin/router-rules.sh
COPY entrypoint-wrapper.sh /usr/local/bin/entrypoint-wrapper.sh
RUN chmod +x /usr/local/bin/router-rules.sh /usr/local/bin/entrypoint-wrapper.sh

ENTRYPOINT ["/usr/local/bin/entrypoint-wrapper.sh"]
