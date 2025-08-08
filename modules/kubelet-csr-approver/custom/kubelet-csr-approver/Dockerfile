ARG ALPINE=3.20
FROM alpine:${ALPINE}

RUN apk add --no-cache bash curl jq openssl kubectl sed

# Aggiungi utente non-root
RUN addgroup -S csrgroup && adduser -S csruser -G csrgroup -u 10001

# Copia lo script
COPY csr-approver.sh /usr/local/bin/csr-approver.sh
RUN chown csruser:csrgroup /usr/local/bin/csr-approver.sh && chmod 500 /usr/local/bin/csr-approver.sh

USER csruser

ENTRYPOINT ["/usr/local/bin/csr-approver.sh"]
