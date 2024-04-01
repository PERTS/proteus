#!/bin/bash

# TODO
# * Add gitleaks to unpublished proteus repo
# * Lock down what gitleaks finds
# * Publish repo
# * Test script

# --- About this script --- #


# This is for setting up a GCE instance to run Canvas from scratch. It expects
# a postgres instance to be available in Cloud SQL, a large blank disk to be
# available at /dev/sdb, and several secrets to be defined in the Secrets
# Manager.

# Future scripts will want to separate actions that set up the attached disk so
# we can do a faster setup (e.g. without having to do yarn install).


# --- Secrets --- #

get_secret() {
  gcloud secrets versions access latest --secret="$1"
}
# Example use:
# CANVAS_DB_PASSWORD=$(get_secret "canvas-db-password")

# Script expect secrets to be set in the project:
# * canvas-db-password
# * canvas-lms-admin-password
# * canvas-security-key
# * canvas-rce-cipher-password
# * canvas-rce-secret
# * canvas-rce-key
# * flickr-api-key
# * youtube-api-key
# * canvas-perts-net-ssl-key
# * canvas-perts-net-bundle-crt
# * canvas-perts-net-crt
# * mandrill-api-key


# --- Exported variables --- #


# All variables are exported so they can be used when switching users and so
# they can affect running scripts.

export CANVAS_DISK=/var/canvas-disk
export CANVAS_LMS_DIR=$CANVAS_DISK/canvas
export CANVAS_RCE_DIR=$CANVAS_DISK/canvas-rce

export CANVAS_LMS_NODE_VER='18.19.1'
export CANVAS_RCE_NODE_VER='16.20.2'

# These affect `bundle exec rake db:initial_setup`
export CANVAS_LMS_ADMIN_EMAIL=admin@perts.net
export CANVAS_LMS_ADMIN_PASSWORD=$(get_secret canvas-lms-admin-password)
export CANVAS_LMS_ACCOUNT_NAME=PERTS
export CANVAS_LMS_STATS_COLLECTION=opt_out

export CANVAS_SECURITY_KEY=$(get_secret "canvas-security-key")
export CANVAS_DB_PASSWORD=$(get_secret "canvas-db-password")
export CANVAS_RCE_KEY=$(get_secret canvas-rce-key)
export CANVAS_RCE_SECRET=$(get_secret canvas-rce-secret)
export CIPHER_PASSWORD=$(get_secret canvas-rce-cipher-password)
export FLICKR_API_KEY=$(get_secret flickr-api-key)
export YOUTUBE_API_KEY=$(get_secret youtube-api-key)
export MANDRILL_API_KEY=$(get_secret mandrill-api-key)

# Affects all calls to `bundle exec`
export RAILS_ENV=production

# FYI port 5432 is standard for postgres connections
export CLOUD_SQL_INSTANCE="proteus-development:us-central1:development-01"


# --- Mount persistent disk --- #


# Format
mkfs.ext4 -m 0 -E lazy_itable_init=0,lazy_journal_init=0,discard /dev/sdb

# Mount location
mkdir -p $CANVAS_DISK

# Identify UUID of disk and add to /etc/fstab
cp /etc/fstab /etc/fstab.backup
uuid_regex='UUID="([0-9a-f-]+)'
disk_uuid=''
if [[ $(blkid /dev/sdb) =~ $uuid_regex ]]
then
    disk_uuid=${BASH_REMATCH[1]}
else
    echo "Can't identify UUID of persistent disk."
    exit 1
fi
cat << EOF >> /etc/fstab
UUID=$disk_uuid $CANVAS_DISK ext4 discard,defaults,nofail 0 2
EOF

# Mount
mount -o discard,defaults /dev/sdb $CANVAS_DISK

# Make accessible
chmod a+w $CANVAS_DISK


# --- OS packages --- #


add-apt-repository -y ppa:instructure/ruby
add-apt-repository -y ppa:chris-lea/redis-server
apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 561F9B9CAC40B2F7
sh -c 'echo deb https://oss-binaries.phusionpassenger.com/apt/passenger focal main > /etc/apt/sources.list.d/passenger.list'
curl -sL https://deb.nodesource.com/setup_18.x | sudo -E bash -

apt-get update

# TODO: should remove postgresql-12? Is there a difference between
# server and client? Looks like yes. The client only is 
# postgresql-client. So I'm removing postgresql-12.
apt-get install -y \
  software-properties-common \
  postgresql-client \
  ruby3.1 \
  ruby3.1-dev \
  zlib1g-dev \
  libxml2-dev \
  libsqlite3-dev \
  postgresql \
  libpq-dev \
  libxmlsec1-dev \
  libyaml-dev \
  libidn11-dev \
  curl \
  make \
  g++ \
  nodejs \
  apache2 \
  dirmngr \
  gnupg \
  apt-transport-https \
  ca-certificates \
  jq \
  libapache2-mod-passenger \
  redis-server

