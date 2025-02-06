#!/bin/bash
set -exuo pipefail

SHELLCHECK=${SHELLCHECK:-shellcheck}

if ! "${SHELLCHECK}" -V; then
    if [[ ! -e SHELLCHECK ]]; then
        scversion="stable"
        arch=$(uname -m)
        curl -L "https://github.com/koalaman/shellcheck/releases/download/${scversion?}/shellcheck-${scversion?}.linux.${arch}.tar.xz" | tar -xJv
    fi
    SHELLCHECK="./shellcheck-${scversion}/shellcheck"
fi

${SHELLCHECK} -S error *.sh
