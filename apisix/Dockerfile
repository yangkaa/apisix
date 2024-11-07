FROM --platform=linux/amd64 registry.cn-hangzhou.aliyuncs.com/goodrain/apisix:3.9.1-debian
USER root
RUN apt update && apt install -y curl procps net-tools vim
COPY init.lua /usr/local/apisix/apisix/init.lua

# docker build . -t registry.cn-hangzhou.aliyuncs.com/goodrain/apisix:3.9.1-debian-debug && docker push registry.cn-hangzhou.aliyuncs.com/goodrain/apisix:3.9.1-debian-debug
