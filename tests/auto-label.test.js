#!/usr/bin/env node
// Copyright (C) 2026 ZIT STUDIO
// SPDX-License-Identifier: AGPL-3.0-only
//
// Offline unit tests for the auto-label rule engine. No network, no token.

'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { computeLabels, commitType, NEW_LABELS } = require(path.join(__dirname, '..', '.github', 'scripts', 'auto-label.js'));

test('commitType parses conventional commits', () => {
  assert.equal(commitType('feat(grub): new menu'), 'feat');
  assert.equal(commitType('fix(a)!: broken build'), 'fix');
  assert.equal(commitType('  CI: adjust runner  '), 'ci');
});

test('commitType parses Chinese prefixes used in this repo', () => {
  assert.equal(commitType('新增预装应用脚本'), 'feat');
  assert.equal(commitType('修复镜像构建'), 'fix');
  assert.equal(commitType('文档: 更新说明'), 'docs');
  assert.equal(commitType('性能: 压缩优化'), 'perf');
  assert.equal(commitType('随便聊聊'), '');
});

test('type labels map to the expected names', () => {
  assert.ok(computeLabels({ title: 'feat: add app' }).includes('enhancement'));
  assert.ok(computeLabels({ title: 'fix: grub entry' }).includes('bug'));
  assert.ok(computeLabels({ title: 'docs: readme' }).includes('documentation'));
  assert.ok(computeLabels({ title: 'perf: faster squashfs' }).includes('performance'));

  const ci = computeLabels({ title: 'ci: tweak workflow' });
  assert.ok(ci.includes('ci'));
  assert.ok(ci.includes('github_actions'));
});

test('feature keyword in Issue body marks enhancement', () => {
  assert.ok(computeLabels({ title: '希望支持 zstd', isPR: false }).includes('enhancement'));
  assert.ok(computeLabels({ title: '构建报错', isPR: false }).includes('bug'));
});

test('Dependabot PRs get dependencies', () => {
  const labels = computeLabels({
    title: 'chore(deps): bump actions/checkout from 4 to 5',
    author: 'dependabot[bot]',
    isPR: true,
  });
  assert.ok(labels.includes('dependencies'));
  assert.ok(labels.includes('chore'));
  // A human fixing the DCO rule is not a dependency update.
  assert.ok(!computeLabels({ title: 'fix: dependabot DCO check' }).includes('dependencies'));
});

test('PR file paths add area labels', () => {
  const labels = computeLabels({
    title: 'chore: touch many files',
    isPR: true,
    files: [
      '.github/workflows/pr-check.yml',
      'install-app/git.sh',
      'remove-app/firefox.sh',
      'edit-grub/grub.cfg',
      'build.sh',
      'scripts/download-release.sh',
      'README.md',
    ],
  });
  for (const expected of ['ci', 'github_actions', 'installer', 'remove-app', 'boot', 'build-system', 'scripts', 'documentation']) {
    assert.ok(labels.includes(expected), `expected label: ${expected}`);
  }
  // Area labels from paths must not leak into Issues.
  const issue = computeLabels({ title: 'chore: touch many files', files: ['build.sh'], isPR: false });
  assert.ok(!issue.includes('build-system'));
});

test('CONTRIBUTORS file changes get the CONTRIBUTORS label (PR only)', () => {
  const labels = computeLabels({ title: 'chore: refresh credits', isPR: true, files: ['CONTRIBUTORS'] });
  assert.ok(labels.includes('CONTRIBUTORS'));
  // Path rule must not leak into Issues.
  assert.ok(!computeLabels({ title: 'discuss CONTRIBUTORS', isPR: false, files: ['CONTRIBUTORS'] }).includes('CONTRIBUTORS'));
});

