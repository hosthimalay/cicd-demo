const request = require('supertest');
const app = require('./server');

describe('Health Endpoints', () => {
  test('GET /health returns 200 with status UP', async () => {
    const res = await request(app).get('/health');
    expect(res.statusCode).toBe(200);
    expect(res.body.status).toBe('UP');
    expect(res.body.timestamp).toBeDefined();
    expect(res.body.hostname).toBeDefined();
  });

  test('GET /ready returns 200 with ready true', async () => {
    const res = await request(app).get('/ready');
    expect(res.statusCode).toBe(200);
    expect(res.body.ready).toBe(true);
  });
});

describe('API Endpoints', () => {
  test('GET / returns welcome message', async () => {
    const res = await request(app).get('/');
    expect(res.statusCode).toBe(200);
    expect(res.body.message).toContain('Hello');
  });

  test('GET /api/info returns app information', async () => {
    const res = await request(app).get('/api/info');
    expect(res.statusCode).toBe(200);
    expect(res.body.app).toBe('cicd-demo');
    expect(res.body.node).toBeDefined();
  });

  test('GET /api/items returns array of items', async () => {
    const res = await request(app).get('/api/items');
    expect(res.statusCode).toBe(200);
    expect(Array.isArray(res.body.items)).toBe(true);
    expect(res.body.items.length).toBeGreaterThan(0);
  });
});
