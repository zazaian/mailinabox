#!/bin/bash

source setup/functions.sh

echo "Installing Mail-in-a-Box system management daemon..."

# DEPENDENCIES

# Install Python packages that are available from the Ubuntu
# apt repository:
# flask, yaml, dnspython, and dateutil are all for our Python 3 management daemon itself.
# duplicity does backups. python-pip is so we can 'pip install boto' for Python 2, for duplicity, so it can do backups to AWS S3.
apt_install python3-flask links duplicity libyaml-dev python3-dnspython python3-dateutil python-pip

# These are required to pip install cryptography.
apt_install build-essential libssl-dev libffi-dev python3-dev

# pip<6.1 + setuptools>=34 have a problem with packages that
# try to update setuptools during installation, like cryptography.
# See https://github.com/pypa/pip/issues/4253. The Ubuntu 14.04
# package versions are pip 1.5.4 and setuptools 3.3. When we
# install cryptography under those versions, it tries to update
# setuptools to version 34, which now creates the conflict, and
# then pip gets permanently broken with errors like
# "ImportError: No module named 'packaging'".
#
# Let's test for the error:
if ! python3 -c "from pkg_resources import load_entry_point" 2&> /dev/null; then
	# This system seems to be broken already.
	echo "Fixing broken pip and setuptools..."
	rm -rf /usr/local/lib/python3.4/dist-packages/{pkg_resources,setuptools}*
	apt-get install --reinstall python3-setuptools python3-pip python3-pkg-resources
fi
#
# The easiest work-around on systems that aren't already broken is
# to upgrade pip (to >=9.0.1) and setuptools (to >=34.1) individually
# before we install any package that tries to update setuptools.
hide_output pip3 install --upgrade pip
hide_output pip3 install --upgrade setuptools

# Install other Python 3 packages used by the management daemon.
# The first line is the packages that Josh maintains himself!
# NOTE: email_validator is repeated in setup/questions.sh, so please keep the versions synced.
# Force acme to be updated because it seems to need it after the
# pip/setuptools breakage (see above) and the ACME protocol may
# have changed (I got an error on one of my systems).
hide_output pip3 install --upgrade \
	rtyaml "email_validator>=1.0.0" "free_tls_certificates>=0.1.3" "exclusiveprocess" \
	"idna>=2.0.0" "cryptography>=1.0.2" acme boto psutil

# duplicity uses python 2 so we need to get the python 2 package of boto to have backups to S3.
# boto from the Ubuntu package manager is too out-of-date -- it doesn't support the newer
# S3 api used in some regions, which breaks backups to those regions.  See #627, #653.
hide_output pip2 install --upgrade boto

# CONFIGURATION

# Create a backup directory and a random key for encrypting backups.
mkdir -p $STORAGE_ROOT/backup
if [ ! -f $STORAGE_ROOT/backup/secret_key.txt ]; then
	$(umask 077; openssl rand -base64 2048 > $STORAGE_ROOT/backup/secret_key.txt)
fi


# Download jQuery and Bootstrap local files

# Make sure we have the directory to save to.
assets_dir=/usr/local/lib/mailinabox/vendor/assets
rm -rf $assets_dir
mkdir -p $assets_dir

# jQuery CDN URL
jquery_version=2.1.4
jquery_url=https://code.jquery.com

# Get jQuery
wget_verify $jquery_url/jquery-$jquery_version.min.js 43dc554608df885a59ddeece1598c6ace434d747 $assets_dir/jquery.min.js

# Bootstrap CDN URL
bootstrap_version=3.3.7
bootstrap_url=https://github.com/twbs/bootstrap/releases/download/v$bootstrap_version/bootstrap-$bootstrap_version-dist.zip

# Get Bootstrap
wget_verify $bootstrap_url e6b1000b94e835ffd37f4c6dcbdad43f4b48a02a /tmp/bootstrap.zip
unzip -q /tmp/bootstrap.zip -d /usr/local/lib/mailinabox/vendor/assets
mv /usr/local/lib/mailinabox/vendor/assets/bootstrap-$bootstrap_version-dist /usr/local/lib/mailinabox/vendor/assets/bootstrap
rm -f /tmp/bootstrap.zip

# Link the management server daemon into a well known location.
rm -f /usr/local/bin/mailinabox-daemon
ln -s `pwd`/management/daemon.py /usr/local/bin/mailinabox-daemon

# Create an init script to start the management daemon and keep it
# running after a reboot.
rm -f /etc/init.d/mailinabox
ln -s $(pwd)/conf/management-initscript /etc/init.d/mailinabox
hide_output update-rc.d mailinabox defaults

# Remove old files we no longer use.
rm -f /etc/cron.daily/mailinabox-backup
rm -f /etc/cron.daily/mailinabox-statuschecks

# Perform nightly tasks at 3am in system time: take a backup, run
# status checks and email the administrator any changes.

cat > /etc/cron.d/mailinabox-nightly << EOF;
# Mail-in-a-Box --- Do not edit / will be overwritten on update.
# Run nightly tasks: backup, status checks.
0 3 * * *	root	(cd `pwd` && management/daily_tasks.sh)
EOF

# Start the management server.
restart_service mailinabox
