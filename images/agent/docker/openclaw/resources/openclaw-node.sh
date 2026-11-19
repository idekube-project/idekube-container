# Prefer the OpenClaw Node 24 runtime over agent-base's Node 22.
# claude/opencode remain on PATH via $NVM_DIR/current (later in PATH).
export NVM_DIR=${NVM_DIR:-/usr/local/nvm}
if [ -d "$NVM_DIR/openclaw-node" ]; then
    case ":$PATH:" in
        *":$NVM_DIR/openclaw-node:"*) ;;
        *) export PATH="$NVM_DIR/openclaw-node:$PATH" ;;
    esac
fi
