#!/bin/bash

DB_CONFIG=/etc/openvpn/scripts/config.sh
. $DB_CONFIG

RESOURCE_PORT=()
RESOURCE_GROUP=()
SQUID_DIR="/etc/squid"
SQUID_DIR_CONF="$SQUID_DIR/squid.conf.d"
SQUID_PEER_CONF="$SQUID_DIR_CONF/cache_peers.conf"
SQUID_DSTDOMAIN="$SQUID_DIR_CONF/acl_dstdomains.conf"
SQUID_PORTS="$SQUID_DIR_CONF/acl_ports.conf"
SQUID_GROUP="$SQUID_DIR_CONF/acl_user_roles.conf"
SQUID_ACCESS="$SQUID_DIR_CONF/http_access.conf"
SQUID_CACHE_ACCESS="$SQUID_DIR_CONF/never_direct.conf"

read -p "What name would you like to use for your resource? " RESOURCE_NAME

echo
echo "Your available gateways are:"
mysql -h$HOST -P$PORT -u$USER -p$PASS $DB -se "select gateway_name,gateway_ip from gateway where gateway_ip != '$GATEWAY_GATEWAY'"
echo
read -p "Enter the IP of the gateway that will be protecting this resource?  Enter DIRECT if this resource does not have a gateway: " GATEWAY_ADDRESS
if [ "$GATEWAY_ADDRESS" != `mysql -h$HOST -P$PORT -u$USER -p$PASS $DB -sNe "select gateway_ip from gateway where gateway_ip='$GATEWAY_ADDRESS'"` ]; then
  echo "Value entered does not exist, using DIRECT"
  GATEWAY_ADDRESS="DIRECT"
fi

echo
read -r -p "Will this be a Web Resource or TCP Resource ['web/tcp'] " RESOURCE_TYPE
case "$RESOURCE_TYPE" in
    [wW][eE][bB]|[wW]) 
        RESOURCE_TYPE=web
        ;;
    [tT][cC][pP]|[tT])
        RESOURCE_TYP=tcp
        ;;
    *)
        echo "You did not enter a value. Exiting."
        exit
        ;;
esac

echo
read -p "What is the DOMAIN or IP of your resource? " RESOURCE_DOMAIN

function resourcePorts {
  echo
  read -p "Enter a new port for this resource? " newPort
  RESOURCE_PORT+=("$newPort")
  read -r -p "Would you you like to add another port? [Y/n] " addPort
  case "$addPort" in
    [yY][eE][sS]|[yY]) 
        resourcePorts
        ;;
    *)
        echo ""
        ;;
  esac
}

function resourceGroups {
  echo
  read -p "Enter a new group for this resource? " newPort
  RESOURCE_GROUP+=("$newPort")
  read -r -p "Would you you like to add another group? [Y/n] " addGroup
  case "$addGroup" in
    [yY][eE][sS]|[yY])
        resourceGroups
        ;;
    *)
        echo ""
        ;;
  esac
}

