#!/bin/bash

###############################################################################
# Motor Blue-Green Deployment
#
# Flow:
#   incoming JAR
#       ↓
#   backup service
#       ↓
#   verify backup
#       ↓
#   cleanup incoming
#       ↓
#   switch nginx to backup
#       ↓
#   stop primary
#       ↓
#   copy JAR FROM backup TO primary
#       ↓
#   start primary
#       ↓
#   verify primary
#       ↓
#   switch nginx back to primary
#       ↓
#   stop backup
###############################################################################

BLUEGREEN_PRIMARY_SERVICE="211_motor"
BLUEGREEN_BACKUP_SERVICE="211_motor_backup"

BLUEGREEN_PRIMARY_JAR="/opt/backend/211_motor/211_motor.jar"
BLUEGREEN_BACKUP_JAR="/opt/backend/211_motor_backup/211_motor.jar"

BLUEGREEN_NGINX_UPSTREAM="/etc/nginx/upstreams/motor_backend.conf"

BLUEGREEN_PRIMARY_PORT="8083"
BLUEGREEN_BACKUP_PORT="8086"

BLUEGREEN_NGINX_BACKUP="${BLUEGREEN_NGINX_UPSTREAM}.deployment-backup"


###############################################################################
# Cleanup incoming files
###############################################################################

blue_green_cleanup_incoming()
{
    info "Cleaning Motor incoming deployment files..."

    if [[ -n "${UPLOADED_JAR:-}" && -f "${UPLOADED_JAR}" ]]; then
        sudo rm -f "${UPLOADED_JAR}" || true
    fi

    if [[ -n "${UPLOADED_DEPLOY:-}" && -f "${UPLOADED_DEPLOY}" ]]; then
        sudo rm -f "${UPLOADED_DEPLOY}" || true
    fi

    # Safety cleanup for any remaining Motor deployment files.
    if [[ -d "${UPLOAD_DIR:-}" ]]; then
        sudo find "${UPLOAD_DIR}" -maxdepth 1 \
            -type f \
            \( -name "*.jar" -o -name "*.deploy" -o -name "*.zip" \) \
            -delete 2>/dev/null || true
    fi

    info "Motor incoming cleanup completed."
}


###############################################################################
# Service status
###############################################################################

blue_green_service_is_running()
{
    local service="$1"

    sudo systemctl is-active --quiet "${service}.service"
}


###############################################################################
# Start service
###############################################################################

blue_green_start_service()
{
    local service="$1"

    info "Starting ${service}.service..."

    if ! sudo systemctl start "${service}.service"; then
        error "Failed to start ${service}.service."
        return 1
    fi

    return 0
}


###############################################################################
# Stop service
###############################################################################

blue_green_stop_service()
{
    local service="$1"

    info "Stopping ${service}.service..."

    if sudo systemctl is-active --quiet "${service}.service"; then
        if ! sudo systemctl stop "${service}.service"; then
            error "Failed to stop ${service}.service."
            return 1
        fi
    else
        info "${service}.service is already stopped."
    fi

    return 0
}


###############################################################################
# Verify service
###############################################################################

blue_green_verify_service()
{
    local service="$1"
    local wait_seconds="${2:-30}"

    info "Waiting for ${service}.service to become healthy..."

    local elapsed=0

    while [[ "${elapsed}" -lt "${wait_seconds}" ]]; do

        if sudo systemctl is-active --quiet "${service}.service"; then
            info "${service}.service is active."
            return 0
        fi

        sleep 2
        elapsed=$((elapsed + 2))
    done

    error "${service}.service failed to become active."

    sudo systemctl status "${service}.service" --no-pager || true

    return 1
}


###############################################################################
# Verify port
###############################################################################

