#!/usr/bin/env node
/*
 * Cross-checks the management API against the web UI, in both directions.
 *
 * api-sweep.ps1 proves that every documented operation answers with a
 * documented status and a well formed envelope. That is necessary but it is
 * not sufficient: an endpoint can return 200 and a plausible body while
 * reading or writing somewhere other than the place the web UI uses. This
 * script closes that gap by driving both surfaces against the same data and
 * comparing what each one says.
 *
 *   API -> UI   create something through the API, then find it in the web UI
 *   UI -> API   create something through a real web UI form, then find it
 *               through the API
 *   deletion    remove something through one surface and confirm the other
 *               stops reporting it
 *
 * The credential checks are the sharpest ones. The UI prints the credential
 * key in clear text, the API member endpoint returns it, and the API
 * collection endpoint deliberately omits it. All three have to agree, which
 * pins down both the value and the redaction.
 *
 * This is CommonJS on purpose. The wrapper, crosscheck.ps1, makes the globally
 * installed Playwright resolvable through NODE_PATH, and NODE_PATH is only
 * consulted by require(). An ES module would not find the package.
 *
 * Usage:  node script/production/crosscheck.cjs
 *         POSTAL_HEADED=1 to watch the browser instead of running headless.
 */

const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

const credentialsPath = process.env.POSTAL_CREDENTIALS ||
  path.join('tmp', 'production', 'credentials.json');
const screenshotDir = process.env.POSTAL_SCREENSHOTS ||
  path.join('tmp', 'production', 'crosscheck');
const headed = process.env.POSTAL_HEADED === '1';

let credentials;
try {
  credentials = JSON.parse(fs.readFileSync(credentialsPath, 'utf8'));
} catch (error) {
  console.error(`Cannot read ${credentialsPath}: ${error.message}`);
  console.error('Run ./script/production/bootstrap.ps1 first.');
  process.exit(1);
}

if (!credentials.token) {
  console.error(`${credentialsPath} holds no token.`);
  console.error('The plain key is only available on the run which created it;');
  console.error('re-run bootstrap.ps1 with -NewToken.');
  process.exit(1);
}

const baseUrl = String(process.env.POSTAL_BASE_URL || credentials.base_url).replace(/\/+$/, '');
const bootstrapOrg = credentials.organization_permalink;
const bootstrapServer = credentials.server_permalink;
const messageId = credentials.message_id;

// Everything this script creates lives inside one organization which is named
// after the run, so that an interrupted run can be recognised and removed by
// cleanup.ps1 rather than being mistaken for data someone wanted.
const tag = `${process.pid}-${Math.random().toString(16).slice(2, 10)}`;
const sandbox = {
  orgName: 'Crosscheck Sandbox',
  orgPermalink: `xcheck-${tag}`,
  apiServerName: 'Crosscheck Server',
  apiServerPermalink: 'crosscheck-server',
  uiServerName: 'UI Built Server',
  uiServerPermalink: 'ui-built-server',
  apiDomain: `xcheck-${tag}.example.com`,
  uiDomain: `ui-xcheck-${tag}.example.com`,
  orgDomain: `org-xcheck-${tag}.example.com`,
  apiCredentialName: 'Crosscheck Credential',
  uiCredentialName: 'UI Credential',
  apiEndpointName: 'Crosscheck Endpoint',
  uiEndpointName: 'UI Endpoint',
  uiEndpointUrl: `https://ui-endpoint-${tag}.example.com/hook`,
  apiEndpointUrl: `https://api-endpoint-${tag}.example.com/hook`,
};

// ---------------------------------------------------------------------------
// reporting

let passed = 0;
let failed = 0;
const notes = [];
let page = null;

function stage(name) {
  console.log(`\n== ${name} ==`);
}

function check(name, ok, detail) {
  if (ok) {
    passed += 1;
    console.log(`  PASS ${name}`);
  } else {
    failed += 1;
    console.log(`  FAIL ${name}`);
    if (detail) console.log(`       ${detail}`);
    captureScreenshot(name);
  }
  return !!ok;
}

// Something which is neither a pass nor a failure: behaviour which is worth
// putting in front of a human but which this script is not in a position to
// call wrong. Notes never affect the exit code.
function note(text) {
  notes.push(text);
  console.log(`  NOTE ${text}`);
}

// check() is synchronous, because making it async would put an `await` in front
// of forty call sites for the sake of one diagnostic. Taking a screenshot is
// not, so the request is queued instead and drained before the browser closes.
// The queue runs at the next await point in the caller, which is before the
// page has navigated anywhere else.
let screenshotQueue = Promise.resolve();

// The directory is cleared at the start of a run rather than appended to. A
// screenshot is evidence of a specific failure in a specific run, and a passing
// run which left the previous run's pictures in place would be worse than one
// which left none: the natural reading of a full screenshot directory is that
// the checks named in it are currently failing.
function clearScreenshots() {
  try {
    if (!fs.existsSync(screenshotDir)) return;
    for (const entry of fs.readdirSync(screenshotDir)) {
      if (path.extname(entry).toLowerCase() === '.png') {
        fs.rmSync(path.join(screenshotDir, entry));
      }
    }
  } catch (error) {
    console.log(`could not clear ${screenshotDir}: ${error.message}`);
  }
}

function captureScreenshot(name) {
  if (!page) return;
  screenshotQueue = screenshotQueue.then(async () => {
    try {
      fs.mkdirSync(screenshotDir, { recursive: true });
      const slug = name.replace(/[^a-z0-9]+/gi, '-').replace(/^-|-$/g, '').slice(0, 60);
      const file = path.join(screenshotDir, `${slug}.png`);
      await page.screenshot({ path: file, fullPage: true });
      console.log(`       screenshot ${file}`);
    } catch (error) {
      console.log(`       screenshot failed: ${error.message}`);
    }
  });
}

function show(value) {
  return typeof value === 'string' ? JSON.stringify(value) : JSON.stringify(value);
}

