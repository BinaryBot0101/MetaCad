#!/bin/bash

#NOTE: 
# This script is designed to be run on a Linux-based MetaCAD build server. 
# It automates the process of building MetaCAD using Docker Compose, while providing robust logging, error handling, and email reporting capabilities. 
# The script will run in the background, allowing you to monitor its progress through log files and receive a detailed report via email upon completion or failure.

# >> TO DO: The cloud provider detection is not proper need to be worked on.

###############################################################################
# STRICT MODE
###############################################################################

set -Eeuo pipefail

###############################################################################
# AUTO BACKGROUND
###############################################################################

if [ -z "${RUNNING_IN_BACKGROUND:-}" ]; then
    export RUNNING_IN_BACKGROUND=1

    nohup "$0" "$@" > launcher.log 2>&1 &
    PID=$!

    echo "$PID" > run_build.pid
    echo "================================================="
    echo 
    echo "Build started in background"
    echo "PID: $PID"
    echo "PID file: $(pwd)/run_build.pid"
    echo
    echo "To check PID: ps -ef | grep run_build.sh || pgrep -af run_build.sh "
    echo "To stop docker composer: docker ps -> docker stop <container_id> or docker kill <container_id>"
    echo
    echo "Launcher log: $(pwd)/launcher.log"
    echo
    echo "Monitor progress:"
    echo "tail -f launcher.log"
    echo
    echo "================================================="

    exit 0
fi

###############################################################################
# CONFIGURATION
###############################################################################

SMTP_HOST="smtp.gmail.com"
SMTP_PORT="587"
SMTP_USERNAME="demotestting309@gmail.com"
SMTP_PASSWORD="faofpgkeqjsocrgw"
SMTP_FROM="demotestting309@gmail.com"
SMTP_TO="demo.testmail77@gmail.com,ganesh.rao@bitsflowtech.com"

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

REPORT_DIR="./z_build_reports"
mkdir -p "$REPORT_DIR"

LOG_FILE="${REPORT_DIR}/build_${TIMESTAMP}.log"
REPORT_FILE="${REPORT_DIR}/report_${TIMESTAMP}.txt"

FAILED=0
FAILED_STEP=""

BUILD_START_TIME=$(date)
###############################################################################
# FORCE_CLEAN_BUILD 
#controls whether to perform a forced clean build by touching all source files and deleting the build/debug directory before building. 
# This can help ensure that all files are recompiled, which is useful if you suspect that incremental builds are not properly detecting changes. 
# However, it will significantly increase build time. Set to 1 to enable forced clean build, or set to 0 to skip cleanup and attempt an incremental build.
###############################################################################
FORCE_CLEAN_BUILD="${FORCE_CLEAN_BUILD:-1}" 
EMAIL_SENT=0
HOST_IP=""
CLOUD_PROVIDER=""
WORK_DIR_LABEL=""

###############################################################################
# LOGGING
###############################################################################

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

wait_for_apt_lock() {
    local timeout="${APT_LOCK_TIMEOUT:-600}"
    local waited=0

    while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock >/dev/null 2>&1; do
        if [ "$waited" -ge "$timeout" ]; then
            log "ERROR: Timed out waiting for apt/dpkg lock after ${timeout} seconds."
            return 1
        fi

        log "Waiting for apt/dpkg lock to be released... (${waited}/${timeout}s)"
        sleep 10
        waited=$((waited + 10))
    done
}

apt_install() {
    local missing_packages=()
    local package

    for package in "$@"; do
        if dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q "install ok installed"; then
            log "Package already installed: $package"
        else
            missing_packages+=("$package")
        fi
    done

    if [ "${#missing_packages[@]}" -eq 0 ]; then
        log "All requested packages are already installed. Skipping apt-get."
        return 0
    fi

    log "Installing missing packages: ${missing_packages[*]}"
    wait_for_apt_lock
    sudo apt-get update
    wait_for_apt_lock
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing_packages[@]}"
}

export -f log
export -f wait_for_apt_lock
export -f apt_install

get_host_ip() {
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')

    if [ -z "$ip" ] && command -v ip >/dev/null 2>&1; then
        ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}')
    fi

    echo "${ip:-Unknown}"
}

