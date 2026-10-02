#!/bin/sh
# Copyright (C) 2026 ZIT STUDIO
# Author: Oliver Lin <oliver@liuxiaozhen.dev>
# App-Maintainer: Oliver Lin <oliver@liuxiaozhen.dev>
# SPDX-License-Identifier: AGPL-3.0-only

set -e

add-apt-repository -y ppa:zitzhen/patchsplit
apt update
apt install -y patchsplit