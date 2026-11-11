/**
 * Ti.Socketline example app: runs the self-test (selftest.js) against the local test server
 * (../server/server.js) on launch and shows the results. See ../README.md.
 * Copyright (c) 2026 Centreville Tech LLC. Licensed under the Apache License, Version 2.0.
 */
'use strict';

const selftest = require('selftest');

const win = Ti.UI.createWindow({ backgroundColor: '#fff', layout: 'vertical' });
const status = Ti.UI.createLabel({ top: 60, left: 16, right: 16, color: '#000', font: { fontSize: 16, fontWeight: 'bold' }, text: 'Ti.Socketline self-test' });
const current = Ti.UI.createLabel({ top: 8, left: 16, right: 16, color: '#444', font: { fontSize: 13 }, text: '' });
win.add([ status, current ]);

win.addEventListener('open', async () => {
	const counts = await selftest.run((name) => {
		current.text = name;
	});
	status.text = `passed ${counts.passed}, failed ${counts.failed}`;
	status.color = counts.failed === 0 ? '#060' : '#a00';
	current.text = 'Background check armed: send the app to the background and back.';
	selftest.armBackgroundCheck();
});

win.open();
