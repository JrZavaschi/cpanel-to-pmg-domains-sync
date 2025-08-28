#!/bin/bash

# Proxmox Mail Gateway Credentials
PMG_IP="#"
PMG_USER="#" # user@pmg
PMG_PASSWORD="#"

# Transport Configuration
SYNC_TRANSPORTS=true  # Set to false to disable transport synchronization
TARGET_HOST="#"
TARGET_PORT="25"
PROTOCOL="smtp"
USE_MX="1" # 1 to use MX records, 0 to use TARGET_HOST
COMMENT="Added automatically by cPanel sync script"

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

# 4. Get PMG transport list (only if transport sync is enabled)
if [ "$SYNC_TRANSPORTS" = true ]; then
    log "Fetching transport entries from PMG..."
    RESPONSE_TRANSPORTS_PMG=$(curl -s -k -b "PMGAuthCookie=$TICKET" -H "CSRFPreventionToken: $CSRF_TOKEN" \
        -X GET \
        "https://$PMG_IP:8006/api2/json/config/transport")

    # Extract transport domains from PMG response
    TRANSPORTS_PMG=$(echo "$RESPONSE_TRANSPORTS_PMG" | grep -o '"domain":"[^"]*' | cut -d'"' -f4 | sort)

    if [ -z "$TRANSPORTS_PMG" ]; then
        log "No transport entries found in PMG."
        TRANSPORTS_PMG=""
    fi
fi

# 5. Add domains that are in cPanel but not in PMG
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
    
    # 6. Add transport entry for domain if it doesn't exist (only if transport sync is enabled)
    if [ "$SYNC_TRANSPORTS" = true ]; then
        if ! echo "$TRANSPORTS_PMG" | grep -q "^$domain$"; then
            log "Adding transport entry for: $domain"
            RESPONSE_TRANSPORT=$(curl -s -k -b "PMGAuthCookie=$TICKET" -H "CSRFPreventionToken: $CSRF_TOKEN" \
                -X POST \
                -H "Content-Type: application/json" \
                -d "{\"domain\":\"$domain\", \"host\":\"$TARGET_HOST\", \"port\":$TARGET_PORT, \"protocol\":\"$PROTOCOL\", \"use_mx\":$USE_MX, \"comment\":\"$COMMENT\"}" \
                "https://$PMG_IP:8006/api2/json/config/transport")
                
            if echo "$RESPONSE_TRANSPORT" | grep -q '"data":'; then
                log "SUCCESS: Transport entry for $domain added!"
            elif echo "$RESPONSE_TRANSPORT" | grep -q 'already exists'; then
                log "NOTICE: Transport entry for $domain already exists"
            else
                log "ERROR adding transport for $domain: $RESPONSE_TRANSPORT"
            fi
        else
            log "Transport entry for $domain already exists. Skipping."
        fi
    fi
done

# 7. Remove domains that are in PMG but not in cPanel
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

# 8. Remove transport entries that are in PMG but not in cPanel (only if transport sync is enabled)
if [ "$SYNC_TRANSPORTS" = true ]; then
    log "Syncing transport entries: removing obsolete..."
    for domain in $TRANSPORTS_PMG; do
        if ! echo "$DOMAINS_CPANEL" | grep -q "^$domain$"; then
            log "Removing transport entry: $domain"
            RESPONSE_DELETE_TRANSPORT=$(curl -s -k -b "PMGAuthCookie=$TICKET" -H "CSRFPreventionToken: $CSRF_TOKEN" \
                -X DELETE \
                "https://$PMG_IP:8006/api2/json/config/transport/$domain")

            if echo "$RESPONSE_DELETE_TRANSPORT" | grep -q '"data":'; then
                log "SUCCESS: Transport entry $domain removed!"
            else
                log "ERROR removing transport entry $domain: $RESPONSE_DELETE_TRANSPORT"
            fi
        else
            log "Transport entry $domain still needed. Keeping."
        fi
    done
fi

log "Sync complete."