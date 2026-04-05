FROM debian:bookworm-slim

# Install packages
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    curl \
    git \
    build-essential \
    python3 \
    python3-pip \
    nodejs \
    npm \
    vim \
    openssh-client \
    jq \
    socat \
    sudo \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user (UID/GID will be remapped at runtime via entrypoint)
ARG USER_UID=1000
ARG USER_GID=1000
RUN groupadd -g $USER_GID coder && \
    useradd -m -u $USER_UID -g coder -d /home/coder -s /bin/bash coder && \
    echo "coder ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/coder && \
    mkdir -p /home/coder/.claude /home/coder/.local/bin && \
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

# Hook event logger: logs Claude Code hook events to JSONL for host-side access
COPY cleat-hook-logger /usr/local/bin/cleat-hook-logger
RUN chmod +x /usr/local/bin/cleat-hook-logger && \
    mkdir -p /var/log/cleat && chown coder:coder /var/log/cleat

# User-level CLAUDE.md (won't conflict with project-level CLAUDE.md files)
COPY CLAUDE.md /home/coder/.claude/CLAUDE.md
RUN chown coder:coder /home/coder/.claude/CLAUDE.md

# Entrypoint remaps UID/GID to match host, then drops to coder
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /workspace
ENTRYPOINT ["/entrypoint.sh"]
CMD ["bash"]
