#!/usr/bin/env bash
# Generate TestFlight "What to Test" notes from recent git history.
# Produces plain-language bullets for testers, not raw commit messages.
set -euo pipefail

limit="${1:-20}"
ref="${2:-HEAD}"

# Strip Conventional Commits prefix and optional scope: "feat(ios): foo" -> "foo"
strip_prefix() {
  printf '%s' "$1" | sed -E 's/^[a-zA-Z]+(\([^)]+\))?!?:[[:space:]]*//'
}

# True when the commit is internal/infrastructure and should not appear in tester notes.
is_internal_commit() {
  local raw="$1"
  local lower
  lower="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"

  # Skip any commit scoped to internal areas: feat(ci):, fix(build):, etc.
  if printf '%s' "$lower" | grep -Eq '^(feat|fix|perf|refactor|chore|build|test|style)\((ci|build|docs|chore|test)\)'; then
    return 0
  fi

  case "$lower" in
    ci:*|ci\(*|chore:*|chore\(*|docs:*|docs\(*|build:*|build\(*|test:*|test\(*|style:*|style\(*)
      return 0
      ;;
  esac

  case "$lower" in
    *github\ actions*|*workflow*|*paths-filter*|*xcodebuild*|*pbxproj*|*swift-format*)
      return 0
      ;;
    *typos*|*spell-check*|*checkout\ credential*|*pinned\ action*|*legal*|*security\ hygiene*)
      return 0
      ;;
    *oss\ legal*|*privacy\ policy*|*notices*|*subagent*|*claude*|*readme\ hero*)
      return 0
      ;;
    *signing\ secret*|*distribution\ signing*|*provisioning\ profile*|*asc\ api*)
      return 0
      ;;
    *app\ store\ connect\ api*|*manual\ distribution*|*automatic\ signing*)
      return 0
      ;;
    *build\ number\ to\ [0-9]*\ for\ testflight*|*create\ build/ios*|*release\ notes*)
      return 0
      ;;
  esac

  return 1
}

