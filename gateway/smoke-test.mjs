import assert from "node:assert/strict";

const base = process.env.FREETUBE_GATEWAY_URL ?? "http://127.0.0.1:8787";

const health = await fetch(`${base}/healthz`);
assert.equal(health.status, 200, "gateway health check failed");

const invalidResolve = await fetch(`${base}/resolve?id=invalid`);
assert.equal(invalidResolve.status, 400, "invalid video IDs must be rejected");

const missingMedia = await fetch(`${base}/media/AAAAAAAAAAA-480.mp4`);
assert.equal(missingMedia.status, 404, "missing media must return 404");

const videoID = process.env.FREETUBE_TEST_VIDEO_ID;
if (videoID) {
  assert.match(videoID, /^[A-Za-z0-9_-]{11}$/, "test video ID must be a YouTube ID");
  const resolved = await fetch(`${base}/resolve?id=${videoID}&quality=480`);
  assert.equal(resolved.status, 200, "gateway could not resolve the test video");
  const payload = await resolved.json();
  assert.equal(typeof payload.url, "string", "resolve response did not contain a media URL");
  const range = await fetch(payload.url, { headers: { Range: "bytes=0-1023" } });
  assert.equal(range.status, 206, "gateway media endpoint did not honor byte ranges");
  assert.equal((await range.arrayBuffer()).byteLength, 1024, "gateway returned an incorrect range size");
}

console.log("gateway smoke tests passed");
