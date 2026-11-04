// Line-oriented adapter for the plugin model, used by real MCP stdio tests.
const readline = require('node:readline');
const {fixture} = require('./plugin-regression-test');
const {c} = fixture();
const {source} = require('./plugin-test-support');
c.root.pluginVersion = source.match(/property string pluginVersion: "([^"]+)"/)[1];
c.root.allowEval = process.argv.includes('--allow-eval');
c.api.websocketserver = {send(_id, reply) { process.stdout.write(reply + '\n'); }};
readline.createInterface({input: process.stdin}).on('line', line => c.processMessage(line, 1));