# Install `curtail`. Used for capturing process output to log files and
# guarantee the file doesn't grow forever.
apt install -y libtool
apt install -y automake
apt install -y autoconf
# Why use /opt? I don't know, it's confusing.
# https://unix.stackexchange.com/questions/11544/what-is-the-difference-between-opt-and-usr-local
git clone https://github.com/Comcast/Infinite-File-Curtailer /opt/curtail
(
  cd /opt/curtail
  libtoolize
  aclocal
  autoheader
  autoconf
  automake --add-missing
  ./configure
  make
  make install
  # The program should now be available in /usr/local/bin/curtail
)

# Install `yq` which allows modifying YAML files from the command line. The
# major advantage here is that it's aware of YAML syntax and escape sequences,
# so if we insert a password with a character that needs escaping, yq will
# handle it.
mkdir -p /opt/yq/bin
sudo wget -qO \
  /usr/local/bin/yq \
  https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
chmod +x /usr/local/bin/yq


# --- Create OS user --- #


adduser --disabled-password --gecos canvas canvasuser


# --- Connect to Cloud SQL instance of postgres --- #


# Use the Cloud Sql Auth Proxy, which will run in the background
# and use application default credentials to take care of all the
# authentication. All we need to know is that the specified
# instance will be available for connections locally on the
# postgres port, 5432.
curl -o /opt/cloud-sql-proxy \
  https://storage.googleapis.com/cloud-sql-connectors/cloud-sql-proxy/v2.0.0/cloud-sql-proxy.linux.amd64
chmod +x /opt/cloud-sql-proxy
# Requires service account running this instance to have iam role
# "roles/cloudsql.client"
touch /var/log/cloud-sql-proxy.log
/opt/cloud-sql-proxy $CLOUD_SQL_INSTANCE |
    curtail -s 100M /var/log/cloud-sql-proxy.log &


# --- Install languages: Node, Ruby --- #


npm install -g npm@latest
gem install bundler --version 2.5.6

npm install -g n
n install $CANVAS_LMS_NODE_VER
n install $CANVAS_RCE_NODE_VER
n exec $CANVAS_LMS_NODE_VER npm -g install yarn


# --- Switch users --- #


su canvasuser


# --- Clone PERTS code --- #


(
  cd $HOME
  git clone https://github.com/PERTS/proteus.git
)


# --- Clone application repos --- #


# TODO: change this to clone from our fork
git clone \
  --branch release/2024-03-27.90 \
  --depth 1 \
  https://github.com/instructure/canvas-lms.git \
  $CANVAS_LMS_DIR

git clone \
  --branch v1.25 \
  --depth 1 \
  https://github.com/instructure/canvas-rce-api.git \
  $CANVAS_RCE_DIR


# --- Install Canvas depedencies: Ruby --- #


(
  cd $CANVAS_LMS_DIR
  bundle config set --local path vendor/bundle
  bundle install
)


# --- Install Canvas dependencies: Node --- #


(
  cd $CANVAS_LMS_DIR
  mkdir .yarn-cache
  DISABLE_POSTINSTALL=1 n exec $CANVAS_LMS_NODE_VER yarn install \
    --cache-folder .yarn-cache
)


# --- Install Canvas RCE dependencies: Node  --- #


(
  cd $CANVAS_RCE_DIR
  n exec $CANVAS_RCE_NODE_VER npm install
)


# --- Copy Canvas source code modified by PERTS --- #

# Supports ?login_hint
# See https://github.com/instructure/canvas-lms/pull/2335
cp $HOME/proteus/canvas/app/controllers/login/oauth2_controller.rb \
  $CANVAS_LMS_DIR/app/controllers/login/oauth2_controller.rb
cp $HOME/proteus/canvas/app/models/authentication_provider/oauth2.rb \
  $CANVAS_LMS_DIR/app/models/authentication_provider/oauth2.rb


# --- Create config files --- #


# Many file can just be copied from their canvas-provided examples.
CONFIG_EXAMPLES="amazon_s3 delayed_jobs dynamic_settings file_store \
  external_migration"
for config in $CONFIG_EXAMPLES
do
  cp $CANVAS_LMS_DIR/config/$config.yml.example \
    $CANVAS_LMS_DIR/config/$config.yml
done

FILE="$CANVAS_LMS_DIR/config/dynamic_settings.yml"
# In this case the example file needs modification. Copy settings from
# "development" to "production". Force a delete of the "app-host" key b/c
# the example file is invalid as written and contains repeats of the key.
# Then updated it to the desired value.
yq -i '.production = .development' $FILE
yq -i 'del(.production.config.canvas["rich-content-service"]["app-host"])' $FILE
yq -i '.production.config.canvas["rich-content-service"]["app-host"] = "http://canvas.perts.net"' $FILE

