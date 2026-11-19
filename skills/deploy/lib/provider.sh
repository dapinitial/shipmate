#!/usr/bin/env bash
# provider.sh — which host deploys a project. Order: `provider:` in .shipmate.yml (explicit
# wins), then .do/app.yaml (DigitalOcean App Platform), then .vercel/project.json (Vercel).
# Prints do | vercel | none. Sourced by app.sh, preflight and deploy-card; tested.
provider_of() { # <dir>
  local d="${1%/}" p=""
  [ -f "$d/.shipmate.yml" ] && p="$(sed -nE 's/^provider:[[:space:]]*([a-z]+).*/\1/p' "$d/.shipmate.yml" | head -1)"
  case "$p" in do|digitalocean) echo do; return ;; vercel) echo vercel; return ;; esac
  if [ -f "$d/.do/app.yaml" ]; then echo do
  elif [ -f "$d/.vercel/project.json" ]; then echo vercel
  else echo none; fi
}

# The app a checkout deploys, so two checkouts of one app are known to be one app.
# do:<spec name> | vercel:<projectId> | dir:<path> when neither can be read.
provider_app_id() { # <dir>
  local d="${1%/}" id=""
  case "$(provider_of "$d")" in
    do) [ -f "$d/.do/app.yaml" ] && id="$(sed -nE 's/^name:[[:space:]]*([^[:space:]#]+).*/\1/p' "$d/.do/app.yaml" | head -1)"
        [ -n "$id" ] && { echo "do:$id"; return; } ;;
    vercel) [ -f "$d/.vercel/project.json" ] && id="$(sed -nE 's/.*"projectId"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$d/.vercel/project.json" | head -1)"
        [ -n "$id" ] && { echo "vercel:$id"; return; } ;;
  esac
  echo "dir:$d"
}

# exit 0 when the checkout's origin is the repo its host deploys from (DigitalOcean: the spec's
# github.repo; Vercel, whose project file names no repo: an origin exists at all).
provider_deploys_here() { # <dir>
  local d="${1%/}" origin spec
  origin="$(git -C "$d" remote get-url origin 2>/dev/null)" || return 1
  [ -n "$origin" ] || return 1
  case "$(provider_of "$d")" in
    do) spec="$(sed -nE 's/^[[:space:]]*repo:[[:space:]]*([^[:space:]#]+).*/\1/p' "$d/.do/app.yaml" 2>/dev/null | head -1)"
        [ -n "$spec" ] || return 0
        [ "$(printf '%s' "$origin" | sed -E 's#/*$##; s#\.git$##; s#^.*[:/]([^/:]+/[^/]+)$#\1#')" = "$spec" ] ;;
    *) return 0 ;;
  esac
}
