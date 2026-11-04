// Regression tests for real plugin functions with a model of the native
// cursor and boolean undo lock. Native layout/command integration needs MuseScore.
const assert = require('node:assert/strict');
const {loadPlugin, plain} = require('./plugin-test-support');
const Element = {CHORD: 1, REST: 2, TIMESIG: 3, KEYSIG: 4, TEMPO_TEXT: 5, HARMONY: 99};
const clone = value => JSON.parse(JSON.stringify(value));

function fixture() {
    let state = {
        measures: [480, 1920, 1440, 1920], // pickup, 4/4, 3/4, 4/4
        tracks: {
            0: [{tick:0,pitches:[60],duration:480,lyrics:[{text:'a\u030a',verse:0}]}, {tick:480,pitches:[60],duration:1920},
                {tick:2400,pitches:[62],duration:1440}, {tick:3840,pitches:[67],duration:1920}],
            1: [{tick:0,pitches:[60],duration:480}, {tick:480,pitches:[64,67],duration:960},
                {tick:1440,pitches:[],duration:960}, {tick:2400,pitches:[65],duration:1440}],
            4: [{tick:0,pitches:[48],duration:480}, {tick:480,pitches:[48],duration:1920},
                {tick:2400,pitches:[50],duration:1440}, {tick:3840,pitches:[55],duration:1920}],
            5: [{tick:0,pitches:[48],duration:480}, {tick:480,pitches:[52],duration:1920},
                {tick:2400,pitches:[53],duration:1440}],
        },
        annotations: {},
    };
    let saved, active = false, locked = false, nativeStarts = 0, nativeEnds = 0;
    const history = [];
    const commandCalls = [];
    function measures() {
        let tick = 0;
        const table = state.measures.map((length, index) => {
            const m = {tick:{ticks:tick}, ticks:{ticks:length},
                timesigNominal:{numerator:index===2 ? 3 : 4, denominator:4}};
            tick += length;
            return m;
        });
        table.forEach((m, i) => m.nextMeasure = table[i + 1] || null);
        return table;
    }
    const end = () => state.measures.reduce((a,b) => a+b,0);
    function wrap(event, track) {
        if (!event) return null;
        const notes = event.pitches.map(pitch => ({pitch, tpc:pitch % 12}));
        return {name:notes.length ? 'Chord':'Rest', type:notes.length ? Element.CHORD:Element.REST,
            voice:track % 4, staffIdx:Math.floor(track/4), track, notes,
            fraction:{ticks:event.tick}, actualDuration:{ticks:event.duration},
            durationType:{type:2,dots:0}, tuplet:event.tuplet || null,
            lyrics:(event.lyrics || []).map(lyric=>({
                get text() {return lyric.text;}, set text(value) {lyric.text=value;},
                get plainText() {return lyric.text;},verse:lyric.verse})), visible:true};
    }
    function segment(tick) {
        return {tick, annotations:state.annotations[tick] || [],
            elementAt(track) {return wrap((state.tracks[track] || []).find(e=>e.tick===tick),track);}};
    }
    let range = {start:0,end:480,staff:0,endStaff:1};
    const selection = {
        get startSegment() {return range && !range.planned ? {tick:range.start}:null;},
        get endSegment() {return range && range.end < end() ? {tick:range.end}:null;},
        get startStaff() {return range ? range.staff:0;},
        get endStaff() {return range ? range.endStaff:1;},
        elements: [],
        selectRange(start,finish,staff,endStaff) {
            if (finish > end()) finish=end(); // native null end sentinel
            else if (finish === end()) {
                // Native tick2leftSegment(scoreEnd) resolves the final event.
                finish=Math.max(...Object.values(state.tracks).flat().map(e=>e.tick));
            }
            if (start<0 || finish<=start || finish>end() || staff<0 || endStaff<=staff || endStaff>2) return false;
            range={start,end:finish,staff,endStaff,planned:active && finish < end()}; return true;
        },
        clear() {range=null;},
        select() {return true;},
    };
    const part = {partName:'Piano', instrumentId:'grand-piano', longName:'Piano',
        startTrack:0,endTrack:8,instruments:[{instrumentId:'grand-piano', channels:[
            {name:'normal', volume:100,pan:64,chorus:0,reverb:0,midiProgram:0,midiBank:0}]}]};
    const score = {
        get nmeasures() {return state.measures.length;}, nstaves:2, keysig:-1,
        get firstMeasure() {return measures()[0];},
        get lastMeasure() {return measures().at(-1);},
        parts:[part], staves:[0,1].map(()=>({part,visible:true,playbackVoice1:true,
            playbackVoice2:true,playbackVoice3:true,playbackVoice4:true})), selection,
        metaTag(key) {return {workTitle:'Regression score',composer:'Test Composer',
            lyricist:'Test Lyricist',copyright:'Test Copyright'}[key] || '';},
        startCmd() {
            nativeStarts++;
            if (!locked) {saved=clone(state);active=true;}
            locked=true;
        },
        endCmd(rollback) {
            nativeEnds++;locked=false;
            if (active) {
                if (rollback) state=clone(saved);
                else history.push(clone(saved));
                active=false;
            }
        },
        setVoiceVisible() {return false;},
        replaceInstrument(target, instrumentId) {target.instrumentId=instrumentId;},
        appendPart(instrumentId) {
            this.parts.push({partName:instrumentId,instrumentId,startTrack:this.nstaves*4,
                endTrack:(this.nstaves+1)*4,instruments:[]});
            this.staves.push({part:this.parts.at(-1),visible:true});
            this.nstaves++;
        },
        firstSegment() {
            const ticks=[...new Set([...measures().map(m=>m.tick.ticks),
                ...Object.values(state.tracks).flat().map(e=>e.tick)])].sort((a,b)=>a-b);
            const segs=[];
            for (const tick of ticks) {
                if (tick===0 || tick===2400) segs.push({tick,annotations:[],
                    elementAt:track=>track===0 ? {type:Element.KEYSIG,actualKey:tick===0 ? -1:2}:null});
                segs.push(segment(tick));
            }
            segs.forEach((seg,i)=>seg.next=segs[i+1] || null);
            return segs[0];
        },
        newCursor() {
            let position=null, duration=480;
            const c={staffIdx:0,voice:0,
                get track() {return this.staffIdx*4+this.voice;},
                get tick() {return position===null ? 0:position;},
                get segment() {return position===null ? null:segment(position);},
                get element() {return position===null ? null:wrap((state.tracks[this.track] || []).find(e=>e.tick===position),this.track);},
                rewind() {position=(state.tracks[this.track] || [])[0]?.tick ?? null;},
                rewindToTick(tick) {position=(state.tracks[this.track] || []).find(e=>e.tick>=tick)?.tick ?? null;},
                rewindToFraction(f) {
                    const tick=f.ticks;
                    const exists=measures().some(m=>m.tick.ticks===tick)
                        || Object.values(state.tracks).some(es=>es.some(e=>e.tick===tick));
                    position=exists ? tick:null;
                },
                next() {position=(state.tracks[this.track] || []).find(e=>e.tick>position)?.tick ?? null;return position!==null;},
                setDuration(n,d) {duration=1920*n/d;},
                addNote(pitch,add) {
                    if (position===null) return;
                    let es=state.tracks[this.track] ||= [];
                    let e=es.find(e=>e.tick===position);
                    if (add && e?.pitches.length) e.pitches.push(pitch);
                    else {
                        es=es.filter(e=>e.tick!==position);
                        es.push({tick:position,pitches:[pitch],duration});
                        state.tracks[this.track]=es.sort((a,b)=>a.tick-b.tick);
                    }
                },
                addRest() {
                    const es=(state.tracks[this.track] || []).filter(e=>e.tick!==position);
                    es.push({tick:position,pitches:[],duration});
                    state.tracks[this.track]=es.sort((a,b)=>a.tick-b.tick);
                },
                addTuplet(ratio,span) {
                    this.addRest();
                    const e=state.tracks[this.track].find(e=>e.tick===position);
                    e.duration=span.ticks/ratio.numerator;e.tuplet={duration:span};
                },
                add(element) {
                    element.track=this.track;element.staffIdx=this.staffIdx;
                    (state.annotations[position] ||= []).push(element);
                },
            };
            return c;
        },
    };
    let brokenCandidate = false;
    function cmd(code) {
        commandCalls.push(code);
        if (code.includes('undo')) {
            if (locked) return;
            if (history.length) state=history.pop();
        } else if (code==='append-measure') state.measures.push(1920);
        else if (code==='insert-measure') state.measures.push(1920);
        else if (/voice-x\d\d$/.test(code)) {
            if (range.planned) return; // native tickStart is -1 until commit
            const [a,b]=code.slice(-2).split('').map(n=>Number(n)-1);
            if (!code.startsWith('voice-x')) return;
            for (let staff=range.staff;staff<range.endStaff;staff++) {
                const ta=staff*4+a,tb=staff*4+b;
                const ea=clone(state.tracks[ta] || []),eb=clone(state.tracks[tb] || []);
                const inside=e=>e.tick>=range.start && e.tick<range.end;
                state.tracks[ta]=[...ea.filter(e=>!inside(e)),...eb.filter(inside)].sort((x,y)=>x.tick-y.tick);
                state.tracks[tb]=[...eb.filter(e=>!inside(e)),...ea.filter(inside)].sort((x,y)=>x.tick-y.tick);
                if (brokenCandidate) state.tracks[ta].find(inside).pitches[0]=99;
            }
        }
    }
    const context=loadPlugin({curScore:score,Element,cmd,mscoreMajorVersion:4,mscoreMinorVersion:7,
        newElement:type=>({type,name:type===Element.TEMPO_TEXT ? 'TempoText':'TimeSig'})});
    return {c:context,score,history,commandCalls,state:()=>clone(state),
        stats:()=>({starts:nativeStarts,ends:nativeEnds,locked}),breakSwap:()=>brokenCandidate=true};
}

