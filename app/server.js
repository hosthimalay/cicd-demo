const express = require('express');
const os = require('os');
const app = express();

app.use(express.json());

// ── Health check endpoint (used by Kubernetes liveness + readiness probes) ──
app.get('/health', (req, res) => {
  res.status(200).json({
    status: 'UP',
    timestamp: new Date().toISOString(),
    hostname: os.hostname(),
    version: process.env.APP_VERSION || 'unknown',
    environment: process.env.NODE_ENV || 'development'
  });
});

// ── Readiness probe — more thorough than liveness ────────────────────────────
app.get('/ready', (req, res) => {
  // In a real app this would check DB connectivity, cache, etc.
  res.status(200).json({ ready: true });
});

// ── Main API routes ──────────────────────────────────────────────────────────
app.get('/', (req, res) => {
  res.json({
    message: 'Hello from Node.js CI/CD Demo App',
    version: process.env.APP_VERSION || 'unknown',
    hostname: os.hostname(),
    environment: process.env.NODE_ENV || 'development'
  });
});

app.get('/api/info', (req, res) => {
  res.json({
    app: 'cicd-demo',
    version: process.env.APP_VERSION || 'unknown',
    node: process.version,
    platform: os.platform(),
    hostname: os.hostname(),
    uptime: process.uptime()
  });
});

app.get('/api/items', (req, res) => {
  res.json({
    items: [
      { id: 1, name: 'Item One', status: 'active' },
      { id: 2, name: 'Item Two', status: 'active' },
      { id: 3, name: 'Item Three', status: 'inactive' }
    ]
  });
});

// ── Graceful shutdown (required for zero-downtime rolling updates) ───────────
process.on('SIGTERM', () => {
  console.log('SIGTERM received — shutting down gracefully');
  server.close(() => {
    console.log('Server closed');
    process.exit(0);
  });
});

const PORT = process.env.PORT || 3000;
const server = app.listen(PORT, () => {
  console.log(`Server running on port ${PORT}`);
  console.log(`Version: ${process.env.APP_VERSION || 'unknown'}`);
  console.log(`Environment: ${process.env.NODE_ENV || 'development'}`);
});

module.exports = app;
// first pipeline trigger
// pipeline trigger
