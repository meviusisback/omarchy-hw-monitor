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

console.log("model tests passed")
