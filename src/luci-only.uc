import { readfile, writefile } from 'fs';
let known = json(readfile('known-functions.json'));
function cutfn(s, name, stub) {
    let start = index(s, '\n' + name + '() {\n');
    if (start < 0) return s;
    let tail = substr(s, start + 1), end = index(tail, '\n}\n');
    assert(end >= 0, 'Unknown function layout: ' + name);
    let body = substr(tail, 0, end + 3);
    assert(body == known[name], 'Updated function needs review: ' + name);
    let result = substr(s, 0, start + 1) + stub + substr(tail, end + 3);
    assert(index(result, '\n' + name + '() {\n') < 0, 'Duplicate function: ' + name);
    return result;
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
        // Keep the one-shot process alive until cleanup finishes. It uses the
        // addon stored outside the upstream installation, then patches the new
        // updater too. Unrecognised future updater layouts stay untouched.
        if (p.kind == 'shell') {
            line = join('sh /etc/zm-local-ui/fetch-manager.sh "$1" ||', split(line, '_zm_gh_get "$ZM_SCRIPT_URL" "$1" ||'));
            line = join('не удалось скачать установщик напрямую с GitHub; обновление отменено', split(line, 'не удалось скачать установщик с GitHub — ни напрямую, ни через WARP'));
            let before = '( sleep 5; sh "$tmp" $arg >/tmp/zm_update_install.log 2>&1; rm -f "$tmp" )';
            let after = '( sleep 5; if sh "$tmp" $arg >/tmp/zm_update_install.log 2>&1; then sh /etc/zm-local-ui/after-update.sh >>/tmp/zm_update_install.log 2>&1; fi; rm -f "$tmp" )';
            line = join(after, split(line, before));
        }
        // Upstream uses this text as an installer completeness sentinel.
        // It is protocol data, not a visible label. Repair older local rewrites
        // and preserve the original check, including its failure handling.
        if (p.kind == 'shell' && index(line, 'tail -n 5 "$1" | grep -q ') >= 0) {
            line = join("grep -q 'Web UI:'", split(line, "grep -q 'панель LuCI:'"));
            if (index(line, "grep -q 'Web UI:'") >= 0) {
                push(out, line);
                continue;
            }
        }
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
