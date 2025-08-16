# cPanel to Proxmox Mail Gateway Sync Script

Automatically synchronizes domains between cPanel/WHM and Proxmox Mail Gateway (PMG). Adds new domains to PMG and removes domains that no longer exist in cPanel.

## Features

- Automatic domain synchronization
- Bi-directional sync (adds missing domains, removes obsolete ones)
- Detailed logging with timestamps
- Error handling for common issues
- API-based integration
- Lightweight and efficient

## Requirements

- cPanel/WHM server
- Proxmox Mail Gateway (PMG) with API access
- `curl` installed on cPanel server
- WHM API access (requires root privileges)

## Configuration

Edit the script with your PMG credentials:

```bash
PMG_IP="your.pmg.server.ip"          # Proxmox Mail Gateway IP
PMG_USER="syncuser@pmg"              # PMG API user
PMG_PASSWORD="your_secure_password"  # PMG API password
```

Create a dedicated PMG user with permissions:

- Domains: Allocate
- Domains: Modify

## Installation

Save the script as `/usr/local/bin/cpanel-pmg-sync.sh`:

```bash
curl -o /usr/local/bin/cpanel-pmg-sync.sh https://raw.githubusercontent.com/JrZavaschi/cpanel-to-pmg-domains-sync/main/cpanel-pmg-sync.sh
```

Make it executable:

```bash
chmod +x /usr/local/bin/cpanel-pmg-sync.sh
```

Create log file:

```bash
touch /var/log/cpanel-pmg-sync.log
chmod 644 /var/log/cpanel-pmg-sync.log
```

Edit the script with your credentials:

```bash
nano /usr/local/bin/cpanel-pmg-sync.sh
```

## Usage

### Manual Run

```bash
/usr/local/bin/cpanel-pmg-sync.sh
```

### Cron Job (Recommended)

Add to root's crontab (run every 30 minutes):

```bash
crontab -e
```

Add this line:

```bash
*/30 * * * * /usr/local/bin/cpanel-pmg-sync.sh >> /var/log/cpanel-pmg-sync.log 2>&1
```

### Log Monitoring

```bash
tail -f /var/log/cpanel-pmg-sync.log
```

## Sample Output

```text
[2025-08-16 10:30:00] Getting authentication ticket from PMG...
[2025-08-16 10:30:01] Fetching domains from cPanel...
[2025-08-16 10:30:03] Fetching domains from PMG...
[2025-08-16 10:30:05] Syncing domains: adding new ones...
[2025-08-16 10:30:05] Adding domain: newdomain.com
[2025-08-16 10:30:06] SUCCESS: Domain newdomain.com added!
[2025-08-16 10:30:06] Domain existing.com already exists in PMG. Skipping.
[2025-08-16 10:30:06] Syncing domains: removing obsolete...
[2025-08-16 10:30:06] Removing domain: olddomain.com
[2025-08-16 10:30:07] SUCCESS: Domain olddomain.com removed!
[2025-08-16 10:30:07] Domain current.com still exists in cPanel. Keeping.
[2025-08-16 10:30:07] Sync complete.
```

## Security Notes

- Use a dedicated PMG API user with minimal permissions
- Store credentials securely:
  - Avoid committing passwords to version control
  - Consider using environment variables for credentials
- Restrict script permissions:

```bash
chmod 700 /usr/local/bin/cpanel-pmg-sync.sh
```

- Regularly rotate API credentials
- Limit PMG user permissions to only required operations

## Troubleshooting

| Error                   | Solution                                                     |
|------------------------|--------------------------------------------------------------|
| Authentication failed  | Verify PMG user credentials and permissions                  |
| Connection refused     | Check firewall rules between servers (port 8006)             |
| Domain not syncing     | Check for special characters in domain names                 |
| Permission denied      | Ensure script is run as root                                 |
| No domains found       | Verify WHMAPI access and account status                      |
| CSRF token missing     | Check authentication process and network connectivity        |

## Contributing

Pull requests are welcome! Please follow these guidelines:

- Maintain consistent coding style
- Include comments for new features
- Update documentation accordingly
- Test changes thoroughly
- Keep commits atomic and well-described

## License

MIT License

Copyright (c) [year] [fullname]

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Support

For assistance, please open an issue on GitHub.

> Note: Replace placeholders like `your.pmg.server.ip`, `syncuser@pmg`, and `your_secure_password` with your actual credentials before use. Also update the GitHub URLs to point to your actual repository.