// ---------------------------------------------------------------------------
// the API

async function api(method, apiPath, body) {
  const headers = { 'X-Postal-API-Key': credentials.token };
  const init = { method, headers };
  if (body !== undefined) {
    headers['Content-Type'] = 'application/json';
    init.body = JSON.stringify(body);
  }
  const response = await fetch(`${baseUrl}${apiPath}`, init);
  const text = await response.text();
  let json = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    // A 204 has no body and the raw message endpoints have a non JSON one.
  }
  return { status: response.status, json, text };
}

function data(response) {
  return response.json && response.json.data;
}

// One item from a collection response, or null.
function find(response, predicate) {
  const rows = data(response);
  return Array.isArray(rows) ? (rows.find(predicate) || null) : null;
}

// ---------------------------------------------------------------------------
// the web UI

async function goto(page_, uiPath) {
  await page_.goto(`${baseUrl}${uiPath}`, { waitUntil: 'domcontentloaded' });
  return new URL(page_.url()).pathname;
}

// Every Postal resource form is submitted over AJAX and answered with
// {redirect_to: ...}, which ajax.coffee hands to Turbolinks.visit. The URL
// therefore changes without a navigation event, so the usual
// waitForURL/waitForLoadState pair does not describe what happens. This polls
// the location instead, and also watches for the form error list so that a
// rejected submission reports the reason rather than timing out silently.
async function submitRemote(page_, submitValue, expected, timeoutMs = 25000) {
  // The path the form is on has to be excluded from the expectation. A create
  // form lives at .../domains/new and redirects to .../domains/<uuid>/setup, so
  // a pattern as loose as "somewhere under domains" already matches before the
  // request has been sent. Returning at that point is worse than a slow test:
  // the next step navigates away, which aborts the in-flight submission, and
  // the failure surfaces several checks later as a record which does not exist.
  const startPath = new URL(page_.url()).pathname;
  await page_.locator(`input[type=submit][value="${submitValue}"]`).first().click();
  const matches = (current) => current !== startPath && (expected instanceof RegExp
    ? expected.test(current || '')
    : current === expected);
  const deadline = Date.now() + timeoutMs;
  let last = { path: null, errors: [], flash: [] };
  while (Date.now() < deadline) {
    last = await page_.evaluate(() => ({
      path: location.pathname,
      errors: Array.from(document.querySelectorAll('.formErrors li'))
        .map((element) => element.textContent.replace(/\s+/g, ' ').trim()),
      flash: Array.from(document.querySelectorAll('.flashMessage'))
        .map((element) => element.textContent.replace(/\s+/g, ' ').trim()),
    }));
    if (matches(last.path)) return last;
    if (last.errors.length > 0) return last;
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
  last.timedOut = true;
  return last;
}

function describeRemoteResult(result) {
  if (result.errors && result.errors.length) return `the form was rejected: ${result.errors.join('; ')}`;
  if (result.timedOut) return `never reached the expected page, last path was ${show(result.path)}`;
  return `landed on ${show(result.path)}`;
}

// The text of every element matching a selector, whitespace collapsed.
async function texts(page_, selector) {
  return page_.locator(selector).evaluateAll((elements) => elements
    .map((element) => element.textContent.replace(/\s+/g, ' ').trim()));
}

// Every list in the web UI is a <ul> of items whose interesting parts carry
// their own class. This pulls a whole row apart at once so that a check can
// compare several of its parts without querying the page again. A part is
// either a selector, whose text is taken, or { selector, attribute }.
async function rows(page_, itemSelector, parts) {
  return page_.locator(itemSelector).evaluateAll((elements, selectors) => elements
    .map((element) => {
      const row = { text: element.textContent.replace(/\s+/g, ' ').trim() };
      for (const key of Object.keys(selectors)) {
        const spec = selectors[key];
        const found = element.querySelector(spec.selector || spec);
        if (!found) {
          row[key] = null;
        } else if (spec.attribute) {
          row[key] = found.getAttribute(spec.attribute);
        } else {
          row[key] = found.textContent.replace(/\s+/g, ' ').trim();
        }
      }
      return row;
    }), parts);
}

async function text(page_, selector) {
  const all = await texts(page_, selector);
  return all.length === 1 ? all[0] : all;
}

// texts() collapses whitespace, which is right for a label in a list and wrong
// for the body of an e-mail. This returns textContent untouched, so that a
// comparison against a value the API returned verbatim means something.
async function rawText(page_, selector) {
  const all = await page_.locator(selector).evaluateAll((elements) => elements
    .map((element) => element.textContent));
  return all.length === 1 ? all[0] : all;
}

// Both surfaces humanize the stored value: the web UI renders
// @message.spam_status.underscore.humanize and the API returns "NotChecked".
// Comparing letters and digits only makes that difference visible without
// reimplementing ActiveSupport's humanize in JavaScript.
function sameLabel(shown, expected) {
  const letters = (value) => String(value === null || value === undefined ? '' : value)
    .toLowerCase().replace(/[^a-z0-9]/g, '');
  return letters(expected) !== '' && letters(shown) === letters(expected);
}

// Pairs are joined with a NUL so that neither part can be confused with the
// other, which a separator such as ": " would allow in a header value.
function unpack(entry) {
  return entry.replace('\u0000', ' = ');
}

// ---------------------------------------------------------------------------

const serverErrors = [];
const pageErrors = [];

async function main() {
  console.log(`API/UI cross-check against ${baseUrl}`);
  console.log(`browser: chromium, ${headed ? 'headed' : 'headless'}`);
  console.log(`sandbox: ${sandbox.orgPermalink}`);
  clearScreenshots();

  const browser = await chromium.launch({ headless: !headed });
  const context = await browser.newContext({ ignoreHTTPSErrors: true });
  page = await context.newPage();

  // A 500 in the middle of a Turbolinks visit does not fail anything on its
  // own, so it would otherwise pass unnoticed. Collecting them here means the
  // run ends with a list of every server error the browser saw.
  page.on('response', (response) => {
    if (response.status() >= 500) {
      serverErrors.push(`${response.status()} ${response.request().method()} ${new URL(response.url()).pathname}`);
    }
  });
  page.on('pageerror', (error) => pageErrors.push(error.message.split('\n')[0]));
  // rails-ujs implements data-confirm with window.confirm.
  page.on('dialog', (dialog) => dialog.accept());

  try {
    await runLogin();
    await runApiToUi();
    await runUiToApi();
    await runDeletion();
  } finally {
    await teardown();
    await screenshotQueue;
    await browser.close();
  }

  if (serverErrors.length > 0) {
    note(`the browser saw ${serverErrors.length} server error(s): ${serverErrors.slice(0, 5).join(', ')}`);
  }
  if (pageErrors.length > 0) {
    note(`the browser saw ${pageErrors.length} JavaScript error(s): ${pageErrors.slice(0, 5).join(', ')}`);
  }

  console.log(`\n${passed} passed, ${failed} failed`);
  if (notes.length > 0) console.log(`${notes.length} note(s)`);
  process.exit(failed === 0 ? 0 : 1);
}

// ---------------------------------------------------------------------------

async function runLogin() {
  stage('logging in');

  const before = await goto(page, '/login');
  const formCount = await page.locator('form.loginForm').count();
  check('the login page is a form and not a redirect', before === '/login' && formCount === 1,
    `path was ${show(before)}, ${formCount} login form(s)`);

  // The credentials in tmp/production/credentials.json come from the same .env
  // the stack was bootstrapped with, so this is also a check that bootstrap.ps1
  // records the administrator password it actually set.
  await page.fill('input[name="email_address"]', credentials.admin_email);
  await page.fill('input[name="password"]', credentials.admin_password);
  await Promise.all([
    page.waitForNavigation({ waitUntil: 'domcontentloaded' }),
    page.click('input[type=submit]'),
  ]);

  const title = await text(page, 'h1.pageHeader__title');
  check('the administrator password from the credentials file logs in',
    new URL(page.url()).pathname === '/' && /^Welcome to Postal, \S/.test(String(title)),
    `path was ${show(new URL(page.url()).pathname)}, title was ${show(title)}`);

  const me = await api('GET', '/api/v2/me');
  // GET /me nests: {data: {user, token, organizations}}.
  const meUser = data(me) ? data(me).user : null;
  check('the signed in user and the API token belong to the same person',
    me.status === 200 && !!meUser && meUser.email_address === credentials.admin_email,
    `GET /me returned ${me.status} for ${show(meUser && meUser.email_address)}`);
}

async function runApiToUi() {
  stage('api -> ui: organization and server');

  const created = await api('POST', '/api/v2/organizations', {
    name: sandbox.orgName,
    permalink: sandbox.orgPermalink,
    time_zone: 'UTC',
  });
  check(`POST /organizations created ${sandbox.orgPermalink}`, created.status === 201,
    `${created.status} ${created.text.slice(0, 200)}`);

  await goto(page, '/');
  const orgRows = await rows(page, 'ul.largeList li.largeList__item',
    { href: { selector: 'a.largeList__link', attribute: 'href' } });
  const orgRow = orgRows.find((row) => row.text === sandbox.orgName);
  check('the web UI lists the organization the API created', !!orgRow,
    `the organizations page listed ${show(orgRows.map((row) => row.text))}`);
  check('and links to it by the permalink the API returned',
    !!orgRow && orgRow.href === `/org/${sandbox.orgPermalink}`,
    orgRow ? `href was ${show(orgRow.href)}` : 'the row was not there');

  // Two independent readings of the same question: which organizations can this
  // user see. The web UI answers it with OrganizationsController#index and the
  // API with User#organizations_scope, so a scope which drifts in one of them
  // shows up here.
  const meAfter = await api('GET', '/api/v2/me');
  const apiOrgs = ((data(meAfter) || {}).organizations || []).map((row) => row.permalink).sort();
  const uiOrgs = orgRows.map((row) => (row.href || '').replace(/^\/org\//, '')).filter(Boolean).sort();
  check('GET /me lists exactly the organizations the web UI lists',
    JSON.stringify(apiOrgs) === JSON.stringify(uiOrgs),
    `the API said ${show(apiOrgs)}, the web UI said ${show(uiOrgs)}`);

  const server = await api('POST', `/api/v2/organizations/${sandbox.orgPermalink}/servers`, {
    name: sandbox.apiServerName,
    mode: 'Live',
  });
  check(`POST /servers created ${sandbox.apiServerName}`, server.status === 201,
    `${server.status} ${server.text.slice(0, 200)}`);
  const apiServerPermalink = data(server) ? data(server).permalink : sandbox.apiServerPermalink;

  await goto(page, `/org/${sandbox.orgPermalink}`);
  const serverRows = await rows(page, 'ul.largeList li.largeList__item', {
    href: { selector: 'a.largeList__link', attribute: 'href' },
    status: '.largeList__rightLabel',
  });
  // Identified by the link rather than by the row's text, because the status
  // label is rendered before the name and the row's textContent therefore does
  // not start with it.
  const serverHref = `/org/${sandbox.orgPermalink}/servers/${apiServerPermalink}`;
  const serverRow = serverRows.find((row) => row.href === serverHref);
  check('the web UI lists the server the API created, at the permalink the API returned',
    !!serverRow,
    `the server page linked to ${show(serverRows.map((row) => row.href))}`);
  check('and names it as the API named it',
    !!serverRow && serverRow.text.includes(sandbox.apiServerName),
    serverRow ? `the row read ${show(serverRow.text)}` : 'the row was not there');
  check('and shows it with the Live status the API set',
    !!serverRow && /live/i.test(serverRow.status || ''),
    serverRow ? `the status label read ${show(serverRow.status)}` : 'the row was not there');

  stage('api -> ui: domain');

  const domain = await api('POST',
    `/api/v2/organizations/${sandbox.orgPermalink}/servers/${apiServerPermalink}/domains`,
    { name: sandbox.apiDomain });
  check(`POST /domains created ${sandbox.apiDomain}`, domain.status === 201,
    `${domain.status} ${domain.text.slice(0, 200)}`);
  const apiDomainVerified = !!(data(domain) && data(domain).verified_at);
  check('the API reports it verified, because an administrator created it', apiDomainVerified,
    `verified_at was ${show(data(domain) && data(domain).verified_at)}`);

  await goto(page, `/org/${sandbox.orgPermalink}/servers/${apiServerPermalink}/domains`);
  const domainNames = await texts(page, 'ul.domainList li.domainList__item .domainList__name');
  check('the web UI lists the domain the API created',
    domainNames.some((name) => name.includes(sandbox.apiDomain)),
    `the domains page listed ${show(domainNames)}`);
  const uiDomainVerified = (await texts(page, 'li.domainList__item .domainList__verificationTime')).length > 0;
  check('and shows it verified, matching the API', uiDomainVerified === apiDomainVerified,
    `the UI showed ${uiDomainVerified ? 'a verification time' : 'no verification time'}, the API said ${apiDomainVerified}`);

  stage('api -> ui: credential key');

  // The key sent here is not the key which comes back. Credential#generate_key
  // runs before_validation and overwrites it for every type except SMTP-IP,
  // which is what CredentialInput in the OpenAPI document says. Sending one
  // anyway is the point: it proves the document and the UI agree that the key
  // is the server's choice rather than the caller's.
  const credential = await api('POST',
    `/api/v2/organizations/${sandbox.orgPermalink}/servers/${apiServerPermalink}/credentials`,
    { type: 'SMTP', name: sandbox.apiCredentialName, key: 'deliberately-ignored' });
  check(`POST /credentials created ${sandbox.apiCredentialName}`, credential.status === 201,
    `${credential.status} ${credential.text.slice(0, 200)}`);
  const credentialUuid = data(credential) ? data(credential).uuid : null;
  const createdKey = data(credential) ? data(credential).key : null;
  check('the key the API supplied was generated, not the one which was sent',
    !!createdKey && createdKey !== 'deliberately-ignored',
    `the key was ${show(createdKey)}`);

  const listing = await api('GET',
    `/api/v2/organizations/${sandbox.orgPermalink}/servers/${apiServerPermalink}/credentials`);
  const listed = find(listing, (row) => row.uuid === credentialUuid);
  check('the API collection omits the key', !!listed && listed.key === undefined,
    listed ? `the collection row carried key ${show(listed.key)}` : 'the credential was not listed');

  const member = await api('GET',
    `/api/v2/organizations/${sandbox.orgPermalink}/servers/${apiServerPermalink}/credentials/${credentialUuid}`);
  const memberKey = data(member) ? data(member).key : null;
  check('but the API member endpoint returns it', memberKey === createdKey,
    `the member endpoint returned ${show(memberKey)}, creation returned ${show(createdKey)}`);

  await goto(page, `/org/${sandbox.orgPermalink}/servers/${apiServerPermalink}/credentials`);
  const uiKey = await text(page, 'ul.credentialList li.credentialList__item:has(.credentialList__name:text-is("' +
    sandbox.apiCredentialName + '")) .credentialList__key');
  check('and the web UI shows the same key', uiKey === createdKey,
    `the UI showed ${show(uiKey)}, the API said ${show(createdKey)}`);

  stage('api -> ui: http endpoint');

  const endpoint = await api('POST',
    `/api/v2/organizations/${sandbox.orgPermalink}/servers/${apiServerPermalink}/http_endpoints`,
    {
      name: sandbox.apiEndpointName,
      url: sandbox.apiEndpointUrl,
      encoding: 'BodyAsJSON',
      format: 'RawMessage',
    });
  check(`POST /http_endpoints created ${sandbox.apiEndpointName}`, endpoint.status === 201,
    `${endpoint.status} ${endpoint.text.slice(0, 200)}`);

  await goto(page, `/org/${sandbox.orgPermalink}/servers/${apiServerPermalink}/http_endpoints`);
  const endpointRows = await rows(page, 'ul.endpointList li.endpointList__item',
    { name: '.endpointList__name', url: '.endpointList__url' });
  const endpointRow = endpointRows.find((row) => row.name === sandbox.apiEndpointName);
  check('the web UI lists the endpoint the API created', !!endpointRow,
    `the endpoints page listed ${show(endpointRows.map((row) => row.name))}`);
  check('and shows the URL the API stored',
    !!endpointRow && endpointRow.url === sandbox.apiEndpointUrl,
    endpointRow ? `the UI showed ${show(endpointRow.url)}` : 'the row was not there');

  stage('api -> ui: message');

  const message = await api('GET',
    `/api/v2/organizations/${bootstrapOrg}/servers/${bootstrapServer}/messages/${messageId}`);
  const apiMessage = data(message);
  check(`GET /messages/${messageId} returned the bootstrap message`,
    message.status === 200 && !!apiMessage,
    `${message.status} ${message.text.slice(0, 200)}`);

  if (apiMessage) {
    await goto(page, `/org/${bootstrapOrg}/servers/${bootstrapServer}/messages/outgoing`);
    const messageRows = await page.locator('ul.messageList li.messageList__message')
      .evaluateAll((elements) => elements.map((element) => ({
        subject: ((element.querySelector('.messageList__subject') || {}).textContent || '').replace(/\s+/g, ' ').trim(),
        status: ((element.querySelector('[class*="label--messageStatus-"]') || {}).textContent || '').replace(/\s+/g, ' ').trim(),
        addresses: Array.from(element.querySelectorAll('.messageList__addresses dd'))
          .map((item) => item.textContent.replace(/\s+/g, ' ').trim()),
      })));
    const row = messageRows.find((candidate) => candidate.subject === apiMessage.subject);
    check('the web UI lists the message the API returned', !!row,
      `the outgoing page listed ${show(messageRows.map((candidate) => candidate.subject))}`);
    // The list renders To before From, which is the order the template uses
    // rather than anything the API promises, so the comparison is by membership.
    check('and shows the same recipients and sender',
      !!row && row.addresses.includes(apiMessage.rcpt_to) && row.addresses.includes(apiMessage.mail_from),
      row ? `the UI showed ${show(row.addresses)}, the API said ${show([apiMessage.rcpt_to, apiMessage.mail_from])}` : 'the row was not there');
    check('and shows the same status',
      !!row && row.status.toLowerCase() === String(apiMessage.status).toLowerCase(),
      row ? `the UI showed ${show(row.status)}, the API said ${show(apiMessage.status)}` : 'the row was not there');

    await runMessageDetail(apiMessage);
  }

  stage('api -> ui: organization scoped domain');

  // A domain can belong to an organization or to one of its servers, and the
  // two are different scopes with different routes on both surfaces:
  // DomainsController picks between organization.domains and @server.domains on
  // whether params[:server_id] arrived, and the API picks on
  // params[:server_permalink]. Creating one at organization level and looking
  // for it in both places is what proves the choice is actually being made,
  // rather than the two scopes happening to resolve to the same rows.
  const orgDomain = await api('POST', `/api/v2/organizations/${sandbox.orgPermalink}/domains`,
    { name: sandbox.orgDomain });
  check(`POST /organizations/:permalink/domains created ${sandbox.orgDomain}`,
    orgDomain.status === 201,
    `${orgDomain.status} ${orgDomain.text.slice(0, 200)}`);

  const orgDomainsPath = await goto(page, `/org/${sandbox.orgPermalink}/domains`);
  const orgDomainNames = await texts(page, 'ul.domainList li.domainList__item .domainList__name');
  check('and the web UI lists it on the organization domains page',
    orgDomainsPath === `/org/${sandbox.orgPermalink}/domains` &&
    orgDomainNames.some((name) => name.includes(sandbox.orgDomain)),
    `rendered at ${show(orgDomainsPath)} and listed ${show(orgDomainNames)}`);

  await goto(page, `/org/${sandbox.orgPermalink}/servers/${apiServerPermalink}/domains`);
  const serverDomainNames = await texts(page, 'ul.domainList li.domainList__item .domainList__name');
  check('but not on the server domains page, which is a different scope',
    !serverDomainNames.some((name) => name.includes(sandbox.orgDomain)),
    `the server page listed ${show(serverDomainNames)}`);

  const serverDomainList = await api('GET',
    `/api/v2/organizations/${sandbox.orgPermalink}/servers/${apiServerPermalink}/domains`);
  const orgDomainList = await api('GET', `/api/v2/organizations/${sandbox.orgPermalink}/domains`);
  check('and the API keeps the same separation',
    !find(serverDomainList, (row) => row.name === sandbox.orgDomain) &&
    !!find(orgDomainList, (row) => row.name === sandbox.orgDomain),
    `the server scope listed ${show((data(serverDomainList) || []).map((row) => row.name))} ` +
    `and the organization scope listed ${show((data(orgDomainList) || []).map((row) => row.name))}`);
}

// The API addresses a message by its integer id and returns its subject,
// status, headers, bodies and attachments. The web UI has a page for every one
// of those, reached from the same id.
//
// MessagesController defines no show, plain, headers or attachments method, and
// asking it whether it does gives the wrong answer: action_methods is built from
// the controller's own public instance methods and so reports none of them.
// Dispatch does not go through action_methods. It goes through
// method_for_action, which ActionController::ImplicitRender extends to return
// "default_render" whenever a template of that name exists -- and
// app/views/messages holds all four. The template is rendered with a 200 and the
// before_actions which set @server and @message still run, which is all the
// controller those views need. AbstractController::Base#available_action? is the
// predicate which reflects that; action_methods is not.
//
// So these pages are compared rather than merely noted. They are the only place
// where the two surfaces expose the same body text, and a serializer which
// mangled an encoding or dropped a header would show up here and nowhere else.
async function runMessageDetail(apiMessage) {
  stage('api -> ui: message detail');

  const prefix = `/api/v2/organizations/${bootstrapOrg}/servers/${bootstrapServer}/messages/${messageId}`;
  const detailPath = `/org/${bootstrapOrg}/servers/${bootstrapServer}/messages/${messageId}`;

  const detail = await page.goto(`${baseUrl}${detailPath}`, { waitUntil: 'domcontentloaded' });
  const detailWhere = new URL(page.url()).pathname;
  // The status alone proves nothing. An unauthenticated request to this URL also
  // answers 200, because it is redirected to the login page and that renders
  // successfully. The path is what tells the two apart.
  check('the web UI renders the message detail page for the id the API used',
    !!detail && detail.status() === 200 && detailWhere === detailPath,
    `${detail ? detail.status() : 'no response'} at ${show(detailWhere)}`);

  const subject = await text(page, '.messageHeader__subject');
  check('and shows the subject the API returned', subject === apiMessage.subject,
    `the UI showed ${show(subject)}, the API said ${show(apiMessage.subject)}`);

  const status = await text(page, '.messageHeader__status .label');
  check('and shows the status the API returned', sameLabel(status, apiMessage.status),
    `the UI showed ${show(status)}, the API said ${show(apiMessage.status)}`);

  // _message_header.html.haml renders From, To and Received as <dl> siblings, in
  // that order, with no class on any of them.
  const basic = await rows(page, '.messageHeader__basicProperties dl', { value: 'dd' });
  const basicValue = (label) => {
    const row = basic.find((candidate) => candidate.text.startsWith(label));
    return row ? row.value : null;
  };
  check('and shows the sender and recipient the API returned',
    basicValue('From') === apiMessage.mail_from && basicValue('To') === apiMessage.rcpt_to,
    `the UI showed ${show([basicValue('From'), basicValue('To')])}, ` +
    `the API said ${show([apiMessage.mail_from, apiMessage.rcpt_to])}`);

  const properties = await rows(page, '.messagePropertiesPage__property', { value: 'dd' });
  const property = (label) => {
    const row = properties.find((candidate) => candidate.text.startsWith(label));
    return row ? row.value : null;
  };
  check('and shows the message ID the API returned',
    property('Message ID') === (apiMessage.message_id || 'No message ID'),
    `the UI showed ${show(property('Message ID'))}, the API said ${show(apiMessage.message_id)}`);
  check('and shows the spam status the API returned',
    sameLabel(property('Spam Status'), apiMessage.spam_status),
    `the UI showed ${show(property('Spam Status'))}, the API said ${show(apiMessage.spam_status)}`);
  check('and shows whether the raw message is still stored',
    property('Raw Message') === (apiMessage.raw_message ? 'Available' : 'Removed'),
    `the UI showed ${show(property('Raw Message'))}, the API said raw_message=${show(apiMessage.raw_message)}`);

  // number_to_human_size rounds to three significant figures, so the reported
  // size is only exactly comparable while it is still counted in whole bytes.
  const sizeText = property('Message Size');
  if (/Bytes$/.test(String(sizeText))) {
    check('and shows the size the API returned',
      parseInt(sizeText, 10) === apiMessage.size,
      `the UI showed ${show(sizeText)}, the API said ${show(apiMessage.size)}`);
  }

  const plain = await api('GET', `${prefix}/plain`);
  await goto(page, `${detailPath}/plain`);
  const plainShown = await rawText(page, 'pre.codeBlock');
  const plainApi = data(plain) ? data(plain).body : null;
  check('the plain text page shows the body the API returns, byte for byte',
    plain.status === 200 && typeof plainShown === 'string' && plainShown === plainApi &&
    plainApi === apiMessage.plain_body,
    `the UI showed ${show(String(plainShown).slice(0, 80))}, the dedicated endpoint said ` +
    `${show(String(plainApi).slice(0, 80))} and the detail payload said ` +
    `${show(String(apiMessage.plain_body).slice(0, 80))}`);

  const headersResponse = await api('GET', `${prefix}/headers`);
  await goto(page, `${detailPath}/headers`);
  const headerRows = await page.locator('.headersList__item')
    .evaluateAll((elements) => elements.map((element) => ({
      key: (element.querySelector('dt') || {}).textContent || '',
      value: (element.querySelector('dd') || {}).textContent || '',
    })));
  // The API returns a hash of header name to a list of values and the web UI
  // flattens exactly that: one <dl> per (name, value) pair. Sorting both sides
  // makes the comparison about membership rather than about the order two
  // unrelated implementations happen to iterate a hash in.
  const apiHeaders = (data(headersResponse) || {}).headers || {};
  const expectedHeaders = Object.keys(apiHeaders).sort()
    .flatMap((key) => [].concat(apiHeaders[key]).map((value) => `${key}\u0000${value}`))
    .sort();
  const shownHeaders = headerRows.map((row) => `${row.key}\u0000${row.value}`).sort();
  check('the headers page lists every header the API returns, and no others',
    headersResponse.status === 200 &&
    JSON.stringify(expectedHeaders) === JSON.stringify(shownHeaders),
    `${expectedHeaders.length} from the API and ${shownHeaders.length} from the UI; ` +
    `the API said ${show(expectedHeaders.slice(0, 3).map(unpack))}, ` +
    `the UI said ${show(shownHeaders.slice(0, 3).map(unpack))}`);

  const attachmentsResponse = await api('GET', `${prefix}/attachments`);
  await goto(page, `${detailPath}/attachments`);
  const attachmentRows = await rows(page, 'ul.largeList li.largeList__item',
    { name: 'p:not([class])', type: '.largeList__subText' });
  const apiAttachments = (data(attachmentsResponse) || {}).attachments || apiMessage.attachments || [];
  const expectedAttachments = apiAttachments
    .map((attachment) => `${attachment.filename}\u0000${attachment.content_type}`).sort();
  const shownAttachments = attachmentRows.map((row) => `${row.name}\u0000${row.type}`).sort();
  check('and the attachments page lists every attachment the API returns',
    attachmentsResponse.status === 200 &&
    JSON.stringify(expectedAttachments) === JSON.stringify(shownAttachments),
    `the API said ${show(expectedAttachments.map(unpack))}, the UI said ${show(shownAttachments.map(unpack))}`);
}

async function runUiToApi() {
  stage('ui -> api: server');

  await goto(page, `/org/${sandbox.orgPermalink}/servers/new`);
  await page.fill('input[name="server[name]"]', sandbox.uiServerName);
  await page.selectOption('select[name="server[mode]"]', 'Live');
  let result = await submitRemote(page, 'Build server',
    `/org/${sandbox.orgPermalink}/servers/${sandbox.uiServerPermalink}`);
  check('the web UI created a server', result.path === `/org/${sandbox.orgPermalink}/servers/${sandbox.uiServerPermalink}`,
    describeRemoteResult(result));

  const servers = await api('GET', `/api/v2/organizations/${sandbox.orgPermalink}/servers`);
  const uiServer = find(servers, (row) => row.name === sandbox.uiServerName);
  check('and the API reports it', !!uiServer,
    `the API listed ${show((data(servers) || []).map((row) => row.name))}`);
  check('with the permalink the web UI derived from its name',
    !!uiServer && uiServer.permalink === sandbox.uiServerPermalink,
    uiServer ? `the API said ${show(uiServer.permalink)}` : 'the server was not there');
  check('and the mode which was chosen in the form',
    !!uiServer && uiServer.mode === 'Live',
    uiServer ? `the API said ${show(uiServer.mode)}` : 'the server was not there');

  stage('ui -> api: domain');

  await goto(page, `/org/${sandbox.orgPermalink}/servers/${sandbox.uiServerPermalink}/domains/new`);
  await page.fill('input[name="domain[name]"]', sandbox.uiDomain);
  // An administrator is not shown the verification method at all: the form
  // omits it and DomainsController verifies the domain outright.
  const verificationFieldCount = await page.locator('select[name="domain[verification_method]"]').count();
  check('the web UI does not ask an administrator how to verify a domain',
    verificationFieldCount === 0,
    `${verificationFieldCount} verification method field(s)`);
  result = await submitRemote(page, 'Create Domain',
    new RegExp('^/org/[^/]+/servers/[^/]+/domains/[^/]+/setup$'));
  // DomainsController verifies a domain outright when the person creating it is
  // an administrator, and redirects to its setup page rather than back to the
  // list. The web UI and the API agree on this, which is what makes the
  // verified_at comparison below meaningful.
  check('the web UI created a domain and was sent to its setup page',
    new RegExp('^/org/[^/]+/servers/[^/]+/domains/[^/]+/setup$').test(result.path || '') && result.errors.length === 0,
    describeRemoteResult(result));

  const uiDomains = await api('GET',
    `/api/v2/organizations/${sandbox.orgPermalink}/servers/${sandbox.uiServerPermalink}/domains`);
  const uiDomain = find(uiDomains, (row) => row.name === sandbox.uiDomain);
  check('and the API reports it', !!uiDomain,
    `the API listed ${show((data(uiDomains) || []).map((row) => row.name))}`);
  check('already verified, which is what the web UI does for an administrator',
    !!uiDomain && !!uiDomain.verified_at,
    uiDomain ? `verified_at was ${show(uiDomain.verified_at)}` : 'the domain was not there');

  stage('ui -> api: credential');

  await goto(page, `/org/${sandbox.orgPermalink}/servers/${sandbox.uiServerPermalink}/credentials/new`);
  await page.fill('input[name="credential[name]"]', sandbox.uiCredentialName);
  // application.coffee disables whichever key input does not belong to the
  // selected type, and for SMTP it disables both, so the key is not something
  // the form can supply. Filling it would fail against a disabled element, and
  // rightly so.
  const enabledKeyInputs = await page.locator('[data-credential-key-type] input[name="credential[key]"]:not([disabled])').count();
  check('the web UI does not let anyone choose a credential key', enabledKeyInputs === 0,
    `${enabledKeyInputs} enabled key input(s)`);
  result = await submitRemote(page, 'Create credential',
    `/org/${sandbox.orgPermalink}/servers/${sandbox.uiServerPermalink}/credentials`);
  check('the web UI created a credential',
    result.path === `/org/${sandbox.orgPermalink}/servers/${sandbox.uiServerPermalink}/credentials`,
    describeRemoteResult(result));

  const shownKey = await text(page, 'ul.credentialList li.credentialList__item:has(.credentialList__name:text-is("' +
    sandbox.uiCredentialName + '")) .credentialList__key');
  const uiCredentials = await api('GET',
    `/api/v2/organizations/${sandbox.orgPermalink}/servers/${sandbox.uiServerPermalink}/credentials`);
  const uiCredential = find(uiCredentials, (row) => row.name === sandbox.uiCredentialName);
  check('and the API reports it', !!uiCredential,
    `the API listed ${show((data(uiCredentials) || []).map((row) => row.name))}`);
  check('with the collection still keeping the key back',
    !!uiCredential && uiCredential.key === undefined,
    uiCredential ? `the collection row carried key ${show(uiCredential.key)}` : 'the credential was not there');

  if (uiCredential) {
    const uiMember = await api('GET',
      `/api/v2/organizations/${sandbox.orgPermalink}/servers/${sandbox.uiServerPermalink}/credentials/${uiCredential.uuid}`);
    check('and the key the web UI generated is the key the API member endpoint returns',
      data(uiMember) && data(uiMember).key === shownKey,
      `the API said ${show(data(uiMember) && data(uiMember).key)}, the UI showed ${show(shownKey)}`);
  }

  stage('ui -> api: http endpoint');

  await goto(page, `/org/${sandbox.orgPermalink}/servers/${sandbox.uiServerPermalink}/http_endpoints/new`);
  await page.fill('input[name="http_endpoint[name]"]', sandbox.uiEndpointName);
  await page.fill('input[name="http_endpoint[url]"]', sandbox.uiEndpointUrl);
  // Deliberately not the first option in either list, so that the comparison
  // below can only pass if the submitted values really travelled.
  await page.selectOption('select[name="http_endpoint[encoding]"]', 'FormData');
  await page.selectOption('select[name="http_endpoint[format]"]', 'Hash');
  result = await submitRemote(page, 'Create HTTP endpoint',
    `/org/${sandbox.orgPermalink}/servers/${sandbox.uiServerPermalink}/http_endpoints`);
  check('the web UI created an HTTP endpoint',
    result.path === `/org/${sandbox.orgPermalink}/servers/${sandbox.uiServerPermalink}/http_endpoints`,
    describeRemoteResult(result));

  const uiEndpoints = await api('GET',
    `/api/v2/organizations/${sandbox.orgPermalink}/servers/${sandbox.uiServerPermalink}/http_endpoints`);
  const uiEndpoint = find(uiEndpoints, (row) => row.name === sandbox.uiEndpointName);
  check('and the API reports it', !!uiEndpoint,
    `the API listed ${show((data(uiEndpoints) || []).map((row) => row.name))}`);
  check('with the URL, encoding and format which were chosen in the form',
    !!uiEndpoint && uiEndpoint.url === sandbox.uiEndpointUrl &&
    uiEndpoint.encoding === 'FormData' && uiEndpoint.format === 'Hash',
    uiEndpoint ? `the API said ${show([uiEndpoint.url, uiEndpoint.encoding, uiEndpoint.format])}` : 'the endpoint was not there');
}

async function runDeletion() {
  stage('deletion through the web UI');

  await goto(page, `/org/${sandbox.orgPermalink}/servers/${sandbox.uiServerPermalink}/domains`);
  const domainRows = await rows(page, 'li.domainList__item', { name: '.domainList__name' });
  const rowIndex = domainRows.findIndex((row) => (row.name || '').includes(sandbox.uiDomain));
  const listed = check('the web UI still lists the domain it created', rowIndex >= 0,
    `the domains page listed ${show(domainRows.map((row) => row.name))}`);
  const deleteLink = listed
    ? page.locator('li.domainList__item').nth(rowIndex).locator('a.domainList__delete')
    : null;
  const deleteCount = listed ? await deleteLink.count() : 0;
  if (listed && check('and offers a delete link for it', deleteCount === 1, `${deleteCount} delete link(s)`)) {
    // data-confirm becomes a window.confirm, which the dialog handler above
    // accepts; data-method=delete becomes a hidden form which rails-ujs
    // submits over AJAX.
    await deleteLink.first().click();
    const result = await submitRemoteResult(page,
      `/org/${sandbox.orgPermalink}/servers/${sandbox.uiServerPermalink}/domains`);
    check('deleting through the web UI works', result.errors.length === 0 && !result.timedOut,
      describeRemoteResult(result));

    const remaining = await api('GET',
      `/api/v2/organizations/${sandbox.orgPermalink}/servers/${sandbox.uiServerPermalink}/domains`);
    check('and the API stops reporting the domain the web UI deleted',
      !find(remaining, (row) => row.name === sandbox.uiDomain),
      `the API still listed ${show((data(remaining) || []).map((row) => row.name))}`);
  }

  stage('deletion through the API');

  const endpoints = await api('GET',
    `/api/v2/organizations/${sandbox.orgPermalink}/servers/${sandbox.uiServerPermalink}/http_endpoints`);
  const target = find(endpoints, (row) => row.name === sandbox.uiEndpointName);
  if (check('the endpoint the web UI created is still there to delete', !!target,
    `the API listed ${show((data(endpoints) || []).map((row) => row.name))}`)) {
    const deleted = await api('DELETE',
      `/api/v2/organizations/${sandbox.orgPermalink}/servers/${sandbox.uiServerPermalink}/http_endpoints/${target.uuid}`);
    check('DELETE /http_endpoints/:uuid returned 204', deleted.status === 204,
      `${deleted.status} ${deleted.text.slice(0, 200)}`);

    await goto(page, `/org/${sandbox.orgPermalink}/servers/${sandbox.uiServerPermalink}/http_endpoints`);
    const names = await texts(page, 'ul.endpointList li.endpointList__item .endpointList__name');
    check('and the web UI stops listing it', !names.includes(sandbox.uiEndpointName),
      `the UI still listed ${show(names)}`);
  }
}

// The delete link is not a form, so there is no submit button to click and no
// expected redirect to wait for: rails-ujs posts it and ajax.coffee sends
// Turbolinks to whatever comes back. This waits for the list page to be
// rendered again rather than for a URL which is already the current one.
async function submitRemoteResult(page_, expectedPath, timeoutMs = 25000) {
  const deadline = Date.now() + timeoutMs;
  let last = { path: null, errors: [], flash: [], timedOut: true };
  while (Date.now() < deadline) {
    last = await page_.evaluate(() => ({
      path: location.pathname,
      errors: Array.from(document.querySelectorAll('.formErrors li'))
        .map((element) => element.textContent.replace(/\s+/g, ' ').trim()),
      flash: Array.from(document.querySelectorAll('.flashMessage'))
        .map((element) => element.textContent.replace(/\s+/g, ' ').trim()),
      // The domain is gone from the list once the delete has been applied and
      // the page replaced, which is a more reliable signal than the URL.
      listed: Array.from(document.querySelectorAll('.domainList__name'))
        .map((element) => element.textContent.replace(/\s+/g, ' ').trim()),
    }));
    last.timedOut = false;
    if (last.errors.length > 0) return last;
    if (last.path === expectedPath && !last.listed.some((name) => name.includes(sandbox.uiDomain))) return last;
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
  last.timedOut = true;
  return last;
}

// ---------------------------------------------------------------------------

async function teardown() {
  stage('teardown');

  // Deleting an organization or a server is guarded against a mistake the same
  // way in the API as it is in the web UI: the name has to be echoed back in
  // confirm_text. A teardown which omitted it would be refused with a 422 and
  // leave the sandbox behind.
  const targets = [
    [`/api/v2/organizations/${sandbox.orgPermalink}/servers/${sandbox.uiServerPermalink}`, sandbox.uiServerName],
    [`/api/v2/organizations/${sandbox.orgPermalink}/servers/${sandbox.apiServerPermalink}`, sandbox.apiServerName],
    [`/api/v2/organizations/${sandbox.orgPermalink}`, sandbox.orgName],
  ];
  for (const [target, confirmText] of targets) {
    const response = await api('DELETE', target, { confirm_text: confirmText });
    if (response.status === 204) {
      console.log(`  removed ${target}`);
    } else if (response.status === 404) {
      console.log(`  ${target} was already gone`);
    } else {
      console.log(`  could not remove ${target}: ${response.status} ${response.text.slice(0, 200)}`);
      failed += 1;
    }
  }

  // The organization is soft deleted, which keeps the row and therefore keeps
  // its globally unique permalink taken. That is a property of Postal rather
  // than of this script, but it is worth stating because it is the reason a
  // second run cannot reuse the name.
  const organizations = await api('GET', '/api/v2/organizations');
  const stillListed = find(organizations, (row) => row.permalink === sandbox.orgPermalink);
  check('the API no longer lists the sandbox organization', !stillListed,
    `the API still listed ${show((data(organizations) || []).map((row) => row.permalink))}`);
}

main().catch((error) => {
  console.error(`\ncross-check aborted: ${error && error.stack ? error.stack : error}`);
  captureScreenshot('aborted');
  screenshotQueue.then(() => process.exit(1));
});