function insertDB {
  if [ `mysql -h$HOST -P$PORT -u$USER -p$PASS $DB -sNe "select count(*) from sdp_resource where resource_name='$RESOURCE_NAME' and resource_domain='$RESOURCE_DOMAIN' and resource_type='$RESOURCE_TYPE'"` -lt 1 ]; then
    mysql -h$HOST -P$PORT -u$USER -p$PASS $DB -e "insert into sdp_resource (resource_name, resource_domain, resource_type, resource_enabled, resource_start_date, resource_end_date) values ('$RESOURCE_NAME','$RESOURCE_DOMAIN','$RESOURCE_TYPE','yes',now(),now() + INTERVAL 50 year)"
  fi
  ##Insert Groups
  for name in "${RESOURCE_GROUP[@]}"
  do
    if [ `mysql -h$HOST -P$PORT -u$USER -p$PASS $DB -sNe "select count(*) from ugroup where ugroup_name = '$name'"` -lt 1 ]; then
      mysql -h$HOST -P$PORT -u$USER -p$PASS $DB -e "insert into ugroup (ugroup_name, ugroup_description) values ('$name','$name')"
    fi
    mysql -h$HOST -P$PORT -u$USER -p$PASS $DB -e "insert into sdp_resource_group (resource_id,ugroup_id) values ((select resource_id from sdp_resource where resource_name='$RESOURCE_NAME'),(select ugroup_id from ugroup where ugroup_name='$name'))"
  done
  ##Insert Ports
  for number in "${RESOURCE_PORT[@]}"
  do
    if [ `mysql -h$HOST -P$PORT -u$USER -p$PASS $DB -sNe "select count(*) from sdp_port where port_number = '$number'"` -lt 1 ]; then
      mysql -h$HOST -P$PORT -u$USER -p$PASS $DB -e "insert into sdp_port (port_name,port_number,port_protocol) values ('$number','$number','tcp')"
    fi
    mysql -h$HOST -P$PORT -u$USER -p$PASS $DB -e "insert into sdp_resource_port (resource_id,port_id) values ((select resource_id from sdp_resource where resource_name='$RESOURCE_NAME'),(select port_id from sdp_port where port_number='$number'))"
  done
  ##Gateway Association
  if [ "$GATEWAY_ADDRESS" != "DIRECT" ]; then
    mysql -h$HOST -P$PORT -u$USER -p$PASS $DB -e "insert into sdp_gateway_resource (gateway_id,resource_id) values ((select gateway_id from gateway where gateway_ip='$GATEWAY_ADDRESS'),(select resource_id from sdp_resource where resource_name='$RESOURCE_NAME'))"
  fi
}

function writeSquid {
  sed -i "/${RESOURCE_NAME}_domain/d" $SQUID_DSTDOMAIN
  echo "acl ${RESOURCE_NAME}_domain dstdomain $RESOURCE_DOMAIN" >> $SQUID_DSTDOMAIN

  for name in "${RESOURCE_GROUP[@]}"
  do
    if [ `grep -c $name $SQUID_GROUP` -lt 1 ]; then
      echo "acl ${name}_group external sdp_user_groups $name" >> $SQUID_GROUP
    fi
  done

  for number in "${RESOURCE_PORT[@]}"
  do
    if [ `grep -c $number $SQUID_PORTS` -lt 1 ]; then
      echo "acl ${number}_port port $number" >> $SQUID_PORTS
    fi
  done

  sed -i "/${RESOURCE_NAME}_domain/d" $SQUID_CACHE_ACCESS
  if [ "$GATEWAY_ADDRESS" != "DIRECT" ]; then
    echo "cache_peer_access $GATEWAY_ADDRESS allow ${RESOURCE_NAME}_domain" >> $SQUID_CACHE_ACCESS
    echo "never_direct allow ${RESOURCE_NAME}_domain" >> $SQUID_CACHE_ACCESS
  fi

  sed -i "/${RESOURCE_NAME}_domain/d" $SQUID_ACCESS
  for name in "${RESOURCE_GROUP[@]}"
  do
    echo "http_access allow ${RESOURCE_NAME}_domain ${name}_group" >> $SQUID_ACCESS
  done
  echo "http_access deny ${RESOURCE_NAME}_domain" >> $SQUID_ACCESS

  service squid reload
}

resourcePorts
resourceGroups

echo "Resource Definition:"
echo
echo "Resource Name = $RESOURCE_NAME"
echo "Resource Type = $RESOURCE_TYPE"
echo "Resource Ports = ${RESOURCE_PORT[@]}"
echo "Resource Groups = ${RESOURCE_GROUP[@]}"

RESOURCE_EXISTS=`mysql -h$HOST -P$PORT -u$USER -p$PASS $DB -sNe "select count(*) from sdp_resource where resource_name='$RESOURCE_NAME'"`
if [ "$RESOURCE_EXISTS" -gt 1 ]; then
  read -r -p "Resource exists, would you like to update the resource instead? [Y/n] " response
  case "$response" in
  [yY][eE][sS]|[yY])
      echo Exiting
      ;;
  *) 
      echo Exiting 
      ;;
  esac
#  exit
else
  insertDB
  writeSquid
fi
