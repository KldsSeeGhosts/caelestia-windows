'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');

const output = process.env.CAELESTIA_SUPPORT_TEST_OUTPUT;
assert.ok(output, 'Run Test-SupportBundle.ps1 with an explicit disposable output directory');
const root = fs.mkdtempSync(path.join(path.resolve(output), 'support-'));
const exporter = path.resolve(__dirname, '../../scripts/Export-CaelestiaSupport.ps1');
const powershell = path.join(process.env.SystemRoot, 'System32/WindowsPowerShell/v1.0/powershell.exe');
const support = path.resolve(__dirname, '../../support');
const schema = JSON.parse(fs.readFileSync(path.join(support, 'support-bundle.schema.json')));
const secret = 'SYNTHETIC_SECRET_TOKEN_Z9';
const content = 'SYNTHETIC_CLIPBOARD_NOTIFICATION_TITLE_SSID_Z9';
const personal = 'C:\\Users\\SYNTHETIC_PERSON_Z9\\private';
const sha = 'eec2778123d47c3555006b3af5e75fd893c7b9c2';
const backend = 'e6039b2b9cbb35b97473bda4dcc3f12789ae7f0c';
const glazier = '37f795041cbbb32ed46cba103f3f000a3a99ac13';
const m3shapes = '32ad9ce328bb77ed349b40a3be10ee9ea610b8ab';
const ids = ['shell', 'tiling', 'audio', 'battery', 'bluetooth', 'brightness', 'network',
    'media', 'notifications', 'desktop', 'capture', 'idleInhibit', 'keyboard', 'tray', 'wallpaper'];
let sequence = 0;
const receipts = [];

// This dependency-free validator covers every keyword used in the committed
// schema. Unknown keywords fail instead of silently weakening schema tests.
function validate(value, rule, at = '$') {
    const known = ['$schema', '$id', 'title', '$defs', '$ref', 'type', 'const', 'enum', 'maxLength',
        'pattern', 'minimum', 'maximum', 'properties', 'required', 'additionalProperties',
        'minItems', 'maxItems', 'items'];
    for (const key of Object.keys(rule)) assert.ok(known.includes(key), `unhandled schema keyword ${key}`);
    if (rule.$ref) {
        assert.ok(rule.$ref.startsWith('#/$defs/'));
        return validate(value, schema.$defs[rule.$ref.slice(8)], at);
    }
    if ('const' in rule) assert.deepEqual(value, rule.const, at);
    if (rule.enum) assert.ok(rule.enum.some(item => item === value), `${at} enum`);
    if (rule.type) {
        const types = [].concat(rule.type);
        assert.ok(types.some(type => type === 'null' ? value === null
            : type === 'array' ? Array.isArray(value)
            : type === 'object' ? value !== null && typeof value === 'object' && !Array.isArray(value)
            : type === 'integer' ? Number.isSafeInteger(value)
            : typeof value === type), `${at} type`);
    }
    if (typeof value === 'string') {
        if (rule.maxLength !== undefined) assert.ok(value.length <= rule.maxLength, `${at} maxLength`);
        if (rule.pattern) assert.ok(new RegExp(rule.pattern).test(value), `${at} pattern`);
    }
    if (typeof value === 'number') {
        if (rule.minimum !== undefined) assert.ok(value >= rule.minimum, `${at} minimum`);
        if (rule.maximum !== undefined) assert.ok(value <= rule.maximum, `${at} maximum`);
    }
    if (Array.isArray(value)) {
        if (rule.minItems !== undefined) assert.ok(value.length >= rule.minItems, `${at} minItems`);
        if (rule.maxItems !== undefined) assert.ok(value.length <= rule.maxItems, `${at} maxItems`);
        if (rule.items) value.forEach((item, i) => validate(item, rule.items, `${at}[${i}]`));
    } else if (value !== null && typeof value === 'object') {
        for (const name of rule.required || []) assert.ok(Object.hasOwn(value, name), `${at}.${name} required`);
        for (const [name, child] of Object.entries(value)) {
            if (rule.additionalProperties === false) assert.ok(Object.hasOwn(rule.properties, name), `${at}.${name} forbidden`);
            if (rule.properties?.[name]) validate(child, rule.properties[name], `${at}.${name}`);
        }
    }
}

