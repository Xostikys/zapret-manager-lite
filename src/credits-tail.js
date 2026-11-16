
return view.extend({
    handleSave: null, handleSaveApply: null, handleReset: null,
    render: function() {
        return E('div', {}, [
            E('h2', {}, ['Авторы и исходные проекты']),
            E('p', {}, ['Zapret Manager — StressOzz. Авторы компонентов:']),
            E('ul', {}, CREDITS.map(function(item) {
                return E('li', {}, [item.product + ' — ' + item.author]);
            }))
        ]);
    }
});
