import { readfile, writefile } from 'fs';
function cutfn(s, name, stub) {
    let start = index(s, '\n' + name + '() {\n');
    if (start < 0) return s;
    let tail = substr(s, start + 1), end = index(tail, '\n}\n');
    assert(end >= 0, 'Unknown function layout: ' + name);
    return substr(s, 0, start + 1) + stub + substr(tail, end + 3);
}
let plan = json(readfile('plan.json'));
for (let i = 0; i < length(plan); i++) {
    let p = plan[i], s = readfile('old/' + p.id);
    assert(type(s) == 'string', 'Cannot read component');
    if (p.kind == 'shell') {
        // Multiline implementation is removed before dispatch/forwarder lines.
        s = cutfn(s, 'webui', '');
        s = cutfn(s, '_zmw_saved', '');
        s = cutfn(s, '_zmw_save', '');
        s = cutfn(s, '_zmw_used', '');
        s = cutfn(s, '_zmw_port', '_zmw_port() { return 1; }\n');
    }
    let lines = split(s, '\n'), out = [];
    for (let j = 0; j < length(lines); j++) {
        let line = lines[j];
        if (match(line, /^webui\(\) \{ _zmL/) ||
            match(line, /^\s*webui\)/) ||
            index(line, 'json_add_object "webui"') >= 0 ||
            match(line, /^\s*"webui",?\s*$/) ||
            index(line, 'var callWebui = ') >= 0 ||
            index(line, 'webui: callWebui') >= 0) continue;
        if (index(line, '/www/zm/theme.txt') >= 0 || index(line, '/www/zm/look.json') >= 0) continue;
        line = join('mkdir -p "$ZM_STATE_DIR"', split(line, 'mkdir -p "$ZM_STATE_DIR" /www/zm'));
        line = join('Zapret Manager для LuCI', split(line, 'Zapret Manager для LuCI и Web'));
        for (let k = 0; k < 2; k++) {
            let old = [' и Web UI', 'Web UI и '][k];
            line = join('', split(line, old));
        }
        line = join('панель LuCI', split(line, 'Web UI'));
        push(out, line);
    }
    s = join('\n', out);
    assert(index(s, 'webui()') < 0 && index(s, 'callWebui') < 0, 'Component still exposes standalone controls');
    if (p.kind == 'json') json(s);
    assert(writefile('new/' + p.id, s) == length(s), 'Cannot stage component');
}