function writeJson(file, data) { fs.writeFileSync(file, JSON.stringify(data)); }
function fixture() {
    const dir = path.join(root, String(++sequence));
    const prefix = path.join(dir, 'SYNTHETIC_PERSON_Z9-prefix');
    fs.mkdirSync(prefix, { recursive: true });
    const record = {
        product: 'caelestia-windows', version: 1, prefix, profile: personal, installId: secret,
        sourceRevision: sha, backendRevision: backend, glazierRevision: glazier,
        releaseId: 'v0.1.0-preview.2', executableSha256: 'a'.repeat(64)
    };
    const release = {
        schema: 'caelestia-windows-release', version: 1, platform: 'windows-x64',
        releaseId: record.releaseId, sourceRevision: sha, nativeSourceRevision: 'b'.repeat(40),
        backendRevision: backend, qtVersion: '6.11.2',
        dependencies: {
            quickshell: { revision: backend }, glazier: { revision: glazier },
            m3shapes: { revision: m3shapes },
            schemeCli: { revision: 'c'.repeat(40), pythonPackages: { materialyoucolor: '3.0.4', pillow: '13.0.0' } }
        },
        files: [{ path: personal, secret, content }], rawEnvironment: { secret }
    };
    writeJson(path.join(prefix, 'install.json'), record);
    writeJson(path.join(prefix, 'release-manifest.json'), release);
    fs.mkdirSync(path.join(prefix, 'logs'));
    fs.writeFileSync(path.join(prefix, 'logs', 'raw.log'), `${secret}\n${content}\n${personal}`);
    return { dir, prefix, record, release, file: path.join(dir, 'bundle.json') };
}
function run(f, input, extra = []) {
    const args = ['-NoProfile', '-NonInteractive', '-File', f.exporter || exporter, '-Prefix', f.prefix, '-OutputPath', f.file];
    if (input !== undefined) {
        const snapshot = path.join(f.dir, 'snapshot.json');
        writeJson(snapshot, input);
        args.push('-SnapshotPath', snapshot);
    }
    const started = performance.now();
    const result = spawnSync(powershell, [...args, ...extra], {
        encoding: 'utf8', timeout: 20000, windowsHide: true, cwd: f.dir,
        env: f.env || process.env
    });
    const elapsedMs = Math.round(performance.now() - started);
    // Keep failures private locally, never concatenate raw fixture source logs.
    fs.writeFileSync(path.join(f.dir, 'command.stdout.txt'), result.stdout || '');
    fs.writeFileSync(path.join(f.dir, 'command.stderr.txt'), result.stderr || '');
    receipts.push({ case: sequence, exitCode: result.status, elapsedMs });
    assert.ifError(result.error);
    assert.equal(result.status, 0, result.stderr);
    const raw = fs.readFileSync(f.file, 'utf8');
    assert.ok(Buffer.byteLength(raw) <= 65536);
    for (const canary of [secret, content, personal, 'SYNTHETIC_PERSON_Z9']) {
        assert.ok(!raw.includes(canary), `leaked ${canary}`);
        assert.ok(!(result.stdout + result.stderr).includes(canary), 'console leak');
    }
    const bundle = JSON.parse(raw);
    validate(bundle, schema);
    assert.deepEqual(bundle.providers.map(row => row.id), ids);
    return bundle;
}
function input(providers = {}) { return { schema: 'caelestia-support-input', version: 1, providers }; }

