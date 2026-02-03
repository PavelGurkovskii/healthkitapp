#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFO_PLIST="$ROOT_DIR/ios/HealthKitApp/Info.plist"
XCODEPROJ="$ROOT_DIR/ios/HealthKitApp.xcodeproj"
SCHEME="HealthKitApp"
BUNDLE_ID="com.pavlohurkovskyi.healthkitapp"

UDID=""
NO_LAUNCH="0"
NGROK_AUTHTOKEN_OVERRIDE="${NGROK_AUTHTOKEN:-}"
TEAM_ID="${TEAM_ID:-}"

usage() {
  echo "Usage: $(basename "$0") [--udid <device_udid>] [--no-launch] [--ngrok-authtoken <token>] [--team <TEAM_ID>]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --udid)
      UDID="${2:-}"
      shift 2
      ;;
    --team)
      TEAM_ID="${2:-}"
      shift 2
      ;;
    --ngrok-authtoken)
      NGROK_AUTHTOKEN_OVERRIDE="${2:-}"
      shift 2
      ;;
    --no-launch)
      NO_LAUNCH="1"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

if [[ ! -f "$INFO_PLIST" ]]; then
  echo "Info.plist not found at: $INFO_PLIST"
  exit 1
fi

if [[ ! -d "$XCODEPROJ" ]]; then
  echo "Xcode project not found at: $XCODEPROJ"
  exit 1
fi

if ! command -v ngrok >/dev/null 2>&1; then
  echo "ngrok not found."
  if command -v brew >/dev/null 2>&1; then
    read -r -p "Install ngrok via Homebrew now? (brew install ngrok/ngrok/ngrok) [y/N]: " INSTALL_NGROK
    if [[ "${INSTALL_NGROK}" =~ ^[Yy]$ ]]; then
      brew install ngrok/ngrok/ngrok
    else
      echo "Aborting. Install manually: brew install ngrok/ngrok/ngrok"
      exit 1
    fi
  else
    echo "Homebrew (brew) not found. Install ngrok manually: https://ngrok.com/download"
    exit 1
  fi
fi

if ! command -v node >/dev/null 2>&1; then
  echo "node not found. Install Node.js first."
  exit 1
fi

if ! command -v npm >/dev/null 2>&1; then
  echo "npm not found. Install Node.js first."
  exit 1
fi

if [[ ! -d "$ROOT_DIR/backend/node_modules" ]]; then
  echo "backend/node_modules is missing."
  read -r -p "Run 'npm install' in backend now? [y/N]: " INSTALL_BACKEND_DEPS
  if [[ "${INSTALL_BACKEND_DEPS}" =~ ^[Yy]$ ]]; then
    (
      cd "$ROOT_DIR/backend"
      npm install
    )
  else
    echo "Aborting. You can run it manually: (cd backend && npm install)"
    exit 1
  fi
fi

BACKEND_PID=""
NGROK_PID=""
DERIVED_DIR=""

is_descendant_pid() {
  local child="$1"
  local ancestor="$2"

  if [[ -z "$child" || -z "$ancestor" ]]; then
    return 1
  fi

  while [[ -n "$child" && "$child" != "1" ]]; do
    if [[ "$child" == "$ancestor" ]]; then
      return 0
    fi
    child="$(ps -o ppid= -p "$child" 2>/dev/null | tr -d ' ' || true)"
  done

  return 1
}

kill_process_tree() {
  local root="$1"
  if [[ -z "$root" ]]; then
    return 0
  fi

  local children
  children="$(pgrep -P "$root" 2>/dev/null || true)"
  if [[ -n "$children" ]]; then
    while read -r c; do
      if [[ -n "$c" ]]; then
        kill_process_tree "$c"
        kill "$c" >/dev/null 2>&1 || true
      fi
    done <<< "$children"
  fi
}

cleanup() {
  if [[ -n "$NGROK_PID" ]]; then
    kill "$NGROK_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$BACKEND_PID" ]]; then
    kill_process_tree "$BACKEND_PID"
    kill "$BACKEND_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$DERIVED_DIR" && -d "$DERIVED_DIR" ]]; then
    rm -rf "$DERIVED_DIR" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT INT TERM

(
  cd "$ROOT_DIR/backend"
  npm start
) >"$ROOT_DIR/.backend.log" 2>&1 &
BACKEND_PID="$!"

