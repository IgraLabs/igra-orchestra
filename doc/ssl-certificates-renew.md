## SSL Certificate Management

The HTTPS services use Let's Encrypt certificates that are valid for 90 days and need to be renewed before expiry.

### Automatic Certificate Renewal

1. Create a renewal script `renew_certs.sh`:

```bash
#!/bin/bash

# Navigate to your docker compose project directory
cd ~/igra-orchestra

# Renew certificates
docker compose run --rm certbot renew

# Reload Nginx to pick up the new certificates
docker compose exec nginx nginx -s reload

echo "Certificate renewal process completed at $(date)"
```

2. Make the script executable:
```bash
chmod +x renew_certs.sh
```

3. Set up a cron job to run the script twice daily:
```bash
# Run crontab -e and add this line:
0 3,15 * * * /path/to/renew_certs.sh >> /var/log/cert_renewal.log 2>&1
```

### Manual Certificate Renewal

If needed, you can manually renew the certificate:

```bash
# Navigate to your docker compose project directory
cd /path/to/igra-orchestra

# Renew certificates
docker compose run --rm certbot renew

# Reload Nginx to pick up the new certificates
docker compose exec nginx nginx -s reload
```

### Troubleshooting SSL Configuration

1. Check certificate expiration:
```bash
docker compose exec nginx openssl x509 -dates -noout -in /etc/letsencrypt/live/devnet.igralabs.com/fullchain.pem
```

2. If SSL configuration files are missing:
```bash
# Create ssl-conf directory
mkdir -p ssl-conf

# Create options-ssl-nginx.conf
cat > ssl-conf/options-ssl-nginx.conf << 'EOF'
ssl_session_cache shared:le_nginx_SSL:10m;
ssl_session_timeout 1440m;
ssl_session_tickets off;
ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers off;
ssl_ciphers "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384";
EOF

# Create ssl-dhparams.pem
openssl dhparam -out ssl-conf/ssl-dhparams.pem 2048

# Update docker compose.yml to mount these files
# Add these lines to the nginx service volumes:
# - ./ssl-conf/options-ssl-nginx.conf:/etc/letsencrypt/options-ssl-nginx.conf:ro
# - ./ssl-conf/ssl-dhparams.pem:/etc/letsencrypt/ssl-dhparams.pem:ro
```

3. If certificates have expired, request new ones:
```bash
docker compose run --rm certbot certonly --webroot --webroot-path /var/www/certbot \
  -d devnet.igralabs.com \
  --email igor@igralabs.com \
  --agree-tos --no-eff-email \
  --rsa-key-size 4096 \
  --force-renewal
```
