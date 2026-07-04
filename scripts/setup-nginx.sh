#!/bin/bash
# Day 4 — Nginx (Ubuntu) + ModSecurity v3 (compiled connector) + OWASP CRS + Let's Encrypt + Rate Limiting
#
# nginx-module-modsecurity is not pre-built for Ubuntu in nginx.org's open-source repo.
# Instead: use Ubuntu's nginx 1.18.0, compile the ModSecurity-nginx connector from source
# against the matching nginx.org source tarball (--with-compat handles the ABI bridge).
# OWASP CRS is installed from Ubuntu's modsecurity-crs package.
#
# Usage (direct SSH):
#   DOMAIN=$(terraform output -raw domain_name)
#   scp -i .learningsteps_key scripts/setup-nginx.sh azureuser@$(terraform output -raw vm_public_ip):/tmp/
#   ssh -i .learningsteps_key azureuser@$(terraform output -raw vm_public_ip) \
#     "sudo bash /tmp/setup-nginx.sh $DOMAIN your@email.com"
#
# The script is idempotent — safe to run more than once.

set -euo pipefail

DOMAIN="${1:-${DOMAIN:-}}"
EMAIL="${2:-${EMAIL:-}}"

if [ -z "$DOMAIN" ] || [ -z "$EMAIL" ]; then
    echo "Usage: $0 <domain> <email>" >&2
    exit 1
fi

MODSEC_NGINX_VER="1.0.3"

echo "==> Domain : $DOMAIN"
echo "==> Email  : $EMAIL"
echo ""

# ── 1. Install packages ───────────────────────────────────────────────────────
echo "==> Installing nginx, ModSecurity v3 library, OWASP CRS, build tools..."
apt-get update -q
DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
    nginx \
    libmodsecurity3 \
    libmodsecurity-dev \
    modsecurity-crs \
    build-essential \
    libpcre3-dev \
    zlib1g-dev \
    libssl-dev \
    certbot \
    python3-certbot-nginx

# ── 2. Verify nginx was compiled with --with-compat ───────────────────────────
if ! nginx -V 2>&1 | grep -q 'with-compat'; then
    echo "ERROR: installed nginx was not built with --with-compat; dynamic module build will fail." >&2
    exit 1
fi

# ── 3. Build the ModSecurity-nginx connector dynamic module ───────────────────
echo "==> Building ModSecurity-nginx connector v${MODSEC_NGINX_VER}..."

NGINX_VER=$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
echo "    nginx version : ${NGINX_VER}"

MODULE_SO="/usr/lib/nginx/modules/ngx_http_modsecurity_module.so"

# Skip rebuild if already compiled (idempotent)
if [ ! -f "$MODULE_SO" ]; then
    # nginx source — must match installed version for compatible module headers
    if [ ! -d "/tmp/nginx-${NGINX_VER}" ]; then
        curl -fsSL "http://nginx.org/download/nginx-${NGINX_VER}.tar.gz" \
            | tar -xz -C /tmp
    fi

    # ModSecurity-nginx connector source
    if [ ! -d "/tmp/modsecurity-nginx-v${MODSEC_NGINX_VER}" ]; then
        curl -fsSL \
            "https://github.com/SpiderLabs/ModSecurity-nginx/releases/download/v${MODSEC_NGINX_VER}/modsecurity-nginx-v${MODSEC_NGINX_VER}.tar.gz" \
            | tar -xz -C /tmp
    fi

    # --with-compat links the module against the installed nginx binary's ABI
    cd "/tmp/nginx-${NGINX_VER}"
    ./configure --with-compat \
        --add-dynamic-module="/tmp/modsecurity-nginx-v${MODSEC_NGINX_VER}"
    make modules

    cp objs/ngx_http_modsecurity_module.so "$MODULE_SO"
    chmod 644 "$MODULE_SO"
    echo "    installed: ${MODULE_SO}"
else
    echo "    module already built, skipping."
fi

# ── 4. Load the module (Ubuntu uses modules-enabled/ convention) ──────────────
echo "==> Enabling ModSecurity module..."
echo "load_module ${MODULE_SO};" \
    > /etc/nginx/modules-enabled/50-mod-http-modsecurity.conf

# ── 5. ModSecurity configuration ──────────────────────────────────────────────
echo "==> Writing ModSecurity configuration..."
mkdir -p /etc/nginx/modsecurity

# Ubuntu's modsecurity-crs package installs modsecurity.conf-recommended to /etc/modsecurity/
# Copy to our nginx modsecurity dir and enable enforcement
if [ ! -f /etc/nginx/modsecurity/modsecurity.conf ]; then
    cp /etc/modsecurity/modsecurity.conf-recommended /etc/nginx/modsecurity/modsecurity.conf
    cp /etc/modsecurity/unicode.mapping /etc/nginx/modsecurity/unicode.mapping

    # Switch from detection-only to enforcement
    sed -i 's/SecRuleEngine DetectionOnly/SecRuleEngine On/' \
        /etc/nginx/modsecurity/modsecurity.conf

    # SecRequestBodyInMemoryLimit was removed in ModSecurity v3
    sed -i 's/^SecRequestBodyInMemoryLimit/#SecRequestBodyInMemoryLimit/' \
        /etc/nginx/modsecurity/modsecurity.conf
