// dsh-mobile — Web 同源部署反代（零依赖，node 18+）
// 用途：Flutter Web 构建的浏览器安全模型（CORS/禁止 Cookie 头）要求「Web 端以同源
// 形态部署」。本工具把静态站点与云端 API 聚到一个 origin 下：
//   /        → build/web 静态文件
//   /reg/*   → https://dsh-api.example.com/*      （registry API；响应里的云端地址重写为本代理）
//   /host/*  → https://dsh.example.com/*          （host API/中继；SSE 流式透传；Location 重写）
//   wss      → 不代理：浏览器直连真实 broker（WebSocket 无 CORS 限制）
// App 侧配合：Web 用 withCredentials（浏览器托管 cookie），见 http_client_factory_web.dart。
//
// 用法：node tool/web_origin_proxy.mjs   （env: PORT/WEB_ROOT/UPSTREAM_REG/UPSTREAM_HOST）
import http from "node:http";
import https from "node:https";
import { createReadStream, existsSync, statSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const PORT = Number(process.env.PORT ?? 8123);
const WEB_ROOT = process.env.WEB_ROOT ?? path.join(path.dirname(path.dirname(fileURLToPath(import.meta.url))), "build", "web");
const UPSTREAM_REG = process.env.UPSTREAM_REG ?? "https://dsh-api.example.com";
const UPSTREAM_HOST = process.env.UPSTREAM_HOST ?? "https://dsh.example.com";
const SELF = `http://127.0.0.1:${PORT}`;
// 归因实验用：把 join 下发的 brokerUrl 改写为不可达地址（App 会进入初连退避重试，
// 不建立任何 wss 连接）——用于隔离「真实 MQTT wss 连接」对 Flutter Web 输入的影响。
const BROKER_OVERRIDE = process.env.BROKER_OVERRIDE ?? "";

const MIME = {
  ".html": "text/html; charset=utf-8", ".js": "text/javascript", ".mjs": "text/javascript",
  ".wasm": "application/wasm", ".json": "application/json", ".png": "image/png",
  ".svg": "image/svg+xml", ".ico": "image/x-icon", ".ttf": "font/ttf", ".css": "text/css",
};

function serveStatic(req, res, pathname) {
  let file = path.join(WEB_ROOT, pathname === "/" ? "index.html" : pathname);
  if (!file.startsWith(WEB_ROOT) || !existsSync(file) || statSync(file).isDirectory()) {
    file = path.join(WEB_ROOT, "index.html"); // Flutter Web 路由回退
  }
  // no-cache：Flutter 产物文件名固定（main.dart.js），浏览器启发式缓存会命中旧 JS
  //（实测用户明明配好了却跑旧逻辑、看不到新效果的元凶）
  res.writeHead(200, { "content-type": MIME[path.extname(file)] ?? "application/octet-stream", "cache-control": "no-cache" });
  createReadStream(file).pipe(res);
}

function proxy(req, res, prefix, upstreamBase) {
  const u = new URL(upstreamBase);
  const target = new URL(req.url.slice(prefix.length) || "/", u);
  const headers = { ...req.headers };
  delete headers.host; delete headers.connection; delete headers.origin; delete headers.referer;
  headers.host = u.host;
  headers["accept-encoding"] = "identity"; // 需要重写 JSON 体的响应禁止压缩
  const upMod = u.protocol === "http:" ? http : https;
  const upReq = upMod.request(
    { hostname: u.hostname, port: u.port || 443, path: target.pathname + target.search, method: req.method, headers },
    (upRes) => {
      const h = { ...upRes.headers };
      delete h["content-encoding"];
      // Location 重写（token 交换 303 → 浏览器跟随到代理路径）
      if (typeof h.location === "string") {
        h.location = h.location.startsWith("/")
          ? prefix + h.location
          : h.location.replace(upstreamBase, prefix);
      }
      const ctype = String(h["content-type"] ?? "");
      const isSse = ctype.includes("text/event-stream");
      const mayRewrite = prefix === "/reg" && ctype.includes("json");
      if (isSse || !mayRewrite) {
        res.writeHead(upRes.statusCode, h);
        upRes.pipe(res); // SSE 流式透传（不缓冲）
        return;
      }
      // registry JSON：把云端地址改写为本代理（publicUrl/tokenUrl/registryUrl 统一替换）
      const chunks = [];
      upRes.on("data", (c) => chunks.push(c));
      upRes.on("end", () => {
        let body = Buffer.concat(chunks).toString("utf8");
        body = body.split(UPSTREAM_HOST).join(`${SELF}/host`).split(UPSTREAM_REG).join(`${SELF}/reg`);
        if (BROKER_OVERRIDE) {
          body = body.replace(/"brokerUrl"\s*:\s*"[^"]*"/, `"brokerUrl":"${BROKER_OVERRIDE}"`);
        }
        delete h["content-length"];
        res.writeHead(upRes.statusCode, h);
        res.end(body);
      });
    },
  );
  upReq.on("error", (e) => {
    res.writeHead(502, { "content-type": "text/plain" });
    res.end(`proxy error: ${e.message}`);
  });
  req.pipe(upReq);
}

const server = http.createServer((req, res) => {
  const p = (req.url ?? "/").split("?")[0];
  // Service Worker：返回空 no-op 脚本（注册成功、零缓存行为）——
  // 直接 404 会让 Flutter loader 每次加载都打两条红色报错。
  if (p === "/flutter_service_worker.js" || p === "/service-worker.js") {
    res.writeHead(200, { "content-type": "application/javascript", "cache-control": "no-cache" });
    return res.end("// no-op: caching disabled by web_origin_proxy");
  }
  if (p === "/reg" || p.startsWith("/reg/")) return proxy(req, res, "/reg", UPSTREAM_REG);
  if (p === "/host" || p.startsWith("/host/")) return proxy(req, res, "/host", UPSTREAM_HOST);
  if (req.method === "GET" || req.method === "HEAD") return serveStatic(req, res, p);
  res.writeHead(404).end("not found");
});

// MQTT WSS 反代：浏览器 wss:// 走本机系统代理时会被代理层剪断（实测 ServerError
// 1006；代理对 CONNECT+Upgrade 支持不佳）。App 在 Web 端把 brokerUrl 配成
// ws://127.0.0.1:PORT/mqtt（明文 → 本机）后，这里以 node 直连云 EMQX（TLS），
// 数据面仍是真实云端（dsh-mqtt.example.com），仅浏览器侧换成同源入口。
const UPSTREAM_MQTT = process.env.UPSTREAM_MQTT ?? "wss://dsh-mqtt.example.com/mqtt";

server.on("upgrade", (req, clientSocket, head) => {
  const p = (req.url ?? "/").split("?")[0];
  if (p !== "/mqtt") {
    clientSocket.write("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n");
    clientSocket.end();
    return;
  }
  const u = new URL(UPSTREAM_MQTT);
  const headers = { ...req.headers, host: u.host, connection: "Upgrade", upgrade: "websocket" };
  delete headers.origin; // 上游 EMQX 无需 Origin（浏览器带的也无意义）
  // 上游路径取 wss URL 的 pathname（默认 /mqtt）
  const upReq = https.request(
    { hostname: u.hostname, port: u.port || 443, path: u.pathname + u.search, method: "GET", headers },
    (res) => {
      res.resume();
      clientSocket.write(`HTTP/1.1 ${res.statusCode} ${res.statusMessage ?? ""}\r\n\r\n`);
      clientSocket.end();
    },
  );
  upReq.on("upgrade", (upRes, upSocket, upHead) => {
    const lines = ["HTTP/1.1 101 Switching Protocols"];
    for (const [k, v] of Object.entries(upRes.headers)) lines.push(`${k}: ${v}`);
    clientSocket.write(lines.join("\r\n") + "\r\n\r\n");
    if (head && head.length) upSocket.write(head); // 客户端首包（MQTT CONNECT）
    if (upHead && upHead.length) clientSocket.write(upHead);
    upSocket.pipe(clientSocket);
    clientSocket.pipe(upSocket);
    upSocket.on("error", () => clientSocket.destroy());
    clientSocket.on("error", () => upSocket.destroy());
  });
  upReq.on("error", (e) => {
    clientSocket.write(`HTTP/1.1 502 Bad Gateway\r\nContent-Length: ${e.message.length}\r\n\r\n${e.message}`);
    clientSocket.end();
  });
  upReq.end();
});

server.listen(PORT, "127.0.0.1", () => {
  console.log(`[web-origin-proxy] http://127.0.0.1:${PORT}`);
  console.log(`  web:  ${WEB_ROOT}`);
  console.log(`  reg:  ${UPSTREAM_REG}  host: ${UPSTREAM_HOST}  mqtt: ${UPSTREAM_MQTT}`);
});
