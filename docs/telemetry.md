# What Lifeboat reports, and what it deliberately does not

This is the customer-facing truth about every byte a Lifeboat install sends to
iterate.ai. Keep it accurate — it is the document a security review will hold
you to, and it is referenced from `telemetry.py`, which is the code that has to
match it.

## The three messages

| message | sent by | when | carries |
|---|---|---|---|
| **Activation** | an install being licensed | once, when a key is entered | licence key, `cluster_id` |
| **Heartbeat** | a licensed install, **online licences only** | 30 s after boot, then every 6 h (`LIFEBOAT_HEARTBEAT_INTERVAL_HOURS`), and once immediately before starting an inference server (throttled to 60 s, 3 s ceiling) | licence key, `cluster_id`, pod count, version, hardware fingerprint |
| **Census** | an install with **no** licence key | once every 24 h (`LIFEBOAT_CENSUS_INTERVAL_HOURS`) | `cluster_id`, version, lifecycle state, first-boot time, hardware fingerprint |

The heartbeat is **not** "every few minutes" — that was a reasonable guess and
it is wrong by two orders of magnitude. The 6-hour interval is why revocation
also has a synchronous pre-start check: a binding released on the licence
server blocks the very next server start, rather than waiting up to 6 hours.

### An offline licence sends nothing, ever

`_send_heartbeat` returns immediately when `source == "offline"`, and so does
the census beat. That is a property of the code, not of the customer's
firewall: an air-gapped install that *could* reach the internet still would
not. The consequence is stated where it matters — a licence reset cannot reach
an offline install, so it has to be deactivated on the box.

## Payload sizes

Steady state, licensed:

```json
{"license_key":"LB-XXXX-XXXX-XXXX-XXXX","cluster_id":"3f9a1c2e-…","pod_count":1,
 "version":"2.2.40","hw_hash":"81ab8ac424596572"}
```

~160 bytes, pinned by a test (`test_steady_state_beat_is_tiny`, ceiling 256).
At 6-hour intervals that is under 250 KB per install **per century**.

## The hardware block is sent ONCE

The full description rides along on the first beat and is then represented by
its 16-character fingerprint. If the licence server does not recognise a
fingerprint it answers `need_hw: true` and the next beat carries the block
again — so a lost row self-heals instead of leaving a permanent hole.

```json
{"v":1,"os":"linux","arch":"x86_64","tier":"gpu_full","engine":"sglang",
 "cpu":{"cores":64,"threads":128,"isa":"avx512","model":"AMD EPYC 9555P"},
 "mem":{"total_gb":1536.0},
 "acc":{"vendor":"nvidia","count":2,"gpus":[["NVIDIA H100 80GB HBM3",81559],
        ["NVIDIA H100 80GB HBM3",81559]],"arch":"9.0","fp8":true},
 "rt":"docker"}
```

The fingerprint deliberately covers **no volatile field** — no free memory, no
utilisation, no temperature. If it did, it would change on every beat, the
block would be re-sent every beat, and "send once" would be quietly false while
still looking correct. Free memory is excluded when the snapshot is *built*,
not filtered when it is hashed, so there is one place to get this wrong instead
of two.

The fingerprint is a hash of a hardware *description*, so two identical
machines collide by design. It is not a device identifier and is useless for
singling out an install; `cluster_id` remains the only identifier.

## What is never collected

No model names or paths. No prompt or completion text. No token counts. No
request counts. No API keys. No hostnames. No IP addresses (beyond the source
address of the connection itself, which any HTTPS request reveals). No
filesystem paths. No usernames or email addresses. No dataset names.

This is enforced, not merely intended:
`test_snapshot_carries_nothing_about_workload_or_identity` walks every key of
the real snapshot against a forbidden list, so adding one breaks the build.

## Turning it off

`LIFEBOAT_TELEMETRY=off` (also `0`, `false`, `no`, `disabled`).

It stops the census beat and strips the hardware block from the heartbeat. It
does **not** stop the licence heartbeat itself: proving that a licence is bound
to one cluster is a contractual obligation, not telemetry. An offline licence
is the way to send nothing at all.