get_cloud_provider() {
    local provider=""
    local provider_lc=""

    provider=$(curl -s ipinfo.io/org 2>/dev/null || true)
    provider_lc=$(echo "$provider" | tr '[:upper:]' '[:lower:]')

    case "$provider_lc" in
        *as16509*|*amazon*|*aws*|*ec2*|*as14618*)
            echo "AWS"
            ;;
        *as8075*|*microsoft*|*azure*)
            echo "Microsoft Azure"
            ;;
        *as15169*|*google*|*gcp*)
            echo "Google Cloud"
            ;;
        *as31898*|*oracle*)
            echo "Oracle Cloud"
            ;;
        *as14061*|*digitalocean*)
            echo "DigitalOcean"
            ;;
        *as51167*|*contabo*)
            echo "Contabo"
            ;;
        *as24940*|*hetzner*)
            echo "Hetzner"
            ;;
        *as16276*|*ovh*)
            echo "OVH Cloud"
            ;;
        *as63949*|*akamai*connected*cloud*|*linode*)
            echo "Linode (Akamai)"
            ;;
        *as20473*|*constant*company*|*vultr*)
            echo "Vultr"
            ;;
        *as12876*|*scaleway*)
            echo "Scaleway"
            ;;
        *as202053*|*upcloud*)
            echo "UpCloud"
            ;;
        *as60781*|*leaseweb*)
            echo "Leaseweb"
            ;;
        *as45102*|*alibaba*)
            echo "Alibaba Cloud"
            ;;
        *as132203*|*tencent*)
            echo "Tencent Cloud"
            ;;
        *as36351*|*softlayer*|*ibm*)
            echo "IBM Cloud"
            ;;
        *as27357*|*rackspace*)
            echo "Rackspace"
            ;;
        *as15395*|*cloudsigma*)
            echo "CloudSigma"
            ;;
        *as29222*|*exoscale*)
            echo "Exoscale"
            ;;
        *as26347*|*dreamhost*)
            echo "DreamHost"
            ;;
        *as40509*|*fly.io*)
            echo "Fly.io"
            ;;
        *as396982*|*render*)
            echo "Render"
            ;;
        "")
            echo "$provider"
            ;;
        *)
            echo "$provider"
            ;;
    esac
}

get_work_dir_label() {
    local current_dir
    local parent_dir
    local base_dir

    current_dir=$(basename "$(pwd)")
    parent_dir=$(basename "$(dirname "$(pwd)")")
    base_dir="${parent_dir}/${current_dir}"

    echo "$base_dir"
}

HOST_IP=$(get_host_ip)
CLOUD_PROVIDER=$(get_cloud_provider)
WORK_DIR_LABEL=$(get_work_dir_label)

error_handler() {
    local exit_code=$?

    log "ERROR DETECTED"
    log "LINE      : ${BASH_LINENO[0]}"
    log "COMMAND   : ${BASH_COMMAND}"
    log "EXIT CODE : ${exit_code}"

    FAILED=1

    if [ -z "$FAILED_STEP" ]; then
        FAILED_STEP="Unexpected Script Failure"
    fi

    log "BUILD FAILED"
    log "FAILED STEP : $FAILED_STEP"

    generate_report
    send_email

    exit "$exit_code"
}

trap error_handler ERR

###############################################################################
# REPORT GENERATION
###############################################################################

generate_report() {

    BUILD_END_TIME=$(date)

    {
        echo "========================================================================"
        echo "MetaCAD BUILD REPORT"
        echo "========================================================================"
        echo
        echo "SERVER            : MetaCAD Build Server | $CLOUD_PROVIDER "
        echo "HOST IP           : $HOST_IP"
        echo "WORKING DIRECTORY : $WORK_DIR_LABEL"
        echo
        echo "BUILD START       : $BUILD_START_TIME"
        echo "BUILD END         : $BUILD_END_TIME"
        echo

        if [ "$FAILED" -eq 0 ]; then
            echo "FINAL STATUS      : SUCCESS"
        else
            echo "FINAL STATUS      : FAILED"
            echo "FAILED STEP       : $FAILED_STEP"
        fi

        echo
        echo "========================================================================"
        echo "COMPLETE EXECUTION LOG"
        echo "========================================================================"
        echo

        cat "$LOG_FILE"

    } > "$REPORT_FILE"
}

