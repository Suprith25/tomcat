# tomcat

Automated Apache Tomcat installation for Ubuntu/Debian instances.

## Quick start

On a freshly launched instance:

```bash
git clone <this-repo-url> tomcat
cd tomcat
sudo bash install-tomcat.sh
```

When the script finishes it prints the URL to open in your browser and the
manager/admin password.

**Before you browse to it:** allow inbound TCP **8080** in the instance's
security group (or cloud firewall). The script cannot do that from inside the
instance.

## What the script does

1. Installs Java (`default-jdk`, or OpenJDK 17 if the default is too old) and
   detects `JAVA_HOME` automatically.
2. Looks up the latest Tomcat 11 release, downloads it, verifies its SHA-512 checksum and extracts it to `/opt/tomcat`.
3. Creates a dedicated `tomcat` system user and runs the service as that user.
4. Adds `manager` and `admin` users to `conf/tomcat-users.xml`.
5. Enables remote access to the Manager and Host Manager apps.
6. Creates, enables and starts the `tomcat` systemd service.
7. Waits until Tomcat responds and prints the access URLs.

## Options

Set these as environment variables:

| Variable          | Default            | Purpose                         |
|-------------------|--------------------|---------------------------------|
| `TOMCAT_VERSION`  | latest Tomcat 11   | Tomcat version to install       |
| `TOMCAT_PASSWORD` | random, printed    | Password for `manager`/`admin`  |
| `TOMCAT_PORT`     | `8080`             | HTTP port                       |

Example:

```bash
sudo TOMCAT_VERSION=10.1.61 TOMCAT_PASSWORD='MyPass123' bash install-tomcat.sh
```

## Managing the service

```bash
sudo systemctl status tomcat
sudo systemctl restart tomcat
sudo tail -f /opt/tomcat/logs/catalina.out
```

The password is also saved in `/root/tomcat-credentials.txt` (root only).

The original manual steps are kept in `tomcat installation steps` for reference.
