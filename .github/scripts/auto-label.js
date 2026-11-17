#!/usr/bin/env node
/**
 * Auto-label pull requests and issues for zhenTo.
 *
 * Rules (in priority order):
 *   1. Conventional-commit type in the title  -> type label (enhancement, bug, ci, ...)
 *   2. Changed file paths (PR only)           -> area label (installer, build-system, ...)
 *   3. Dependabot author / title              -> dependencies
 *   4. Free-text keywords (Issue only)        -> bug / enhancement / documentation
 *   5. Nothing matched                        -> triage
 *
 * Labels in NEW_LABELS are created on demand if they do not exist.
 * Existing labels are only referenced, never modified.
 * This script only ADDS labels; it never removes labels (human-applied ones are kept).
 */

'use strict';

const fs = require('node:fs');

/** Labels this workflow owns. Created automatically when missing. */
const NEW_LABELS = {
  triage: {
    color: 'fbca04',
    description: 'No rule matched yet - please categorize manually',
  },
  ci: {
    color: '1d76db',
    description: 'CI, GitHub Actions and automation changes',
  },
  chore: {
    color: 'fef2c0',
    description: 'Maintenance chores: cleanup, config, housekeeping',
  },
  refactor: {
    color: 'c5def5',
    description: 'Code refactoring without behavior change',
  },
  performance: {
    color: '0e8a16',
    description: 'Performance improvement',
  },
  installer: {
    color: 'bfd4f2',
    description: 'Installer and install-app scripts',
  },
  'build-system': {
    color: 'f9d0c4',
    description: 'ISO build scripts and build configuration',
  },
  scripts: {
    color: 'd4c5f9',
    description: 'Standalone utility scripts under scripts/',
  },
  i18n: {
    color: '84b6eb',
    description: 'Internationalization and localization',
  },
  boot: {
    color: 'c2e0c6',
    description: 'GRUB and boot configuration',
  },
};

/** Chinese conventional-commit style prefixes seen in this repo's history. */
const ZH_TYPE_PREFIX = [
  [/^预装/, 'feat'],
  [/^(新增|添加|增加)/, 'feat'],
  [/^修复/, 'fix'],
  [/^重构/, 'refactor'],
  [/^(文档|说明)/, 'docs'],
  [/^性能/, 'perf'],
];

/** Match a conventional-commit prefix such as "feat(grub)!: title" or "i18n: title". */
function commitType(title) {
  const value = String(title || '').trim();
  const m = value.toLowerCase().match(/^\s*([a-z][a-z0-9-]*)(\([^)]*\))?\s*!?\s*:/);
  if (m) return m[1];
  for (const [pattern, type] of ZH_TYPE_PREFIX) {
    if (pattern.test(value)) return type;
  }
  return '';
}

/**
 * Pure rule engine. Exported so the whole rule set can be tested offline.
 * @returns {string[]} sorted, de-duplicated label names
 */
function computeLabels({ title = '', body = '', files = [], author = '', isPR = false }) {
  const labels = new Set();
  const text = `${title}\n${body}`.toLowerCase();
  const type = commitType(title);

  // 1. Conventional-commit type
  switch (type) {
    case 'feat':
    case 'feature':
      labels.add('enhancement');
      break;
    case 'fix':
    case 'hotfix':
    case 'bugfix':
      labels.add('bug');
      break;
    case 'doc':
    case 'docs':
      labels.add('documentation');
      break;
    case 'ci':
      labels.add('ci');
      labels.add('github_actions');
      break;
    case 'build':
      labels.add('build-system');
      break;
    case 'refactor':
      labels.add('refactor');
      break;
    case 'perf':
      labels.add('performance');
      break;
    case 'i18n':
    case 'l10n':
      labels.add('i18n');
      break;
    case 'chore':
    case 'deps':
    case 'revert':
      labels.add('chore');
      break;
    default:
      break;
  }

  // 2. Changed paths (PR only)
  if (isPR) {
    for (const raw of files) {
      const p = String(raw).toLowerCase();

      if (p.startsWith('.github/workflows/') || p === '.github/dependabot.yml') {
        labels.add('github_actions');
        labels.add('ci');
      }
      if (p === '.gitignore') labels.add('gitignore');
      if (p.startsWith('install-app/')) {
        labels.add('installer');
        if (type === 'feat' || type === 'feature') labels.add('new-app');
      }
      if (p.startsWith('edit-grub/')) labels.add('boot');
      if (p.startsWith('edit-os-release/') || p === 'build.sh' || p.endsWith('/manifest.conf')) {
        labels.add('build-system');
      }
      if (p.startsWith('scripts/')) labels.add('scripts');
      if (p === 'readme.md' || p.startsWith('docs/') || p.endsWith('.md')) {
        labels.add('documentation');
      }
    }
  }

  // Localization can be the real intent even under a chore(scripts) scope
  if (/i18n|l10n|localiz|internationaliz|translat|本地化|国际化|翻译|英文化/.test(text)) {
    labels.add('i18n');
  }

  // 3. Dependabot PRs. A human fixing a "dependabot" DCO rule is NOT a dependency update.
  if (author === 'dependabot[bot]' || /^chore\(deps\)|\bbump\b.*\b(group|from|to)\b/i.test(title)) {
    labels.add('dependencies');
  }

  // 4. Free-text keywords, used only when the title has no conventional type
  if (!type) {
    if (/bug|error|crash|fail|broken|报错|错误|崩溃|失败|无法|不能|异常/.test(text)) {
      labels.add('bug');
    }
    if (/feature|request|suggest|希望|建议|需求|支持|增加|新增/.test(text)) {
      labels.add('enhancement');
    }
    if (/\bdocs?\b|readme|文档|说明/.test(text)) {
      labels.add('documentation');
    }
  }

  // 5. Guarantee every PR / issue has at least one label
  if (labels.size === 0) labels.add('triage');

  return [...labels].sort();
}

