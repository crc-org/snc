#!/bin/bash
set -exuo pipefail

SHELLCHECK=${SHELLCHECK:-shellcheck}

if ! "${SHELLCHECK}" -V; then
    if [[ ! -e SHELLCHECK ]]; then
        scversion="stable"
        curl -L "https://github.com/koalaman/shellcheck/releases/download/${scversion?}/shellcheck-${scversion?}.linux.x86_64.tar.xz" | tar -xJv
    fi
    SHELLCHECK="./shellcheck-${scversion}/shellcheck"
fi

${SHELLCHECK} -S error *.sh