test('installed-layout metadata projection excludes profile/log/content canaries', () => {
    const f = fixture();
    const before = crypto.createHash('sha256').update(fs.readFileSync(path.join(f.prefix, 'install.json'))).digest('hex');
    const snapshot = input({
        audio: { category: 'failed', reason: secret, message: `${personal} ${content}`,
            errors: [{ category: 'failed', reason: 'operation-failed', count: 3, trace: secret }] },
        notifications: { category: 'denied', reason: 'permission-denied', ready: false, body: content },
        media: { category: 'empty', reason: 'empty', ready: true },
        attacker: { category: 'supported', reason: secret }
    });
    snapshot.shellState = { lifecycle: { ready: true, generation: secret }, wallpaperEngine: { current: { path: personal } }, keyboard: { name: content } };
    snapshot.tilingState = { backendLoaded: true, failedCount: 5, recentFailureCount: 2, title: content };
    snapshot.displayDriverVersion = '32.0.15.0001';
    const b = run(f, snapshot);
    assert.equal(b.collection.category, 'supported');
    assert.equal(b.identity.sourceRevision, sha);
    assert.equal(b.identity.nativeSourceRevision, 'b'.repeat(40));
    assert.equal(b.identity.m3shapesRevision, m3shapes);
    assert.equal(b.modules.qt, '6.11.2');
    assert.equal(b.environment.displayDriver.version, '32.0.15.0001');
    assert.equal(b.providers[0].ready, true);
    assert.equal(b.providers[1].counters.failures, 5);
    assert.equal(b.providers[2].category, 'failed');
    assert.equal(b.providers[2].reason, 'provider-unavailable');
    assert.deepEqual(b.providers[2].errors, [{ category: 'failed', reason: 'operation-failed', count: 3 }]);
    assert.equal(b.providers[8].category, 'denied');
    assert.equal(b.providers[7].category, 'empty');
    assert.equal(crypto.createHash('sha256').update(fs.readFileSync(path.join(f.prefix, 'install.json'))).digest('hex'), before);
});

test('missing metadata and missing provider stay unavailable; no arbitrary log ingestion', () => {
    const f = fixture();
    fs.unlinkSync(path.join(f.prefix, 'install.json'));
    fs.unlinkSync(path.join(f.prefix, 'release-manifest.json'));
    const b = run(f);
    assert.deepEqual(b.sources.install, { category: 'unavailable', reason: 'missing' });
    assert.equal(b.identity.sourceRevision, null);
    assert.ok(b.providers.every(row => row.category === 'unavailable' && row.reason === 'not-collected'));
    assert.equal(b.sources.snapshot.reason, 'not-collected');
});

test('copied installed scripts run without repository working directory or SDK/Node PATH', () => {
    const f = fixture();
    const scripts = path.join(f.dir, 'copied-payload');
    fs.mkdirSync(scripts);
    for (const name of ['Export-CaelestiaSupport.ps1', 'Caelestia-Support.ps1']) {
        fs.copyFileSync(path.join(path.dirname(exporter), name), path.join(scripts, name));
    }
    f.exporter = path.join(scripts, 'Export-CaelestiaSupport.ps1');
    f.env = { ...process.env, PATH: path.dirname(powershell) };
    const b = run(f);
    assert.equal(b.collection.category, 'supported');
    assert.equal(b.identity.sourceRevision, sha);
});

test('versioned selector follows only fixed installed metadata child', () => {
    const f = fixture();
    const id = 'v0.1.0-preview.2-01234567';
    const payload = path.join(f.prefix, 'versions', id);
    fs.mkdirSync(payload, { recursive: true });
    writeJson(path.join(payload, 'install.json'), { ...f.record, versionId: id });
    writeJson(path.join(payload, 'release-manifest.json'), f.release);
    writeJson(path.join(f.prefix, 'install.json'), { ...f.record, version: 2, current: id });
    assert.equal(run(f).identity.sourceRevision, sha);
});

test('selector traversal and inconsistent version metadata fail closed', () => {
    for (const id of ['..\\outside', '../../outside', secret]) {
        const f = fixture();
        writeJson(path.join(f.prefix, 'install.json'), { ...f.record, version: 2, current: id });
        const b = run(f);
        assert.equal(b.sources.install.category, 'unavailable');
        assert.equal(b.identity.sourceRevision, null);
    }
});

