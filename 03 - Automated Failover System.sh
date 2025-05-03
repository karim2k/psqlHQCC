#!/bin/bash
# postgres_auto_failover.sh
# Complete automated failover solution for PostgreSQL HA

set -euo pipefail

# CONFIGURATION ================================================================
PRIMARY_IP="192.168.1.100"    # Current primary IP
REPLICA_IP="192.168.1.101"    # This server's IP
OTHER_REPLICAS=("192.168.1.102")  # Other replica IPs
LB_API="http://loadbalancer:8000/api/servers"
REPLICATOR_PWD="securepassword"

# Path configurations
PG_DATA="/var/lib/postgresql/14/main"
PG_VERSION="14"
TRIGGER_FILE="/var/lib/postgresql/failover.trigger"
LOCK_FILE="/tmp/postgres_failover.lock"
LOG_FILE="/var/log/postgresql/failover.log"

# FUNCTIONS ===================================================================
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> $LOG_FILE
}

check_primary() {
    # Check if primary is responding
    if ! pg_isready -h $PRIMARY_IP -p 5432 -t 3 >/dev/null 2>&1; then
        log "Primary node is down!"
        return 1
    fi
    
    # Verify replication status if we're a replica
    if [ -f $PG_DATA/standby.signal ]; then
        lag=$(psql -h $PRIMARY_IP -U replicator -t -c "SELECT EXTRACT(SECOND FROM (now() - pg_last_xact_replay_timestamp()))" | tr -d ' ')
        
        if [ -z "$lag" ] || [ "$lag" -gt 15 ]; then
            log "High replication lag detected: ${lag} seconds"
            return 1
        fi
    fi
    
    return 0
}

promote_replica() {
    log "Promoting this replica to primary"
    sudo -u postgres pg_ctl promote -D $PG_DATA
    
    # Wait for promotion to complete
    sleep 5
    
    # Create replication slots for other replicas
    for slot in replica1 replica2; do
        psql -c "SELECT pg_create_physical_replication_slot('$slot')"
    done
}

reconfigure_replicas() {
    for replica in "${OTHER_REPLICAS[@]}"; do
        log "Reconfiguring replica $replica"
        ssh -o StrictHostKeyChecking=no postgres@$replica "
            sudo systemctl stop postgresql
            rm -rf $PG_DATA/*
            sudo -u postgres pg_basebackup -h $REPLICA_IP -D $PG_DATA -U replicator -P -Xs -R -S replica1
            sudo systemctl start postgresql
        "
    done
}

update_load_balancer() {
    log "Updating load balancer configuration"
    curl -X PUT -d "server new-primary $REPLICA_IP:5432 check" $LB_API
}

cleanup_after_failover() {
    rm -f $TRIGGER_FILE
    log "Failover completed successfully"
}

# MAIN EXECUTION ==============================================================
main() {
    # Only run on replica nodes
    if [ ! -f $PG_DATA/standby.signal ]; then
        log "This is not a replica node. Exiting."
        exit 0
    fi
    
    # Check for existing failover in progress
    if [ -f $LOCK_FILE ]; then
        log "Failover already in progress. Exiting."
        exit 0
    fi
    
    touch $LOCK_FILE
    trap 'rm -f $LOCK_FILE' EXIT
    
    # Check primary status
    if check_primary; then
        log "Primary node is healthy"
        exit 0
    fi
    
    # Create trigger file if not exists
    if [ ! -f $TRIGGER_FILE ]; then
        touch $TRIGGER_FILE
        log "Trigger file created. Waiting for consensus..."
        sleep 20  # Wait for other nodes to detect failure
        
        # Verify consensus (simple majority)
        healthy_nodes=0
        for replica in "${OTHER_REPLICAS[@]}"; do
            if ssh postgres@$replica "test -f $TRIGGER_FILE"; then
                ((healthy_nodes++))
            fi
        done
        
        if [ $healthy_nodes -lt $((${#OTHER_REPLICAS[@]} / 2)) ]; then
            log "No consensus for failover. Aborting."
            rm -f $TRIGGER_FILE
            exit 1
        fi
    fi
    
    # Execute failover
    promote_replica
    reconfigure_replicas
    update_load_balancer
    cleanup_after_failover
}

# Run main function with logging
main >> $LOG_FILE 2>&1