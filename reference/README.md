# Reference content

The same nginx image runs in two places: the local server wired to the
router, and Azure App Service (the controlled cloud endpoint).

Two assets are not committed (size / licensing) and must be added before
building the image:

- `content/media/reference.mp4`: a CC BY 4.0 video. Record the source and
  attribution in `hardware/` or `design/`.
- `content/files/testfile.bin`: a fixed-size download file. Generate with:

  ```
  head -c 50M /dev/urandom > content/files/testfile.bin
  ```

Build and run locally:

```
docker build -t wifi-ref .
docker run -p 8080:80 wifi-ref
```
