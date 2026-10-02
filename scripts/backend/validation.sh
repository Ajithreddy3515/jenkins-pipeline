#!/usr/bin/env bash

###############################################################################
# Validation Functions
###############################################################################

validate_environment()
{
    info "Validating deployment environment..."

    validate_required_commands || return 1
    validate_configuration || return 1
    validate_upload || return 1
    validate_service || return 1

    info "Environment validation completed successfully."

    return 0
}

###############################################################################

validate_required_commands()
{
    info "Checking required commands..."

    local commands=(
        systemctl
        journalctl
        sha256sum
        find
        cp
        mv
        rm
        mkdir
    )

    local command

    for command in "${commands[@]}"
    do
        require_command "$command"
    done

    info "Required commands verified."
}

###############################################################################

validate_upload()
{
    info "Checking uploaded package..."

    ###########################################################################
    # Verify upload directory
    ###########################################################################

    if [[ ! -d "$UPLOAD_DIR" ]]; then
        error "Upload directory does not exist."
        return 1
    fi

    ###########################################################################
    # Verify DEPLOY file
    ###########################################################################

    local deploy_count

    deploy_count=$(find "$UPLOAD_DIR" -maxdepth 1 -type f -name "*.deploy" | wc -l)

    [[ "$deploy_count" -eq 1 ]] || {
        error "Exactly one .deploy file is required."
        return 1
    }

    UPLOADED_DEPLOY=$(find "$UPLOAD_DIR" -maxdepth 1 -type f -name "*.deploy")

    ###########################################################################
    # Find uploaded package
    ###########################################################################

    local package_count

    package_count=$(find "$UPLOAD_DIR" -maxdepth 1 -type f \
        \( -name "*.jar" -o -name "*.zip" \) | wc -l)

    [[ "$package_count" -eq 1 ]] || {
        error "Exactly one .jar or .zip file is required."
        return 1
    }

    UPLOADED_PACKAGE=$(find "$UPLOAD_DIR" -maxdepth 1 -type f \
        \( -name "*.jar" -o -name "*.zip" \))

    ###########################################################################
    # ZIP uploaded
    ###########################################################################

    if [[ "$UPLOADED_PACKAGE" == *.zip ]]; then

        info "ZIP package detected."

        unzip -oq "$UPLOADED_PACKAGE" -d "$UPLOAD_DIR"

        local jar_count

        jar_count=$(find "$UPLOAD_DIR" -maxdepth 1 -type f -name "*.jar" | wc -l)

        [[ "$jar_count" -eq 1 ]] || {
            error "ZIP must contain exactly one JAR."
            return 1
        }

        UPLOADED_JAR=$(find "$UPLOAD_DIR" -maxdepth 1 -type f -name "*.jar")

    else

        UPLOADED_JAR="$UPLOADED_PACKAGE"

    fi

    info "Uploaded package verified."
}

###############################################################################

#validate_service()
#{
#    info "Checking systemd service..."
#
#    if ! systemctl list-unit-files | grep -q "^${SERVICE_NAME}.service"; then
#        error "Service '${SERVICE_NAME}' not found."
#
#        exit 1
#    fi
#
#    info "Systemd service verified."
#}
validate_service()
{
    info "Checking systemd service..."

    if ! sudo  systemctl show "${SERVICE_NAME}.service" >/dev/null 2>&1; then
        error "Service '${SERVICE_NAME}' not found."
        return 1
    fi

    info "Systemd service verified."
}