`GET /api/license/status` reports `"telemetry": true|false` so an operator can
confirm the switch took effect without reading a log.

---

# "Is it illegal to send model names and token counts?"

Short answer: **not illegal, but do not do it by default.** The honest framing
is that it is a contractual and trust problem long before it is a legal one,
and the legal exposure depends on who your customers are.

*Engineering and compliance analysis, not legal advice. Have counsel confirm
before any of this reaches a customer agreement.*

### Why hardware facts are easy and workload facts are not

A CPU model and a GPU count describe **the customer's machine**. A model name
and a token count describe **what the customer is doing** — which model they
chose, how much they run, when they run it, and how that changes over time.
That is competitively sensitive business information about them, held by you,
whether or not any regulation names it.

Concretely, what you would be able to infer: which of your customers are
evaluating a competitor's model, which are scaling up before they tell their
account manager, which have gone quiet, and roughly what their inference spend
is. That is genuinely useful to you — which is exactly why a customer's
security reviewer will treat its collection as adverse.

### The specific regimes

**GDPR / UK GDPR.** A source IP address is personal data (*Breyer*, C-582/14),
and `cluster_id` is at minimum a pseudonymous identifier. Even today's
hardware-only telemetry is therefore processing of personal data and needs a
lawful basis — legitimate interest is available and defensible for licence
enforcement and support, but it requires: a transparent privacy notice, a
Legitimate Interests Assessment on file, and a documented retention period.
Adding workload metadata does not change the lawful basis so much as weaken the
balancing test, because the processing stops being necessary for the stated
purpose. **Purpose limitation is the real constraint: you cannot collect
usage data for "licence enforcement" and then use it for sales.**

**Customer data vs personal data.** Token counts are metadata, not content, so
they are not the end user's personal data. But they *are* the customer's
confidential information, and most enterprise agreements and DPAs restrict what
a vendor may extract from software running on the customer's own infrastructure.
This is where the real risk sits: not a regulator, a contract.

**Regulated sectors.** A hospital or a bank running Lifeboat on-prem will ask
what leaves the box. Token counts are not PHI and not cardholder data, so no
BAA or PCI obligation is triggered by them directly — but "the vendor's
software reports usage to the vendor" is a finding in any HIPAA or SOC 2 review
unless it is disclosed, contractually permitted and minimisable. Several
customers will simply prohibit it.

**China / India / EU data-residency rules.** Once you hold usage data you have
to say where it lives. Hardware inventory raises the same question far more
weakly.

### Recommendation

1. **Keep the default at hardware-only.** It is defensible in one sentence —
   *"we record what kind of machine your licence runs on, and nothing about
   what you run on it"* — and that sentence is worth more in enterprise deals
   than the data would be.
2. **If you want usage insight, make it explicitly opt-in**, per install, with
   a benefit the customer receives (a usage dashboard, right-sizing advice, a
   volume discount). `LIFEBOAT_USAGE_INSIGHTS=on`, default off, off by
   construction on offline licences.
3. **If you build it, aggregate before it leaves the box.** Daily totals and
   model-*family* buckets ("a 30B MoE"), never per-request records and never
   the operator's own aliases — an alias like `acme-claims-triage` is itself
   disclosure. Aggregating on the customer's machine is the difference between
   a statistic and a log.
4. **Publish a retention period and honour it.** The monitor purges its event
   table on a daily cron (`LIFEBOAT_MONITOR_RETAIN_DAYS`, default 180).
5. **Say it in the docs before you ship it**, not after. The kill switch is
   worth very little if a customer discovers the feature by running tcpdump.

### Counting unlicensed installs — the one judgement call here

The census beat is new behaviour: installs that previously sent nothing now
report that they exist. That is normal for licensed software and it is how you
answer "is this evaluation alive", but it is still a change worth being
straight about, because the people affected are precisely those who have not
yet agreed to anything.

What makes it defensible: no licence key, nothing about workload, the same
hardware description a licensed install sends, once a day, with a documented
kill switch — and the fact that installing the software already implies a
connection to the licence server within 24 hours anyway. What it needs before
it ships: this page reachable from the first-run UI and from the Docker Hub
description, and the privacy notice updated in the same commit.
