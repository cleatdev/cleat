FROM node:20-bookworm-slim

# Install packages (node/npm pre-installed in base image)
# gh: GitHub CLI from official apt repo
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    bash \
    curl \
    git \
    python3 \
    python3-pip \
    openssh-client \
    jq \
    socat \
    sudo \
    ca-certificates \
    gpg && \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | gpg --dearmor -o /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends gh && \
    apt-get purge -y gpg && \
    apt-get autoremove -y && \
    rm -rf /var/lib/apt/lists/*

# Create non-root user (UID/GID will be remapped at runtime via entrypoint)
# node:20-bookworm-slim ships with node:node at 1000:1000 — remove it first
ARG USER_UID=1000
ARG USER_GID=1000
RUN userdel -r node 2>/dev/null || true && \
    groupdel node 2>/dev/null || true && \
    groupadd -g $USER_GID coder && \
    useradd -m -u $USER_UID -g coder -d /home/coder -s /bin/bash coder && \
    echo "coder ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/coder && \
    mkdir -p /home/coder/.claude /home/coder/.local/bin /home/coder/.config/gh && \
    chown -R coder:coder /home/coder

# Install Claude Code CLI as coder user (native installer)
USER coder
ENV HOME=/home/coder
RUN curl -fsSL https://claude.ai/install.sh | bash && \
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> /home/coder/.bashrc
USER root

# Clipboard: shims for standard commands (file bridge primary, OSC 52 fallback)
COPY clip /usr/local/bin/clip
COPY clip-daemon /usr/local/bin/clip-daemon
RUN chmod +x /usr/local/bin/clip /usr/local/bin/clip-daemon && \
    ln -s clip /usr/local/bin/pbcopy && \
    ln -s clip /usr/local/bin/xclip && \
    ln -s clip /usr/local/bin/xsel

# Browser bridge: forward URLs to the host browser
COPY open-bridge /usr/local/bin/open-bridge
RUN chmod +x /usr/local/bin/open-bridge && \
    ln -sf open-bridge /usr/local/bin/open && \
    ln -sf open-bridge /usr/local/bin/xdg-open && \
    ln -sf open-bridge /usr/local/bin/sensible-browser

# Hook event forwarder directory (used when hooks capability is active)
RUN mkdir -p /var/log/cleat && chown coder:coder /var/log/cleat

# User-level CLAUDE.md (won't conflict with project-level CLAUDE.md files)
COPY CLAUDE.md /home/coder/.claude/CLAUDE.md
RUN chown coder:coder /home/coder/.claude/CLAUDE.md

# Entrypoint remaps UID/GID to match host, then drops to coder
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /workspace
ENTRYPOINT ["/entrypoint.sh"]
CMD ["bash"]
