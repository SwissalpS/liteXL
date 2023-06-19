#!/bin/bash
set -e

if [ ! -e "src/api/api.h" ]; then
  echo "Please run this script from the root directory of Lite XL."; exit 1
fi

./build-packages.sh -P -d liteXL -r && mkdir liteXL/user;
