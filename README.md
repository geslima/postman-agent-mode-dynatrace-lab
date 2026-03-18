# Postman Agent Mode + Dynatrace MCP: I Found the Root Cause of a Database Lock Using Plain English

*Published 18 March 2026*

---

## The Investigation That Eats Your Morning

You know the scene. Your Postman tests are passing, but something feels off. An endpoint that should respond in 300ms is taking 10 seconds. No errors. No exceptions. Just slowness.

You already use Dynatrace, so the data is there. The question is how long it takes to surface it. You navigate to the service, check the response time chart, spot the spike, then switch to logs, write a DQL query, filter by the right time window, cross-reference with database metrics, and try to piece together a coherent picture of what actually happened. On a good day, with a fresh mind, that process takes 20 to 30 minutes. On a bad day, when the incident is still live and someone is waiting for an answer, it takes longer.

This is the problem that Dynatrace and Postman set out to address when, on 12 March 2026, they announced an integration allowing **Postman Agent Mode** to query **Dynatrace via MCP** (the Model Context Protocol) in real time, without leaving the tool you already use for API testing. Rather than navigating Dynatrace manually and correlating events with performance spikes by hand, you describe the problem in plain English and let the agent do the legwork.

I built a complete lab to test this properly, injected a table lock into PostgreSQL, and asked the agent what was going on. The result was genuinely impressive.

---

## What MCP Is and Why It Matters

The Model Context Protocol is an open standard that allows AI agents to connect to external tools in a structured, machine-readable way. Rather than copying and pasting logs into a chat window, the agent accesses data directly, executes queries, correlates information across sources, and delivers a coherent analysis.

