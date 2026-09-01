import http from "node:http";
import { spawn } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { existsSync, mkdirSync, statSync, createReadStream, readFileSync, writeFileSync, chmodSync } from "node:fs";
import { join } from "node:path";
import { URL } from "node:url";

const port = Number(process.env.FREETUBE_GATEWAY_PORT ?? 8787);
const host = process.env.FREETUBE_GATEWAY_HOST ?? "0.0.0.0";
const cacheDir = join(process.cwd(), "gateway-cache");
mkdirSync(cacheDir, { recursive: true });
const jobs = new Map();
const pairings = new Map();
const oauthStates = new Map();
const auth = { accessToken: null, refreshToken: null, expiresAt: 0 };
const deviceTokens = new Set();
const googleClientID = process.env.FREETUBE_GOOGLE_CLIENT_ID ?? "";
const oauthRedirectURI = process.env.FREETUBE_GOOGLE_REDIRECT_URI ?? `http://127.0.0.1:${port}/oauth/callback`;
const ytdlpPlayerClient = process.env.FREETUBE_YTDLP_PLAYER_CLIENT ?? "tv";
const ytdlpPotProviderURL = process.env.FREETUBE_YTDLP_POT_PROVIDER_URL ?? "http://127.0.0.1:4416";
const ytdlpCookiesFile = process.env.FREETUBE_YTDLP_COOKIES_FILE ?? "";
const authFile = join(process.cwd(), ".gateway-auth.json");
const historyFile = join(process.cwd(), ".gateway-history.json");
try {
  if (existsSync(authFile)) {
    const saved = JSON.parse(readFileSync(authFile, "utf8"));
    auth.refreshToken = saved.refreshToken ?? null;
    for (const token of saved.deviceTokens ?? []) if (typeof token === "string") deviceTokens.add(token);
  }
} catch (error) { console.error("[gateway] unable to read auth state", error.message); }

function saveAuth() {
  if (!auth.refreshToken && deviceTokens.size === 0) return;
  writeFileSync(authFile, JSON.stringify({ refreshToken: auth.refreshToken, deviceTokens: [...deviceTokens] }), { mode: 0o600 });
  chmodSync(authFile, 0o600);
}

function readHistory() {
  try { return JSON.parse(readFileSync(historyFile, "utf8")); } catch { return []; }
}

async function requestBody(req) {
  let body = "";
  for await (const chunk of req) body += chunk;
  return JSON.parse(body || "{}");
}

function videoPath(id, quality) { return join(cacheDir, `${id}-${quality}.mp4`); }

function download(id, quality) {
  const jobKey = `${id}-${quality}`;
  if (jobs.has(jobKey)) return jobs.get(jobKey);
  const output = videoPath(id, quality);
  const maxHeight = Math.max(144, Math.min(2160, Number(quality) || 480));
  const args = [
    "--no-playlist", "--newline", "--no-warnings",
    "--retries", "3", "--fragment-retries", "3", "--socket-timeout", "20",
    "--extractor-args", `youtube:player_client=${ytdlpPlayerClient};youtubepot-bgutilhttp:base_url=${ytdlpPotProviderURL}`,
    "-f", `bv*[height<=${maxHeight}][vcodec^=avc1]+ba[acodec^=mp4a]/b[height<=${maxHeight}][ext=mp4][vcodec^=avc1][acodec^=mp4a]`,
    "--concurrent-fragments", "4",
    "--merge-output-format", "mp4",
    "-o", output,
    `https://www.youtube.com/watch?v=${id}`,
  ];
  if (ytdlpCookiesFile && existsSync(ytdlpCookiesFile)) args.splice(2, 0, "--cookies", ytdlpCookiesFile);
  const promise = new Promise((resolve, reject) => {
    console.log(`[gateway] downloading ${id} at <=${maxHeight}p`);
    const child = spawn("yt-dlp", args, { stdio: ["ignore", "pipe", "pipe"] });
    child.stdout.on("data", data => process.stdout.write(`[yt-dlp] ${data}`));
    child.stderr.on("data", data => process.stderr.write(`[yt-dlp] ${data}`));
    child.on("error", reject);
    child.on("exit", code => code === 0 && existsSync(output)
      ? resolve(output)
      : reject(new Error(`yt-dlp exited with ${code}`)));
  }).finally(() => jobs.delete(jobKey));
  jobs.set(jobKey, promise);
  return promise;
}

