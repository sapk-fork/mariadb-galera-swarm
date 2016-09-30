#!/bin/bash -ex

if [ -z "$XTRABACKUP_PASSWORD" ]; then
	echo "XTRABACKUP_PASSWORD not set"
	exit 1
fi

CLUSTERCHECK_PASSWORD=$(echo "$XTRABACKUP_PASSWORD" | sha256sum | awk '{print $1;}')
GCOMM=""
CLUSTER_NAME=${CLUSTER_NAME:-cluster}
MYSQL_MODE_ARGS=""

if [ -z "$NODE_ADDRESS" ]; then
	# Support Weave/Kontena
	NODE_ADDRESS=$(ip addr | awk '/inet/ && /ethwe/{sub(/\/.*$/,"",$2); print $2}')
elif [[ "$NODE_ADDRESS" =~ [a-zA-Z][a-zA-Z0-9:]+ ]]; then
	# Support Docker Swarm Mode (e.g. eth0)
	NODE_ADDRESS=$(ip addr | awk "/inet/ && / $NODE_ADDRESS\$/{sub(/\\/.*$/,\"\",\$2); print \$2}" | head -n 1)
fi
if ! expr "$NODE_ADDRESS" : '^[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*$' >/dev/null; then
	echo "Could not determine NODE_ADDRESS: $NODE_ADDRESS"
	exit 1
fi

case "$1" in
	seed)
		# bootstrapping
		if [ ! -f /var/lib/mysql/skip-cluster-bootstrapping ]; then
			if [ -z "$MYSQL_ROOT_PASSWORD" ]; then
				MYSQL_ROOT_PASSWORD=$(openssl rand -base64 32)
				echo "MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD"
			fi

			cat >/tmp/bootstrap.sql <<EOF
CREATE USER 'xtrabackup'@'127.0.0.1' IDENTIFIED BY '$XTRABACKUP_PASSWORD';
GRANT RELOAD,LOCK TABLES,REPLICATION CLIENT ON *.* TO 'xtrabackup'@'127.0.0.1';
CREATE USER 'clustercheck'@'127.0.0.1' IDENTIFIED BY '$CLUSTERCHECK_PASSWORD';
GRANT PROCESS ON *.* TO 'clustercheck'@'127.0.0.1';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%';
UPDATE mysql.user SET Password=PASSWORD('$MYSQL_ROOT_PASSWORD') WHERE User='root';
EOF

			if [ "$MYSQL_DATABASE" ]; then
				echo "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\` ;" >> /tmp/bootstrap.sql
			fi

			if [ "$MYSQL_USER" -a "$MYSQL_PASSWORD" ]; then
				echo "CREATE USER '$MYSQL_USER'@'%' IDENTIFIED BY '$MYSQL_PASSWORD' ;" >> /tmp/bootstrap.sql
				if [ "$MYSQL_DATABASE" ]; then
					echo "GRANT ALL ON \`$MYSQL_DATABASE\`.* TO '$MYSQL_USER'@'%' ;" >> /tmp/bootstrap.sql
				fi
			fi
			echo "FLUSH PRIVILEGES;" >> /tmp/bootstrap.sql

			MYSQL_MODE_ARGS+=" --init-file=/tmp/bootstrap.sql"
			touch /var/lib/mysql/skip-cluster-bootstrapping

			echo -n "Bootstrapping cluster. "
		fi

		MYSQL_MODE_ARGS+=" --wsrep-new-cluster"

		shift 1
		echo "Starting seed node"
		;;
	node)
		if [ -z "$2" ]; then
			echo "Missing master node address"
			exit 1
		fi
		ADDRS="$2"
		SEP=""
		for ADDR in ${ADDRS//,/ }; do
			if expr "$ADDR" : '^[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*$' >/dev/null; then
				GCOMM+="$SEP$ADDR"
			else
				GCOMM+="$SEP$(host -t A "$ADDR" | awk '/has address/{ print $4 }' | paste -sd ",")"
			fi
			if [ -n "$GCOMM" ]; then
				SEP=,
			fi
		done

		shift 2
		echo "Starting node, connecting to gcomm://$GCOMM"
		;;
	*)
		echo "seed|node <othernode>,..."
		exit 1
esac

# start processes
set +e -m

function shutdown () {
	echo Shutting down
	test -s /var/run/mysql/mysqld.pid && kill -TERM $(cat /var/run/mysql/mysqld.pid)
}
trap shutdown TERM INT

galera-healthcheck -password="$CLUSTERCHECK_PASSWORD" -pidfile=/var/run/galera-healthcheck.pid -user clustercheck &
gosu mysql mysqld.sh --console \
	$MYSQL_MODE_ARGS \
	--wsrep_cluster_name="$CLUSTER_NAME" \
	--wsrep_cluster_address="gcomm://$GCOMM" \
	--wsrep_node_address="$NODE_ADDRESS:4567" \
	--wsrep_sst_auth="xtrabackup:$XTRABACKUP_PASSWORD" \
	--default-time-zone="+00:00" \
	"$@" 2>&1 &
wait $!
RC=$?

test -s /var/run/galera-healthcheck.pid && kill $(cat /var/run/galera-healthcheck.pid)

exit $RC