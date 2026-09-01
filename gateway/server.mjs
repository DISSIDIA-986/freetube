import http from "node:http";
import { spawn } from "node:child_process";
import { existsSync, mkdirSync, statSync, createReadStream } from "node:fs";
import { join } from "node:path";
import { URL } from "node:url";

const port = Number(process.env.FREETUBE_GATEWAY_PORT ?? 8787);
const host = process.env.FREETUBE_GATEWAY_HOST ?? "0.0.0.0";
const cacheDir = join(process.cwd(), "gateway-cache");
mkdirSync(cacheDir, { recursive: true });
const jobs = new Map();

function videoPath(id) { return join(cacheDir, `${id}.mp4`); }

function download(id) {
  if (jobs.has(id)) return jobs.get(id);
  const output = videoPath(id);
  const args = [
    "--no-playlist", "--newline", "--no-warnings",
    // A TV client should start quickly; downloading a 1080p two-hour source before
    // playback can mean hundreds of MB. Keep the LAN gateway responsive at 480p.
    "-f", "bv*[height<=480][vcodec^=avc1]+ba[acodec^=mp4a]/b[height<=480][ext=mp4][vcodec^=avc1][acodec^=mp4a]",
    "--concurrent-fragments", "4",
    "--merge-output-format", "mp4",
    "-o", output,
    `https://www.youtube.com/watch?v=${id}`,
  ];
  const promise = new Promise((resolve, reject) => {
    console.log(`[gateway] downloading ${id}`);
    const child = spawn("yt-dlp", args, { stdio: ["ignore", "pipe", "pipe"] });
    child.stdout.on("data", data => process.stdout.write(`[yt-dlp] ${data}`));
    child.stderr.on("data", data => process.stderr.write(`[yt-dlp] ${data}`));
    child.on("error", reject);
    child.on("exit", code => code === 0 && existsSync(output)
      ? resolve(output)
      : reject(new Error(`yt-dlp exited with ${code}`)));
  }).finally(() => jobs.delete(id));
  jobs.set(id, promise);
  return promise;
}

function json(res, status, body) {
  const data = JSON.stringify(body);
  res.writeHead(status, { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(data) });
  res.end(data);
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
    if (url.pathname === "/resolve") {
      const id = url.searchParams.get("id");
      if (!id || !/^[A-Za-z0-9_-]{11}$/.test(id)) return json(res, 400, { error: "invalid video id" });
      const file = existsSync(videoPath(id)) ? videoPath(id) : await download(id);
      return json(res, 200, { url: `http://${req.headers.host}/media/${id}.mp4` , bytes: statSync(file).size });
    }
    const match = url.pathname.match(/^\/media\/([A-Za-z0-9_-]{11})\.mp4$/);
    if (match && existsSync(videoPath(match[1]))) return serveFile(req, res, videoPath(match[1]));
    json(res, 404, { error: "not found" });
  } catch (error) {
    console.error("[gateway]", error);
    json(res, 502, { error: String(error.message ?? error) });
  }
});

server.listen(port, host, () => console.log(`[gateway] listening on http://${host}:${port}`));
