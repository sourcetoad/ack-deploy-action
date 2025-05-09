FROM alpine:3.21.3

RUN apk add --no-cache bash kubectl kustomize

COPY deploy.sh /deploy.sh