###############################################################################
# EMAIL REPORT
###############################################################################

send_email() {

if [ "$EMAIL_SENT" -eq 1 ]; then
    return 0
fi


if ! command -v swaks >/dev/null 2>&1; then
    apt_install swaks >> "$LOG_FILE" 2>&1
fi

local SUBJECT

if [ "$FAILED" -eq 0 ]; then
    SUBJECT="[SUCCESS] MetaCAD Build - MetaCAD Build Server | $CLOUD_PROVIDER "
    STATUS_TEXT="SUCCESS"
    ACCESS_URL="http://${HOST_IP}:8010/vnc.html?resize=scale&autoconnect=true"
else
    SUBJECT="[FAILED] MetaCAD Build - MetaCAD Build Server | $CLOUD_PROVIDER "
    STATUS_TEXT="FAILED"
    ACCESS_URL=""
fi

BUILD_END_TIME=$(date)

log "Compressing report and logs..." 

REPORT_SIZE=$(du -h "$REPORT_FILE" | awk '{print $1}')
LOG_SIZE=$(du -h "$LOG_FILE" | awk '{print $1}')

gzip -f "$REPORT_FILE" 
gzip -f "$LOG_FILE" 

REPORT_GZ="${REPORT_FILE}.gz" 
LOG_GZ="${LOG_FILE}.gz"

SUMMARY_FILE=$(mktemp)

cat > "$SUMMARY_FILE" <<EOF


MetaCAD Build Summary

Status            : $STATUS_TEXT
Server            : MetaCAD Build Server | $CLOUD_PROVIDER 
Host IP           : $HOST_IP
Working Directory : $WORK_DIR_LABEL

Build Started     : $BUILD_START_TIME
Build Finished    : $BUILD_END_TIME

Failed Step       : ${FAILED_STEP:-N/A}
EOF

if [ "$STATUS_TEXT" = "SUCCESS" ]; then
cat >> "$SUMMARY_FILE" <<EOF

MetaCAD Access URL:
$ACCESS_URL

Note:
If you are unable to access the URL, whitelist/open port 8010 in the server firewall or cloud security group.
EOF
fi

cat >> "$SUMMARY_FILE" <<EOF

Report Attached:
$(basename "$REPORT_FILE") (${REPORT_SIZE})

Build Log Attached:
$(basename "$LOG_FILE") (${LOG_SIZE})

Both files are attached in compressed (.gz) format.
EOF


log "Sending email report with attachments..."

IFS=',' read -r -a SMTP_TO_RECIPIENTS <<< "$SMTP_TO"

EMAIL_FAILED=0

for RECIPIENT in "${SMTP_TO_RECIPIENTS[@]}"; do
    RECIPIENT=$(echo "$RECIPIENT" | xargs)
    if [ -z "$RECIPIENT" ]; then
        continue
    fi

    log "Sending email report to $RECIPIENT..."

    if swaks \
        --server "$SMTP_HOST" \
        --port "$SMTP_PORT" \
        --tls \
        --auth LOGIN \
        --auth-user "$SMTP_USERNAME" \
        --auth-password "$SMTP_PASSWORD" \
        --from "$SMTP_FROM" \
        --to "$RECIPIENT" \
        --header "Subject: $SUBJECT" \
        --body @"$SUMMARY_FILE" \
        --attach @"$REPORT_GZ" \
        --attach @"$LOG_GZ" \
        >> "$LOG_FILE" 2>&1; then
        log "Email has been sent successfully to $RECIPIENT."
    else
        EMAIL_FAILED=1
        log "WARNING: Email could not be sent to $RECIPIENT. Check swaks output above."
    fi
done

if [ "$EMAIL_FAILED" -eq 0 ]; then
    log "Email has been sent successfully to all recipients."
fi

rm -f "$SUMMARY_FILE"

EMAIL_SENT=1

}