# Rewrite developer jargon into tester-friendly language.
humanize() {
  local msg="$1"
  local lower
  lower="$(printf '%s' "$msg" | tr '[:upper:]' '[:lower:]')"

  msg="$(printf '%s' "$msg" | sed -E 's/[[:space:]]*\(#[0-9]+\)[[:space:]]*$//')"
  msg="$(printf '%s' "$msg" | sed -E 's/[[:space:]]*\([a-f0-9]{7,}\)[[:space:]]*$//')"

  # Most-specific full replacements first (before broad partial matches).
  if [[ "$lower" == *live\ monitor\ milestone* || "$lower" == *testflight\ prep* ]]; then
    msg="Live monitoring improvements and media playback updates"
  elif [[ "$lower" == *media\ page* || "$lower" == *browse\ ·\ play* ]]; then
    msg="Media page to browse clips, play back footage, and export color looks"
  elif [[ "$lower" == *oauth\ upload* ]]; then
    msg="Upload clips to Frame.io from the Media page"
  elif [[ "$lower" == *wire\ the* || "$lower" == *settings\ to\ live\ state* ]]; then
    msg="Display and monitoring settings now apply to the live image immediately"
  elif [[ "$lower" == *shadow\ floor* || "$lower" == *reach\ crush* || "$lower" == *light\ fires* ]]; then
    msg="Waveform and scope displays show the full exposure range correctly"
  elif [[ "$lower" == *oom* || "$lower" == *out\ of\ memory* || "$lower" == *memory\ kill* ]]; then
    msg="Improved stability so live view uses less memory"
  elif [[ "$lower" == *actor\ boundary* || "$lower" == *scroll\ offset\ callback* ]]; then
    msg="Smoother scrolling in camera controls"
  elif [[ "$lower" == *night\ audit* || "$lower" == *hot-path* || "$lower" == *swiftui* ]]; then
    msg="General performance and stability improvements"
  elif [[ "$lower" == *imagecapturecore* || "$lower" == *usb-c\ transport* ]]; then
    msg="Connect to your camera over USB-C"
  elif [[ "$lower" == *codec-aware\ iso* || "$lower" == *iso\ picker* ]]; then
    msg="ISO picker now adapts to your recording codec"
  elif [[ "$lower" == *r3d\ ne\ recording\ lock* ]]; then
    msg="Recording settings lock correctly for R3D NE codec"
  elif [[ "$lower" == *meter\ scopes* || "$lower" == *assist\ bake* || "$lower" == *clean\ live\ frame* ]]; then
    msg="Exposure meters and scopes now read from the clean live image"
  elif [[ "$lower" == *landscape-only\ ipad* || "$lower" == *full\ screen* && "$lower" == *ipad* ]]; then
    msg="iPad layout works correctly in landscape"
  elif [[ "$lower" == *operator\ setup* ]]; then
    msg="Redesigned the operator setup screen"
  elif [[ "$lower" == *shutter\ angle* || "$lower" == *shutter\ speed* || "$lower" == *recenter* || "$lower" == *tracking* ]]; then
    msg="Camera control fixes for shutter, recenter, and subject tracking"
  elif [[ "$lower" == *remaining-time* || "$lower" == *readout* ]]; then
    msg="More accurate camera status readouts and recording time remaining"
  elif [[ "$lower" == *desync* ]]; then
    msg="Live preview recovers automatically if the first frame fails to load"
  elif [[ "$lower" == *apple\ distribution* || "$lower" == *testflight\ archive* ]]; then
    msg=""
  else
    if [[ "$lower" == *ptp-ip* || "$lower" == *ptp\ ip* ]]; then
      msg="$(printf '%s' "$msg" | sed -E 's/PTP-IP|PTP IP|ptp-ip|ptp ip/camera connection/gi')"
    fi
    if [[ "$lower" == *live\ monitor* || "$lower" == *live-view* || "$lower" == *live\ view* ]]; then
      msg="$(printf '%s' "$msg" | sed -E 's/live[- ]view/live preview/gi')"
      msg="$(printf '%s' "$msg" | sed -E 's/live monitor/live monitoring/gi')"
    fi
    if [[ "$lower" == *view\ assist* || "$lower" == *view-assist* ]]; then
      msg="$(printf '%s' "$msg" | sed -E 's/view[- ]assist/on-screen monitoring tools/gi')"
    fi
    if [[ "$lower" == *lut* ]]; then
      msg="$(printf '%s' "$msg" | sed -E 's/LUT/color look/gi')"
    fi
    if [[ "$lower" == *scopes* || "$lower" == *waveform* || "$lower" == *parade* ]]; then
      msg="$(printf '%s' "$msg" | sed -E 's/scopes/exposure scopes/gi')"
    fi
  fi

  msg="$(printf '%s' "$msg" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]*\.$//')"
  if [[ -n "$msg" ]]; then
    local first rest
    first="$(printf '%s' "${msg:0:1}" | tr '[:lower:]' '[:upper:]')"
    rest="${msg:1}"
    msg="${first}${rest}"
    msg="$(printf '%s' "$msg" | sed 's/^IPad/iPad/')"
  fi

  printf '%s' "$msg"
}

# Classify a commit for grouping: new | fixed | improved
classify() {
  local raw="$1"
  local lower
  lower="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"

  case "$lower" in
    fix:*|fix\(*|bugfix:*|bugfix\(*)
      printf 'fixed'
      ;;
    feat:*|feat\(*)
      printf 'new'
      ;;
    perf:*|perf\(*)
      printf 'improved'
      ;;
    *)
      case "$lower" in
        fix\ *|fixed\ *|bug\ *|*crash*|*recover*|*avoid\ *|*stop\ *|*require\ *)
          printf 'fixed'
          ;;
        *)
          printf 'new'
          ;;
      esac
      ;;
  esac
}

normalize_key() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/ /g; s/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g'
}

# Dedupe helper: returns 0 if key already seen.
seen_keys=""
is_duplicate() {
  local key="$1"
  local padded
  padded=" ${key} "
  case " ${seen_keys} " in
    *"${padded}"*) return 0 ;;
  esac
  seen_keys="${seen_keys} ${key} "
  return 1
}

new_items=""
fixed_items=""
improved_items=""

