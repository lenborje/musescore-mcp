const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const html = fs.readFileSync(require('node:path').join(__dirname, '../testClient.html'), 'utf8');
const nodes = {};
const document = {
    getElementById(id) {
        return nodes[id] ||= {value:'2',classList:{add(){},remove(){}},appendChild(){}};
    },
    createElement() {return {};},
};
const c = {document, WebSocket:{OPEN:1}, setTimeout};
vm.createContext(c);
vm.runInContext(html.match(/<script>([\s\S]*?)<\/script>/)[1], c);
const calls = [];
c.sendCommand = (action,params) => calls.push({action,params});
for (const name of ['addNote','addRest','addTuplet','goToMeasure']) c[name]();
for (const call of calls) assert.equal(call.params.voice,2,call.action);
const tuplet = calls.find(x=>x.action==='addTuplet').params;
assert.deepEqual(JSON.parse(JSON.stringify(tuplet.duration)),{numerator:1,denominator:4});
assert.equal(typeof tuplet.advanceCursorAfterAction,'boolean');
document.getElementById('eval-code').value='return params.value;';
document.getElementById('eval-params').value='{"value":42}';
c.runCode();
assert.equal(calls.at(-1).action,'runCode');
assert.equal(calls.at(-1).params.params.value,42);
console.log('PASS test client sends selected voices, complete tuplets and eval parameters');
