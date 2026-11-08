import "shared/output.just"

# Detects configuration drift against target infrastructure
[linux]
[no-cd]
[group('Verification & Diagnostics')]
drift profile:
  #!/usr/bin/env bash

  set -euo pipefail

  # Track overall status
  EQUAL="true"

  # Enable globstar to find files
  shopt -s globstar

  # Examine each configuration file.
  for FILE in servers/{{ profile }}/**/*.bu; do

    # Store all paths found in the current configuration file.
    readarray -t CONFIGFILES < <(yq -r '.storage.files[].path' "$FILE")

    # Examine each file found in the current configuration file.
    for CONFIGFILE in ${CONFIGFILES[@]}; do

      # Continue if file is ignored in .diffignore
      ! just -q is-file-ignored "$CONFIGFILE" || continue

      # Determine what kind of operation to perform. Overwrite the contents of the file or append to it.
      OVERWRITE=$(yq eval "(.storage.files[] | select(.path == \"$CONFIGFILE\") | has(\"contents\"))" "$FILE")
      APPEND=$(yq eval "(.storage.files[] | select(.path == \"$CONFIGFILE\") | has(\"append\"))" "$FILE")

      if [ "$OVERWRITE" == "true" ]; then
        just -q is-content-overwritten {{ profile }} "$FILE" "$CONFIGFILE" || EQUAL="false"
      elif [ "$APPEND" == "true" ]; then
        just -q is-content-appended {{ profile }} "$FILE" "$CONFIGFILE" || EQUAL="false"
      else
        just display-error "Unable to process file: $CONFIGFILE"
        EQUAL="false"
      fi
    done
  done

  # Disable globstar
  shopt -u globstar

  # Exit unsuccessfully if not equal
  if [ "$EQUAL" != "true" ]; then
    just display-error "Configuration drift has been detected."
    exit 1
  fi

# Lints butane file using yamllint.
[linux]
[no-cd]
[group('Verification & Diagnostics')]
lint:
  #!/usr/bin/env bash

  # Set up Bash script to exit on error, enforcing strict mode with `pipefail` option
  set -euo pipefail

  # Determine if yamllint is installed locally.
  HAS_YAMLLINT=1
  if which yamllint &>/dev/null; then
    HAS_YAMLLINT=0
  fi

  # Pull the yamllint docker image if yamllint is not installed.
  if [ $HAS_YAMLLINT -ne 0 ]; then
    podman pull -q docker.io/pipelinecomponents/yamllint:latest > /dev/null
  fi

  shopt -s globstar
  readarray -t BUTANE_FILES < <(ls -1 servers/**/*.bu 2>/dev/null | grep -v '\.enc\.bu$' | sort)

  if [ $HAS_YAMLLINT -ne 0 ]; then
    podman run --rm -v .:/code:z,ro docker.io/pipelinecomponents/yamllint:latest yamllint "${BUTANE_FILES[@]}"
  else
    yamllint "${BUTANE_FILES[@]}"
  fi

  echo "All butane files passed linting checks."

[linux]
[no-cd]
[private]
is-content-appended $SERVER $FILE $CONFIGFILE:
  #!/usr/bin/env bash

  set -euo pipefail

  # Unlike `contents`, `append` is an array. Store content that should have been appended to the file.
  readarray -t APPENDEDCONTENT < <(yq -r ".storage.files[] | select(.path == \"$CONFIGFILE\") | .append[].inline" "$FILE")

  # If there is content to append to the file, then proceed.
  if (( ${#APPENDEDCONTENT[@]} > 0 )); then
    # Check for existence of the file on the server. If necessary, use `sudo`.
    if ssh $SERVER "test -e '$CONFIGFILE' || sudo test -e '$CONFIGFILE'"; then

      # Iterate over appended content and determine if the server file contains it. If the content
      # is missing, then add it to the `MISSING_CONTENT` array for displaying later.
      MISSING_CONTENT=()
      for CONTENT in "${APPENDEDCONTENT[@]}"; do
        if ! printf "%s" "$CONTENT" | ssh $SERVER "grep -qFf - '$CONFIGFILE'"; then
          MISSING_CONTENT+=("$CONTENT")
        fi
      done

      # Diplay content missing from server file.
      if (( ${#MISSING_CONTENT[@]} > 0 )); then
        just display-error "Content missing from file: $CONFIGFILE"
        echo "Content:"
        echo "${MISSING_CONTENT[@]}"
        exit 1
      fi
    else
      just display-error "Unable to locate file on server: $CONFIGFILE"
      exit 1
    fi
  fi

  exit 0

[linux]
[no-cd]
[private]
is-content-overwritten $SERVER $FILE $CONFIGFILE:
  #!/usr/bin/env bash

  set -euo pipefail

  # Calculate checksum of file contents listed in the configuration file.
  CONTENT=$(yq -r ".storage.files[] | select(.path == \"$CONFIGFILE\") | .contents.inline // \"\"" "$FILE")

  # A file can be overwritten or appended. If `contents` have been provided then perform an equality
  # comparison of the contents of the file against the contents listed in the configuration file.
  if [ -n "$CONTENT" ]; then
    CONTENT_CSUM=$(sha256sum < <(echo "$CONTENT") | cut -d' ' -f1)

    # Check for existence of the file on the server. If necessary, use `sudo`.
    if ssh $SERVER "test -e '$CONFIGFILE' || sudo test -e '$CONFIGFILE'"; then

      # Calculate checksum of server content
      if SERVER_CSUM=$(ssh $SERVER "sha256sum '$CONFIGFILE' 2>/dev/null || sudo sha256sum '$CONFIGFILE'" | cut -d' ' -f1); then
        # Test checksums for equality. If not equal, generate a diff to illustrate the differences.
        if [ "$CONTENT_CSUM" != "$SERVER_CSUM" ]; then
          just display-error "Content differs for file: $CONFIGFILE"
          if ! printf "%s" "$CONTENT" | ssh $SERVER "sudo diff - '$CONFIGFILE' -" ; then
            echo "$DIFFERENCE"
            echo "Checksums: $CONTENT_CSUM (configuration), $SERVER_CSUM ($SERVER)"
            echo ""
            exit 1
          fi
        fi
      else
        just display-error "Unable to compute checksum for file: $CONFIGFILE"
        exit 1
      fi
    else
      just display-error "Unable to locate file on server: $CONFIGFILE"
      exit 1
    fi
  fi

  exit 0

[linux]
[no-cd]
[private]
is-file-ignored $FILE:
  #!/usr/bin/env bash

  set -euo pipefail

  while IFS= read -r line; do
    # Skip comments and empty lines
    [[ "$line" =~ ^# ]] && continue
    [ -z "$line" ] && continue

    # Remove leading/trailing whitespace
    line=$(echo "$line" | tr -d '[:space:]')

    # Skip exception patterns
    if [[ "$line" =~ ^! ]]; then
        continue
    fi

    # Convert pattern to regex
    # Handles: * (any number of characters), ? (single character), [a-z] (character classes)
    regex=$(echo "$line" | sed -E 's/\*\/\./\.\*\/\./g; s/\*\.*/\.\*\.txt/g; s/\?/./g; s/[\[\/\]]/\\&/g')

    # Check if file matches pattern (case-sensitive)
    if [[ "$FILE" =~ $regex ]]; then
        exit 0
    fi
  done < ".diffignore"

  exit 1