In this integration, Dynatrace exposes an MCP server with 14 tools*, ranging from executing DQL (Dynatrace's query language) to anomaly detection and querying problems raised by Davis AI.

The lab architecture looked like this:

```
Postman Agent Mode ──▶ Dynatrace MCP Server ──▶ Dynatrace SaaS
       │                                              │
       ▼                                              ▼
  Orders API                                   Davis AI + Grail
  (.NET 10)                                    (logs, metrics)
       │
       ▼
  PostgreSQL 18
  (Podman container)
```

**Lab stack (almost entirely free):**

| Component | Cost |
|---|---|
| Postman (free plan) | Free |
| Dynatrace 15-day Trial | Free |
| .NET 10 API + Kestrel | Free |
| PostgreSQL 18 via Podman | Free |
| Hetzner server (Rocky Linux 10) | ~£0.80–1.20/day |

---

## Building the Lab: The Real Secret Is Telemetry

The API consists of four straightforward endpoints built with .NET 10 Minimal API, Kestrel, Npgsql, and Dapper. The entire environment (API, database, firewall rules, and PostgreSQL configuration) is provisioned automatically by a single `setup-lab.sh` script available in my GitHub repository [LINK]. The full code is there too, but what truly matters for this lab is getting the observability stack right before anything else.

### ActiveGate and PostgreSQL Extension

Beyond the OneAgent, we installed an **ActiveGate** on the server and configured the PostgreSQL extension in Dynatrace. This gives the platform visibility inside the database (statement-level metrics, lock events, and execution plans) rather than just observing it from the outside. The combination of the ActiveGate and the extension is what gives Agent Mode the depth of context it needs to reason about what happened inside the database.

### PostgreSQL Logging Configuration

Without proper logging configuration, Dynatrace has nothing meaningful to investigate:

```bash
ALTER SYSTEM SET log_lock_waits = on;
ALTER SYSTEM SET deadlock_timeout = '1s';
ALTER SYSTEM SET log_min_duration_statement = 1000;
ALTER SYSTEM SET log_line_prefix = '%m [%p] user=%u db=%d app=%a ';
SELECT pg_reload_conf();
```

These parameters instruct PostgreSQL to log whenever a session waits more than one second for a lock, which is precisely the signal we need for the investigation scenario. This configuration is standard practice in production environments; it is not something specific to this lab.

### OneAgent and Deep Monitoring

The Dynatrace OneAgent was installed on the server and within five minutes the Smartscape view already showed the full topology: .NET API → PostgreSQL → Host.

Two additional settings made a meaningful difference to the quality of the investigation:

- **Deep monitoring enabled for .NET:** the OneAgent monitors the process but does not instrument requests in depth without it. PurePaths and SQL tracing require deep monitoring to be active, and these are what allow Dynatrace to see inside each individual request.
- **Davis AI (Davis CoPilot) enabled:** the agent works without it, but with Davis CoPilot active the quality of the investigation improves significantly. The agent reasons more fluently across the available data and translates natural language questions into optimised DQL queries automatically.

---

## The Baseline: Everything Green

With the API running and Dynatrace monitoring, I used Postman's Collection Runner to fire 200+ iterations across three endpoints to establish a performance baseline:

- **GET /products:** ~290ms
- **POST /orders:** ~300ms
- **GET /orders/{id}:** ~295ms

*[Screenshot: Collection Runner showing iterations with normal response times of ~290–300ms]*

In Dynatrace, the response time was stable with p50 sitting at **1.8ms** and p99 at **225ms** exactly the behaviour you would expect from a healthy API connecting to a local containerised database.

---

## The Incident: Injecting the Lock

With the Collection Runner still running, I executed the lock injection script from a second terminal:

```bash
bash ~/inject-lock.sh
```

The script runs a deliberate blocking transaction:

```sql
BEGIN;
LOCK TABLE orders IN ACCESS EXCLUSIVE MODE;
SELECT pg_sleep(10);
COMMIT;
```

The effect was immediate and unambiguous in Dynatrace:

*[Screenshot: DynatraceLabApi dashboard showing response time spiking to 30 seconds at 08:10, failure rate reaching 5%, and throughput collapsing from 80–90 req/min to near zero]*

- **P99 response time:** from ~225ms to **30 seconds**
- **Failure rate:** jumped to **5%**
- **Throughput:** fell from 90 req/min to almost nothing
- **HTTP errors:** appeared on the dashboard

The Postman tests were still passing, eventually, but with absurd latency. The classic developer's confusion: no explicit error, but clearly something had gone badly wrong.

---

## The Investigation: One Prompt in Plain English

This is where it gets interesting. Rather than opening dashboards, manually filtering logs, and cross-referencing metrics across multiple tools, I typed a single prompt into Postman's Agent Mode:

> *"Run fresh queries right now against Dynatrace to investigate the DynatraceLabApi spike that happened around 11:10 UTC today March 18."*

*[Screenshot: Agent Mode prompt field with the Dynatrace MCP server connected (@Dyna)]*

The agent worked for roughly three minutes, automatically executing multiple DQL queries across metrics, logs, and problems, then returned a complete analysis.

### What Agent Mode Found

**1. Spike confirmed**

The P99 jumped to **19.19 seconds** at 11:05 UTC, from a baseline of 1.5–4ms, a degradation of roughly **1,000×**.

**2. Root cause in the PostgreSQL logs**

| Time (UTC) | Event | Wait duration |
|---|---|---|
| 11:07:01 | Process 388 waiting for RowExclusiveLock on the orders table (held by process 390) | 1,000ms |
| 11:07:09 | Process 388 acquired the lock | **9,356ms total wait** |
| 11:07:33 | Cascading AccessShareLock on the same table | 1,000ms+ |

*[Screenshot: Agent Mode response showing the full analysis with impact table and root cause chain]*

**3. Impact quantified**

| Metric | Baseline | During spike | Impact |
|---|---|---|---|
| Response time | 1,500–4,000 µs | ~2,911,446 µs (~3s) | ~1,000× increase |
| Throughput | 80–90 req/min | 1–25 req/min | 75–90% drop |
| Failures | 0 | 1 at ~11:09 UTC | Minimal |
| DB lock wait | N/A | **9,356ms** | Root cause |

*[Screenshot: Agent Mode response with the detailed impact table]*

The agent's conclusion was precise: **process 390 held a RowExclusiveLock on the orders table long enough to block DynatraceLabApi's INSERT queries for 9.4 seconds, triggering a cascade of AccessShareLock contention that affected even read operations.**

---

## What Worked, and the Honest Limitations

### What worked well

**Genuine natural language.** Even knowing DQL, knowing exactly where to look in Dynatrace, and knowing the service entity ID by heart, the Agent Mode handled the investigative work entirely. Rather than navigating dashboards and writing queries manually, a single plain-English prompt did it all. The value is not in replacing expertise. It is in not having to spend it on mechanical correlation. What fascinates me most is that this capability is no longer confined to SRE teams. Any developer who can describe a problem in plain English now has access to the same depth of investigation that previously required years of observability experience.

**Automatic correlation.** The agent crossed response time data against PostgreSQL logs without being asked to, and identified the exact time window where the lock event occurred.

**Preserved context.** Within a single conversation, the agent maintained context across queries. It knew it was investigating the DynatraceLabApi service and that the problem involved the orders table.

### The honest limitations

**Davis CoPilot must be enabled.** Without it, the `create-dql` tool returns a 403 and the agent falls back to writing DQL manually. This still works, but it is slower and less fluent.

**Telemetry is the real prerequisite.** The agent reached the root cause because PostgreSQL was configured to log lock waits. Without `log_lock_waits = on`, those logs would not exist and the investigation would have stopped at the response time metric with no explanation.

**The Postman free plan has a limited number of AI messages.** The allocation is small, but generous given how computationally expensive each Agent Mode interaction is. For sustained use, Postman Pro is the more practical option.

**This is correlation, not comprehension.** The agent did not "understand" the problem. It executed queries, correlated timestamps, and presented the data coherently. The quality of the analysis is entirely dependent on the quality of the data available.

---

## Dynatrace vs Datadog: A Brief Note

Datadog also launched its MCP Server in March 2026, with integrations for Claude Code, Cursor, and Codex. The relevant distinction for API developers is that **the native integration with Postman Agent Mode was announced specifically by Dynatrace. Datadog does not yet have a first-party presence in the Postman API Network.

---

## Conclusion

Time from my first prompt to root cause identified: **approximately 3 minutes**.

The equivalent investigation done manually (opening Dynatrace, filtering by service, navigating to logs, writing a DQL query, cross-referencing with response time metrics, narrowing the time window, then filtering PostgreSQL logs specifically) would conservatively take **20 to 30 minutes**, and that assumes you already know where to look.

The Postman Agent Mode and Dynatrace MCP combination does not eliminate the need for well-configured telemetry. What it eliminates is the need to know where that telemetry lives and how to retrieve it. For teams that already live in Postman, that is a meaningful shift in how debugging actually feels.

The full lab, including the `setup-lab.sh` script and the API source code, is available on GitHub. The entire environment can be brought up in under an hour from a clean server.

---

## What's Next

In Part 2 of this series: **what happens when the problem isn't infrastructure, but a client abusing your API?** I'll show how Agent Mode identifies a partner generating hundreds of 404 errors and distinguishes between an integration bug, a retry loop, and a potential attack.

---

*Tags: Postman, Dynatrace, MCP, API Testing, .NET 10, DevOps, Observability, PostgreSQL*

---

## * Dynatrace MCP Server: Available Tools

| Tool |
|---|
| `create-dql` |
| `execute-dql` |
| `explain-dql` |
| `get-entity-id` |
| `get-entity-name` |
| `query-problems` |
| `get-problem-by-id` |
| `get-events-for-kubernetes-cluster` |
| `get-vulnerabilities` |
| `timeseries-forecast` |
| `timeseries-novelty-detection` |
| `ask-dynatrace-docs` |
| `find-documents` |
| `find-troubleshooting-guides` |
