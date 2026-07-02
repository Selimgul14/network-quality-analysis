# nginx image serving the reference content. Same image runs on the local
# server (wired to the router) and on Azure App Service (the cloud endpoint).
FROM nginx:1.27-alpine

COPY content/ /usr/share/nginx/html/

# content/ holds:
#   page/index.html      static reference page (web workload)
#   media/reference.mp4  CC BY 4.0 video (video workload)   [not committed, see README]
#   files/testfile.bin   fixed-size download file           [generated, see README]

EXPOSE 80