test('malformed, excessive-depth and oversized metadata remain bounded', () => {
    for (const raw of ['{"secret":', '[' + '[]', '{"x":'.repeat(30) + '1' + '}'.repeat(30), ' '.repeat(65537)]) {
        const f = fixture();
        fs.writeFileSync(path.join(f.prefix, 'install.json'), raw);
        const b = run(f);
        assert.ok(['invalid', 'oversized'].includes(b.sources.install.reason));
        assert.equal(b.identity.sourceRevision, null);
    }
    const f = fixture();
    fs.writeFileSync(path.join(f.prefix, 'release-manifest.json'), ' '.repeat(4194305));
    assert.equal(run(f).sources.release.reason, 'oversized');
});

test('manifest IDs and module versions reject content, paths, banners and wrong types', () => {
    const f = fixture();
    writeJson(path.join(f.prefix, 'install.json'), { ...f.record,
        sourceRevision: secret, releaseId: secret, backendRevision: personal, glazierRevision: [glazier],
        executableSha256: `${'a'.repeat(64)}\n`, releaseManifestSha256: content });
    writeJson(path.join(f.prefix, 'release-manifest.json'), { ...f.release, sourceRevision: secret, qtVersion: personal });
    const b = run(f);
    assert.ok(Object.entries(b.identity).filter(([key]) => key !== 'trust').every(([, value]) => value === null));
    const g = fixture();
    g.release.qtVersion = '6.11.2 ' + secret;
    g.release.releaseId = secret;
    g.release.dependencies.schemeCli.pythonPackages.pillow = personal;
    writeJson(path.join(g.prefix, 'release-manifest.json'), g.release);
    const clean = run(g);
    assert.equal(clean.modules.qt, null);
    assert.equal(clean.modules.pillow, null);
    assert.equal(clean.identity.releaseId, null);
});

test('all stable categories survive and accepted never implies completed', () => {
    const categories = ['supported', 'unsupported', 'denied', 'unavailable', 'transient', 'failed', 'empty'];
    const providers = Object.fromEntries(categories.map((category, index) => [ids[index + 2], {
        category, requested: true, accepted: true, errors: [{ category: secret, reason: secret, count: secret }]
    }]));
    providers.desktop = { category: 'supported', requested: true, accepted: true, completed: true };
    providers.capture = { category: 'supported', requested: false, accepted: true, completed: true };
    const b = run(fixture(), input(providers));
    categories.forEach((category, i) => {
        assert.equal(b.providers[i + 2].category, category);
        assert.equal(b.providers[i + 2].completed, null);
    });
    assert.equal(b.providers[9].completed, true);
    assert.equal(b.providers[10].accepted, null);
    assert.equal(b.providers[10].completed, null);
});

test('provider unknown/malformed/failure input cannot leak or poison healthy peers', () => {
    const b = run(fixture(), input({
        audio: { category: secret, reason: `${secret} ${personal}` },
        battery: 'exception: ' + secret,
        bluetooth: { category: 'unavailable', reason: 'timeout' },
        media: { category: 'supported', ready: true, counters: { failures: -1, samples: 1e40 }, timing: { lastDurationMs: secret } }
    }));
    assert.equal(b.providers[2].reason, 'invalid');
    assert.equal(b.providers[3].reason, 'invalid');
    assert.equal(b.providers[4].reason, 'timeout');
    assert.equal(b.providers[7].ready, true);
    assert.equal(b.providers[7].counters.failures, null);
    assert.equal(b.providers[7].counters.samples, null);
    assert.equal(b.providers[7].timing.lastDurationMs, null);
});

test('error/timing/counter bounds project rather than copying nested input', () => {
    const b = run(fixture(), input({ audio: {
        category: 'failed', reason: 'operation-failed', counters: { failures: 1000000000, recentFailures: 1000000001, samples: 2.5 },
        timing: { lastDurationMs: 600001, totalDurationMs: 86400000, raw: secret },
        errors: Array.from({ length: 100 }, () => ({ category: 'failed', reason: 'operation-failed', count: 2, message: secret }))
    } }));
    assert.equal(b.providers[2].errors.length, 4);
    assert.deepEqual(b.providers[2].counters, { failures: 1000000000, recentFailures: null, samples: null });
    assert.deepEqual(b.providers[2].timing, { lastDurationMs: null, totalDurationMs: 86400000 });
});

