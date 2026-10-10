ARG AGENTMEMORY_SOURCE_COMMIT=v0.9.30
ARG III_VERSION=0.22.1

FROM iiidev/iii:${III_VERSION} AS iii-image

FROM node:26-trixie AS builder

ARG AGENTMEMORY_SOURCE_COMMIT
ARG III_VERSION

RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /build
RUN git clone https://github.com/rohitg00/agentmemory.git . \
 && git checkout "${AGENTMEMORY_SOURCE_COMMIT}"
# Fail fast if the pinned commit's iii-sdk dependency drifts from the engine
# image pulled above — the worker speaks that engine's wire protocol, so a
# mismatch here means a cryptic runtime crash instead of a build-time error.
RUN pinned_sdk="$(node -p "require('./package.json').dependencies['iii-sdk']")" \
 && [ "$pinned_sdk" = "${III_VERSION}" ] \
 || { echo "pinned commit requires iii-sdk ${pinned_sdk}, but III_VERSION=${III_VERSION} was requested" >&2; exit 1; }
RUN npm install --no-fund --no-audit \
 && npm run build \
 && npm prune --omit=dev --omit=optional

FROM node:26-trixie

ARG III_VERSION

RUN apt-get update \
 && apt-get install -y --no-install-recommends openssl ca-certificates tini gosu curl \
 && rm -rf /var/lib/apt/lists/*

COPY --from=iii-image /app/iii /usr/local/bin/iii
RUN iii --version 2>&1 | grep -qF "${III_VERSION}" \
 || { echo "the iiidev/iii:${III_VERSION} image does not contain iii ${III_VERSION}" >&2; exit 1; }

WORKDIR /opt/agentmemory
COPY --from=builder /build/dist ./node_modules/@agentmemory/agentmemory/dist
COPY --from=builder /build/node_modules ./node_modules
COPY --from=builder /build/package.json ./node_modules/@agentmemory/agentmemory/package.json
RUN mkdir -p node_modules/.bin \
 && ln -s ../@agentmemory/agentmemory/dist/cli.mjs node_modules/.bin/agentmemory \
 && ln -s /opt/agentmemory/node_modules/.bin/agentmemory /usr/local/bin/agentmemory \
 && chmod +x node_modules/@agentmemory/agentmemory/dist/cli.mjs

ENV AGENTMEMORY_III_VERSION=${III_VERSION} \
    TINI_SUBREAPER=1

COPY --chmod=0755 entrypoint.sh /usr/local/bin/agentmemory-entrypoint.sh

EXPOSE 3111

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/agentmemory-entrypoint.sh"]
