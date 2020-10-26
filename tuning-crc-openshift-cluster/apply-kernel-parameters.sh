#!/bin/bash

set -exuo pipefail

${SSH_CMD} sudo rpm-ostree kargs --append=transparent_hugepage=never
${SSH_CMD} sudo rpm-ostree kargs --append=vm.swappiness=30