fi

# Ubuntu package layout:
#   /etc/modsecurity/crs/crs-setup.conf  — CRS tunables
#   /usr/share/modsecurity-crs/rules/    — CRS rule files
# IncludeOptional is Apache-only; ModSecurity v3 only supports Include
cat > /etc/nginx/modsecurity/main.conf << 'EOF'
Include /etc/nginx/modsecurity/modsecurity.conf
Include /etc/modsecurity/crs/crs-setup.conf
Include /usr/share/modsecurity-crs/rules/*.conf
EOF

# ── 6. Rate-limit zone ────────────────────────────────────────────────────────
cat > /etc/nginx/conf.d/rate_limit.conf << 'NGINX'
limit_req_zone $binary_remote_addr zone=api:10m rate=10r/s;
NGINX

# ── 7. FastAPI on localhost only ──────────────────────────────────────────────
echo "==> Binding FastAPI to 127.0.0.1..."
sed -i 's/--host 0\.0\.0\.0/--host 127.0.0.1/' /etc/systemd/system/learningsteps.service
systemctl daemon-reload
systemctl restart learningsteps

# ── 8. HTTP-only config (certbot ACME challenge) ──────────────────────────────
echo "==> Writing HTTP nginx config..."
mkdir -p /var/www/certbot

cat > /tmp/learningsteps-http.conf << 'NGINX'
server {
    listen 80;
    server_name DOMAIN_PLACEHOLDER;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
        try_files $uri =404;
    }

    location / {
        proxy_pass       http://127.0.0.1:8000;
        proxy_set_header Host      $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
NGINX
sed "s/DOMAIN_PLACEHOLDER/${DOMAIN}/g" /tmp/learningsteps-http.conf \
    > /etc/nginx/sites-available/learningsteps-http

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/learningsteps-http \
       /etc/nginx/sites-enabled/learningsteps

nginx -t && (systemctl start nginx 2>/dev/null || systemctl reload nginx)

# ── 9. TLS certificate via Let's Encrypt ─────────────────────────────────────
echo "==> Obtaining TLS certificate..."
certbot certonly \
    --webroot -w /var/www/certbot \
    -d "$DOMAIN" \
    --non-interactive \
    --agree-tos \
    -m "$EMAIL" \
    --keep-until-expiring

# ── 10. HTTPS config (TLS + ModSecurity + rate limiting) ──────────────────────
echo "==> Writing HTTPS nginx config..."

cat > /tmp/learningsteps-https.conf << 'NGINX'
server {
    listen 80;
    server_name DOMAIN_PLACEHOLDER;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name DOMAIN_PLACEHOLDER;

    ssl_certificate     /etc/letsencrypt/live/DOMAIN_PLACEHOLDER/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/DOMAIN_PLACEHOLDER/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    add_header Strict-Transport-Security "max-age=63072000" always;

    limit_req        zone=api burst=20 nodelay;
    limit_req_status 429;

    location / {
        modsecurity on;
        modsecurity_rules_file /etc/nginx/modsecurity/main.conf;

        proxy_pass       http://127.0.0.1:8000;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
NGINX

sed "s/DOMAIN_PLACEHOLDER/${DOMAIN}/g" /tmp/learningsteps-https.conf \
    > /etc/nginx/sites-available/learningsteps-https

ln -sf /etc/nginx/sites-available/learningsteps-https \
       /etc/nginx/sites-enabled/learningsteps

nginx -t && systemctl reload nginx

# ── 11. Auto-renewal ──────────────────────────────────────────────────────────
systemctl enable --now certbot.timer

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo " Setup complete!"
echo " API  : https://${DOMAIN}/docs"
echo " WAF  : ModSecurity v3 + OWASP CRS (connector v${MODSEC_NGINX_VER})"
echo "============================================================"
echo ""
echo "Test WAF (should return 403):"
echo "  curl -i 'https://${DOMAIN}/entries?id=1+UNION+SELECT+*+FROM+users'"
echo "  curl -i 'https://${DOMAIN}/entries?id=1%20UNION%20SELECT%20*%20FROM%20users'"
echo "  curl -i 'https://${DOMAIN}/entries?q=%3Cscript%3Ealert(1)%3C%2Fscript%3E'"
echo ""
echo "Test rate limiting (429s after ~20 rapid requests):"
echo "  for i in \$(seq 1 30); do curl -sf -o /dev/null -w '%{http_code}\\n' https://${DOMAIN}/entries; done"
echo ""
echo "ModSecurity audit log:"
echo "  tail -f /var/log/modsec_audit.log"
