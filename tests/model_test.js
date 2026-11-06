#!/usr/bin/env node

const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const vm = require("node:vm")

const root = path.resolve(__dirname, "..")
const source = fs.readFileSync(path.join(root, "Model.js"), "utf8")
  .replace(/^\.pragma library\s*/, "")
vm.runInThisContext(source, { filename: "Model.js" })

const headlessAmd = { kind: "amdgpu", card: "card0", connectedOutputs: 0 }
const displayNvidia = { kind: "nvidia", card: "card1", connectedOutputs: 3 }

assert.equal(pickGpu([headlessAmd, displayNvidia], "auto"), displayNvidia)
assert.equal(pickGpu([headlessAmd, displayNvidia], ""), displayNvidia)
assert.equal(pickGpu([headlessAmd, displayNvidia], "0"), headlessAmd)
assert.equal(pickGpu([headlessAmd, displayNvidia], "amd"), headlessAmd)

const first = { card: "card0", connectedOutputs: 1 }
const tied = { card: "card1", connectedOutputs: 1 }
assert.equal(pickGpu([first, tied], "auto"), first)
delete first.connectedOutputs
delete tied.connectedOutputs
assert.equal(pickGpu([first, tied], "auto"), first)

const parsed = parseProbe(JSON.stringify({
  cpu: {},
  gpus: [{ kind: "nvidia", connectedOutputs: 3 }]
}))
assert.equal(parsed.gpus[0].connectedOutputs, 3)

const nvidia0 = { kind: "nvidia", card: "card1", index: 0, connectedOutputs: 3 }
const nvidia1 = { kind: "nvidia", card: "card2", index: 1, connectedOutputs: 1 }
assert.equal(pickGpu([nvidia0, nvidia1], "busiest", 1), nvidia1)
assert.equal(pickGpu([nvidia0, nvidia1], "busiest", 0), nvidia0)
assert.equal(pickGpu([nvidia0, nvidia1], "busiest", 99), nvidia0)

const quiet = { busy: 40 }
const busy = { busy: 45 }
assert.equal(busiestNvidia([quiet, busy], 0, 10), 0)
assert.equal(busiestNvidia([quiet, busy], 0, 3), 1)
assert.equal(busiestNvidia([null, busy], 0, 10), 1)
assert.equal(busiestNvidia([], 0, 10), 0)

const samples = parseNvidiaAll("50, 60, 1024, 8192, 120\n\n70, 65, 2048, 8192, 150\n")
assert.equal(samples.length, 3)
assert.equal(samples[0].busy, 50)
assert.equal(samples[1], null)
assert.equal(samples[2].busy, 70)

console.log("model tests passed")
