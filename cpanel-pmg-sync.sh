#!/bin/bash

# Proxmox Mail Gateway Credentials
PMG_IP="#"
PMG_USER="#" # user@pmg
PMG_PASSWORD="#"

# Function to record messages with timestamp
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# 1. Get authentication ticket
log "Getting authentication ticket from PMG..."
AUTH_RESPONSE=$(curl -s -k -X POST \
    --data-urlencode "username=$PMG_USER" \
    --data-urlencode "password=$PMG_PASSWORD" \
    "https://$PMG_IP:8006/api2/json/access/ticket")

# Check authentication
if ! echo "$AUTH_RESPONSE" | grep -q '"data":'; then
    log "ERROR: Authentication failed. Check credentials."
    exit 1
fi

# Extract ticket and CSRF token
TICKET=$(echo "$AUTH_RESPONSE" | grep -o '"ticket":"[^"]*' | cut -d'"' -f4)
CSRF_TOKEN=$(echo "$AUTH_RESPONSE" | grep -o '"CSRFPreventionToken":"[^"]*' | cut -d'"' -f4)

if [ -z "$TICKET" ]; then
    log "ERROR: Failed to get authentication ticket"
    exit 1
fi

# 2. Get cPanel domain list
log "Fetching domains from cPanel..."
DOMAINS_CPANEL=$(whmapi1 listaccts | grep 'domain:' | awk '{print $2}' | grep -v '^0$' | sort)

if [ -z "$DOMAINS_CPANEL" ]; then
    log "No domains found in cPanel."
fi

# 3. Get PMG domain list
log "Fetching domains from PMG..."
RESPONSE_DOMAINS_PMG=$(curl -s -k -b "PMGAuthCookie=$TICKET" -H "CSRFPreventionToken: $CSRF_TOKEN" \
    -X GET \
    "https://$PMG_IP:8006/api2/json/config/domains")

# Extract domains from PMG response
DOMAINS_PMG=$(echo "$RESPONSE_DOMAINS_PMG" | grep -o '"domain":"[^"]*' | cut -d'"' -f4 | sort)

if [ -z "$DOMAINS_PMG" ]; then
    log "No domains found in PMG."
    DOMAINS_PMG=""
fi

# 4. Add domains that are in cPanel but not in PMG
log "Syncing domains: adding new ones..."
for domain in $DOMAINS_CPANEL; do
    if ! echo "$DOMAINS_PMG" | grep -q "^$domain$"; then
        log "Adding domain: $domain"
        RESPONSE_ADD=$(curl -s -k -b "PMGAuthCookie=$TICKET" -H "CSRFPreventionToken: $CSRF_TOKEN" \
            -X POST \
            -H "Content-Type: application/json" \
            -d "{\"domain\":\"$domain\"}" \
            "https://$PMG_IP:8006/api2/json/config/domains")

        if echo "$RESPONSE_ADD" | grep -q '"data":'; then
            log "SUCCESS: Domain $domain added!"
        elif echo "$RESPONSE_ADD" | grep -q 'already exists'; then
            log "NOTICE: Domain $domain already exists"
        else
            log "ERROR adding $domain: $RESPONSE_ADD"
        fi
    else
        log "Domain $domain already exists in PMG. Skipping."
    fi
done

# 5. Remove domains that are in PMG but not in cPanel
log "Syncing domains: removing obsolete..."
for domain in $DOMAINS_PMG; do
    if ! echo "$DOMAINS_CPANEL" | grep -q "^$domain$"; then
        log "Removing domain: $domain"
        RESPONSE_DELETE=$(curl -s -k -b "PMGAuthCookie=$TICKET" -H "CSRFPreventionToken: $CSRF_TOKEN" \
            -X DELETE \
            "https://$PMG_IP:8006/api2/json/config/domains/$domain")

        if echo "$RESPONSE_DELETE" | grep -q '"data":'; then
            log "SUCCESS: Domain $domain removed!"
        else
            log "ERROR removing $domain: $RESPONSE_DELETE"
        fi
    else
        log "Domain $domain still exists in cPanel. Keeping."
    fi
done

log "Sync complete."