import { cp, mkdir, readFile, rm, writeFile } from 'node:fs/promises'
import path from 'node:path'
import { build } from 'esbuild'

const root = path.resolve(import.meta.dirname, '..')
const dist = path.join(root, 'dist')
await rm(dist, { recursive: true, force: true })
await mkdir(dist, { recursive: true })
const uppyStylePackages = ['dashboard', 'webcam', 'audio', 'screen-capture', 'image-editor']
const uppyStyles = await Promise.all(uppyStylePackages.map((name) => readFile(path.join(root, 'node_modules', '@uppy', name, 'dist', 'style.min.css'), 'utf8')))

await Promise.all([
  cp(path.join(root, 'web', 'index.html'), path.join(dist, 'index.html')),
  cp(path.join(root, 'web', 'styles.css'), path.join(dist, 'styles.css')),
  writeFile(path.join(dist, 'uppy.css'), uppyStyles.join('\n')),
  build({
    entryPoints: [path.join(root, 'web', 'main.js')],
    outfile: path.join(dist, 'app.js'),
    bundle: true,
    minify: true,
    platform: 'browser',
    target: ['es2020'],
    legalComments: 'none',
  }),
])
