// Pure-JS regression checks for plugin Harmony traversal and edit validation.
// Run: node dev/harmony-test.js. MuseScore runtime checks are separate.
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = fs.readFileSync(require('node:path').join(__dirname, '../musescore-mcp-plugin.qml'), 'utf8');
const harmonyCode = source.slice(source.indexOf('    function harmonyData('), source.indexOf('    // Voice census'));
const indexCode = source.slice(source.indexOf('    function measureIndexForTick('), source.indexOf('    // Harmony annotations'));
let checks = 0;
function check(name, fn) { fn(); checks++; console.log('PASS', name); }
function fixture() {
    // Include a symbol at a segment where staff 0 has no note, two symbols
    // on one track, two voices, and an unrelated annotation.
    const segments = [0, 480, 960].map(tick => ({tick, annotations: []}));
    segments.forEach((seg, i) => seg.next = segments[i + 1] || null);
    const notePositions = {0: [0, 480], 4: [480, 960], 5: [480]};
    function symbol(seg, track, text, type = 0) {
        const e = {type: 99, track, staffIdx: Math.floor(track / 4), harmonyType: type, text};
        seg.annotations.push(e); return e;
    }
    symbol(segments[0], 0, 'F');
    symbol(segments[1], 4, 'C7/E');
    symbol(segments[1], 4, 'Dm');
    symbol(segments[1], 5, 'V', 1);
    symbol(segments[2], 4, 'B♭');
    segments[0].annotations.push({type: 1});
    let snapshot;
    const ends = [];
    const score = {
        nstaves: 2,
        firstSegment: () => segments[0],
        startCmd() { snapshot = segments.map(s => s.annotations.map(a => ({...a}))); },
        endCmd(rollback) {
            ends.push(!!rollback);
            if (rollback) segments.forEach((s, i) => s.annotations = snapshot[i]);
        },
        newCursor() {
            let position = 0;
            return {
                staffIdx: 0, voice: 0,
                rewind() { position = 0; this.seek(); },
                seek() {
                    const ticks = notePositions[this.staffIdx * 4 + this.voice] || [];
                    this.tick = ticks[position];
                    this.segment = segments.find(s => s.tick === this.tick) || null;
                    this.element = this.segment ? {name: 'Chord'} : null;
                },
                next() { position++; this.seek(); return !!this.segment; },
                add(e) {
                    e.track = this.staffIdx * 4 + this.voice;
                    e.staffIdx = this.staffIdx;
                    e.attached = true;
                    this.segment.annotations.push(e);
                }
            };
        }
    };
    const context = {
        curScore: score, Element: {HARMONY: 99}, Cursor: {INPUT_STATE_INDEPENDENT: 1},
        measureBoundaries: () => [0, 960],
        newElement: () => {
            let text = '';
            return {type: 99, harmonyType: 0,
                get text() { return text; },
                set text(value) {
                    assert.equal(this.attached, true, 'attach before invoking native Harmony parser');
                    if (value === 'THROW') throw Error('parser failure');
                    text = value;
                }};
        }
    };
    vm.createContext(context);
    vm.runInContext(indexCode + harmonyCode, context);
    return {context, segments, ends};
}
const plain = value => JSON.parse(JSON.stringify(value));
check('reads symbols once across all tracks, including annotation-only staff-0 positions', () => {
    const {context: c} = fixture();
    const hs = plain(c.getHarmonies({}).harmonies);
    assert.deepEqual(hs.map(h => h.text), ['F', 'C7/E', 'Dm', 'V', 'B♭']);
    assert.deepEqual(hs.map(h => [h.measure, h.voice, h.index]), [[1,0,0],[1,0,0],[1,0,1],[1,1,0],[2,0,0]]);
});
check('staff and half-open tick filters', () => {
    const {context: c} = fixture();
    assert.equal(c.getHarmonies({staff: 1, startTick: 480, endTick: 960}).harmonies.length, 3);
    assert.equal(c.getHarmonies({endTick: 0}).harmonies.length, 0);
});
check('updates exactly the selected duplicate, preserving type and other symbols', () => {
    const {context: c, ends} = fixture();
    assert.throws(() => c.setHarmony({staff: 1, startTick: 480, text: 'G'}), /Multiple harmonies/);
    const result = c.setHarmony({staff: 1, startTick: 480, index: 1, text: 'G7/B'});
    assert.equal(result.created, false);
    assert.deepEqual(plain(c.getHarmonies({}).harmonies.map(h => h.text)), ['F','C7/E','G7/B','V','B♭']);
    c.setHarmony({staff: 1, voice: 1, startTick: 480, text: 'IV'});
    assert.equal(c.getHarmonies({}).harmonies[3].harmonyType, 1);
    assert.deepEqual(ends, [false, false]);
});
check('creates a slash chord, attaches before parsing, and reports its position', () => {
    const {context: c} = fixture();
    const result = c.setHarmony({staff: 0, startTick: 480, text: 'C7/E'});
    assert.equal(result.created, true);
    assert.deepEqual(plain(result.harmony), {name:'Harmony',text:'C7/E',harmonyType:0,staffIdx:0,voice:0,startTick:480,measure:1,index:0});
    assert.equal(c.getHarmonies({}).harmonies.length, 6);
});
check('rejects missing exact positions and invalid requests before mutation', () => {
    const {context: c, ends} = fixture();
    for (const params of [
        {staff:0,startTick:1,text:'C'}, {staff:0,startTick:99999,text:'C'},
        {staff:2,startTick:0,text:'C'}, {staff:0,startTick:-1,text:'C'},
        {staff:0,startTick:0,text:''}, {staff:0,startTick:0,text:'C',voice:4},
        {staff:0,startTick:0,text:'C',harmonyType:3},
        {staff:0,startTick:0,text:'C',index:1}, {staff:0,text:'C'}
    ]) assert.throws(() => c.setHarmony(params));
    assert.throws(() => c.getHarmonies({startTick:480,endTick:0}));
    assert.deepEqual(ends, []);
    assert.equal(c.getHarmonies({}).harmonies.length, 5);
});
check('parser exception rolls back new symbol', () => {
    const {context: c, ends} = fixture();
    assert.throws(() => c.setHarmony({staff:0,startTick:480,text:'THROW'}), /parser failure/);
    assert.deepEqual(ends, [true]);
    assert.equal(c.getHarmonies({}).harmonies.length, 5);
});
console.log(`${checks}/${checks} checks passed`);
