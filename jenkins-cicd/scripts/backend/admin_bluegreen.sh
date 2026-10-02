#!/usr/bin/env bash

###############################################################################
# Admin Blue-Green Deployment
###############################################################################

set -Eeuo pipefail
IFS=$'\n\t'

###############################################################################
# Configuration
###############################################################################

ADMIN_PROJECT_NAME="211_admin"

ADMIN_PRIMARY_SERVICE="admin"
ADMIN_BACKUP_SERVICE="adminbackup"

ADMIN_PRIMARY_JAR="/opt/backend/Admin/admin.jar"
ADMIN_BACKUP_JAR="/opt/backend/Admin_backup/admin.jar"

ADMIN_PRIMARY_PORT="8082"
ADMIN_BACKUP_PORT="8084"

ADMIN_NGINX_UPSTREAM="/etc/nginx/upstreams/admin_backend.conf"
ADMIN_NGINX_BACKUP="${ADMIN_NGINX_UPSTREAM}.deployment-backup"

ADMIN_UPLOAD_DIR="/home/logs/backend/admin/incoming"

ADMIN_DEPLOY_USER="pmrbackendsecurity"
ADMIN_DEPLOY_GROUP="pmrbackendsecurity"

###############################################################################
# Cleanup incoming files
###############################################################################

admin_blue_green_cleanup_incoming()
{
    info "Cleaning Admin incoming deployment files..."

    if [[ -n "${UPLOADED_JAR:-}" && -f "${UPLOADED_JAR}" ]]; then
        sudo rm -f "${UPLOADED_JAR}" || true
    fi

    if [[ -n "${UPLOADED_DEPLOY:-}" && -f "${UPLOADED_DEPLOY}" ]]; then
        sudo rm -f "${UPLOADED_DEPLOY}" || true
    fi

    sudo find "${ADMIN_UPLOAD_DIR}" -maxdepth 1 -type f \
        \( -name "*.jar" -o -name "*.deploy" -o -name "*.zip" \) \
        -delete || true

    info "Admin incoming cleanup completed."
}

###############################################################################
# Service helpers
###############################################################################

admin_blue_green_service_is_running()
{
    local service="$1"

    sudo systemctl is-active --quiet "${service}.service"
}

admin_blue_green_start_service()
{
    local service="$1"

    info "Starting ${service}.service..."

    sudo systemctl start "${service}.service"

    info "${service}.service start command completed."
}

admin_blue_green_stop_service()
{
    local service="$1"

    info "Stopping ${service}.service..."

    sudo systemctl stop "${service}.service" || true

    info "${service}.service stopped."
}

###############################################################################
# Verify service
###############################################################################

admin_blue_green_verify_service()
{
    local service="$1"

    info "Verifying ${service}.service..."

    local attempts=30

    for ((i=1; i<=attempts; i++))
    do
        if admin_blue_green_service_is_running "${service}"; then
            info "${service}.service is active."
            return 0
        fi

        sleep 1
    done

    error "${service}.service failed to become active."

    sudo systemctl status "${service}.service" --no-pager || true

    return 1
}

###############################################################################
# Verify port
###############################################################################

admin_blue_green_verify_port()
{
    local port="$1"

    info "Checking Admin port ${port}..."

    local attempts=30

    for ((i=1; i<=attempts; i++))
    do
        if sudo ss -lntp | grep -q ":${port}"; then
            info "Admin port ${port} is listening."
            return 0
        fi

        sleep 1
    done

    error "Admin port ${port} is not listening."

    sudo ss -lntp | grep -E ":${ADMIN_PRIMARY_PORT}|:${ADMIN_BACKUP_PORT}" || true

    return 1
}

###############################################################################
# Journal verification
###############################################################################

admin_blue_green_check_journal()
{
    local service="$1"

    info "Checking startup journal for ${service}.service..."

    local journal_output

    journal_output=$(sudo journalctl \
        -u "${service}.service" \
        -n 100 \
        --no-pager 2>/dev/null || true)

    if echo "${journal_output}" | grep -Eiq \
        "APPLICATION FAILED TO START|Application run failed|OutOfMemoryError|BeanCreationException|WebServerException"
    then
        error "Critical startup error detected in ${service}.service."

        echo "${journal_output}"

        return 1
    fi

    info "No critical startup errors found for ${service}.service."

    return 0
}

###############################################################################
# Deploy JAR to backup
###############################################################################

admin_blue_green_deploy_backup()
{
    info "Deploying new Admin JAR to backup..."

    if [[ ! -f "${UPLOADED_JAR}" ]]; then
        error "Uploaded Admin JAR not found: ${UPLOADED_JAR}"
        return 1
    fi

    sudo mkdir -p "$(dirname "${ADMIN_BACKUP_JAR}")"

    sudo /usr/bin/cp "${UPLOADED_JAR}" "${ADMIN_BACKUP_JAR}"

    sudo chown \
        "${ADMIN_DEPLOY_USER}:${ADMIN_DEPLOY_GROUP}" \
        "${ADMIN_BACKUP_JAR}"

    sudo chmod 640 "${ADMIN_BACKUP_JAR}"

    if [[ ! -s "${ADMIN_BACKUP_JAR}" ]]; then
        error "Admin backup JAR is empty."
        return 1
    fi

    info "Admin backup JAR deployed successfully."

    return 0
}

