import {build} from 'esbuild';
import {readFile} from 'node:fs/promises';
import {dirname, resolve, join} from 'node:path';
import {fileURLToPath, pathToFileURL} from 'node:url';

const root = dirname(fileURLToPath(import.meta.url));
const runtimeGlobals = {
  react: 'SP_REACT',
  'react/jsx-runtime': 'SP_JSX',
  'react-dom': 'SP_REACTDOM',
  '@decky/ui': 'DFL',
};

// Decky supplies React and its UI in the host. Bundle its API, not a second
// React instance. Keep the same ESM default-export contract as @decky/rollup.
export async function buildPlugin(outdir = join(root, 'dist')) {
  const manifest = JSON.parse(await readFile(join(root, 'plugin.json'), 'utf8'));
  return build({
    absWorkingDir: root,
    entryPoints: ['src/index.tsx'],
    outfile: join(outdir, 'index.js'),
    bundle: true,
    platform: 'browser',
    format: 'esm',
    target: 'es2020',
    jsx: 'automatic',
    sourcemap: true,
    sourceRoot: `decky://decky/plugin/${encodeURIComponent(manifest.name)}/`,
    metafile: true,
    define: {'process.env.NODE_ENV': JSON.stringify('production')},
    plugins: [{
      name: 'decky-host-runtime',
      setup(builder) {
        builder.onResolve({filter: /^(react(?:\/jsx-runtime)?|react-dom|@decky\/ui|@decky\/manifest)$/}, args => ({path: args.path, namespace: 'decky-host'}));
        builder.onLoad({filter: /.*/, namespace: 'decky-host'}, args => args.path === '@decky/manifest'
          ? {contents: JSON.stringify(manifest), loader: 'json'}
          : {contents: `module.exports = globalThis[${JSON.stringify(runtimeGlobals[args.path])}];`, loader: 'js'});
      },
    }],
  });
}

if (process.argv[1] && pathToFileURL(resolve(process.argv[1])).href === import.meta.url) {
  await buildPlugin();
}
