{
    zon2json
    , writeShellApplication
    , jq
    , zig
    , curl
    , coreutils
    , findutils
    , nix-prefetch-git
}:

writeShellApplication {
    name = "zon2json-lock";
    runtimeInputs = [ zon2json jq zig curl findutils coreutils nix-prefetch-git ];
    text = ''
      # shellcheck disable=SC2059
      error() { printf -- "error: $1\n" "''${@:2}" 1>&2; exit 1; }

      path="''${1:-build.zig.zon}"
      if [[ ! -f "$path" ]]; then
          error 'file does not exist: %s' "$path"
      fi

      tmpdir="$(mktemp -d)"
      trap 'rm -rf "$tmpdir"' EXIT
      read -r zig_cache < <(zig env | jq -er '.global_cache_dir')

      split_git_url() {
        url_part="''${1##git+}"
        case "$1" in
          *#*)
            url="''${url_part%\#*}"
            rev="''${url_part##*\#}"
            printf -- "%s\n%s" "$url" "$rev"
            ;;
          *)
            printf -- "%s\n%s" "$url_part" "HEAD"
            ;;
        esac
      }

      zon2json-recursive() {
        while {
          read -r name;
          read -r url;
          read -r zhash;
        } do
          # Prevent dependency loop
          if [[ ! -f "$tmpdir/$zhash.read" ]]; then
            # do not zig fetch if we have the dep already
            if [[ ! -d "$zig_cache/p/$zhash" ]]; then
              printf -- 'fetching (zig fetch): %s\n' "$url" 1>&2
              case "$url" in
                file://*)
                  # workaround bug: https://github.com/ziglang/zig/issues/18549
                  mkdir -p "$tmpdir/tmp"
                  fname="$(cd "$tmpdir/tmp"; curl -sSL "$url" -O; find . -mindepth 1 -maxdepth 1 -type f)"
                  zhash2="$(zig fetch "$tmpdir/tmp/$fname" || true)"
                  rm -rf "$tmpdir/tmp"
                  ;;
                *)
                  zhash2="$(zig fetch "$url" || true)"
                  ;;
              esac
              if [[ ! "$zhash2" ]] || [[ "$zhash" != "$zhash2" ]]; then
                error 'unexpected zig hash, got: %s, expected: %s' "''${zhash2:-nothing}" "$zhash"
              fi
            fi

            # do not redownload artifact if we know its hash already
            # we can't just rely on the zhash because it may not change even though the artifact change
            old_url="$(jq -er --arg k "$zhash" '."\($k)".url' "''${path}2json-lock" 2>/dev/null || true)"
            if [[ ! "$old_url" ]] || [[ "$old_url" != "$url" ]]; then
              printf -- 'fetching (nix hash): %s\n' "$url" 1>&2
              case "$url" in
                git+http://*|git+https://*)
                  IFS=$'\n' read -rd "" git_url git_rev < <(split_git_url "$url") || true
                  ahash="$(nix-prefetch-git --out "$tmpdir/$zhash.git" \
                            --url "$git_url" --rev "$git_rev" \
                            --no-deepClone --quiet | jq -er '.hash')"
                  rm -rf "$tmpdir/$zhash.git"
                  ;;
                file://*|http://*|https://*)
                  curl -sSL "$url" -o "$tmpdir/$zhash.artifact"
                  ahash="$(nix hash file "$tmpdir/$zhash.artifact")"
                  rm -f "$tmpdir/$zhash.artifact"
                  ;;
                *)
                  error 'unsupported url: %s' "$url"
                  ;;
              esac
            else
              ahash="$(jq -er --arg k "$zhash" '."\($k)".hash' "''${path}2json-lock")"
            fi

            printf '{"%s":{"name":"%s","url":"%s","hash":"%s"}}\n' "$zhash" "$name" "$url" "$ahash"

            if [[ -f "$zig_cache/p/$zhash/build.zig.zon" ]]; then
              zon2json-recursive "$zig_cache/p/$zhash/build.zig.zon"
            fi

            touch "$tmpdir/$zhash.read"
          fi
        done < <(zon2json "$1" | jq -r '.dependencies | to_entries | .[] | select(.value.url != null) | .key, .value.url, .value.hash')
      }

      if ! jq -e '.dependencies[] | select(.url != null) | length > 0' <(zon2json "$path") >/dev/null; then
        printf -- '%s has no dependencies\n' "$path" 1>&2
        exit 0
      fi

      zon2json-recursive "$path" | jq -se add > "$tmpdir/build.zig.zon2json-lock"
      if [[ "''${2:-}" == "-" ]]; then
        jq . "$tmpdir/build.zig.zon2json-lock"
      else
        cp -f "$tmpdir/build.zig.zon2json-lock" "''${2:-''${path}2json-lock}"
      fi
      '';
}