###############################################################################
# Backup health check
###############################################################################

admin_blue_green_health_check_backup()
{
    info "Starting Admin backup health check..."

    admin_blue_green_start_service "${ADMIN_BACKUP_SERVICE}" \
        || return 1

    admin_blue_green_verify_service "${ADMIN_BACKUP_SERVICE}" \
        || return 1

    admin_blue_green_verify_port "${ADMIN_BACKUP_PORT}" \
        || return 1

    admin_blue_green_check_journal "${ADMIN_BACKUP_SERVICE}" \
        || return 1

    info "Admin backup health check passed."

    return 0
}

###############################################################################
# Backup Nginx configuration
###############################################################################

admin_blue_green_backup_nginx()
{
    info "Backing up Admin Nginx upstream configuration..."

    if [[ -f "${ADMIN_NGINX_UPSTREAM}" ]]; then
        sudo /usr/bin/cp \
            "${ADMIN_NGINX_UPSTREAM}" \
            "${ADMIN_NGINX_BACKUP}"
    fi

    info "Admin Nginx configuration backup completed."
}

###############################################################################
# Switch traffic to backup
###############################################################################

admin_blue_green_switch_to_backup()
{
    info "Switching Admin traffic to backup port ${ADMIN_BACKUP_PORT}..."

    sudo tee "${ADMIN_NGINX_UPSTREAM}" >/dev/null <<'EOF'
upstream admin_backend {
    server 127.0.0.1:8082 down;
    server 127.0.0.1:8084;
}
EOF

    if ! sudo /usr/sbin/nginx -t; then
        error "Nginx configuration test failed while switching to Admin backup."

        if [[ -f "${ADMIN_NGINX_BACKUP}" ]]; then
            sudo /usr/bin/cp \
                "${ADMIN_NGINX_BACKUP}" \
                "${ADMIN_NGINX_UPSTREAM}"
        fi

        return 1
    fi

    sudo systemctl reload nginx

    info "Admin traffic is now routed to backup ${ADMIN_BACKUP_PORT}."

    return 0
}

###############################################################################
# Switch traffic to primary
###############################################################################

admin_blue_green_switch_to_primary()
{
    info "Switching Admin traffic to primary port ${ADMIN_PRIMARY_PORT}..."

    sudo tee "${ADMIN_NGINX_UPSTREAM}" >/dev/null <<'EOF'
upstream admin_backend {
    server 127.0.0.1:8082;
    server 127.0.0.1:8084 down;
}
EOF

    if ! sudo /usr/sbin/nginx -t; then
        error "Nginx configuration test failed while switching to Admin primary."
        return 1
    fi

    sudo systemctl reload nginx

    info "Admin traffic is now routed to primary ${ADMIN_PRIMARY_PORT}."

    return 0
}

###############################################################################
# Deploy JAR to primary
###############################################################################

admin_blue_green_deploy_primary()
{
    info "Deploying Admin JAR from backup to primary..."

    if [[ ! -f "${ADMIN_BACKUP_JAR}" ]]; then
        error "Backup Admin JAR not found: ${ADMIN_BACKUP_JAR}"
        return 1
    fi

    sudo /usr/bin/cp \
        "${ADMIN_BACKUP_JAR}" \
        "${ADMIN_PRIMARY_JAR}"

    sudo chown \
        "${ADMIN_DEPLOY_USER}:${ADMIN_DEPLOY_GROUP}" \
        "${ADMIN_PRIMARY_JAR}"

    sudo chmod 640 "${ADMIN_PRIMARY_JAR}"

    if [[ ! -s "${ADMIN_PRIMARY_JAR}" ]]; then
        error "Admin primary JAR is empty."
        return 1
    fi

    info "Admin primary JAR deployed successfully."

    return 0
}

###############################################################################
# Primary health check
###############################################################################

admin_blue_green_health_check_primary()
{
    info "Starting Admin primary health check..."

    admin_blue_green_start_service "${ADMIN_PRIMARY_SERVICE}" \
        || return 1

    admin_blue_green_verify_service "${ADMIN_PRIMARY_SERVICE}" \
        || return 1

    admin_blue_green_verify_port "${ADMIN_PRIMARY_PORT}" \
        || return 1

    admin_blue_green_check_journal "${ADMIN_PRIMARY_SERVICE}" \
        || return 1

    info "Admin primary health check passed."

    return 0
}

###############################################################################
# Primary failure - keep backup serving
###############################################################################

