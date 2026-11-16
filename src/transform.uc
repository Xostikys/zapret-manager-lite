import { readfile, writefile } from 'fs';

// Only static UI files are transformed. Never execute source from the manager.
let fragments = json(readfile('fragments.json'));
function save(name, text) {
    assert(type(text) == 'string' && length(text) > 0, 'Empty UI output');
    assert(writefile('new/' + name, text) == length(text), 'Cannot stage ' + name);
}
function remove_fragment(text, fragment, hint) {
    let pos = index(text, fragment);
    if (pos >= 0) {
        text = substr(text, 0, pos) + substr(text, pos + length(fragment));
        assert(index(text, fragment) < 0, 'Duplicate UI fragment');
    }
    assert(index(text, hint) < 0, 'Unknown updated UI layout: ' + hint);
    return text;
}
let menu = json(readfile('old/menu.json'));
assert(type(menu) == 'object', 'Unexpected LuCI menu');
assert(type(menu['admin/services/zapret-manager']) == 'object', 'Manager entry missing');
delete menu['admin/services/zapret-manager/thanks'];
save('menu.json', sprintf('%.2J\n', menu));

let css = readfile('old/style.css');
assert(type(css) == 'string' && index(css, '.zm-card') >= 0, 'Unknown CSS layout');
let begin = index(css, '/* ZM-LOCAL-UI-BEGIN');
if (begin >= 0) {
    let end = index(css, '/* ZM-LOCAL-UI-END */');
    assert(end > begin, 'Incomplete local CSS block');
    css = substr(css, 0, begin) + substr(css, end + length('/* ZM-LOCAL-UI-END */'));
}
assert(index(css, '/* ZM-LOCAL-UI-BEGIN') < 0, 'Duplicate local CSS block');
// Trim only trailing whitespace: repeat execution produces identical bytes.
css = rtrim(css) + '\n\n' + readfile('lite.css');
save('style.css', css);

let dashboard = readfile('old/dashboard.js');
if (dashboard != null) {
    dashboard = remove_fragment(dashboard, fragments.header, 'stresskvn.lol');
    assert(index(lc(dashboard), 't.me/stressozz_manager') < 0, 'Unknown Telegram header layout');
    let label = 'Zapret Manager для LuCI и Web';
    let pos = index(dashboard, label);
    if (pos >= 0) dashboard = substr(dashboard, 0, pos) + 'Zapret Manager для LuCI' + substr(dashboard, pos + length(label));
    save('dashboard.js', dashboard);
}
let system = readfile('old/system.js');
if (system != null) {
    system = remove_fragment(system, fragments.webcard, 'var zwCard = E(');
    assert(index(system, 'zm.webui(') < 0, 'Unknown standalone Web controls');
    save('system.js', system);
}
let thanks = readfile('old/thanks.js');
if (thanks != null) {
    let start = index(thanks, 'var CREDITS = [');
    assert(start >= 0 && index(thanks, 'return view.extend') >= 0, 'Unknown credits layout');
    let rest = substr(thanks, start);
    let end = index(rest, '\n];');
    assert(end > 0, 'Unknown credits array');
    let credits = substr(rest, 0, end + 3);
    // Preserve the current version's author list rather than an older snapshot.
    save('thanks.js', readfile('credits-head.js') + credits + readfile('credits-tail.js'));
}
