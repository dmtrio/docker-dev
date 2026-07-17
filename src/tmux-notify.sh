#!/bin/bash
# tmux-notify.sh — agent-blind idle notifier (RFC 04 Phase B).
# Fired by tmux's alert-silence hook (armed in tmux.conf only when NTFY_URL
# is present): the pane produced no output for the monitor-silence window,
# which for an agent means "waiting at a prompt" or "finished". Deliberately
# knows nothing about WHICH agent runs in the pane — works for all of them.
#
# Suppression: if any client is attached you are already looking at the
# session — pushing would self-notify on every pause. Only push when nobody
# is watching.

[ -n "${NTFY_URL:-}" ] || exit 0

if [ "$(tmux list-clients 2>/dev/null | wc -l)" -gt 0 ]; then
    exit 0
fi

# Last non-blank pane lines give the push its context (the prompt/question).
TAIL=$(tmux capture-pane -p -t agent 2>/dev/null | grep -v '^[[:space:]]*$' | tail -n 3)

curl -s --max-time 10 \
    -H "Title: dev-agent-${CONTAINER_NAME:-container}: agent idle" \
    -H "Tags: robot" \
    -d "${TAIL:-<no recent output>}" \
    "${NTFY_URL%/}/${NTFY_TOPIC:-dev-agents}" >/dev/null || true

exit 0
