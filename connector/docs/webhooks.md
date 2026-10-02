# Native inbound notifications

Connector registers `people-native` in its descriptor-owned route file using
Bilimbi's [inbound webhook seam](https://github.com/BelimbingApp/bilimbi/blob/a4511f3f06a16a212597716f8eac238620bdf761/docs/architecture/inbound-webhooks.md).
The host owns `POST /webhooks/people-native`, parser isolation, body/rate limits,
receipt audit and uniform responses: 202 accepted or 403 delivery refused.

On **People connections**, a manager sets the company-scoped signing secret,
allowed clock difference (1–86400 seconds, default 300) and intake switch.
Intake defaults disabled and enabling requires a secret of 32–4096 bytes.
The secret is encrypted in `people-connector.webhook.secret`, has no reveal
path and never appears in the receipt, audit payload or UI. The switch and
clock setting are `people-connector.webhook.enabled` and
`people-connector.webhook.max_skew_seconds`. Connection management authority
and Core Company reach are required; a same-tenant sibling needs tenant-wide
reach. Clearing the secret requires disabling intake in the same save.

This is receipt intake for native directory-change notifications. It does not
activate outbound delivery, a remote directory reader, or vendor transport.
The sender is a machine with the company's signing secret, not a login actor.
The handler records the notification and last receipt for an operator to
review. **Synchronise now** remains the actor-authorized mechanism for
refreshing Connector projections from co-located People. No People business
history is written and no directory work is enqueued under a fabricated actor.

## Signed request contract, version 1

Send each header exactly once:

| Header | Meaning |
| --- | --- |
| `x-people-tenant` | Validated tenant's positive decimal ID |
| `x-people-company` | Platform company ID: a live Core Company in that tenant, not a workforce company or employee ID |
| `x-people-timestamp` | Positive decimal Unix seconds at signing |
| `x-people-nonce` | Unique attempt key, 1–100 ASCII characters |
| `x-people-delivery` | Stable delivery key across attempts, 1–100 ASCII characters |
| `x-people-signature` | Lowercase hexadecimal HMAC-SHA256, 64 characters |

Numeric headers have no leading zero and at most 18 digits. Nonce and delivery
keys start with a letter or digit and otherwise allow letters, digits, `.`,
`_`, `:` and `-`. Duplicate headers, including differently cased duplicates,
are refused. The raw body is a JSON object containing only
`{"event":"directory.changed"}`. Its whitespace is significant for signing
and delivery identity; retry with the exact same bytes.

HMAC input is the following byte sequence. There is one LF between each line,
one LF after the delivery key, and then the **exact raw body bytes** with no
normalization or extra LF:

```text
people-native:v1
<tenant>
<platform company>
<timestamp>
<nonce>
<delivery>
<raw body>
```

The secret is resolved from the validated tenant and platform company before
constant-time verification. All routing fields are authenticated. Only an
enabled native connection with a current Workforce company mapping and
enabled intake can verify. Body decoding happens after verification. Handling
rechecks policy and signature under a connection row lock, so rotation or
disabling between verification and handling refuses the delivery.

## Replay, retries and audit

Migration `20261002070003` owns `people_connector_webhook_nonces` and
`people_connector_webhook_deliveries`, each tenant-owned and cascading from
its Connector connection. Named unique indexes enforce one nonce and one
delivery hash per connection. SHA-256 hashes of the nonce, delivery key and
body are stored; raw keys, signatures and payloads are not. These fresh tables
are Bilimbi-only, with no adoption or import path.

A used nonce always refuses. To retry a delivery, mint a **new nonce and
current timestamp**, keep its delivery key and raw body unchanged, and sign
again. A repeated delivery with identical body bytes acknowledges successfully
without recording a second notification. Reusing its key for different bytes
refuses. Nonce consumption, first receipt and scoped audit commit atomically;
a failed handling transaction leaves neither nonce nor receipt. Concurrent
requests serialize on the connection lock. The callback also tolerates a retry
when host receipt auditing fails after module work has committed.

A scoped `people-connector.webhook` Audit action records `received` or
`duplicate`, the platform company, and guest actor 0; the signature proves a
sender, not an account. Repo mutation capture records nonce/delivery and
operator settings writes. Pre-authentication and replay refusals receive the
host's unscoped guest audit, avoiding an unauthenticated claim of tenant
identity. No body, signature, secret or provider error text is logged.

Replay and delivery history survive restart and secret rotation and are kept
until an operator purge under the company's [retention](operations.md) period. Changing
provider or Workforce mapping clears the signing secret, intake switch and
clock-difference override; removing a connection clears them and also deletes
its receipt history. Recreating a connection starts a new receipt lifetime:
configure a fresh signing secret rather than reusing the old one.
