#!/bin/zsh
# Günlük bakım: listeyi yeniden üret, test et, gist'i güncelle. launchd tarafından çalıştırılır.
set -u
PROJECT_DIR="${0:A:h}"
LOG_DIR="$PROJECT_DIR/logs"
LOG_RETENTION_DAYS=14

export PATH="/opt/homebrew/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
mkdir -p "$LOG_DIR"
log_file="$LOG_DIR/$(date +%Y-%m-%d).log"

{
  echo "=== $(date '+%Y-%m-%d %H:%M:%S') başladı ==="
  "$PROJECT_DIR/.venv/bin/python" "$PROJECT_DIR/build_playlist.py" --publish
  echo "=== $(date '+%Y-%m-%d %H:%M:%S') bitti (çıkış kodu $?) ==="
} >> "$log_file" 2>&1

find "$LOG_DIR" -name '*.log' -mtime +$LOG_RETENTION_DAYS -delete
