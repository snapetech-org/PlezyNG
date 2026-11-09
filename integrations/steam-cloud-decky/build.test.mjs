import assert from 'node:assert/strict';
import {test} from 'node:test';
import {mkdtemp, readFile, rm, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {pathToFileURL} from 'node:url';
import {buildPlugin} from './build.mjs';

test('bundle retains Decky ESM and host React/UI contract without legacy build dependencies', async () => {
  const outdir = await mkdtemp(join(tmpdir(), 'pleazyng-decky-build-'));
  try {
    const result = await buildPlugin(outdir);
    assert.ok(Object.values(result.metafile.outputs).every(output => output.imports.length === 0));
    assert.ok(!Object.keys(result.metafile.inputs).some(path => /deepmerge|node_modules\/react\//.test(path)));
    const code = await readFile(join(outdir, 'index.js'), 'utf8');
    assert.match(code, /SP_REACT/);
    assert.match(code, /SP_JSX/);
    assert.match(code, /DFL/);
    assert.match(code, /export\s*\{/);
    await writeFile(join(outdir, 'package.json'), '{"type":"module"}');
    const connections = [];
    globalThis.SP_REACT = {useSyncExternalStore: () => false};
    globalThis.SP_JSX = {jsx: (type, props) => ({type, props}), jsxs: (type, props) => ({type, props})};
    globalThis.DFL = {PanelSection: () => {}, PanelSectionRow: () => {}, ToggleField: () => {}};
    globalThis.window = {__DECKY_SECRET_INTERNALS_DO_NOT_USE_OR_YOU_WILL_BE_FIRED_deckyLoaderAPIInit: {
      connect: (version, name) => {
        connections.push([version, name]);
        return {_version: 2, callable: () => async () => '', addEventListener: () => ({}), removeEventListener: () => {}};
      },
    }};
    const plugin = await import(pathToFileURL(join(outdir, 'index.js')).href);
    assert.equal(typeof plugin.default, 'function');
    assert.deepEqual(connections, [[2, 'Pleazyng Steam Cloud']]);
    const instance = plugin.default();
    assert.equal(instance.name, 'Pleazyng Steam Cloud');
    const content = instance.content.type();
    assert.equal(content.type, globalThis.DFL.PanelSection);
    instance.onDismount();
  } finally {
    delete globalThis.window;
    delete globalThis.SP_REACT;
    delete globalThis.SP_JSX;
    delete globalThis.DFL;
    await rm(outdir, {recursive: true, force: true});
  }
});
