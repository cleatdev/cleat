# v1.5.4's compute_config_fingerprint, copied literally from the tag and
# renamed, so a test can hold today's function to it. Every oracle that calls
# today's function instead cancels out any change that moves every box's hash,
# which is the change that would put a recreate prompt in front of every
# existing box after an upgrade. Its three helpers (_configured_box_memory,
# _configured_box_cpus, _md5) are unchanged since the tag.
#
# Regenerate with:
#   git show v1.5.4:bin/cleat | awk '/^compute_config_fingerprint\(\)/,/^}$/'
_fp_v154() {
  local project="${1:-}"
  local fingerprint_input=""

  # Caps (sorted)
  fingerprint_input+="caps:"
  if [[ ${#ACTIVE_CAPS[@]} -gt 0 ]]; then
    fingerprint_input+="$(printf '%s\n' "${ACTIVE_CAPS[@]}" | sort | tr '\n' ',')"
  fi
  fingerprint_input+=$'\n'

  # Env keys (sorted HERE, values excluded). We sort inside this function rather
  # than trust the caller's arg order: resolve_env_args happens to emit keys
  # sorted today, but folding that assumption in means a different ordering (a
  # refactor, a new env source) would silently change the hash and fire a false
  # "caps or env keys differ" drift notice on an otherwise-unchanged setup.
  fingerprint_input+="env-keys:"
  if [[ ${#_RESOLVED_ENV_ARGS[@]} -gt 0 ]]; then
    local _ekeys=""
    for arg in "${_RESOLVED_ENV_ARGS[@]}"; do
      [[ "$arg" == -e ]] && continue
      _ekeys+="${arg%%=*}"$'\n'
    done
    fingerprint_input+="$(printf '%s' "$_ekeys" | sort | tr '\n' ',')"
  fi
  fingerprint_input+=$'\n'

  # Resources: only what the user DECLARED in config (_configured_box_*), so an
  # explicit `[resources] memory = 8g` still triggers a recreate (the ceiling is
  # baked at `docker run`, not changeable on a live container) while an
  # unconfigured box stays stable across VM resizes and CLI upgrades. Never the
  # VM-derived default or the daemon-clamped cpus: those move underfoot and were
  # the source of the v0.16.4 false-positive recreate.
  fingerprint_input+="resources:memory=$(_configured_box_memory "$project" "${_BOX:-main}")"
  fingerprint_input+=$'\n'
  fingerprint_input+="resources:cpus=$(_configured_box_cpus "$project" "${_BOX:-main}")"
  fingerprint_input+=$'\n'

  if command -v sha256sum &>/dev/null; then
    echo -n "$fingerprint_input" | sha256sum | head -c 16
  else
    echo -n "$fingerprint_input" | _md5 | head -c 16
  fi
}
