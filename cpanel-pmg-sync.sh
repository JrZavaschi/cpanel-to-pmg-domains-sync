#!/bin/bash

# Proxmox Mail Gateway Credentials
PMG_IP="#"
PMG_USER="#" # user@pmg
PMG_PASSWORD="#"

# Transport Configuration
SYNC_TRANSPORTS=true                 # Set to false to disable transport synchronization
TARGET_HOST="#"            # Target server IP for mail routing
TARGET_PORT="25"                     # SMTP port
PROTOCOL="smtp"                      # Transport protocol (smtp/lmtp)
USE_MX="0"                           # Enable MX lookups (0 = false, 1 = true)
COMMENT="Added automatically by cPanel sync script"  # Comment for transport entries

# MX Verification Configuration
CHECK_MX=true                        # Set to false to disable MX verification
SERVER_IPS=("#")          # Array of server IPs to check against MX records

# Function to record messages with timestamp
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Function to check if a domain's MX records point to allowed IPs
check_mx() {
    local domain=$1
    local mx_hosts
    local mx_ip
    local apontando=false
    
    # Get MX records for the domain
    mx_hosts=$(dig +short MX "$domain" 2>/dev/null | awk '{print $NF}' | sed 's/\.$//')
    
    if [ -z "$mx_hosts" ]; then
        log "WARNING: No MX records found for $domain"
        return 1
    fi
    
    # Convert SERVER_IPS array to newline-separated string for grep
    local server_ips_string=$(printf "%s\n" "${SERVER_IPS[@]}")
    
    # Check each MX server
    for mx in $mx_hosts; do
        # If MX is already an IP, use it directly
        if [[ "$mx" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            mx_ip="$mx"
        else
            # Resolve MX hostname to IP
            mx_ip=$(dig +short A "$mx" 2>/dev/null | head -n1)
        fi
        
        if [ -n "$mx_ip" ] && echo "$server_ips_string" | grep -qw "$mx_ip"; then
            apontando=true
            log "MX record points to our server: $domain -> $mx ($mx_ip)"
            break
        fi
    done
    
    if [ "$apontando" = true ]; then
        return 0
    else
        log "MX verification failed for $domain"
        return 1
    fi
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

# 5. Filter domains based on MX verification if enabled
FILTERED_DOMAINS_CPANEL=""
if [ "$CHECK_MX" = true ]; then
    log "Verifying MX records for domains..."
    for domain in $DOMAINS_CPANEL; do
        if check_mx "$domain"; then
            FILTERED_DOMAINS_CPANEL="$FILTERED_DOMAINS_CPANEL $domain"
            log "Domain $domain passed MX verification"
        else
            log "Skipping domain $domain - MX records don't point to allowed IPs"
        fi
    done
    # Remove leading space and set the filtered domains
    DOMAINS_CPANEL=$(echo "$FILTERED_DOMAINS_CPANEL" | sed 's/^ *//')
fi

# 6. Add domains that are in cPanel but not in PMG
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
    
    # 7. Add transport entry for domain if it doesn't exist (only if transport sync is enabled)
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

# 8. Remove domains that are in PMG but not in cPanel (or fail MX check if enabled)
log "Syncing domains: removing obsolete..."
for domain in $DOMAINS_PMG; do
    # Check if domain should be removed (not in cPanel or fails MX check)
    if [ "$CHECK_MX" = true ]; then
        # If MX checking is enabled, verify if domain still points to our server
        if ! check_mx "$domain"; then
            log "Removing domain (MX check failed): $domain"
            RESPONSE_DELETE=$(curl -s -k -b "PMGAuthCookie=$TICKET" -H "CSRFPreventionToken: $CSRF_TOKEN" \
                -X DELETE \
                "https://$PMG_IP:8006/api2/json/config/domains/$domain")

            if echo "$RESPONSE_DELETE" | grep -q '"data":'; then
                log "SUCCESS: Domain $domain removed!"
            else
                log "ERROR removing $domain: $RESPONSE_DELETE"
            fi
        elif ! echo "$DOMAINS_CPANEL" | grep -q "^$domain$"; then
            log "Removing domain (not in cPanel): $domain"
            RESPONSE_DELETE=$(curl -s -k -b "PMGAuthCookie=$TICKET" -H "CSRFPreventionToken: $CSRF_TOKEN" \
                -X DELETE \
                "https://$PMG_IP:8006/api2/json/config/domains/$domain")

            if echo "$RESPONSE_DELETE" | grep -q '"data":'; then
                log "SUCCESS: Domain $domain removed!"
            else
                log "ERROR removing $domain: $RESPONSE_DELETE"
            fi
        else
            log "Domain $domain still exists in cPanel and passes MX check. Keeping."
        fi
    else
        # If MX checking is disabled, only check if domain exists in cPanel
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
    fi
done

# 9. Remove transport entries that are in PMG but not in cPanel (or fail MX check if enabled)
if [ "$SYNC_TRANSPORTS" = true ]; then
    log "Syncing transport entries: removing obsolete..."
    for domain in $TRANSPORTS_PMG; do
        # Check if transport should be removed (not in cPanel or fails MX check)
        if [ "$CHECK_MX" = true ]; then
            # If MX checking is enabled, verify if domain still points to our server
            if ! check_mx "$domain"; then
                log "Removing transport entry (MX check failed): $domain"
                RESPONSE_DELETE_TRANSPORT=$(curl -s -k -b "PMGAuthCookie=$TICKET" -H "CSRFPreventionToken: $CSRF_TOKEN" \
                    -X DELETE \
                    "https://$PMG_IP:8006/api2/json/config/transport/$domain")

                if echo "$RESPONSE_DELETE_TRANSPORT" | grep -q '"data":'; then
                    log "SUCCESS: Transport entry $domain removed!"
                else
                    log "ERROR removing transport entry $domain: $RESPONSE_DELETE_TRANSPORT"
                fi
            elif ! echo "$DOMAINS_CPANEL" | grep -q "^$domain$"; then
                log "Removing transport entry (not in cPanel): $domain"
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
        else
            # If MX checking is disabled, only check if domain exists in cPanel
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
        fi
    done
fi

log "Sync complete."