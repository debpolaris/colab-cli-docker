#!/bin/sh
IMAGE="us-central1-docker.pkg.dev/mymain-506202/colab-cli/colab-cli:0.7.5-r2"
TTY=""
[ -t 0 ] && TTY="-t"
exec docker run --rm -i $TTY --memory=512m --memory-swap=512m -v colab-home:/home/colab "$IMAGE" "$@"
