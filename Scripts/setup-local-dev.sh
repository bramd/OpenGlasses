#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Last commit that still tracked OpenGlasses.xcodeproj (with DEVELOPMENT_TEAM + entitlements),
# i.e. the merge right before the XcodeGen migration. `--from-commit` recovers personal
# signing config from here. Stays valid permanently (git history is immutable).
DEFAULT_COMMIT=4a7011f70ab74c2ad5924aadb39b1cae357243be

development_team_from_commit() {
  local commit="$1"
  git show "$commit:OpenGlasses.xcodeproj/project.pbxproj" 2>/dev/null \
    | grep 'DEVELOPMENT_TEAM =' \
    | sed 's/.*= //;s/;//' \
    | sort \
    | uniq -c \
    | sort -rn \
    | head -1 \
    | awk '{print $2}'
}

write_project_local_yml() {
  local team="$1"
  local app_bundle="${2:-com.openglasses.app}"
  local widget_bundle="${3:-com.openglasses.app.GlassesActivityWidget}"
  cat > project.local.yml <<EOF
options:
  developmentTeam: ${team}

targets:
  OpenGlasses:
    settings:
      base:
        CODE_SIGN_ENTITLEMENTS: Config/Entitlements/Personal/OpenGlasses.entitlements
        DEVELOPMENT_TEAM: ${team}
        # By default the app builds from the committed OpenGlasses/Info.plist so new
        # usage-description keys can never go stale in a personal copy (that caused an
        # App Store ITMS-90683 "missing NSLocationAlwaysAndWhenInUseUsageDescription").
        # ONLY rebranders (custom bundle id / display name) need a personal plist —
        # uncomment the next line and keep Config/Info/Info.personal.plist in sync with
        # OpenGlasses/Info.plist by hand:
        #   INFOPLIST_FILE: Config/Info/Info.personal.plist
        PRODUCT_BUNDLE_IDENTIFIER: ${app_bundle}

  GlassesActivityWidget:
    settings:
      base:
        CODE_SIGN_ENTITLEMENTS: Config/Entitlements/Personal/GlassesActivityWidget.entitlements
        DEVELOPMENT_TEAM: ${team}
        PRODUCT_BUNDLE_IDENTIFIER: ${widget_bundle}

  # The remaining signed targets need a team as well, or a command-line device build fails on
  # them ("Signing for X requires a development team"). Xcode's GUI hides this by filling the
  # team in automatically, so the gap only surfaces in CI or a headless
  # \`xcodebuild -destination 'platform=iOS,...'\`. They keep the committed entitlements —
  # their only capability is the shared app group, which any team can sign.
  OpenGlassesShareExtension:
    settings:
      base:
        DEVELOPMENT_TEAM: ${team}

  OpenGlassesWatch:
    settings:
      base:
        DEVELOPMENT_TEAM: ${team}

  OpenGlassesWatchWidget:
    settings:
      base:
        DEVELOPMENT_TEAM: ${team}
EOF
}

bundle_ids_from_commit() {
  local commit="$1"
  local pbx
  pbx="$(git show "$commit:OpenGlasses.xcodeproj/project.pbxproj" 2>/dev/null)" || return 1
  local app widget
  app="$(printf '%s\n' "$pbx" | grep 'PRODUCT_BUNDLE_IDENTIFIER = com\.' | grep -v watchkitapp | grep -v '\.tests' | grep -v GlassesActivityWidget | head -1 | sed 's/.*= //;s/;//')"
  widget="$(printf '%s\n' "$pbx" | grep 'GlassesActivityWidget' | grep PRODUCT_BUNDLE_IDENTIFIER | head -1 | sed 's/.*= //;s/;//')"
  printf '%s\n%s\n' "$app" "$widget"
}

restore_from_commit() {
  local commit="$1"
  mkdir -p Config/Entitlements/Personal Config/Info

  git show "$commit:OpenGlasses/OpenGlasses.entitlements" > Config/Entitlements/Personal/OpenGlasses.entitlements
  git show "$commit:GlassesActivityWidget/GlassesActivityWidget.entitlements" > Config/Entitlements/Personal/GlassesActivityWidget.entitlements
  # Seed the (opt-in, rebrand-only) personal Info.plist from the CURRENT committed plist, not the
  # old signing-recovery commit — otherwise it starts life missing every key added since.
  cp OpenGlasses/Info.plist Config/Info/Info.personal.plist

  local team
  team="$(development_team_from_commit "$commit")"
  if [[ -z "$team" ]]; then
    echo "Could not read DEVELOPMENT_TEAM from $commit" >&2
    exit 1
  fi
  local app_bundle widget_bundle
  read -r app_bundle widget_bundle < <(bundle_ids_from_commit "$commit")
  write_project_local_yml "$team" "$app_bundle" "$widget_bundle"

  echo "Restored from $commit:"
  echo "  project.local.yml (team ${team})"
  echo "  Config/Entitlements/Personal/*.entitlements"
  echo "  Config/Info/Info.personal.plist"
}

if [[ "${1:-}" == "--from-commit" ]]; then
  restore_from_commit "${2:-$DEFAULT_COMMIT}"
else
  if [[ ! -f project.local.yml ]]; then
    cp project.local.yml.example project.local.yml
    echo "Created project.local.yml — set developmentTeam to your Apple Team ID"
  fi

  mkdir -p Config/Entitlements/Personal
  for f in Config/Entitlements/Personal/*.entitlements.example; do
    [[ -f "$f" ]] || continue
    out="${f%.example}"
    if [[ ! -f "$out" ]]; then
      cp "$f" "$out"
      echo "Created $out"
    fi
  done
fi

./Scripts/generate-xcodeproj.sh
