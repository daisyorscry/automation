#!/usr/bin/env bash

# Gateway hostnames may have a single wildcard as the leftmost DNS label.
valid_gateway_hostname() {
  local hostname="${1:-}" label
  local -a labels
  [[ ${#hostname} -le 253 ]] || return 1
  hostname="${hostname#\*.}"
  [[ "$hostname" == *.* && "$hostname" != *.test ]] || return 1
  IFS=. read -r -a labels <<< "$hostname"
  for label in "${labels[@]}"; do
    [[ ${#label} -le 63 && "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
  done
  [[ "$hostname" != *. && "$hostname" != *$'\n'* ]]
}
