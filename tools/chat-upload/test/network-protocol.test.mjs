import assert from 'node:assert/strict'
import { Writable } from 'node:stream'
import test from 'node:test'
import { isPrivateIPv4, parseLinuxDefaultInterface, selectPrivateDefaultRouteIPv4 } from '../src/network.mjs'
import { JsonlProtocol } from '../src/protocol.mjs'

const routes = `Iface\tDestination\tGateway\tFlags\tRefCnt\tUse\tMetric\tMask\neth0\t00000000\t0101A8C0\t0003\t0\t0\t100\t00000000\ndocker0\t000011AC\t00000000\t0001\t0\t0\t0\t0000FFFF\n`

test('selects only RFC1918 IPv4 on the Linux default-route interface', async () => {
  assert.equal(parseLinuxDefaultInterface(routes), 'eth0')
  const result = await selectPrivateDefaultRouteIPv4({
    readRoutes: async () => routes,
    interfaces: () => ({ eth0: [{ family: 'IPv4', address: '192.168.1.9', internal: false }], docker0: [{ family: 'IPv4', address: '172.17.0.1', internal: false }] }),
  })
  assert.deepEqual(result, { interfaceName: 'eth0', address: '192.168.1.9' })
  assert.equal(isPrivateIPv4('172.31.2.3'), true)
  assert.equal(isPrivateIPv4('172.32.2.3'), false)
})

test('fails when default interface has no private IPv4', async () => {
  await assert.rejects(selectPrivateDefaultRouteIPv4({
    readRoutes: async () => routes,
    interfaces: () => ({ eth0: [{ family: 'IPv4', address: '100.64.0.1', internal: false }] }),
  }), (error) => error.code === 'private_lan_address_unavailable')
})

test('JSONL protocol isolates events and rejects duplicates', () => {
  let stdout = ''; let stderr = ''
  const sink = (set) => new Writable({ write(chunk, _encoding, done) { set(chunk.toString()); done() } })
  const protocol = new JsonlProtocol({ stdout: sink((value) => { stdout += value }), stderr: sink((value) => { stderr += value }) })
  protocol.emit({ event: 'ready', port: 1 })
  protocol.log('diagnostic')
  protocol.emit({ event: 'cancelled' })
  assert.deepEqual(stdout.trim().split('\n').map(JSON.parse).map((event) => event.event), ['ready', 'cancelled'])
  assert.equal(stderr, 'diagnostic\n')
  assert.throws(() => protocol.emit({ event: 'cancelled' }), /duplicate terminal/)
})
