#!/bin/bash
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# Generated, self-contained installer; the same file is served over HTTP.
source "$source_dir/client-install.sh"