BACKEND_OK="0"
for _ in {1..60}; do
  if ! kill -0 "$BACKEND_PID" >/dev/null 2>&1; then
    echo "Backend process exited during startup. See .backend.log"
    tail -n 80 "$ROOT_DIR/.backend.log" || true
    exit 1
  fi

  if command -v lsof >/dev/null 2>&1; then
    LISTEN_PID="$(lsof -nP -iTCP:3000 -sTCP:LISTEN -t 2>/dev/null | head -n 1 || true)"
    if [[ -n "$LISTEN_PID" && "$LISTEN_PID" != "$BACKEND_PID" ]]; then
      if ! is_descendant_pid "$LISTEN_PID" "$BACKEND_PID"; then
        echo "Port 3000 is already in use by PID $LISTEN_PID. Backend PID is $BACKEND_PID."
        echo "Stop the conflicting process and re-run. See .backend.log for details."
        tail -n 80 "$ROOT_DIR/.backend.log" || true
        exit 1
      fi
    fi
  fi

  if curl -sf "http://127.0.0.1:3000/ping" >/dev/null 2>&1; then
    BACKEND_OK="1"
    break
  fi
  sleep 0.25
done

if [[ "$BACKEND_OK" != "1" ]]; then
  echo "Backend did not start or /ping is not reachable. See .backend.log"
  tail -n 50 "$ROOT_DIR/.backend.log" || true
  exit 1
fi

