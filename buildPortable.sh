#!/bin/bash
set -e

if [ ! -e "src/api/api.h" ]; then
  echo "Please run this script from the root directory of Lite XL."; exit 1
fi

rm -fr buildXL;
./scripts/build.sh -P -r -b buildXL && mv buildXL/lite-xl buildXL/liteXL && mv buildXL/liteXL/lite-xl buildXL/liteXL/liteXL && mkdir buildXL/liteXL/user && cp -r user/* buildXL/liteXL/user/

