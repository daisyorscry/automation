#!/usr/bin/env bash

ipv4_number() {
  local address="$1" octet number=0
  local -a octets
  [[ "$address" =~ ^(0|[1-9][0-9]{0,2})(\.(0|[1-9][0-9]{0,2})){3}$ ]] || return 1
  IFS=. read -r -a octets <<< "$address"
  for octet in "${octets[@]}"; do
    (( octet <= 255 )) || return 1
    number=$((number * 256 + octet))
  done
  printf '%s\n' "$number"
}

ipv4_in_block() {
  local address="$1" block="$2" low high prefix
  case "$block" in
    *-*)
      low="$(ipv4_number "${block%-*}")" || return 1
      high="$(ipv4_number "${block#*-}")" || return 1
      (( low <= address && address <= high ))
      ;;
    */*)
      low="$(ipv4_number "${block%/*}")" || return 1
      prefix="${block#*/}"
      [[ "$prefix" =~ ^(0|[1-9][0-9]?)$ ]] && (( prefix <= 32 )) || return 1
      (( address >> (32 - prefix) == low >> (32 - prefix) ))
      ;;
    *)
      low="$(ipv4_number "$block")" || return 1
      (( address == low ))
      ;;
  esac
}
