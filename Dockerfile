FROM debian:bookworm-slim

ENV HOME=/root

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    openssh-client \
    ripgrep \
    fd-find \
    curl \
    jq \
    ca-certificates \
  && ln -s /usr/bin/fdfind /usr/bin/fd \
  && curl -fsSL https://claude.ai/install.sh | bash \
  && cp -aL /root/.local/bin/. /usr/local/bin/ \
  && GH_VERSION=$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest | jq -r .tag_name | sed 's/^v//') \
  && GH_ARCH=$(dpkg --print-architecture | sed 's/amd64/amd64/;s/arm64/arm64/') \
  && curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${GH_ARCH}.tar.gz" \
     | tar xz -C /usr/local --strip-components=1 "gh_${GH_VERSION}_linux_${GH_ARCH}/bin/gh" \
  && apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/*

ARG EXTRA_PACKAGES=""
RUN if [ -n "$EXTRA_PACKAGES" ]; then \
      apt-get update && apt-get install -y --no-install-recommends $EXTRA_PACKAGES \
      && apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/*; \
    fi

WORKDIR /work

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# PTY proxy: intercepts bracketed paste for image clipboard detection
COPY pty-proxy /usr/local/bin/pty-proxy
RUN chmod +x /usr/local/bin/pty-proxy

# Clipboard bridge: shim scripts that forward to host clipboard daemon
COPY clipboard-shim.sh /usr/local/bin/clipboard-shim
RUN chmod +x /usr/local/bin/clipboard-shim \
  && ln -sf clipboard-shim /usr/local/bin/xclip \
  && ln -sf clipboard-shim /usr/local/bin/xsel \
  && ln -sf clipboard-shim /usr/local/bin/wl-paste \
  && ln -sf clipboard-shim /usr/local/bin/wl-copy \
  && ln -sf clipboard-shim /usr/local/bin/pbpaste \
  && ln -sf clipboard-shim /usr/local/bin/pbcopy \
  && ln -sf clipboard-shim /usr/local/bin/pngpaste

ENTRYPOINT ["/entrypoint.sh"]
