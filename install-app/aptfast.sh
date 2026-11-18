#!/bin/sh
# Copyright (C) 2026 ZIT STUDIO
# Author: Oliver Lin <oliver@liuxiaozhen.dev>
# App-Maintainer: Oliver Lin <oliver@liuxiaozhen.dev>
# App-URL: https://git-scm.com/
# OS-repository: https://github.com/git/git
# SPDX-License-Identifier: AGPL-3.0-only

set -e

add-apt-repository ppa:apt-fast/stable
apt-get update
apt-get -y install apt-fast
