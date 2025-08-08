ARG ALPINE=3.20
FROM alpine:${ALPINE}

RUN apk add --no-cache bash curl jq openssl kubectl sed

# Aggiungi utente non-root
RUN addgroup -S approver && adduser -S approver -G approver -u 10001

# Copia lo script
COPY csr-approver.sh /usr/local/bin/csr-approver.sh
RUN chown approver:approver /usr/local/bin/csr-approver.sh && chmod 500 /usr/local/bin/csr-approver.sh

USER approver

ENTRYPOINT ["/usr/local/bin/csr-approver.sh"]