# Copy in config files that PERTS stores in our repo.
PERTS_CONFIGS="domain cache_store redis outgoing_mail database \
  security vault_contents"
for config in $PERTS_CONFIGS
do
  cp $HOME/proteus/canvas/config/$config.yml $CANVAS_LMS_DIR/config/$config.yml
done


# --- Add secret values to config files --- #


FILE="$CANVAS_LMS_DIR/config/outgoing_mail.yml"
yq -i '.production.password = env(MANDRILL_API_KEY)' $FILE

FILE="$CANVAS_LMS_DIR/config/database.yml"
yq -i '.production.password = env(CANVAS_DB_PASSWORD)' $FILE

FILE="$CANVAS_LMS_DIR/config/security.yml"
yq -i '.production.encryption_key = env(CANVAS_SECURITY_KEY)' $FILE

FILE="$CANVAS_LMS_DIR/config/vault_contents.yml"
yq -i '.production.["app-canvas/data/secrets"].data.canvas_security.encryption_secret = env(CANVAS_RCE_KEY)' $FILE
yq -i '.production.["app-canvas/data/secrets"].data.canvas_security.signing_secret = env(CANVAS_RCE_SECRET)' $FILE

cp $HOME/proteus/canvas-rce/.env $CANVAS_RCE_DIR/.env
# Append secrets to .env
cat << EOF >> $CANVAS_RCE_DIR/.env
CIPHER_PASSWORD=$CIPHER_PASSWORD
ECOSYSTEM_SECRET=$CANVAS_RCE_SECRET
ECOSYSTEM_KEY=$CANVAS_RCE_KEY
FLICKR_API_KEY=$FLICKR_API_KEY
YOUTUBE_API_KEY=$YOUTUBE_API_KEY
EOF



# --- Set up db --- #


(
  cd $CANVAS_LMS_DIR
  mv db/migrate/20210823222355_change_immersive_reader_allowed_on_to_on.rb .
  mv db/migrate/20210812210129_add_singleton_column.rb \
    db/migrate/20111111214311_add_singleton_column.rb
  n exec $CANVAS_LMS_NODE_VER yarn gulp rev

  # affected by env vars at top of script.
  bundle exec rake db:initial_setup

  mv 20210823222355_change_immersive_reader_allowed_on_to_on.rb db/migrate/.
  bundle exec rake db:migrate
)



# --- Compile assets --- #


(
  cd $CANVAS_LMS_DIR
  mkdir -p log tmp/pids public/assets app/stylesheets/brandable_css_brands
  touch app/stylesheets/_brandable_variables_defaults_autogenerated.scss
  touch Gemfile.lock
  touch log/production.log
  # Hack to allow eslint to pass
  tmp=$(mktemp) && \
    jq '.eslintConfig.plugins += ["import"]' ui/engine/package.json > "$tmp" && \
    mv "$tmp" ui/engine/package.json
  # Run with `n exec` to make sure all the commands attached to this one
  # have access to `yarn`.
  n exec $CANVAS_LMS_NODE_VER bundle exec rake canvas:compile_assets
)


# --- Switch back to root --- #


exit


# --- Configure apache --- #


# Save the private key in a file and secure it
get_secret canvas-perts-net-ssl-key > /etc/ssl/private/canvas.perts.net.key
chmod 640 /etc/ssl/private/canvas.perts.net.key

# Save the other certificates. The "bundle" cert is also known as "intermediate"
# or a "chain file". The other one is the "primary" cert. Both of these are
# public.
get_secret canvas-perts-net-bundle-crt > /etc/ssl/certs/canvas.perts.net.bundle.crt
get_secret canvas-perts-net-crt > /etc/ssl/certs/canvas.perts.net.crt

# Copy over our config files.
cp $HOME/proteus/apache2/mods-available/passenger.conf \
  /etc/apache2/mods-available/passenger.conf
cp $HOME/apache2/sites-available/canvas.conf \
  /etc/apache2/sites-available/canvas.conf

a2enmod rewrite
a2enmod passenger
a2enmod ssl
# Enable `ProxyPass` directive, used by the Rich Content Editor.
a2enmod proxy_http
a2dissite 000-default
a2ensite canvas


# --- Protect sensitive files --- #


chmod 400 $CANVAS_LMS_DIR/config/*.yml


# --- Start services --- #


service apache2 reload

service redis-server start
systemctl enable redis-server

ln -s $CANVAS_LMS_DIR/script/canvas_init /etc/init.d/canvas_init
update-rc.d canvas_init defaults
/etc/init.d/canvas_init start

(
  cd $CANVAS_RCE_DIR
  mkdir $CANVAS_RCE_DIR/log
  # Run canvas-rce-api and send the output to a log file, limiting the total
  # size of the log file. The `curtail` tool is installed earlier in this
  # script.
  n exec $CANVAS_RCE_NODE_VER npm start |
    curtail -s 100M $CANVAS_RCE_DIR/log/production.log &
)
