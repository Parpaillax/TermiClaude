'use strict';

// Plugin Hyper compagnon de HyperClaude (palier L3).
//
// Recoit un ordre de focus ecrit par le widget dans ~/.hyperclaude/focus.json
// { shellPid, tty, ts } et met au premier plan la fenetre Hyper dont une session
// correspond (pty.pid === shellPid, ou tty identique en repli).
//
// Tourne dans le PROCESS PRINCIPAL de Hyper (hooks onApp / onWindow), seul endroit
// ou l'on peut acceder aux fenetres et a leurs sessions node-pty.

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const DIR = path.join(os.homedir(), '.hyperclaude');
const REQ = path.join(DIR, 'focus.json');
const LOG = path.join(DIR, 'plugin.log');
const STALE_MS = 10000;

const windows = new Set();
let watcher = null;

function log(msg) {
  try {
    fs.appendFileSync(LOG, '[' + new Date().toISOString() + '] ' + msg + '\n');
  } catch (e) { /* silencieux */ }
}

// tty d'un pid via ps (repli quand shellPid ne suffit pas). ps -o tty= rend "ttys016".
function ttyOf(pid) {
  try {
    return execFileSync('ps', ['-o', 'tty=', '-p', String(pid)], { encoding: 'utf8' }).trim() || null;
  } catch (e) {
    return null;
  }
}

// pids des sessions (node-pty) d'une fenetre. Defensif : l'API interne peut varier.
function windowPids(win) {
  const pids = [];
  try {
    const sessions = win && win.sessions;
    if (sessions && typeof sessions.forEach === 'function') {
      sessions.forEach((s) => {
        const pid = s && ((s.pty && s.pty.pid) || s.pid);
        if (pid) pids.push(pid);
      });
    }
  } catch (e) {
    log('windowPids error: ' + e.message);
  }
  return pids;
}

function focusWindow(win) {
  try {
    if (win.isMinimized && win.isMinimized()) win.restore();
    win.show();
    win.focus();
    if (win.moveTop) win.moveTop();
  } catch (e) {
    log('focus error: ' + e.message);
  }
}

function handleRequest() {
  let req;
  try {
    req = JSON.parse(fs.readFileSync(REQ, 'utf8'));
  } catch (e) {
    return; // fichier absent / ecriture en cours : on ignore, un autre event suivra
  }
  if (!req) return;
  if (req.ts && Date.now() - req.ts > STALE_MS) {
    log('requete perimee ignoree');
    return;
  }
  log('requete shellPid=' + req.shellPid + ' tty=' + req.tty);

  for (const win of windows) {
    const pids = windowPids(win);
    let match = req.shellPid && pids.indexOf(req.shellPid) !== -1;
    if (!match && req.tty) {
      match = pids.some((p) => ttyOf(p) === req.tty);
    }
    if (match) {
      log('fenetre trouvee (pids=' + pids.join(',') + '), focus');
      focusWindow(win);
      return;
    }
  }
  log('aucune fenetre correspondante (pids vus: ' +
    Array.from(windows).map((w) => windowPids(w).join(',')).join(' | ') + ')');
}

function startWatch() {
  try {
    fs.mkdirSync(DIR, { recursive: true });
  } catch (e) { /* ok */ }
  if (watcher) return;
  try {
    watcher = fs.watch(DIR, (event, filename) => {
      if (!filename || filename === 'focus.json') handleRequest();
    });
    log('surveillance active: ' + DIR);
  } catch (e) {
    log('watch error: ' + e.message);
  }
}

exports.onApp = () => {
  startWatch();
};

exports.onWindow = (win) => {
  windows.add(win);
  win.on('closed', () => windows.delete(win));
};
