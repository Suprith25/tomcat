#!/usr/bin/env bash
#
# Automated Apache Tomcat install for Ubuntu/Debian instances.
#
#   git clone <this repo> && cd tomcat && sudo bash install-tomcat.sh
#
# Optional settings (environment variables):
#   TOMCAT_VERSION   Tomcat version to install      (default: latest Tomcat 11 release)
#   TOMCAT_PASSWORD  Password for the manager/admin (default: random, printed at the end)
#   TOMCAT_PORT      HTTP port                      (default: 8080)
#
# Safe to re-run: an existing install in /opt/tomcat is kept, not overwritten.

set -euo pipefail

TOMCAT_VERSION="${TOMCAT_VERSION:-latest}"
LATEST_MAJOR="11"            # release line used when TOMCAT_VERSION=latest
FALLBACK_VERSION="11.0.29"   # used if the latest version cannot be looked up
TOMCAT_PORT="${TOMCAT_PORT:-8080}"
TOMCAT_PASSWORD="${TOMCAT_PASSWORD:-}"
INSTALL_DIR="/opt/tomcat"
TOMCAT_USER="tomcat"
SERVICE_FILE="/etc/systemd/system/tomcat.service"
CREDS_FILE="/root/tomcat-credentials.txt"

log()  { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
fail() { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# --- Pre-flight -------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
    exec sudo -E bash "$0" "$@"
fi

command -v apt-get >/dev/null || fail "This script supports Ubuntu/Debian (apt) only."
command -v systemctl >/dev/null || fail "systemd is required."

[[ "$TOMCAT_VERSION" == "latest" || "$TOMCAT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || fail "TOMCAT_VERSION must be 'latest' or look like 11.0.29"
[[ "$TOMCAT_PORT" =~ ^[0-9]+$ ]] || fail "TOMCAT_PORT must be a number"
if [[ -n "$TOMCAT_PASSWORD" && ! "$TOMCAT_PASSWORD" =~ ^[A-Za-z0-9_.@%+=-]+$ ]]; then
    fail "TOMCAT_PASSWORD may only contain letters, digits and _ . @ % + = -"
fi

# --- Java -------------------------------------------------------------------

log "Installing Java and required packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y default-jdk wget curl tar

# --- Tomcat version ---------------------------------------------------------

if [[ "$TOMCAT_VERSION" == "latest" ]]; then
    log "Looking up the latest Tomcat $LATEST_MAJOR release"
    TOMCAT_VERSION="$(curl -fsS -m 30 "https://downloads.apache.org/tomcat/tomcat-$LATEST_MAJOR/" \
        | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+/' | tr -d 'v/' | sort -uV | tail -1 || true)"
    if [[ ! "$TOMCAT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        TOMCAT_VERSION="$FALLBACK_VERSION"
        log "Lookup failed - falling back to $TOMCAT_VERSION"
    fi
fi
log "Tomcat version: $TOMCAT_VERSION"

TOMCAT_MAJOR="${TOMCAT_VERSION%%.*}"
TARBALL="apache-tomcat-${TOMCAT_VERSION}.tar.gz"
BASE_URL="https://archive.apache.org/dist/tomcat/tomcat-${TOMCAT_MAJOR}/v${TOMCAT_VERSION}/bin"

# --- Java version -----------------------------------------------------------

# Detect JAVA_HOME instead of hardcoding a JDK version/architecture.
detect_java() {
    JAVA_HOME_DIR="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"
    [[ -x "$JAVA_HOME_DIR/bin/java" ]] || fail "Could not detect JAVA_HOME"
    JAVA_MAJOR="$("$JAVA_HOME_DIR/bin/java" -XshowSettings:properties -version 2>&1 \
        | awk -F'= ' '/java.specification.version/ {print $2}')"
    JAVA_MAJOR="${JAVA_MAJOR#1.}"
}
detect_java

# Tomcat 11 needs Java 17+; older distros ship Java 11 as default-jdk.
if [[ "$TOMCAT_MAJOR" -ge 11 && "${JAVA_MAJOR:-0}" -lt 17 ]]; then
    log "Java $JAVA_MAJOR is too old for Tomcat $TOMCAT_MAJOR - installing OpenJDK 17"
    apt-get install -y openjdk-17-jdk-headless
    JAVA_HOME_DIR="/usr/lib/jvm/java-17-openjdk-$(dpkg --print-architecture)"
    [[ -x "$JAVA_HOME_DIR/bin/java" ]] || fail "OpenJDK 17 not found in $JAVA_HOME_DIR"
    JAVA_MAJOR=17
fi
log "Using Java $JAVA_MAJOR, JAVA_HOME=$JAVA_HOME_DIR"

# --- Tomcat user ------------------------------------------------------------

if ! id "$TOMCAT_USER" >/dev/null 2>&1; then
    log "Creating system user '$TOMCAT_USER'"
    useradd --system --home-dir "$INSTALL_DIR" --shell /usr/sbin/nologin "$TOMCAT_USER"
fi

# --- Download and extract ---------------------------------------------------

if [[ -x "$INSTALL_DIR/bin/startup.sh" ]]; then
    log "Tomcat already present in $INSTALL_DIR - skipping download"
else
    log "Downloading Apache Tomcat $TOMCAT_VERSION"
    WORK_DIR="$(mktemp -d)"
    trap 'rm -rf "$WORK_DIR"' EXIT
    wget -q --show-progress -O "$WORK_DIR/$TARBALL" "$BASE_URL/$TARBALL"
    wget -q -O "$WORK_DIR/$TARBALL.sha512" "$BASE_URL/$TARBALL.sha512"

    log "Verifying checksum"
    expected="$(awk '{print $1}' "$WORK_DIR/$TARBALL.sha512")"
    actual="$(sha512sum "$WORK_DIR/$TARBALL" | awk '{print $1}')"
    [[ -n "$expected" && "$expected" == "$actual" ]] || fail "Checksum mismatch for $TARBALL"

    log "Extracting to $INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
    tar xzf "$WORK_DIR/$TARBALL" -C "$INSTALL_DIR" --strip-components=1
fi

# --- HTTP port --------------------------------------------------------------

if [[ "$TOMCAT_PORT" != "8080" ]]; then
    log "Setting HTTP port to $TOMCAT_PORT"
    sed -i "s/<Connector port=\"8080\" protocol=\"HTTP\/1.1\"/<Connector port=\"$TOMCAT_PORT\" protocol=\"HTTP\/1.1\"/" \
        "$INSTALL_DIR/conf/server.xml"
fi

# --- Manager / admin users --------------------------------------------------

USERS_FILE="$INSTALL_DIR/conf/tomcat-users.xml"
if grep -q 'install-tomcat.sh' "$USERS_FILE"; then
    log "Manager/admin users already configured - leaving them unchanged"
    USERS_CREATED=0
else
    log "Configuring manager and admin users"
    [[ -n "$TOMCAT_PASSWORD" ]] || TOMCAT_PASSWORD="$(openssl rand -hex 12)"
    sed -i '/<\/tomcat-users>/d' "$USERS_FILE"
    cat >> "$USERS_FILE" <<EOF
  <!-- added by install-tomcat.sh -->
  <role rolename="manager-gui" />
  <role rolename="manager-script" />
  <role rolename="admin-gui" />
  <user username="manager" password="$TOMCAT_PASSWORD" roles="manager-gui,manager-script" />
  <user username="admin" password="$TOMCAT_PASSWORD" roles="manager-gui,admin-gui" />
</tomcat-users>
EOF
    USERS_CREATED=1
    umask 077
    cat > "$CREDS_FILE" <<EOF
Tomcat users: manager, admin
Password:     $TOMCAT_PASSWORD
EOF
    umask 022
fi

# --- Remote access to Manager and Host Manager ------------------------------

log "Enabling remote access to Manager and Host Manager"
for app in manager host-manager; do
    ctx="$INSTALL_DIR/webapps/$app/META-INF/context.xml"
    # Replace the localhost-only allow list of the RemoteAddrValve with "any address".
    [[ -f "$ctx" ]] && sed -i 's/allow="127[^"]*"/allow=".*"/' "$ctx"
done

# --- Ownership and permissions ----------------------------------------------

log "Setting ownership and permissions"
chown -R "$TOMCAT_USER:$TOMCAT_USER" "$INSTALL_DIR"
chmod -R u+rwX,g+rX,o-rwx "$INSTALL_DIR"
chmod 750 "$INSTALL_DIR"/bin/*.sh

# --- systemd service --------------------------------------------------------

log "Creating systemd service"
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Apache Tomcat $TOMCAT_VERSION
After=network.target

[Service]
Type=forking
User=$TOMCAT_USER
Group=$TOMCAT_USER
Environment="JAVA_HOME=$JAVA_HOME_DIR"
Environment="JAVA_OPTS=-Djava.security.egd=file:///dev/urandom"
Environment="CATALINA_BASE=$INSTALL_DIR"
Environment="CATALINA_HOME=$INSTALL_DIR"
Environment="CATALINA_PID=$INSTALL_DIR/temp/tomcat.pid"
Environment="CATALINA_OPTS=-Xms512M -Xmx1024M -server -XX:+UseParallelGC"
PIDFile=$INSTALL_DIR/temp/tomcat.pid
ExecStart=$INSTALL_DIR/bin/startup.sh
ExecStop=$INSTALL_DIR/bin/shutdown.sh
SuccessExitStatus=143
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

log "Starting Tomcat"
systemctl daemon-reload
systemctl enable tomcat
systemctl restart tomcat

# --- Local firewall ---------------------------------------------------------

if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
    log "Opening port $TOMCAT_PORT in ufw"
    ufw allow "$TOMCAT_PORT/tcp"
fi

# --- Wait until it answers --------------------------------------------------

log "Waiting for Tomcat to respond on port $TOMCAT_PORT"
started=0
for _ in $(seq 1 30); do
    if curl -fsS -o /dev/null "http://localhost:$TOMCAT_PORT/"; then
        started=1
        break
    fi
    sleep 2
done

if [[ $started -ne 1 ]]; then
    systemctl status tomcat --no-pager || true
    fail "Tomcat did not respond within 60s. Check: journalctl -u tomcat and $INSTALL_DIR/logs/catalina.out"
fi

# --- Work out the address to show -------------------------------------------

# Cloud metadata service (AWS IMDSv2), falling back to the instance's own IP.
PUBLIC_IP=""
IMDS_TOKEN="$(curl -fsS -m 2 -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true)"
if [[ -n "$IMDS_TOKEN" ]]; then
    PUBLIC_IP="$(curl -fsS -m 2 -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
        "http://169.254.169.254/latest/meta-data/public-ipv4" 2>/dev/null || true)"
fi
[[ "$PUBLIC_IP" =~ ^[0-9.]+$ ]] || PUBLIC_IP="$(hostname -I | awk '{print $1}')"

cat <<EOF

============================================================
 Apache Tomcat $TOMCAT_VERSION is running.

 Home page:     http://$PUBLIC_IP:$TOMCAT_PORT/
 Manager app:   http://$PUBLIC_IP:$TOMCAT_PORT/manager/html
 Host manager:  http://$PUBLIC_IP:$TOMCAT_PORT/host-manager/html
EOF

if [[ $USERS_CREATED -eq 1 ]]; then
    cat <<EOF

 Users:         manager, admin
 Password:      $TOMCAT_PASSWORD
 (also saved in $CREDS_FILE, readable by root only)
EOF
else
    cat <<EOF

 Users:         manager, admin (password unchanged, see $CREDS_FILE)
EOF
fi

cat <<EOF

 If the page does not load, allow inbound TCP $TOMCAT_PORT in the
 instance's security group / cloud firewall.

 Service:       sudo systemctl {status|restart|stop} tomcat
 Logs:          $INSTALL_DIR/logs/catalina.out
============================================================
EOF
