#!/usr/bin/env node
import { chromium } from 'playwright-core';
import { readFileSync, writeFileSync, mkdirSync } from 'fs';
import { dirname, isAbsolute, resolve } from 'path';
import { fileURLToPath } from 'url';

const CLI_DIR = dirname(fileURLToPath(import.meta.url));
const STATE_FILE = resolve(CLI_DIR, '.state.json');
const ENDPOINT = process.env.BROWSER_CDP_ENDPOINT || 'http://127.0.0.1:9222';
const DEFAULT_TIMEOUT = 30000;
const DEFAULT_MAX_CHARS = 20000;

const USAGE = `browser-cli -- drive the shared Chromium over CDP

usage: browser-cli <command> [args] [--flags]

navigation
  goto <url> [--capture] [--timeout ms]        navigate; --capture prints load errors
  wait --text "..." | --selector "..."         block until the condition matches
       | --url-prefix "..." | --url-regex "..." [--timeout ms]
  scroll [--by N] | scroll --to top|bottom|<selector>
  status                                       CDP + current page info

inspection
  snapshot [--selector S] [--max-chars N]      accessibility tree (default: body)
  text [--selector S] [--max-chars N]          visible text
  eval <js-expression>                         evaluate JS in the page, print JSON
  cookies [--name N] [--json] [--full]         context cookies

interaction
  click <selector> [--timeout ms]
  dblclick <selector> | hover <selector> | check <selector> | uncheck <selector>
  fill <selector> <value> | select <selector> <value> | press <key>

tabs
  tabs list | tabs new [url] | tabs select <n> | tabs close <n>

capture
  shot <path> [--selector S] [--full] [--jpeg [--quality N]]

selectors: CSS, text=..., role=button[name="Login"]; other Playwright engines pass through
env: BROWSER_CDP_ENDPOINT (default ${'http://127.0.0.1:9222'})`;

function fail(message) {
  console.error(`browser-cli: ${message}`);
  process.exit(1);
}

function num(value, fallback) {
  return value === undefined ? fallback : Number(value);
}

function truncate(text, max) {
  if (text.length <= max) return text;
  return text.slice(0, max) + `\n[truncated ${text.length - max} chars]`;
}

function parseOptions(args) {
  const positionals = [];
  const options = {};
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (!arg.startsWith('--')) {
      positionals.push(arg);
      continue;
    }
    const eq = arg.indexOf('=');
    if (eq !== -1) {
      options[arg.slice(2, eq)] = arg.slice(eq + 1);
      continue;
    }
    const key = arg.slice(2);
    const next = args[i + 1];
    if (next !== undefined && !next.startsWith('--')) {
      options[key] = next;
      i++;
    } else {
      options[key] = true;
    }
  }
  return { positionals, options };
}

async function connect() {
  try {
    return await chromium.connectOverCDP(ENDPOINT, { timeout: 10000 });
  } catch (err) {
    fail(`cannot connect to ${ENDPOINT} (${String(err.message).split('\n')[0]})\n  is the browser running? try: browser.sh start`);
  }
}

function loadState() {
  try {
    return JSON.parse(readFileSync(STATE_FILE, 'utf8'));
  } catch {
    return {};
  }
}

function saveState(state) {
  writeFileSync(STATE_FILE, JSON.stringify(state, null, 2) + '\n');
}

async function pageTargetId(page) {
  const session = await page.context().newCDPSession(page);
  try {
    const { targetInfo } = await session.send('Target.getTargetInfo');
    return targetInfo.targetId;
  } finally {
    await session.detach().catch(() => {});
  }
}

function contextOf(browser) {
  return browser.contexts()[0] || browser.newContext();
}

async function selectedPage(browser) {
  const context = await contextOf(browser);
  const pages = context.pages();
  if (pages.length === 0) return context.newPage();
  const { selected } = loadState();
  if (selected) {
    for (const page of pages) {
      if (await pageTargetId(page) === selected) return page;
    }
  }
  return pages[pages.length - 1];
}

