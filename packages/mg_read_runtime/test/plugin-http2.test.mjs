import assert from "node:assert/strict";
import http from "node:http";
import http2 from "node:http2";
import https from "node:https";
import net from "node:net";
import test from "node:test";

import { getGlobalDispatcher } from "undici";

import { ConfigurablePluginHttpClient } from "../dist/plugin-http-client.js";

const certificate = pem("CERTIFICATE", `MIICyDCCAbCgAwIBAgIIAc3qXRTthRcwDQYJKoZIhvcNAQELBQAwFDESMBAGA1UEAxMJbG9jYWxo
b3N0MB4XDTI2MDgyOTE1MTIyN1oXDTI3MDgzMDE1MTIyN1owFDESMBAGA1UEAxMJbG9jYWxob3N0
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA2eivRJ40W+VW4oO5qTqcQO8T2gIVZDBK
e5fqoDpBpxuuneb2bRe3VCnvSF7qHs5ff2JdFvNR4CvRoQXFJUCYLAusSzXYAQzYQBDuILQcP9NY
rOp/NzEF+DL+OGndjHm/p09xG9xfeEIbAhJLXQJX3klAFK7EUGP5Ehy4AG9bFU/JgU5OaDAOApZH
ifUYbL/VJgyDVN9kIv6WQn8FWfIdZhhPCn2xqjdv05cFYR2d6Lm3txJgup55U7EX4fHSw0qsvY9U
zlUj3cd0OafI7ya40VHt2gdCcXNHJSYklLFBetFXalTS9itWRrUfGy+e41WkuLhEKlqmujF19015
jpCa3QIDAQABox4wHDAaBgNVHREEEzARgglsb2NhbGhvc3SHBH8AAAEwDQYJKoZIhvcNAQELBQAD
ggEBAFjOTd+t+8wUsaRFgfojQwzA7I8PegsIa5J9ugB/QiTm2b/YsYGyB07CpJ1SfmBbjbEjFydC
kLBFABmHoMpdgDWeAD2bvrtVTbbc5P/08i0Yj+79jCQXVJs/PmlyAEnFVJoloRMsaUnITTFx6weh
SHJNGbaNzqTuGXPknNC4+FdoRFpB99gp0PIhNo3lDe9fsFw3uts82zlM/PqULhsxYVr/Zvk38foU
ydj3Gf0uRoDDAckqGgMMdi2OGA/EyHcTBRc6FzPqU/w9gHZyHQzw1tRbdAizZOmbWLCOIwWb98b5
W6rbLS/J0z3pCe8/DJsT3h6Ot5v/yDyjz11ORpCTMf4=`);

const privateKey = pem("PRIVATE KEY", `MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDZ6K9EnjRb5Vbig7mpOpxA7xPa
AhVkMEp7l+qgOkGnG66d5vZtF7dUKe9IXuoezl9/Yl0W81HgK9GhBcUlQJgsC6xLNdgBDNhAEO4g
tBw/01is6n83MQX4Mv44ad2Meb+nT3Eb3F94QhsCEktdAlfeSUAUrsRQY/kSHLgAb1sVT8mBTk5o
MA4ClkeJ9Rhsv9UmDINU32Qi/pZCfwVZ8h1mGE8KfbGqN2/TlwVhHZ3oube3EmC6nnlTsRfh8dLD
Sqy9j1TOVSPdx3Q5p8jvJrjRUe3aB0Jxc0clJiSUsUF60VdqVNL2K1ZGtR8bL57jVaS4uEQqWqa6
MXX3TXmOkJrdAgMBAAECggEAdpeHA44iKr0mywIrgeku7rvujuBBahRKBPeJrofmAR80qiTvijG1
CW4FFtrpCbkBCh+rT/k+XwUaAktUntCHwLjdnNUB6Jhn/H36Svwav7Wy9fBtKclZWVnPNz6OX4xG
/LRkd2g44QcBEeCI+WZ0EbrF0DvJBYNTI0NT9JCl/nM7btHYI1VPTsa7QCzqJfO35OriNgLCoHcO
RR9q/m6124WZz6YEvtXJz6SW0VBLCOsTT3MxQmpVYp1jXYldNsEEgMPRYggHtRoitUJ/p2DZ9oAr
7pwCSJ+3Ah3C4QjofKAvGs8smmBBc5Lh77pyLiKEjOP0FG81DxT9zn0EKMkL9QKBgQD4IicL/7Gj
quIZQSCx/c3BCeY6GrLScA7SHlQjXK5wKV9H6c9EgFGJhQOaTOT4bjLnnmbQ/wPCzZ/Y+l95uchB
RnEZEZsmLcKGrgd+wmv9xmBXn5siDz93iL/L9arxnX4Rwk3O7uAQ3FvafW4MPofiE9yvOireXpgQ
8GcZdjLKIwKBgQDg0TsIoptZud7JSIjC40PjitthdZFxwelAO1pjy6fUWlkkJP8KkxSdBYNfjXhU
c0T1KD+4uBygkW5UtdrkgnEItiuPl9Ly8vcGxYEIR2loNjrx6ksL0MWWtXrJqUEOW9wezCKq7iF2
o9S3qPjKPmPfdW6vV2sqb7Ii49bNfwDW/wKBgCNXCeSlmDFNR0J9iiCPm1xhAo9H+iwKlbHLbARV
UOrcmZtua3zAIdzKOwcg6IORfmKKpu4hQ/Hcw2Vt02dM1H6nf7goT8aSQeBYrOya2DKerF4Od1PU
hB+MNHTiGmSrH6d72wUb9IGyQMrPjnrj9Qp39bhnOm/NXS8cbjKsKPOtAoGBAMRb2xzysY9P+deC
o/jceRpP2Mcp4cwjGvBAJvXNFhwygXNBYQVCa5muDA20SaoxN8SM0AMtw8s22s/gOnyltcZvHmL/
r38FWV8vuECb5uPfoeJTyhJa2YmFnuZuD2VUNFEt6QW0kcPG2m9DhXFXxvGQ5wj86JwbDNLOf3ni
+L/PAoGAUGV2VUD656uo+Yn3lqx2EJ0g4euxGAvuB4iKSVHzV1wAUbaV6Qr5rId2HI8loCQtejnw
ppAHuqpn3YdjiScyKNjRrxJaEFC11K2WcuPBYYBcYCIYpujAlBC+lMDdF5RUv/vbVWk+jQa21+TK
1ySNrMYQC8RgBdSXSlHe3VLs3tw=`);

