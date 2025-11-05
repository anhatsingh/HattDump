#!/bin/bash
set -euo pipefail

# === DEFAULT CONFIG ===
REMOTE_USER="youruser"
REMOTE_HOST="your.server.com"
REMOTE_CONTAINER="postgres"
REMOTE_DB_USER="postgres"
DATABASES=("yourdb")
BACKUP_DIR="./backups"
LOCAL_CONTAINER="sql_db"
LOG_FILE="./db_sync.log"
DRY_RUN=false
SKIP_RESTORE=false
SSH_KEY=""
LOCAL_DB_USER="postgres"

# === COLORS ===
RED=$(tput setaf 1 || true)
GREEN=$(tput setaf 2 || true)
YELLOW=$(tput setaf 3 || true)
RESET=$(tput sgr0 || true)
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# === FUNCTIONS ===
usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --remote-user USER          Remote SSH user (default: $REMOTE_USER)"
    echo "  --remote-host HOST          Remote server host (default: $REMOTE_HOST)"
    echo "  --remote-container NAME     Remote Postgres docker container (default: $REMOTE_CONTAINER)"
    echo "  --remote-db-user USER       Postgres user inside remote container (default: $REMOTE_DB_USER)"
    echo "  --databases 'db1 db2'       Space-separated list of databases (default: ${DATABASES[*]})"
    echo "  --local-container NAME      Local docker container to restore into (default: $LOCAL_CONTAINER)"
    echo "  --backup-dir DIR            Backup directory (default: $BACKUP_DIR)"
    echo "  --config FILE               Load defaults from config file"
    echo "  --skip-restore              Only download backups, skip restore"
    echo "  --dry-run                   Show actions without executing"
    echo "  --clean                     Delete all local backups and exit"
    echo "  -h, --help                  Show this help"
    exit 1
}

log() {
    local LEVEL="$1"
    shift
    echo -e "[$(date +"%Y-%m-%d %H:%M:%S")] [$LEVEL] $*" | tee -a "$LOG_FILE"
}

clean_backups() {
    log INFO "Deleting all local backups..."
    rm -rf "$BACKUP_DIR"
    log INFO "Backups deleted."
    exit 0
}

load_config() {
    local CONFIG_FILE="$1"
    if [[ -f "$CONFIG_FILE" ]]; then
        log INFO "Loading config from $CONFIG_FILE"
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    else
        log ERROR "Config file $CONFIG_FILE not found!"
        exit 1
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --remote-user) REMOTE_USER="$2"; shift 2;;
            --remote-host) REMOTE_HOST="$2"; shift 2;;
            --remote-container) REMOTE_CONTAINER="$2"; shift 2;;
            --remote-db-user) REMOTE_DB_USER="$2"; shift 2;;
            --databases) IFS=' ' read -r -a DATABASES <<< "$2"; shift 2;;
            --local-container) LOCAL_CONTAINER="$2"; shift 2;;
            --backup-dir) BACKUP_DIR="$2"; shift 2;;
            --config) load_config "$2"; shift 2;;
            --skip-restore) SKIP_RESTORE=true; shift;;
            --dry-run) DRY_RUN=true; shift;;
            --clean) clean_backups;;
            --ssh-key) SSH_KEY="$2"; shift 2;;
            -h|--help) usage;;
            *) log ERROR "Unknown option: $1"; usage;;
        esac
    done
}

download_backup() {
    mkdir -p "$BACKUP_DIR"

    for DB in "${DATABASES[@]}"; do
        BACKUP_FILE="$BACKUP_DIR/${DB}_${TIMESTAMP}.sql.gz"

        # Check if recent backup exists (last 24h)
        RECENT_BACKUP=$(find "$BACKUP_DIR" -name "${DB}_*.sql.gz" -mtime -1 | head -n 1 || true)
        if [[ -n "$RECENT_BACKUP" ]]; then
            log INFO "${YELLOW}Found recent backup for $DB ($RECENT_BACKUP). Using it.${RESET}"
            continue
        fi

        log INFO "No recent backup for $DB. Downloading new one..."
        if $DRY_RUN; then
            log INFO "DRY RUN: ssh $REMOTE_USER@$REMOTE_HOST docker exec -t $REMOTE_CONTAINER pg_dump -U $REMOTE_DB_USER $DB | gzip > $BACKUP_FILE"
        else
            $SSH_CMD "$REMOTE_USER@$REMOTE_HOST" \
            "docker exec -t $REMOTE_CONTAINER pg_dump --no-owner --no-acl -U $REMOTE_DB_USER $DB | gzip" \
            > "$BACKUP_FILE"

            if [[ ! -s "$BACKUP_FILE" ]]; then
                log ERROR "Backup file for $DB is empty!"
                exit 1
            fi
            log INFO "${GREEN}Backup saved to $BACKUP_FILE${RESET}"
        fi
    done
}

restore_backup() {
    if $SKIP_RESTORE; then
        log INFO "Skipping restore (per --skip-restore)"
        return
    fi

    for DB in "${DATABASES[@]}"; do
         # Find the latest backup file for this DB
        BACKUP_FILE=$(ls -t "$BACKUP_DIR/${DB}_"*.sql.gz 2>/dev/null | head -n1)

        if [[ -z "$BACKUP_FILE" ]]; then
            log ERROR "No backup file found for $DB in $BACKUP_DIR"
            continue
        fi

        echo "Using latest backup: $BACKUP_FILE"

        echo "Recreating $DB locally..."
        docker exec -i "$LOCAL_CONTAINER" psql -U "$LOCAL_DB_USER" -tc "SELECT 1 FROM pg_database WHERE datname = '$DB'" | grep -q 1 && \
        docker exec -i "$LOCAL_CONTAINER" psql -U "$LOCAL_DB_USER" -c "DROP DATABASE \"$DB\""
        docker exec -i "$LOCAL_CONTAINER" psql -U "$LOCAL_DB_USER" -c "CREATE DATABASE \"$DB\""

        echo "Importing $DB into local container..."
        gunzip -c "$BACKUP_FILE" | docker exec -i "$LOCAL_CONTAINER" \
        psql -U "$LOCAL_DB_USER" -d "$DB" \
        -v ON_ERROR_STOP=1 --set VERBOSITY=verbose --set SHOW_CONTEXT=always \
        > /dev/null
        echo "Done"
    done
}


list_remote_databases() {
    log INFO "Fetching list of databases from remote Postgres..."
    if $DRY_RUN; then
        log INFO "DRY RUN: ssh -o BatchMode=yes $REMOTE_USER@$REMOTE_HOST docker exec -i $REMOTE_CONTAINER psql -U $REMOTE_DB_USER -lqt"
    else
        $SSH_CMD "$REMOTE_USER@$REMOTE_HOST" \
        "docker exec -i $REMOTE_CONTAINER psql -U $REMOTE_DB_USER -lqt" \
        | cut -d \| -f 1 | awk '{$1=$1};1' | grep -vE '^(|template0|template1)$' \
        | tee /dev/stderr
    fi
}


# === MAIN ===
parse_args "$@"
SSH_CMD="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
if [[ -n "$SSH_KEY" ]]; then
    SSH_CMD="$SSH_CMD -i $SSH_KEY"
fi
# list_remote_databases
download_backup
restore_backup
