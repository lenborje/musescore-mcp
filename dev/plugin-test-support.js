// Execute the shipped plugin functions, rather than copies of their logic.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../musescore-mcp-plugin.qml'), 'utf8');
const functions = [...source.matchAll(/^    function \w+\([^\n]*\) \{[\s\S]*?^    \}/gm)]
    .map(match => match[0]).join('\n');

function loadPlugin(globals = {}, overrides = {}) {
    const context = {
        root: {currentVoice: 0, allowEval: false, codeState: {}, swapCodePrefix: '',
            commandDepth: 0, commandFailed: false, commandScore: null,
            commandSelection: null, commandVoice: 0, evaluatingCode: false, sequenceDepth: 0,
            selectionPending: false},
        selectionState: {startStaff: 0, endStaff: 1, startTick: 0, endTick: 480, voice: 0, elements: []},
        console: {log() {}}, api: {log: {info() {}}},
        Cursor: {INPUT_STATE_INDEPENDENT: 0, INPUT_STATE_SYNC_WITH_SCORE: 1},
        fraction: (numerator, denominator) => ({numerator, denominator, ticks: 1920 * numerator / denominator}),
        ...globals,
    };
    vm.createContext(context);
    vm.runInContext(functions, context, {filename: 'musescore-mcp-plugin.qml.functions'});
    Object.assign(context, overrides);
    return context;
}

module.exports = {loadPlugin, source, plain: value => JSON.parse(JSON.stringify(value))};