test("plugin HTTP negotiates h2 directly and through proxies with HTTP/1.1 fallback", async (t) => {
  const previousTlsSetting = process.env.NODE_TLS_REJECT_UNAUTHORIZED;
  process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0";
  const client = new ConfigurablePluginHttpClient();
  const protocols = [];
  const h2Server = http2.createSecureServer({ allowHTTP1: true, cert: certificate, key: privateKey }, (request, response) => {
    protocols.push(request.httpVersion);
    response.end("h2");
  });
  const h1Server = https.createServer({ cert: certificate, key: privateKey }, (request, response) => {
    protocols.push(request.httpVersion);
    response.end("h1");
  });
  let httpProxyTunnels = 0;
  const httpProxy = http.createServer();
  httpProxy.on("connect", (request, downstream, head) => {
    httpProxyTunnels += 1;
    const target = new URL(`http://${request.url}`);
    const upstream = net.connect(Number(target.port), target.hostname, () => {
      downstream.write("HTTP/1.1 200 Connection Established\r\n\r\n");
      if (head.length > 0) upstream.write(head);
      downstream.pipe(upstream);
      upstream.pipe(downstream);
    });
    upstream.on("error", () => downstream.destroy());
  });
  let socksProxyTunnels = 0;
  const socksProxy = createSocks5Proxy(() => socksProxyTunnels += 1);
  await Promise.all([listen(h2Server), listen(h1Server), listen(httpProxy), listen(socksProxy)]);
  t.after(async () => {
    await client.close();
    await getGlobalDispatcher().close();
    await Promise.all([close(h2Server), close(h1Server), close(httpProxy), close(socksProxy)]);
    if (previousTlsSetting === undefined) delete process.env.NODE_TLS_REJECT_UNAUTHORIZED;
    else process.env.NODE_TLS_REJECT_UNAUTHORIZED = previousTlsSetting;
  });

  assert.equal(await (await client.fetch(urlFor(h2Server), {})).text(), "h2");
  assert.equal(await (await client.fetch(urlFor(h1Server), {})).text(), "h1");
  client.configure(proxyUrlFor("http", httpProxy));
  assert.equal(await (await client.fetch(urlFor(h2Server), {})).text(), "h2");
  client.configure(proxyUrlFor("socks5", socksProxy));
  assert.equal(await (await client.fetch(urlFor(h2Server), {})).text(), "h2");

  assert.deepEqual(protocols, ["2.0", "1.1", "2.0", "2.0"]);
  assert.equal(httpProxyTunnels, 1);
  assert.equal(socksProxyTunnels, 1);
});

function listen(server) {
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      server.off("error", reject);
      resolve();
    });
  });
}

function close(server) {
  return new Promise((resolve, reject) => {
    server.close((error) => error === undefined ? resolve() : reject(error));
  });
}

function urlFor(server) {
  const address = server.address();
  assert.notEqual(address, null);
  assert.notEqual(typeof address, "string");
  return `https://127.0.0.1:${address.port}/`;
}

function proxyUrlFor(protocol, server) {
  const address = server.address();
  assert.notEqual(address, null);
  assert.notEqual(typeof address, "string");
  return `${protocol}://127.0.0.1:${address.port}/`;
}

function createSocks5Proxy(onTunnel) {
  return net.createServer((downstream) => {
    let buffered = Buffer.alloc(0);
    let greeted = false;
    const read = (chunk) => {
      buffered = Buffer.concat([buffered, chunk]);
      if (!greeted) {
        if (buffered.length < 2) return;
        const greetingLength = 2 + buffered[1];
        if (buffered.length < greetingLength) return;
        buffered = buffered.subarray(greetingLength);
        greeted = true;
        downstream.write(Buffer.from([5, 0]));
      }
      if (buffered.length < 5) return;
      const addressType = buffered[3];
      const addressLength = addressType === 1 ? 4 : addressType === 4 ? 16 : 1 + buffered[4];
      const addressOffset = addressType === 3 ? 5 : 4;
      const requestLength = addressOffset + (addressType === 3 ? buffered[4] : addressLength) + 2;
      if (buffered.length < requestLength) return;
      const addressBytes = buffered.subarray(addressOffset, requestLength - 2);
      const host = addressType === 1
        ? [...addressBytes].join(".")
        : addressType === 3
          ? addressBytes.toString("utf8")
          : "::1";
      const port = buffered.readUInt16BE(requestLength - 2);
      const trailing = buffered.subarray(requestLength);
      downstream.off("data", read);
      onTunnel();
      const upstream = net.connect(port, host, () => {
        downstream.write(Buffer.from([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]));
        if (trailing.length > 0) upstream.write(trailing);
        downstream.pipe(upstream);
        upstream.pipe(downstream);
      });
      upstream.on("error", () => downstream.destroy());
    };
    downstream.on("data", read);
  });
}

function pem(label, value) {
  return `-----BEGIN ${label}-----\n${value}\n-----END ${label}-----`;
}
