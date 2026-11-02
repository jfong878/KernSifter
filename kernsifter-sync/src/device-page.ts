/**
 * The device-approval page, rendered on the server.
 *
 * It is deliberately plain HTML with no JavaScript: the approval step is a
 * security decision made by a signed-in human, and a page that needs no script
 * cannot be subverted by one. Every dynamic value is HTML-escaped — the code
 * arrives from the query string and the client name arrives from a native
 * client, so both are untrusted input being written into a page.
 */

/** Escape a value for interpolation into HTML text or a quoted attribute. */
export function escapeHtml(value: string): string {
  return value
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

export interface DevicePageOptions {
  /** The code as the user entered or linked it, normalised for display. */
  userCode: string | null;
  /** Set when the code resolves to a live, pending authorization. */
  pending: { clientName: string; expiresIn: number } | null;
  signedIn: boolean;
  /** Path to return to after signing in, including the code when present. */
  returnTo: string;
  /** A human-readable problem to show above the form. */
  problem?: string;
}

const SHELL_STYLE = `
  :root { color-scheme: light dark; }
  body { margin: 0; padding: 2.5rem 1.25rem; font: 16px/1.55 system-ui, -apple-system, Segoe UI, sans-serif; display: flex; justify-content: center; }
  main { width: 100%; max-width: 30rem; }
  h1 { font-size: 1.35rem; margin: 0 0 .35rem; }
  p.lede { margin: 0 0 1.5rem; opacity: .75; }
  .card { border: 1px solid color-mix(in srgb, currentColor 20%, transparent); border-radius: .75rem; padding: 1.25rem; }
  .client { font-weight: 600; font-size: 1.05rem; margin: 0 0 .25rem; word-break: break-word; }
  .expiry { margin: 0 0 1.25rem; opacity: .75; font-size: .9rem; }
  label { display: block; font-weight: 600; margin-bottom: .4rem; font-size: .9rem; }
  input[type=text] { width: 100%; box-sizing: border-box; padding: .65rem .75rem; font: inherit; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; letter-spacing: .12em; text-transform: uppercase; border-radius: .5rem; border: 1px solid color-mix(in srgb, currentColor 30%, transparent); background: transparent; color: inherit; }
  .row { display: flex; gap: .6rem; margin-top: 1.25rem; flex-wrap: wrap; }
  button { font: inherit; padding: .6rem 1.1rem; border-radius: .5rem; border: 1px solid transparent; cursor: pointer; }
  button.primary { background: #2f6feb; color: #fff; }
  button.quiet { background: transparent; color: inherit; border-color: color-mix(in srgb, currentColor 30%, transparent); }
  .problem { margin: 0 0 1rem; padding: .6rem .75rem; border-radius: .5rem; background: color-mix(in srgb, #d64545 22%, transparent); }
  code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; letter-spacing: .12em; }
  a { color: #2f6feb; }
`;

function shell(title: string, body: string): string {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>${escapeHtml(title)}</title>
<style>${SHELL_STYLE}</style>
</head>
<body>
<main>
${body}
</main>
</body>
</html>
`;
}

function problemBlock(problem: string | undefined): string {
  return problem ? `<p class="problem">${escapeHtml(problem)}</p>` : '';
}

function codeForm(userCode: string | null): string {
  return `<form class="card" method="post" action="/api/device/lookup">
  <label for="code">Enter the code shown in your app</label>
  <input id="code" name="user_code" type="text" inputmode="latin" autocomplete="off"
         autocapitalize="characters" spellcheck="false" maxlength="9" required
         value="${userCode ? escapeHtml(userCode) : ''}" placeholder="XXXX-XXXX">
  <div class="row"><button class="primary" type="submit">Continue</button></div>
</form>`;
}

export function renderDevicePage(options: DevicePageOptions): string {
  const { userCode, pending, signedIn, returnTo, problem } = options;

  if (!signedIn) {
    // The sign-in link carries the code in `returnTo` so the user lands back on
    // the consent screen with the code still filled in.
    const signIn = `/auth/freebuff/signin?returnTo=${encodeURIComponent(returnTo)}`;
    return shell(
      'Connect a device',
      `<h1>Connect a device to KernSifter</h1>
<p class="lede">Sign in to approve this device. KernSifter never sees your password.</p>
${problemBlock(problem)}
<div class="card">
  <p style="margin:0">You need to be signed in to approve a device.</p>
  <div class="row"><a href="${escapeHtml(signIn)}"><button class="primary" type="button">Sign in with Freebuff</button></a></div>
</div>`,
    );
  }

  if (pending) {
    const minutes = Math.max(1, Math.ceil(pending.expiresIn / 60));
    const clientName = pending.clientName
      ? escapeHtml(pending.clientName)
      : 'An unidentified app';
    return shell(
      'Approve device',
      `<h1>Approve this device?</h1>
<p class="lede">Only continue if you started this on a device you trust.</p>
${problemBlock(problem)}
<div class="card">
  <p class="client">${clientName}</p>
  <p class="expiry">wants to sync your KernSifter data. This code expires in ${minutes} minute${minutes === 1 ? '' : 's'}.</p>
  <div class="row">
    <form method="post" action="/api/device/approve">
      <input type="hidden" name="user_code" value="${userCode ? escapeHtml(userCode) : ''}">
      <button class="primary" type="submit">Approve</button>
    </form>
    <form method="post" action="/api/device/deny">
      <input type="hidden" name="user_code" value="${userCode ? escapeHtml(userCode) : ''}">
      <button class="quiet" type="submit">Deny</button>
    </form>
  </div>
</div>`,
    );
  }

  return shell(
    'Connect a device',
    `<h1>Connect a device to KernSifter</h1>
<p class="lede">Entering the code approves one app on one device. You can revoke it later.</p>
${problemBlock(problem)}
${codeForm(userCode)}`,
  );
}

/** Terminal page shown after an approve/deny form post. */
export function renderDeviceResult(options: {
  ok: boolean;
  clientName?: string;
  message: string;
  signedIn: boolean;
  returnTo: string;
}): string {
  const { ok, clientName, message, signedIn, returnTo } = options;
  const body = `<h1>${ok ? 'Device approved' : 'Device not approved'}</h1>
${ok ? '' : problemBlock(message)}
<div class="card">
  <p style="margin:0">${ok ? escapeHtml(message) : ''}</p>
  ${ok && clientName ? `<p class="expiry" style="margin:.5rem 0 0">${escapeHtml(clientName)}</p>` : ''}
</div>
<p class="lede" style="margin-top:1.25rem">You can close this window and return to the app.</p>`;
  return shell(ok ? 'Device approved' : 'Device not approved', body + (signedIn ? '' : `<p class="lede"><a href="${escapeHtml(`/auth/freebuff/signin?returnTo=${encodeURIComponent(returnTo)}`)}">Sign in</a></p>`));
}
