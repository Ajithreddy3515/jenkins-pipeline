#!/usr/bin/env bash

###############################################################################
# Blue-Green Configuration Functions
###############################################################################

load_configuration()
{
    local application="$1"

    case "$application" in

        211_admin)
            CONFIG_FILE="${CONFIG_DIR}/admin.conf"
            ;;

        211_motor)
            CONFIG_FILE="${CONFIG_DIR}/211_motor.conf"
            ;;

        *)
            echo "ERROR: Unsupported application: ${application}"
            exit 1
            ;;

    esac

    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "ERROR: Configuration file not found."
        echo "File : ${CONFIG_FILE}"
        exit 1
    fi

    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
}


###############################################################################
# Validate configuration
###############################################################################

validate_configuration()
{
    local required=(
        PROJECT_NAME
        SERVICE_NAME
        DEPLOY_USER
        DEPLOY_GROUP
        UPLOAD_DIR
        LIVE_JAR
        LOG_DIR
    )

    local variable

    for variable in "${required[@]}"
    do

        if [[ -z "${!variable:-}" ]]; then

            echo "ERROR: Missing configuration variable."
            echo "Variable : ${variable}"
            echo "Config   : ${CONFIG_FILE}"

            return 1
        fi

    done

    return 0
}


###############################################################################
# Initialize framework
###############################################################################

initialize_framework()
{
    ensure_directory "$LOG_DIR"

    info "============================================================"
    info "Framework : Blue-Green Backend Deployment"
    info "Version   : 2.0.0"
    info "Project   : ${PROJECT_NAME}"
    info "Action    : ${ACTION}"
    info "============================================================"

    info "Configuration loaded successfully."
    info "Framework initialized."
}
