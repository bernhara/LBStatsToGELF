# $Id: $

FROM almalinux:8

RUN dnf install -y \
       python39-pip jq nc && \
    dnf clean all

RUN pip3 install --no-cache-dir sysbus

WORKDIR /app

COPY sendLBMibStatsToGELFServer.sh /app

ENV LOOP_DELAY=5m
ENV GELF_SERVER_UDP_PORT=''
ENV GELF_SERVER_HOSTNAME=''

CMD /app/sendLBMibStatsToGELFServer.sh
