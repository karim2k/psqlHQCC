# PostgreSQL High Availability Solution

## Overview
Complete HA solution with:
- Automated failover (30-60s RTO)
- Synchronous replication
- Health monitoring

## Setup
1. Primary node:
```bash
sudo NODE_TYPE=primary bash setup_postgres_ha.sh