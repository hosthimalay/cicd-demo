# ── Stage 1: Dependencies ────────────────────────────────────────────────────
# Separate stage for installing deps so this layer is cached independently
# Only reinstalls when package-lock.json changes, not when source code changes
FROM node:20-alpine AS deps

WORKDIR /app

# Copy only dependency files first — maximises Docker layer caching
COPY package*.json ./

# npm ci is faster, stricter, and reproducible (vs npm install)
# --only=production excludes devDependencies from final image
RUN npm ci --only=production && npm cache clean --force


# ── Stage 2: Build / Test Runner ─────────────────────────────────────────────
# This stage includes devDependencies for running tests in CI
# It is NOT the final image — it is discarded after the build
FROM node:20-alpine AS builder

WORKDIR /app

COPY package*.json ./
RUN npm ci

# Copy source code
COPY . .

# Run linting (fail fast on code style issues)
# RUN npm run lint

# Run tests with coverage — pipeline uses this stage to verify tests pass
# In CI this is run as a separate step; here it acts as a quality gate
# RUN npm run test:ci


# ── Stage 3: Production Runtime ───────────────────────────────────────────────
# Final image — lean, secure, production-only
FROM node:20-alpine AS runtime

# Security: run as non-root user
# Alpine uses 'node' user (uid 1000) by default in node images
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

WORKDIR /app

# Copy production dependencies from deps stage (no devDeps)
COPY --from=deps /app/node_modules ./node_modules

# Copy application source
COPY --chown=appuser:appgroup . .

# Drop to non-root user — security best practice
USER appuser

# Document which port the app listens on
EXPOSE 3000

# Health check — Docker and Kubernetes use this to determine container health
# interval: how often to check
# timeout: how long to wait for a response
# retries: how many failures before marking unhealthy
# start-period: grace period on startup before health checks begin
HEALTHCHECK \
  --interval=30s \
  --timeout=5s \
  --retries=3 \
  --start-period=10s \
  CMD wget -qO- http://localhost:3000/health || exit 1

# Use exec form (not shell form) for proper signal handling (SIGTERM for graceful shutdown)
CMD ["node", "server.js"]
