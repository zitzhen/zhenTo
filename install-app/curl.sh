#!/bin/sh
# Copyright (C) 2026 ZIT STUDIO
# Author: Oliver Lin <oliver@liuxiaozhen.dev>
# App-Maintainer: Oliver Lin <oliver@liuxiaozhen.dev>
# App-URL: https://curl.se/
# OS-repository: https://github.com/curl/curl
# SPDX-License-Identifier: AGPL-3.0-only

set -e

apt-get update
apt-get install -y curl
