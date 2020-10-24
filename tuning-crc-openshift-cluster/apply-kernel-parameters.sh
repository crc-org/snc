#!/bin/bash

set -exuo pipefail

${SSH_CMD} sudo grubby --update-kernel=ALL --args="transparent_hugepage=never "
${SSH_CMD} sudo grubby --update-kernel=ALL --args="vm.swappiness=30"
