# Grafana with the datasource + dashboard provisioning baked in, so the
# same image runs identically on App Service (compose mounts the files
# instead). DB_HOST / DB_PASSWORD / DB_SSLMODE come from app settings.
FROM grafana/grafana:11.1.0

COPY datasources/ /etc/grafana/provisioning/datasources/
COPY dashboards/  /etc/grafana/provisioning/dashboards/

EXPOSE 3000
