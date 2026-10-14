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
