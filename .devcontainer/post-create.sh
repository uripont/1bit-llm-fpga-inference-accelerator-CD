#!/bin/bash
set -euo pipefail

# Heavy toolchain setup happens in the Docker image (dockerfile). This workspace hook only
# adds the expected course-style path as a symlink for convenience.
if [[ ! -e neorv32-setups ]]; then
    ln -s /opt/neorv32-setups neorv32-setups
fi