function repoPath(suffix) {
  const [owner, repo] = (process.env.GITHUB_REPOSITORY || '').split('/');
  if (!owner || !repo) throw new Error('GITHUB_REPOSITORY is not set');
  return `/repos/${owner}/${repo}${suffix}`;
}

class ApiError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

async function api(path, { method = 'GET', body } = {}) {
  const response = await fetch(`https://api.github.com${path}`, {
    method,
    headers: {
      Accept: 'application/vnd.github+json',
      Authorization: `Bearer ${process.env.GH_TOKEN}`,
      'X-GitHub-Api-Version': '2022-11-28',
      'User-Agent': 'zhento-auto-label',
      ...(body ? { 'Content-Type': 'application/json' } : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });

  if (!response.ok) {
    throw new ApiError(response.status, `${method} ${path} -> ${response.status}: ${await response.text()}`);
  }
  return response.status === 204 ? null : response.json();
}

async function listPRFiles(number) {
  const files = [];
  for (let page = 1; page <= 20; page += 1) {
    const batch = await api(repoPath(`/pulls/${number}/files?per_page=100&page=${page}`));
    files.push(...batch.map((f) => f.filename));
    if (batch.length < 100) break;
  }
  return files;
}

/** Create only the labels we own, and only when they are missing. */
async function ensureLabels(names) {
  for (const name of names) {
    const meta = NEW_LABELS[name];
    if (!meta) continue;
    try {
      await api(repoPath(`/labels/${encodeURIComponent(name)}`));
    } catch (error) {
      if (!(error instanceof ApiError) || error.status !== 404) throw error;
      await api(repoPath('/labels'), { method: 'POST', body: { name, ...meta } });
      console.log(`Created missing label: ${name}`);
    }
  }
}

async function applyLabels(item, isPR) {
  const number = item.number;
  const files = isPR ? await listPRFiles(number) : [];
  const labels = computeLabels({
    title: item.title || '',
    body: item.body || '',
    files,
    author: (item.user && item.user.login) || '',
    isPR,
  });

  await ensureLabels(labels);
  await api(repoPath(`/issues/${number}/labels`), { method: 'POST', body: { labels } });
  console.log(`Applied to ${isPR ? 'PR' : 'issue'} #${number}: ${labels.join(', ')}`);
  return labels;
}

/** Manual mode: label every open PR and issue once. */
async function backfill() {
  let total = 0;
  for (let page = 1; page <= 10; page += 1) {
    const items = await api(repoPath(`/issues?state=open&per_page=100&page=${page}`));
    for (const item of items) {
      await applyLabels(item, Boolean(item.pull_request));
      total += 1;
    }
    if (items.length < 100) break;
  }
  console.log(`Backfilled ${total} open items`);
}

async function main() {
  if (!process.env.GH_TOKEN) throw new Error('GH_TOKEN is not set');

  if (process.argv.includes('--backfill')) {
    await backfill();
    return;
  }

  if (!process.env.GITHUB_EVENT_PATH) throw new Error('GITHUB_EVENT_PATH is not set');
  const event = JSON.parse(fs.readFileSync(process.env.GITHUB_EVENT_PATH, 'utf8'));
  const isPR = Boolean(event.pull_request);
  const item = isPR ? event.pull_request : event.issue;
  if (!item || !item.number) throw new Error('Unsupported event: no pull_request or issue payload');

  const labels = await applyLabels(item, isPR);
  const summary = `## Auto Label\n\n${isPR ? 'PR' : 'Issue'} #${item.number}: ${labels.map((l) => `\`${l}\``).join(', ')}\n`;
  if (process.env.GITHUB_STEP_SUMMARY) {
    fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, summary);
  }
}

if (require.main === module) {
  main().catch((error) => {
    console.error(error);
    process.exit(1);
  });
}

module.exports = { computeLabels, commitType, NEW_LABELS };
