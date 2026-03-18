# Dynatrace Lab Setup Script

> **LAB USE ONLY. This script is designed for a short-lived, throwaway environment. It will be running for a few hours and then completely destroyed. It contains deliberate shortcuts and anti-patterns that would never be acceptable in a production system. Please read the [Production Warning](#not-for-production) section before proceeding.**

---

## What is this?

This lab simulates a realistic backend workload: a .NET 10 API talking to a PostgreSQL 18 database, so you can explore Dynatrace observability features in a live, instrumented environment. The idea is to have something meaningful to look at in Dynatrace: real queries, real lock contention, real traces, and real metrics, without spending time building an app from scratch.

`setup-lab.sh` automates the entire infrastructure side of that. It provisions the database, seeds it with data, configures logging and the monitoring user, scaffolds and builds the API, and opens the right firewall ports. The whole thing is designed to be stood up in under 10 minutes on a fresh **Rocky Linux 10** VPS and destroyed completely at the end of the session.

**This script is not a Dynatrace tutorial.** It does not install or configure Dynatrace for you. Before the lab makes sense, you will need to have already set up:

- A **Dynatrace tenant** (SaaS trial or managed)
- **ActiveGate** installed and connected to your tenant
- **OneAgent** installed on the same VPS where you run this script
- **Postman** configured with the Dynatrace MCP integration for agent mode

Once those are in place, the script gives you a live target to monitor.

---

## What the Script Automatically Creates

### PostgreSQL 18 (via Podman container)

- Pulls and runs `docker.io/postgres:18` as a rootless Podman container named `postgres-lab`
- Creates a database called `orders_db`
- Seeds two tables (`products` with 1,000 rows and `orders`) with random data, ready to query
- Enables the `pg_stat_statements` extension for query-level observability
- Configures logging settings optimised for observability demos:
  - `log_lock_waits = on`
  - `deadlock_timeout = 1s`
  - `log_min_duration_statement = 1000ms`
  - Custom `log_line_prefix` with user, database, and application name
- Creates a dedicated **`dynatrace` monitoring user** with `pg_monitor` and read-only access to `public` schema
- Generates a `systemd` user unit (`container-postgres-lab.service`) so the container survives a reboot during the lab session

### .NET 10 Minimal API (`DynatraceLabApi`)

Scaffolded at `~/dynatrace-lab-api/DynatraceLabApi/` with the following endpoints:

| Method | Route | Description |
|--------|-------|-------------|
| `GET` | `/health` | Returns service status and UTC timestamp |
| `GET` | `/products` | Returns the first 50 products from the database |
| `POST` | `/orders` | Places an order (validates stock, inserts row) |
| `GET` | `/orders/{id}` | Retrieves a single order with product name |

Dependencies installed automatically: **Npgsql** + **Dapper**.

The application name is set to `DynatraceLabApi` in the connection string so queries are identifiable in Dynatrace's database monitoring views.

### inject-lock.sh

A helper script placed at `~/inject-lock.sh` that acquires an `ACCESS EXCLUSIVE` lock on the `orders` table for 10 seconds, useful for demonstrating lock contention detection in Dynatrace.

### Firewall Rules

- Port **5000/tcp** opened (API)
- Port **5432/tcp** explicitly blocked externally (PostgreSQL stays localhost-only)

---

## Prerequisites

- Rocky Linux 10 (the Microsoft `.NET` repository is configured for `rhel/10`)
- `sudo` privileges
- Internet access (to pull packages and the Postgres image)

---

## Usage

```bash
chmod +x setup-lab.sh
./setup-lab.sh
```

You will be prompted for:
1. A password for the PostgreSQL `postgres` superuser
2. A password for the `dynatrace` monitoring user

---

## Post-Setup Manual Steps

### 1. Start the API

```bash
DB_PASSWORD='your_password' dotnet run --project ~/dynatrace-lab-api/DynatraceLabApi
```

### 2. Test the endpoints

```bash
curl http://localhost:5000/health
curl http://localhost:5000/products
curl -X POST http://localhost:5000/orders \
  -H 'Content-Type: application/json' \
  -d '{"productId": 1, "quantity": 2}'
```

### 3. Install Dynatrace OneAgent

Sign up for a free trial at [dynatrace.com/signup](https://www.dynatrace.com/signup/) and follow the OneAgent installation instructions for your platform.

### 4. Configure the PostgreSQL Extension in Dynatrace

Navigate to **Extensions > PostgreSQL > Add configuration** and use:
- **Username:** `dynatrace`
- **Password:** the password you set during setup

### 5. Configure the MCP Integration (Postman / Agent Mode)

```
URL:  https://<TENANT>.apps.dynatrace.com/platform-reserved/mcp-gateway/v0.1/servers/dynatrace-mcp/mcp
Auth: Bearer Token (Personal Access Token with relevant scopes)
```

### 6. Trigger a Lock Contention Demo

```bash
bash ~/inject-lock.sh
```

---

## Not for Production

This script takes several deliberate shortcuts that are entirely acceptable for a lab that lives for a few hours, and entirely unacceptable anywhere else. These are called out explicitly so nobody accidentally copies patterns from here into a real environment.

| Shortcut | Why it's fine here | Why it's dangerous in prod |
|----------|-------------------|---------------------------|
| Database password passed via environment variable at the CLI | Convenient for a one-person lab | Visible in `ps aux`, shell history, and process listings |
| PostgreSQL `postgres` superuser used by the application | Simplest path for a demo | The app should connect as a least-privilege application user, never as a superuser |
| Connection string with credentials hardcoded in `Program.cs` | Fine for a throwaway app | Credentials must come from a secrets manager (Vault, AWS Secrets Manager, etc.) |
| No TLS on the API (`http://`) | Acceptable on localhost | All traffic must be encrypted in transit |
| No TLS on the PostgreSQL connection | Container is localhost-only | Require `sslmode=require` or `verify-full` in any networked environment |
| `ACCESS EXCLUSIVE` lock injected manually via `inject-lock.sh` | Intentional chaos for a demo | This pattern would take down any real workload that touches the table |
| Single-node, non-replicated PostgreSQL | Sufficient for demo data | Production databases require replication, backups, and failover |
| `set -euo pipefail` without full error recovery | Good enough for a scripted setup | A production provisioning system needs idempotency, rollback, and proper state management |
| Rootless Podman with a named volume (no backup strategy) | Ephemeral data, doesn't matter | All persistent data needs a backup and restore plan |

---

## Clean Up

When the lab session is over, just destroy the VPS.

---

## Licence

Do whatever you like with this. It's a lab script. Just don't run it in production.