function json(res, status, body) {
  const data = JSON.stringify(body);
  res.writeHead(status, { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(data) });
  res.end(data);
}

function hasDeviceAccess(req) {
  if (deviceTokens.size === 0) return true;
  const header = req.headers.authorization ?? "";
  return header.startsWith("Bearer ") && deviceTokens.has(header.slice("Bearer ".length));
}

function requireDeviceAccess(req, res) {
  if (hasDeviceAccess(req)) return true;
  json(res, 401, { error: "FreeTube TV pairing required" });
  return false;
}

function pairingCode() {
  let code;
  do code = String(Math.floor(100000 + Math.random() * 900000));
  while (pairings.has(code));
  return code;
}

function prunePairings() {
  const now = Date.now();
  for (const [code, pairing] of pairings) {
    if (pairing.expiresAt < now) pairings.delete(code);
  }
}

function pairPage() {
  return `<!doctype html><meta name="viewport" content="width=device-width"><title>FreeTube TV pairing</title>
  <style>body{font:20px system-ui;max-width:560px;margin:48px auto;padding:0 24px;background:#111;color:#eee}input,button{font:inherit;padding:12px;margin-top:12px}input{width:10em}button{cursor:pointer}#status{margin-top:20px;color:#9f9}</style>
  <h1>Pair FreeTube TV</h1><p>On Apple TV, open Settings → Pair with Mac and enter the six-digit code below.</p>
  <form><input id="code" inputmode="numeric" pattern="[0-9]{6}" maxlength="6" placeholder="123456" required><button>Pair</button></form><div id="status"></div>
  <script>document.querySelector('form').onsubmit=async e=>{e.preventDefault();let code=document.querySelector('#code').value;let r=await fetch('/pair/confirm?code='+encodeURIComponent(code),{method:'POST'});let j=await r.json();document.querySelector('#status').textContent=r.ok?'Paired successfully. Return to Apple TV.':(j.error||'Pairing failed');}</script>`;
}

function html(res, status, body) {
  res.writeHead(status, { "Content-Type": "text/html; charset=utf-8", "Content-Length": Buffer.byteLength(body) });
  res.end(body);
}

function oauthPage(message) {
  return `<!doctype html><meta name="viewport" content="width=device-width"><title>FreeTube YouTube account</title><style>body{font:20px system-ui;max-width:640px;margin:48px auto;padding:0 24px;background:#111;color:#eee}</style><h1>FreeTube YouTube account</h1><p>${message}</p><p>You can close this page and return to Apple TV.</p>`;
}

function oauthStartURL() {
  const state = randomBytes(24).toString("base64url");
  const verifier = randomBytes(48).toString("base64url");
  const challenge = createHash("sha256").update(verifier).digest("base64url");
  oauthStates.set(state, { verifier, expiresAt: Date.now() + 10 * 60 * 1000 });
  const params = new URLSearchParams({ client_id: googleClientID, redirect_uri: oauthRedirectURI, response_type: "code", access_type: "offline", prompt: "consent", scope: "openid email profile https://www.googleapis.com/auth/youtube.readonly", state, code_challenge: challenge, code_challenge_method: "S256" });
  return `https://accounts.google.com/o/oauth2/v2/auth?${params}`;
}

async function exchangeOAuthCode(code, verifier) {
  const body = new URLSearchParams({ code, client_id: googleClientID, client_secret: process.env.FREETUBE_GOOGLE_CLIENT_SECRET ?? "", redirect_uri: oauthRedirectURI, grant_type: "authorization_code", code_verifier: verifier });
  const response = await fetch("https://oauth2.googleapis.com/token", { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body });
  const result = await response.json();
  if (!response.ok) throw new Error(result.error_description ?? result.error ?? "OAuth token exchange failed");
  auth.accessToken = result.access_token;
  auth.refreshToken = result.refresh_token ?? auth.refreshToken;
  auth.expiresAt = Date.now() + (result.expires_in ?? 3600) * 1000;
  saveAuth();
}

