FROM mcr.microsoft.com/mssql/server:2022-latest

USER root

# Bake in the custom CA / server certificate used by tests/custom-cert.rs.
COPY certs/server.crt certs/server.pem certs/server-full.crt certs/customCA.crt /certs/
COPY certs/server.key /certs/server.key
COPY docker-mssql.conf /var/opt/mssql/mssql.conf

# The /certs directory must be traversable (x bit) and the private key must be
# owned by and readable only by the mssql user, otherwise SQL Server refuses the
# certificate configuration at startup (error 49940 / 49939).
RUN chmod 755 /certs \
 && chmod 444 /certs/server.crt /certs/server.pem /certs/server-full.crt /certs/customCA.crt \
 && chown mssql /certs/server.key \
 && chmod 400 /certs/server.key \
 && chown mssql /var/opt/mssql/mssql.conf

USER mssql
