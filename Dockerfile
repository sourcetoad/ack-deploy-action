FROM alpine:3.19.1

RUN apk add --no-cache bash kubectl kustomize

COPY deploy.sh /deploy.sh
