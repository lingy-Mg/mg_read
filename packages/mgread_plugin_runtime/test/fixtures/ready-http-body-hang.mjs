import { createServer } from 'node:http';

const server = createServer((request, response) => {
  if (request.url !== '/health/ready') {
    response.writeHead(404);
    response.end();
    return;
  }

  // Headers are deliberately sent, but the body never reaches EOF. The Dart
  // supervisor must cancel the response stream and kill this child on timeout.
  response.writeHead(200, { 'content-type': 'application/json' });
  response.write('{"status":"ready"');
});

server.listen(0, '127.0.0.1', () => {
  const address = server.address();
  if (address === null || typeof address === 'string') {
    process.exit(72);
  }
  process.stdout.write(`${JSON.stringify({
    type: 'ready',
    bootId: 'test-http-body-hang',
    host: '127.0.0.1',
    port: address.port,
    nodeVersion: '26.10.0',
    protocolVersion: '1.2',
  })}\n`);
});