admin_blue_green_failure_backup_active()
{
    local message="$1"

    error "${message}"

    error "Admin primary deployment failed."
    error "Keeping Admin backup active on port ${ADMIN_BACKUP_PORT}."

    # Make absolutely sure primary is not running.
    admin_blue_green_stop_service "${ADMIN_PRIMARY_SERVICE}"

    # Backup must remain running.
    if ! admin_blue_green_service_is_running "${ADMIN_BACKUP_SERVICE}"; then
        error "WARNING: Admin backup service is not running."
    else
        info "Admin backup service remains active."
    fi

    # Keep Nginx on backup.
    admin_blue_green_switch_to_backup || true

    # Cleanup incoming files.
    admin_blue_green_cleanup_incoming

    return 1
}

###############################################################################
# Main Admin Blue-Green deployment
###############################################################################

admin_blue_green_deployment()
{
    info "============================================================"
    info "Starting Admin Blue-Green Deployment"
    info "============================================================"

    info "Project          : ${ADMIN_PROJECT_NAME}"
    info "Primary service  : ${ADMIN_PRIMARY_SERVICE}"
    info "Backup service   : ${ADMIN_BACKUP_SERVICE}"
    info "Primary port     : ${ADMIN_PRIMARY_PORT}"
    info "Backup port      : ${ADMIN_BACKUP_PORT}"
    info "Primary JAR      : ${ADMIN_PRIMARY_JAR}"
    info "Backup JAR       : ${ADMIN_BACKUP_JAR}"
    info "Nginx upstream   : ${ADMIN_NGINX_UPSTREAM}"

    ###########################################################################
    # 1. Deploy uploaded JAR to backup
    ###########################################################################

    admin_blue_green_deploy_backup \
        || {
            admin_blue_green_cleanup_incoming
            return 1
        }

    ###########################################################################
    # 2. Start and verify backup
    ###########################################################################

    if ! admin_blue_green_health_check_backup; then

        # IMPORTANT:
        # admin_backup.service has Restart=always.
        # Stop it so a failed deployment does not keep restarting.
        admin_blue_green_stop_service "${ADMIN_BACKUP_SERVICE}"

        admin_blue_green_cleanup_incoming

        error "Admin backup deployment failed."

        return 1
    fi

    ###########################################################################
    # 3. Backup is healthy - incoming files can now be removed
    ###########################################################################

    admin_blue_green_cleanup_incoming

    ###########################################################################
    # 4. Backup current Nginx configuration
    ###########################################################################

    admin_blue_green_backup_nginx

    ###########################################################################
    # 5. Switch traffic to backup
    ###########################################################################

    if ! admin_blue_green_switch_to_backup; then

        admin_blue_green_stop_service "${ADMIN_BACKUP_SERVICE}"

        return 1
    fi

    ###########################################################################
    # 6. Stop primary
    ###########################################################################

    admin_blue_green_stop_service "${ADMIN_PRIMARY_SERVICE}"

    ###########################################################################
    # 7. Copy tested backup JAR to primary
    ###########################################################################

    if ! admin_blue_green_deploy_primary; then

        admin_blue_green_failure_backup_active \
            "Failed to deploy Admin JAR to primary."

        return 1
    fi

    ###########################################################################
    # 8. Start and verify primary
    ###########################################################################

    if ! admin_blue_green_health_check_primary; then

        admin_blue_green_failure_backup_active \
            "Admin primary health check failed."

        return 1
    fi

    ###########################################################################
    # 9. Primary is healthy - switch traffic back to primary
    ###########################################################################

    if ! admin_blue_green_switch_to_primary; then

        error "Failed to switch Admin traffic back to primary."

        # Keep backup serving traffic.
        admin_blue_green_switch_to_backup || true

        admin_blue_green_stop_service "${ADMIN_PRIMARY_SERVICE}"

        return 1
    fi

    ###########################################################################
    # 10. Stop backup
    ###########################################################################

    admin_blue_green_stop_service "${ADMIN_BACKUP_SERVICE}"

    ###########################################################################
    # 11. Remove temporary Nginx backup
    ###########################################################################

    if [[ -f "${ADMIN_NGINX_BACKUP}" ]]; then
        sudo rm -f "${ADMIN_NGINX_BACKUP}" || true
    fi

    ###########################################################################
    # 12. Final verification
    ###########################################################################

    info "Final Admin deployment verification..."

    if ! admin_blue_green_service_is_running "${ADMIN_PRIMARY_SERVICE}"; then
        error "Admin primary service is not active after deployment."
        return 1
    fi

    if ! admin_blue_green_verify_port "${ADMIN_PRIMARY_PORT}"; then
        error "Admin primary port verification failed."
        return 1
    fi

    if admin_blue_green_service_is_running "${ADMIN_BACKUP_SERVICE}"; then
        error "Admin backup service is still running."
        return 1
    fi

    info "============================================================"
    info "Admin Blue-Green Deployment Successful"
    info "Traffic       : PRIMARY ${ADMIN_PRIMARY_PORT}"
    info "Backup        : STOPPED"
    info "============================================================"

    return 0
}