test('new-app requires both feat type and install-app path', () => {
  const labels = computeLabels({
    title: 'feat: install ripgrep',
    isPR: true,
    files: ['install-app/ripgrep.sh'],
  });
  assert.ok(labels.includes('new-app'));
  assert.ok(!computeLabels({ title: 'fix: install ripgrep', isPR: true, files: ['install-app/ripgrep.sh'] }).includes('new-app'));
});

test('remove-app/ paths get the remove-app label (PR only)', () => {
  const labels = computeLabels({
    title: 'chore: drop bundled firefox',
    isPR: true,
    files: ['remove-app/firefox.sh'],
  });
  assert.ok(labels.includes('remove-app'));
  // Removal scripts are not installers.
  assert.ok(!labels.includes('installer'));
  // Path rule must not leak into Issues.
  assert.ok(!computeLabels({ title: 'discuss remove-app', isPR: false, files: ['remove-app/firefox.sh'] }).includes('remove-app'));
});

test('localization intent wins even under a chore(scripts) scope', () => {
  const labels = computeLabels({ title: 'chore(scripts): 英文化提示文案', isPR: true, files: ['scripts/a.sh'] });
  assert.ok(labels.includes('i18n'));
});

test('.githooks/ paths are labeled hook', () => {
  const labels = computeLabels({
    title: 'chore: tweak commit-msg hook',
    isPR: true,
    files: ['.githooks/commit-msg'],
  });
  assert.ok(labels.includes('hook'));
  // The hook label is a path rule, not an Issue free-text rule.
  assert.ok(!computeLabels({ title: 'hook related discussion', isPR: false }).includes('hook'));
});

test('hook-only PR ignores the i18n boilerplate baked into the PR template', () => {
  // The PR template hardcodes "i18n" in every body. PR #29 (feat(hooks) +
  // .githooks/commit-msg) was wrongly tagged i18n by this.
  const templateBody = '- [ ] `i18n` internationalization / localization';
  const labels = computeLabels({
    title: 'feat(hooks): add commit-msg hook to auto-add DCO sign-off',
    body: templateBody,
    isPR: true,
    files: ['.githooks/commit-msg'],
  });
  assert.ok(labels.includes('hook'));
  assert.ok(labels.includes('enhancement'));
  assert.ok(!labels.includes('i18n'));
});

test('mixed PR touching .githooks/ and real i18n files still gets i18n', () => {
  const labels = computeLabels({
    title: 'chore: hooks plus translation',
    body: 'update translation strings',
    isPR: true,
    files: ['.githooks/commit-msg', 'i18n/zh_CN.js'],
  });
  assert.ok(labels.includes('hook'));
  assert.ok(labels.includes('i18n'));
});

test('empty input falls back to triage; output is sorted and unique', () => {
  assert.deepEqual(computeLabels({}), ['triage']);
  const labels = computeLabels({ title: 'ci: i18n', isPR: true, files: ['.github/workflows/a.yml'] });
  assert.deepEqual(labels, [...new Set(labels)].sort());
  assert.equal(new Set(labels).size, labels.length);
});

test('new-directory paths get their own area labels (PR only)', () => {
  const labels = computeLabels({
    title: 'chore: touch new areas',
    isPR: true,
    files: [
      'edit-icon/README.md',
      'edit-backgrounds/edit-backgrounds.sh',
      'edit-hostname/hostname.sh',
      'edit-hosts/hosts',
      'tests/icon.test.sh',
      '.github/actions/build-iso/action.yml',
    ],
  });
  for (const expected of ['icon', 'background', 'host-config', 'test', 'github_actions', 'documentation']) {
    assert.ok(labels.includes(expected), `expected label: ${expected}`);
  }
  // Path rules must not leak into Issues.
  const issue = computeLabels({
    title: 'chore: discuss new areas',
    isPR: false,
    files: ['edit-icon/README.md', 'tests/icon.test.sh'],
  });
  for (const leaked of ['icon', 'background', 'host-config', 'test']) {
    assert.ok(!issue.includes(leaked), `unexpected issue label: ${leaked}`);
  }
});