###############################################################################
# STEP RUNNER
###############################################################################

run_step() {

    local STEP_NAME="${1:-}"
    local CMD="${2:-}"

    if [ -z "$STEP_NAME" ]; then
        log "ERROR: run_step called without STEP_NAME"
        return 1
    fi

    if [ -z "$CMD" ]; then
        log "ERROR: run_step called without CMD for step [$STEP_NAME]"
        return 1
    fi

    echo "" | tee -a "$LOG_FILE"
    echo "========================================================================" | tee -a "$LOG_FILE"
    echo "STEP       : $STEP_NAME" | tee -a "$LOG_FILE"
    echo "START TIME : $(date)" | tee -a "$LOG_FILE"
    echo "COMMAND    : $CMD" | tee -a "$LOG_FILE"
    echo "========================================================================" | tee -a "$LOG_FILE"

    local STEP_START
    STEP_START=$(date +%s)

    FAILED_STEP="$STEP_NAME"

    bash -c "$CMD" 2>&1 | tee -a "$LOG_FILE"

    local STATUS=${PIPESTATUS[0]}

    local STEP_END
    STEP_END=$(date +%s)

    local DURATION=$((STEP_END - STEP_START))

    echo "" | tee -a "$LOG_FILE"
    echo "EXIT CODE  : $STATUS" | tee -a "$LOG_FILE"
    echo "DURATION   : ${DURATION} seconds" | tee -a "$LOG_FILE"
    echo "END TIME   : $(date)" | tee -a "$LOG_FILE"
    echo "========================================================================" | tee -a "$LOG_FILE"

    if [ "$STATUS" -ne 0 ]; then
        FAILED=1
        FAILED_STEP="$STEP_NAME"
        return "$STATUS"
    fi

    FAILED_STEP=""
    return 0
}

###############################################################################
# START
###############################################################################

log "========================================================================"
log "MetaCAD BUILD PROCESS STARTED"
log "SERVER   : MetaCAD Build Server | $CLOUD_PROVIDER "
log "HOST IP  : $HOST_IP"
log "WORKDIR  : $WORK_DIR_LABEL"
log "========================================================================"

###############################################################################
# STEP 1 - CREATE .ENV
###############################################################################

if [ ! -f ".env" ]; then

    if [ ! -f "env.example" ]; then
        FAILED=1
        FAILED_STEP="Create .env"

        log "ERROR: env.example not found"
        exit 1
    fi

    run_step \
        "Create .env from env.example" \
        "cp env.example .env"

else
    log ".env already exists. Skipping creation."
fi

###############################################################################
# STEP 2
###############################################################################

run_step \
    "Install dos2unix" \
    "apt_install dos2unix"

###############################################################################
# STEP 3
###############################################################################

run_step \
    "Convert docker/start-novnc.sh" \
    "dos2unix docker/start-novnc.sh"

###############################################################################
# STEP 4
###############################################################################

run_step \
    "docker compose build" \
    "docker compose build"

###############################################################################
# STEP 5
###############################################################################

if [ "$FORCE_CLEAN_BUILD" = "1" ]; then
    run_step \
        "docker compose configure cleanup" \
        'docker compose run --rm configure bash -c "find /workspace/FreeCAD -type f -exec touch {} + && rm -rf /workspace/FreeCAD/build/debug/*"'
else
    log "Skipping forced cleanup. Set FORCE_CLEAN_BUILD=1 to touch source files and delete build/debug."
fi

###############################################################################
# STEP 6
###############################################################################

run_step \
    "docker compose run configure" \
    "docker compose run --rm configure"

###############################################################################
# STEP 7
###############################################################################

run_step \
    "docker compose run build" \
    "docker compose run --rm build"

###############################################################################
# STEP 8
###############################################################################

run_step \
    "docker compose desktop startup" \
    "docker compose --profile desktop up desktop -d"

###############################################################################
# SUCCESS
###############################################################################

log "========================================================================"
log "BUILD COMPLETED SUCCESSFULLY"
log "LOG FILE    : $LOG_FILE"
log "REPORT FILE : $REPORT_FILE"
log "========================================================================"

generate_report
send_email

exit 0