blue_green_verify_port()
{
    local port="$1"
    local service="$2"
    local wait_seconds="${3:-30}"

    info "Checking ${service} port ${port}..."

    local elapsed=0

    while [[ "${elapsed}" -lt "${wait_seconds}" ]]; do

        if sudo ss -lntp 2>/dev/null | grep -q ":${port} "; then
            info "${service} is listening on port ${port}."
            return 0
        fi

        sleep 2
        elapsed=$((elapsed + 2))
    done

    error "${service} is not listening on port ${port}."

    return 1
}


###############################################################################
# Check startup errors
###############################################################################

blue_green_check_journal()
{
    local service="$1"

    info "Checking ${service}.service journal..."

    local errors

    errors=$(
        sudo journalctl \
            -u "${service}.service" \
            -n 100 \
            --no-pager 2>/dev/null |
        grep -Ei \
        "APPLICATION FAILED TO START|Application run failed|OutOfMemoryError|BeanCreationException|WebServerException" \
        || true
    )

    if [[ -n "${errors}" ]]; then
        error "Startup errors detected for ${service}.service:"
        echo "${errors}"
        return 1
    fi

    info "No critical startup errors found for ${service}.service."

    return 0
}


###############################################################################
# Deploy JAR to backup
###############################################################################

blue_green_deploy_backup()
{
    info "Deploying new Motor JAR to backup..."

    if [[ -z "${UPLOADED_JAR:-}" || ! -f "${UPLOADED_JAR}" ]]; then
        error "Uploaded Motor JAR not found."
        return 1
    fi

    if ! sudo cp -f "${UPLOADED_JAR}" "${BLUEGREEN_BACKUP_JAR}"; then
        error "Failed to copy JAR to Motor backup."
        return 1
    fi

    if ! sudo chown "${DEPLOY_USER}:${DEPLOY_GROUP}" "${BLUEGREEN_BACKUP_JAR}"; then
        error "Failed to set backup JAR ownership."
        return 1
    fi

    if ! sudo chmod 640 "${BLUEGREEN_BACKUP_JAR}"; then
        error "Failed to set backup JAR permissions."
        return 1
    fi

    if [[ ! -f "${BLUEGREEN_BACKUP_JAR}" ]]; then
        error "Backup JAR verification failed."
        return 1
    fi

    info "Motor backup JAR copied successfully."

    return 0
}


###############################################################################
# Backup health check
###############################################################################

blue_green_health_check_backup()
{
    info "Starting Motor backup service..."

    blue_green_start_service "${BLUEGREEN_BACKUP_SERVICE}" || return 1

    blue_green_verify_service \
        "${BLUEGREEN_BACKUP_SERVICE}" \
        30 || return 1

    blue_green_verify_port \
        "${BLUEGREEN_BACKUP_PORT}" \
        "${BLUEGREEN_BACKUP_SERVICE}" \
        30 || return 1

    blue_green_check_journal \
        "${BLUEGREEN_BACKUP_SERVICE}" || return 1

    info "Motor backup deployment verified successfully."

    return 0
}


###############################################################################
# Backup nginx configuration
###############################################################################

blue_green_backup_nginx()
{
    info "Backing up Motor Nginx upstream configuration..."

    if ! sudo cp -f \
        "${BLUEGREEN_NGINX_UPSTREAM}" \
        "${BLUEGREEN_NGINX_BACKUP}"; then

        error "Failed to backup Nginx configuration."
        return 1
    fi

    return 0
}


###############################################################################
# Switch Nginx to backup
###############################################################################

blue_green_switch_to_backup()
{
    info "Switching Nginx traffic to Motor backup..."

    blue_green_backup_nginx || return 1

    if ! sudo tee "${BLUEGREEN_NGINX_UPSTREAM}" > /dev/null <<'EOF'
upstream motor_backend {
    server 127.0.0.1:8083 down;
    server 127.0.0.1:8086;
}
EOF
    then
        error "Failed to write backup Nginx configuration."
        return 1
    fi

    if ! sudo nginx -t; then
        error "Nginx configuration test failed."

        sudo cp -f \
            "${BLUEGREEN_NGINX_BACKUP}" \
            "${BLUEGREEN_NGINX_UPSTREAM}" || true

        return 1
    fi

    if ! sudo systemctl reload nginx; then
        error "Failed to reload Nginx."

        sudo cp -f \
            "${BLUEGREEN_NGINX_BACKUP}" \
            "${BLUEGREEN_NGINX_UPSTREAM}" || true

        sudo nginx -t || true
        sudo systemctl reload nginx || true

        return 1
    fi

    info "Nginx traffic is now going to Motor backup."

    return 0
}


