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
      'edit-grub/grub.cfg',
      'build.sh',
      'scripts/download-release.sh',
      'README.md',
    ],
  });
  for (const expected of ['ci', 'github_actions', 'installer', 'boot', 'build-system', 'scripts', 'documentation']) {
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

test('NEW_LABELS covers labels the workflow may create', () => {
  for (const name of ['triage', 'ci', 'chore', 'boot', 'build-system', 'installer', 'scripts', 'i18n', 'hook', 'CONTRIBUTORS']) {
    assert.ok(Object.hasOwn(NEW_LABELS, name), `missing NEW_LABELS entry: ${name}`);
  }
});