test('missing/malformed/oversized snapshot stays unavailable without losing identity', () => {
    for (const raw of ['{', ' '.repeat(65537), JSON.stringify({ schema: secret, version: 1 })]) {
        const f = fixture();
        const snapshot = path.join(f.dir, 'bad.json');
        fs.writeFileSync(snapshot, raw);
        const b = run(f, undefined, ['-SnapshotPath', snapshot]);
        assert.ok(['invalid', 'oversized'].includes(b.sources.snapshot.reason));
        assert.equal(b.identity.sourceRevision, sha);
    }
    const f = fixture();
    assert.equal(run(f, undefined, ['-SnapshotPath', path.join(f.dir, 'missing.json')]).sources.snapshot.reason, 'missing');
});

test('collector deadline emits a schema-valid unavailable bundle, never false success', () => {
    const f = fixture();
    const b = run(f, input({ audio: { category: 'supported' } }), ['-TimeoutMilliseconds', '1']);
    assert.deepEqual(b.collection, { category: 'unavailable', reason: 'timeout' });
    assert.ok(b.providers.every(row => row.category === 'unavailable'));
    assert.ok(receipts.at(-1).elapsedMs < 8000);
});

function injectedCollector(f, injection) {
    const scripts = path.join(f.dir, 'installed-scripts');
    fs.mkdirSync(scripts);
    f.exporter = path.join(scripts, 'Export-CaelestiaSupport.ps1');
    fs.copyFileSync(exporter, f.exporter);
    const helper = fs.readFileSync(path.join(path.dirname(exporter), 'Caelestia-Support.ps1'), 'utf8');
    const signature = 'function Get-CaelestiaSupportBundle([string]$Prefix, [string]$SnapshotPath) {';
    assert.equal(helper.split(signature).length, 2, 'one real collection seam');
    fs.writeFileSync(path.join(scripts, 'Caelestia-Support.ps1'), helper.replace(signature, signature + '\n' + injection));
}

test('throwing collector never exposes its raw exception and produces unavailable output', () => {
    const f = fixture();
    injectedCollector(f, `throw '${secret} ${personal} ${content}'`);
    const b = run(f);
    assert.deepEqual(b.collection, { category: 'unavailable', reason: 'provider-unavailable' });
});

test('stalled collector is actually terminated by deadline without blocking export', () => {
    const f = fixture();
    const pidFile = path.join(f.dir, 'worker-pid.txt');
    injectedCollector(f, `[IO.File]::WriteAllText('${pidFile.replaceAll("'", "''")}', [string]$PID)\nStart-Sleep -Seconds 30`);
    const b = run(f, undefined, ['-TimeoutMilliseconds', '1500']);
    assert.deepEqual(b.collection, { category: 'unavailable', reason: 'timeout' });
    assert.ok(fs.existsSync(pidFile), 'collector started and actually stalled');
    const workerPid = Number(fs.readFileSync(pidFile, 'utf8'));
    assert.ok(workerPid > 0);
    assert.throws(() => process.kill(workerPid, 0), /ESRCH/, 'owned stalled worker exited');
    assert.ok(receipts.at(-1).elapsedMs < 8000);
});

test('maximum admitted error records and timings stay within output size bound', () => {
    const row = {
        category: 'failed', reason: 'operation-failed', requested: true, accepted: true, completed: true,
        counters: { failures: 1000000000, recentFailures: 1000000000, samples: 1000000000 },
        timing: { lastDurationMs: 600000, totalDurationMs: 86400000 },
        errors: Array.from({ length: 4 }, () => ({ category: 'failed', reason: 'completion-unobserved', count: 1000000000 }))
    };
    const b = run(fixture(), input(Object.fromEntries(ids.map(id => [id, row]))));
    assert.equal(b.providers.reduce((count, p) => count + p.errors.length, 0), 60);
    assert.ok(b.providers.every(p => p.completed === null), 'failed operation cannot claim successful completion');
});