test('issue template component dropdown maps to area labels', () => {
  const app = computeLabels({
    title: 'feat: something for apps',
    isPR: false,
    body: '### 希望改进的组件\n\n预装应用 / install-app（新增或更新软件）\n\n### 想解决什么问题\n\n...',
  });
  assert.ok(app.includes('installer'));

  const boot = computeLabels({
    title: 'fix: menu issue',
    isPR: false,
    body: '### Affected component\n\nBoot configuration / edit-grub\n\n### Steps to reproduce\n\n...',
  });
  assert.ok(boot.includes('boot'));
});

test('issue prose picks up icon, background, host and test areas', () => {
  assert.deepEqual(
    computeLabels({
      title: 'fix: 突兀的logo和壁纸',
      body: '开机后的gmd3和GNOME设置中\n\n### 受影响的组件\n\n其他 / 不确定',
      isPR: false,
    }),
    ['background', 'bug', 'icon'],
  );
  const hosts = computeLabels({ title: 'hosts 配置问题', body: '/etc/hosts 主机名映射', isPR: false });
  assert.ok(hosts.includes('host-config'));
  // build.sh-only PRs still get host-config when the title says so.
  const pr = computeLabels({
    title: 'build: add hostname and hosts configuration to image build',
    files: ['build.sh'],
    isPR: true,
  });
  assert.ok(pr.includes('host-config'));
  const test = computeLabels({ title: '测试覆盖不足', isPR: false });
  assert.ok(test.includes('test'));
});

test('maintenance task-type dropdown beats the default chore title', () => {
  const labels = computeLabels({
    title: 'chore: rebuild pipeline',
    isPR: false,
    body: '### 任务类型\n\nCI / 自动化（ci）\n\n### 任务描述\n\n...',
  });
  assert.ok(labels.includes('ci'));
  assert.ok(labels.includes('github_actions'));
  assert.ok(!labels.includes('chore'));
});

test('maintenance template i18n example does not tag every issue as i18n', () => {
  const boilerplate = '> 标题前缀可按实际情况修改，自动打标脚本会识别：\n> `chore:` / `ci:` / `deps:` / `docs:` / `refactor:` / `perf:` / `i18n:` / `build:`';
  const labels = computeLabels({
    title: 'chore: housekeeping',
    isPR: false,
    body: `${boilerplate}\n\n### 任务类型\n\n其他杂务（chore）\n\n### 任务描述\n\n...`,
  });
  assert.ok(labels.includes('chore'));
  assert.ok(!labels.includes('i18n'));

  const explicit = computeLabels({ title: 'i18n: translate docs', isPR: false, body: boilerplate });
  assert.ok(explicit.includes('i18n'));
});

test('recent regressions keep their expected label sets', () => {
  assert.deepEqual(
    computeLabels({
      title: 'docs: document background wallpaper installer and new tests',
      isPR: true,
      files: ['README.md', 'build.sh', 'edit-backgrounds/edit-backgrounds.sh', 'tests/backgrounds.test.sh'],
    }),
    ['background', 'build-system', 'documentation', 'test'],
  );
  assert.deepEqual(
    computeLabels({
      title: 'fix(edit-icon): use transparent full banner for brand icons',
      isPR: true,
      files: ['edit-icon/README.md', 'edit-icon/files/pixmaps/ubuntu-logo-text-dark.png', 'tests/icon.test.sh'],
    }),
    ['bug', 'documentation', 'icon', 'test'],
  );
});

test('NEW_LABELS covers labels the workflow may create', () => {
  for (const name of [
    'triage', 'ci', 'chore', 'boot', 'build-system', 'installer', 'remove-app',
    'scripts', 'i18n', 'hook', 'CONTRIBUTORS', 'new-app', 'icon',
    'background', 'host-config', 'test',
  ]) {
    assert.ok(Object.hasOwn(NEW_LABELS, name), `missing NEW_LABELS entry: ${name}`);
  }
});
