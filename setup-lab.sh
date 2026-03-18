#!/bin/bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()     { echo -e "${GREEN}[✓]${NC} $1"; }
info()    { echo -e "${BLUE}[→]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[✗]${NC} $1"; exit 1; }
section() { echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${BLUE}  $1${NC}"; echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

section "PostgreSQL Password"

while true; do
    read -rsp "Enter a password for the PostgreSQL postgres user: " DB_PASSWORD
    echo ""
    read -rsp "Confirm password: " DB_PASSWORD_CONFIRM
    echo ""
    if [ "$DB_PASSWORD" = "$DB_PASSWORD_CONFIRM" ]; then
        [ -n "$DB_PASSWORD" ] && break
        warn "Password cannot be empty. Please try again."
    else
        warn "Passwords do not match. Please try again."
    fi
done

read -rsp "Enter a password for the Dynatrace monitoring user: " DT_PASSWORD
echo ""
log "Passwords set."

section "Step 1 — Updating the system"

info "Fixing Rocky Linux 10 mirrorlist (known issue on fresh installs)..."
sudo sed -i 's/^mirrorlist=/#mirrorlist=/g' /etc/yum.repos.d/*.repo
sudo sed -i 's/^#baseurl=/baseurl=/g' /etc/yum.repos.d/*.repo
sudo dnf clean all > /dev/null
log "Mirrorlist fixed."

info "Running dnf update..."
sudo dnf update -y
sudo dnf install -y curl wget git tar unzip postgresql
log "System updated."

section "Step 2 — Checking Podman"

if command -v podman &>/dev/null; then
    log "Podman already installed: $(podman --version)"
else
    info "Installing Podman..."
    sudo dnf install -y podman
    log "Podman installed: $(podman --version)"
fi

section "Step 3 — Installing .NET 10 SDK"

if command -v dotnet &>/dev/null && dotnet --list-sdks | grep -q "^10\."; then
    log ".NET 10 already installed: $(dotnet --version)"
else
    info "Adding Microsoft repository..."
    sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
    sudo wget -q -O /etc/yum.repos.d/microsoft-prod.repo \
        https://packages.microsoft.com/config/rhel/9/prod.repo

    info "Installing dotnet-sdk-10.0..."
    sudo dnf install -y dotnet-sdk-10.0
    log ".NET installed: $(dotnet --version)"
fi

section "Step 4 — Starting PostgreSQL 18"

if podman ps -a --format "{{.Names}}" | grep -q "^postgres-lab$"; then
    warn "Container postgres-lab already exists. Skipping creation."
else
    info "Starting PostgreSQL 18 container..."
    podman run -d \
        --name postgres-lab \
        -e POSTGRES_PASSWORD="$DB_PASSWORD" \
        -e POSTGRES_DB=orders_db \
        -p 127.0.0.1:5432:5432 \
        -v postgres-lab-data:/var/lib/postgresql \
        docker.io/postgres:18

    info "Waiting for PostgreSQL to initialise..."
    sleep 5

    for i in {1..15}; do
        if PGPASSWORD="$DB_PASSWORD" podman exec postgres-lab pg_isready -U postgres &>/dev/null; then
            break
        fi
        sleep 2
    done
    log "PostgreSQL running."
fi

info "Configuring PostgreSQL logging..."
PGPASSWORD="$DB_PASSWORD" podman exec -i postgres-lab psql -U postgres -c "ALTER SYSTEM SET log_lock_waits = on;" > /dev/null
PGPASSWORD="$DB_PASSWORD" podman exec -i postgres-lab psql -U postgres -c "ALTER SYSTEM SET deadlock_timeout = '1s';" > /dev/null
PGPASSWORD="$DB_PASSWORD" podman exec -i postgres-lab psql -U postgres -c "ALTER SYSTEM SET log_min_duration_statement = 1000;" > /dev/null
PGPASSWORD="$DB_PASSWORD" podman exec -i postgres-lab psql -U postgres -c "ALTER SYSTEM SET log_line_prefix = '%m [%p] user=%u db=%d app=%a ';" > /dev/null
PGPASSWORD="$DB_PASSWORD" podman exec -i postgres-lab psql -U postgres -c "SELECT pg_reload_conf();" > /dev/null
log "Logging configured."

info "Creating Dynatrace monitoring user..."
PGPASSWORD="$DB_PASSWORD" podman exec -i postgres-lab psql -U postgres -c "
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'dynatrace') THEN
        CREATE USER dynatrace WITH PASSWORD '$DT_PASSWORD' INHERIT;
    END IF;
END
\$\$;
" > /dev/null
PGPASSWORD="$DB_PASSWORD" podman exec -i postgres-lab psql -U postgres -c "GRANT pg_monitor TO dynatrace;" > /dev/null
log "Dynatrace user created and pg_monitor granted."

info "Checking database seed..."
TABLE_EXISTS=$(PGPASSWORD="$DB_PASSWORD" podman exec -i postgres-lab psql -U postgres orders_db -tAc \
    "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name='products');") || TABLE_EXISTS="f"

if [ "$TABLE_EXISTS" = "t" ]; then
    warn "Tables already exist. Skipping seed."
else
    info "Creating tables and inserting seed data..."
    PGPASSWORD="$DB_PASSWORD" podman exec -i postgres-lab psql -U postgres orders_db << 'EOF'
CREATE TABLE products (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100),
    price DECIMAL(10,2),
    stock INT
);

CREATE TABLE orders (
    id SERIAL PRIMARY KEY,
    product_id INT REFERENCES products(id),
    quantity INT,
    total DECIMAL(10,2),
    created_at TIMESTAMP DEFAULT NOW()
);

INSERT INTO products (name, price, stock)
SELECT 'Product ' || i, (random() * 100 + 1)::DECIMAL(10,2), (random() * 1000)::INT
FROM generate_series(1, 1000) AS i;

CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
EOF

    info "Granting schema permissions to dynatrace user..."
    PGPASSWORD="$DB_PASSWORD" podman exec -i postgres-lab psql -U postgres orders_db << 'EOF'
CREATE SCHEMA IF NOT EXISTS dynatrace;
GRANT USAGE ON SCHEMA dynatrace TO dynatrace;
GRANT USAGE ON SCHEMA public TO dynatrace;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO dynatrace;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO dynatrace;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA dynatrace TO dynatrace;
EOF
    log "Tables created, seed data inserted, and dynatrace permissions configured."
fi

info "Configuring PostgreSQL auto-start..."
mkdir -p ~/.config/systemd/user/

cd "$HOME"
podman generate systemd --name postgres-lab --files 2>/dev/null || true

if [ -f "$HOME/container-postgres-lab.service" ]; then
    mv "$HOME/container-postgres-lab.service" ~/.config/systemd/user/
    systemctl --user daemon-reload
    systemctl --user enable container-postgres-lab.service 2>/dev/null || true
    loginctl enable-linger "$USER" 2>/dev/null || true
    log "Auto-start configured."
else
    warn "Could not generate systemd unit file. Container will not survive a reboot automatically."
fi

section "Step 5 — Creating .NET 10 API"

API_DIR="$HOME/dynatrace-lab-api/DynatraceLabApi"

if [ -d "$API_DIR" ]; then
    warn "Directory $API_DIR already exists. Skipping project creation."
else
    info "Creating .NET project..."
    mkdir -p "$HOME/dynatrace-lab-api"
    cd "$HOME/dynatrace-lab-api"
    dotnet new web -n DynatraceLabApi --force > /dev/null
    cd DynatraceLabApi

    info "Installing Npgsql and Dapper packages..."
    dotnet add package Npgsql > /dev/null
    dotnet add package Dapper > /dev/null
    log "Project created with dependencies installed."
fi

info "Writing Program.cs..."
cat > "$API_DIR/Program.cs" << 'CSEOF'
using Npgsql;
using Dapper;

var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();
var dbPassword = Environment.GetEnvironmentVariable("DB_PASSWORD")
    ?? throw new InvalidOperationException("DB_PASSWORD environment variable is not set.");
var connStr = $"Host=localhost;Database=orders_db;Username=postgres;Password={dbPassword};Application Name=DynatraceLabApi";

app.MapGet("/health", () => Results.Ok(new { status = "ok", timestamp = DateTime.UtcNow }));

app.MapGet("/products", async () =>
{
    using var conn = new NpgsqlConnection(connStr);
    var products = await conn.QueryAsync("SELECT * FROM products LIMIT 50");
    return Results.Ok(products);
});

app.MapPost("/orders", async (OrderRequest req) =>
{
    using var conn = new NpgsqlConnection(connStr);
    var order = await conn.QuerySingleOrDefaultAsync(
        @"INSERT INTO orders (product_id, quantity, total)
          SELECT @ProductId, @Quantity, p.price * @Quantity
          FROM products p WHERE p.id = @ProductId AND p.stock >= @Quantity
          RETURNING *",
        req);
    return order is not null
        ? Results.Created($"/orders/{order.id}", order)
        : Results.BadRequest(new { error = "Product not found or insufficient stock" });
});

app.MapGet("/orders/{id}", async (int id) =>
{
    using var conn = new NpgsqlConnection(connStr);
    var order = await conn.QuerySingleOrDefaultAsync(
        "SELECT o.*, p.name as product_name FROM orders o JOIN products p ON o.product_id = p.id WHERE o.id = @Id",
        new { Id = id });
    return order is not null ? Results.Ok(order) : Results.NotFound();
});

app.Run("http://0.0.0.0:5000");

record OrderRequest(int ProductId, int Quantity);
CSEOF
log "Program.cs written."

info "Building the API..."
cd "$API_DIR"
dotnet build -c Release > /dev/null
log "Build successful."

info "Creating systemd service for the API..."
sudo tee /etc/systemd/system/dynatrace-lab-api.service > /dev/null << EOF
[Unit]
Description=DynatraceLabApi
After=network.target container-postgres-lab.service
Wants=container-postgres-lab.service

[Service]
Type=simple
User=$USER
WorkingDirectory=$API_DIR
ExecStart=$(which dotnet) run --project $API_DIR --configuration Release
Environment=DB_PASSWORD=$DB_PASSWORD
Environment=ASPNETCORE_URLS=http://0.0.0.0:5000
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now dynatrace-lab-api.service
log "API service created and started."

section "Step 6 — Configuring Firewall"

if ! command -v firewall-cmd &>/dev/null; then
    info "firewalld not found. Installing..."
    sudo dnf install -y firewalld
    sudo systemctl enable --now firewalld
    log "firewalld installed and started."
fi

info "Opening port 5000/tcp..."
sudo firewall-cmd --permanent --add-port=5000/tcp
sudo firewall-cmd --reload
log "Port 5000/tcp opened."

if sudo firewall-cmd --list-ports | grep -q "5432/tcp"; then
    warn "Port 5432 was open in the firewall — removing..."
    sudo firewall-cmd --permanent --remove-port=5432/tcp
    sudo firewall-cmd --reload
fi
log "Port 5432 blocked externally."

section "Bonus — Creating inject-lock.sh"

cat > "$HOME/inject-lock.sh" << 'EOF'
#!/bin/bash
echo "[→] Injecting lock on orders table for 10 seconds..."
podman exec -i postgres-lab psql -U postgres orders_db << 'EOSQL'
BEGIN;
LOCK TABLE orders IN ACCESS EXCLUSIVE MODE;
SELECT pg_sleep(10);
COMMIT;
EOSQL
echo "[✓] Lock released."
EOF
chmod +x "$HOME/inject-lock.sh"
log "inject-lock.sh created at ~/inject-lock.sh"

section "Setup complete!"

echo ""
echo -e "  ${GREEN}Next manual steps:${NC}"
echo ""
echo -e "  1. Verify the API is running:"
echo -e "     ${YELLOW}sudo systemctl status dynatrace-lab-api.service${NC}"
echo -e "     ${YELLOW}curl http://localhost:5000/health${NC}"
echo -e "     ${YELLOW}curl http://localhost:5000/products${NC}"
echo -e "     ${YELLOW}curl -X POST http://localhost:5000/orders -H 'Content-Type: application/json' -d '{\"productId\": 1, \"quantity\": 2}'${NC}"
echo -e "     ${YELLOW}curl http://localhost:5000/orders/1${NC}"
echo ""
echo -e "  3. Create a Dynatrace trial and install OneAgent:"
echo -e "     ${YELLOW}https://www.dynatrace.com/signup/${NC}"
echo -e "     ${YELLOW}Hub > OneAgent > Linux > copy and run the install command${NC}"
echo ""
echo -e "  4. Install the Dynatrace ActiveGate:"
echo -e "     ${YELLOW}Hub > ActiveGate > Install ActiveGate > Linux > copy and run the install command${NC}"
echo -e "     ${YELLOW}Required for the PostgreSQL extension to monitor the database from within${NC}"
echo ""
echo -e "  5. Configure PostgreSQL extension in Dynatrace:"
echo -e "     ${YELLOW}Extensions > PostgreSQL > Add configuration${NC}"
echo -e "     ${YELLOW}Username: dynatrace | Password: the DT password you set above${NC}"
echo -e "     ${YELLOW}Run the db-setup-PostgreSQL-self-hosted.sh script provided by Dynatrace${NC}"
echo ""
echo -e "  6. Enable .NET deep monitoring and Davis AI (Davis CoPilot) in Dynatrace:"
echo -e "     ${YELLOW}Infrastructure > Hosts > your host > Processes > DynatraceLabApi > Enable deep monitoring${NC}"
echo -e "     ${YELLOW}Settings > Dynatrace Intelligence > Davis AI > Enable Davis CoPilot${NC}"
echo ""
echo -e "  7. Create a Postman account and configure Agent Mode with Dynatrace MCP:"
echo -e "     ${YELLOW}https://www.postman.com/sign-up${NC}"
echo -e "     ${YELLOW}Create a new MCP Request (HTTP) with the Dynatrace MCP server URL:${NC}"
echo -e "     ${YELLOW}https://<TENANT>.apps.dynatrace.com/platform-reserved/mcp-gateway/v0.1/servers/dynatrace-mcp/mcp${NC}"
echo -e "     ${YELLOW}Auth: Bearer Token — generate a Personal Access Token in Dynatrace with all scopes${NC}"
echo ""
echo -e "  8. Lock demo:"
echo -e "     ${YELLOW}bash ~/inject-lock.sh${NC}"
echo ""