test('envelope types are exact, never coerced from arrays, strings or booleans', () => {
    for (const version of ['1', true, [1]]) {
        const f = fixture();
        writeJson(path.join(f.prefix, 'install.json'), { ...f.record, version });
        const b = run(f, { ...input(), version });
        assert.equal(b.sources.install.reason, 'invalid');
        assert.equal(b.sources.snapshot.reason, 'invalid');
    }
    const f = fixture();
    const b = run(f, input({ audio: { category: ['supported'], reason: ['none'] } }));
    assert.equal(b.providers[2].reason, 'invalid');
});

test('read failure remains truthful and partial', () => {
    const f = fixture();
    fs.unlinkSync(path.join(f.prefix, 'release-manifest.json'));
    fs.mkdirSync(path.join(f.prefix, 'release-manifest.json'));
    const b = run(f);
    assert.equal(b.sources.release.category, 'unavailable');
    assert.equal(b.identity.sourceRevision, sha);
});

test('output collision and output inside installation are refused without overwrite', () => {
    for (const inside of [false, true]) {
        const f = fixture();
        const target = inside ? path.join(f.prefix, 'do-not-write.json') : f.file;
        fs.writeFileSync(target, secret);
        const result = spawnSync(powershell, ['-NoProfile', '-NonInteractive', '-File', exporter,
            '-Prefix', f.prefix, '-OutputPath', target], { encoding: 'utf8', timeout: 10000, windowsHide: true });
        assert.notEqual(result.status, 0);
        assert.equal(fs.readFileSync(target, 'utf8'), secret);
        assert.ok(!(result.stdout + result.stderr).includes(secret));
    }
});

test('network/device/reserved/alternate-stream and junction input paths are refused', () => {
    const f = fixture();
    const junction = path.join(f.dir, 'junction');
    fs.symlinkSync(f.prefix, junction, 'junction');
    for (const prefix of ['\\\\invalid.example\\share', '\\\\?\\C:\\invalid', 'C:\\NUL',
        f.prefix + ':stream', junction, f.prefix + '. ']) {
        const result = spawnSync(powershell, ['-NoProfile', '-NonInteractive', '-File', exporter,
            '-Prefix', prefix, '-OutputPath', f.file], { encoding: 'utf8', timeout: 10000, windowsHide: true });
        assert.ifError(result.error);
        assert.notEqual(result.status, 0);
        assert.equal(fs.existsSync(f.file), false);
    }
});
test('schema rejects additions at every nested boundary and invalid values', () => {
    const b = run(fixture());
    for (const at of [[], ['collection'], ['sources'], ['sources', 'install'], ['identity'], ['modules'],
        ['environment'], ['environment', 'displayDriver'], ['providers', 0], ['providers', 0, 'counters'],
        ['providers', 0, 'timing']]) {
        const clone = structuredClone(b);
        let cursor = clone;
        for (const key of at) cursor = cursor[key];
        cursor.raw = secret;
        assert.throws(() => validate(clone, schema), /forbidden/);
    }
    const clone = structuredClone(b);
    clone.providers[0].errors = [{ category: 'failed', reason: 'operation-failed', count: 1, raw: secret }];
    assert.throws(() => validate(clone, schema), /forbidden/);
    clone.providers[0].errors = [];
    clone.providers[0].category = secret;
    assert.throws(() => validate(clone, schema), /enum/);
    const newline = structuredClone(b);
    newline.modules.qt = '6.11.2\n';
    assert.throws(() => validate(newline, schema), /pattern/);
    newline.modules.qt = null;
    newline.identity.releaseId = 'v0.1.0\n';
    assert.throws(() => validate(newline, schema), /pattern/);
});

test('sanitized committed example validates against strict schema', () => {
    validate(JSON.parse(fs.readFileSync(path.join(support, 'support-bundle.example.json'))), schema);
});

test.after(() => {
    writeJson(path.join(root, 'receipt.json'), {
        evidence: 'synthetic-support-fixtures', invocations: receipts.length, commands: receipts,
        note: 'No live profile, desktop, shell IPC, device or package acceptance was exercised.'
    });
    console.log(`Retained synthetic support evidence: ${root}`);
});
