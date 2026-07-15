FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=America/Chicago

# ── Build args ────────────────────────────────────────────────────────────────
ARG USERNAME=coder
ARG USER_UID=1000
ARG USER_GID=1000
ARG AUTHORIZED_KEY=""
ARG INSTALL_CLAUDE="true"
ARG INSTALL_PI="true"
ARG INSTALL_GEMINI="true"
ARG INSTALL_CURSOR="true"
ARG INSTALL_AIDER="true"
ARG INSTALL_CODEX="true"
ARG INSTALL_SSH="true"

# ── System packages ───────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y \
    # Core utilities
    curl wget git git-lfs sudo \
    # Build tools
    build-essential pkg-config \
    # Python
    python3 python3-pip python3-venv \
    # Search / file tools
    ripgrep fd-find jq unzip zip \
    # GitHub CLI deps
    ca-certificates gnupg \
    && rm -rf /var/lib/apt/lists/*

# ── Python packages ──────────────────────────────────────────────────────────
# --break-system-packages: Ubuntu 24.04 marks Python as externally managed
# (PEP 668). Safe to override here — the container is the isolation layer.
RUN pip3 install pipenv playwright --break-system-packages

# ── GitHub CLI ────────────────────────────────────────────────────────────────
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

# ── Gitea CLI (tea) ──────────────────────────────────────────────────────────
RUN curl -fsSL "https://dl.gitea.com/tea/0.9.2/tea-0.9.2-linux-$(dpkg --print-architecture)" -o /usr/local/bin/tea \
    && chmod +x /usr/local/bin/tea

# ── Create non-root user ──────────────────────────────────────────────────────
RUN userdel -r ubuntu 2>/dev/null || true \
    && groupadd --gid $USER_GID $USERNAME 2>/dev/null || true \
    && useradd --uid $USER_UID --gid $USER_GID -m -s /bin/bash $USERNAME \
    && echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# ── User .ssh dir (server + keys handled in the SSH block near EOF) ──────────
RUN mkdir -p /home/$USERNAME/.ssh \
    && chmod 700 /home/$USERNAME/.ssh \
    && chown -R $USERNAME:$USERNAME /home/$USERNAME/.ssh

# ── fnm (Fast Node Manager) ───────────────────────────────────────────────────
USER $USERNAME

RUN curl -fsSL https://fnm.vercel.app/install | bash -s -- --install-dir /home/$USERNAME/.fnm

# Add fnm to bash profile so it works in interactive AND non-interactive shells
RUN echo '' >> /home/$USERNAME/.bashrc \
    && echo '# fnm' >> /home/$USERNAME/.bashrc \
    && echo 'export PATH="/home/$USERNAME/.fnm:$PATH"' >> /home/$USERNAME/.bashrc \
    && echo 'eval "$(fnm env --use-on-cd --shell bash)"' >> /home/$USERNAME/.bashrc \
    # Also add to .bash_profile for SSH login shells
    && echo '' >> /home/$USERNAME/.bash_profile \
    && echo 'source ~/.bashrc' >> /home/$USERNAME/.bash_profile

# Install a default LTS node (projects can override via .node-version)
ENV PATH="/home/coder/.local/bin:/home/coder/.fnm:$PATH"
RUN eval "$(fnm env)" && fnm install --lts && fnm use lts-latest

# ── uv (Python package manager) ──────────────────────────────────────────────
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

# ── AI tools (toggled via build args) ────────────────────────────────────────
RUN if [ "$INSTALL_CLAUDE" = "true" ]; then \
        eval "$(fnm env)" && npm install -g @anthropic-ai/claude-code; \
    fi

# pi ships an interactive installer (pi.dev/install.sh) that just wraps this
# npm package — install it directly for non-TTY builds
RUN if [ "$INSTALL_PI" = "true" ]; then \
        eval "$(fnm env)" && npm install -g @earendil-works/pi-coding-agent; \
    fi

RUN if [ "$INSTALL_GEMINI" = "true" ]; then \
        eval "$(fnm env)" && npm install -g @google/gemini-cli; \
    fi

# Installs to ~/.local/share/cursor-agent, symlinks into ~/.local/bin (on PATH)
RUN if [ "$INSTALL_CURSOR" = "true" ]; then \
        curl -fsSL https://cursor.com/install | bash; \
    fi

RUN if [ "$INSTALL_AIDER" = "true" ]; then \
        pip3 install aider-chat --break-system-packages; \
    fi

# OpenAI Codex CLI (ChatGPT command line)
RUN if [ "$INSTALL_CODEX" = "true" ]; then \
        eval "$(fnm env)" && npm install -g @openai/codex; \
    fi

# ── Agent-identity shims ──────────────────────────────────────────────────────
# Each agent CLI is fronted by a shim that loads per-agent MCP credentials
# from ~/.agent-keys/(common|<agent>).env, OVERRIDING inherited env, then
# execs the real binary. This gives per-agent identity (attribution in tools
# like Obsidian Annotated) and makes delegation safe: an agent spawning
# another never passes its own credentials along.
RUN mkdir -p /home/$USERNAME/.agent-shims && \
    for a in claude pi gemini cursor-agent codex; do \
        printf '#!/bin/bash\nAGENT=%s\nKEYS="$HOME/.agent-keys"\nset -a\n[ -f "$KEYS/common.env" ] && . "$KEYS/common.env"\n[ -f "$KEYS/$AGENT.env" ] && . "$KEYS/$AGENT.env"\nset +a\nREAL=$(type -aP %s | grep -v ".agent-shims" | head -1)\n[ -n "$REAL" ] || { echo "%s is not installed in this container" >&2; exit 127; }\nexec "$REAL" "$@"\n' "$a" "$a" "$a" > /home/$USERNAME/.agent-shims/$a && \
        chmod +x /home/$USERNAME/.agent-shims/$a; \
    done && \
    echo '' >> /home/$USERNAME/.bashrc && \
    echo '# agent-identity shims must win over the real binaries' >> /home/$USERNAME/.bashrc && \
    echo 'export PATH="$HOME/.agent-shims:$PATH"' >> /home/$USERNAME/.bashrc

# ── Workspace ─────────────────────────────────────────────────────────────────
RUN sudo mkdir -p /workspace && sudo chown $USERNAME:$USERNAME /workspace

WORKDIR /workspace

# ── Entrypoint ────────────────────────────────────────────────────────────────
COPY --chown=$USERNAME:$USERNAME entrypoint.sh /home/$USERNAME/entrypoint.sh
RUN chmod +x /home/$USERNAME/entrypoint.sh

# Back to root for the entrypoint (drops to coder context / runs sshd)
USER root

# ── Egress firewall (init-firewall.sh, run by entrypoint) ────────────────────
# Needs NET_ADMIN + NET_RAW at runtime. Kept late in the file for layer cache.
RUN apt-get update && apt-get install -y \
    iptables ipset iproute2 dnsutils aggregate \
    && rm -rf /var/lib/apt/lists/*

COPY init-firewall.sh /usr/local/bin/init-firewall.sh
RUN chmod +x /usr/local/bin/init-firewall.sh

# ── SSH server (optional — remote-parity builds) ─────────────────────────────
# Kept at the end of the file so INSTALL_SSH=true/false share all layers above.
RUN if [ "$INSTALL_SSH" = "true" ]; then \
        apt-get update && apt-get install -y openssh-server \
        && rm -rf /var/lib/apt/lists/* \
        && mkdir -p /var/run/sshd \
        && sed -i \
            -e 's/#PasswordAuthentication yes/PasswordAuthentication no/' \
            -e 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' \
            -e 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' \
            /etc/ssh/sshd_config \
        && echo "AllowUsers $USERNAME" >> /etc/ssh/sshd_config \
        && if [ -n "$AUTHORIZED_KEY" ]; then \
            echo "$AUTHORIZED_KEY" > /home/$USERNAME/.ssh/authorized_keys \
            && chmod 600 /home/$USERNAME/.ssh/authorized_keys \
            && chown $USERNAME:$USERNAME /home/$USERNAME/.ssh/authorized_keys; \
        fi; \
    fi

ENV SSH_ENABLED=$INSTALL_SSH

# VS Code / Cursor "Attach to Running Container" reads this: attach as
# coder (not root) and open /workspace by default.
LABEL devcontainer.metadata='{"remoteUser":"coder","workspaceFolder":"/workspace"}'

EXPOSE 22

ENTRYPOINT ["/home/coder/entrypoint.sh"]
