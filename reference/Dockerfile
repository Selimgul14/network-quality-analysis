# nginx image serving the reference content. Same image runs on the local
# server (wired to the router) and on Azure App Service (the cloud endpoint).
#
# Stage 1 generates the two large assets so nothing big lives in git and the
# image is fully reproducible from source:
#   media/reference.mp4  60 s synthetic test video (H.264, 720p, ~2 Mbps)
#   files/testfile.bin   fixed 25 MB download file

FROM alpine:3.20 AS assets
RUN apk add --no-cache ffmpeg

# Test-pattern video with a tick tone: testsrc gives changing frames so the
# encoder produces realistic bitrate; +faststart puts the moov atom first so
# playback can begin before the file finishes downloading.
RUN mkdir -p /assets/media /assets/files && \
    ffmpeg -f lavfi -i testsrc=duration=60:size=1280x720:rate=30 \
           -f lavfi -i sine=frequency=440:duration=60 \
           -c:v libx264 -preset medium -b:v 2M -maxrate 2M -bufsize 4M \
           -c:a aac -b:a 96k -movflags +faststart \
           /assets/media/reference.mp4 && \
    head -c 26214400 /dev/urandom > /assets/files/testfile.bin  # 25 MiB

FROM nginx:1.27-alpine

COPY content/ /usr/share/nginx/html/
COPY --from=assets /assets/ /usr/share/nginx/html/

# content/ holds:
#   page/index.html      static reference page (web workload)
#   media/reference.mp4  generated above (video workload)
#   files/testfile.bin   generated above (download workload)

EXPOSE 80
