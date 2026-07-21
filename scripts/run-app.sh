#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
zsh "$ROOT_DIR/scripts/build-app.sh"
open "$ROOT_DIR/dist/Agent Island.app"
