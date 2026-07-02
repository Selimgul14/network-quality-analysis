# Reference content

The same nginx image runs in two places: the local server wired to the
router, and Azure App Service (the controlled cloud endpoint).

Both large assets are generated inside the Docker build (stage 1 of the
Dockerfile), so nothing big is committed and the image is reproducible:

- `media/reference.mp4`: 60 s synthetic test video generated with ffmpeg
  (`testsrc`, H.264 720p at ~2 Mbps, AAC tone). Self-generated, so no
  third-party licence applies.
- `files/testfile.bin`: fixed 25 MiB file from `/dev/urandom` (random bytes
  so on-path compression cannot skew throughput numbers).

`content/page/index.html` is the static reference page for the web workload.

Build and run locally:

```
docker build -t wifi-ref .
docker run -p 8080:80 wifi-ref
```

Check the three assets:

```
curl -sI localhost:8080/page/index.html
curl -sI localhost:8080/media/reference.mp4
curl -sI localhost:8080/files/testfile.bin   # Content-Length: 26214400
```