function locator(page, selector) {
  const roleMatch = selector.match(/^role=([a-zA-Z]+)(?:\[name=(?:"([^"]*)"|'([^']*)'|([^\]]+))\])?$/);
  if (roleMatch) {
    const [, role, dq, sq, bare] = roleMatch;
    return page.getByRole(role, { name: dq ?? sq ?? bare });
  }
  return page.locator(selector);
}

function printResult(result) {
  if (result === undefined) {
    console.log('undefined');
  } else if (typeof result === 'string') {
    console.log(result);
  } else {
    console.log(JSON.stringify(result, null, 2));
  }
}

async function status() {
  const browser = await connect();
  const page = await selectedPage(browser);
  console.log(`cdp:     ${ENDPOINT} (${browser.version()})`);
  console.log(`pages:   ${contextPageCount(browser)}`);
  console.log(`current: ${page.url()}`);
  console.log(`title:   ${await page.title()}`);
}

function contextPageCount(browser) {
  return browser.contexts().reduce((sum, context) => sum + context.pages().length, 0);
}

async function goto(positionals, options) {
  const url = positionals[0];
  if (!url) fail('usage: browser-cli goto <url> [--capture] [--timeout ms]');

  const browser = await connect();
  const page = await selectedPage(browser);
  const logs = [];
  const onConsole = (msg) => {
    if (msg.type() === 'error' || msg.type() === 'warning') logs.push(`[${msg.type()}] ${msg.text()}`);
  };
  const onPageError = (err) => logs.push(`[pageerror] ${err.message}`);
  if (options.capture) {
    page.on('console', onConsole);
    page.on('pageerror', onPageError);
  }

  const response = await page.goto(url, { waitUntil: 'load', timeout: num(options.timeout, DEFAULT_TIMEOUT) });
  console.log(`url:   ${page.url()}`);
  console.log(`title: ${await page.title()}`);
  if (response) console.log(`http:  ${response.status()}`);
  if (options.capture) {
    console.log(logs.length ? `console:\n${logs.slice(0, 20).map((line) => '  ' + line).join('\n')}` : 'console: (no errors or warnings)');
  }
}

async function wait(positionals, options) {
  const browser = await connect();
  const page = await selectedPage(browser);
  const timeout = num(options.timeout, DEFAULT_TIMEOUT);

  if (options.text) {
    await page.getByText(options.text, { exact: false }).first().waitFor({ state: 'visible', timeout });
    console.log(`matched text: ${options.text}`);
  } else if (options.selector) {
    await locator(page, options.selector).waitFor({ state: 'visible', timeout });
    console.log(`matched selector: ${options.selector}`);
  } else if (options['url-prefix']) {
    await page.waitForURL((url) => url.href.startsWith(options['url-prefix']), { timeout });
    console.log(`url: ${page.url()}`);
  } else if (options['url-regex']) {
    const pattern = new RegExp(options['url-regex']);
    await page.waitForURL((url) => pattern.test(url.href), { timeout });
    console.log(`url: ${page.url()}`);
  } else {
    fail('usage: browser-cli wait --text "..." | --selector "..." | --url-prefix "..." | --url-regex "..." [--timeout ms]');
  }
}

async function scroll(positionals, options) {
  const browser = await connect();
  const page = await selectedPage(browser);

  if (options.to !== undefined) {
    const target = String(options.to);
    if (target === 'top') {
      await page.evaluate(() => window.scrollTo(0, 0));
    } else if (target === 'bottom') {
      await page.evaluate(() => window.scrollTo(0, document.documentElement.scrollHeight));
    } else {
      await locator(page, target).scrollIntoViewIfNeeded({ timeout: num(options.timeout, DEFAULT_TIMEOUT) });
    }
  } else if (options.by !== undefined) {
    const delta = Number(options.by);
    if (!Number.isFinite(delta)) fail(`--by expects a number, got: ${options.by}`);
    await page.evaluate((dy) => window.scrollBy(0, dy), delta);
  }

  const { y, max } = await page.evaluate(() => ({
    y: Math.round(window.scrollY),
    max: Math.round(document.documentElement.scrollHeight - window.innerHeight),
  }));
  console.log(`scrollY: ${y} / ${max}`);
}

async function snapshot(positionals, options) {
  const browser = await connect();
  const page = await selectedPage(browser);
  const tree = await locator(page, options.selector || 'body').ariaSnapshot();
  console.log(truncate(tree, num(options['max-chars'], DEFAULT_MAX_CHARS)));
}

async function text(positionals, options) {
  const browser = await connect();
  const page = await selectedPage(browser);
  const content = await page.locator(options.selector || 'body').innerText({ timeout: num(options.timeout, DEFAULT_TIMEOUT) });
  console.log(truncate(content, num(options['max-chars'], DEFAULT_MAX_CHARS)));
}

async function evalCommand(positionals) {
  const expression = positionals.join(' ');
  if (!expression) fail('usage: browser-cli eval <js-expression>');
  const browser = await connect();
  const page = await selectedPage(browser);
  printResult(await page.evaluate(expression));
}

async function cookies(positionals, options) {
  const browser = await connect();
  const context = await contextOf(browser);
  let list = await context.cookies();
  if (options.name) list = list.filter((cookie) => cookie.name === options.name);
  if (options.json) {
    console.log(JSON.stringify(list, null, 2));
    return;
  }
  if (list.length === 0) {
    console.log('(no cookies)');
    return;
  }
  for (const cookie of list) {
    const value = options.full ? cookie.value : truncate(cookie.value, 60).split('\n')[0];
    const expires = cookie.expires === -1 ? 'session' : new Date(cookie.expires * 1000).toISOString();
    console.log(`${cookie.name}=${value}  (domain=${cookie.domain}, expires=${expires})`);
  }
}

async function shot(positionals, options) {
  const target = positionals[0];
  if (!target) fail('usage: browser-cli shot <path> [--selector S] [--full] [--jpeg [--quality N]]');
  const path = isAbsolute(target) ? target : resolve(process.cwd(), target);
  mkdirSync(dirname(path), { recursive: true });

  const browser = await connect();
  const page = await selectedPage(browser);
  const type = options.jpeg ? 'jpeg' : 'png';
  const quality = options.jpeg ? num(options.quality, 70) : undefined;

  if (options.selector) {
    await locator(page, options.selector).screenshot({ path, type, quality });
  } else {
    await page.screenshot({ path, type, fullPage: !!options.full, quality });
  }
  console.log(path);
}

async function tabs(positionals) {
  const sub = positionals[0] || 'list';
  const browser = await connect();
  const context = await contextOf(browser);
  const pages = context.pages();
  const state = loadState();

  if (sub === 'list') {
    for (let i = 0; i < pages.length; i++) {
      const id = await pageTargetId(pages[i]);
      const marker = id === state.selected ? ' *' : '';
      console.log(`[${i}]${marker} ${pages[i].url()} — ${await pages[i].title()}`);
    }
    return;
  }

  if (sub === 'new') {
    const page = await context.newPage();
    if (positionals[1]) await page.goto(positionals[1], { waitUntil: 'load', timeout: DEFAULT_TIMEOUT });
    saveState({ ...state, selected: await pageTargetId(page) });
    console.log(`new tab: ${page.url()}`);
    return;
  }

  const index = Number(positionals[1]);
  if (!Number.isInteger(index) || !pages[index]) fail(`no tab at index ${positionals[1]} (see: browser-cli tabs list)`);

  if (sub === 'select') {
    saveState({ ...state, selected: await pageTargetId(pages[index]) });
    console.log(`selected [${index}] ${pages[index].url()}`);
    return;
  }

  if (sub === 'close') {
    const id = await pageTargetId(pages[index]);
    await pages[index].close();
    if (state.selected === id) saveState({});
    console.log('closed');
    return;
  }

  fail(`unknown tabs subcommand: ${sub} (list, new, select, close)`);
}

async function action(name, positionals, options) {
  const browser = await connect();
  const page = await selectedPage(browser);
  const timeout = num(options.timeout, DEFAULT_TIMEOUT);
  const [selector, value] = positionals;

  if (name === 'press') {
    if (!selector) fail('usage: browser-cli press <key>');
    await page.keyboard.press(selector);
    console.log(`pressed ${selector}`);
    return;
  }

  if (!selector) fail(`usage: browser-cli ${name} <selector>${name === 'fill' || name === 'select' ? ' <value>' : ''}`);
  const element = locator(page, selector);

  switch (name) {
    case 'click':
      await element.click({ timeout });
      break;
    case 'dblclick':
      await element.dblclick({ timeout });
      break;
    case 'hover':
      await element.hover({ timeout });
      break;
    case 'check':
      await element.check({ timeout });
      break;
    case 'uncheck':
      await element.uncheck({ timeout });
      break;
    case 'fill':
      if (value === undefined) fail('usage: browser-cli fill <selector> <value>');
      await element.fill(value, { timeout });
      break;
    case 'select':
      if (value === undefined) fail('usage: browser-cli select <selector> <value>');
      await element.selectOption(value, { timeout });
      break;
    default:
      fail(`unknown action: ${name}`);
  }
  console.log(`${name}: ${selector}`);
}

async function main() {
  const [command, ...rest] = process.argv.slice(2);
  if (!command || command === 'help' || command === '--help' || command === '-h') {
    console.log(USAGE);
    return;
  }

  const { positionals, options } = parseOptions(rest);
  const handlers = {
    status,
    goto,
    wait,
    scroll,
    snapshot,
    text,
    eval: evalCommand,
    cookies,
    shot,
    tabs,
    click: (p, o) => action('click', p, o),
    dblclick: (p, o) => action('dblclick', p, o),
    hover: (p, o) => action('hover', p, o),
    check: (p, o) => action('check', p, o),
    uncheck: (p, o) => action('uncheck', p, o),
    fill: (p, o) => action('fill', p, o),
    select: (p, o) => action('select', p, o),
    press: (p, o) => action('press', p, o),
  };

  const handler = handlers[command];
  if (!handler) fail(`unknown command: ${command}\n\n${USAGE}`);
  await handler(positionals, options);
}

main().then(
  () => process.exit(0),
  (err) => fail(String(err.message).split('\n').slice(0, 3).join('\n')),
);
