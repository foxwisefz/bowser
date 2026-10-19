# System WebKit push delivery probe

Tested 2026-09-13 on macOS 26.6.2 (25G83), arm64, installed WebKit
21624.5.1.11.3. Tracking: `bowser-browser-fy6e.2`.

## Result

A Developer ID-signed app with hardened runtime and no extra entitlements can
deliver a local payload through `_processPushMessage:completionHandler:` to a
real service worker after destroying its WKWebView. The worker reported zero
window clients, read the exact payload, and requested a native notification.
Passing that notification's native metadata to
`_processPersistentNotificationClick:completionHandler:` dispatched a real
`notificationclick` event to the worker.

Standard `registration.pushManager.subscribe(...)` failed with:

```text
AbortError: No connection to push daemon
```

This proves native worker dispatch and click dispatch, **not** a complete Web
Push integration. No subscription endpoint was created, no network push service
was connected, and no encrypted Web Push payload was decrypted. Subscription
provider integration remains the gate before building a production relay.

## Custom-provider admission

Tested again 2026-10-19 on the same macOS and WebKit versions. A disposable
user-level Mach service was configured through
`_WKWebsiteDataStoreConfiguration.setWebPushMachServiceName:`. Both the test
app and provider were Developer ID-signed with hardened runtime and no extra
entitlements. A separate control client reached the provider and received its
reply before the WKWebView attempted to subscribe.

The provider received no WebKit requests. macOS recorded:

```text
Sandbox: com.apple.WebKit.Networking(...) deny(1) mach-lookup com.foxwiseai.bowser.pushprobe.<UUID>
denied lookup: ... error = 159: Sandbox restriction
```

The page received `AbortError: Connection to web push daemon failed`. Native
worker delivery after closing the tab and notification-click dispatch still
passed. The temporary provider was removed at test exit.

This establishes a sandbox blocker for this custom-provider path in the
installed system WebKit. It does not establish that every possible native
integration is impossible. The control provider implements only a connectivity
check, not subscriptions, encryption or remote delivery; the failure happens
before those would be exercised. Do not build the production relay on the
assumption that this configuration hook provides a working connection.

## Method and controls

`bin/check-web-push` builds `tests/web-push-probe/Probe.m` as a separate app,
signs it with a normal Developer ID identity, and runs a loopback fixture server.
Each run uses fresh randomly identified WKWebsiteDataStores and a temporary
home override. It neither launches installed Bowser nor reads its profiles.
The default mode creates no daemon. The optional provider check registers a
uniquely named, temporary user-level service and removes it on exit; it does not
alter system services or claim private entitlements.

The fixture registers an actual service worker on a secure-context loopback
origin. Native private preference setters enable push/notification APIs. The
data-store delegate supplies an Allow decision for this test origin. This tests
an already-approved site, not a user gesture or permission prompt.

After the page reports readiness, the probe removes message handlers, detaches
and releases the WKWebView, closes its window, and dispatches after a delay.
Evidence is posted by the service worker itself to the loopback fixture; no
page script synthesizes the push or notificationclick events.

Two controls precede valid delivery: an unregistered scope and a different
fresh data store, each with a distinct payload. Neither control payload reaches
the worker. The other data store returns false. The unregistered scope returns
true despite delivering no event: the native completion flag must not be treated
as an end-to-end delivery acknowledgement.

The native notification delegate captures the request and invokes click dispatch
programmatically. The test does not request macOS notification permission,
display a banner, simulate a user's click, or exercise `clients.openWindow`.
It also does not prove persistence across app relaunch, worker process termination,
minimum supported macOS compatibility, or encrypted remote delivery.

## Reproduce

```sh
BOWSER_SIGN_IDENTITY='Developer ID Application: Foxwise AI FZ-LLC (V7W5LP47U9)' bin/check-web-push
```

To also test custom-provider admission:

```sh
BOWSER_SIGN_IDENTITY='Developer ID Application: Foxwise AI FZ-LLC (V7W5LP47U9)' \
  BOWSER_PUSH_PROVIDER_CHECK=1 bin/check-web-push
```

The provider mode requires a logged-in macOS GUI session. It adds
`provider-control.jsonl`, `provider.jsonl`, `provider-connection.log`,
`provider-result.json` and `provider-cleanup.txt` to the evidence directory.
The connection log is restricted to the unique test service name. An absent
control reply or missing admission evidence fails the check. A reported
`BLOCKED` outcome confirms the sandbox rejection, not Web Push support. If a
future WebKit reaches the provider, the result explicitly reports that
subscriptions and encrypted delivery remain unimplemented.

The command prints an evidence directory containing native and worker JSONL,
stderr, signing inspection, and the isolated app. It asserts actual payload,
zero clients, notification-click evidence, and absence of control deliveries.
Its PASS line applies only to those assertions. Subscription results are printed
separately. The fixture server exits with the runner; evidence is retained.

## Next engineering question

Can an available native integration bind a Bowser subscription provider to
system WebKit without the rejected network-process Mach lookup? If not, full
Web Push requires an explicit engine-distribution decision: investigate a
maintained Bowser WebKit build or another engine. An alternative product
milestone is native notifications from running pages, with its tab-lifecycle
limits stated clearly. That milestone does not satisfy this Web Push gate.

The working payload dispatch method supplies neither subscription creation nor
a standards-compliant `PushSubscription` object. Do not ship a page-only shim
as a substitute for that integration.

Reference declarations and dictionary format:
[WKWebsiteDataStore private API](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKWebsiteDataStorePrivate.h),
[WebPushMessageCocoa](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/Shared/Cocoa/WebPushMessageCocoa.mm),
[data-store delegate](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/_WKWebsiteDataStoreDelegate.h).