NGROK_CONFIG_PATH="$HOME/Library/Application Support/ngrok/ngrok.yml"
if [[ -n "$NGROK_AUTHTOKEN_OVERRIDE" ]]; then
  NGROK_AUTHTOKEN_OVERRIDE="$(echo -n "$NGROK_AUTHTOKEN_OVERRIDE" | tr -d '\r\n' | sed -e 's/^[[:space:]]\+//' -e 's/[[:space:]]\+$//')"
  if [[ -z "$NGROK_AUTHTOKEN_OVERRIDE" ]]; then
    echo "Empty authtoken passed via --ngrok-authtoken / NGROK_AUTHTOKEN."
    exit 1
  fi
  if [[ "$NGROK_AUTHTOKEN_OVERRIDE" =~ [[:space:]] ]]; then
    echo "Invalid ngrok authtoken (contains whitespace)."
    echo "Make sure you paste only the token value from https://dashboard.ngrok.com/get-started/your-authtoken"
    exit 1
  fi
  if [[ "$NGROK_AUTHTOKEN_OVERRIDE" == .* || "$NGROK_AUTHTOKEN_OVERRIDE" == /* || "$NGROK_AUTHTOKEN_OVERRIDE" == ngrok* ]]; then
    echo "Invalid ngrok authtoken (looks like a command/path, not a token)."
    echo "Paste only the token value from https://dashboard.ngrok.com/get-started/your-authtoken"
    exit 1
  fi
  ngrok config add-authtoken "$NGROK_AUTHTOKEN_OVERRIDE" >/dev/null
fi
if [[ -f "$NGROK_CONFIG_PATH" ]]; then
  if ! grep -qE '^[[:space:]]*authtoken:[[:space:]]*[^[:space:]]+' "$NGROK_CONFIG_PATH"; then
    echo "ngrok is installed but authtoken is not configured."
    if [[ -n "$NGROK_AUTHTOKEN_OVERRIDE" ]]; then
      ngrok config add-authtoken "$NGROK_AUTHTOKEN_OVERRIDE" >/dev/null
    else
      if [[ -t 0 ]]; then
        read -r -s -p "Enter ngrok authtoken: " NGROK_AUTHTOKEN
        echo
        if [[ -z "${NGROK_AUTHTOKEN}" ]]; then
          echo "Empty authtoken. Aborting."
          exit 1
        fi
        ngrok config add-authtoken "$NGROK_AUTHTOKEN" >/dev/null
      else
        echo "No TTY available to prompt for ngrok authtoken."
        echo "Re-run with: ./run_device.sh --ngrok-authtoken <TOKEN>"
        echo "or set env var: NGROK_AUTHTOKEN=<TOKEN> ./run_device.sh"
        exit 1
      fi
    fi
  fi
else
  echo "ngrok config file not found: $NGROK_CONFIG_PATH"
  if [[ -n "$NGROK_AUTHTOKEN_OVERRIDE" ]]; then
    ngrok config add-authtoken "$NGROK_AUTHTOKEN_OVERRIDE" >/dev/null
  else
    if [[ -t 0 ]]; then
      read -r -s -p "Enter ngrok authtoken to initialize config: " NGROK_AUTHTOKEN
      echo
      if [[ -z "${NGROK_AUTHTOKEN}" ]]; then
        echo "Empty authtoken. Aborting."
        exit 1
      fi
      ngrok config add-authtoken "$NGROK_AUTHTOKEN" >/dev/null
    else
      echo "No TTY available to prompt for ngrok authtoken."
      echo "Re-run with: ./run_device.sh --ngrok-authtoken <TOKEN>"
      echo "or set env var: NGROK_AUTHTOKEN=<TOKEN> ./run_device.sh"
      exit 1
    fi
  fi
fi

ngrok http 3000 --log=stdout >"$ROOT_DIR/.ngrok.log" 2>&1 &
NGROK_PID="$!"

PUBLIC_URL=""
for _ in {1..200}; do
  TUNNELS_JSON="$(curl -sf "http://127.0.0.1:4040/api/tunnels" 2>/dev/null || true)"
  if [[ -n "$TUNNELS_JSON" ]]; then
    printf "%s" "$TUNNELS_JSON" > "$ROOT_DIR/.ngrok_tunnels.json" 2>/dev/null || true
  fi
  if [[ -n "$TUNNELS_JSON" ]]; then
    PUBLIC_URL="$(python3 -c 'import json,sys
data=json.load(sys.stdin)
for t in data.get("tunnels", []):
  u=t.get("public_url", "")
  proto=t.get("proto", "")
  if isinstance(u, str) and u.startswith("https://"):
    print(u); break
  if isinstance(proto, str) and proto=="https" and isinstance(u, str) and u:
    print(u); break
' <<<"$TUNNELS_JSON")"
    if [[ -n "$PUBLIC_URL" ]]; then
      break
    fi
  fi
  sleep 0.25
done

if [[ -z "$PUBLIC_URL" ]]; then
  echo "Failed to get ngrok public URL. See .ngrok.log"
  if grep -q "ERR_NGROK_105" "$ROOT_DIR/.ngrok.log" 2>/dev/null; then
    echo "ngrok authentication failed (ERR_NGROK_105)."
    echo "Fix: run again with a valid token: ./run_device.sh --ngrok-authtoken <TOKEN>"
    echo "Token source: https://dashboard.ngrok.com/get-started/your-authtoken"
  fi
  if [[ -f "$ROOT_DIR/.ngrok_tunnels.json" ]]; then
    echo "Last ngrok tunnels JSON saved to: $ROOT_DIR/.ngrok_tunnels.json"
    echo "Snippet:"
    head -c 800 "$ROOT_DIR/.ngrok_tunnels.json" || true
    echo
  fi
  tail -n 80 "$ROOT_DIR/.ngrok.log" || true
  exit 1
fi

/usr/libexec/PlistBuddy -c "Set :BackendBaseURL $PUBLIC_URL" "$INFO_PLIST" >/dev/null 2>&1 \
  || /usr/libexec/PlistBuddy -c "Add :BackendBaseURL string $PUBLIC_URL" "$INFO_PLIST" >/dev/null

echo "BackendBaseURL set to: $PUBLIC_URL"

if [[ -z "$UDID" ]]; then
  UDID="$(
    xcrun xctrace list devices 2>/dev/null \
      | awk -F'[()]' 'BEGIN{in_devices=0} /^== Devices ==/{in_devices=1; next} /^==/{in_devices=0} in_devices && /iPhone/ {print $(NF-1); exit}'
  )"
fi

if [[ -z "$UDID" ]]; then
  echo "Could not auto-detect a connected iPhone. Provide UDID via --udid <udid>."
  exit 1
fi

echo "Using device UDID: $UDID"

DERIVED_DIR="$(mktemp -d "/tmp/HealthKitAppDerivedData.XXXXXX")"

if [[ -z "$TEAM_ID" ]]; then
  echo "No Apple DEVELOPMENT_TEAM set. Required for signing on a physical device."
  echo "Provide it via: ./run_device.sh --team <TEAM_ID> ..."
  echo "or env var: TEAM_ID=<TEAM_ID> ./run_device.sh ..."
  echo "You can find TEAM_ID in Xcode: Settings -> Accounts -> (your team)"
  exit 1
fi

xcodebuild \
  -project "$XCODEPROJ" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination "id=$UDID" \
  -derivedDataPath "$DERIVED_DIR" \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  build

APP_PATH="$DERIVED_DIR/Build/Products/Debug-iphoneos/$SCHEME.app"
if [[ ! -d "$APP_PATH" ]]; then
  APP_PATH="$(find "$DERIVED_DIR" -type d -name "$SCHEME.app" -path "*/Debug-iphoneos/*" | head -n 1)"
fi

if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
  echo "Built app not found in DerivedData: $DERIVED_DIR"
  exit 1
fi

xcrun devicectl device install app --device "$UDID" "$APP_PATH"

if [[ "$NO_LAUNCH" != "1" ]]; then
  xcrun devicectl device process launch --device "$UDID" "$BUNDLE_ID" --terminate-existing --activate || true
fi

echo "Running. Press Ctrl-C to stop (this will stop backend and ngrok)."
wait "$BACKEND_PID" "$NGROK_PID"
