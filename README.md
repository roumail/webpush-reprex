# Reprex: Web Push from Erlang

The smallest working example of a server (the "relay") waking a phone through
**Web Push**. This is the push an installed web app gets on iPhone (iOS 16.4+,
added to the home screen) and on Android, with no Apple developer account.
The tests come first and are the spec for the relay's push sender.

Plain Erlang/OTP 27 with **no dependencies**: `crypto`, `public_key`, `httpc`,
`ssl` and `json` all ship with OTP.

## What Web Push is, in four steps

```
 phone (web app)                relay (this code)           push service
 ───────────────                ─────────────────           ────────────
 1. pushManager.subscribe() ──► gets endpoint URL + keys
                                (p256dh, auth) as JSON
 2.                             encrypt payload to the keys
                                (RFC 8291, aes128gcm)
 3.                             sign with VAPID (RFC 8292) ─► POST endpoint
 4. service worker decrypts ◄───────────────────────────────  delivers
```

The push service (Apple's for Safari, Google's for Chrome) only ever sees
ciphertext. The relay never needs an account with it: the VAPID key pair is
the relay's identity.

## Layout: who plays whom

```
webpush-reprex/
├── README.md                 this file
├── run-tests.sh              runs the suite (local rebar3, else Docker)
├── push.sh                   manual check: make keys, push to a real phone
├── rebar.config              no dependencies
├── src/
│   ├── webpush.app.src
│   ├── webpush.erl           THE CODE UNDER TEST: what the relay will do
│   └── webpush_manual.erl    what push.sh runs
├── test/                     AUTOMATED: no network, no phone
│   ├── webpush_SUITE.erl     THE SPEC: one test case per scenario
│   ├── browser.erl           plays the phone's browser
│   └── fake_push_service.erl plays Apple's / Google's push server
└── docs/                     MANUAL: the test page, served by GitHub Pages
    ├── index.html, app.js    subscribes and shows the subscription JSON
    ├── sw.js                 service worker: shows each push
    ├── manifest.json         makes it installable to the home screen
    └── config.js             the VAPID public key (made by push.sh keys)
```

Never committed (`*.local.json`, gitignored): `vapid.local.json` (the VAPID
private key) and `subscription.local.json` (the phone's subscription).

| Module | Plays | Does |
|---|---|---|
| `webpush` | the relay | `subscription/1` reads the web app's JSON; `vapid_keys/1`; `encrypt/2,3`; `send/4` |
| `browser` | the phone | makes a subscription like `pushManager.subscribe()`; decrypts a push like the service worker. Written separately from `webpush`, so the code is never checked against itself |
| `fake_push_service` | Apple / Google | a one-request HTTP server on 127.0.0.1 that hands the request to the test and answers 201, 410, … |

Nothing leaves the machine: the endpoint is `http://127.0.0.1:<port>/push/device-1`.

## The scenarios (`test/webpush_SUITE.erl`)

| Test case | Proves |
|---|---|
| `encrypts_the_rfc8291_example` | With the RFC's fixed keys and salt, the body is byte-for-byte the RFC's (Appendix A). Pins us to the standard. |
| `browser_helper_reads_the_rfc8291_example` | Tests the tester: the fake browser decrypts the RFC's message. |
| `delivers_a_message_the_browser_can_read` | End to end: POST to the endpoint, `aes128gcm`, no readable text on the wire, the phone decrypts it. |
| `signs_the_request_with_vapid` | `Authorization: vapid t=<JWT>, k=<key>`; ES256 signature verifies; `aud` = push service origin, `exp` ≤ 24 h, `sub` set. |
| `asks_for_ttl_and_urgency` | An incoming call is sent with `TTL: 45` and `Urgency: high`. |
| `every_push_is_encrypted_afresh` | Each push has its own salt and server key. |
| `a_gone_subscription_is_reported` | A 410 from the push service becomes `{error, gone}`, so the relay deletes the subscription. |
| `the_largest_payload_fits_and_one_more_byte_is_refused` | 3993 bytes go through; 3994 are refused before any request. |
| `reads_the_subscription_json_from_the_web_app` | The web app's JSON becomes `#{endpoint, p256dh, auth}`; malformed keys are refused. |

Each test reads as Given / When / Then: the `step/2` labels appear in the
Common Test log.

## Running

```sh
./run-tests.sh
```

- Uses `rebar3` if installed (`brew install erlang rebar3`), otherwise the
  official `erlang:27` Docker image, pinned by digest.
- Results: the terminal summary; details per step in
  `_build/test/logs/index.html`.
- One scenario: `./run-tests.sh --case=a_gone_subscription_is_reported`.
- Play with it in a shell: `rebar3 shell` (or
  `docker run --rm -it -v "$PWD":/app -w /app erlang:27 rebar3 shell`), then
  `webpush:vapid_keys(<<"https://family.example">>).`

## Manual check on a real iPhone

What the automated tests can't prove: that Apple's real push service accepts
our requests and the phone shows the notification.

Test page: https://www.rohailtaimour.com/webpush-reprex/

1. **Keys (once):** `./push.sh keys` writes `vapid.local.json` (private) and
   `docs/config.js` (public). Commit and push `docs/config.js`.
2. **Phone:** open the page in Safari → Share → Add to Home Screen → open it
   from the home screen → *Turn on notifications* → allow → *Copy
   subscription*.
3. **Mac:** paste it into `subscription.local.json` (Universal Clipboard,
   or AirDrop a note).
4. **Send:** lock the phone, then `./push.sh send "Dad: dinner is ready"`.
   `ok` means Apple accepted it; the notification should show on the lock
   screen. `{error, gone}` means subscribe again on the phone.

**Result 2026-11-21:** `ok` from Apple, and the notification showed on a
locked iPhone 14 Pro (iOS 18.6.2) running the test page from the home screen.

## For Elixir later

Everything here is OTP. In Elixir the same calls read `:crypto.mac(...)`,
`:httpc.request(...)`, `:json.decode(...)`, and the suite would be ExUnit.
Porting this module is a good first Elixir exercise.