append_item() {
  local bucket="$1"
  local line="$2"
  case "$bucket" in
    new) new_items="${new_items}${line}"$'\n' ;;
    fixed) fixed_items="${fixed_items}${line}"$'\n' ;;
    improved) improved_items="${improved_items}${line}"$'\n' ;;
  esac
}

while IFS= read -r raw; do
  [[ -z "${raw// }" ]] && continue
  if is_internal_commit "$raw"; then
    continue
  fi

  stripped="$(strip_prefix "$raw")"
  human="$(humanize "$stripped")"
  [[ -z "${human// }" ]] && continue

  key="$(normalize_key "$human")"
  if is_duplicate "$key"; then
    continue
  fi

  bucket="$(classify "$raw")"
  append_item "$bucket" "$human"
done < <(git log --pretty=format:"%s" -"${limit}" "${ref}")

print_section() {
  local title="$1"
  local items="$2"
  [[ -z "${items// }" ]] && return

  printf '%s\n' "$title"
  while IFS= read -r item; do
    [[ -z "${item// }" ]] && continue
    printf -- '- %s\n' "$item"
  done <<< "$items"
  printf '\n'
}

printf 'What'\''s new in this build\n\n'

if [[ -z "${new_items// }" && -z "${fixed_items// }" && -z "${improved_items// }" ]]; then
  printf -- '- General updates and improvements since the last TestFlight build\n\n'
else
  print_section "New" "$new_items"
  print_section "Fixed" "$fixed_items"
  print_section "Improved" "$improved_items"
fi

suggestions=""
seen_suggestions=""

add_suggestion() {
  local text="$1"
  local key
  key="$(normalize_key "$text")"
  local padded=" ${key} "
  case " ${seen_suggestions} " in
    *"${padded}"*) return ;;
  esac
  seen_suggestions="${seen_suggestions} ${key} "
  suggestions="${suggestions}${text}"$'\n'
}

all_text="${new_items}${fixed_items}${improved_items}"
all_lower="$(printf '%s' "$all_text" | tr '[:upper:]' '[:lower:]')"

case "$all_lower" in
  *live\ preview*|*live\ monitoring*|*camera\ preview*|*live\ view*)
    add_suggestion "Connect to your Nikon Z camera and confirm the live preview is smooth and stable"
    ;;
esac
case "$all_lower" in
  *scope*|*waveform*|*histogram*|*meter*|*exposure*)
    add_suggestion "Open monitoring tools (waveform, histogram, scopes) and verify they track the image"
    ;;
esac
case "$all_lower" in
  *settings*|*operator\ setup*|*view\ assist*|*on-screen\ monitoring*)
    add_suggestion "Try changing display and monitoring settings — confirm they apply to the live image"
    ;;
esac
case "$all_lower" in
  *media*|*playback*|*frame.io*|*export*|*color\ look*)
    add_suggestion "Browse recorded clips on the Media page and try playback or export"
    ;;
esac
case "$all_lower" in
  *usb-c*|*usb\ c*)
    add_suggestion "If you have a USB-C connection, try connecting the camera that way"
    ;;
esac
case "$all_lower" in
  *iso*|*codec*|*recording*|*shutter*|*tracking*|*recenter*)
    add_suggestion "Adjust recording settings (ISO, shutter, codec) and confirm the camera responds"
    ;;
esac
case "$all_lower" in
  *ipad*|*landscape*|*layout*)
    add_suggestion "On iPad, rotate to landscape and check that the layout fills the screen"
    ;;
esac
case "$all_lower" in
  *memory*|*stability*|*performance*|*recover*)
    add_suggestion "Leave live preview running for a few minutes to check for crashes or slowdowns"
    ;;
esac

if [[ -z "${suggestions// }" ]]; then
  add_suggestion "Connect to your camera and walk through live preview, recording controls, and settings"
fi
add_suggestion "Report anything that crashes, freezes, or looks wrong compared to the last build"

printf 'Please test\n'
while IFS= read -r suggestion; do
  [[ -z "${suggestion// }" ]] && continue
  printf -- '- %s\n' "$suggestion"
done <<< "$suggestions"
