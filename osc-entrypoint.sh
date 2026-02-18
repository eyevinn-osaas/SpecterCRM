#!/bin/sh
set -e

# Set default values
export NGINX_PORT=${PORT:-8080}
export NODE_ENV=${NODE_ENV:-production}
# Backend runs on port 3000 (fixed, not configurable)
export PORT=3000

# Set JWT secrets with fallback and warnings
if [ -z "$JWT_SECRET" ]; then
  export JWT_SECRET="default-jwt-secret-change-this-in-production-not-secure-for-real-use"
  echo "WARNING: Using default JWT_SECRET - NOT SECURE for production!"
  echo "WARNING: Set JWT_SECRET environment variable with: openssl rand -hex 32"
fi

if [ -z "$REFRESH_TOKEN_SECRET" ]; then
  export REFRESH_TOKEN_SECRET="default-refresh-secret-change-this-in-production-not-secure-for-real-use"
  echo "WARNING: Using default REFRESH_TOKEN_SECRET - NOT SECURE for production!"
  echo "WARNING: Set REFRESH_TOKEN_SECRET environment variable with: openssl rand -hex 32"
fi

# Set JWT defaults
export JWT_EXPIRES_IN=${JWT_EXPIRES_IN:-8h}
export REFRESH_TOKEN_EXPIRES_IN=${REFRESH_TOKEN_EXPIRES_IN:-7d}

# Accept any hostname so CNAME custom domains work at the nginx level
export SERVER_NAME="_"

# Set CORS origin based on OSC_HOSTNAME and any pre-configured CORS_ORIGIN
if [ -n "$OSC_HOSTNAME" ]; then
    if [ -n "$CORS_ORIGIN" ]; then
        # If CORS_ORIGIN is already set (e.g. custom domain), append OSC hostname
        export CORS_ORIGIN="$CORS_ORIGIN,https://$OSC_HOSTNAME"
    else
        export CORS_ORIGIN="https://$OSC_HOSTNAME"
    fi
else
    export CORS_ORIGIN="${CORS_ORIGIN:-http://localhost:$NGINX_PORT}"
fi

echo "Starting SpecterCRM OSC container..."
echo "NGINX_PORT: $NGINX_PORT"
echo "BACKEND_PORT: $PORT"
echo "SERVER_NAME: $SERVER_NAME"
echo "CORS_ORIGIN: $CORS_ORIGIN"
echo "NODE_ENV: $NODE_ENV"

# Generate nginx configuration from template
envsubst '${NGINX_PORT} ${SERVER_NAME}' < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf

echo "Generated nginx configuration:"
cat /etc/nginx/nginx.conf

# Ensure nginx directories exist and have correct permissions
mkdir -p /var/log/nginx /var/lib/nginx/tmp /run/nginx
chown -R node:node /var/log/nginx /var/lib/nginx /run/nginx

# Database setup
echo "Setting up database schema..."
cd /app/backend

# Push database schema (creates tables if they don't exist)
echo "Creating database tables..."
npx prisma db push --accept-data-loss

# Check if database is empty and seed if needed
echo "Checking if database needs seeding..."

# Create a simple Node.js script to check tenant count
cat > check_tenants.js << 'EOF'
const { PrismaClient } = require('@prisma/client');
const prisma = new PrismaClient();

async function checkTenants() {
  try {
    const count = await prisma.tenant.count();
    console.log(count);
    process.exit(0);
  } catch (error) {
    console.log("0");
    process.exit(0);
  } finally {
    await prisma.$disconnect();
  }
}

checkTenants();
EOF

TENANT_COUNT=$(node check_tenants.js)
rm check_tenants.js

if [ "$TENANT_COUNT" = "0" ]; then
  echo "Database is empty, running initial seed..."
  npm run db:seed || echo "Warning: Database seeding failed, continuing..."
else
  echo "Database already has data (${TENANT_COUNT} tenants), skipping seed"
fi

# Allow manual seeding override
if [ "$FORCE_SEED" = "true" ]; then
  echo "Force seeding enabled..."
  npm run db:seed || echo "Warning: Database seeding failed, continuing..."
fi


# Test nginx configuration
echo "Testing nginx configuration..."
nginx -t

# Start nginx in the background
echo "Starting nginx..."
nginx

# Start the backend API server
echo "Starting backend server..."
cd /app/backend
exec npx tsx src/index.ts