let checks=0;
function check(name,fn) {fn();checks++;console.log('PASS',name);}
if (require.main === module) {
check('summary reads every staff/voice with empty current voice and preserves selection/undo',()=>{
    const f=fixture(),c=f.c;c.root.currentVoice=3;
    const selected=plain(c.selectionState),before=f.state();
    const score=c.getScoreSummary();
    assert.deepEqual(plain(score.measures.map(m=>m.startTick)),[0,480,2400,3840]);
    assert.equal(score.measures[1].numElements,5);
    assert.equal(score.measures[2].elements.staff1[0].notes[0].pitchMidi,50);
    assert.deepEqual(plain(c.selectionState),selected);assert.deepEqual(f.state(),before);
    assert.deepEqual(f.stats(),{starts:0,ends:0,locked:false});
});
check('metadata reads native tags and nominal time/key changes, including pickup',()=>{
    const {c}=fixture();const meta=c.getScoreMetadata({}).metadata;
    assert.equal(meta.title,'Regression score');assert.equal(meta.composer,'Test Composer');
    assert.equal(meta.lyricist,'Test Lyricist');assert.equal(meta.copyright,'Test Copyright');
    assert.equal(meta.measures[0].durationTicks,480);
    assert.deepEqual(plain(meta.measures.map(m=>m.timeSignature.numerator)),[4,4,3,4]);
    assert.deepEqual(plain(meta.measures.map(m=>m.keySignature)),[-1,-1,2,2]);
});
check('voice census staff alias, half-open interval, empty range and per-measure counts',()=>{
    const {c}=fixture();
    let r=c.getVoices({staff:1,startTick:480,endTick:2400,perMeasure:true});
    assert.equal(r.staves.length,1);assert.equal(r.staves[0].staff,1);
    assert.equal(r.staves[0].voices[0].elementCount,1);
    assert.deepEqual(plain(r.staves[0].voices[0].measures),[{measure:2,hasContent:true,elementCount:1}]);
    assert.equal(c.getVoices({startTick:100000,endTick:100001}).staves[0].voices[0].hasContent,false);
    assert.equal(c.getVoices({measure:3,staff:0}).staves[0].voices[1].firstMeasure,3);
    assert.match(c.getVoices({staff:1,startStaff:0}).error,/conflicts/);
});
check('goToMeasure explicit voice is retained by later writes without a voice parameter',()=>{
    const f=fixture(),c=f.c;
    assert.equal(c.goToMeasure({measure:2,voice:1}).success,true);
    assert.equal(c.root.currentVoice,1);
    assert.equal(c.addNote({pitch:72,duration:{numerator:1,denominator:4},advanceCursorAfterAction:false}).success,true);
    assert(f.state().tracks[1].find(e=>e.tick===480).pitches.includes(72));
    assert(!f.state().tracks[0].find(e=>e.tick===480).pitches.includes(72));
});
check('tuplets and rests use explicit voice on second staff and a valid exclusive staff end',()=>{
    const f=fixture(),c=f.c;
    c.selectCustomRange({startTick:480,endTick:2400,startStaff:1,endStaff:2});
    c.selectionState.voice=0;
    assert.equal(c.addTuplet({voice:2,duration:{numerator:1,denominator:4},ratio:{numerator:3,denominator:2},advanceCursorAfterAction:false}).success,true);
    assert(f.state().tracks[6][0].tuplet);assert.equal(c.selectionState.endStaff,2);
    assert.equal(c.addRest({voice:3,duration:{numerator:1,denominator:4},advanceCursorAfterAction:false}).success,true);
    assert.equal(f.state().tracks[7][0].pitches.length,0);
});
check('selectCurrentMeasure does not sum concurrent voices',()=>{
    const {c}=fixture();c.goToMeasure({measure:2});
    assert.equal(c.selectCurrentMeasure().success,true);
    assert.equal(c.selectionState.startTick,480);assert.equal(c.selectionState.endTick,2400);
});
check('navigation boundaries do not leave undo locked or append unrequested measures',()=>{
    const f=fixture(),c=f.c;
    assert.equal(c.prevStaff({}).success,false);
    c.selectCustomRange({startTick:0,endTick:480,startStaff:1,endStaff:2});
    assert.equal(c.nextStaff({}).success,false);
    assert.equal(c.goToFinalMeasure({}).success,true);
    assert.equal(c.nextElement({}).success,false);
    assert.equal(f.score.nmeasures,4);assert.deepEqual(f.stats(),{starts:0,ends:0,locked:false});
});
check('undo is accepted through the same sequence path used by MCP',()=>{
    const f=fixture(),c=f.c;
    assert.equal(c.processSequence({sequence:[{action:'appendMeasure',params:{count:1}},{action:'undo',params:{}}]}).success,true);
    assert.equal(f.score.nmeasures,4);assert.equal(f.stats().locked,false);
});
check('runCode nested actions/read summaries commit once and undo together',()=>{
    const f=fixture(),c=f.c;c.root.allowEval=true;
    const result=c.runCode({code:'ctx.processCommand({action:"appendMeasure",params:{count:1}});ctx.getScoreSummary();ctx.processCommand({action:"appendMeasure",params:{count:1}});return ctx.score.nmeasures;'});
    assert.equal(result.status,'success');assert.equal(result.result,6);
    assert.deepEqual(f.stats(),{starts:1,ends:1,locked:false});assert.equal(f.history.length,1);
    c.undo();assert.equal(f.score.nmeasures,4);
});
check('runCode restores nested mutations and invalid JSON results',()=>{
    for (const code of ['throw new Error("deliberate");','var o={};o.o=o;return o;']) {
        const f=fixture(),c=f.c;c.root.allowEval=true;const before=f.state();
        const r=c.runCode({code:'ctx.processCommand({action:"appendMeasure",params:{count:1}});'+code});
        assert.equal(r.status,'error');assert.deepEqual(f.state(),before);
        assert.deepEqual(f.stats(),{starts:1,ends:1,locked:false});
    }
});
check('nested cursor navigation uses logical state while native range updates are deferred',()=>{
    const f=fixture(),c=f.c;c.root.allowEval=true;const before=f.state();
    const r=c.runCode({code:'ctx.processCommand({action:"goToMeasure",params:{measure:3,voice:1}});ctx.processCommand({action:"addNote",params:{pitch:72,duration:{numerator:1,denominator:4},advanceCursorAfterAction:false}});return true;'});
    assert.equal(r.status,'success',r.error);
    assert(f.state().tracks[1].find(e=>e.tick===2400).pitches.includes(72));
    c.undo();assert.deepEqual(f.state(),before);
});
check('selection-based nested commands require the prepared native range and roll back on mismatch',()=>{
    const f=fixture(),c=f.c;c.root.allowEval=true;const before=f.state();
    const rejected=c.runCode({code:'ctx.processCommand({action:"goToMeasure",params:{measure:2}});ctx.processCommand({action:"swapVoices",params:{voice1:0,voice2:1,measure:2}});'});
    assert.equal(rejected.status,'error');assert.deepEqual(f.state(),before);
    c.selectCustomRange({startTick:480,endTick:3840,startStaff:0,endStaff:2});
    const accepted=c.runCode({code:'ctx.processCommand({action:"swapVoices",params:{voice1:0,voice2:1}});return true;'});
    assert.equal(accepted.status,'success',accepted.error);
    c.undo();assert.deepEqual(f.state(),before);
});
check('eval gate and rollback-unsafe operations are enforced before playback changes',()=>{
    const f=fixture(),c=f.c;
    assert.match(c.runCode({code:'return 1;'}).error,/disabled/);
    c.root.allowEval=true;
    for (const action of ['undo','setStaffMute','setChannelProperties','setVoicePlayback','runCode']) {
        const r=c.runCode({code:'ctx.processCommand({action:'+JSON.stringify(action)+',params:{staff:0,mute:true,volume:1,voice:1,play:false}});'});
        assert.equal(r.status,'error');assert.equal(f.score.staves[0].playbackVoice1,true);
    }
});
check('swap checks later notes, rhythms and both staves within selected measure range',()=>{
    const f=fixture(),c=f.c;const before=f.state();
    c.selectCustomRange({startTick:480,endTick:3840,startStaff:0,endStaff:2});
    const r=c.swapVoices({voice1:0,voice2:1});
    assert.equal(r.success,true,r.error);assert.equal(r.startTick,480);assert.equal(r.endTick,3840);
    assert.deepEqual(f.state().tracks[0].find(e=>e.tick===480).pitches,[64,67]);
    assert.deepEqual(f.state().tracks[4].find(e=>e.tick===2400).pitches,[53]);
    c.undo();assert.deepEqual(f.state(),before);
});
check('swap ignores identical prefixes outside range and rolls back every bad candidate',()=>{
    const f=fixture(),c=f.c;const before=f.state();
    f.breakSwap();const r=c.swapVoices({voice1:0,voice2:1,measure:2,startStaff:0,endStaff:2});
    assert(r.error);assert.deepEqual(f.state(),before);
    assert.equal(f.stats().starts,3);assert.equal(f.stats().ends,3);assert.equal(f.history.length,0);
});
check('partial-measure swap is refused before any edit',()=>{
    const f=fixture(),c=f.c;const before=f.state();
    assert.match(c.swapVoices({voice1:0,voice2:1,startTick:480,endTick:1440}).error,/whole-measure/);
    assert.deepEqual(f.state(),before);assert.equal(f.stats().starts,0);
});
check('native rejected voice visibility is an error, not false success',()=>{
    const f=fixture(),c=f.c;
    const r=c.setVoiceVisibility({staff:0,voice:1,visible:false});
    assert.match(r.error,/linked part/);assert.equal(f.history.length,0);assert.equal(f.stats().locked,false);
});
check('staff mute modifies playback only, and tempo sets quarters per second',()=>{
    const f=fixture(),c=f.c;
    assert.equal(c.setStaffMute({staff:1,mute:true}).success,true);
    assert.equal(f.score.staves[1].playbackVoice1,false);assert.equal(f.score.staves[1].visible,true);
    assert.equal(c.setStaffMute({staff:1,mute:false}).success,true);
    assert.equal(c.setTempo({bpm:90}).success,true);
    assert.equal(f.state().annotations[0][0].tempo,1.5);
});
check('all complete cookbook examples execute, and reduction stays within measure bounds',()=>{
    const fs=require('node:fs'),path=require('node:path');
    const doc=fs.readFileSync(path.join(__dirname,'../docs/AGENT-COOKBOOK.md'),'utf8');
    const codes=[...doc.matchAll(/## Example [123]:[\s\S]*?```js\n([\s\S]*?)```/g)].map(m=>m[1]);
    assert.equal(codes.length,3);
    for (let i=0;i<codes.length;i++) {
        const f=fixture(),c=f.c;c.root.allowEval=true;
        f.score.nstaves=3;f.score.staves.push({...f.score.staves[0]});
        if (i===2) {
            // Only rests in measure 2; an unbounded search would borrow the
            // first chord in measure 3. The model intentionally has a gap.
            const c0=c.curScore.newCursor();c0.staffIdx=0;c0.voice=0;c0.rewindToFraction(c.fraction(480,1920));c0.setDuration(1,1);c0.addRest();
            const c1=c.curScore.newCursor();c1.staffIdx=1;c1.voice=0;c1.rewindToFraction(c.fraction(480,1920));c1.setDuration(1,1);c1.addRest();
        }
        const before=f.state();const r=c.runCode({code:codes[i]});
        assert.equal(r.status,'success',r.error);
        if (i===0) assert.equal(r.result[0].text,'a\u030a');
        if (i===1) assert.equal(f.state().tracks[0][0].lyrics[0].text,'å');
        if (i===2) {
            assert(!r.result.some(row=>row.measure===2));
            assert.equal(f.state().tracks[8][0].duration,480); // pickup, not a whole note
        }
        c.undo();assert.deepEqual(f.state(),before);
    }
});
check('plugin logs omit incoming code, parameters and eval exception payloads',()=>{
    const {c}=fixture();c.root.allowEval=true;
    const logs=[],replies=[];
    c.api.log.info=line=>logs.push(line);
    c.api.websocketserver={send(_id,reply){replies.push(JSON.parse(reply));}};
    const secret='PRIVATE_EVAL_CODE_AND_PARAMS';
    c.processMessage(JSON.stringify({action:'runCode',params:{
        code:'throw new Error("'+secret+'");',params:{secret}}}),1);
    assert(!logs.join('\n').includes(secret));
    assert(replies[0].result.error.includes(secret)); // error is returned to its caller
});
console.log(`${checks}/${checks} plugin regression checks passed`);
}

module.exports = {fixture};
