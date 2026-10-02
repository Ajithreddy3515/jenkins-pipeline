#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

###############################################################################
# Blue-Green Backend Deployment
###############################################################################

FRAMEWORK_HOME="/opt/backend-deployment"

LIB_DIR="${FRAMEWORK_HOME}/lib"
CONFIG_DIR="${FRAMEWORK_HOME}/config"

###############################################################################
# Arguments
###############################################################################

ACTION="${1:-}"
APPLICATION="${2:-}"

if [[ -z "$ACTION" || -z "$APPLICATION" ]]; then
    echo
    echo "Usage:"
    echo "  backend-deploy.sh blue-green <application>"
    echo
    echo "Applications:"
    echo "  211_motor"
    echo "  211_admin"
    echo
    exit 1
fi

###############################################################################
# Load libraries
###############################################################################

source "${LIB_DIR}/common.sh"
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/config.sh"
source "${LIB_DIR}/validation.sh"
source "${LIB_DIR}/bluegreen.sh"
source "${LIB_DIR}/admin_bluegreen.sh"

###############################################################################
# Load application configuration
###############################################################################

load_configuration "$APPLICATION"

###############################################################################
# Initialize framework
###############################################################################

initialize_framework

###############################################################################
# Blue-Green Deployment
###############################################################################

case "$ACTION" in

    blue-green)

        info "============================================================"
        info "Blue-Green Deployment"
        info "Application : ${APPLICATION}"
        info "============================================================"

        #######################################################################
        # Validate
        #######################################################################

        validate_environment || {
            error "Environment validation failed."
            exit 1
        }

        #######################################################################
        # Application selection
        #######################################################################

        case "$APPLICATION" in

            211_motor)

                info "Running Motor Blue-Green deployment..."

                if ! blue_green_deployment; then
                    error "Motor Blue-Green deployment failed."
                    exit 1
                fi

                ;;

            211_admin)

                info "Running Admin Blue-Green deployment..."

                if ! admin_blue_green_deployment; then
                    error "Admin Blue-Green deployment failed."
                    exit 1
                fi

                ;;

            *)

                error "Unsupported application: ${APPLICATION}"
                exit 1

                ;;

        esac

        #######################################################################
        # Success
        #######################################################################

        info "============================================================"
        info "Blue-Green Deployment SUCCESSFUL"
        info "Application : ${APPLICATION}"
        info "============================================================"

        exit 0
        ;;

    *)

        error "Invalid action: ${ACTION}"

        echo
        echo "Usage:"
        echo "  backend-deploy.sh blue-green <application>"
        echo

        exit 1
        ;;

esac