###############################################################################
# Switch Nginx to primary
###############################################################################

blue_green_switch_to_primary()
{
    info "Switching Nginx traffic back to Motor primary..."

    if ! sudo tee "${BLUEGREEN_NGINX_UPSTREAM}" > /dev/null <<'EOF'
upstream motor_backend {
    server 127.0.0.1:8083;
    server 127.0.0.1:8086 down;
}
EOF
    then
        error "Failed to write primary Nginx configuration."
        return 1
    fi

    if ! sudo nginx -t; then
        error "Nginx primary configuration test failed."

        if [[ -f "${BLUEGREEN_NGINX_BACKUP}" ]]; then
            sudo cp -f \
                "${BLUEGREEN_NGINX_BACKUP}" \
                "${BLUEGREEN_NGINX_UPSTREAM}" || true

            sudo nginx -t || true
            sudo systemctl reload nginx || true
        fi

        return 1
    fi

    if ! sudo systemctl reload nginx; then
        error "Failed to reload Nginx for primary."

        if [[ -f "${BLUEGREEN_NGINX_BACKUP}" ]]; then
            sudo cp -f \
                "${BLUEGREEN_NGINX_BACKUP}" \
                "${BLUEGREEN_NGINX_UPSTREAM}" || true

            sudo nginx -t || true
            sudo systemctl reload nginx || true
        fi

        return 1
    fi

    info "Nginx traffic is now going to Motor primary."

    return 0
}


###############################################################################
# Deploy primary FROM BACKUP
###############################################################################

blue_green_deploy_primary()
{
    info "Deploying Motor primary from backup JAR..."

    if [[ ! -f "${BLUEGREEN_BACKUP_JAR}" ]]; then
        error "Backup JAR does not exist."
        return 1
    fi

    if ! sudo cp -f \
        "${BLUEGREEN_BACKUP_JAR}" \
        "${BLUEGREEN_PRIMARY_JAR}"; then

        error "Failed to copy backup JAR to primary."
        return 1
    fi

    if ! sudo chown \
        "${DEPLOY_USER}:${DEPLOY_GROUP}" \
        "${BLUEGREEN_PRIMARY_JAR}"; then

        error "Failed to set primary JAR ownership."
        return 1
    fi

    if ! sudo chmod 640 "${BLUEGREEN_PRIMARY_JAR}"; then
        error "Failed to set primary JAR permissions."
        return 1
    fi

    if [[ ! -f "${BLUEGREEN_PRIMARY_JAR}" ]]; then
        error "Primary JAR verification failed."
        return 1
    fi

    info "Motor primary JAR copied from backup successfully."

    return 0
}


###############################################################################
# Primary health check
###############################################################################

blue_green_health_check_primary()
{
    info "Starting Motor primary service..."

    blue_green_start_service "${BLUEGREEN_PRIMARY_SERVICE}" || return 1

    blue_green_verify_service \
        "${BLUEGREEN_PRIMARY_SERVICE}" \
        30 || return 1

    blue_green_verify_port \
        "${BLUEGREEN_PRIMARY_PORT}" \
        "${BLUEGREEN_PRIMARY_SERVICE}" \
        30 || return 1

    blue_green_check_journal \
        "${BLUEGREEN_PRIMARY_SERVICE}" || return 1

    info "Motor primary deployment verified successfully."

    return 0
}


###############################################################################
# Failure while backup is active
###############################################################################

