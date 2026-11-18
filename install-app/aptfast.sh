#!/bin/sh
# Copyright (C) 2026 ZIT STUDIO
# Author: freedom-323 <long.hummingbird.wivo@mask.me>
# App-Maintainer: freedom-323 <long.hummingbird.wivo@mask.me>
# App-URL: https://launchpad.net/apt-fast/
# OS-repository: https://github.com/ilikenwf/apt-fast
# SPDX-License-Identifier: AGPL-3.0-only
# App-License: GPL-3.0-only

set -e

add-apt-repository ppa:apt-fast/stable
apt-get -y install apt-fast
