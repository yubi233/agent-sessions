import assert from 'node:assert/strict';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import test from 'node:test';
import { zstdCompressSync } from 'node:zlib';

import { encodeSegment, projectKey, runPreflight } from './dsh-v08-preflight.mjs';

async function writeArtifact(root, directory, id, body) {
  const cwd = join(root, directory);
  const path = join(root, directory, '.dsh-sessions', projectKey(cwd), encodeSegment(id), 'session.jsonl');
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, `${JSON.stringify({ type: 'session', version: 0, id, createdAt: 1, delegationDepth: 0, cwd })}\n${body}\n`);
}

async function writeCompressedArtifact(root, directory, id, body) {
  const cwd = join(root, directory);
  const path = join(root, directory, '.dsh-sessions', projectKey(cwd), encodeSegment(id), 'session.jsonl.zstd');
  await mkdir(dirname(path), { recursive: true });
  const content = `${JSON.stringify({ type: 'session', version: 0, id, createdAt: 1, delegationDepth: 0, cwd })}\n${body}\n`;
  await writeFile(path, zstdCompressSync(Buffer.from(content)));
}

test('preflight inventories headers without exposing paths or content', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'dsh-v08-preflight-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  await writeArtifact(root, 'project-a', 'session-a', '{"type":"assistant/message","secret":"must-not-appear"}');

  const report = await runPreflight({
    roots: [{ kind: 'workspace', value: root }],
    maxProjectDepth: 4,
    maxArtifacts: 100,
  });

  const serialized = JSON.stringify(report);
  assert.equal(report.status, 'passed');
  assert.equal(report.summary.artifact_count, 1);
  assert.equal(report.summary.migration_ready, true);
  assert.equal(serialized.includes(root), false);
  assert.equal(serialized.includes('session-a'), false);
  assert.equal(serialized.includes('must-not-appear'), false);
});

test('preflight blocks migration readiness on duplicate ids with different artifacts', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'dsh-v08-preflight-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  await writeArtifact(root, 'project-a', 'same-session', '{"type":"turn/end","seq":1}');
  await writeArtifact(root, 'project-b', 'same-session', '{"type":"turn/end","seq":2}');

  const report = await runPreflight({
    roots: [{ kind: 'legacy', value: root }],
    maxProjectDepth: 4,
    maxArtifacts: 100,
  });

  assert.equal(report.summary.migration_ready, false);
  assert.equal(report.status, 'blocked');
  assert.equal(report.collisions.length, 1);
  assert.equal(report.collisions[0].reason, 'duplicate_id_different_digest');
});

test('preflight reads zstd artifacts and blocks dual encoding', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'dsh-v08-preflight-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  await writeArtifact(root, 'project-a', 'same-session', '{"type":"turn/end","seq":1}');
  await writeCompressedArtifact(root, 'project-a', 'same-session', '{"type":"turn/end","seq":1}');

  const report = await runPreflight({
    roots: [{ kind: 'legacy', value: root }],
    maxProjectDepth: 4,
    maxArtifacts: 100,
  });

  assert.equal(report.summary.zstd_count, 1);
  assert.equal(report.summary.migration_ready, false);
  assert.equal(report.status, 'blocked');
  assert.equal(report.collisions[0].reason, 'duplicate_id_dual_compression');
});

test('preflight does not mark a depth-truncated inventory migration-ready', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'dsh-v08-preflight-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  await writeArtifact(root, 'project-a/nested', 'session-a', '{"type":"turn/end","seq":1}');

  const report = await runPreflight({
    roots: [{ kind: 'workspace', value: root }],
    maxProjectDepth: 1,
    maxArtifacts: 100,
  });

  assert.equal(report.summary.migration_ready, false);
  assert.equal(report.status, 'blocked');
  assert.equal(report.summary.error_counts.scan_limit_reached, 1);
});

test('preflight treats an explicit persistence root as a bounded inventory', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'dsh-v08-preflight-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  await writeArtifact(root, '.', 'session-at-root', '{"type":"turn/end","seq":1}');
  await writeArtifact(root, 'nested/project', 'nested-session', '{"type":"turn/end","seq":1}');

  const report = await runPreflight({
    roots: [{ kind: 'legacy', value: root }],
    maxProjectDepth: 1,
    maxArtifacts: 100,
  });

  assert.equal(report.summary.artifact_count, 1);
  assert.equal(report.summary.migration_ready, true);
});

test('preflight accepts a .dsh-sessions directory passed directly as a legacy root', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'dsh-v08-preflight-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  await writeArtifact(root, '.', 'direct-persistence-root', '{"type":"turn/end","seq":1}');

  const report = await runPreflight({
    roots: [{ kind: 'legacy', value: join(root, '.dsh-sessions') }],
    maxProjectDepth: 1,
    maxArtifacts: 100,
  });

  assert.equal(report.summary.artifact_count, 1);
  assert.equal(report.summary.valid_header_count, 1);
  assert.equal(report.summary.migration_ready, true);
});

test('preflight rejects a header whose id/cwd do not match its storage path', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'dsh-v08-preflight-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const cwd = join(root, 'project-a');
  const path = join(cwd, '.dsh-sessions', projectKey(cwd), encodeSegment('directory-id'), 'session.jsonl');
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, `${JSON.stringify({ type: 'session', version: 0, id: 'header-id', createdAt: 1, delegationDepth: 0, cwd })}\n{}\n`);

  const report = await runPreflight({
    roots: [{ kind: 'workspace', value: root }],
    maxProjectDepth: 4,
    maxArtifacts: 100,
  });

  assert.equal(report.summary.migration_ready, false);
  assert.equal(report.status, 'blocked');
  assert.equal(report.summary.error_counts.header_path_mismatch, 1);
});

test('preflight rejects a future session format version', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'dsh-v08-preflight-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const cwd = join(root, 'project-a');
  const path = join(cwd, '.dsh-sessions', projectKey(cwd), encodeSegment('future'), 'session.jsonl');
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, `${JSON.stringify({ type: 'session', version: 99, id: 'future', createdAt: 1, delegationDepth: 0, cwd })}\n{}\n`);

  const report = await runPreflight({
    roots: [{ kind: 'workspace', value: root }],
    maxProjectDepth: 4,
    maxArtifacts: 100,
  });

  assert.equal(report.summary.migration_ready, false);
  assert.equal(report.status, 'blocked');
  assert.equal(report.summary.error_counts.header_invalid_shape, 1);
});
