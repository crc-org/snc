#!/bin/bash

set -x

export AVAR="kaludios"
envsubst '${AVAR}' < machine.sh