async function accessToken() {
  if (auth.accessToken && auth.expiresAt > Date.now() + 60_000) return auth.accessToken;
  if (!auth.refreshToken) return null;
  const body = new URLSearchParams({ client_id: googleClientID, client_secret: process.env.FREETUBE_GOOGLE_CLIENT_SECRET ?? "", refresh_token: auth.refreshToken, grant_type: "refresh_token" });
  const response = await fetch("https://oauth2.googleapis.com/token", { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body });
  const result = await response.json();
  if (!response.ok) { auth.accessToken = null; auth.refreshToken = null; throw new Error(result.error_description ?? "Google session expired"); }
  auth.accessToken = result.access_token;
  auth.expiresAt = Date.now() + (result.expires_in ?? 3600) * 1000;
  return auth.accessToken;
}

async function youtubeAPI(path) {
  const token = await accessToken();
  if (!token) return null;
  const response = await fetch(`https://www.googleapis.com/youtube/v3/${path}`, {
    headers: { Authorization: `Bearer ${token}` },
    signal: AbortSignal.timeout(15_000)
  });
  const result = await response.json();
  if (!response.ok) throw new Error(result.error?.message ?? "YouTube API request failed");
  return result;
}

function serveFile(req, res, file) {
  const size = statSync(file).size;
  const range = req.headers.range?.match(/bytes=(\d+)-(\d*)/);
  if (!range) {
    res.writeHead(200, { "Content-Type": "video/mp4", "Content-Length": size, "Accept-Ranges": "bytes" });
    createReadStream(file).pipe(res);
    return;
  }
  const start = Number(range[1]);
  const end = range[2] ? Number(range[2]) : size - 1;
  if (start >= size || end < start) return json(res, 416, { error: "invalid range" });
  const actualEnd = Math.min(end, size - 1);
  res.writeHead(206, {
    "Content-Type": "video/mp4", "Accept-Ranges": "bytes",
    "Content-Range": `bytes ${start}-${actualEnd}/${size}`,
    "Content-Length": actualEnd - start + 1,
  });
  createReadStream(file, { start, end: actualEnd }).pipe(res);
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://${req.headers.host ?? "localhost"}`);
    if (url.pathname === "/healthz") return json(res, 200, { status: "ok" });
    prunePairings();
    for (const [state, item] of oauthStates) if (item.expiresAt < Date.now()) oauthStates.delete(state);
    if (url.pathname === "/oauth/start" && req.method === "GET") {
      if (!googleClientID) return json(res, 503, { error: "FREETUBE_GOOGLE_CLIENT_ID is not configured" });
      res.writeHead(302, { Location: oauthStartURL() });
      return res.end();
    }
    if (url.pathname === "/oauth/callback" && req.method === "GET") {
      const state = url.searchParams.get("state");
      const item = state && oauthStates.get(state);
      if (!item || item.expiresAt < Date.now()) return html(res, 400, oauthPage("This Google sign-in link expired. Start again from the account page."));
      oauthStates.delete(state);
      try {
        await exchangeOAuthCode(url.searchParams.get("code"), item.verifier);
        return html(res, 200, oauthPage("Google account connected successfully."));
      } catch (error) { return html(res, 502, oauthPage(`Google sign-in failed: ${String(error.message ?? error)}`)); }
    }
    if (url.pathname === "/account" && req.method === "GET") {
      if (!requireDeviceAccess(req, res)) return;
      if (!googleClientID) return json(res, 200, { signedIn: false, configured: false });
      try {
        const channel = await youtubeAPI("channels?part=snippet&mine=true");
        const item = channel?.items?.[0];
        return json(res, 200, { signedIn: Boolean(item), configured: true, title: item?.snippet?.title ?? null, channelID: item?.id ?? null, thumbnailURL: item?.snippet?.thumbnails?.high?.url ?? item?.snippet?.thumbnails?.default?.url ?? null });
      } catch (error) { return json(res, 401, { signedIn: false, configured: true, error: String(error.message ?? error) }); }
    }
    if (url.pathname === "/subscriptions" && req.method === "GET") {
      if (!requireDeviceAccess(req, res)) return;
      try {
        const subscriptions = await youtubeAPI("subscriptions?part=snippet,contentDetails&mine=true&maxResults=50");
        if (!subscriptions) return json(res, 401, { error: "YouTube account is not connected" });
        const channelIDs = (subscriptions.items ?? []).map(item => item.snippet?.resourceId?.channelId).filter(Boolean);
        if (!channelIDs.length) return json(res, 200, { videos: [] });
        const channels = await youtubeAPI(`channels?part=contentDetails&id=${channelIDs.join(",")}&maxResults=50`);
        const playlistIDs = (channels?.items ?? []).map(item => item.contentDetails?.relatedPlaylists?.uploads).filter(Boolean);
        const pages = await Promise.all(playlistIDs.slice(0, 20).map(playlistID => youtubeAPI(`playlistItems?part=snippet,contentDetails&playlistId=${playlistID}&maxResults=5`)));
        const videos = pages.flatMap(page => (page?.items ?? []).map(item => ({ id: item.contentDetails?.videoId, title: item.snippet?.title ?? "", channel: item.snippet?.channelTitle ?? "", thumbnailURL: item.snippet?.thumbnails?.high?.url ?? item.snippet?.thumbnails?.default?.url ?? null }))).filter(item => item.id);
        return json(res, 200, { videos });
      } catch (error) { return json(res, 401, { error: String(error.message ?? error) }); }
    }
    if (url.pathname === "/playlists" && req.method === "GET") {
      if (!requireDeviceAccess(req, res)) return;
      try {
        const result = await youtubeAPI("playlists?part=snippet,contentDetails&mine=true&maxResults=50");
        if (!result) return json(res, 401, { error: "YouTube account is not connected" });
        return json(res, 200, { playlists: (result.items ?? []).map(item => ({ id: item.id, title: item.snippet?.title ?? "", count: item.contentDetails?.itemCount ?? 0, thumbnailURL: item.snippet?.thumbnails?.high?.url ?? item.snippet?.thumbnails?.default?.url ?? null })) });
      } catch (error) { return json(res, 401, { error: String(error.message ?? error) }); }
    }
    if (url.pathname === "/collection-videos" && req.method === "GET") {
      if (!requireDeviceAccess(req, res)) return;
      try {
        const id = url.searchParams.get("id");
        const kind = url.searchParams.get("kind");
        if (!id || !["channel", "playlist"].includes(kind)) return json(res, 400, { error: "invalid collection" });

        let playlistID = id;
        if (kind === "channel") {
          const channels = await youtubeAPI(`channels?part=contentDetails&id=${encodeURIComponent(id)}`);
          playlistID = channels?.items?.[0]?.contentDetails?.relatedPlaylists?.uploads;
          if (!playlistID) return json(res, 200, { videos: [] });
        }

        const videos = [];
        let pageToken = "";
        do {
          const query = new URLSearchParams({ part: "snippet,contentDetails", playlistId: playlistID, maxResults: "50" });
          if (pageToken) query.set("pageToken", pageToken);
          const page = await youtubeAPI(`playlistItems?${query}`);
          for (const item of page?.items ?? []) {
            const videoID = item.contentDetails?.videoId;
            if (!videoID || item.snippet?.title === "Deleted video" || item.snippet?.title === "Private video") continue;
            videos.push({
              id: videoID,
              title: item.snippet?.title ?? "",
              channel: item.snippet?.videoOwnerChannelTitle ?? item.snippet?.channelTitle ?? "YouTube",
              channelID: item.snippet?.videoOwnerChannelId ?? item.snippet?.channelId ?? null,
              thumbnailURL: item.snippet?.thumbnails?.high?.url ?? item.snippet?.thumbnails?.default?.url ?? null,
              publishedAt: item.snippet?.publishedAt ?? null
            });
          }
          pageToken = page?.nextPageToken ?? "";
        } while (pageToken && videos.length < 200);

        videos.sort((left, right) => {
          const leftTime = Date.parse(left.publishedAt ?? "");
          const rightTime = Date.parse(right.publishedAt ?? "");
          if (Number.isNaN(leftTime) && Number.isNaN(rightTime)) return 0;
          if (Number.isNaN(leftTime)) return 1;
          if (Number.isNaN(rightTime)) return -1;
          return rightTime - leftTime;
        });
        return json(res, 200, { videos });
      } catch (error) { return json(res, 401, { error: String(error.message ?? error) }); }
    }
    if (url.pathname === "/likes" && req.method === "GET") {
      if (!requireDeviceAccess(req, res)) return;
      try {
        const result = await youtubeAPI("videos?part=snippet,contentDetails&myRating=like&maxResults=50");
        if (!result) return json(res, 401, { error: "YouTube account is not connected" });
        return json(res, 200, { videos: (result.items ?? []).map(item => ({ id: item.id, title: item.snippet?.title ?? "", channel: item.snippet?.channelTitle ?? "", thumbnailURL: item.snippet?.thumbnails?.high?.url ?? item.snippet?.thumbnails?.default?.url ?? null })) });
      } catch (error) { return json(res, 401, { error: String(error.message ?? error) }); }
    }
    if (url.pathname === "/sync/history" && req.method === "GET") {
      if (!requireDeviceAccess(req, res)) return;
      return json(res, 200, { videos: readHistory() });
    }
    if (url.pathname === "/sync/history" && req.method === "POST") {
      if (!requireDeviceAccess(req, res)) return;
      try {
        const incoming = await requestBody(req);
        const merged = [...incoming.videos ?? [], ...readHistory()].filter((video, index, all) => video?.id && all.findIndex(item => item.id === video.id) === index).slice(0, 100);
        writeFileSync(historyFile, JSON.stringify(merged), { mode: 0o600 });
        chmodSync(historyFile, 0o600);
        return json(res, 200, { videos: merged });
      } catch (error) { return json(res, 400, { error: String(error.message ?? error) }); }
    }
    if (url.pathname === "/pair" && req.method === "GET") {
      const page = pairPage();
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8", "Content-Length": Buffer.byteLength(page) });
      return res.end(page);
    }
    if (url.pathname === "/pair/start" && req.method === "POST") {
      const code = pairingCode();
      const expiresAt = Date.now() + 5 * 60 * 1000;
      pairings.set(code, { expiresAt, status: "pending" });
      return json(res, 200, { code, expiresAt });
    }
    if (url.pathname === "/pair/status" && req.method === "GET") {
      const code = url.searchParams.get("code");
      const pairing = code && pairings.get(code);
      if (!pairing) return json(res, 404, { error: "pairing code expired or not found" });
      return json(res, 200, { status: pairing.status, expiresAt: pairing.expiresAt, token: pairing.token ?? null });
    }
    if (url.pathname === "/pair/confirm" && req.method === "POST") {
      const code = url.searchParams.get("code");
      const pairing = code && pairings.get(code);
      if (!pairing) return json(res, 404, { error: "pairing code expired or not found" });
      pairing.status = "paired";
      pairing.token = randomBytes(32).toString("base64url");
      deviceTokens.add(pairing.token);
      saveAuth();
      return json(res, 200, { status: pairing.status });
    }
    if (url.pathname === "/resolve") {
      const id = url.searchParams.get("id");
      const quality = [144, 240, 360, 480, 720, 1080, 1440, 2160].includes(Number(url.searchParams.get("quality"))) ? Number(url.searchParams.get("quality")) : 480;
      if (!id || !/^[A-Za-z0-9_-]{11}$/.test(id)) return json(res, 400, { error: "invalid video id" });
      const file = existsSync(videoPath(id, quality)) ? videoPath(id, quality) : await download(id, quality);
      return json(res, 200, { url: `http://${req.headers.host}/media/${id}-${quality}.mp4` , bytes: statSync(file).size, quality });
    }
    const match = url.pathname.match(/^\/media\/([A-Za-z0-9_-]{11})-(144|240|360|480|720|1080|1440|2160)\.mp4$/);
    if (match && existsSync(videoPath(match[1], match[2]))) return serveFile(req, res, videoPath(match[1], match[2]));
    json(res, 404, { error: "not found" });
  } catch (error) {
    console.error("[gateway]", error);
    json(res, 502, { error: String(error.message ?? error) });
  }
});

server.listen(port, host, () => console.log(`[gateway] listening on http://${host}:${port}`));