blue_green_failure_backup_active()
{
    local reason="$1"

    error "Motor blue-green deployment failed: ${reason}"

    error "Motor backup remains active to keep traffic available."

    # Incoming files can safely be removed because the backup JAR
    # has already been copied and verified.
    blue_green_cleanup_incoming

    return 1
}


###############################################################################
# Main Motor Blue-Green Deployment
###############################################################################

blue_green_deployment()
{
    info "============================================================"
    info "Starting Motor Blue-Green Deployment"
    info "============================================================"

    ###########################################################################
    # STEP 1
    # Copy incoming JAR → backup
    ###########################################################################

    if ! blue_green_deploy_backup; then

        blue_green_cleanup_incoming

        error "Motor backup deployment copy failed."

        return 1
    fi


    ###########################################################################
    # STEP 2
    # Start + verify backup
    ###########################################################################

    if ! blue_green_health_check_backup; then

        blue_green_stop_service "${BLUEGREEN_BACKUP_SERVICE}" || true

        blue_green_cleanup_incoming

        error "Motor backup verification failed."

        return 1
    fi


    ###########################################################################
    # STEP 3
    # Backup is now SUCCESSFUL.
    #
    # Incoming files are no longer required.
    ###########################################################################

    info "Motor backup deployment successful."

    blue_green_cleanup_incoming


    ###########################################################################
    # STEP 4
    # Switch traffic to backup
    ###########################################################################

    if ! blue_green_switch_to_backup; then

        blue_green_stop_service "${BLUEGREEN_BACKUP_SERVICE}" || true

        error "Failed to switch Nginx traffic to Motor backup."

        return 1
    fi


    ###########################################################################
    # STEP 5
    # Stop primary
    ###########################################################################

    if ! blue_green_stop_service "${BLUEGREEN_PRIMARY_SERVICE}"; then

        error "Failed to stop Motor primary."

        # Backup is already serving traffic.
        return 1
    fi


    ###########################################################################
    # STEP 6
    # Copy BACKUP JAR → PRIMARY
    ###########################################################################

    if ! blue_green_deploy_primary; then

        return blue_green_failure_backup_active \
            "Failed to deploy backup JAR to primary."
    fi


    ###########################################################################
    # STEP 7
    # Start + verify primary
    ###########################################################################

    if ! blue_green_health_check_primary; then

        error "Motor primary failed after deployment."

        #######################################################################
        # IMPORTANT:
        # Do NOT switch Nginx back to primary.
        #
        # Backup remains active on 8086.
        #######################################################################

        blue_green_stop_service "${BLUEGREEN_PRIMARY_SERVICE}" || true

        error "Motor backup remains active on port ${BLUEGREEN_BACKUP_PORT}."

        return 1
    fi


    ###########################################################################
    # STEP 8
    # Primary successful → switch traffic back
    ###########################################################################

    if ! blue_green_switch_to_primary; then

        error "Failed to switch traffic back to Motor primary."

        #######################################################################
        # Backup should remain available.
        #######################################################################

        return 1
    fi


    ###########################################################################
    # STEP 9
    # Primary is serving traffic → stop backup
    ###########################################################################

    if ! blue_green_stop_service "${BLUEGREEN_BACKUP_SERVICE}"; then

        warn "Motor backup could not be stopped."

        # Primary is already active and serving traffic.
        # Do not fail the deployment only because backup cleanup failed.
    fi


    ###########################################################################
    # STEP 10
    # Remove temporary Nginx deployment backup
    ###########################################################################

    if [[ -f "${BLUEGREEN_NGINX_BACKUP}" ]]; then
        sudo rm -f "${BLUEGREEN_NGINX_BACKUP}" || true
    fi


    ###########################################################################
    # SUCCESS
    ###########################################################################

    info "============================================================"
    info "Motor Blue-Green Deployment SUCCESSFUL"
    info "============================================================"

    return 0
}
